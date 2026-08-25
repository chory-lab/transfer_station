#!/usr/bin/env bash
# Download the CI-audited sdm image and write it to removable media.
set -euo pipefail

IMAGE_URL="https://github.com/chory-lab/transfer_station/releases/download/pi-image/transfer-station.img.xz"
SHA_URL="${IMAGE_URL}.sha256"
CACHE="${TS_IMAGE_CACHE:-${SUDO_USER:+/home/$SUDO_USER}/.cache/transfer-station-sdm}"
CACHE="${CACHE:-/tmp/transfer-station-sdm}"
IMAGE="$CACHE/transfer-station.img.xz"

if [ -r /dev/tty ]; then exec 3</dev/tty; else exec 3<&0; fi
ask() { printf '%s' "$1" >&2; read -r "$2" <&3; }

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
for tool in curl xz sha256sum lsblk dd awk; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

echo
echo "=== Transfer Station ready-image flasher ==="
echo
echo "Removable drives:"
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,RM,MODEL | awk '$3==1 {print}')
[ "${#DISKS[@]}" -gt 0 ] || { echo "No removable drive found." >&2; exit 1; }
for i in "${!DISKS[@]}"; do echo "  [$((i+1))] ${DISKS[$i]}"; done
ask "Which one? [1-${#DISKS[@]}] " CHOICE
[[ "$CHOICE" =~ ^[0-9]+$ ]] || { echo "Invalid selection." >&2; exit 1; }
[ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#DISKS[@]}" ] ||
    { echo "Invalid selection." >&2; exit 1; }
DEV="$(awk '{print $1}' <<<"${DISKS[$((CHOICE-1))]}")"
[ -b "$DEV" ] || { echo "Not a block device: $DEV" >&2; exit 1; }
[ "$(lsblk -dno RM "$DEV" | tr -d ' ')" = 1 ] ||
    { echo "$DEV is not removable. Refusing." >&2; exit 1; }

echo
echo "  !! $DEV will be COMPLETELY ERASED"
lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$DEV"
ask "  Type ERASE to continue: " CONFIRM
[ "$CONFIRM" = ERASE ] || { echo "Aborted."; exit 1; }

mkdir -p "$CACHE"
echo ">> fetching the published checksum"
curl -fsSL --retry 3 -o "$CACHE/transfer-station.img.xz.sha256" "$SHA_URL"
EXPECTED="$(awk '{print $1}' "$CACHE/transfer-station.img.xz.sha256")"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || { echo "Published checksum is invalid." >&2; exit 1; }

if [ ! -f "$IMAGE" ] || [ "$(sha256sum "$IMAGE" | awk '{print $1}')" != "$EXPECTED" ]; then
    echo ">> downloading the ready-to-flash image (about 1 GB)"
    curl -fL --retry 3 -o "$IMAGE.part" "$IMAGE_URL"
    mv "$IMAGE.part" "$IMAGE"
else
    echo ">> using the verified cached image"
fi
echo "$EXPECTED  $IMAGE" | sha256sum -c -
xz -t "$IMAGE"

while read -r part; do
    [ "$part" = "$DEV" ] || umount "$part" 2>/dev/null || true
done < <(lsblk -lnpo NAME "$DEV")

echo ">> writing the audited image"
xz -dc "$IMAGE" | dd of="$DEV" bs=4M conv=fsync status=progress
sync

echo
echo "Done. Put the media in the Pi and switch it on."
echo "  UI:  http://192.168.10.1:5000"
echo "  SSH: ssh chorylab@192.168.10.1"
echo
echo "This branch image currently uses the build credential (default: changeme)."
