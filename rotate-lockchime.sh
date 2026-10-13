#!/usr/bin/env bash
# Swap LockChime.wav for a different library clip.
#
# The car imports the file when it next scans the USB volume. This script does
# not unbind, rebind, or reconnect the gadget: dashcam and Sentry keep the
# drive. A cycle is skipped when the lock is already held, an archive or
# music sync is running, or the camera image is busy.
set -euo pipefail

LOCKCHIME_CONFIG="${LOCKCHIME_CONFIG:-/etc/default/lockchime-rotate}"
if [ ! -f "$LOCKCHIME_CONFIG" ]; then
  echo "lockchime: $LOCKCHIME_CONFIG is missing, skipping"
  exit 0
fi
# shellcheck disable=SC1090
source "$LOCKCHIME_CONFIG"

: "${CHIME_DIR:?CHIME_DIR is not set}"
: "${TARGET_FILE:?TARGET_FILE is not set}"

CAM_MOUNT="${CAM_MOUNT:-/mnt/cam}"
LOCK_FILE="${LOCKCHIME_LOCK:-/tmp/lockchime-rotate.lock}"
IMAGE="${LOCKCHIME_IMAGE:-/backingfiles/cam_disk.bin}"
# Tesla rejects a lock chime of 1 MiB or larger and keeps the previous sound.
MAX_WAV_BYTES=1048576
USE_MOUNT=0
if [ "${1:-}" = "--use-mount" ]; then
  USE_MOUNT=1
fi

STATE_FILE="${CHIME_DIR}/.last_lockchime"
TMP_WAV=""

cleanup() {
  local rc=$?
  if [ -n "$TMP_WAV" ] && [ -e "$TMP_WAV" ]; then
    rm -f -- "$TMP_WAV" || true
  fi
  exit "$rc"
}
trap cleanup EXIT

skip() {
  echo "lockchime: $*"
  exit 0
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  skip "lock held, skipping this cycle"
fi

archive_running() {
  if [ "${LOCKCHIME_ASSUME_ARCHIVE:-}" = "1" ]; then
    return 0
  fi
  if [ "${LOCKCHIME_ASSUME_ARCHIVE:-}" = "0" ]; then
    return 1
  fi
  if mountpoint -q /mnt/archive || mountpoint -q /mnt/musicarchive; then
    return 0
  fi
  if pgrep -x rsync >/dev/null 2>&1 || pgrep -x rclone >/dev/null 2>&1; then
    return 0
  fi
  if pgrep -f '/archive-clips\.sh' >/dev/null 2>&1 || pgrep -f '/copy-music\.sh' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

image_has_loop() {
  [ -e "$IMAGE" ] || return 1
  losetup -j "$IMAGE" 2>/dev/null | grep -q .
}

gadget_active() {
  if [ -n "${LOCKCHIME_GADGET_ACTIVE+x}" ]; then
    [ "$LOCKCHIME_GADGET_ACTIVE" = "1" ]
    return
  fi
  local udc=/sys/kernel/config/usb_gadget/teslausb/UDC
  [ -r "$udc" ] || return 1
  [ -n "$(cat "$udc" 2>/dev/null || true)" ]
}

choose() {
  local -a pool=("$@")
  local n=${#pool[@]}
  [ "$n" -gt 0 ] || return 1
  printf '%s\n' "${pool[RANDOM % n]}"
}

mapfile -t files < <(find "$CHIME_DIR" -maxdepth 1 -type f -iname '*.wav' ! -iname '._*' -size -"${MAX_WAV_BYTES}c" | sort)
if [ "${#files[@]}" -eq 0 ]; then
  skip "no WAV files under ${MAX_WAV_BYTES} bytes in $CHIME_DIR"
fi

if archive_running; then
  skip "archive or sync is running, skipping this cycle"
fi

current=""
if [ -f "$TARGET_FILE" ]; then
  for candidate in "${files[@]}"; do
    if cmp -n "$(stat -c %s "$candidate")" -s -- "$candidate" "$TARGET_FILE"; then
      current="$candidate"
      break
    fi
  done
fi

last=""
if [ -f "$STATE_FILE" ]; then
  last="$(cat "$STATE_FILE" || true)"
fi

not_current=()
eligible=()
for candidate in "${files[@]}"; do
  if [ "$candidate" = "$current" ]; then
    continue
  fi
  not_current+=("$candidate")
  if [ -n "$last" ] && [ "$candidate" = "$last" ]; then
    continue
  fi
  eligible+=("$candidate")
done

pick=""
if [ "${#files[@]}" -eq 1 ]; then
  pick="${files[0]}"
elif pick="$(choose "${eligible[@]+"${eligible[@]}"}")"; then
  :
elif pick="$(choose "${not_current[@]+"${not_current[@]}"}")"; then
  :
else
  pick="${files[0]}"
fi

# Slot is the largest library clip. The file keeps that many clusters so a
# later in-place swap does not have to allocate while the car is writing.
slot=0
for candidate in "${files[@]}"; do
  sz=$(stat -c %s "$candidate")
  if [ "$sz" -gt "$slot" ]; then
    slot=$sz
  fi
done

write_on_mount() {
  local tmp="${TARGET_FILE}.tmp.$$"
  TMP_WAV=$tmp
  cp -- "$pick" "$tmp"
  local cur
  cur=$(stat -c %s "$tmp")
  if [ "$slot" -gt "$cur" ]; then
    dd if=/dev/zero of="$tmp" bs=1 seek="$cur" count=$((slot - cur)) conv=notrunc status=none
  fi
  sync || true
  mv -f -- "$tmp" "$TARGET_FILE"
  TMP_WAV=""
  sync || true
}

inplace_writer() {
  if [ -n "${LOCKCHIME_INPLACE:-}" ]; then
    printf '%s\n' "$LOCKCHIME_INPLACE"
    return
  fi
  local here
  here=$(dirname "$(readlink -f "$0")")
  if [ -f "$here/lockchime_inplace.py" ]; then
    printf '%s\n' "$here/lockchime_inplace.py"
    return
  fi
  if [ -f "$here/run/lockchime_inplace.py" ]; then
    printf '%s\n' "$here/run/lockchime_inplace.py"
    return
  fi
  printf '%s\n' /root/bin/lockchime_inplace.py
}

write_inplace() {
  local offset writer rc
  if [ -n "${LOCKCHIME_IMAGE_OFFSET:-}" ]; then
    offset=$LOCKCHIME_IMAGE_OFFSET
  elif [ -e "$IMAGE" ]; then
    offset=$(sfdisk -l -q -o START "$IMAGE" | tail -1)
    offset=$((offset * 512))
  else
    skip "camera image $IMAGE is missing, skipping this cycle"
  fi
  writer=$(inplace_writer)
  set +e
  if [ -x "$writer" ]; then
    "$writer" --image "$IMAGE" --offset "$offset" --name "$(basename "$TARGET_FILE")" --source "$pick"
  else
    python3 "$writer" --image "$IMAGE" --offset "$offset" --name "$(basename "$TARGET_FILE")" --source "$pick"
  fi
  rc=$?
  set -e
  if [ "$rc" -eq 3 ]; then
    skip "camera image is not ready for an in-place swap, skipping this cycle"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "lockchime: in-place swap failed ($rc)" >&2
    exit "$rc"
  fi
}

if [ "$USE_MOUNT" -eq 1 ]; then
  if ! mountpoint -q "$CAM_MOUNT"; then
    skip "startup mount $CAM_MOUNT is not available, skipping this cycle"
  fi
  write_on_mount
elif mountpoint -q "$CAM_MOUNT" || { [ "${LOCKCHIME_ASSUME_BUSY:-}" = "1" ]; } || image_has_loop; then
  skip "camera drive is busy, skipping this cycle"
elif gadget_active; then
  write_inplace
else
  mount_log=$(mktemp)
  if ! mount "$CAM_MOUNT" >"$mount_log" 2>&1; then
    cat "$mount_log" >&2 || true
    rm -f "$mount_log"
    skip "camera drive is busy, skipping this cycle"
  fi
  rm -f "$mount_log"
  write_on_mount
  umount "$CAM_MOUNT" || true
fi

printf '%s\n' "$pick" > "$STATE_FILE"
echo "Current chime: ${current:-<unknown>}"
echo "Selected chime: $pick -> $TARGET_FILE"
