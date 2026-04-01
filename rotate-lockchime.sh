#!/usr/bin/env bash
set -euo pipefail
source /etc/default/lockchime-rotate

STATE_FILE="${CHIME_DIR}/.last_lockchime"
GADGET_WAS_DISABLED=0
CAM_WAS_MOUNTED=0

cleanup() {
  local rc=$?
  if [ "$CAM_WAS_MOUNTED" -eq 1 ]; then
    sync || true
    umount /mnt/cam || true
  fi
  if [ "$GADGET_WAS_DISABLED" -eq 1 ]; then
    /root/bin/enable_gadget.sh || true
  fi
  exit $rc
}
trap cleanup EXIT

if ! mountpoint -q /mnt/cam; then
  disable_log=/tmp/lockchime-disable-gadget.log
  if /root/bin/disable_gadget.sh >"$disable_log" 2>&1; then
    GADGET_WAS_DISABLED=1
  elif grep -qi 'already released' "$disable_log"; then
    :
  else
    cat "$disable_log" >&2 || true
    exit 1
  fi

  mounted=0
  sleep 5
  for _ in $(seq 1 20); do
    if mountpoint -q /mnt/cam; then
      mounted=1
      break
    fi
    mount_log=/tmp/lockchime-mount.log
    if mount /mnt/cam >"$mount_log" 2>&1; then
      mounted=1
      CAM_WAS_MOUNTED=1
      break
    elif grep -qi 'overlapping loop device exists' "$mount_log"; then
      sleep 3
    elif grep -qi 'is already mounted' "$mount_log"; then
      sleep 1
      mountpoint -q /mnt/cam && mounted=1 && CAM_WAS_MOUNTED=1 && break
    else
      cat "$mount_log" >&2 || true
      exit 1
    fi
  done

  if [ "$mounted" -ne 1 ]; then
    cat /tmp/lockchime-mount.log >&2 || true
    exit 1
  fi

  mountpoint -q /mnt/cam && CAM_WAS_MOUNTED=1
fi

mapfile -t files < <(find "$CHIME_DIR" -maxdepth 1 -type f -iname '*.wav' ! -iname '._*' | sort)
[ "${#files[@]}" -gt 0 ] || { echo "No WAV files found in $CHIME_DIR"; exit 1; }

pick=""
current=""
count="${#files[@]}"

if [ "$count" -eq 1 ]; then
  pick="${files[0]}"
else
  last=""
  [ -f "$STATE_FILE" ] && last="$(cat "$STATE_FILE" || true)"

  if [ -f "$TARGET_FILE" ]; then
    for candidate in "${files[@]}"; do
      if cmp -s -- "$candidate" "$TARGET_FILE"; then
        current="$candidate"
        break
      fi
    done
  fi

  if [ -z "$current" ] && [ -n "$last" ]; then
    current="$last"
  fi

  eligible=()
  for candidate in "${files[@]}"; do
    [ "$candidate" = "$current" ] && continue
    eligible+=("$candidate")
  done

  if [ "${#eligible[@]}" -gt 0 ]; then
    pick="${eligible[RANDOM % ${#eligible[@]}]}"
  else
    pick="${files[RANDOM % count]}"
  fi
fi

install -m 0644 "$pick" "$TARGET_FILE"
printf '%s\n' "$pick" > "$STATE_FILE"

echo "Current chime: ${current:-<unknown>}"
echo "Selected chime: $pick -> $TARGET_FILE"
