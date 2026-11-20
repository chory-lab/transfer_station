#!/usr/bin/env bash
# Updates the app on a running transfer station Pi from this checkout, over
# SSH. The Pi needs no internet. From the top of the repo:
#
#   bash pi-image/update-pi.sh [user@host]      (default chorylab@192.168.10.1)
#
# update-pi.ps1 does the same from Windows. The work on the Pi is done by
# apply-update.sh, which backs up, installs, restarts and rolls back on
# failure.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TARGET="${1:-chorylab@192.168.10.1}"

# What runs on the Pi. pyproject.toml and uv.lock go along only so the Pi
# can refuse an update that changes dependencies.
FILES=(A4988.py api_step_motor.py templates pyproject.toml uv.lock)

cd "$ROOT"
for f in "${FILES[@]}"; do
    [ -e "$f" ] || { echo "ERROR: $f is missing from $ROOT" >&2; exit 1; }
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
NAME="$(basename "$STAGE")"
COPYFILE_DISABLE=1 tar -cf "$STAGE/bundle.tar" "${FILES[@]}"
cp "$HERE/apply-update.sh" "$STAGE/"

echo "==> Uploading to $TARGET (enter the Pi password if asked)"
scp -q -r "$STAGE" "$TARGET:/tmp/"

echo "==> Installing on the Pi"
ssh -t "$TARGET" \
    "bash /tmp/$NAME/apply-update.sh /tmp/$NAME/bundle.tar; s=\$?; rm -rf /tmp/$NAME; exit \$s"
