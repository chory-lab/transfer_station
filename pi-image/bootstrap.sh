#!/usr/bin/env bash
# Download the CI-audited sdm image and write it to removable media.
set -euo pipefail

IMAGE_URL="https://github.com/chory-lab/transfer_station/releases/download/pi-image/transfer-station.img.xz"
SHA_URL="${IMAGE_URL}.sha256"
CACHE="${TS_IMAGE_CACHE:-/var/tmp/transfer-station-sdm}"
IMAGE="$CACHE/transfer-station.img.xz"
OS="$(uname -s)"

if [ -r /dev/tty ]; then exec 3</dev/tty; else exec 3<&0; fi
ask() { printf '%s' "$1" >&2; read -r "$2" <&3; }

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
for tool in curl awk; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
case "$OS" in
    Linux)
        for tool in xz sha256sum lsblk dd; do
            command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
        done
        sha256_file() { sha256sum "$1" | awk '{print $1}'; }
        ;;
    Darwin)
        for tool in shasum diskutil; do
            command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
        done
        IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/rpi-imager"
        [ -x "$IMAGER" ] || IMAGER="/Applications/Raspberry Pi Imager.app/Contents/MacOS/Raspberry Pi Imager"
        [ -x "$IMAGER" ] || {
            echo "Install Raspberry Pi Imager from https://www.raspberrypi.com/software/" >&2
            exit 1
        }
        sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
        ;;
    *) echo "Unsupported operating system: $OS" >&2; exit 1 ;;
esac

echo
echo "=== Transfer Station ready-image flasher ==="
echo
echo "Removable drives:"
DISKS=()
if [ "$OS" = Linux ]; then
    while IFS= read -r dev; do DISKS[${#DISKS[@]}]="$dev"; done \
        < <(lsblk -dpno NAME,RM | awk '$2==1 {print $1}')
else
    while IFS= read -r dev; do DISKS[${#DISKS[@]}]="$dev"; done \
        < <(diskutil list external physical | awk '/^\/dev\/disk[0-9]+/ {print $1}')
fi
[ "${#DISKS[@]}" -gt 0 ] || { echo "No removable drive found." >&2; exit 1; }
for i in "${!DISKS[@]}"; do
    DEV="${DISKS[$i]}"
    if [ "$OS" = Linux ]; then
        DESC="$(lsblk -dno SIZE,MODEL "$DEV")"
    else
        DESC="$(diskutil info "$DEV" | awk -F: '/Media Name|Disk Size/ {gsub(/^[ \t]+/,"",$2); printf "%s ",$2}')"
    fi
    echo "  [$((i+1))] $DEV  $DESC"
done
ask "Which one? [1-${#DISKS[@]}] " CHOICE
[[ "$CHOICE" =~ ^[0-9]+$ ]] || { echo "Invalid selection." >&2; exit 1; }
[ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#DISKS[@]}" ] ||
    { echo "Invalid selection." >&2; exit 1; }
DEV="${DISKS[$((CHOICE-1))]}"
[ -b "$DEV" ] || { echo "Not a block device: $DEV" >&2; exit 1; }
if [ "$OS" = Linux ]; then
    [ "$(lsblk -dno RM "$DEV" | tr -d ' ')" = 1 ] ||
        { echo "$DEV is not removable. Refusing." >&2; exit 1; }
else
    INFO="$(diskutil info "$DEV")"
    echo "$INFO" | grep -Eq 'Device Location:[[:space:]]+External' ||
        { echo "$DEV is not external. Refusing." >&2; exit 1; }
    echo "$INFO" | grep -Eq 'Whole:[[:space:]]+Yes' ||
        { echo "$DEV is not a whole disk. Refusing." >&2; exit 1; }
fi

echo
echo "  !! $DEV will be COMPLETELY ERASED"
if [ "$OS" = Linux ]; then lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$DEV"
else diskutil info "$DEV" | grep -E 'Device Node|Media Name|Disk Size|Device Location'; fi
ask "  Type ERASE to continue: " CONFIRM
[ "$CONFIRM" = ERASE ] || { echo "Aborted."; exit 1; }

mkdir -p "$CACHE"
echo ">> fetching the published checksum"
curl -fsSL --retry 3 -o "$CACHE/transfer-station.img.xz.sha256" "$SHA_URL"
EXPECTED="$(awk '{print $1}' "$CACHE/transfer-station.img.xz.sha256")"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || { echo "Published checksum is invalid." >&2; exit 1; }

if [ ! -f "$IMAGE" ] || [ "$(sha256_file "$IMAGE")" != "$EXPECTED" ]; then
    echo ">> downloading the ready-to-flash image (about 1 GB)"
    curl -fL --retry 3 -o "$IMAGE.part" "$IMAGE_URL"
    mv "$IMAGE.part" "$IMAGE"
else
    echo ">> using the verified cached image"
fi
[ "$(sha256_file "$IMAGE")" = "$EXPECTED" ] || {
    echo "Downloaded image checksum does not match the published checksum." >&2; exit 1;
}

if [ "$OS" = Linux ]; then
    xz -t "$IMAGE"
    while read -r part; do
        [ "$part" = "$DEV" ] || umount "$part" 2>/dev/null || true
    done < <(lsblk -lnpo NAME "$DEV")
    echo ">> writing the audited image"
    xz -dc "$IMAGE" | dd of="$DEV" bs=4M conv=fsync status=progress
    sync
else
    echo ">> writing and verifying the audited image"
    diskutil unmountDisk "$DEV"
    "$IMAGER" --cli "$IMAGE" "$DEV"
fi

echo
echo "Done. Put the media in the Pi and switch it on."
echo "  UI:  http://192.168.10.1:5000"
echo "  SSH: ssh chorylab@192.168.10.1"
echo
echo "This branch image currently uses the build credential (default: changeme)."
