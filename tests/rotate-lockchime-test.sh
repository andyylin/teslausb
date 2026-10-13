#!/usr/bin/env bash
# Static tests for rotate-lockchime.sh. Gadget and mount commands are fakes.
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
if [ -f "$state/hold" ]; then
  n=$(cat "$state/hold")
  if [ "$n" -gt 0 ]; then
    echo $((n - 1)) > "$state/hold"
    exit 0
  fi
fi
if [ -f "$state/mounted" ]; then
  exit 0
fi
exit 1
EOF

cat > "$BIN/mount" << 'EOF'
#!/usr/bin/env bash
state=${LOCKCHIME_TEST_STATE:?}
echo mount >> "$state/mount_calls"
target=${1:?}
if [ -f "$state/fail_mounts" ]; then
  n=$(cat "$state/fail_mounts")
  if [ "$n" -gt 0 ]; then
    echo $((n - 1)) > "$state/fail_mounts"
    msg=$(cat "$state/fail_message")
    echo "$msg" >&2
    exit 1
  fi
fi
mkdir -p "$target"
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

cat > "$BIN/disable_gadget.sh" << 'EOF'
#!/usr/bin/env bash
state=${LOCKCHIME_TEST_STATE:?}
echo disable >> "$state/gadget"
if [ -f "$state/disable_mode" ] && [ "$(cat "$state/disable_mode")" = "released" ]; then
  echo "already released" >&2
  exit 2
fi
if [ -f "$state/disable_mode" ] && [ "$(cat "$state/disable_mode")" = "fail" ]; then
  echo "disable failed" >&2
  exit 1
fi
exit 0
EOF

cat > "$BIN/enable_gadget.sh" << 'EOF'
#!/usr/bin/env bash
state=${LOCKCHIME_TEST_STATE:?}
echo enable >> "$state/gadget"
exit 0
EOF

chmod +x "$BIN/mountpoint" "$BIN/mount" "$BIN/umount" "$BIN/sync" \
  "$BIN/disable_gadget.sh" "$BIN/enable_gadget.sh"

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
  local f=$1
  if [ -f "$f" ]; then
    wc -l < "$f" | tr -d ' '
  else
    echo 0
  fi
}

reset_state() {
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : > "$STATE/mount_calls"
  : > "$STATE/umount_calls"
  : > "$STATE/gadget"
}

run_rotate() {
  local cam=$1 library=$2
  LOCKCHIME_CONFIG="$library/lockchime.conf" \
  LOCKCHIME_TEST_STATE="$STATE" \
  LOCKCHIME_LOCK="$STATE/lock" \
  LOCKCHIME_RETRY_SLEEP=0 \
  LOCKCHIME_MAX_ATTEMPTS="${LOCKCHIME_MAX_ATTEMPTS:-10}" \
  CAM_MOUNT="$cam" \
  DISABLE_GADGET="$BIN/disable_gadget.sh" \
  ENABLE_GADGET="$BIN/enable_gadget.sh" \
  PATH="$BIN:$PATH" \
    "$SCRIPT"
}

new_library() {
  local library=$1
  mkdir -p "$library"
  printf 'CHIME_DIR=%q\nTARGET_FILE=%q\n' "$library" "$CAM_FOR_CONF/LockChime.wav" \
    > "$library/lockchime.conf"
}

echo "test: rotates away from the clip currently on the image"
reset_state
CAM_FOR_CONF="$WORKDIR/cam1"
library="$WORKDIR/lib1"
mkdir -p "$CAM_FOR_CONF"
printf 'aaa' > "$CAM_FOR_CONF/LockChime.wav"
new_library "$library"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
run_rotate "$CAM_FOR_CONF" "$library" > "$STATE/out"
assert_eq "$(cat "$CAM_FOR_CONF/LockChime.wav")" "bbb" "first rotation"
assert_eq "$(count_lines "$STATE/umount_calls")" 1 "umounts once"
assert_eq "$(grep -c enable "$STATE/gadget")" 1 "restores gadget"
run_rotate "$CAM_FOR_CONF" "$library" > "$STATE/out"
assert_eq "$(cat "$CAM_FOR_CONF/LockChime.wav")" "aaa" "second rotation"

echo "test: retries a busy mount instead of skipping the rotation"
reset_state
CAM_FOR_CONF="$WORKDIR/cam2"
library="$WORKDIR/lib2"
mkdir -p "$CAM_FOR_CONF"
printf 'aaa' > "$CAM_FOR_CONF/LockChime.wav"
new_library "$library"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
echo 1 > "$STATE/fail_mounts"
echo "mount: device is busy" > "$STATE/fail_message"
run_rotate "$CAM_FOR_CONF" "$library" > "$STATE/out"
assert_eq "$(cat "$CAM_FOR_CONF/LockChime.wav")" "bbb" "rotation after busy"
assert_eq "$(count_lines "$STATE/mount_calls")" 2 "retried mount"

echo "test: does not claim or unmount a mount it did not create, then still rotates"
reset_state
CAM_FOR_CONF="$WORKDIR/cam3"
library="$WORKDIR/lib3"
mkdir -p "$CAM_FOR_CONF"
printf 'aaa' > "$CAM_FOR_CONF/LockChime.wav"
new_library "$library"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
echo 2 > "$STATE/hold"
run_rotate "$CAM_FOR_CONF" "$library" > "$STATE/out"
assert_eq "$(cat "$CAM_FOR_CONF/LockChime.wav")" "bbb" "rotation after foreign mount"
assert_eq "$(count_lines "$STATE/umount_calls")" 1 "does not unmount the foreign holder"

echo "test: gives up without touching the gadget when every clip is too large"
reset_state
CAM_FOR_CONF="$WORKDIR/cam4"
library="$WORKDIR/lib4"
mkdir -p "$CAM_FOR_CONF"
printf 'keep' > "$CAM_FOR_CONF/LockChime.wav"
new_library "$library"
dd if=/dev/zero of="$library/big.wav" bs=1048576 count=1 status=none
set +e
run_rotate "$CAM_FOR_CONF" "$library" > "$STATE/out" 2> "$STATE/err"
rc=$?
set -e
assert_eq "$rc" 1 "oversized library fails"
assert_eq "$(cat "$CAM_FOR_CONF/LockChime.wav")" "keep" "target unchanged"
assert_eq "$(count_lines "$STATE/mount_calls")" 0 "no mount"
assert_eq "$(grep -c . "$STATE/gadget" || true)" 0 "no gadget calls"
grep -q 'No WAV files under' "$STATE/err" || fail "missing size error"

echo "test: ignores an oversized sibling and keeps a legal clip"
reset_state
CAM_FOR_CONF="$WORKDIR/cam5"
library="$WORKDIR/lib5"
mkdir -p "$CAM_FOR_CONF"
new_library "$library"
printf 'aaa' > "$library/a.wav"
dd if=/dev/zero of="$library/big.wav" bs=1048576 count=1 status=none
run_rotate "$CAM_FOR_CONF" "$library" > "$STATE/out"
assert_eq "$(cat "$CAM_FOR_CONF/LockChime.wav")" "aaa" "picked the legal clip"
assert_eq "$(wc -c < "$CAM_FOR_CONF/LockChime.wav" | tr -d ' ')" 3 "did not copy the oversized clip"

echo "test: restores the gadget after an unrecognized mount error"
reset_state
CAM_FOR_CONF="$WORKDIR/cam6"
library="$WORKDIR/lib6"
mkdir -p "$CAM_FOR_CONF"
new_library "$library"
printf 'aaa' > "$library/a.wav"
echo 99 > "$STATE/fail_mounts"
echo "mount: wrong fs type, bad superblock" > "$STATE/fail_message"
set +e
LOCKCHIME_MAX_ATTEMPTS=10 run_rotate "$CAM_FOR_CONF" "$library" > "$STATE/out" 2> "$STATE/err"
rc=$?
set -e
assert_eq "$rc" 1 "bad superblock fails"
assert_eq "$(count_lines "$STATE/mount_calls")" 5 "stops retrying unknown errors"
assert_eq "$(grep -c enable "$STATE/gadget")" 1 "gadget restored"

echo "test: does not re-enable a gadget that was already released"
reset_state
CAM_FOR_CONF="$WORKDIR/cam7"
library="$WORKDIR/lib7"
mkdir -p "$CAM_FOR_CONF"
printf 'aaa' > "$CAM_FOR_CONF/LockChime.wav"
new_library "$library"
printf 'aaa' > "$library/a.wav"
printf 'bbb' > "$library/b.wav"
echo released > "$STATE/disable_mode"
run_rotate "$CAM_FOR_CONF" "$library" > "$STATE/out"
assert_eq "$(cat "$CAM_FOR_CONF/LockChime.wav")" "bbb" "wrote while gadget was down"
assert_eq "$(grep -c enable "$STATE/gadget" || true)" 0 "did not re-enable"

echo "all rotate-lockchime tests passed"
