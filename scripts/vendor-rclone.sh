#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.74.4"
BASE="https://downloads.rclone.org/v${VERSION}"
OUT="$ROOT/Vendor/rclone"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

fetch_arch() {
  local arch="$1" expected="$2"
  local zip="$TMP/rclone-${arch}.zip"
  /usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "$BASE/rclone-v${VERSION}-osx-${arch}.zip" -o "$zip"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$zip" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "rclone ${arch} checksum mismatch: ${actual}" >&2
    exit 1
  fi
  /usr/bin/unzip -q "$zip" -d "$TMP/$arch"
  local folder="$TMP/$arch/rclone-v${VERSION}-osx-${arch}"
  cp "$folder/rclone" "$TMP/rclone-${arch}"
  if [[ -f "$folder/COPYING" ]]; then cp "$folder/COPYING" "$OUT/LICENSE.rclone.txt"; fi
}

fetch_arch amd64 4188aa84043d7a6240912923f47639a9d2da21f3b40a521c065c8d92e66563f6
fetch_arch arm64 c2100e2d4a4b3be04c55cd45380cafe7647e1ad772bb055f52f00876ed701167
/usr/bin/lipo -create "$TMP/rclone-amd64" "$TMP/rclone-arm64" -output "$OUT/rclone"
chmod 0755 "$OUT/rclone"
"$OUT/rclone" version
