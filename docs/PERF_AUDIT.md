# TeslaUSB performance audit

Review of this fork (Andy’s teslausb, Raspberry Pi as a Tesla USB drive). The question was time from power-on until the car sees the drive and the archive loop is ready, the cost of the archive/snapshot/web path, and why the LockChime rotator does not change the sound on every lock and unlock.

Checked by reading the boot and archive scripts and by running `tests/rotate-lockchime-test.sh` and `tests/lockchime_inplace_test.py` on this host (shellcheck 0.9.0 on the changed scripts). Nothing here was timed on a Pi. Each finding says which of those two that is.

## Lock chime

The car does not play `LockChime.wav` off the stick at the moment of lock or unlock. It imports the file into the car when it scans a USB volume, then plays that stored copy, including after the stick is gone. Owner reports from 2023 through 2026 (Tesla Lounge threads on a “stuck” USB lock sound, and [marcone/teslausb#803](https://github.com/marcone/teslausb/issues/803)) line up on the same rules:

- The file has to be named `LockChime.wav` at the root of a volume, and it has to be under 1 MiB. A larger file is ignored and the previous import keeps playing.
- A same-name overwrite waits on the volume until the car scans again. That scan is one the car starts: it enumerates the drive on its own, the Boombox lock-sound setting is switched off USB and back (about 10 seconds), or the car is rebooted. Which of those works depends on firmware. A scan that runs while the car is asleep does not.
- Lock and unlock only play the copy already imported. They are not a read of the wav.

A rotation publishes the file the car will import on its next scan. The lock that already happened keeps playing the copy the car stored. This fork leaves the USB gadget connected across every rotation, so dashcam and Sentry keep the drive. The rotator never unbinds, rebinds, or reconnects USB to force a rescan. The car picks up the new chime at its next scan: a reconnect the car starts itself, the Boombox lock-sound setting switched off USB and back, or a reboot. Which of those the firmware accepts still has to be checked in the car. A scan while the car is asleep does not import the file.

The old helper never ran from this repo. When something outside did call it, a busy mount, a stolen `/mnt/cam`, a missing lock, a same-clip reinstall, a file of 1 MiB or more, or a short write from `install` finished without a file the car could import. The web UI can still copy one chosen file (`teslausb-www/html/filebrowser.js`, `makeLockChime`). The scheduled path is separate:

- **Startup.** `clean_cam_mount boot` calls `rotate-lockchime.sh --use-mount` (`run/archiveloop` lines 434–440) while `/mnt/cam` is already mounted and the gadget is still down. The write is a temp file plus `mv` on that filesystem. The published file is padded out to the largest library clip under 1 MiB, so a later swap fits in clusters that are already allocated.
- **Every 15 minutes.** `lockchime-rotate.timer` (`setup/pi/configure.sh` lines 836–864) uses `OnBootSec=15min` and `OnUnitActiveSec=15min`. The first timer fire is 15 minutes after boot, so it does not stack on the startup swap. The service is a oneshot with `ConditionPathExists=/etc/default/lockchime-rotate` and `After=teslausb.service`. systemd is the match for this image: `configure.sh` already installs units, and apt timers are disabled. Config keys stay `CHIME_DIR` and `TARGET_FILE`.
- **While the car has the drive.** If the gadget UDC is set, `run/lockchime_inplace.py` overwrites bytes already in `LockChime.wav`'s cluster chain and patches that one 32-byte directory entry (size and timestamp). The FAT is left as it is, so the writer does not allocate or free clusters while the car is recording. A new clip larger than those clusters, a missing file, or an exFAT image skips that cycle. The next boot can grow the file through the mount path, while the gadget is down.
- **Skip the cycle, exit 0,** when `/etc/default/lockchime-rotate` is missing, `/tmp/lockchime-rotate.lock` is held, the library has no wav under 1 MiB, an archive or music sync is running, or the camera image is busy. Busy means `/mnt/cam` is already mounted on the periodic path, or `losetup` shows a loop on the live image. The mount the Pi already holds stays mounted. `disable_gadget.sh` and `enable_gadget.sh` are not on this path.
- **Gadget down and the image free.** The periodic run mounts, does the same temp-and-rename swap, unmounts, and leaves USB down for `archiveloop` to connect again.

Archive or sync means `/mnt/archive` or `/mnt/musicarchive` is mounted, or `rsync`, `rclone`, `archive-clips.sh`, or `copy-music.sh` is running (`rotate-lockchime.sh` lines 53–69).

A second `LockChime.wav` on the music, lightshow, or boombox image is left in place. If the car scans that volume, it can keep importing the stale file. Removing it automatically would delete a file someone put there on purpose.

## Findings

### P0 — Lock chime rotation skipped

- **Status:** fixed. Startup rotation in `archiveloop`, plus a 15-minute systemd timer. The gadget stays connected so dashcam and Sentry keep recording.
- **Where:** `rotate-lockchime.sh` lines 11–14 (missing config exits 0), 24 and 94–97 (1 MiB cap), 48–51 (lock), 53–69 and 99–101 (archive/sync), 152–165 (temp file, pad, rename), 185–211 (in-place writer), 213–232 (a mounted or looped image skips; a live gadget uses the in-place writer; a down gadget mounts and unmounts). `run/lockchime_inplace.py` `overwrite` (from line 267) writes only the existing chain and one directory entry. `run/archiveloop` lines 434–440. `setup/pi/configure.sh` lines 374–375 (install) and 836–864 (service and timer).
- **Impact:** With `/etc/default/lockchime-rotate` in place, the file on the camera volume changes at boot and about every 15 minutes, except a cycle where the lock is held, an archive or sync is running, or the image is busy. The car keeps recording through those runs. It plays the new chime after its next USB scan.
- **Risk:** The script has no path that unbinds the gadget. The in-place write shares the backing file's page cache with `g_mass_storage` and only touches clusters the directory entry already assigns to `LockChime.wav`, plus that one directory entry. A kill during the data write can leave a mixed cluster under the old directory size until the next successful run. The mount path uses `mv`, which replaces the name in one step. An exFAT camera image, or a new clip larger than the allocated chain, waits for the startup mount path. Whether a given firmware imports the new file on its next scan, or only after the Boombox setting is toggled or the car reboots, still has to be checked in the car.
- **Check on a Pi:** Two clips under 1 MiB in `CHIME_DIR`, `/etc/default/lockchime-rotate` pointed at `/mnt/cam/LockChime.wav`. Boot and confirm `/mutable/archiveloop.log` does not say `lockchime startup rotation skipped`, and `systemctl is-enabled lockchime-rotate.timer` is `enabled`. While the car is recording, `cat /sys/kernel/config/usb_gadget/teslausb/UDC` stays non-empty across a timer fire (`journalctl -u lockchime-rotate.service`), and the dashcam clip continues. After the car next scans the volume, the lock sound should match the file the last successful run printed as `Selected chime`. During an archive (`mountpoint /mnt/cam` or `rsync` running), the timer log should say it skipped and `findmnt /mnt/cam` should stay up until `archiveloop` drops it. A second copy started while the first holds `/tmp/lockchime-rotate.lock` should print `lock held`.
- **Verified:** Static. `tests/rotate-lockchime-test.sh` covers the startup swap with the mount left up and the gadget untouched, a different clip on the next startup run, an archive skip, a mounted-image skip, an in-place write while the gadget is up with no mount and no gadget call, a lock skip, a mount/unmount while the gadget is down without enabling USB, padding to the larger clip, a loop-device skip, and an all-too-large library that does not touch the drive. `tests/lockchime_inplace_test.py` covers an in-place overwrite that keeps the FAT chain, a clip larger than the allocated clusters, and a missing filename. Not run against a car or a real gadget.

### P1 — Filesystem check of every image was serial, and it sat in front of USB

- **Status:** fixed. `run/archiveloop` `fix_errors_in_images` (lines 291–310) starts cam, music, boombox, and lightshow together. `losetup` is serialized with `/tmp/teslausb-losetup.lock` (lines 102–111) because `losetup -f` races when called in parallel. `fsck` itself overlaps.
- **Impact:** Time-to-USB was the sum of the image checks. A large cam image plus music/lightshow/boombox dominated boot. The car sees no mass-storage gadget until this finishes (`connect_usb_drives_to_host` is after it, line 922).
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

- **Status:** fixed. Order is now fsck, boot clean, `connect_usb_drives_to_host`, then `make_snapshot.sh nofsck` (`run/archiveloop` lines 915–927).
- **Impact:** The snapshot’s table-of-contents walk (`run/make_snapshot.sh` line 193) held off USB for the length of that walk. The copy is `cp --reflink=always` (line 156) and does not need the gadget disconnected. The hourly path already snapshots while the car is attached (lines 799–801 and the call before `archive_clips`).
- **Risk:** Medium-low for the live image (the reflink does not write the source). The first snapshot can include a torn file if the car starts writing during the copy. The web UI can show that snapshot until the next one. The live dashcam image is the one the car is writing, not the snapshot.
- **Check on a Pi:** From a cold boot in the car, note uptime when the car displays the USB drive, and the log timestamp of `Connected usb to host` versus `took snapshot`. Record a few seconds of footage during that window and confirm the car keeps the clip (live image), even if the first snapshot’s web view looks incomplete.
- **Verified:** Static only.

### P1 — Time sync could block the archive loop with no timeout

- **Status:** fixed. `set_time` in `run/archiveloop` lines 778–782 wraps each `sntp` and `ntpdig` in `timeout 3`. Still up to five attempts, with `sleep 2` between failures.
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
- **Impact:** The boot path calls this once after USB is up (`run/archiveloop` line 930). In the car, a configured CIFS/NFS host that does not answer adds up to 5 seconds before the main loop. The connection monitor during an active copy uses the same probe (`run/cifs_archive/archive-clips.sh` lines 4–14, five tries, then `sleep 5` when the host is up).
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

- **Status:** not changed. `run/archiveloop` line 961, `sleep "${ARCHIVE_DELAY:-20}"`.
- **Impact:** Every time the car comes home, archive waits 20 seconds after the host answers, then takes a snapshot, then copies. This is after USB is already up. It is the main delay before a copy starts, and it is configurable without a code change.
- **Risk of changing the default:** The delay is there so the link is stable before a long `rsync`. Not changed.
- **Check on a Pi:** Set `ARCHIVE_DELAY=5` in the config, re-source, restart `teslausb`, and confirm the log gap shrinks. Default stays 20.
- **Verified:** Static only.

### P2 — Hourly snapshot walks the whole cam tree, after waiting for idle

- **Status:** not changed. `snapshotloop` sleeps `SNAPSHOT_INTERVAL` (default 3480s) then `waitforidle` (`run/archiveloop` lines 795–802). `run/waitforidle` polls `file-storage` write bytes for up to 90 seconds. `run/make_snapshot.sh` lines 185–193 wait for autofs, then `find` every file for a table of contents. An identical snapshot is deleted.
- **Impact:** Once an hour the Pi spends a full tree walk, and up to 90 seconds of 1 second polls, while the car may be writing. The reflink itself is cheap on XFS. The walk is the cost, and it mounts the snapshot through autofs.
- **Risk of skipping the idle wait:** The snapshot can cut through a clip the car is still writing. Not changed.
- **Check on a Pi:** `time find /tmp/snapshots/snap-*/ -type f` on a full card, and log timestamps around `waiting up to 90 seconds for idle interval` / `took snapshot`.
- **Verified:** Static only.

### P3 — Archive candidate filtering forks a shell per batch

- **Status:** not changed. `run/archiveloop` lines 526–531 build a `find -L` command with `xargs echo` and `eval` it to drop clips under 100000 bytes.
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

- Free-space manager sleeps 30 seconds and runs `stat` on the filesystem (`run/archiveloop` lines 805–821). The stat is one syscall. The expensive part is deleting snapshots when space is low (`run/manage_free_space.sh`).
- `log()` in `archiveloop` stats the log on every line and rewrites it past 1 MB. Fine at current volume.
- `wifichecker` blocks in `dmesg -w` (line 845 area). One process, no poll interval.
- Temperature monitor, when enabled, wakes every 60 seconds (`run/temperature_monitor`).
- Music copy uses the same connection-monitor pattern as clip archive.

Not changed. Static review only.

## What this PR changes

| Area | Change | On a Pi you should see |
| --- | --- | --- |
| Lock chime | Startup swap in `archiveloop`, then every 15 minutes from a systemd timer. Swap the file only; skip when the drive is busy, an archive or sync is running, or the lock is held. The gadget stays connected | The car imports the new file on its next USB scan. Dashcam keeps recording across a timer fire |
| Boot fsck | Parallel `fsck`, serial `losetup` | Overlapping `Running fsck` lines, then one `Connected usb` |
| Boot clean | No short-clip walk and no `fstrim` on the boot clean | No `Trim complete` before the first `Connected usb` |
| Boot snapshot | After the gadget is up | Car sees USB before `took snapshot` |
| Time sync | 3 second cap per `sntp`/`ntpdig` | `set_time` cannot hang for minutes |
| Web UI | Status refresh 15s | Fewer `status.sh` processes; uptime text still ticks |

Shellcheck 0.9.0 was run on `rotate-lockchime.sh`, `tests/rotate-lockchime-test.sh`, and `run/archiveloop` with `--exclude=SC1091`. Clean. `bash -n` on those and on `setup/pi/configure.sh` was clean. `tests/rotate-lockchime-test.sh` and `tests/lockchime_inplace_test.py` passed on this host. Boot timing, live gadget behavior, and whether the car imports the new chime on its next scan were not run here.
