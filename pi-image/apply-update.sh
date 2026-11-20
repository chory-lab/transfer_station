#!/usr/bin/env bash
# Runs ON THE PI. update-pi.sh / update-pi.ps1 upload it with a bundle of app
# files and run it over SSH:
#
#   bash apply-update.sh /tmp/ts-update-XXXX/bundle.tar
#
# Backs up the installed app, installs the bundle over it, restarts the
# service, and puts the old files back if the server does not come up.
#
# The Pi has no internet, so it cannot install Python packages. An update
# that changes pyproject.toml or uv.lock is refused: that needs a new image.
set -euo pipefail

BUNDLE="${1:?usage: apply-update.sh BUNDLE.tar}"
REPO_DEST="${TS_REPO_DEST:-/home/chorylab/transfer_station}"
SERVICE="${TS_SERVICE:-transfer-station}"
HEALTH_URL="${TS_HEALTH_URL:-http://127.0.0.1:5000/position}"
HEALTH_WAIT="${TS_HEALTH_WAIT:-30}"  # seconds
BACKUPS="${TS_BACKUPS:-$HOME/transfer_station-backups}"
KEEP_BACKUPS=5

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$BUNDLE" ] || die "no bundle at $BUNDLE"
[ -d "$REPO_DEST" ] || die "$REPO_DEST does not exist. Is this Pi running the transfer station image?"
systemctl cat "$SERVICE.service" >/dev/null 2>&1 \
    || die "no $SERVICE service on this Pi. Is it running the transfer station image?"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# A bundle packed on macOS can carry ._* metadata files and extended headers
# that GNU tar warns about; skip both.
QUIET=()
tar --version 2>/dev/null | grep -q GNU && QUIET=(--warning=no-unknown-keyword)
tar -xf "$BUNDLE" -C "$STAGE" --no-same-owner --exclude='._*' ${QUIET[@]+"${QUIET[@]}"}

for f in pyproject.toml uv.lock; do
    cmp -s "$STAGE/$f" "$REPO_DEST/$f" || die "$f differs from (or is missing on) the Pi.
This update changes Python dependencies, which the Pi cannot install without
internet. Flash a new image instead (see README, SD Card Setup)."
done

say "Files to install:"
(cd "$STAGE" && find . -type f | sed 's|^\./|    |' | sort)

mkdir -p "$BACKUPS"
BACKUP="$BACKUPS/$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
say "Backing up the installed app to $BACKUP"
tar -czf "$BACKUP" -C "$REPO_DEST" --exclude=./.venv .

restart() {
    say "Restarting $SERVICE (sudo may ask for the Pi password)"
    sudo systemctl restart "$SERVICE"
}

healthy() {
    local i
    for ((i = 0; i < HEALTH_WAIT; i++)); do
        if systemctl is-active --quiet "$SERVICE" && python3 -c \
            'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=2)' \
            "$HEALTH_URL" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

say "Installing into $REPO_DEST"
cp -R "$STAGE/." "$REPO_DEST/"
restart

say "Waiting for the server to answer at $HEALTH_URL"
if ! healthy; then
    printf '\nERROR: the server did not come up after the update. Its log:\n\n' >&2
    sudo journalctl -u "$SERVICE" -n 30 --no-pager >&2 || true
    say "Putting the previous files back from $BACKUP"
    tar -xzf "$BACKUP" -C "$REPO_DEST"
    restart
    die "update rolled back. Nothing changed on the Pi."
fi

# Keep the newest few backups
# shellcheck disable=SC2012  # names are generated above, no odd characters
ls -1t "$BACKUPS"/*.tar.gz | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
    rm -f "$old"
done

say "Update installed and the server is answering."
say "To undo it: tar -xzf $BACKUP -C $REPO_DEST && sudo systemctl restart $SERVICE"
