#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
README="$ROOT/README.md"

grep -q 'sdm-image-builder/pi-image/bootstrap.sh' "$README"
grep -q 'sdm-image-builder/pi-image/bootstrap.ps1' "$README"
! grep -q 'main/provisioning/bootstrap' "$README"
for script in "$ROOT/pi-image/bootstrap.sh" "$ROOT/pi-image/bootstrap.ps1"; do
    grep -q 'releases/download/pi-image-sdm/transfer-station.img.xz' "$script"
    grep -qi 'sha256\|checksum' "$script"
    grep -q 'ERASE' "$script"
done
grep -q 'pi-image-sdm' "$ROOT/.github/workflows/pi-image.yml"
grep -q -- '--prerelease' "$ROOT/.github/workflows/pi-image.yml"
echo "bootstrap wiring ok"
