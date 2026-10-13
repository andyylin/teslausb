# LockChime rotation

`rotate-lockchime.sh` replaces the Tesla USB drive's `LockChime.wav` with a different WAV from a library. It avoids the clip already on the volume, and the previously selected path, when another choice exists.

The car imports `LockChime.wav` when it scans the USB volume, then plays that stored copy on lock and unlock, including after the drive is unplugged. Lock and unlock do not open the file again. A same-name overwrite waits on the volume until the car scans again. This helper leaves the USB gadget connected, so dashcam and Sentry keep recording. The car picks up the new chime at its next scan (a reconnect the car starts itself, the Boombox lock-sound setting switched off USB and back, or a reboot). Which of those a given firmware accepts has to be checked in the car.

## When it runs

`setup/pi/configure.sh` installs the script and `run/lockchime_inplace.py` into `/root/bin` and enables `lockchime-rotate.timer`:

- At startup, `archiveloop` calls `rotate-lockchime.sh --use-mount` while `/mnt/cam` is already mounted and the gadget is still down.
- Every 15 minutes after that (`OnBootSec=15min`, `OnUnitActiveSec=15min`). The first timer fire does not stack on the startup swap.

The timer service starts only when `/etc/default/lockchime-rotate` exists. Config keys are unchanged.

## What a cycle does

The script swaps the file and skips the cycle, exit 0, when:

- `/tmp/lockchime-rotate.lock` is already held
- an archive or music sync is running (`/mnt/archive`, `/mnt/musicarchive`, `rsync`, `rclone`, `archive-clips.sh`, or `copy-music.sh`)
- the camera image is busy (`/mnt/cam` is already mounted on the periodic path, or a loop device is attached to the live image)

While the gadget is up, the writer overwrites bytes already in `LockChime.wav`'s cluster chain and patches that directory entry. It does not rewrite the FAT, so it does not allocate clusters while the car is recording. A clip larger than those clusters, a missing file, or an exFAT image waits for the next startup, which can grow the file through the mounted filesystem. The startup and gadget-down paths write a temp file, pad it out to the largest library clip under 1 MiB, and `mv` it into place. Clips of 1 MiB or larger are ignored, because the car keeps the previously imported sound.

The script does not call `disable_gadget.sh` or `enable_gadget.sh`.

## Configuration

Create `/etc/default/lockchime-rotate`:

```bash
CHIME_DIR=/path/to/chime-library
TARGET_FILE=/mnt/cam/LockChime.wav
```

The source directory must contain at least one `.wav` file under 1 MiB. macOS `._*` metadata files are ignored. The helper records the last selection in `.last_lockchime` inside `CHIME_DIR`.

A manual run uses the same rules:

```bash
sudo /root/bin/rotate-lockchime.sh
```
