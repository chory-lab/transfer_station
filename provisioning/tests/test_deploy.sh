#!/usr/bin/env bash
# Post-provision deployment checks: the generated systemd unit, the isolated
# network profile, and whether the Flask server actually serves a request
# using the unit's real ExecStart command line.
#
# Run inside a container AFTER provision.sh has completed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

if [ "${TS_ALLOW_DESTRUCTIVE:-0}" != "1" ]; then
    echo "refusing to run: set TS_ALLOW_DESTRUCTIVE=1 (container only)" >&2
    exit 2
fi

CONFIG=/usr/local/share/transfer-station-config.env
[ -f "$CONFIG" ] || CONFIG=/src/provisioning/config.env
# shellcheck disable=SC1090
. "$CONFIG"

UNIT=/etc/systemd/system/transfer-station.service
KEYFILE="/etc/NetworkManager/system-connections/${ETH_IFACE}-isolated.nmconnection"

echo "== systemd unit =="
it "unit is installed"; assert_file "$UNIT"

it "runs as ${PI_USER}, not root"
assert_contains "$(cat "$UNIT")" "User=${PI_USER}"

it "binds the configured port"
assert_contains "$(cat "$UNIT")" "--port=${SERVER_PORT}"

it "binds all interfaces (the isolated NIC included)"
assert_contains "$(cat "$UNIT")" "--host=0.0.0.0"

it "uses the uv-built venv interpreter"
assert_contains "$(cat "$UNIT")" "${REPO_DEST}/.venv/bin/flask"

it "no unsubstituted template placeholders remain"
assert_not_contains "$(cat "$UNIT")" "__"

it "requires redis (flask-caching backend is RedisCache)"
assert_contains "$(cat "$UNIT")" "Requires=redis-server.service"

it "restarts if the server dies mid-run"
assert_contains "$(cat "$UNIT")" "Restart=on-failure"

it "is wanted by multi-user.target so it starts at boot"
assert_contains "$(cat "$UNIT")" "WantedBy=multi-user.target"

echo
echo "== isolated network profile =="
it "keyfile exists"; assert_file "$KEYFILE"

if [ -f "$KEYFILE" ]; then
    KF="$(cat "$KEYFILE")"
    it "static address matches config.env"
    assert_contains "$KF" "address1=${ETH_ADDRESS}/${ETH_PREFIX}"

    it "method is manual, not auto/DHCP"
    assert_contains "$KF" "method=manual"

    it "NO gateway -- this is what keeps it off the lab LAN"
    assert_not_contains "$KF" "gateway="

    it "NO dns"
    if grep -q '^dns=' "$KEYFILE"; then fail "found a dns= line"; else pass; fi

    it "never-default stops it becoming the default route"
    assert_contains "$KF" "never-default=true"

    it "bound to the configured interface"
    assert_contains "$KF" "interface-name=${ETH_IFACE}"

    it "ipv6 disabled (no SLAAC path onto the LAN)"
    assert_contains "$KF" "method=disabled"

    it "keyfile is mode 0600 (NetworkManager refuses to load it otherwise)"
    assert_eq "$(stat -c '%a' "$KEYFILE")" "600"

    it "parses as a valid keyfile (INI)"
    if python3 -c "
import configparser, sys
c = configparser.ConfigParser()
c.read('$KEYFILE')
assert 'connection' in c and 'ipv4' in c, 'missing required sections'
" 2>/dev/null; then pass; else fail "keyfile is not parseable INI"; fi

    it "NM's auto-generated DHCP profile was removed"
    if compgen -G "/etc/NetworkManager/system-connections/Wired connection*" >/dev/null; then
        fail "a 'Wired connection' profile survived and may win over ours"
    else pass; fi
fi

echo
echo "== server smoke test =="
# RPi.GPIO raises on non-Pi hardware, so shim it. PYTHONPATH is searched
# before site-packages, so this shadows the apt-installed module.
STUB=/tmp/gpio-stub
mkdir -p "$STUB/RPi"
cat > "$STUB/RPi/__init__.py" <<'PY'
PY
cat > "$STUB/RPi/GPIO.py" <<'PY'
BCM = 11; BOARD = 10; OUT = 0; IN = 1; HIGH = 1; LOW = 0
def setmode(*a, **k): pass
def setwarnings(*a, **k): pass
def setup(*a, **k): pass
def output(*a, **k): pass
def input(*a, **k): return 1
def cleanup(*a, **k): pass
PY
chmod -R a+rX "$STUB"

redis-server --daemonize yes --save '' >/dev/null 2>&1
for _ in $(seq 1 20); do redis-cli ping >/dev/null 2>&1 && break; sleep 0.5; done

it "redis is answering"
assert_eq "$(redis-cli ping 2>/dev/null)" "PONG"

# Run the unit's ACTUAL ExecStart line, so a broken command is caught here.
EXECSTART="$(grep '^ExecStart=' "$UNIT" | cut -d= -f2-)"
echo "  ExecStart: $EXECSTART"

cd "$REPO_DEST"
env PYTHONPATH="$STUB" runuser -u "$PI_USER" -- \
    env PYTHONPATH="$STUB" $EXECSTART >/tmp/server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:${SERVER_PORT}/" >/dev/null 2>&1 && break
    sleep 1
done

it "server responds 200 on /"
CODE="$(curl -s -o /tmp/index.html -w '%{http_code}' "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null)"
assert_eq "$CODE" "200"
[ "$CODE" = "200" ] || { echo "--- server log ---"; cat /tmp/server.log; }

it "serves the control UI from the hardcoded templates path"
assert_contains "$(cat /tmp/index.html 2>/dev/null)" "Run Motor"

it "/status endpoint works (redis-backed cache is wired up)"
STATUS="$(curl -fsS "http://127.0.0.1:${SERVER_PORT}/status" 2>/dev/null)"
assert_eq "$STATUS" "False"

it "Stop Motor POST is accepted"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -d 'stop_motor=Stop Motor' "http://127.0.0.1:${SERVER_PORT}/" 2>/dev/null)"
assert_eq "$CODE" "200"

echo
echo "== step rate sanity =="
# Guards the fix for the 5e-14 s default. Both the high and low phase sleep
# for step_delay, so the true step period is 2*step_delay.
it "default step_delay keeps the A4988 inside its pull-in region"
python3 - "$REPO_DEST" <<'PY' && pass || fail "default step_delay is outside 100-1000 full steps/s"
import re, sys
src = open(sys.argv[1] + '/api_step_motor.py').read()
m = re.search(r'step_delay\s*=\s*([0-9.eE+-]+)\s*$', src, re.M)
assert m, "could not find the step_delay default"
d = float(m.group(1))
full_sps = 1.0 / (2 * d) / 2      # half-stepping: 2 half-steps per full step
print(f"  step_delay={d} -> {full_sps:.0f} full steps/s")
sys.exit(0 if 100 <= full_sps <= 1000 else 1)
PY

summary
