#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
README="$ROOT/README.md"

grep -q 'main/pi-image/bootstrap.sh' "$README"
grep -q 'main/pi-image/bootstrap.ps1' "$README"
! grep -q 'main/provisioning/bootstrap' "$README"
for script in "$ROOT/pi-image/bootstrap.sh" "$ROOT/pi-image/bootstrap.ps1"; do
    grep -q 'releases/download/pi-image/transfer-station.img.xz' "$script"
    grep -qi 'sha256\|checksum' "$script"
    grep -q 'ERASE' "$script"
    grep -q '192.168.10.2' "$script"
    grep -q 'static address' "$script"
done
grep -q '192.168.10.2' "$README"
grep -q 'no gateway and no DNS' "$README"
grep -q 'Darwin' "$ROOT/pi-image/bootstrap.sh"
grep -q 'diskutil list external physical' "$ROOT/pi-image/bootstrap.sh"
grep -q 'shasum -a 256' "$ROOT/pi-image/bootstrap.sh"
grep -q 'Raspberry Pi Imager.app' "$ROOT/pi-image/bootstrap.sh"
grep -q 'Linux' "$ROOT/pi-image/bootstrap.sh"
grep -q 'lsblk' "$ROOT/pi-image/bootstrap.sh"
grep -q 'macOS / Linux' "$README"
grep -q 'TAG="pi-image"' "$ROOT/.github/workflows/pi-image.yml"
grep -q -- '--prerelease' "$ROOT/.github/workflows/pi-image.yml"
echo "bootstrap wiring ok"
