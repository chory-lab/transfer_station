#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build a ready-to-flash Raspberry Pi image for this project.
#
#   sudo PI_PASSWORD=secret ./pi-image/build.sh [output.img.xz]
#
# Customises the OFFICIAL Raspberry Pi OS Lite image with sdm. Everything is
# installed at build time, so the resulting card needs no first-boot
# provisioning, no two-stage boot, and no network on the Pi: flash it and
# switch the Pi on.
#
# Everything project-specific lives in pi-app.env. A second instrument needs
# its own copy of that file and nothing else.
#
# Requires: Linux, root, sdm (installed automatically if absent).
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck disable=SC1091
. "$HERE/pi-app.env"
# Allow the environment to override the manifest, so a password never has to
# be committed.
PI_PASSWORD="${PI_PASSWORD:-changeme}"
IMAGE_URL="${IMAGE_URL:?IMAGE_URL missing from pi-app.env}"

CACHE="${PI_IMAGE_CACHE:-/tmp/pi-image-cache}"
OUT="${1:-$REPO_ROOT/${APP_NAME}-$(date -u +%Y-%m-%d).img.xz}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sdm needs it)" >&2; exit 1; }
if [ "$PI_PASSWORD" = "changeme" ]; then
    echo "WARNING: building with the default password. Set PI_PASSWORD." >&2
fi

# --- sdm ------------------------------------------------------------------
# A maintained tool that already solves image customisation: user creation,
# the first-boot account wizard, cloud-init, machine-id, root expansion. All
# things worth not reimplementing.
if ! command -v sdm >/dev/null 2>&1; then
    echo ">> installing sdm"
    curl -fsSL https://raw.githubusercontent.com/gitbls/sdm/master/install-sdm | bash
fi
sdm --version || true

# --- the base image -------------------------------------------------------
mkdir -p "$CACHE"
IMG="$CACHE/raspios.img"
if [ ! -f "$IMG" ]; then
    if [ ! -f "$CACHE/raspios.img.xz" ]; then
        echo ">> downloading Raspberry Pi OS Lite (about 500 MB, cached)"
        curl -fSL --retry 3 -o "$CACHE/raspios.img.xz.part" "$IMAGE_URL"
        mv "$CACHE/raspios.img.xz.part" "$CACHE/raspios.img.xz"
    fi
    echo ">> decompressing"
    xz -dc "$CACHE/raspios.img.xz" > "$IMG.part" && mv "$IMG.part" "$IMG"
fi

# sdm customises in place, so work on a copy and keep the download reusable.
WORK="$CACHE/${APP_NAME}-work.img"
echo ">> preparing a working copy"
rm -f "$WORK"
cp --reflink=auto "$IMG" "$WORK"

# --- render the per-project files ----------------------------------------
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

VENV="${REPO_DEST}/.venv"
EXECSTART="${APP_EXEC//\$\{VENV\}/$VENV}"
EXECSTART="${EXECSTART//\$\{SERVER_PORT\}/$SERVER_PORT}"

# No gateway and no DNS: without a default route on this interface the Pi
# cannot route to or from the lab LAN, only to hosts on the same switch.
cat > "$BUILD/eth0-isolated.nmconnection" <<NMCONN
[connection]
id=${ETH_IFACE}-isolated
type=ethernet
interface-name=${ETH_IFACE}
autoconnect=true
autoconnect-priority=100

[ipv4]
method=manual
address1=${ETH_ADDRESS}/${ETH_PREFIX}
never-default=true
ignore-auto-dns=true
may-fail=false

[ipv6]
method=disabled
NMCONN
chmod 600 "$BUILD/eth0-isolated.nmconnection"

cat > "$BUILD/${APP_NAME}.service" <<UNIT
[Unit]
Description=${APP_NAME} server
After=network.target ${SERVICE_REQUIRES}
Requires=${SERVICE_REQUIRES}

[Service]
Type=simple
User=${PI_USER}
Group=${PI_USER}
SupplementaryGroups=gpio dialout
WorkingDirectory=${REPO_DEST}
Environment=PYTHONUNBUFFERED=1
ExecStart=${EXECSTART}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# The phase script reads the manifest from beside itself, with the password
# resolved from the environment rather than the committed file.
grep -v '^PI_PASSWORD=' "$HERE/pi-app.env" > "$BUILD/pi-app.env"
printf 'PI_PASSWORD=%s\n' "$PI_PASSWORD" >> "$BUILD/pi-app.env"
install -m 755 "$HERE/cscript.sh" "$BUILD/cscript.sh"

# --- customise ------------------------------------------------------------
echo ">> customising the image with sdm"
export PI_IMAGE_REPO="$REPO_ROOT"
export PI_IMAGE_BUILD="$BUILD"

sdm --customize "$WORK" \
    --hostname "$PI_HOSTNAME" \
    --timezone "$TIMEZONE" \
    --extend --xmb "$GROW_MB" \
    --expand-root \
    --restart \
    --plugin "user:username=${PI_USER}|password=${PI_PASSWORD}|groups=sudo,adm,dialout,gpio,i2c,spi,video,plugdev,netdev" \
    --plugin "apps:apps=${APT_PACKAGES}" \
    --cscript "$BUILD/cscript.sh"

# --- compress -------------------------------------------------------------
echo ">> compressing (the slow part)"
rm -f "$OUT.part"
xz -T0 -6 -c "$WORK" > "$OUT.part" 2>/dev/null || xz -6 -c "$WORK" > "$OUT.part"
mv "$OUT.part" "$OUT"
rm -f "$WORK"

echo
echo "Built: $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "Flash it with Raspberry Pi Imager and switch the Pi on. No first boot"
echo "provisioning, no network needed."
echo "  UI:  http://${ETH_ADDRESS}:${SERVER_PORT}"
echo "  SSH: ssh ${PI_USER}@${ETH_ADDRESS}"
