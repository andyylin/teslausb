#!/usr/bin/env bash
# Replace LockChime.wav on the camera image with a different library clip.
#
# Tesla imports LockChime.wav into the car when the USB volume is enumerated.
# It then plays that cached copy on lock/unlock and does not re-read the file
# for each event. This helper therefore has to publish a new file and bounce
# the gadget; the new clip is what the next scan (usually the next lock or
# unlock after this run) can import. Clips of 1 MiB or more are ignored by
# the car, which keeps playing the previous import.
set -euo pipefail

LOCKCHIME_CONFIG="${LOCKCHIME_CONFIG:-/etc/default/lockchime-rotate}"
# shellcheck disable=SC1090
source "$LOCKCHIME_CONFIG"

: "${CHIME_DIR:?CHIME_DIR is not set}"
: "${TARGET_FILE:?TARGET_FILE is not set}"

CAM_MOUNT="${CAM_MOUNT:-/mnt/cam}"
DISABLE_GADGET="${DISABLE_GADGET:-/root/bin/disable_gadget.sh}"
ENABLE_GADGET="${ENABLE_GADGET:-/root/bin/enable_gadget.sh}"
LOCK_FILE="${LOCKCHIME_LOCK:-/tmp/lockchime-rotate.lock}"
RETRY_SLEEP="${LOCKCHIME_RETRY_SLEEP:-1}"
MAX_ATTEMPTS="${LOCKCHIME_MAX_ATTEMPTS:-40}"
# Tesla rejects a lock chime of 1 MiB or larger and keeps the previous sound.
MAX_WAV_BYTES=1048576

STATE_FILE="${CHIME_DIR}/.last_lockchime"
GADGET_WAS_DISABLED=0
CAM_WAS_MOUNTED=0
TMP_WAV=""

cleanup() {
  local rc=$?
  if [ -n "$TMP_WAV" ] && [ -e "$TMP_WAV" ]; then
    rm -f -- "$TMP_WAV" || true
  fi
  if [ "$CAM_WAS_MOUNTED" -eq 1 ]; then
    sync || true
    umount "$CAM_MOUNT" || true
    CAM_WAS_MOUNTED=0
  fi
  if [ "$GADGET_WAS_DISABLED" -eq 1 ]; then
    # If another task mounted the image after we released the gadget, leave
    # the gadget down. Re-enabling it under their mount looks like a skipped
    # rotation and can corrupt the live filesystem.
    if mountpoint -q "$CAM_MOUNT"; then
      echo "leaving gadget disconnected; $CAM_MOUNT is in use" >&2
    else
      "$ENABLE_GADGET" || true
    fi
    GADGET_WAS_DISABLED=0
  fi
  exit "$rc"
}
trap cleanup EXIT

exec 9>"$LOCK_FILE"
flock -w "${LOCKCHIME_LOCK_WAIT:-30}" 9

acquire_cam() {
  local attempt=0
  local logf

  rm -f /tmp/lockchime-disable-gadget.log /tmp/lockchime-mount.log
  while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if mountpoint -q "$CAM_MOUNT"; then
      # Someone else (usually archiveloop) owns the image. Do not write
      # through their mount and do not unmount it.
      sleep "$RETRY_SLEEP"
      continue
    fi

    logf=/tmp/lockchime-disable-gadget.log
    if "$DISABLE_GADGET" >"$logf" 2>&1; then
      GADGET_WAS_DISABLED=1
    elif grep -qi 'already released' "$logf"; then
      :
    else
      cat "$logf" >&2 || true
      return 1
    fi

    logf=/tmp/lockchime-mount.log
    if mount "$CAM_MOUNT" >"$logf" 2>&1; then
      CAM_WAS_MOUNTED=1
      return 0
    fi
    if mountpoint -q "$CAM_MOUNT"; then
      sleep "$RETRY_SLEEP"
      continue
    fi
    if grep -qiE 'overlapping loop|already mounted|resource busy|device is busy' "$logf"; then
      sleep "$RETRY_SLEEP"
      continue
    fi
    # Unrecognized mount errors are often the same busy race with different
    # wording. Retry briefly, then surface the log.
    if [ "$attempt" -ge 5 ]; then
      cat "$logf" >&2 || true
      return 1
    fi
    sleep "$RETRY_SLEEP"
  done

  echo "timed out waiting to mount $CAM_MOUNT" >&2
  cat /tmp/lockchime-mount.log >&2 || true
  return 1
}

choose() {
  local -a pool=("$@")
  local n=${#pool[@]}
  [ "$n" -gt 0 ] || return 1
  printf '%s\n' "${pool[RANDOM % n]}"
}

mapfile -t files < <(find "$CHIME_DIR" -maxdepth 1 -type f -iname '*.wav' ! -iname '._*' -size -"${MAX_WAV_BYTES}c" | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No WAV files under ${MAX_WAV_BYTES} bytes in $CHIME_DIR" >&2
  exit 1
fi

acquire_cam

current=""
if [ -f "$TARGET_FILE" ]; then
  for candidate in "${files[@]}"; do
    if cmp -s -- "$candidate" "$TARGET_FILE"; then
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

# Publish a new directory entry. An in-place overwrite of LockChime.wav is
# what the car's importer tends to treat as "unchanged", so the previous
# cached chime keeps playing.
TMP_WAV="${TARGET_FILE}.tmp.$$"
install -m 0644 "$pick" "$TMP_WAV"
sync || true
mv -f -- "$TMP_WAV" "$TARGET_FILE"
TMP_WAV=""
sync || true
printf '%s\n' "$pick" > "$STATE_FILE"

echo "Current chime: ${current:-<unknown>}"
echo "Selected chime: $pick -> $TARGET_FILE"
