#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot Transfer Station SD card builder. No clone required:
#
#   curl -fsSL https://raw.githubusercontent.com/chory-lab/transfer_station/main/provisioning/bootstrap.sh | sudo bash
#
# Downloads Raspberry Pi OS, asks which card to use and what password to set,
# writes the image and provisions it. Nothing else to do afterwards except
# boot the Pi once with internet.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_TARBALL="https://github.com/chory-lab/transfer_station/archive/refs/heads/main.tar.gz"
IMAGE_URL="${TS_IMAGE_URL:-}"
BUNDLE_URL="${TS_BUNDLE_URL:-https://github.com/chory-lab/transfer_station/releases/latest/download/offline-bundle.tar.gz}"
CACHE="${TS_CACHE:-${SUDO_USER:+/home/$SUDO_USER}/.cache/transfer-station}"
CACHE="${CACHE:-/tmp/transfer-station-cache}"

# When piped from curl, stdin is the script itself -- prompt on the terminal.
if [ -r /dev/tty ]; then exec 3</dev/tty; else exec 3<&0; fi
ask() { printf '%s' "$1" >&2; read -r "${2}" <&3; }

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
for t in curl xz tar lsblk dd; do
    command -v "$t" >/dev/null || { echo "Missing required tool: $t" >&2; exit 1; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$CACHE"

echo
echo "=== Transfer Station SD card builder ==="

# --- 1. pick the card -----------------------------------------------------
echo
echo "Removable drives:"
mapfile -t DISKS < <(lsblk -dno NAME,SIZE,RM,MODEL | awk '$3==1 {print}')
if [ "${#DISKS[@]}" -eq 0 ]; then
    echo "  none found. Insert the SD card and re-run." >&2; exit 1
fi
i=1
for d in "${DISKS[@]}"; do echo "  [$i] /dev/$d"; i=$((i+1)); done
ask "Which one? [1-${#DISKS[@]}] " CHOICE
DEV="/dev/$(echo "${DISKS[$((CHOICE-1))]}" | awk '{print $1}')"
[ -b "$DEV" ] || { echo "Not a block device: $DEV" >&2; exit 1; }

# Refuse anything not flagged removable, whatever the user typed.
[ "$(lsblk -dno RM "$DEV")" = "1" ] || { echo "$DEV is not removable. Refusing." >&2; exit 1; }

echo
echo "  !! $DEV will be COMPLETELY ERASED:"
lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "$DEV"
ask "  Type ERASE to continue: " CONFIRM
[ "$CONFIRM" = "ERASE" ] || { echo "Aborted."; exit 1; }

# --- 2. password ----------------------------------------------------------
echo
printf 'Password for the "chorylab" account (SSH login): ' >&2
read -rs PW <&3; echo >&2
printf 'Again: ' >&2; read -rs PW2 <&3; echo >&2
[ -n "$PW" ] || { echo "Password cannot be empty." >&2; exit 1; }
[ "$PW" = "$PW2" ] || { echo "Passwords do not match." >&2; exit 1; }

# --- 3. fetch the provisioning repo and the OS image ----------------------
echo
echo ">> fetching provisioning scripts"
curl -fsSL "$REPO_TARBALL" | tar -xz -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'transfer_station-*' | head -1)"

# --- offline dependency bundle -------------------------------------------
# Fetched first: it pins the exact OS image its .debs were built against, so
# it decides which image we write. Without a matching image the bundle is
# useless, and the Pi would need a connected boot after all.
BUNDLE_DIR="$CACHE/bundle"
if [ ! -f "$BUNDLE_DIR/manifest.env" ]; then
    echo ">> downloading the offline dependency bundle"
    if curl -fsSL --retry 2 -o "$CACHE/bundle.tar.gz" "$BUNDLE_URL"; then
        rm -rf "$BUNDLE_DIR"; mkdir -p "$BUNDLE_DIR"
        tar -xzf "$CACHE/bundle.tar.gz" -C "$BUNDLE_DIR"
    else
        echo "   WARNING: no bundle available; the Pi will need one connected boot." >&2
        rm -rf "$BUNDLE_DIR"
    fi
else
    echo ">> using the cached offline bundle"
fi

if [ -f "$BUNDLE_DIR/manifest.env" ]; then
    # shellcheck disable=SC1091
    . "$BUNDLE_DIR/manifest.env"
    echo "   bundle: ${BUNDLE_CODENAME:-?} (built ${BUNDLE_BUILT:-?})"
    [ -n "$IMAGE_URL" ] || IMAGE_URL="${BUNDLE_IMAGE_URL:-}"
fi
# No bundle and no override: fall back to the current release.
[ -n "$IMAGE_URL" ] || IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"

IMG="$CACHE/raspios.img"
if [ ! -f "$IMG" ]; then
    echo ">> downloading Raspberry Pi OS Lite (about 500 MB, cached for next time)"
    curl -fSL --retry 3 -o "$CACHE/raspios.img.xz.part" "$IMAGE_URL"
    mv "$CACHE/raspios.img.xz.part" "$CACHE/raspios.img.xz"
    echo ">> decompressing"
    xz -dc "$CACHE/raspios.img.xz" > "$IMG.part" && mv "$IMG.part" "$IMG"
fi

# --- 4. flash -------------------------------------------------------------
# Rewrite the line rather than sed-substituting into it: a password may
# legitimately contain |, & or backslashes.
CFG="$SRC/provisioning/config.env"
grep -v '^PI_PASSWORD=' "$CFG" > "$CFG.new"
# Store it base64-encoded: config.env is sourced by bash AND parsed by
# PowerShell, so any quoting scheme that survives one can break the other.
# Base64 is safe for both, and the consumers know to decode it.
printf 'PI_PASSWORD_B64=%s
' "$(printf '%s' "$PW" | base64 | tr -d '
')" >> "$CFG.new"
mv "$CFG.new" "$CFG"
echo
echo ">> writing the image and provisioning (a few minutes)"
if [ -f "$BUNDLE_DIR/manifest.env" ]; then export TS_BUNDLE="$BUNDLE_DIR"; fi
echo "$DEV" | bash "$SRC/provisioning/flash.sh" --image "$IMG" --device "$DEV"

# --- 5. verify what actually landed on the card ---------------------------
echo
echo ">> verifying the card"
BOOTMNT="$(mktemp -d)"
BOOTPART="$(lsblk -lno NAME,FSTYPE "$DEV" | awk '$2=="vfat"{print "/dev/"$1; exit}')"
mount "$BOOTPART" "$BOOTMNT"
bash "$SRC/provisioning/verify-card.sh" "$BOOTMNT"
VERIFY_RC=$?
umount "$BOOTMNT"; rmdir "$BOOTMNT"
if [ "$VERIFY_RC" -ne 0 ]; then
    echo
    echo "Verification FAILED. Do not boot this card -- re-run to rebuild it." >&2
    exit 1
fi

echo
echo "Done."
if [ -f "$BUNDLE_DIR/manifest.env" ]; then
    echo "The card carries all its dependencies, so the Pi needs NO internet."
    echo "Put it in the Pi and boot it. It reboots twice by itself, then:"
else
    echo "No offline bundle was available, so boot the Pi ONCE plugged into a"
    echo "router with internet. It reboots twice by itself, then comes up at:"
fi
echo
echo "    http://192.168.10.1:5000     ssh chorylab@192.168.10.1"
