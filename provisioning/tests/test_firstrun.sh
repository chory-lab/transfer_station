#!/usr/bin/env bash
# Executes stage A (firstrun.sh) for real against a simulated boot partition.
#
# DESTRUCTIVE: creates users, rewrites /etc/hostname, writes to /etc/systemd.
# Intended to run inside a disposable container. Refuses to run without
# TS_ALLOW_DESTRUCTIVE=1.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

if [ "${TS_ALLOW_DESTRUCTIVE:-0}" != "1" ]; then
    echo "refusing to run: set TS_ALLOW_DESTRUCTIVE=1 (container only)" >&2
    exit 2
fi

# --- record systemctl calls instead of executing them ---------------------
SHIMBIN=/usr/local/bin
SYSCTL_LOG=/tmp/systemctl.calls
: > "$SYSCTL_LOG"
cat > "$SHIMBIN/systemctl" <<'SHIM'
#!/bin/sh
echo "$@" >> /tmp/systemctl.calls
exit 0
SHIM
chmod +x "$SHIMBIN/systemctl"

# The real image has these; a bare container may not.
groupadd -f gpio; groupadd -f dialout; groupadd -f i2c; groupadd -f spi
echo "raspberrypi" > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' > /etc/hosts

# --- build the boot partition exactly as flash.sh leaves it ---------------
BOOTDIR="${TS_BOOTDIR:-/boot/firmware}"
mkdir -p "$BOOTDIR"
# TS_KEEP_BOOT=1 means we are running against a real Raspberry Pi OS boot
# partition, so keep its genuine cmdline.txt/issue.txt instead of synthesising.
if [ "${TS_KEEP_BOOT:-0}" != "1" ]; then
    "$HERE/make-fake-boot.sh" "$BOOTDIR" bookworm
fi

cp "$BOOTDIR/cmdline.txt" "$BOOTDIR/cmdline.txt.orig"

SHIM_SUDO="$(mktemp -d)"
printf '#!/bin/sh\nexec "$@"\n' > "$SHIM_SUDO/sudo"; chmod +x "$SHIM_SUDO/sudo"
PATH="$SHIM_SUDO:$PATH" bash "$PROV/flash.sh" --boot "$BOOTDIR" >/tmp/flash.log 2>&1 \
    || { cat /tmp/flash.log; exit 1; }

# Remember what cmdline.txt looked like before flash.sh touched it, so the
# "original parameters preserved" assertion works against any image.
CMDLINE_BEFORE="$(tr -d '
' < "$BOOTDIR/cmdline.txt.orig" 2>/dev/null                   || tr -d '
' < "$BOOTDIR/cmdline.txt")"

PAYLOAD="$BOOTDIR/transfer-station"
# shellcheck disable=SC1091
. "$PAYLOAD/config.env"

echo "== running stage A =="
bash "$PAYLOAD/firstrun.sh" >/tmp/firstrun.out 2>&1
RC=$?
it "firstrun.sh exits 0 (systemd.run_success_action=reboot depends on it)"
assert_eq "$RC" "0"
[ "$RC" -eq 0 ] || { cat /tmp/firstrun.out; }

echo
echo "== account =="
it "creates the ${PI_USER} account"
if id -u "$PI_USER" >/dev/null 2>&1; then pass; else fail "user ${PI_USER} not created"; fi

it "adds ${PI_USER} to the gpio group"
assert_contains "$(id -nG "$PI_USER" 2>/dev/null)" "gpio"

it "adds ${PI_USER} to the dialout group"
assert_contains "$(id -nG "$PI_USER" 2>/dev/null)" "dialout"

it "installs a passwordless sudoers rule"
assert_file "/etc/sudoers.d/010_${PI_USER}-nopasswd"

it "sudoers rule has mode 0440"
assert_eq "$(stat -c '%a' "/etc/sudoers.d/010_${PI_USER}-nopasswd" 2>/dev/null)" "440"

it "sudoers rule passes visudo"
if visudo -cf "/etc/sudoers.d/010_${PI_USER}-nopasswd" >/dev/null 2>&1; then pass
else fail "visudo rejected the generated sudoers file"; fi

echo
echo "== identity =="
it "sets the hostname"
assert_eq "$(cat /etc/hostname | tr -d '[:space:]')" "$PI_HOSTNAME"

it "rewrites the 127.0.1.1 entry in /etc/hosts"
assert_contains "$(cat /etc/hosts)" "$PI_HOSTNAME"

it "enables ssh"
assert_contains "$(cat "$SYSCTL_LOG")" "enable ssh"

echo
echo "== repository =="
it "extracts the app to REPO_DEST"
assert_file "${REPO_DEST}/api_step_motor.py"

it "extracts the templates to the path the app hardcodes"
assert_file "${REPO_DEST}/templates/buttons.html"

it "repo is owned by ${PI_USER}"
assert_eq "$(stat -c '%U' "${REPO_DEST}/api_step_motor.py" 2>/dev/null)" "$PI_USER"

echo
echo "== stage B is armed =="
it "installs the provisioning unit"
assert_file "/etc/systemd/system/transfer-station-provision.service"

it "enables the provisioning unit"
assert_contains "$(cat "$SYSCTL_LOG")" "enable transfer-station-provision.service"

it "provisioning unit waits for the network"
assert_contains "$(cat /etc/systemd/system/transfer-station-provision.service)" "After=network-online.target"

it "stashes config.env where stage B reads it"
assert_file "/usr/local/share/transfer-station-config.env"

it "stashed config.env still carries the real settings"
assert_contains "$(cat /usr/local/share/transfer-station-config.env)" "ETH_ADDRESS=192.168.10.1"

it "stashes the service template"
assert_file "/usr/local/share/transfer-station.service.tmpl"

it "installs the stage B script as executable"
if [ -x /usr/local/sbin/transfer-station-provision ]; then pass; else fail "not executable"; fi

echo
echo "== stage A disarms itself =="
it "strips systemd.run from cmdline.txt"
assert_not_contains "$(cat "$BOOTDIR/cmdline.txt")" "systemd.run="

it "strips systemd.unit from cmdline.txt"
assert_not_contains "$(cat "$BOOTDIR/cmdline.txt")" "systemd.unit="

it "restores cmdline.txt to exactly its pre-flash contents"
assert_eq "$(tr -d '
' < "$BOOTDIR/cmdline.txt")" "$CMDLINE_BEFORE"

it "cmdline.txt is still a single line"
assert_eq "$(wc -l < "$BOOTDIR/cmdline.txt" | tr -d ' ')" "1"

it "deletes firstrun.sh from the boot partition"
assert_no_file "$PAYLOAD/firstrun.sh"

it "deletes the repo tarball from the boot partition"
assert_no_file "$PAYLOAD/repo.tar.gz"

it "removes the userconf.txt fallback once stage A has succeeded"
assert_no_file "$BOOTDIR/userconf.txt"

it "redacts the password left on the FAT partition"
assert_not_contains "$(cat "$PAYLOAD/config.env")" "PI_PASSWORD=changeme"

summary
