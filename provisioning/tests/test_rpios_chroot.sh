#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tier 1: run the provisioning chain inside the REAL Raspberry Pi OS rootfs.
#
# Downloads the official Raspberry Pi OS Lite arm64 image, loop-mounts its
# partitions, and chroots into them under qemu-user binfmt emulation. Stage A,
# stage B and the deployment checks then run against genuine Raspberry Pi OS:
# its real apt archive (archive.raspberrypi.com), its real package versions,
# its real Python and its real filesystem layout.
#
# What this still does NOT cover: nothing boots. No bootloader, no kernel
# command line, no systemd as PID 1, no NetworkManager applying a profile to a
# real NIC, no GPIO. See provisioning/README.md.
#
# Requires: Linux, root, losetup, qemu-user-static binfmt for aarch64.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$PROV/.." && pwd)"

IMAGE_URL="${TS_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}"
CACHE="${TS_IMAGE_CACHE:-/tmp/rpios-cache}"
HEADROOM_GB="${TS_HEADROOM_GB:-3}"

if [ "$(id -u)" -ne 0 ]; then echo "must run as root" >&2; exit 2; fi
for tool in losetup xz curl sfdisk resize2fs e2fsck; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done

MNT="$(mktemp -d)"
LOOP=""
cleanup() {
    set +e
    for d in dev/pts dev proc sys boot/firmware; do
        mountpoint -q "$MNT/$d" && umount -l "$MNT/$d"
    done
    mountpoint -q "$MNT" && umount -l "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP"
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

# --- fetch the official image --------------------------------------------
mkdir -p "$CACHE"
XZ="$CACHE/raspios.img.xz"
IMG="$CACHE/raspios.img"

if [ ! -f "$IMG" ]; then
    if [ ! -f "$XZ" ]; then
        echo ">> downloading Raspberry Pi OS Lite arm64..."
        curl -fSL --retry 3 -o "$XZ.part" "$IMAGE_URL"
        mv "$XZ.part" "$XZ"
    fi
    echo ">> decompressing..."
    xz -dc "$XZ" > "$IMG.part"
    mv "$IMG.part" "$IMG"
fi

# Provisioning mutates the image. Locally, work on a copy so the cached
# download stays reusable; in CI the runner is disposable and disk is tight
# (the image is ~3G before headroom), so operate in place.
if [ "${TS_INPLACE:-0}" = "1" ]; then
    WORKIMG="$IMG"
else
    WORKIMG="$(mktemp -u /tmp/rpios-work-XXXX.img)"
    cp --reflink=auto "$IMG" "$WORKIMG"
    trap 'cleanup; rm -f "$WORKIMG"' EXIT
fi

# --- grow the rootfs so apt has room -------------------------------------
echo ">> growing rootfs by ${HEADROOM_GB}G"
truncate -s "+${HEADROOM_GB}G" "$WORKIMG"
# Extend the last partition to fill the new space.
echo ", +" | sfdisk -N 2 --no-reread --force "$WORKIMG" >/dev/null

LOOP="$(losetup --show -fP "$WORKIMG")"
BOOTPART="${LOOP}p1"
ROOTPART="${LOOP}p2"
e2fsck -fp "$ROOTPART" >/dev/null 2>&1 || true
resize2fs "$ROOTPART" >/dev/null

# --- mount exactly the way the device does -------------------------------
mount "$ROOTPART" "$MNT"

echo ">> verifying the image's own layout assumptions"
FSTAB="$(cat "$MNT/etc/fstab")"
echo "$FSTAB"
if ! grep -qE '/boot/firmware\s+vfat' "$MNT/etc/fstab"; then
    echo "!! this image does NOT mount the FAT partition at /boot/firmware" >&2
    echo "!! flash.sh's bookworm systemd.run path would be wrong" >&2
    exit 1
fi
echo "   ok: /etc/fstab mounts the FAT partition at /boot/firmware"

mkdir -p "$MNT/boot/firmware"
mount "$BOOTPART" "$MNT/boot/firmware"

echo ">> real issue.txt from the image:"
sed -n '1p' "$MNT/boot/firmware/issue.txt" || true
echo ">> real cmdline.txt from the image:"
cat "$MNT/boot/firmware/cmdline.txt"

# --- qemu-user + chroot plumbing -----------------------------------------
if [ -f /usr/bin/qemu-aarch64-static ]; then
    cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/"
fi
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"

# Confirm we are actually executing aarch64 binaries, not host ones.
ARCH_IN_CHROOT="$(chroot "$MNT" /usr/bin/uname -m)"
echo ">> uname -m inside the chroot: $ARCH_IN_CHROOT"
if [ "$ARCH_IN_CHROOT" != "aarch64" ]; then
    echo "!! binfmt emulation is not active; aborting rather than testing the host" >&2
    exit 1
fi

# --- stage the repo and run the suites ------------------------------------
mkdir -p "$MNT/work"
cp -a "$REPO_ROOT/." "$MNT/work/"

# --- optional: build the offline dependency bundle -----------------------
# apt's own solver runs here, against the real archive, for the real release.
# That is the whole reason this lives in the chroot rather than on the host.
if [ "${TS_BUILD_BUNDLE:-0}" = "1" ]; then
    echo
    echo "############ building the offline bundle ############"
    chroot "$MNT" /bin/bash -c '
        set -e
        apt-get install -y --no-install-recommends curl ca-certificates >/dev/null
        bash /work/provisioning/build-bundle.sh /bundle
    '
    # Pin the exact image this bundle matches. .debs are only valid for the
    # release they came from, so the bootstraps must write this same image or
    # the bundle is useless.
    RESOLVED="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$IMAGE_URL")"
    echo "BUNDLE_IMAGE_URL=${RESOLVED}" >> "$MNT/bundle/manifest.env"
    rm -rf /tmp/ts-bundle
    cp -r "$MNT/bundle" /tmp/ts-bundle
    echo ">> bundle copied to /tmp/ts-bundle"
    exit 0
fi

echo
echo "############ stage A: firstrun.sh on real Raspberry Pi OS ############"
chroot "$MNT" /bin/bash -c '
    set -e
    export TS_ALLOW_DESTRUCTIVE=1 TS_KEEP_BOOT=1
    bash /work/provisioning/tests/test_firstrun.sh
'

echo
echo "############ stage B: provision.sh against archive.raspberrypi.com ############"
chroot "$MNT" /bin/bash -c '
    set -e
    export TS_CI=1
    bash /usr/local/sbin/transfer-station-provision
'

echo
echo "############ deployment checks ############"
chroot "$MNT" /bin/bash -c '
    set -e
    export TS_ALLOW_DESTRUCTIVE=1 TS_EMULATED=1
    bash /work/provisioning/tests/test_deploy.sh
'

echo
echo ">> package provenance (the point of Tier 1):"
chroot "$MNT" /bin/bash -c '
    apt-cache policy python3-rpi.gpio redis-server 2>/dev/null | grep -E "Installed|500 http" | head -20
'

echo
echo "TIER 1 PASSED: provisioning works on genuine Raspberry Pi OS userspace"
