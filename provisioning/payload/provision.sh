#!/bin/bash
# ---------------------------------------------------------------------------
# Stage B -- runs once on the second boot, with networking up. Installs
# system packages and Python deps, installs the server unit, then swaps the
# ethernet interface over to the isolated static address and reboots.
#
# Plug the Pi into a normal router/switch with internet for this one boot.
# After it finishes, the Pi is permanently on the isolated link.
# ---------------------------------------------------------------------------
set -euo pipefail

# Establish logging FIRST. Anything that can fail must fail into the log,
# not before it exists -- sourcing the config used to come first, so a missing
# config file killed this script under `set -e` with no output anywhere.
for _b in /boot/firmware /boot; do
    if [ -d "$_b/transfer-station" ]; then
        exec > >(tee -a "$_b/transfer-station/provision.log") 2>&1
        break
    fi
done

# Flush the log to the card on EVERY exit path, not just success. Without
# this, a failed provisioning boot could lose provision.log to the page cache
# if the Pi is powered off before the kernel's writeback timer fires -- which
# is precisely when the log matters most.
trap 'sync' EXIT

echo "=== transfer-station provisioning $(date -u) ==="

CONFIG=/usr/local/share/transfer-station-config.env
TMPL=/usr/local/share/transfer-station.service.tmpl
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG is missing. Stage A should have installed it;" >&2
    echo "       re-provision the card and boot again." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG"

# --- offline bundle -------------------------------------------------------
# If the card carries a dependency bundle, everything installs from it and
# this boot needs no network at all. Otherwise fall back to the archives.
BUNDLE=""
for _b in /boot/firmware /boot; do
    if [ -d "$_b/transfer-station/bundle" ]; then BUNDLE="$_b/transfer-station/bundle"; break; fi
done
if [ -n "$BUNDLE" ] && [ -f "$BUNDLE/manifest.env" ]; then
    # shellcheck disable=SC1091
    . "$BUNDLE/manifest.env"
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${BUNDLE_CODENAME:-}" != "${VERSION_CODENAME:-}" ]; then
        echo "WARNING: bundle was built for ${BUNDLE_CODENAME:-?} but this OS is"
        echo "         ${VERSION_CODENAME:-?}. Ignoring it -- mixing releases would"
        echo "         install a broken set. Falling back to the network."
        BUNDLE=""
    else
        echo "using the offline bundle (${BUNDLE_CODENAME}, built ${BUNDLE_BUILT:-?})"
    fi
elif [ -n "$BUNDLE" ]; then
    echo "WARNING: bundle directory has no manifest.env; ignoring it."
    BUNDLE=""
fi


# CI mode: exercise the package/venv work inside an arm64 container, where
# there is no init system, no NetworkManager and no reboot. Everything else
# runs for real so dependency resolution is genuinely tested.
if [ "${TS_CI:-0}" = "1" ]; then
    echo "*** TS_CI=1: systemctl and reboot are stubbed ***"
    systemctl() { echo "[ci] systemctl $*"; return 0; }
    mkdir -p /etc/NetworkManager/system-connections
fi

# --- wait for real connectivity ------------------------------------------
# Only needed when there is no bundle to install from.
if [ -z "$BUNDLE" ]; then
# network-online.target only means an interface came up, not that DNS works.
for i in $(seq 1 30); do
    if getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
    echo "waiting for DNS ($i/30)..."
    sleep 5
done
if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "ERROR: no internet on this boot, and no offline bundle on the card." >&2
    echo "Connect ${ETH_IFACE} to a router with internet and reboot, or rebuild" >&2
    echo "the card with a bundle so no network is needed." >&2
    exit 1
fi
fi

# --- system packages ------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
# python3-rpi.gpio is the prebuilt C extension; installing it via pip would
# require a toolchain and frequently fails on current kernels.
if [ -n "$BUNDLE" ]; then
    # The bundle already holds the full dependency closure, so dpkg needs
    # neither network nor solver: installing the whole set at once satisfies it.
    dpkg -i "$BUNDLE"/debs/*.deb
else
    apt-get update
    apt-get install -y --no-install-recommends         redis-server python3-rpi.gpio python3-venv ca-certificates curl
fi

systemctl enable redis-serversystemctl enable redis-server

# --- uv -------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    if [ -n "$BUNDLE" ]; then
        tar -xzf "$BUNDLE/uv.tar.gz" -C /tmp
        install -m 755 "$(find /tmp -name uv -type f | head -1)" /usr/local/bin/uv
    else
        curl -LsSf https://astral.sh/uv/install.sh             | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
    fi
fi
uv --version

# --- python environment ---------------------------------------------------
# Built on the SYSTEM interpreter with system site-packages visible, so the
# apt-installed RPi.GPIO stays importable. uv only manages the pure-Python
# deps in requirements.txt.
rm -rf "${REPO_DEST}/.venv"
uv venv --python /usr/bin/python3 --system-site-packages "${REPO_DEST}/.venv"
if [ -n "$BUNDLE" ]; then
    uv pip install --python "${REPO_DEST}/.venv/bin/python"         --no-index --find-links "$BUNDLE/wheels" -r "${REPO_DEST}/requirements.txt"
else
    uv pip install --python "${REPO_DEST}/.venv/bin/python" -r "${REPO_DEST}/requirements.txt"
fi
# RPi.GPIO is checked by spec rather than import: importing it on non-Pi
# hardware (i.e. in CI) raises, but presence on sys.path is what we need.
"${REPO_DEST}/.venv/bin/python" - <<'PYCHECK'
import importlib.util as u
import flask, flask_caching, redis          # noqa: F401
assert u.find_spec("RPi.GPIO"), "RPi.GPIO not visible in the venv"
print("deps ok")
PYCHECK
chown -R "${PI_USER}:${PI_USER}" "${REPO_DEST}/.venv"

# --- server unit ----------------------------------------------------------
sed -e "s|__PI_USER__|${PI_USER}|g" \
    -e "s|__REPO_DEST__|${REPO_DEST}|g" \
    -e "s|__SERVER_PORT__|${SERVER_PORT}|g" \
    "$TMPL" > /etc/systemd/system/transfer-station.service
systemctl daemon-reload
systemctl enable transfer-station.service

# --- isolated ethernet ----------------------------------------------------
# Static address with NO gateway and NO DNS. Without a default route through
# this interface the Pi cannot reach, and cannot be reached from, the lab LAN
# -- only hosts on the same physical switch.
if [ "${TS_CI:-0}" = "1" ] || systemctl is-active --quiet NetworkManager; then
    echo "configuring ${ETH_IFACE} via NetworkManager keyfile"
    KEYFILE="/etc/NetworkManager/system-connections/${ETH_IFACE}-isolated.nmconnection"
    cat > "$KEYFILE" <<NMCONN
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
    chmod 600 "$KEYFILE"
    # Drop the auto-generated DHCP profiles so neither can win the race:
    # NetworkManager's own, and the one cloud-init renders from network-config.
    find /etc/NetworkManager/system-connections \
        \( -name 'Wired connection*' -o -name 'cloud-init-*' \) \
        -delete 2>/dev/null || true
else
    echo "configuring ${ETH_IFACE} via dhcpcd"
    sed -i "/# BEGIN transfer-station/,/# END transfer-station/d" /etc/dhcpcd.conf
    cat >> /etc/dhcpcd.conf <<DHCPCD

# BEGIN transfer-station
interface ${ETH_IFACE}
static ip_address=${ETH_ADDRESS}/${ETH_PREFIX}
nogateway
nohook resolv.conf
# END transfer-station
DHCPCD
fi

# --- disarm stage B -------------------------------------------------------
systemctl disable transfer-station-provision.service
rm -f /etc/systemd/system/transfer-station-provision.service
rm -f /usr/local/sbin/transfer-station-provision "$CONFIG"
systemctl daemon-reload

echo "=== provisioning complete ==="
echo "rebooting onto isolated link: http://${ETH_ADDRESS}:${SERVER_PORT}"
sync
if [ "${TS_CI:-0}" = "1" ]; then
    echo "[ci] skipping reboot"
    exit 0
fi
systemctl reboot
