#!/usr/bin/env bash
# Exercises flash.sh --boot against synthetic boot partitions and asserts the
# properties that decide whether the Pi actually boots.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

# flash.sh calls sudo throughout. Provide a transparent shim so these tests
# run unprivileged, in containers, and on macOS alike.
SHIMBIN="$(mktemp -d)"
printf '#!/bin/sh\nexec "$@"\n' > "$SHIMBIN/sudo"
chmod +x "$SHIMBIN/sudo"
export PATH="$SHIMBIN:$PATH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$SHIMBIN"' EXIT

flash_into() {  # flash_into <boot-dir>
    ( cd "$PROV/.." && bash "$PROV/flash.sh" --boot "$1" ) >"$WORK/out.log" 2>&1
}

echo "== cmdline.txt hook (bookworm) =="
BOOT="$WORK/bw"; bash "$HERE/make-fake-boot.sh" "$BOOT" bookworm
flash_into "$BOOT" || { cat "$WORK/out.log"; exit 1; }
CMDLINE="$(cat "$BOOT/cmdline.txt")"

it "appends the systemd.run hook"
assert_contains "$CMDLINE" "systemd.run=/boot/firmware/transfer-station/firstrun.sh"

it "sets reboot as the success action"
assert_contains "$CMDLINE" "systemd.run_success_action=reboot"

it "targets kernel-command-line.target"
assert_contains "$CMDLINE" "systemd.unit=kernel-command-line.target"

it "preserves the original kernel parameters"
assert_contains "$CMDLINE" "root=PARTUUID=1a2b3c4d-02"

it "cmdline.txt stays exactly one line"
assert_eq "$(wc -l < "$BOOT/cmdline.txt" | tr -d ' ')" "1"

it "cmdline.txt has no embedded CR"
if has_cr "$BOOT/cmdline.txt"; then fail "found CR in cmdline.txt"; else pass; fi

echo
echo "== release detection =="
BOOT_BULLSEYE="$WORK/be"; bash "$HERE/make-fake-boot.sh" "$BOOT_BULLSEYE" bullseye
flash_into "$BOOT_BULLSEYE" || { cat "$WORK/out.log"; exit 1; }
it "bullseye uses the /boot mount path"
assert_contains "$(cat "$BOOT_BULLSEYE/cmdline.txt")" "systemd.run=/boot/transfer-station/firstrun.sh"

it "bullseye does NOT use the /boot/firmware path"
assert_not_contains "$(cat "$BOOT_BULLSEYE/cmdline.txt")" "/boot/firmware/"

BOOT_NONE="$WORK/none"; bash "$HERE/make-fake-boot.sh" "$BOOT_NONE" none
flash_into "$BOOT_NONE" || { cat "$WORK/out.log"; exit 1; }
it "missing issue.txt falls back to the /boot path"
assert_contains "$(cat "$BOOT_NONE/cmdline.txt")" "systemd.run=/boot/transfer-station/firstrun.sh"

echo
echo "== idempotence =="
flash_into "$BOOT" || { cat "$WORK/out.log"; exit 1; }
flash_into "$BOOT" || { cat "$WORK/out.log"; exit 1; }
it "re-flashing does not duplicate systemd.run"
assert_eq "$(count_in_file "$BOOT/cmdline.txt" "systemd.run=")" "1"

it "re-flashing does not duplicate systemd.unit"
assert_eq "$(count_in_file "$BOOT/cmdline.txt" "systemd.unit=")" "1"

it "re-flashing still leaves exactly one line"
assert_eq "$(wc -l < "$BOOT/cmdline.txt" | tr -d ' ')" "1"

# verify-card decides the card's phase from whether firstrun.log is present,
# so a log left over from a previous boot makes a freshly armed card report
# "stage A started but did NOT complete".
echo "old stage A output" > "$BOOT/transfer-station/firstrun.log"
echo "old stage B output" > "$BOOT/transfer-station/provision.log"
flash_into "$BOOT" || { cat "$WORK/out.log"; exit 1; }

it "re-flashing clears the previous firstrun.log"
assert_no_file "$BOOT/transfer-station/firstrun.log"

it "re-flashing clears the previous provision.log"
assert_no_file "$BOOT/transfer-station/provision.log"

it "the previous firstrun.log is kept as .prev"
assert_contains "$(cat "$BOOT/transfer-station/firstrun.log.prev")" "old stage A output"

it "the previous provision.log is kept as .prev"
assert_contains "$(cat "$BOOT/transfer-station/provision.log.prev")" "old stage B output"

echo
echo "== payload staging =="
it "firstrun.sh is present"      ; assert_file "$BOOT/transfer-station/firstrun.sh"
it "provision.sh is present"     ; assert_file "$BOOT/transfer-station/provision.sh"
it "service template is present" ; assert_file "$BOOT/transfer-station/transfer-station.service"
it "config.env is present"       ; assert_file "$BOOT/transfer-station/config.env"
it "repo tarball is present"     ; assert_file "$BOOT/transfer-station/repo.tar.gz"

# Recovery net: if the boot hook never fires, these are the only way back in.
it "writes the ssh flag file so sshd comes up even if stage A never runs"
assert_file "$BOOT/ssh"

it "writes a userconf.txt fallback login"
assert_file "$BOOT/userconf.txt"

it "userconf.txt holds a sha512-crypt hash, not a plaintext password"
assert_contains "$(cat "$BOOT/userconf.txt")" "chorylab:\$6\$"

it "userconf.txt does not leak the plaintext password"
assert_not_contains "$(cat "$BOOT/userconf.txt")" "changeme"

# CRLF in firstrun.sh breaks the shebang and the Pi silently fails to provision.
for f in firstrun.sh provision.sh config.env; do
    it "$f has LF line endings only"
    if has_cr "$BOOT/transfer-station/$f"; then fail "found CR in $f"; else pass; fi
done

it "writes a build timestamp for the clock fix"
assert_file "$BOOT/transfer-station/buildstamp"

it "buildstamp is a plausible unix epoch"
STAMP="$(cat "$BOOT/transfer-station/buildstamp" 2>/dev/null | tr -d '[:space:]')"
if [ -n "$STAMP" ] && [ "$STAMP" -gt 1700000000 ] 2>/dev/null; then pass
else fail "buildstamp is [$STAMP]"; fi

it "no leftover temp tarball on the boot partition"
assert_no_file "$BOOT/.repo.tar.gz.tmp"

echo
echo "== repo tarball contents =="
LIST="$(tar -tzf "$BOOT/transfer-station/repo.tar.gz")"
it "includes the flask app"      ; assert_contains "$LIST" "./api_step_motor.py"
it "includes the driver"         ; assert_contains "$LIST" "./A4988.py"
it "includes the templates"      ; assert_contains "$LIST" "./templates/buttons.html"
it "includes requirements.txt"   ; assert_contains "$LIST" "./requirements.txt"
it "excludes the stale venv"     ; assert_not_contains "$LIST" "./foobar/"
it "excludes .git"               ; assert_not_contains "$LIST" "./.git/"
it "excludes provisioning/"      ; assert_not_contains "$LIST" "./provisioning/"
it "excludes the 3D files"       ; assert_not_contains "$LIST" "./3D Files/"
it "excludes the redis dump"     ; assert_not_contains "$LIST" "./dump.rdb"

echo
echo "== argument validation =="
it "rejects a directory that is not a boot partition"
mkdir -p "$WORK/notboot"
if ( cd "$PROV/.." && bash "$PROV/flash.sh" --boot "$WORK/notboot" ) >/dev/null 2>&1; then
    fail "should have refused a directory with no cmdline.txt"
else pass; fi

it "rejects --device without --image"
if ( cd "$PROV/.." && bash "$PROV/flash.sh" --device /dev/null ) >/dev/null 2>&1; then
    fail "should have refused --device without --image"
else pass; fi

it "rejects an unknown argument"
if ( cd "$PROV/.." && bash "$PROV/flash.sh" --nonsense ) >/dev/null 2>&1; then
    fail "should have refused an unknown argument"
else pass; fi

summary
