#!/usr/bin/env bash
# Native functional smoke test for the real Flask app and A4988 driver. Only
# RPi.GPIO is shimmed; Redis, Flask, routing, caching and motor logic are real.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

STUB="$(mktemp -d)"
GPIO_LOG="$(mktemp)"
SWITCHES="$(mktemp)"
SERVER_LOG="$(mktemp)"
REDIS_LOG="$(mktemp)"
SERVER_PID=""
REDIS_PID=""
cleanup() {
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
    [ -z "$REDIS_PID" ] || kill "$REDIS_PID" 2>/dev/null || true
    rm -rf "$STUB" "$GPIO_LOG" "$SWITCHES" "$SERVER_LOG" "$REDIS_LOG"
}
trap cleanup EXIT

mkdir -p "$STUB/RPi"
: > "$STUB/RPi/__init__.py"
cat > "$STUB/RPi/GPIO.py" <<'PY'
import os
BCM = 11; BOARD = 10; OUT = 0; IN = 1; HIGH = 1; LOW = 0; PUD_UP = 22
def setmode(*a, **k): pass
def setwarnings(*a, **k): pass
def setup(*a, **k): pass
def output(pin, value):
    with open(os.environ['TS_GPIO_LOG'], 'a') as log:
        log.write(f'{pin}:{value}\n')
# Limit switches: each line of TS_GPIO_SWITCHES is "<pin> <n>", meaning that
# pin reads HIGH (pressed) once n step pulses have been logged. Pins not listed
# read LOW (closed, not pressed).
def input(pin):
    with open(os.environ['TS_GPIO_SWITCHES']) as f:
        trips = dict(map(int, line.split()) for line in f if line.strip())
    if pin not in trips:
        return LOW
    with open(os.environ['TS_GPIO_LOG']) as log:
        pulses = log.read().count('23:True')
    return HIGH if pulses >= trips[pin] else LOW
def cleanup(*a, **k): pass
PY

if ! redis-cli ping >/dev/null 2>&1; then
    redis-server --save '' --appendonly no >"$REDIS_LOG" 2>&1 &
    REDIS_PID=$!
fi
for _ in $(seq 1 30); do
    redis-cli ping >/dev/null 2>&1 && break
    sleep 1
done
redis-cli ping >/dev/null 2>&1 || { cat "$REDIS_LOG"; exit 1; }
redis-cli flushdb >/dev/null

PORT=15000
cd "$ROOT"
env PYTHONPATH="$STUB" TS_GPIO_LOG="$GPIO_LOG" TS_GPIO_SWITCHES="$SWITCHES" \
    .venv/bin/flask --app api_step_motor run --host=127.0.0.1 --port="$PORT" \
    >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
    sleep 1
done

URL="http://127.0.0.1:${PORT}"

# Set which switches are pressed: switches "<pin> <after n steps>" ...
switches() { : > "$SWITCHES"; for s in "$@"; do echo "$s" >> "$SWITCHES"; done; }

# A raw command as the Hamilton sends it: requests.post(url, data='go_right')
# sends no Content-Type, so curl's form default is removed. Prints
# "<json body><http code>".
send() {
    : > "$GPIO_LOG"
    curl -s -w ' %{http_code}' -X POST -H 'Content-Type:' --data-binary "$1" \
        "$URL/" | tr -d ' \n'
}

# A browser button press with a step limit. Prints the http code.
press() {
    : > "$GPIO_LOG"
    curl -s -o /dev/null -w '%{http_code}' -X POST \
        -d "$1&step_num=$2&step_delay=0" "$URL/"
}

it "the real motor server responds"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$URL/")"
assert_eq "$CODE" "200"

it "Redis-backed motor state starts idle"
assert_eq "$(curl -fsS "$URL/status")" "False"

it "Go Right that never reaches its switch is reported as a failure"
switches
assert_eq "$(press 'go_right=Go Right' 2)" "500"

PINS="$(cat "$GPIO_LOG")"
it "command drives clockwise direction"
assert_contains "$PINS" "22:True"
it "command enables and disables the driver"
assert_contains "$PINS" "24:0"
assert_contains "$PINS" "24:1"
it "command emits high and low step pulses"
assert_contains "$PINS" "23:True"
assert_contains "$PINS" "23:False"
it "server returns to idle after motion"
assert_eq "$(curl -fsS "$URL/status")" "False"

it "Hamilton go_right stops at the right switch and reports success"
switches "17 3"
assert_eq "$(send go_right)" '{"result":"reached_right","steps":3}200'
assert_eq "$(count_in_file "$GPIO_LOG" "23:True")" "3"

it "Hamilton go_left stops at the left switch and reports success"
switches "4 5"
assert_eq "$(send go_left)" '{"result":"reached_left","steps":5}200'

it "a move toward a switch already pressed succeeds without stepping"
switches "17 0"
assert_eq "$(send go_right)" '{"result":"reached_right","steps":0}200'
assert_eq "$(count_in_file "$GPIO_LOG" "23:True")" "0"

it "the switch at the far end does not stop a move away from it"
switches "4 0"
assert_eq "$(press 'go_right=Go Right' 5)" "500"
assert_eq "$(count_in_file "$GPIO_LOG" "23:True")" "5"

it "Run Motor stops at the switch in its direction of travel"
switches "17 2"
assert_eq "$(press 'run_motor=Run Motor&direction=True' 10)" "200"
assert_eq "$(count_in_file "$GPIO_LOG" "23:True")" "2"

it "Run Motor that runs all its steps is not a failure"
switches
assert_eq "$(press 'run_motor=Run Motor&direction=False' 4)" "200"

it "both switches pressed is a wiring fault and the motor does not move"
switches "4 0" "17 0"
assert_eq "$(send go_right)" '{"result":"switch_fault","steps":0}500'
assert_eq "$(count_in_file "$GPIO_LOG" "23:True")" "0"

it "/position reports neither switch pressed"
switches
assert_eq "$(curl -fsS "$URL/position" | tr -d ' \n')" \
    '{"at_left":false,"at_right":false,"moving":false}'

it "/position reports a pressed switch"
switches "17 0"
assert_eq "$(curl -fsS "$URL/position" | tr -d ' \n')" \
    '{"at_left":false,"at_right":true,"moving":false}'

it "Stop Motor command is accepted"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -d 'stop_motor=Stop Motor' "$URL/")"
assert_eq "$CODE" "200"

it "a Stop pressed while idle does not cancel the next move"
switches "17 2"
assert_eq "$(send go_right)" '{"result":"reached_right","steps":2}200'

summary
