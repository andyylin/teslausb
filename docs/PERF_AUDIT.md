# TeslaUSB performance audit

Review of this fork (Andy’s teslausb, Raspberry Pi as a Tesla USB drive). The question was time from power-on until the car sees the drive and the archive loop is ready, the cost of the archive/snapshot/web path, and why the LockChime rotator does not change the sound on every lock and unlock.

Checked by reading the boot and archive scripts and by running `tests/rotate-lockchime-test.sh` on this host (shellcheck 0.9.0 on the changed scripts). Nothing here was timed on a Pi. Each finding says which of those two that is.

## Lock chime

The car does not play `LockChime.wav` off the stick at the moment of lock or unlock. It imports the file into the car when it scans a USB volume, then plays that stored copy, including after the stick is gone. Owner reports from 2023 through 2026 (Tesla Lounge threads on a “stuck” USB lock sound, and [marcone/teslausb#803](https://github.com/marcone/teslausb/issues/803)) line up on the same rules:

- The file has to be named `LockChime.wav` at the root of a volume, and it has to be under 1 MiB. A larger file is ignored and the previous import keeps playing.
- A same-name overwrite is often ignored. The new file is picked up when the car scans the volume again: the gadget is unplugged and plugged back in while the new file is already there, the Boombox lock-sound setting is switched off USB and back (about 10 seconds), or the car is rebooted. Which of those works depends on firmware. A scan that runs while the car is asleep does not.
- Lock and unlock only play the copy already imported. They are not a read of the wav.

So a rotation changes the *next* scan, not the event that is already playing. The helper has to finish writing and reconnect the gadget before that next lock or unlock, with the car awake.

**Nothing in this repo runs the helper.** There is no systemd unit, cron, udev rule, BLE watch, or `archiveloop` call. `doc/LockChimeRotation.md` leaves scheduling to the machine. The web UI can copy one chosen file to `LockChime.wav` (`teslausb-www/html/filebrowser.js`, `makeLockChime`) and that path does not bounce the gadget. If no external job calls `rotate-lockchime.sh`, lock and unlock never rotate. That is the “doesn’t fire” case when the script is only sitting on disk.

When something does call the old script, these paths skipped the rotation or hid it from the car:

1. **Busy mount aborted.** After `disable_gadget.sh` the image is often still busy. The script slept 5 seconds, then retried only the two strings `overlapping loop device exists` and `is already mounted`. Any other mount error, including `device is busy`, exited 1. The trap turned the gadget back on with the old file. `rotate-lockchime.sh` previously did this in the mount loop (the fixed retry is lines 66–105).
2. **It stole `/mnt/cam`.** If the mount already existed (archive or the free-space clean), the script did not bounce the gadget, wrote through that mount, and the exit trap unmounted it because any true `mountpoint` set `CAM_WAS_MOUNTED`. The write could miss the image, and the car was not forced to rescan. The fixed script waits and only unmounts a mount it took (lines 68–72 and 38–40).
3. **No lock against a second run or `archiveloop`.** During the 5 second sleep the archive loop can recreate the gadget. `enable_gadget.sh` line 21 then exits 0 with `already prepared` and does not refresh the LUN, so the car keeps the old image.
4. **The picker could reinstall the clip already on the volume.** Content match (`cmp`) and `.last_lockchime` were allowed to disagree, so one run skipped the audible change and the next run did not. Files at or above 1 MiB were copied anyway; the car keeps the old sound and the script still exited 0.
5. **In-place `install`.** A kill mid-copy leaves a short `LockChime.wav`. The car can import that and then refuse to replace it.

A second `LockChime.wav` on the music, lightshow, or boombox image is not touched. If the car scans that volume, it can keep importing the stale file. Removing it automatically would delete a file someone put there on purpose, so this patch does not.

This PR does not start a lock watcher. Polling BLE, or bouncing the gadget on a timer, drops the dashcam drive and can keep the car awake. Call the helper between events instead. The file it publishes is the one the following scan can import. Whether a given firmware imports on that reconnect, or only after the Boombox setting is toggled, still has to be checked in the car.

## Findings

### P0 — Lock chime rotation skipped

- **Status:** script bugs fixed in `rotate-lockchime.sh`. No in-repo trigger added.
- **Where:** `rotate-lockchime.sh` lines 26 (1 MiB cap), 59 (lock), 66–105 (do not steal a mount; retry busy), 119–121 (reject an all-too-large library before touching USB), 142–160 (exclude both the content match and the previous path), 168–172 (write a temp file, then rename).
- **Impact:** Without an external caller, lock and unlock never change the sound. With a caller, a busy image, an archive already holding `/mnt/cam`, a clip ≥ 1 MiB, or a reconnect that races `archiveloop` produced a run that exited without the car getting a new file. Each failed run also left the drive disconnected for the old 5 second sleep plus retries (up to about a minute).
- **Risk of this fix:** Low for the image contents. The helper still disconnects the gadget when it can mount the camera image, which interrupts dashcam and sentry for that run. If `archiveloop` grabs the mount after this script has released the gadget, the script leaves the gadget down instead of stacking a second export under that mount (`rotate-lockchime.sh` lines 43–50). `archiveloop` connects the drive again at the end of archive.
- **Check on a Pi:** Two clips under 1 MiB in `CHIME_DIR`, `/etc/default/lockchime-rotate` pointed at `/mnt/cam/LockChime.wav`. Run the helper, wait until the car is awake, lock, listen. Run it again, lock again. The second lock should differ if the car imported on the reconnect. Repeat with a clip of exactly 1 MiB in the library and confirm stdout did not select it. While `mountpoint /mnt/cam` is true during archive, run the helper and confirm it does not unmount that archive mount (`grep umount` is the wrong check; `findmnt /mnt/cam` should stay up until `archiveloop` drops it). Run two copies at once and confirm the second waits on `/tmp/lockchime-rotate.lock` instead of both writing.
- **Verified:** Static. `tests/rotate-lockchime-test.sh` covers a different clip on each run, a `device is busy` retry, not unmounting a foreign mount, skipping a library that is entirely ≥ 1 MiB without calling mount or the gadget, ignoring an oversized sibling, restoring the gadget after an unknown mount error, and not re-enabling a gadget that was already released. Not run against a car or a real gadget.

### P1 — Filesystem check of every image was serial, and it sat in front of USB

- **Status:** fixed. `run/archiveloop` `fix_errors_in_images` (lines 291–310) starts cam, music, boombox, and lightshow together. `losetup` is serialized with `/tmp/teslausb-losetup.lock` (lines 102–111) because `losetup -f` races when called in parallel. `fsck` itself overlaps.
- **Impact:** Time-to-USB was the sum of the image checks. A large cam image plus music/lightshow/boombox dominated boot. The car sees no mass-storage gadget until this finishes (`connect_usb_drives_to_host` is after it, line 914).
- **Risk:** Low. Repair flags are unchanged (`fsck -p`). Log lines from the jobs can interleave in `/mutable/archiveloop.log`. A snapshot started later uses the same `losetup` binary without this lock; that race already existed between the hourly snapshot and a later archive `fsck`.
- **Check on a Pi:** Boot with cam and at least one other image. In `/mutable/archiveloop.log`, the `Running fsck` lines for those images should overlap, and each should get a `Finished fsck` line before `Connected usb to host`. Compare `systemd-analyze blame` and the `Starting archiveloop at N seconds` line with a boot of the previous build.
- **Verified:** Static only (`bash -n`, shellcheck). Needs a Pi with real images. `fsck` of a Tesla-dirtied FAT image is the long part and was not timed here.

### P1 — Boot clean trimmed the cam image and stat’d every clip before the car could see the drive

- **Status:** fixed for the boot call only. `clean_cam_mount boot` still deletes `FSCK*.REC` and `*~[0-9].MP4` (line 388). It no longer walks every `.mp4` for the short-file delete (lines 390–396) and no longer runs `fstrim` (lines 426–432). The post-archive `freespace` clean still does both.
- **Impact:** `fstrim` on a large cam volume, and a second full walk that stats every clip, ran while the gadget was still down. That delays the moment the car sees the drive. It does not speed up the archive that happens later at home.
- **Risk:** Low. Short clips and free-space trim wait until the next archive clean. A boot that never reaches archive keeps those short files until then. The car can still record.
- **Check on a Pi:** Boot and confirm `Connected usb to host` in the log is no longer preceded by `Trimming free space` / `Trim complete`. After the car has written clips and you archive once, confirm a later `cleaning cam mount` still trims and that a tiny `.mp4` under 100000 bytes is removed.
- **Verified:** Static only.

### P1 — The boot snapshot ran before the gadget was enabled

- **Status:** fixed. Order is now fsck, boot clean, `connect_usb_drives_to_host`, then `make_snapshot.sh nofsck` (`run/archiveloop` lines 907–920).
- **Impact:** The snapshot’s table-of-contents walk (`run/make_snapshot.sh` line 193) held off USB for the length of that walk. The copy is `cp --reflink=always` (line 156) and does not need the gadget disconnected. The hourly path already snapshots while the car is attached (lines 791–793 and the call before `archive_clips`).
- **Risk:** Medium-low for the live image (the reflink does not write the source). The first snapshot can include a torn file if the car starts writing during the copy. The web UI can show that snapshot until the next one. The live dashcam image is the one the car is writing, not the snapshot.
- **Check on a Pi:** From a cold boot in the car, note uptime when the car displays the USB drive, and the log timestamp of `Connected usb to host` versus `took snapshot`. Record a few seconds of footage during that window and confirm the car keeps the clip (live image), even if the first snapshot’s web view looks incomplete.
- **Verified:** Static only.

### P1 — Time sync could block the archive loop with no timeout

- **Status:** fixed. `set_time` in `run/archiveloop` lines 770–774 wraps each `sntp` and `ntpdig` in `timeout 3`. Still up to five attempts, with `sleep 2` between failures.
- **Impact:** This runs before the first archive and before every later archive. A stuck DNS or NTP server used to hold the loop until the tool gave up on its own, which is often much longer than 3 seconds. The car already has the gadget by then; this delays “archive services ready,” not the first USB appearance.
- **Risk:** Low. Worst case is about 25 seconds (5×3s plus 4×2s) and then the loop continues with `fake-hwclock` time. `timeout` is coreutils and is already on Raspberry Pi OS. If the clock is far off, the first archive’s TLS handshake can fail and the next loop retries.
- **Check on a Pi:** `sudo timeout 3 sntp -S time.google.com` should return in about 3 seconds when the network is black-holed. In the log, `Trying to set time...` through `Time adjusted` or `Failed to set time` should stay inside that bound.
- **Verified:** Static only. Not executed against NTP.

### P1 — Web status CGI every 4 seconds

- **Status:** fixed. `teslausb-www/html/index.html` line 1697, `max_status_age` 4000 → 15000. Uptime on the page still advances locally every second (`updateuptimeonly`).
- **Impact:** `teslausb-www/html/cgi-bin/status.sh` forks a shell and runs `find` over snapshots (line 13), `iwconfig`/`ifconfig`/`ethtool`, and three `sudo vcgencmd` calls (lines 49–62). On a Pi Zero that is a steady stream of processes while the car is writing video. 15 seconds cuts that rate by about 4×. Temperature, fan, and “drives active” update more slowly.
- **Risk:** Low. The page does not use the 4 second poll for anything that has to be immediate. The CGI itself is unchanged and still expensive per hit.
- **Check on a Pi:** Open the web UI, watch `ps` or `/proc/stat` while idle on the status header. `status.sh` should appear about every 15 seconds, not every 4. Toggle the drives and confirm the header catches up within 15 seconds.
- **Verified:** Static only. The UI was not opened in a browser; the CGI needs Pi sysfs and `vcgencmd`.

### P2 — Fixed 5 second sleep after every gadget connect

- **Status:** not changed. `run/archiveloop` `connect_usb_drives_to_host` lines 128–132.
- **Impact:** The gadget is already enabled before the sleep, so this does not delay the car seeing the drive. It delays the next step. On a boot where the archive host is reachable, that next step disconnects the drive again for archive, so the 5 seconds is also how long the car gets to enumerate before the drive disappears.
- **Risk of shortening it:** The car can still be mounting when archive calls `disable_gadget.sh`. Left as-is on purpose.
- **Check on a Pi:** In the car (archive unreachable), USB is visible during this sleep. At home, time from `Connected usb to host` to `Disconnecting usb from host` should be about 5 seconds plus the reachability probe below.
- **Verified:** Static only.

### P2 — Archive reachability probe waits 5 seconds when the host is down

- **Status:** not changed. CIFS `run/cifs_archive/archive-is-reachable.sh` line 5 (`nc -z -w 5` to port 445). NFS is the same with port 2049 (`run/nfs_archive/archive-is-reachable.sh` line 4). Rsync and rclone already use a 1 second ping.
- **Impact:** The boot path calls this once after USB is up (`run/archiveloop` line 922). In the car, a configured CIFS/NFS host that does not answer adds up to 5 seconds before the main loop. The connection monitor during an active copy uses the same probe (`run/cifs_archive/archive-clips.sh` lines 4–14, five tries, then `sleep 5` when the host is up).
- **Risk of lowering it:** A slow Wi-Fi hop can look like “archive gone” and kill `rsync` mid-copy. Not changed.
- **Check on a Pi:** Boot on the car’s network with CIFS configured and time `nc -z -w 5 <archive> 445`. It should be the gap in the log between `Connected usb to host` and `Waiting for archive to be reachable`.
- **Verified:** Static only.

### P2 — `g_ether` is what the car sees until `archiveloop` starts

- **Status:** not changed. `setup/pi/setup-teslausb` lines 238–264 load `dwc2,g_ether` from `cmdline.txt`. `run/archiveloop` line 10 unloads `g_ether` before any mass-storage gadget exists.
- **Impact:** From kernel start until `archiveloop` passes fsck and clean, the car sees a USB ethernet gadget, then nothing, then the drive. That gap includes root and mutable `e2fsck` (below) plus the image `fsck`. Presenting mass storage earlier would skip the repair the car’s dirty unplug needs.
- **Risk of changing it:** High. A gadget exported before `fsck -p` hands the car the corrupted filesystem this project exists to repair.
- **Check on a Pi:** `dmesg` around `g_ether` remove versus `g_mass_storage` / configfs UDC `configured`. The car’s USB icon should appear only after the second event.
- **Verified:** Static only.

### P2 — Root and mutable are fsck’d on every boot

- **Status:** not changed. `setup/pi/make-root-fs-readonly.sh` lines 63–70 force `fsck.mode=auto`, remove `fastboot`, and `tune2fs -c 1` on root and mutable.
- **Impact:** Userspace, and therefore `teslausb.service`, waits on those checks. `fastboot` was removed because it skips `fsck`. The service unit (`setup/pi/configure.sh` lines 817–829) already avoids `network-online` and uses `DefaultDependencies=no`, so NetworkManager is not on this critical path. The ext4 checks are.
- **Risk of relaxing `-c 1`:** A power cut can boot an unchecked root. Not changed.
- **Check on a Pi:** `systemd-analyze blame` and `systemd-analyze critical-chain teslausb.service`. Look for `systemd-fsck@` on the root and mutable devices ahead of `teslausb.service`.
- **Verified:** Static only.

### P2 — Twenty second pause after the archive host appears

- **Status:** not changed. `run/archiveloop` line 953, `sleep "${ARCHIVE_DELAY:-20}"`.
- **Impact:** Every time the car comes home, archive waits 20 seconds after the host answers, then takes a snapshot, then copies. This is after USB is already up. It is the main delay before a copy starts, and it is configurable without a code change.
- **Risk of changing the default:** The delay is there so the link is stable before a long `rsync`. Not changed.
- **Check on a Pi:** Set `ARCHIVE_DELAY=5` in the config, re-source, restart `teslausb`, and confirm the log gap shrinks. Default stays 20.
- **Verified:** Static only.

### P2 — Hourly snapshot walks the whole cam tree, after waiting for idle

- **Status:** not changed. `snapshotloop` sleeps `SNAPSHOT_INTERVAL` (default 3480s) then `waitforidle` (`run/archiveloop` lines 787–794). `run/waitforidle` polls `file-storage` write bytes for up to 90 seconds. `run/make_snapshot.sh` lines 185–193 wait for autofs, then `find` every file for a table of contents. An identical snapshot is deleted.
- **Impact:** Once an hour the Pi spends a full tree walk, and up to 90 seconds of 1 second polls, while the car may be writing. The reflink itself is cheap on XFS. The walk is the cost, and it mounts the snapshot through autofs.
- **Risk of skipping the idle wait:** The snapshot can cut through a clip the car is still writing. Not changed.
- **Check on a Pi:** `time find /tmp/snapshots/snap-*/ -type f` on a full card, and log timestamps around `waiting up to 90 seconds for idle interval` / `took snapshot`.
- **Verified:** Static only.

### P3 — Archive candidate filtering forks a shell per batch

- **Status:** not changed. `run/archiveloop` lines 518–522 build a `find -L` command with `xargs echo` and `eval` it to drop clips under 100000 bytes.
- **Impact:** Every archive pays this on the candidate list. It is CPU on the Pi, not a USB delay. The `eval` of a constructed command is also the sort of thing that breaks if a clip name is hostile.
- **Risk of rewriting it:** The filter’s output is the list of files that must not be uploaded. A behavior change re-uploads or drops clips. Not changed in this pass.
- **Check on a Pi:** Time one archive with a few hundred saved clips. The log line `short recording(s) will be skipped` is after this step.
- **Verified:** Static only.

### P3 — Web clip list and status snapshot scan

- **Status:** not changed, aside from the slower poll above. `teslausb-www/html/cgi-bin/videolist.sh` line 8 finds every symlink under `/mutable/TeslaCam` on each page load. `status.sh` line 13 finds every `snap.bin` on each status refresh.
- **Impact:** Noticeable on a Pi Zero with many snapshots and days of links. `videolist.sh` is once per page load, not on a timer.
- **Risk:** Caching the list can hide a clip that just closed. Not changed.
- **Check on a Pi:** `time find /mutable/TeslaCam -type l | wc -l` and the same for `snap.bin` under `/backingfiles/snapshots`.
- **Verified:** Static only.

### P3 — Other loops that are cheap or already bounded

- Free-space manager sleeps 30 seconds and runs `stat` on the filesystem (`run/archiveloop` lines 797–813). The stat is one syscall. The expensive part is deleting snapshots when space is low (`run/manage_free_space.sh`).
- `log()` in `archiveloop` stats the log on every line and rewrites it past 1 MB. Fine at current volume.
- `wifichecker` blocks in `dmesg -w` (line 839 area). One process, no poll interval.
- Temperature monitor, when enabled, wakes every 60 seconds (`run/temperature_monitor`).
- Music copy uses the same connection-monitor pattern as clip archive.

Not changed. Static review only.

## What this PR changes

| Area | Change | On a Pi you should see |
| --- | --- | --- |
| Lock chime | Retry busy mounts, do not steal `/mnt/cam`, skip clips ≥ 1 MiB, rename into place, one lock | Helper stdout shows a different file each run; car changes on the *following* lock/unlock after a reconnect |
| Boot fsck | Parallel `fsck`, serial `losetup` | Overlapping `Running fsck` lines, then one `Connected usb` |
| Boot clean | No short-clip walk and no `fstrim` on the boot clean | No `Trim complete` before the first `Connected usb` |
| Boot snapshot | After the gadget is up | Car sees USB before `took snapshot` |
| Time sync | 3 second cap per `sntp`/`ntpdig` | `set_time` cannot hang for minutes |
| Web UI | Status refresh 15s | Fewer `status.sh` processes; uptime text still ticks |

Shellcheck 0.9.0 was run on `rotate-lockchime.sh`, `tests/rotate-lockchime-test.sh`, `run/archiveloop`, and `check.sh` with `--exclude=SC1091`. Clean. `bash -n` on the first three was clean. The lock-chime tests passed on this host. Boot timing, gadget behavior, and whether the car imports on reconnect were not run here.
