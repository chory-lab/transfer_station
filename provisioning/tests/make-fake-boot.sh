#!/usr/bin/env bash
# Create a directory that looks like a Raspberry Pi OS FAT boot partition.
#   make-fake-boot.sh <dir> [bookworm|bullseye]
set -euo pipefail

DIR="$1"
RELEASE="${2:-bookworm}"
mkdir -p "$DIR"

# A realistic cmdline.txt: single line, no trailing newline handling assumed.
printf '%s\n' \
  "console=serial0,115200 console=tty1 root=PARTUUID=1a2b3c4d-02 rootfstype=ext4 fsck.repair=yes rootwait quiet" \
  > "$DIR/cmdline.txt"

printf '%s\n' "dtparam=audio=on" "camera_auto_detect=1" > "$DIR/config.txt"

# The real thing names no codename -- only a build date and the pi-gen commit.
# Keep the fixture faithful to that, or the release detection is never tested.
case "$RELEASE" in
    bookworm)
        printf '%s\n' "Raspberry Pi reference 2024-11-19" \
          "Generated using pi-gen, https://github.com/RPi-Distro/pi-gen, deadbee, stage2" \
          > "$DIR/issue.txt" ;;
    bullseye)
        printf '%s\n' "Raspberry Pi reference 2023-05-03" \
          "Generated using pi-gen, https://github.com/RPi-Distro/pi-gen, deadbee, stage2" \
          > "$DIR/issue.txt" ;;
    none)
        rm -f "$DIR/issue.txt" ;;
    *) echo "unknown release: $RELEASE" >&2; exit 2 ;;
esac

# Raspberry Pi Imager leaves this behind; our flasher must remove it.
echo 'pi:$6$fakehash' > "$DIR/userconf.txt"
