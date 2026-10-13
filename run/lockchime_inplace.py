#!/usr/bin/env python3
"""Overwrite LockChime.wav inside a FAT image without changing cluster allocation.

The USB gadget keeps this image open while the car records. Mounting it from
the Pi at the same time would let two FAT drivers allocate clusters. This
writer only replaces bytes that already belong to LockChime.wav and patches
that one directory entry (size and timestamp). It does not rewrite the FAT,
so a dashcam write cannot be handed those clusters.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import time
from dataclasses import dataclass


SKIP = 3


@dataclass
class FatFs:
    fat_bits: int
    bytes_per_sector: int
    sectors_per_cluster: int
    reserved_sectors: int
    num_fats: int
    root_entries: int
    fat_sectors: int
    root_cluster: int
    partition_offset: int

    @property
    def first_data_sector(self) -> int:
        root_sectors = (
            (self.root_entries * 32 + self.bytes_per_sector - 1) // self.bytes_per_sector
        )
        return self.reserved_sectors + self.num_fats * self.fat_sectors + root_sectors

    def cluster_offset(self, cluster: int) -> int:
        sector = self.first_data_sector + (cluster - 2) * self.sectors_per_cluster
        return self.partition_offset + sector * self.bytes_per_sector

    @property
    def cluster_bytes(self) -> int:
        return self.bytes_per_sector * self.sectors_per_cluster


def _skip(message: str) -> int:
    print(f"lockchime inplace: {message}", file=sys.stderr)
    return SKIP


def parse_boot(blob: bytes, partition_offset: int) -> FatFs:
    if len(blob) < 512 or blob[510:512] != b"\x55\xaa":
        raise ValueError("not a FAT boot sector")
    if blob[3:11] == b"EXFAT   ":
        raise ValueError("exfat")
    bytes_per_sector = struct.unpack_from("<H", blob, 11)[0]
    sectors_per_cluster = blob[13]
    reserved = struct.unpack_from("<H", blob, 14)[0]
    num_fats = blob[16]
    root_entries = struct.unpack_from("<H", blob, 17)[0]
    fat_sectors_16 = struct.unpack_from("<H", blob, 22)[0]
    total_16 = struct.unpack_from("<H", blob, 19)[0]
    total_32 = struct.unpack_from("<I", blob, 32)[0]
    fat_sectors_32 = struct.unpack_from("<I", blob, 36)[0]
    root_cluster = struct.unpack_from("<I", blob, 44)[0]
    total = total_16 or total_32
    fat_sectors = fat_sectors_16 or fat_sectors_32
    if bytes_per_sector < 512 or sectors_per_cluster == 0 or num_fats == 0 or fat_sectors == 0:
        raise ValueError("unsupported FAT geometry")
    root_sectors = (root_entries * 32 + bytes_per_sector - 1) // bytes_per_sector
    data_sectors = total - reserved - num_fats * fat_sectors - root_sectors
    cluster_count = data_sectors // sectors_per_cluster
    kind = blob[54:62]
    kind32 = blob[82:90]
    if kind32.startswith(b"FAT32"):
        fat_bits = 32
    elif kind.startswith(b"FAT12"):
        fat_bits = 12
    elif kind.startswith(b"FAT16"):
        fat_bits = 16
    elif cluster_count < 4085:
        fat_bits = 12
    elif cluster_count < 65525:
        fat_bits = 16
    else:
        fat_bits = 32
    return FatFs(
        fat_bits=fat_bits,
        bytes_per_sector=bytes_per_sector,
        sectors_per_cluster=sectors_per_cluster,
        reserved_sectors=reserved,
        num_fats=num_fats,
        root_entries=root_entries,
        fat_sectors=fat_sectors,
        root_cluster=root_cluster,
        partition_offset=partition_offset,
    )


def _fat_entry(fat: bytes, bits: int, cluster: int) -> int:
    if bits == 12:
        offset = cluster + cluster // 2
        val = fat[offset] | (fat[offset + 1] << 8)
        return (val >> 4) if cluster & 1 else (val & 0x0FFF)
    if bits == 16:
        return struct.unpack_from("<H", fat, cluster * 2)[0]
    return struct.unpack_from("<I", fat, cluster * 4)[0] & 0x0FFFFFFF


def _eoc(bits: int, value: int) -> bool:
    if bits == 12:
        return value >= 0x0FF8
    if bits == 16:
        return value >= 0xFFF8
    return value >= 0x0FFFFFF8


def cluster_chain(fat: bytes, fs: FatFs, start: int) -> list[int]:
    chain: list[int] = []
    cluster = start
    seen: set[int] = set()
    while cluster >= 2 and cluster not in seen and not _eoc(fs.fat_bits, cluster):
        if _fat_entry(fat, fs.fat_bits, cluster) == 0:
            break
        seen.add(cluster)
        chain.append(cluster)
        nxt = _fat_entry(fat, fs.fat_bits, cluster)
        if _eoc(fs.fat_bits, nxt):
            break
        cluster = nxt
        if len(chain) > 100000:
            break
    return chain


def _lfn_chars(entry: bytes) -> str:
    raw = entry[1:11] + entry[14:26] + entry[28:32]
    chars = []
    for i in range(0, len(raw), 2):
        code = struct.unpack_from("<H", raw, i)[0]
        if code in (0x0000, 0xFFFF):
            break
        chars.append(chr(code))
    return "".join(chars)


def _short_name(entry: bytes) -> str:
    base = entry[0:8].decode("latin1", "replace").rstrip(" ")
    ext = entry[8:11].decode("latin1", "replace").rstrip(" ")
    if entry[0] == 0x05:
        # 0x05 stands in for 0xE5, which is also the deleted-entry marker.
        base = chr(0xE5) + base[1:]
    flags = entry[12]
    if flags & 0x08:
        base = base.lower()
    if flags & 0x10:
        ext = ext.lower()
    return f"{base}.{ext}" if ext else base


def _iter_dir_entries(data: bytes):
    for off in range(0, len(data) - 31, 32):
        entry = data[off : off + 32]
        if entry[0] == 0x00:
            return
        yield off, entry


def find_file(fs: FatFs, fat: bytes, directory: bytes, name: str) -> tuple[int, int, int] | None:
    """Return (dir_entry_offset, start_cluster, file_size) for name."""
    want = name.casefold()
    lfn: list[tuple[int, str]] = []
    for off, entry in _iter_dir_entries(directory):
        if entry[0] == 0xE5:
            lfn = []
            continue
        attr = entry[11]
        if attr == 0x0F:
            seq = entry[0] & 0x1F
            lfn.append((seq, _lfn_chars(entry)))
            continue
        built = ""
        if lfn:
            built = "".join(part for _, part in sorted(lfn))
            lfn = []
        shown = built or _short_name(entry)
        if attr & 0x08 or attr & 0x10:
            continue
        if shown.casefold() != want:
            continue
        start = struct.unpack_from("<H", entry, 26)[0] | (
            struct.unpack_from("<H", entry, 20)[0] << 16
        )
        size = struct.unpack_from("<I", entry, 28)[0]
        if start < 2:
            return None
        # dir_entry_offset is relative to the directory blob. Callers that
        # pass a concatenated chain use the parallel cluster map instead.
        return off, start, size
    return None


def _directory_blob(fd: int, fs: FatFs, fat: bytes) -> tuple[bytes, list[tuple[int, int]]]:
    """Return directory bytes and (absolute file offset, length) pieces."""
    if fs.root_entries:
        root_bytes = fs.root_entries * 32
        root_off = fs.partition_offset + (
            fs.reserved_sectors + fs.num_fats * fs.fat_sectors
        ) * fs.bytes_per_sector
        os.lseek(fd, root_off, os.SEEK_SET)
        return os.read(fd, root_bytes), [(root_off, root_bytes)]
    pieces: list[tuple[int, int]] = []
    chunks: list[bytes] = []
    for cluster in cluster_chain(fat, fs, fs.root_cluster):
        off = fs.cluster_offset(cluster)
        os.lseek(fd, off, os.SEEK_SET)
        chunk = os.read(fd, fs.cluster_bytes)
        pieces.append((off, len(chunk)))
        chunks.append(chunk)
    return b"".join(chunks), pieces


def _absolute_dir_offset(pieces: list[tuple[int, int]], rel: int) -> int:
    cursor = 0
    for off, length in pieces:
        if rel < cursor + length:
            return off + (rel - cursor)
        cursor += length
    raise ValueError("directory entry offset is outside the directory")


def read_file_bytes(image: str, partition_offset: int, name: str) -> bytes | None:
    fd = os.open(image, os.O_RDONLY)
    try:
        os.lseek(fd, partition_offset, os.SEEK_SET)
        boot = os.read(fd, 512)
        fs = parse_boot(boot, partition_offset)
        fat_off = partition_offset + fs.reserved_sectors * fs.bytes_per_sector
        os.lseek(fd, fat_off, os.SEEK_SET)
        fat = os.read(fd, fs.fat_sectors * fs.bytes_per_sector)
        directory, _pieces = _directory_blob(fd, fs, fat)
        found = find_file(fs, fat, directory, name)
        if found is None:
            return None
        _rel, start, size = found
        chain = cluster_chain(fat, fs, start)
        left = size
        out = bytearray()
        for cluster in chain:
            if left <= 0:
                break
            os.lseek(fd, fs.cluster_offset(cluster), os.SEEK_SET)
            take = min(left, fs.cluster_bytes)
            out += os.read(fd, take)
            left -= take
        return bytes(out)
    finally:
        os.close(fd)


def overwrite(image: str, partition_offset: int, name: str, source: str) -> int:
    with open(source, "rb") as src:
        new = src.read()
    fd = os.open(image, os.O_RDWR)
    try:
        os.lseek(fd, partition_offset, os.SEEK_SET)
        boot = os.read(fd, 512)
        try:
            fs = parse_boot(boot, partition_offset)
        except ValueError as exc:
            return _skip(str(exc))
        fat_off = partition_offset + fs.reserved_sectors * fs.bytes_per_sector
        os.lseek(fd, fat_off, os.SEEK_SET)
        fat = os.read(fd, fs.fat_sectors * fs.bytes_per_sector)
        directory, pieces = _directory_blob(fd, fs, fat)
        found = find_file(fs, fat, directory, name)
        if found is None:
            return _skip(f"{name} is not on the image")
        rel, start, old_size = found
        chain = cluster_chain(fat, fs, start)
        if not chain:
            return _skip(f"{name} has no clusters")
        allocated = len(chain) * fs.cluster_bytes
        if len(new) > allocated:
            return _skip(
                f"{name} has {allocated} bytes allocated, new clip is {len(new)}"
            )
        # Keep the existing chain. Fill through the previous logical size so a
        # reader with a stale larger size does not play the tail of the old clip.
        span = max(old_size, len(new))
        if span > allocated:
            span = allocated
        payload = new + bytes(span - len(new))
        view = memoryview(payload)
        written = 0
        for cluster in chain:
            if written >= len(payload):
                break
            chunk = view[written : written + fs.cluster_bytes]
            os.lseek(fd, fs.cluster_offset(cluster), os.SEEK_SET)
            os.write(fd, chunk)
            written += len(chunk)
        os.fsync(fd)

        entry = bytearray(directory[rel : rel + 32])
        struct.pack_into("<I", entry, 28, len(new))
        when = time.localtime()
        # Python's tm_year is the calendar year and tm_mon is 1-12.
        # FAT stores years since 1980 in 7 bits.
        fat_time = (when.tm_sec // 2) | (when.tm_min << 5) | (when.tm_hour << 11)
        fat_year = max(0, when.tm_year - 1980) & 0x7F
        fat_date = when.tm_mday | (when.tm_mon << 5) | (fat_year << 9)
        struct.pack_into("<H", entry, 22, fat_time)
        struct.pack_into("<H", entry, 24, fat_date)
        os.lseek(fd, _absolute_dir_offset(pieces, rel), os.SEEK_SET)
        os.write(fd, entry)
        os.fsync(fd)
        return 0
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--offset", type=int, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--source", required=True)
    args = parser.parse_args()
    try:
        return overwrite(args.image, args.offset, args.name, args.source)
    except OSError as exc:
        print(f"lockchime inplace: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
