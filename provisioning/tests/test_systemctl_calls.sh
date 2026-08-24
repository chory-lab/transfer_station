#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Every systemctl call in the payload names a unit we actually ship.
#
# Two lines in provision.sh once fused into
#     systemctl enable redis-serversystemctl enable redis-server
# which is valid bash, valid shell syntax, and accepted by shellcheck. Real
# systemd rejects the unit, `set -e` takes the script down, and stage B dies
# before it ever reaches the static address -- so the Pi boots and is simply
# not on the network.
#
# CI did not catch it because TS_CI stubs systemctl to return 0 for any
# arguments at all. So this checks both halves: that the stub refuses input
# it should refuse, and that no call in the payload uses a unit name that is
# not ours.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cd "$HERE/../payload" && pwd)"

rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }
ok()   { echo "ok: $*"; }

# Units this project installs or touches, plus the ones Raspberry Pi OS
# already provides. Anything else in a systemctl call is a typo.
KNOWN='redis-server|ssh|NetworkManager|transfer-station|transfer-station-provision'
VERBS='enable|disable|start|stop|restart|reload|daemon-reload|reboot|is-active|is-enabled|mask|unmask'

# --- 1. the stub must reject what real systemd would reject ---------------
# Lift it straight out of provision.sh so this cannot drift from the real one.
stub="$(sed -n '/^ *systemctl() {/,/^ *}$/p' "$PAYLOAD/provision.sh")"
[ -n "$stub" ] || { echo "FAIL: could not find the systemctl stub" >&2; exit 1; }

( eval "$stub"
  systemctl enable redis-server >/dev/null 2>&1 ) \
    || fail "the stub rejects a call that is correct"

( eval "$stub"
  systemctl enable redis-serversystemctl enable redis-server >/dev/null 2>&1 ) \
    && fail "the stub accepts the exact fused call that broke stage B"

( eval "$stub"
  systemctl enable nonexistent-thing.service >/dev/null 2>&1 ) \
    && fail "the stub accepts a unit this project does not ship"

[ "$rc" = 0 ] && ok "the CI stub refuses units systemd would refuse"

# --- 2. no call in the payload names a unit that is not ours -------------
# Only where systemctl is the command word: at the start of a line, or right
# after ;, && or ||. Inside a quoted string it is just text -- this file and
# provision.sh both quote the bad line on purpose.
while IFS= read -r hit; do
    file="${hit%%:*}"; rest="${hit#*:}"
    line="${rest%%:*}"; text="${rest#*:}"

    # Everything after the command word, truncated at the first shell
    # metacharacter so `; then` and friends are not read as unit names.
    # ${text#...} not ${text##...}: greedy stripping would skip to the LAST
    # "systemctl " in the line, which on the fused line is the second one --
    # leaving a perfectly valid tail and hiding the very bug being hunted.
    args="${text#*systemctl }"
    args="${args%%;*}"; args="${args%%&*}"; args="${args%%|*}"; args="${args%%#*}"

    for word in $args; do
        case "$word" in -*) continue ;; esac
        printf '%s' "$word" | grep -Eq "^(${VERBS})$" && continue
        printf '%s' "$word" | grep -Eq "^(${KNOWN})(\.service)?$" && continue
        fail "$file:$line names '$word', which is not a unit this project ships"
    done
done < <(grep -nE '(^|[;&|]|^[[:space:]]*)[[:space:]]*systemctl[[:space:]]'              "$PAYLOAD"/provision.sh "$PAYLOAD"/firstrun.sh          | grep -vE ':[0-9]+:[[:space:]]*#'          | grep -vE 'echo|printf')

[ "$rc" = 0 ] && ok "every systemctl call in the payload names a real unit"

exit "$rc"
