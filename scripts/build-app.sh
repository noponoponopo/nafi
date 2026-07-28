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
APP="$ROOT/.build/nafi.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/nafi" "$APP/Contents/MacOS/nafi"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/nafi"

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

DEFAULT_LOCAL_IDENTITY="nafi Local Development"
SIGNING_IDENTITY="${NAFI_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" && "${CI:-false}" != "true" ]]; then
  AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if print -r -- "$AVAILABLE_IDENTITIES" | grep -Fq "\"$DEFAULT_LOCAL_IDENTITY\""; then
    SIGNING_IDENTITY="$DEFAULT_LOCAL_IDENTITY"
  else
    # Reuse an existing development identity when Xcode has installed one.
    SIGNING_IDENTITY="$(
      print -r -- "$AVAILABLE_IDENTITIES" \
        | sed -nE 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ "((Apple Development|Developer ID Application):[^"]+)".*/\1/p' \
        | head -n 1
    )"
  fi
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

codesign --verify --deep --strict "$APP"

# Force Launch Services to refresh nafi's document-type declarations. This is
# especially important for local builds in .build, which Finder may not scan on
# its own after Info.plist changes.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  if ! "$LSREGISTER" -f "$APP" >/dev/null 2>&1; then
    echo "warning: Launch Services registration failed; move nafi.app to Applications and open it once." >&2
  fi
fi

echo "Built: $APP"
if [[ "${CI:-false}" != "true" ]]; then
  open -R "$APP"
fi
