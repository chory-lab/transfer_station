#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Inspect a flashed SD card from the PC, without booting the Pi.
#
#   ./verify-card.sh /media/$USER/bootfs
#
# Run automatically at the end of bootstrap.sh. Run it again by hand after a
# first boot to see how far the Pi actually got -- both stages leave their
# logs on this partition, which mounts on any machine.
# ---------------------------------------------------------------------------
set -uo pipefail

BOOT="${1:-}"
[ -n "$BOOT" ] || { echo "usage: verify-card.sh <path-to-boot-partition>" >&2; exit 2; }
[ -f "$BOOT/cmdline.txt" ] || { echo "$BOOT is not a Raspberry Pi boot partition" >&2; exit 2; }

PAYLOAD="$BOOT/transfer-station"
[ -d "$PAYLOAD" ] || { echo "No transfer-station payload on this card." >&2; exit 2; }

RUN=0; BAD=0; WARN=0
_g() { printf '\033[32m%s\033[0m\n' "$*"; }
_r() { printf '\033[31m%s\033[0m\n' "$*"; }
_y() { printf '\033[33m%s\033[0m\n' "$*"; }
_d() { printf '\033[90m%s\033[0m\n' "$*"; }

check() {  # check <name> <0|1>
    RUN=$((RUN+1))
    if [ "$2" = "0" ]; then _g "  ok    $1"; else BAD=$((BAD+1)); _r "  FAIL  $1"; fi
}
note() { WARN=$((WARN+1)); _y "  note  $1"; }
info() { _d "  info  $1"; }
has()  { [ -f "$1" ] && echo 0 || echo 1; }
# CR detection via awk: $'' does not survive argument passing to grep on
# some platforms (git-bash), where it degenerates to an empty pattern that
# matches every line and reports false positives.
has_cr() { awk 'BEGIN{cr=sprintf("%c",13)} index($0,cr){f=1} END{exit !f}' "$1"; }

grep_q() { grep -q "$2" "$1" 2>/dev/null && echo 0 || echo 1; }

CMDLINE="$(cat "$BOOT/cmdline.txt")"

echo
echo "=== Card at $BOOT ==="

# Stage A deletes firstrun.sh when it succeeds, so it tells us the phase.
if [ -f "$PAYLOAD/firstrun.sh" ] && [ ! -f "$PAYLOAD/firstrun.log" ]; then
    PHASE=preboot;       echo "State: provisioned, not yet booted"
elif [ -f "$PAYLOAD/firstrun.sh" ]; then
    PHASE=stageA-failed; _y "State: stage A started but did NOT complete"
else
    PHASE=booted;        echo "State: stage A completed"
fi
echo

if [ "$PHASE" = "preboot" ]; then
    echo "Boot hook"
    RELEASE="$(cat "$BOOT/issue.txt" 2>/dev/null || true)"
    case "$RELEASE" in
        *bookworm*|*trixie*|*forky*) EXPECT=/boot/firmware/transfer-station/firstrun.sh ;;
        *)                           EXPECT=/boot/transfer-station/firstrun.sh ;;
    esac
    case "$CMDLINE" in *"systemd.run=$EXPECT"*) R=0 ;; *) R=1 ;; esac
    check "cmdline.txt points at $EXPECT" "$R"
    check "reboots after stage A"         "$(grep_q "$BOOT/cmdline.txt" 'systemd.run_success_action=reboot')"
    check "runs at kernel-command-line"   "$(grep_q "$BOOT/cmdline.txt" 'systemd.unit=kernel-command-line.target')"
    check "original kernel params intact" "$(grep_q "$BOOT/cmdline.txt" 'root=')"
    check "cmdline.txt is a single line"  "$([ "$(wc -l < "$BOOT/cmdline.txt")" -le 1 ] && echo 0 || echo 1)"
    check "cmdline.txt has no CR"         "$(has_cr "$BOOT/cmdline.txt" && echo 1 || echo 0)"
    [ -n "$RELEASE" ] && info "image: $(echo "$RELEASE" | head -1)"

    echo
    echo "Payload"
    for f in firstrun.sh provision.sh transfer-station.service config.env repo.tar.gz; do
        check "$f present" "$(has "$PAYLOAD/$f")"
    done
    # A CRLF here breaks the shebang and the Pi silently never provisions.
    for f in firstrun.sh provision.sh config.env; do
        [ -f "$PAYLOAD/$f" ] || continue
        check "$f has LF endings only" "$(has_cr "$PAYLOAD/$f" && echo 1 || echo 0)"
    done

    echo
    echo "Recovery access (used if the boot hook never fires)"
    check "ssh flag file present" "$(has "$BOOT/ssh")"
    check "userconf.txt present"  "$(has "$BOOT/userconf.txt")"
    if [ -f "$BOOT/userconf.txt" ]; then
        check "userconf holds a hash, not a plaintext password" \
              "$(grep -q ':\$6\$' "$BOOT/userconf.txt" && echo 0 || echo 1)"
    fi

    echo
    echo "Configuration"
    # shellcheck disable=SC1091
    . "$PAYLOAD/config.env"
    if [ -n "${PI_PASSWORD_B64:-}" ] || { [ -n "${PI_PASSWORD:-}" ] && [ "${PI_PASSWORD:-}" != "changeme" ]; }; then
        check "a password is set" 0
    else
        check "a password is set" 1
    fi
    case "${ETH_ADDRESS:-}" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) check "ethernet address configured" 0 ;;
        *)                           check "ethernet address configured" 1 ;;
    esac
    info "will come up at http://${ETH_ADDRESS:-?}:${SERVER_PORT:-?}"
    info "ssh ${PI_USER:-?}@${ETH_ADDRESS:-?}"
    [ "${PI_PASSWORD:-}" = "changeme" ] && note 'password is still the default "changeme"'

    echo
    echo "Repo archive"
    if LIST="$(tar -tzf "$PAYLOAD/repo.tar.gz" 2>/dev/null)"; then
        check "repo.tar.gz is a readable archive" 0
        case "$LIST" in *"./api_step_motor.py"*) R=0;; *) R=1;; esac
        check "contains the flask app" "$R"
        case "$LIST" in *"./templates/buttons.html"*) R=0;; *) R=1;; esac
        check "contains the templates" "$R"
        case "$LIST" in *"./requirements.txt"*) R=0;; *) R=1;; esac
        check "contains requirements" "$R"
    else
        check "repo.tar.gz is a readable archive" 1
    fi
else
    echo "Stage A"
    check "firstrun.log written" "$(has "$PAYLOAD/firstrun.log")"
    if [ -f "$PAYLOAD/firstrun.log" ]; then
        R="$(grep_q "$PAYLOAD/firstrun.log" 'stage A complete')"
        check "stage A reported completion" "$R"
        if [ "$R" != "0" ]; then
            _d "  --- last 25 lines of firstrun.log ---"
            tail -25 "$PAYLOAD/firstrun.log" | sed 's/^/      /'
        fi
    fi
    case "$CMDLINE" in *systemd.run=*) R=1;; *) R=0;; esac
    check "boot hook was disarmed" "$R"

    echo
    echo "Stage B"
    if [ ! -f "$PAYLOAD/provision.log" ]; then
        note "no provision.log - stage B never ran."
        note "Did the Pi have internet on its second boot?"
    else
        R="$(grep_q "$PAYLOAD/provision.log" 'provisioning complete')"
        check "stage B reported completion" "$R"
        if [ "$R" != "0" ]; then
            _d "  --- last 30 lines of provision.log ---"
            tail -30 "$PAYLOAD/provision.log" | sed 's/^/      /'
        fi
    fi
fi

echo
if [ "$BAD" -eq 0 ]; then
    MSG="$RUN checks passed"
    [ "$WARN" -gt 0 ] && MSG="$MSG, $WARN note(s)"
    _g "$MSG"
    [ "$PHASE" = "preboot" ] && echo "Card looks good. Put it in the Pi and boot it once with internet."
    exit 0
else
    _r "$BAD of $RUN checks FAILED"
    exit 1
fi
