#!/usr/bin/env bash
# End-to-end test of the FULL flash path: synthesises a Raspberry Pi OS-shaped
# .img (real MBR + real FAT32 partition), writes it to a loopback "SD card"
# with flash.sh --image/--device, then mounts the result and inspects it.
#
# This is the only test that exercises dd, partition discovery and mounting.
# Requires root + loop device support (Linux only).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "SKIP: needs root for losetup/mount" >&2
    exit 0
fi
if ! command -v losetup >/dev/null 2>&1 || ! command -v mkfs.vfat >/dev/null 2>&1; then
    echo "SKIP: losetup/mkfs.vfat unavailable" >&2
    exit 0
fi

WORK="$(mktemp -d)"
SRC_LOOP=""; DST_LOOP=""; MNT="$WORK/mnt"

cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && umount "$MNT"
    [ -n "$DST_LOOP" ] && losetup -d "$DST_LOOP" 2>/dev/null
    [ -n "$SRC_LOOP" ] && losetup -d "$SRC_LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$MNT"

# --- synthesise a Raspberry Pi OS-shaped source image ---------------------
echo "building a fake raspios image..."
truncate -s 96M "$WORK/raspios.img"
# One bootable FAT32 (type 0c) partition, mirroring the real layout's first
# partition. A root partition is not needed: nothing here touches ext4.
sfdisk "$WORK/raspios.img" >/dev/null <<'SFDISK'
label: dos
unit: sectors
start=8192, type=c, bootable
SFDISK

SRC_LOOP="$(losetup --show -fP "$WORK/raspios.img")"
mkfs.vfat -F 32 -n bootfs "${SRC_LOOP}p1" >/dev/null
mount "${SRC_LOOP}p1" "$MNT"
bash "$HERE/make-fake-boot.sh" "$MNT" bookworm
umount "$MNT"
losetup -d "$SRC_LOOP"; SRC_LOOP=""

# --- the "SD card" --------------------------------------------------------
truncate -s 128M "$WORK/sdcard.img"
DST_LOOP="$(losetup --show -fP "$WORK/sdcard.img")"

echo "running flash.sh --image ... --device $DST_LOOP"
# flash.sh demands the device path typed back as confirmation.
if ! ( cd "$PROV/.." && echo "$DST_LOOP" | bash "$PROV/flash.sh" \
        --image "$WORK/raspios.img" --device "$DST_LOOP" ) >"$WORK/flash.log" 2>&1; then
    echo "--- flash.log ---"; cat "$WORK/flash.log"
    it "flash.sh --image/--device succeeds"; fail "flash.sh exited non-zero"
    summary; exit 1
fi

it "flash.sh --image/--device succeeds"; pass

it "reports the card as ready"
assert_contains "$(cat "$WORK/flash.log")" "Card ready"

it "unmounts the boot partition when it mounted it itself"
if mount | grep -q "$DST_LOOP"; then fail "left $DST_LOOP mounted"; else pass; fi

# --- inspect what actually landed on the card -----------------------------
partprobe "$DST_LOOP" 2>/dev/null || true
sleep 1
mount "${DST_LOOP}p1" "$MNT"

it "image was written: FAT partition is readable"
assert_file "$MNT/cmdline.txt"

it "config.txt survived the write"
assert_file "$MNT/config.txt"

it "first-boot hook is armed on the card"
assert_contains "$(cat "$MNT/cmdline.txt")" "systemd.run=/boot/firmware/transfer-station/firstrun.sh"

it "cmdline.txt on the card is a single line"
assert_eq "$(wc -l < "$MNT/cmdline.txt" | tr -d ' ')" "1"

it "payload landed on the card"
assert_file "$MNT/transfer-station/firstrun.sh"

it "repo tarball landed on the card"
assert_file "$MNT/transfer-station/repo.tar.gz"

it "repo tarball on the card is a valid gzip archive"
if tar -tzf "$MNT/transfer-station/repo.tar.gz" >/dev/null 2>&1; then pass
else fail "tarball is corrupt after the FAT round-trip"; fi

it "ssh flag file landed on the card"
assert_file "$MNT/ssh"

it "userconf.txt recovery login landed on the card"
assert_file "$MNT/userconf.txt"

it "payload fits comfortably on the boot partition"
USED_KB="$(du -sk "$MNT/transfer-station" | cut -f1)"
echo "  payload size: ${USED_KB} KiB"
if [ "$USED_KB" -lt 51200 ]; then pass; else fail "payload is ${USED_KB} KiB, too big for a 512M boot partition"; fi

summary
