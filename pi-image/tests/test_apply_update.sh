#!/usr/bin/env bash
# Runs update-pi.sh end to end against a fake Pi: ssh and scp run locally,
# with the Pi's /tmp mapped to a scratch directory, and sudo, systemctl and
# journalctl are stubs. apply-update.sh itself runs for real.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAILED=0
ok()   { printf '  ok:   %s\n' "$1"; }
bad()  { printf '  FAIL: %s\n' "$1"; FAILED=$((FAILED + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

mkdir -p "$T/bin" "$T/pitmp"
cat > "$T/bin/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
cat > "$T/bin/systemctl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_SYSTEMCTL_LOG"
case "$1" in
    cat) [ -z "${FAKE_NO_SERVICE:-}" ] ;;
    *) exit 0 ;;
esac
SH
cat > "$T/bin/journalctl" <<'SH'
#!/usr/bin/env bash
echo "fake journal"
SH
# scp -q -r SRC HOST:/tmp/  ->  copy SRC into the fake Pi's /tmp
cat > "$T/bin/scp" <<'SH'
#!/usr/bin/env bash
cp -R "$3" "$FAKE_PI_TMP/"
SH
# ssh -t HOST COMMAND  ->  run COMMAND here, with /tmp/ mapped
cat > "$T/bin/ssh" <<'SH'
#!/usr/bin/env bash
cmd="$3"
exec bash -c "${cmd//\/tmp\//$FAKE_PI_TMP/}"
SH
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH"
export FAKE_PI_TMP="$T/pitmp"
export FAKE_SYSTEMCTL_LOG="$T/systemctl.log"
export TS_REPO_DEST="$T/pi/transfer_station"
export TS_BACKUPS="$T/pi/backups"
export TS_HEALTH_URL="file://$T/health"
export TS_HEALTH_WAIT=2

# A Pi running an older version of the app, with the same dependencies
reset_pi() {
    rm -rf "$T/pi" "$T/health" "$FAKE_SYSTEMCTL_LOG"
    mkdir -p "$TS_REPO_DEST/templates" "$TS_REPO_DEST/.venv"
    echo OLD > "$TS_REPO_DEST/A4988.py"
    echo OLD > "$TS_REPO_DEST/api_step_motor.py"
    echo OLD > "$TS_REPO_DEST/templates/buttons.html"
    echo venv > "$TS_REPO_DEST/.venv/marker"
    cp "$ROOT/pyproject.toml" "$ROOT/uv.lock" "$TS_REPO_DEST/"
    touch "$FAKE_SYSTEMCTL_LOG"
}
restarts() { grep -c '^restart transfer-station$' "$FAKE_SYSTEMCTL_LOG" || true; }

echo "a healthy update"
reset_pi
touch "$T/health"
check "update-pi.sh succeeds" bash -c "bash '$ROOT/pi-image/update-pi.sh' >/dev/null"
check "driver is replaced" cmp -s "$ROOT/A4988.py" "$TS_REPO_DEST/A4988.py"
check "server is replaced" cmp -s "$ROOT/api_step_motor.py" "$TS_REPO_DEST/api_step_motor.py"
check "templates are replaced" cmp -s "$ROOT/templates/buttons.html" "$TS_REPO_DEST/templates/buttons.html"
check "no macOS ._ files are installed" test -z "$(find "$TS_REPO_DEST" -name '._*')"
check "the service is restarted once" test "$(restarts)" = 1
check "one backup is kept" test "$(ls "$TS_BACKUPS" | wc -l | tr -d ' ')" = 1
check "the backup holds the old files" \
    test "$(tar -xzOf "$TS_BACKUPS"/*.tar.gz ./A4988.py)" = OLD
check "the backup leaves out the venv" \
    bash -c "! tar -tzf $TS_BACKUPS/*.tar.gz | grep -q venv"
check "the upload is removed from the Pi's /tmp" test -z "$(ls -A "$FAKE_PI_TMP")"

echo "an update whose server does not come up"
reset_pi
check "update-pi.sh fails" bash -c "! bash '$ROOT/pi-image/update-pi.sh' >/dev/null 2>&1"
check "the old driver is put back" test "$(cat "$TS_REPO_DEST/A4988.py")" = OLD
check "the old template is put back" test "$(cat "$TS_REPO_DEST/templates/buttons.html")" = OLD
check "the service is restarted again on the old files" test "$(restarts)" = 2

echo "an update that changes dependencies"
reset_pi
touch "$T/health"
echo "# changed" >> "$TS_REPO_DEST/uv.lock"
check "update-pi.sh refuses" bash -c "! bash '$ROOT/pi-image/update-pi.sh' >/dev/null 2>&1"
check "nothing is installed" test "$(cat "$TS_REPO_DEST/A4988.py")" = OLD
check "the service is not restarted" test "$(restarts)" = 0

echo "a Pi without the service"
reset_pi
touch "$T/health"
check "update-pi.sh refuses" \
    bash -c "! FAKE_NO_SERVICE=1 bash '$ROOT/pi-image/update-pi.sh' >/dev/null 2>&1"
check "nothing is installed" test "$(cat "$TS_REPO_DEST/A4988.py")" = OLD

echo "repeated updates"
reset_pi
touch "$T/health"
for _ in 1 2 3 4 5 6 7; do bash "$ROOT/pi-image/update-pi.sh" >/dev/null; done
check "only the newest 5 backups are kept" \
    test "$(ls "$TS_BACKUPS" | wc -l | tr -d ' ')" = 5

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED failed"
    exit 1
fi
echo "all passed"
