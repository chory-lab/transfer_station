#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build a provisioned Transfer Station SD card (Linux / macOS).
#
#   ./flash.sh --image 2024-11-19-raspios-bookworm-arm64-lite.img.xz --device /dev/sdX
#   ./flash.sh --boot /media/$USER/bootfs        # inject onto an already-flashed card
#
# Writing the image is optional: if you already flashed the card with
# Raspberry Pi Imager, just point --boot at its FAT partition.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

IMAGE=""; DEVICE=""; BOOT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image)  IMAGE="$2"; shift 2 ;;
        --device) DEVICE="$2"; shift 2 ;;
        --boot)   BOOT="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# shellcheck disable=SC1091
. "$HERE/config.env"

# bootstrap writes the password base64-encoded so it is safe for both bash and
# PowerShell to carry; decode it back if present.
if [ -n "${PI_PASSWORD_B64:-}" ]; then
    PI_PASSWORD="$(printf '%s' "$PI_PASSWORD_B64" | base64 -d)"
fi

# --- write the image ------------------------------------------------------
if [ -n "$DEVICE" ]; then
    [ -n "$IMAGE" ] || { echo "--device requires --image" >&2; exit 2; }
    [ -b "$DEVICE" ] || { echo "$DEVICE is not a block device" >&2; exit 2; }
    echo
    echo "  !!  About to ERASE $DEVICE and write $IMAGE"
    lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$DEVICE" 2>/dev/null || diskutil info "$DEVICE" 2>/dev/null || true
    read -r -p "  Type the device path again to confirm: " CONFIRM
    [ "$CONFIRM" = "$DEVICE" ] || { echo "aborted"; exit 1; }

    # Unmount any auto-mounted partitions before writing.
    if command -v udisksctl >/dev/null 2>&1; then
        for p in "${DEVICE}"?*; do udisksctl unmount -b "$p" >/dev/null 2>&1 || true; done
    elif command -v diskutil >/dev/null 2>&1; then
        diskutil unmountDisk "$DEVICE" || true
    fi

    case "$IMAGE" in
        *.xz)  xzcat "$IMAGE" ;;
        *.zip) funzip "$IMAGE" ;;
        *)     cat "$IMAGE" ;;
    esac | sudo dd of="$DEVICE" bs=4M conv=fsync status=progress
    sync
    echo "image written; re-reading partition table"
    # Most card readers get a udev rescan for free, but not all -- and loop
    # devices never do. Force it so the FAT partition node actually appears.
    sudo partprobe "$DEVICE" 2>/dev/null         || sudo blockdev --rereadpt "$DEVICE" 2>/dev/null         || true
    sleep 3

    # Find and mount the FAT partition.
    BOOT="$(mktemp -d)"
    BOOTPART="$(lsblk -lno NAME,FSTYPE "$DEVICE" 2>/dev/null | awk '$2=="vfat"{print "/dev/"$1; exit}')"
    [ -n "$BOOTPART" ] || BOOTPART="${DEVICE}1"
    sudo mount "$BOOTPART" "$BOOT"
    MOUNTED_BY_US=1
fi

[ -n "$BOOT" ] || { echo "nothing to do: pass --device or --boot" >&2; exit 2; }
[ -f "$BOOT/cmdline.txt" ] || { echo "$BOOT does not look like a Raspberry Pi boot partition" >&2; exit 2; }

# --- stage the payload ----------------------------------------------------
PAYLOAD="$BOOT/transfer-station"
sudo mkdir -p "$PAYLOAD"

echo "packing repository..."
# Build the tarball in a temp dir, not on the boot partition: when we mounted
# the card ourselves the mountpoint is root-owned and a non-sudo tar there fails.
TARDIR="$(mktemp -d)"
trap 'rm -rf "$TARDIR"' EXIT
TAR_EXCLUDES=(
    --exclude=./.git
    --exclude=./foobar
    --exclude=./provisioning
    "--exclude=./3D Files"
    --exclude=__pycache__
    --exclude=*.pyc
    --exclude=./dump.rdb
)
tar -czf "$TARDIR/repo.tar.gz" -C "$REPO_ROOT" "${TAR_EXCLUDES[@]}" .
sudo cp "$TARDIR/repo.tar.gz" "$PAYLOAD/repo.tar.gz"

# Strip CR on the way in. A checkout on Windows -- or one that git has
# renormalised -- can leave CRLF in these files, and a CR after the shebang
# makes the Pi fail to run firstrun.sh at all, silently.
for f in firstrun.sh provision.sh transfer-station.service; do
    tr -d $'\r' < "$HERE/payload/$f" > "$TARDIR/$f"
    sudo cp "$TARDIR/$f" "$PAYLOAD/$f"
done
tr -d $'\r' < "$HERE/config.env" > "$TARDIR/config.env"
sudo cp "$TARDIR/config.env" "$PAYLOAD/config.env"
# FAT has no exec bit of its own; the Pi mounts vfat 0755 so this is advisory.
sudo chmod 755 "$PAYLOAD/firstrun.sh" "$PAYLOAD/provision.sh" 2>/dev/null || true

# --- offline bundle -------------------------------------------------------
# If a dependency bundle has been fetched, stage it so stage B needs no
# network at all. Optional: without it the connected-boot path still works.
if [ -n "${TS_BUNDLE:-}" ] && [ -d "$TS_BUNDLE" ]; then
    echo "staging offline bundle from $TS_BUNDLE"
    sudo rm -rf "$PAYLOAD/bundle"
    sudo cp -r "$TS_BUNDLE" "$PAYLOAD/bundle"
fi

# --- build timestamp ------------------------------------------------------
# A Pi has no RTC. With no network it boots believing whatever time it last
# saved, often weeks in the past -- which makes apt reject repositories as
# "not valid yet" and can break TLS. Record when this card was built so stage
# A can advance the clock to at least that point.
date -u +%s | sudo tee "$PAYLOAD/buildstamp" >/dev/null

# --- arm the first-boot hook ---------------------------------------------
# Bookworm+ mounts the FAT partition at /boot/firmware; earlier at /boot.
# pi-gen's real issue.txt names no codename -- it is only
#   Raspberry Pi reference <YYYY-MM-DD>
#   Generated using pi-gen, <url>, <sha>, stage<N>
# -- so the build date is the signal that actually exists. Bookworm was
# released 2023-10-10; the codename match stays as a belt-and-braces override.
RELEASE="$(cat "$BOOT/issue.txt" 2>/dev/null || true)"
# grep exits 1 when issue.txt is missing or dateless; set -e must not care.
BUILT="$(printf '%s' "$RELEASE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 | tr -d '-' || true)"
case "$RELEASE" in
    *bookworm*|*trixie*|*forky*)
        RUNPATH=/boot/firmware/transfer-station/firstrun.sh ;;
    *)
        if [ -n "$BUILT" ] && [ "$BUILT" -ge 20231010 ]; then
            RUNPATH=/boot/firmware/transfer-station/firstrun.sh
        else
            RUNPATH=/boot/transfer-station/firstrun.sh
        fi ;;
esac

CMDLINE="$(tr -d '\n' < "$BOOT/cmdline.txt")"
CMDLINE="$(printf '%s' "$CMDLINE" | sed 's| systemd\.run=[^ ]*||g; s| systemd\.run_success_action=[^ ]*||g; s| systemd\.unit=[^ ]*||g')"
CMDLINE="$CMDLINE systemd.run=$RUNPATH systemd.run_success_action=reboot systemd.unit=kernel-command-line.target"
printf '%s\n' "$CMDLINE" | sudo tee "$BOOT/cmdline.txt" >/dev/null

# --- recovery net ---------------------------------------------------------
# If the systemd.run hook ever fails to fire, stage A never runs -- and on
# Bookworm that leaves no user account and no SSH, i.e. no way in at all and
# no option but to re-flash. Provision SSH and a login independently of the
# hook so a failed first boot is still recoverable over the network.
# firstrun.sh removes userconf.txt once stage A has actually succeeded.
sudo touch "$BOOT/ssh"
if [ -n "${PI_PASSWORD:-}" ] && command -v openssl >/dev/null 2>&1; then
    printf '%s:%s
' "$PI_USER" "$(openssl passwd -6 "$PI_PASSWORD")"         | sudo tee "$BOOT/userconf.txt" >/dev/null
else
    echo "  WARNING: no openssl or no PI_PASSWORD -- skipping the userconf.txt" >&2
    echo "           fallback. A failed first boot will be unrecoverable." >&2
    sudo rm -f "$BOOT/userconf.txt"
fi

sync
if [ "${MOUNTED_BY_US:-0}" = "1" ]; then
    sudo umount "$BOOT" && rmdir "$BOOT"
fi

cat <<EOF

Card ready.

  1. Boot the Pi plugged into a router/switch WITH INTERNET.
     Two automatic reboots follow (stage A: offline setup, stage B: packages).
     Stage B takes a few minutes; watch it on an HDMI display if you like.
  2. When it settles, move the Pi to the isolated switch.
     UI:  http://${ETH_ADDRESS}:${SERVER_PORT}
     SSH: ssh ${PI_USER}@${ETH_ADDRESS}

  Set your controller PC's NIC to a static address on the same subnet,
  e.g. 192.168.10.2/${ETH_PREFIX}, with no gateway.
EOF
