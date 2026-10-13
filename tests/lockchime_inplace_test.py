#!/usr/bin/env python3
"""Round-trip LockChime.wav through a tiny FAT16 image. No mount and no gadget."""

from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "run"))
import lockchime_inplace as fat  # noqa: E402


def build_fat16(name: str, payload: bytes) -> bytes:
    bps = 512
    reserved = 1
    fat_sectors = 1
    root_entries = 16
    data_clusters = 4
    total = reserved + fat_sectors + 1 + data_clusters
    blob = bytearray(total * bps)
    blob[0:3] = b"\xeb\x3c\x90"
    blob[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", blob, 11, bps)
    blob[13] = 1
    struct.pack_into("<H", blob, 14, reserved)
    blob[16] = 1
    struct.pack_into("<H", blob, 17, root_entries)
    struct.pack_into("<H", blob, 19, total)
    blob[21] = 0xF8
    struct.pack_into("<H", blob, 22, fat_sectors)
    blob[38] = 0x29
    blob[54:62] = b"FAT16   "
    blob[510:512] = b"\x55\xaa"

    fat_table = bytearray(fat_sectors * bps)
    struct.pack_into("<H", fat_table, 0, 0xFFF8)
    struct.pack_into("<H", fat_table, 2, 0xFFFF)
    # Cluster 2 holds the file and ends the chain.
    struct.pack_into("<H", fat_table, 4, 0xFFFF)
    blob[bps : bps + len(fat_table)] = fat_table

    short = bytearray(32)
    short[0:11] = b"LOCKCH~1WAV"
    short[11] = 0x20
    struct.pack_into("<H", short, 26, 2)
    struct.pack_into("<I", short, 28, len(payload))

    text = name.encode("utf-16le")
    # One LFN entry holds 13 UTF-16 characters.
    text = text[:26] + b"\x00\x00" * (13 - len(name))
    lfn = bytearray(32)
    lfn[0] = 0x41
    lfn[1:11] = text[0:10]
    lfn[11] = 0x0F
    lfn[14:26] = text[10:22]
    lfn[28:32] = text[22:26]
    root_off = (reserved + fat_sectors) * bps
    blob[root_off : root_off + 32] = lfn
    blob[root_off + 32 : root_off + 64] = short

    data_off = (reserved + fat_sectors + 1) * bps
    blob[data_off : data_off + len(payload)] = payload
    return bytes(blob)


class InplaceTest(unittest.TestCase):
    def test_overwrite_keeps_clusters_and_name(self) -> None:
        image = build_fat16("LockChime.wav", b"aaa")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cam.bin"
            src = Path(tmp) / "next.wav"
            path.write_bytes(image)
            src.write_bytes(b"bbbb")
            rc = fat.overwrite(str(path), 0, "LockChime.wav", str(src))
            self.assertEqual(rc, 0)
            got = fat.read_file_bytes(str(path), 0, "LockChime.wav")
            self.assertEqual(got, b"bbbb")
            # The FAT still ends cluster 2. No new cluster was allocated.
            fat_table = path.read_bytes()[512:514]
            self.assertEqual(fat_table, b"\xf8\xff")
            entry = struct.unpack_from("<H", path.read_bytes(), 512 + 4)[0]
            self.assertEqual(entry, 0xFFFF)

    def test_too_big_for_the_existing_chain_skips(self) -> None:
        image = build_fat16("LockChime.wav", b"aaa")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cam.bin"
            src = Path(tmp) / "big.wav"
            path.write_bytes(image)
            src.write_bytes(b"x" * 600)
            before = path.read_bytes()
            rc = fat.overwrite(str(path), 0, "LockChime.wav", str(src))
            self.assertEqual(rc, fat.SKIP)
            self.assertEqual(path.read_bytes(), before)

    def test_missing_file_skips(self) -> None:
        image = build_fat16("LockChime.wav", b"aaa")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cam.bin"
            src = Path(tmp) / "next.wav"
            path.write_bytes(image)
            src.write_bytes(b"b")
            rc = fat.overwrite(str(path), 0, "Other.wav", str(src))
            self.assertEqual(rc, fat.SKIP)
            self.assertEqual(fat.read_file_bytes(str(path), 0, "LockChime.wav"), b"aaa")


if __name__ == "__main__":
    unittest.main()
