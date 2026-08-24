#!/bin/bash
# ---------------------------------------------------------------------------
# Stage A -- runs once, very early on the first boot, via systemd.run= in
# cmdline.txt. There is NO NETWORK at this point, so this stage only does
# offline setup and then arms Stage B (provision.sh), which runs on the next
# boot once networking is up.
# ---------------------------------------------------------------------------
set -uo pipefail

# Locate the FAT boot partition. Bookworm+ mounts it at /boot/firmware,
# Bullseye and earlier at /boot.
BOOTDIR=""
for d in /boot/firmware /boot; do
    if [ -f "$d/transfer-station/config.env" ]; then BOOTDIR="$d"; break; fi
done
if [ -z "$BOOTDIR" ]; then
    echo "firstrun: cannot find payload on boot partition" >&2
    exit 1
fi
PAYLOAD="$BOOTDIR/transfer-station"

exec > >(tee -a "$PAYLOAD/firstrun.log") 2>&1
echo "=== firstrun stage A $(date -u) ==="

# shellcheck disable=SC1091
. "$PAYLOAD/config.env"

# bootstrap writes the password base64-encoded so it is safe for both bash and
# PowerShell to carry; decode it back if present.
if [ -n "${PI_PASSWORD_B64:-}" ]; then
    PI_PASSWORD="$(printf '%s' "$PI_PASSWORD_B64" | base64 -d)"
fi

# --- account -------------------------------------------------------------
if ! id -u "$PI_USER" >/dev/null 2>&1; then
    # Bookworm images ship with no user at all; create ours from scratch.
    adduser --disabled-password --gecos "" "$PI_USER"
fi
if [ -n "${PI_PASSWORD:-}" ]; then
    echo "${PI_USER}:${PI_PASSWORD}" | chpasswd
fi
# Hardware access + admin. Some groups only exist on Pi images; ignore misses.
for grp in sudo adm gpio dialout i2c spi video plugdev netdev; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" "$PI_USER"
done
echo "${PI_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/010_${PI_USER}-nopasswd"
chmod 440 "/etc/sudoers.d/010_${PI_USER}-nopasswd"

if [ -n "${PI_SSH_PUBKEY:-}" ]; then
    install -d -m 700 -o "$PI_USER" -g "$PI_USER" "/home/${PI_USER}/.ssh"
    echo "$PI_SSH_PUBKEY" > "/home/${PI_USER}/.ssh/authorized_keys"
    chmod 600 "/home/${PI_USER}/.ssh/authorized_keys"
    chown "${PI_USER}:${PI_USER}" "/home/${PI_USER}/.ssh/authorized_keys"
fi

# --- identity ------------------------------------------------------------
CURRENT_HOST="$(cat /etc/hostname | tr -d '[:space:]')"
echo "$PI_HOSTNAME" > /etc/hostname
sed -i "s/127\.0\.1\.1.*${CURRENT_HOST}/127.0.1.1\t${PI_HOSTNAME}/" /etc/hosts
[ -n "${TIMEZONE:-}" ] && ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

# SSH is the only way back in once the Pi is on the isolated switch.
systemctl enable ssh

# --- repository ----------------------------------------------------------
install -d -o "$PI_USER" -g "$PI_USER" "$REPO_DEST"
tar -xzf "$PAYLOAD/repo.tar.gz" -C "$REPO_DEST"
chown -R "${PI_USER}:${PI_USER}" "$REPO_DEST"

# --- arm stage B ---------------------------------------------------------
install -m 700 "$PAYLOAD/provision.sh" /usr/local/sbin/transfer-station-provision
install -m 644 "$PAYLOAD/config.env" /usr/local/share/transfer-station-config.env 2>/dev/null \
    || { install -d /usr/local/share; install -m 644 "$PAYLOAD/config.env" /usr/local/share/transfer-station-config.env; }
install -m 644 "$PAYLOAD/transfer-station.service" /usr/local/share/transfer-station.service.tmpl

cat > /etc/systemd/system/transfer-station-provision.service <<'UNIT'
[Unit]
Description=Transfer Station one-shot provisioning (needs internet)
# cloud-final.service is only present on cloud-init images (Raspberry Pi
# Imager writes user-data on current releases); ordering after a unit that
# does not exist is a no-op. Where it does exist this keeps us off cloud-init's
# apt lock and lets it finish its own account/network setup before we run.
After=network-online.target cloud-final.service
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/transfer-station-provision

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/transfer-station-provision
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable transfer-station-provision.service

# --- disarm stage A ------------------------------------------------------
# Strip our additions from cmdline.txt so this never runs again, and remove
# the script (it holds PI_PASSWORD in plaintext on a FAT partition).
sed -i 's| systemd\.run=[^ ]*||g; s| systemd\.run_success_action=[^ ]*||g; s| systemd\.unit=[^ ]*||g' \
    "$BOOTDIR/cmdline.txt"
rm -f "$PAYLOAD/firstrun.sh" "$PAYLOAD/repo.tar.gz"
# Stage A worked, so the pre-hashed recovery login is no longer needed.
rm -f "$BOOTDIR/userconf.txt"
sed -i 's/^PI_PASSWORD=.*/PI_PASSWORD=<redacted>/' "$PAYLOAD/config.env"

echo "=== stage A complete, rebooting into stage B ==="
sync
exit 0
