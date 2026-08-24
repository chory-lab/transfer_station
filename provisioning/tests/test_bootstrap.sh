#!/usr/bin/env bash
# The README tells people to pipe a URL straight into a shell. If that URL
# ever stops resolving to a real file -- a rename, a typo, a moved directory
# -- the documented instructions break silently. Guard that.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

echo "== URLs quoted in the README point at files that exist =="
mapfile -t URLS < <(grep -oE 'https://raw\.githubusercontent\.com/[^ )`"]+' "$REPO_ROOT/README.md" | sort -u)

it "the README quotes at least one bootstrap URL"
if [ "${#URLS[@]}" -gt 0 ]; then pass; else fail "no raw.githubusercontent URLs found in README.md"; fi

for u in "${URLS[@]}"; do
    # .../main/<path-in-repo>
    REL="${u#*/main/}"
    it "README URL resolves to a file in this repo: $REL"
    assert_file "$REPO_ROOT/$REL"
done

echo
echo "== bootstrap scripts are self-consistent =="
it "bootstrap.sh fetches a tarball from this repo"
assert_contains "$(cat "$REPO_ROOT/provisioning/bootstrap.sh")" "transfer_station/archive"

it "bootstrap.sh hands off to flash.sh"
assert_contains "$(cat "$REPO_ROOT/provisioning/bootstrap.sh")" "provisioning/flash.sh"

it "bootstrap.ps1 hands off to flash.ps1"
assert_contains "$(cat "$REPO_ROOT/provisioning/bootstrap.ps1")" "provisioning\flash.ps1"

it "bootstrap.sh refuses non-removable disks"
assert_contains "$(cat "$REPO_ROOT/provisioning/bootstrap.sh")" "is not removable"

it "the address the README advertises matches config.env"
# shellcheck disable=SC1091
. "$REPO_ROOT/provisioning/config.env"
assert_contains "$(cat "$REPO_ROOT/README.md")" "${ETH_ADDRESS}:${SERVER_PORT}"

echo
echo "== password encoding survives shell metacharacters =="
# config.env is sourced by bash and parsed by PowerShell, so bootstrap stores
# the password base64-encoded rather than trying to quote it for both.
it "bootstrap.sh writes PI_PASSWORD_B64"
assert_contains "$(cat "$REPO_ROOT/provisioning/bootstrap.sh")" "PI_PASSWORD_B64"

it "bootstrap.ps1 writes PI_PASSWORD_B64"
assert_contains "$(cat "$REPO_ROOT/provisioning/bootstrap.ps1")" "PI_PASSWORD_B64"

for consumer in provisioning/flash.sh provisioning/payload/firstrun.sh; do
    it "$consumer decodes PI_PASSWORD_B64"
    assert_contains "$(cat "$REPO_ROOT/$consumer")" "base64 -d"
done

it "flash.ps1 decodes PI_PASSWORD_B64"
assert_contains "$(cat "$REPO_ROOT/provisioning/flash.ps1")" "FromBase64String"

NASTY='p@ss|w&rd$x'"'"'q\ "sp ace" `tick`'
CFG="$(mktemp)"
grep -v '^PI_PASSWORD' "$REPO_ROOT/provisioning/config.env" > "$CFG"
printf 'PI_PASSWORD_B64=%s
' "$(printf '%s' "$NASTY" | base64 | tr -d '
')" >> "$CFG"

it "config.env still parses with an encoded metacharacter password"
if ( set -e; . "$CFG" ) 2>/dev/null; then pass; else fail "config.env broke"; fi

it "the password round-trips byte for byte"
ACTUAL="$( . "$CFG" >/dev/null 2>&1; printf '%s' "$PI_PASSWORD_B64" | base64 -d )"
assert_eq "$ACTUAL" "$NASTY"
rm -f "$CFG"

summary
