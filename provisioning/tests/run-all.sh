#!/usr/bin/env bash
# Runs every test that is safe in the current environment.
#
#   ./run-all.sh              # host-safe tests only
#   ./run-all.sh --container  # also the destructive stage A/B/deploy chain
#
# The destructive tests create users and rewrite /etc; they refuse to run
# without TS_ALLOW_DESTRUCTIVE=1 and are meant for a disposable container.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

run() {
    echo
    echo "############################################################"
    echo "# $1"
    echo "############################################################"
    shift
    "$@" || FAILED=1
}

run "flash.sh injection (no privileges required)" \
    bash "$HERE/test_flash_inject.sh"

if [ "$(id -u)" -eq 0 ] && command -v losetup >/dev/null 2>&1; then
    run "flash.sh full image write (loopback SD card)" \
        bash "$HERE/test_flash_image.sh"
else
    echo; echo "SKIP: loopback image test (needs root + losetup)"
fi

if [ "${1:-}" = "--container" ]; then
    export TS_ALLOW_DESTRUCTIVE=1
    run "stage A: firstrun.sh"            bash "$HERE/test_firstrun.sh"
    run "stage B: provision.sh"           env TS_CI=1 bash /usr/local/sbin/transfer-station-provision
    run "deployment: unit, network, HTTP" bash "$HERE/test_deploy.sh"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL SUITES PASSED"; else echo "SOME SUITES FAILED"; fi
exit "$FAILED"
