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
SERVER_LOG="$(mktemp)"
REDIS_LOG="$(mktemp)"
SERVER_PID=""
REDIS_PID=""
cleanup() {
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
    [ -z "$REDIS_PID" ] || kill "$REDIS_PID" 2>/dev/null || true
    rm -rf "$STUB" "$GPIO_LOG" "$SERVER_LOG" "$REDIS_LOG"
}
trap cleanup EXIT

mkdir -p "$STUB/RPi"
: > "$STUB/RPi/__init__.py"
cat > "$STUB/RPi/GPIO.py" <<'PY'
import os
BCM = 11; BOARD = 10; OUT = 0; IN = 1; HIGH = 1; LOW = 0
def setmode(*a, **k): pass
def setwarnings(*a, **k): pass
def setup(*a, **k): pass
def output(pin, value):
    with open(os.environ['TS_GPIO_LOG'], 'a') as log:
        log.write(f'{pin}:{value}\n')
def input(*a, **k): return 1
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
env PYTHONPATH="$STUB" TS_GPIO_LOG="$GPIO_LOG" \
    .venv/bin/flask --app api_step_motor run --host=127.0.0.1 --port="$PORT" \
    >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
    sleep 1
done

it "the real motor server responds"
CODE="$(curl -s -o /tmp/motor-index.html -w '%{http_code}' "http://127.0.0.1:${PORT}/")"
assert_eq "$CODE" "200"

it "Redis-backed motor state starts idle"
assert_eq "$(curl -fsS "http://127.0.0.1:${PORT}/status")" "False"

it "Go Right command is accepted"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -d 'go_right=Go Right&step_num=2&step_delay=0' \
    "http://127.0.0.1:${PORT}/")"
assert_eq "$CODE" "200"

PINS="$(cat "$GPIO_LOG")"
it "command drives clockwise direction"
assert_contains "$PINS" "22:True"
it "command enables and disables the driver"
assert_contains "$PINS" "24:0"
assert_contains "$PINS" "24:1"
it "command emits high and low step pulses"
assert_contains "$PINS" "23:1"
assert_contains "$PINS" "23:0"
it "server returns to idle after motion"
assert_eq "$(curl -fsS "http://127.0.0.1:${PORT}/status")" "False"

it "Stop Motor command is accepted"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -d 'stop_motor=Stop Motor' "http://127.0.0.1:${PORT}/")"
assert_eq "$CODE" "200"

summary
