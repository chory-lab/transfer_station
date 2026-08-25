#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run cscript.sh phase 0 against a fake mounted image.
#
# Phase 0 is the only phase that can be exercised off a Pi: it runs on the
# host and just moves files around. It is also where the expensive bugs have
# been -- shellcheck cannot see that a path resolves to nothing, so the only
# way to catch it is to run it.
#
# The script is deliberately copied somewhere ELSE before being run, because
# that is what sdm does: it installs the cscript into the image and invokes
# it from there. Anything the script expects to find beside itself is gone by
# then. That exact assumption failed a build once.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_IMAGE_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$PI_IMAGE_DIR/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

# Git Bash on Windows cannot apply POSIX modes, and phase 0 installs files
# with explicit ones. Skip rather than report a failure that says nothing
# about the script -- CI runs this on Linux, where it is meaningful.
probe="$TMP/probe"
mkdir -p "$probe"
if ! install -d -m 700 "$probe/d" 2>/dev/null || [ "$(stat -c %a "$probe/d")" != 700 ]; then
    echo "SKIP: this filesystem does not honour POSIX modes"
    exit 0
fi

# shellcheck disable=SC1091
. "$PI_IMAGE_DIR/pi-app.env"

# --- a staging directory, as build.sh renders it --------------------------
BUILD="$TMP/build"
mkdir -p "$BUILD"
grep -v '^PI_PASSWORD=' "$PI_IMAGE_DIR/pi-app.env" > "$BUILD/pi-app.env"
printf 'PI_PASSWORD=%s\n' 'test-password' >> "$BUILD/pi-app.env"
printf '[connection]\nid=%s-isolated\n' "$ETH_IFACE" > "$BUILD/eth0-isolated.nmconnection"
printf '[Unit]\nDescription=%s\n' "$APP_NAME" > "$BUILD/${APP_NAME}.service"

# --- a fake mounted image -------------------------------------------------
# Only directories a real Raspberry Pi OS image actually ships, so the test
# cannot pass by handing phase 0 something the Pi will not have.
SDMPT="$TMP/img"
mkdir -p "$SDMPT/etc/systemd/system" "$SDMPT/usr/local/sdm" "$SDMPT/home"

# --- sdm copies the cscript into the image and runs it from there ---------
install -m 755 "$PI_IMAGE_DIR/cscript.sh" "$SDMPT/usr/local/sdm/cscript.sh"

SDMPT="$SDMPT" PI_IMAGE_BUILD="$BUILD" PI_IMAGE_REPO="$REPO_ROOT" \
    bash "$SDMPT/usr/local/sdm/cscript.sh" 0

# --- what phase 0 must have left behind -----------------------------------
[ -f "$SDMPT/etc/pi-image-app.env" ] \
    || fail "manifest was not carried into the image"
grep -q '^PI_PASSWORD=test-password$' "$SDMPT/etc/pi-image-app.env" \
    || fail "the manifest in the image is not the one build.sh rendered"
ok "manifest staged for phase 1"

for f in api_step_motor.py A4988.py pyproject.toml uv.lock templates; do
    [ -e "$SDMPT$REPO_DEST/$f" ] || fail "repo is missing $f"
done
ok "application unpacked at $REPO_DEST"

for excluded in .git provisioning pi-image foobar dump.rdb; do
    [ -e "$SDMPT$REPO_DEST/$excluded" ] \
        && fail "$excluded should not be in the image"
done
ok "build-time-only directories excluded"

[ -f "$SDMPT/etc/NetworkManager/system-connections/${ETH_IFACE}-isolated.nmconnection" ] \
    || fail "the isolated network profile was not installed"
[ "$(stat -c %a "$SDMPT/etc/NetworkManager/system-connections/${ETH_IFACE}-isolated.nmconnection")" = 600 ] \
    || fail "NetworkManager ignores a connection profile that is not mode 600"
ok "isolated ethernet profile installed, mode 600"

[ -f "$SDMPT/etc/systemd/system/${APP_NAME}.service" ] \
    || fail "the service unit was not installed"
ok "service unit installed"

# The account does not exist until sdm's user plugin runs in phase 1, so
# phase 0 must not create anything it would have to own.
[ -e "$SDMPT/home/${PI_USER}/.ssh" ] \
    && fail "phase 0 wrote into a home directory that has no owner yet"
ok "no ownerless files under the home directory"

# --- and it must fail loudly, not silently, without its staging dir -------
if SDMPT="$SDMPT" PI_IMAGE_REPO="$REPO_ROOT" \
        bash "$SDMPT/usr/local/sdm/cscript.sh" 0 >/dev/null 2>&1; then
    fail "phase 0 succeeded with no PI_IMAGE_BUILD; it cannot have staged anything"
fi
ok "missing staging directory is a hard error"

echo "phase 0 ok"
