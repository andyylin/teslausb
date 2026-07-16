# LockChime rotation helper

This fork includes `rotate-lockchime.sh`, a standalone helper that safely replaces the Tesla USB drive's `LockChime.wav` with a randomly selected WAV file while avoiding the previously selected chime when alternatives exist.

The helper temporarily releases the USB gadget and mounts the camera filesystem when needed. Its exit trap synchronizes and unmounts the filesystem, then restores the gadget state.

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

Do not run it while another process is actively controlling or writing the camera filesystem. Scheduling policy is intentionally left to the installation rather than baked into the repository.