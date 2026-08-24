# Minimal assertion harness. No external deps so these run locally and in CI.
# shellcheck shell=bash

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
_green() { printf '\033[32m%s\033[0m\n' "$*"; }

it() {
    CURRENT_TEST="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    _red "  FAIL: ${CURRENT_TEST}"
    _red "        $*"
}

pass() { _green "  ok:   ${CURRENT_TEST}"; }

# Visible non-failure, for checks that cannot run in this environment.
skip() {
    TESTS_RUN=$((TESTS_RUN - 1))
    printf '\033[33m  SKIP: %s\033[0m
' "${CURRENT_TEST}${1:+ -- $1}"
}

assert_eq() {
    if [ "$1" = "$2" ]; then pass; else
        fail "expected: [$2]
        actual:   [$1]"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) pass ;;
        *) fail "expected to contain: [$2]
        in: [$1]" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "expected NOT to contain: [$2]
        in: [$1]" ;;
        *) pass ;;
    esac
}

assert_file() {
    if [ -f "$1" ]; then pass; else fail "missing file: $1"; fi
}

assert_no_file() {
    if [ ! -e "$1" ]; then pass; else fail "file should not exist: $1"; fi
}

# Counts occurrences of a fixed string in a file.
count_in_file() { grep -o -F "$2" "$1" 2>/dev/null | wc -l | tr -d ' '; }

summary() {
    echo
    if [ "$TESTS_FAILED" -eq 0 ]; then
        _green "${TESTS_RUN} passed"
        return 0
    fi
    _red "${TESTS_FAILED} of ${TESTS_RUN} failed"
    return 1
}
