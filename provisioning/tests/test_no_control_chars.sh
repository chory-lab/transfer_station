#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Guard against stray C0 control characters in tracked text files.
#
# This is not hypothetical tidiness. Escape sequences get mangled while editing
# through layers of shell/Python quoting, and the results are invisible on
# screen but wrong. Both of these shipped to users:
#
#   provisioning\flash.ps1  ->  provisioning<FF>lash.ps1   (\f became formfeed)
#   .\bootstrap.ps1         ->  .<BS>ootstrap.ps1          (\b became backspace)
#
# Neither was visible in a diff. A byte-level check is the only thing that
# reliably catches them.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

cd "$REPO_ROOT" || exit 1

echo "== no stray control characters in tracked text files =="

# BEL, BS, VT, FF, ESC. Tab, LF and CR are legitimate.
#
# awk, not `grep -P`: PCRE is not compiled into every grep (git-bash's is not),
# and a -P that errors out is indistinguishable from "no matches found" once
# stderr is redirected. The first version of this check used it and silently
# passed a file that was full of the very characters it was looking for.
has_ctrl() {
    LC_ALL=C awk '
        BEGIN { bad = sprintf("%c%c%c%c%c", 7, 8, 11, 12, 27) }
        {
            for (i = 1; i <= length($0); i++)
                if (index(bad, substr($0, i, 1)) > 0) found = 1
        }
        END { exit !found }' "$1"
}

# Self-test. A checker that cannot fail is worse than no checker, because it
# reports success forever. Build a known-dirty and a known-clean file and
# confirm the detector distinguishes them before trusting it on the repo.
_probe="$(mktemp)"
printf 'provisioning\flash.ps1\n.\bootstrap.ps1\n' > "$_probe"
if ! has_ctrl "$_probe"; then
    echo "FATAL: the detector does not detect known-bad input." >&2
    rm -f "$_probe"; exit 1
fi
printf 'a clean line\nanother clean line\n' > "$_probe"
if has_ctrl "$_probe"; then
    echo "FATAL: the detector flags known-clean input." >&2
    rm -f "$_probe"; exit 1
fi
rm -f "$_probe"
echo "  (detector self-test passed)"

# Vendored and binary paths are not ours to police.
FOUND=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
        foobar/*|3D\ Files/*|*.png|*.jpg|*.res|*.lay|*.rdb|*.pyc|*.gz|*.zip)
            continue ;;
    esac
    if has_ctrl "$f"; then
        echo "  offending file: $f"
        FOUND=1
    fi
done < <(git ls-files)

it "no C0 control characters in tracked text files"
if [ "$FOUND" -eq 0 ]; then pass; else fail "see the files listed above"; fi

# CR is excluded above because CRLF files are legitimate -- but never in a
# file .gitattributes pins to eol=lf. A lone CR in a shell script is exactly
# how a mangled carriage-return escape hides, and shellcheck rejects it (SC1017).
echo
echo "== no carriage returns in LF-pinned shell scripts =="
CR_FOUND=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    if LC_ALL=C awk 'BEGIN{cr=sprintf("%c",13)} index($0,cr){f=1} END{exit !f}' "$f"; then
        echo "  offending file: $f"
        LC_ALL=C awk 'BEGIN{cr=sprintf("%c",13)} index($0,cr){print "      line "NR}' "$f" | head -3
        CR_FOUND=1
    fi
done < <(git ls-files '*.sh')

it "no CR in any tracked .sh file"
if [ "$CR_FOUND" -eq 0 ]; then pass; else fail "see above"; fi

echo
echo "== no line is a command doubled onto itself =="
# a4cdcbb shipped this in provision.sh:
#     systemctl enable redis-serversystemctl enable redis-server
# A newline was lost between two copies of the same command. It is valid bash,
# so bash -n, shellcheck and every suite passed it -- and stage B died on the
# real device trying to enable a unit called "redis-serversystemctl". Catch the
# shape: a whole line that is one string written twice, back to back.
DUP_FOUND=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    while IFS= read -r report; do
        echo "  offending line: $f:$report"
        DUP_FOUND=1
    done < <(awk '
        { line = $0
          sub(/^[ 	]+/, "", line); sub(/[ 	]+$/, "", line)
          if (line ~ /^#/ || length(line) < 16 || length(line) % 2 != 0) next
          h = length(line) / 2
          if (substr(line, 1, h) == substr(line, h + 1)) print NR": "substr(line, 1, 60)
        }' "$f")
done < <(git ls-files '*.sh')

it "no tracked .sh line is the same command twice"
if [ "$DUP_FOUND" -eq 0 ]; then pass; else fail "see above"; fi

echo
echo "== the README's copy-paste commands are intact =="
# Users paste these verbatim; a mangled path is a silent failure for them.
it "the explicit disk-number escape hatch survived escaping"
assert_contains "$(cat README.md)" '.\bootstrap.ps1 -DiskNumber'

for u in bootstrap.ps1 bootstrap.sh; do
    it "README references pi-image/$u by its real path"
    assert_contains "$(cat README.md)" "pi-image/$u"
done

summary
