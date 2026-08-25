#!/usr/bin/env bash
# Audit the exact compressed image that CI will publish.
set -euo pipefail

IMAGE="${1:-}"
[ -f "$IMAGE" ] || { echo "usage: $0 image.img.xz" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/pi-image/pi-app.env"

for tool in xz losetup mount umount chroot systemctl stat; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

WORK="$(mktemp -d)"
MNT="$WORK/root"
RAW="$WORK/image.img"
LOOP=""
cleanup() {
    set +e
    mountpoint -q "$MNT/boot/firmware" && umount "$MNT/boot/firmware"
    mountpoint -q "$MNT" && umount "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP"
    rm -rf "$WORK"
}
trap cleanup EXIT

ok() { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo ">> checking and decompressing the published image"
xz -t "$IMAGE"
xz -dc "$IMAGE" > "$RAW"
LOOP="$(losetup --show -fP "$RAW")"
[ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] || fail "image does not have boot and root partitions"
mkdir -p "$MNT"
mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "${LOOP}p1" "$MNT/boot/firmware"
ok "image partitions mount"

grep -qx "$PI_HOSTNAME" "$MNT/etc/hostname" || fail "hostname is not $PI_HOSTNAME"
grep -q "^$PI_USER:" "$MNT/etc/passwd" || fail "user $PI_USER is missing"
USER_GROUPS="$(chroot "$MNT" id -nG "$PI_USER")"
for group in sudo gpio dialout; do
    grep -qw "$group" <<<"$USER_GROUPS" ||
        fail "$PI_USER is not in $group"
done
ok "identity and hardware groups"

for path in api_step_motor.py A4988.py pyproject.toml uv.lock templates .venv/bin/python; do
    [ -e "$MNT$REPO_DEST/$path" ] || fail "$REPO_DEST/$path is missing"
done
APP_UID="$(stat -c %u "$MNT$REPO_DEST")"
USER_UID="$(awk -F: -v user="$PI_USER" '$1 == user { print $3 }' "$MNT/etc/passwd")"
[ -n "$USER_UID" ] && [ "$APP_UID" = "$USER_UID" ] || fail "application has the wrong owner"
ok "application and frozen venv installed"

chroot "$MNT" dpkg-query -W redis-server python3-rpi.gpio network-manager >/dev/null
chroot "$MNT" "$REPO_DEST/.venv/bin/python" - <<'PY'
import importlib.util as u
import flask, flask_caching, redis  # noqa: F401
assert u.find_spec("RPi.GPIO")
print("runtime imports ok")
PY
ok "apt and Python dependencies installed"

systemctl --root="$MNT" is-enabled "$APP_NAME.service" >/dev/null ||
    fail "$APP_NAME.service is not enabled"
systemctl --root="$MNT" is-enabled ssh.service >/dev/null ||
    fail "ssh.service is not enabled"
UNIT="$MNT/etc/systemd/system/$APP_NAME.service"
grep -q "^User=$PI_USER$" "$UNIT" || fail "service runs as the wrong user"
grep -q "^Requires=$SERVICE_REQUIRES$" "$UNIT" || fail "service does not require Redis"
grep -q "^ExecStart=$REPO_DEST/.venv/bin/flask " "$UNIT" || fail "service does not use the frozen venv"
ok "SSH and application service enabled"

PROFILE="$MNT/etc/NetworkManager/system-connections/${ETH_IFACE}-isolated.nmconnection"
[ -f "$PROFILE" ] || fail "isolated NetworkManager profile is missing"
[ "$(stat -c %a "$PROFILE")" = 600 ] || fail "NetworkManager profile is not mode 600"
grep -q "^interface-name=$ETH_IFACE$" "$PROFILE" || fail "profile targets the wrong interface"
grep -q "^address1=$ETH_ADDRESS/$ETH_PREFIX$" "$PROFILE" || fail "static address is wrong"
grep -q '^never-default=true$' "$PROFILE" || fail "profile can install a default route"
grep -q '^ignore-auto-dns=true$' "$PROFILE" || fail "profile can accept automatic DNS"
grep -q '^method=disabled$' "$PROFILE" || fail "IPv6 is not disabled"
grep -Eq '^(gateway|dns)=' "$PROFILE" && fail "isolated profile contains a gateway or DNS"
grep -q '^no-auto-default=\*$' "$MNT/etc/NetworkManager/conf.d/00-no-auto-default.conf" ||
    fail "NetworkManager can create a competing DHCP profile"
ok "isolated static network configuration"

grep -Eq '/boot/firmware[[:space:]]+vfat' "$MNT/etc/fstab" ||
    fail "boot partition mount does not match Raspberry Pi OS"
[ -f "$MNT/boot/firmware/cmdline.txt" ] || fail "cmdline.txt is missing"
ok "boot filesystem layout"

echo "FINAL IMAGE AUDIT PASSED"
