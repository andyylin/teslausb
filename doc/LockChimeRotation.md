# LockChime rotation helper

This fork includes `rotate-lockchime.sh`, a standalone helper that safely replaces the Tesla USB drive's `LockChime.wav` with a randomly selected WAV file while avoiding the previously selected chime when alternatives exist.

The helper temporarily releases the USB gadget and mounts the camera filesystem when needed. Its exit trap synchronizes and unmounts the filesystem, then restores the gadget state. It will not unmount a camera filesystem it did not mount, and it retries a busy image instead of exiting on the first failure. Clips of 1 MiB or larger are skipped, because the car ignores those and keeps playing the previously imported sound.

Nothing in this repository calls the helper. A lock or unlock does not run it. Tesla plays a copy of `LockChime.wav` that it imported into the car, including after the USB drive is unplugged, and it does not open the file again on every lock or unlock. Replacing the file is visible to the car after the gadget is reconnected and the car scans the volume. Run the helper while the car is awake, between events. The clip published by one run is the one the next scan can import.

## Configuration

Create `/etc/default/lockchime-rotate` with the source directory and destination file:

```bash
CHIME_DIR=/path/to/chime-library
TARGET_FILE=/mnt/cam/LockChime.wav
```

The source directory must contain at least one `.wav` file. macOS `._*` metadata files are ignored. The helper records the last selection in `.last_lockchime` inside `CHIME_DIR`.

## Run

Install or invoke the script as root because it controls the USB gadget and camera filesystem:

```bash
sudo ./rotate-lockchime.sh
```

If the camera image is already mounted, the helper waits rather than taking that mount. A long archive can still hold it until this run times out. Scheduling stays outside the repository: nothing here runs the helper on lock or unlock.