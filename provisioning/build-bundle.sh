#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the offline dependency bundle.
#
# Runs INSIDE a Raspberry Pi OS chroot (see tests/test_rpios_chroot.sh), so
# apt's own solver resolves the arm64 dependency graph against the real
# archive. That is the whole point: no guessing at .deb dependencies from a
# machine that is not a Raspberry Pi.
#
#   build-bundle.sh <output-dir>
#
# The result lets stage B install everything with no network at all.
# ---------------------------------------------------------------------------
set -euo pipefail

OUT="${1:-/bundle}"
UV_VERSION="${UV_VERSION:-0.12.5}"

mkdir -p "$OUT/debs" "$OUT/wheels"

# --- what release are we building against? --------------------------------
# .debs are only valid for the release they came from, so record it and let
# provision.sh refuse a mismatch rather than half-install.
# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${VERSION_CODENAME:-unknown}"
ARCH="$(dpkg --print-architecture)"
echo ">> building bundle for ${ID} ${CODENAME} ${ARCH}"

export DEBIAN_FRONTEND=noninteractive
apt-get update

# --- system packages ------------------------------------------------------
# --download-only resolves the full dependency closure and drops the .debs in
# the archive cache without installing anything.
apt-get install -y --download-only --reinstall \
    -o Dir::Cache::archives="$OUT/debs" \
    redis-server python3-rpi.gpio

# apt leaves lock files and a partial/ dir behind; the card only wants .debs.
find "$OUT/debs" -mindepth 1 -maxdepth 1 ! -name '*.deb' -exec rm -rf {} +

# --- uv -------------------------------------------------------------------
UV_TRIPLE="$( [ "$ARCH" = "arm64" ] && echo aarch64-unknown-linux-gnu \
                                    || echo armv7-unknown-linux-gnueabihf )"
if [ "$UV_VERSION" = "latest" ]; then
    UV_URL="https://github.com/astral-sh/uv/releases/latest/download/uv-${UV_TRIPLE}.tar.gz"
else
    UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TRIPLE}.tar.gz"
fi
echo ">> fetching uv for ${UV_TRIPLE}"
curl -fsSL --retry 3 -o "$OUT/uv.tar.gz" "$UV_URL"

# --- python wheels --------------------------------------------------------
# Export the already-resolved uv.lock rather than resolving a second time via
# a floating requirements file. Every runtime dep is pure Python; the only C
# extension, RPi.GPIO, comes from the .deb above.
apt-get install -y --no-install-recommends python3-pip
UV_TMP="$(mktemp -d)"
tar -xzf "$OUT/uv.tar.gz" -C "$UV_TMP"
UV_BIN="$(find "$UV_TMP" -name uv -type f | head -1)"
"$UV_BIN" export --project /work --frozen --no-dev --no-emit-project \
    --format requirements-txt --output-file /tmp/transfer-station.lock.txt
python3 -m pip download \
    --only-binary=:all: \
    --dest "$OUT/wheels" \
    --require-hashes \
    -r /tmp/transfer-station.lock.txt
rm -rf "$UV_TMP" /tmp/transfer-station.lock.txt

# --- manifest -------------------------------------------------------------
cat > "$OUT/manifest.env" <<MANIFEST
BUNDLE_CODENAME=${CODENAME}
BUNDLE_ARCH=${ARCH}
BUNDLE_BUILT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST

echo
echo ">> bundle contents:"
echo "   debs:   $(find "$OUT/debs" -name '*.deb' | wc -l) packages"
echo "   wheels: $(find "$OUT/wheels" -name '*.whl' | wc -l) wheels"
du -sh "$OUT"
cat "$OUT/manifest.env"
