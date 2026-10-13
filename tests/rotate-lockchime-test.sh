#!/usr/bin/env bash
# Rotations must not touch the USB gadget. Busy, archive, and lock skip the cycle.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/rotate-lockchime.sh"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

STATE="$WORKDIR/state"
BIN="$WORKDIR/bin"
mkdir -p "$STATE" "$BIN"

cat > "$BIN/mountpoint" << 'EOF'
#!/usr/bin/env bash
state=${LOCKCHIME_TEST_STATE:?}
if [ -f "$state/mounted" ]; then
  exit 0
fi
exit 1
EOF

cat > "$BIN/mount" << 'EOF'
#!/usr/bin/env bash
state=${LOCKCHIME_TEST_STATE:?}
echo mount >> "$state/mount_calls"
mkdir -p "$1"
touch "$state/mounted"
exit 0
EOF

cat > "$BIN/umount" << 'EOF'
#!/usr/bin/env bash
state=${LOCKCHIME_TEST_STATE:?}
echo umount >> "$state/umount_calls"
rm -f "$state/mounted"
exit 0
EOF

cat > "$BIN/sync" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BIN/losetup" << 'EOF'
#!/usr/bin/env bash
state=${LOCKCHIME_TEST_STATE:?}
if [ -f "$state/loop" ]; then
  echo "/dev/loop0: []"
fi
exit 0
EOF

cat > "$BIN/disable_gadget.sh" << 'EOF'
#!/usr/bin/env bash
echo "disable should not be called" >> "${LOCKCHIME_TEST_STATE:?}/gadget"
exit 99
EOF

cat > "$BIN/enable_gadget.sh" << 'EOF'
#!/usr/bin/env bash
echo "enable should not be called" >> "${LOCKCHIME_TEST_STATE:?}/gadget"
exit 99
EOF

cat > "$BIN/inplace" << 'EOF'
#!/usr/bin/env bash
state=${LOCKCHIME_TEST_STATE:?}
echo inplace >> "$state/inplace_calls"
source=""
while [ $# -gt 0 ]; do
  case $1 in
    --source) source=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp -- "$source" "$state/inplace_bytes"
exit 0
EOF

chmod +x "$BIN/mountpoint" "$BIN/mount" "$BIN/umount" "$BIN/sync" \
  "$BIN/losetup" "$BIN/disable_gadget.sh" "$BIN/enable_gadget.sh" "$BIN/inplace"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local got=$1 expected=$2 label=$3
  if [ "$got" != "$expected" ]; then
    fail "$label: got [$got] expected [$expected]"
  fi
}

count_lines() {
  if [ -f "$1" ]; then
    wc -l < "$1" | tr -d ' '
  else
    echo 0
  fi
}

reset_state() {
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : > "$STATE/mount_calls"
  : > "$STATE/umount_calls"
  : > "$STATE/inplace_calls"
  : > "$STATE/gadget"
}

new_library() {
  local library=$1 cam=$2
  mkdir -p "$library" "$cam"
  printf 'CHIME_DIR=%q\nTARGET_FILE=%q\n' "$library" "$cam/LockChime.wav" > "$library/lockchime.conf"
}

run_rotate() {
  local cam=$1 library=$2
  shift 2
  LOCKCHIME_CONFIG="$library/lockchime.conf" \
  LOCKCHIME_TEST_STATE="$STATE" \
  LOCKCHIME_LOCK="$STATE/lock" \
  LOCKCHIME_ASSUME_ARCHIVE="${LOCKCHIME_ASSUME_ARCHIVE:-0}" \
  LOCKCHIME_GADGET_ACTIVE="${LOCKCHIME_GADGET_ACTIVE:-0}" \
  LOCKCHIME_IMAGE="$STATE/image.bin" \
  LOCKCHIME_IMAGE_OFFSET=0 \
  LOCKCHIME_INPLACE="$BIN/inplace" \
  CAM_MOUNT="$cam" \
  PATH="$BIN:$PATH" \
    "$SCRIPT" "$@"
}

echo "test: startup mount swaps the file and does not touch the gadget"
reset_state
cam="$WORKDIR/cam1"
library="$WORKDIR/lib1"
new_library "$library" "$cam"
printf 'aaa' > "$cam/LockChime.wav"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
touch "$STATE/mounted"
run_rotate "$cam" "$library" --use-mount > "$STATE/out"
assert_eq "$(cmp -n 3 -s "$library/b.wav" "$cam/LockChime.wav" && echo same || echo different)" "same" "startup wrote b"
assert_eq "$(count_lines "$STATE/gadget")" 0 "no gadget calls"
assert_eq "$(count_lines "$STATE/umount_calls")" 0 "startup does not unmount"
assert_eq "$(count_lines "$STATE/inplace_calls")" 0 "startup does not use in-place writer"
# The on-disk file is padded out to the larger library clip.
assert_eq "$(wc -c < "$cam/LockChime.wav" | tr -d ' ')" 3 "slot is the larger clip"

echo "test: second startup run picks the other clip"
run_rotate "$cam" "$library" --use-mount > "$STATE/out"
assert_eq "$(cmp -n 3 -s "$library/a.wav" "$cam/LockChime.wav" && echo same || echo different)" "same" "second startup wrote a"

echo "test: archive skips the cycle"
reset_state
cam="$WORKDIR/cam2"
library="$WORKDIR/lib2"
new_library "$library" "$cam"
printf 'aaa' > "$cam/LockChime.wav"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
touch "$STATE/mounted"
LOCKCHIME_ASSUME_ARCHIVE=1 run_rotate "$cam" "$library" --use-mount > "$STATE/out"
assert_eq "$(cat "$cam/LockChime.wav")" "aaa" "archive left the file"
grep -q 'archive or sync' "$STATE/out"

echo "test: a mounted camera image skips the periodic cycle"
reset_state
cam="$WORKDIR/cam3"
library="$WORKDIR/lib3"
new_library "$library" "$cam"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
touch "$STATE/mounted"
: > "$STATE/image.bin"
LOCKCHIME_GADGET_ACTIVE=1 run_rotate "$cam" "$library" > "$STATE/out"
assert_eq "$(count_lines "$STATE/inplace_calls")" 0 "busy image was not written"
grep -q 'camera drive is busy' "$STATE/out"
assert_eq "$(count_lines "$STATE/gadget")" 0 "busy cycle does not touch the gadget"

echo "test: while the gadget is up, only the in-place writer runs"
reset_state
cam="$WORKDIR/cam4"
library="$WORKDIR/lib4"
new_library "$library" "$cam"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
: > "$STATE/image.bin"
LOCKCHIME_GADGET_ACTIVE=1 run_rotate "$cam" "$library" > "$STATE/out"
assert_eq "$(count_lines "$STATE/inplace_calls")" 1 "in-place writer ran"
assert_eq "$(count_lines "$STATE/mount_calls")" 0 "did not mount"
assert_eq "$(count_lines "$STATE/gadget")" 0 "did not reconnect"
test -s "$STATE/inplace_bytes"

echo "test: a held lock skips"
reset_state
cam="$WORKDIR/cam5"
library="$WORKDIR/lib5"
new_library "$library" "$cam"
printf 'aaa' > "$cam/LockChime.wav"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
touch "$STATE/mounted"
flock "$STATE/lock" -c 'sleep 30' &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  flock -n "$STATE/lock" -c true && sleep 0.05 && continue
  break
done
run_rotate "$cam" "$library" --use-mount > "$STATE/out"
assert_eq "$(cat "$cam/LockChime.wav")" "aaa" "locked cycle did not write"
grep -q 'lock held' "$STATE/out"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

echo "test: gadget down mounts, swaps, and unmounts without enabling USB"
reset_state
cam="$WORKDIR/cam6"
library="$WORKDIR/lib6"
new_library "$library" "$cam"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
: > "$STATE/image.bin"
LOCKCHIME_GADGET_ACTIVE=0 run_rotate "$cam" "$library" > "$STATE/out"
assert_eq "$(count_lines "$STATE/mount_calls")" 1 "mounted while the car is absent"
assert_eq "$(count_lines "$STATE/umount_calls")" 1 "unmounted after the swap"
assert_eq "$(count_lines "$STATE/gadget")" 0 "did not enable the gadget"
assert_eq "$(cmp -n 3 -s "$library/a.wav" "$cam/LockChime.wav" || cmp -n 3 -s "$library/b.wav" "$cam/LockChime.wav" && echo ok || echo bad)" "ok" "wrote a library clip"

echo "test: startup pads the file out to the largest clip"
reset_state
cam="$WORKDIR/cam8"
library="$WORKDIR/lib8"
new_library "$library" "$cam"
printf 'aaa' > "$cam/LockChime.wav"
printf 'aaa' > "$library/a.wav"
printf 'bbbbb' > "$library/b.wav"
touch "$STATE/mounted"
run_rotate "$cam" "$library" --use-mount > "$STATE/out"
assert_eq "$(wc -c < "$cam/LockChime.wav" | tr -d ' ')" 5 "published file keeps the larger slot"
if cmp -n 3 -s "$library/a.wav" "$cam/LockChime.wav" || cmp -n 5 -s "$library/b.wav" "$cam/LockChime.wav"; then
  :
else
  fail "padded file does not start with a library clip"
fi
assert_eq "$(count_lines "$STATE/gadget")" 0 "pad path does not touch the gadget"

echo "test: a loop on the live image skips the periodic cycle"
reset_state
cam="$WORKDIR/cam9"
library="$WORKDIR/lib9"
new_library "$library" "$cam"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
: > "$STATE/image.bin"
touch "$STATE/loop"
LOCKCHIME_GADGET_ACTIVE=1 run_rotate "$cam" "$library" > "$STATE/out"
assert_eq "$(count_lines "$STATE/inplace_calls")" 0 "loop held the image"
grep -q 'camera drive is busy' "$STATE/out"

echo "test: an oversized library does not touch the drive"
reset_state
cam="$WORKDIR/cam7"
library="$WORKDIR/lib7"
new_library "$library" "$cam"
dd if=/dev/zero of="$library/big.wav" bs=1048576 count=1 status=none
LOCKCHIME_GADGET_ACTIVE=1 run_rotate "$cam" "$library" > "$STATE/out"
assert_eq "$(count_lines "$STATE/inplace_calls")" 0 "oversized library skipped"
assert_eq "$(count_lines "$STATE/mount_calls")" 0 "oversized library did not mount"
grep -q 'no WAV files under' "$STATE/out"

echo "all rotate-lockchime tests passed"
