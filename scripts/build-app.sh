#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- app icon ---------------------------------------------------------------
# Build AppIcon.icns from the SVG source. Requires rsvg-convert (Homebrew:
# `brew install librsvg`). iconutil ships with macOS.
ICON_SRC="$ROOT/Assets/app-icon.svg"
if [[ ! -f "$ICON_SRC" ]]; then
  echo "warning: $ICON_SRC not found, skipping icon generation" >&2
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/.build/Nami.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Nami" "$APP/Contents/MacOS/Nami"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/Nami"

if [[ -f "$ICON_SRC" ]]; then
  if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "warning: rsvg-convert not found; install with 'brew install librsvg'. Skipping icon." >&2
  else
    ICONSET="$ROOT/.build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    declare -a SIZES=(16 32 64 128 256 512 1024)
    for px in "${SIZES[@]}"; do
      rsvg-convert -w "$px" -h "$px" "$ICON_SRC" -o "$ICONSET/_${px}.png"
    done
    cp "$ICONSET/_16.png"   "$ICONSET/icon_16x16.png"
    cp "$ICONSET/_32.png"   "$ICONSET/icon_16x16@2x.png"
    cp "$ICONSET/_32.png"   "$ICONSET/icon_32x32.png"
    cp "$ICONSET/_64.png"   "$ICONSET/icon_32x32@2x.png"
    cp "$ICONSET/_128.png"  "$ICONSET/icon_128x128.png"
    cp "$ICONSET/_256.png"  "$ICONSET/icon_128x128@2x.png"
    cp "$ICONSET/_256.png"  "$ICONSET/icon_256x256.png"
    cp "$ICONSET/_512.png"  "$ICONSET/icon_256x256@2x.png"
    cp "$ICONSET/_512.png"  "$ICONSET/icon_512x512.png"
    cp "$ICONSET/_1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
  fi
fi

codesign --force --deep --sign - "$APP"

echo "Built: $APP"
open -R "$APP"
