#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ICON_SRC="$ROOT/Assets/app-icon.svg"

if [[ ! -x "$ROOT/Vendor/rclone/rclone" ]]; then
  "$ROOT/scripts/vendor-rclone.sh"
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/.build/nafi.app"
FP_APPEX="$("$ROOT/scripts/build-file-provider.sh")"

rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources" \
  "$APP/Contents/Helpers" \
  "$APP/Contents/PlugIns" \
  "$APP/Contents/Library/LoginItems/NafiBackgroundAgent.app/Contents/MacOS"

cp "$BIN_DIR/nafi" "$APP/Contents/MacOS/nafi"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Vendor/rclone/rclone" "$APP/Contents/Helpers/rclone"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
[[ ! -f "$ROOT/Vendor/rclone/LICENSE.rclone.txt" ]] || cp "$ROOT/Vendor/rclone/LICENSE.rclone.txt" "$APP/Contents/Resources/LICENSE.rclone.txt"
/usr/bin/ditto "$FP_APPEX" "$APP/Contents/PlugIns/NafiFileProvider.appex"

HELPER="$APP/Contents/Library/LoginItems/NafiBackgroundAgent.app"
cp "$BIN_DIR/nafi-background-agent" "$HELPER/Contents/MacOS/nafi-background-agent"
cp "$ROOT/Resources/NafiBackgroundAgent-Info.plist" "$HELPER/Contents/Info.plist"
chmod 0755 "$APP/Contents/MacOS/nafi" "$APP/Contents/Helpers/rclone" "$HELPER/Contents/MacOS/nafi-background-agent"

if [[ -f "$ICON_SRC" && -x "$(command -v rsvg-convert 2>/dev/null || true)" ]]; then
  ICONSET="$ROOT/.build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for px in 16 32 64 128 256 512 1024; do rsvg-convert -w "$px" -h "$px" "$ICON_SRC" -o "$ICONSET/_${px}.png"; done
  cp "$ICONSET/_16.png" "$ICONSET/icon_16x16.png"; cp "$ICONSET/_32.png" "$ICONSET/icon_16x16@2x.png"
  cp "$ICONSET/_32.png" "$ICONSET/icon_32x32.png"; cp "$ICONSET/_64.png" "$ICONSET/icon_32x32@2x.png"
  cp "$ICONSET/_128.png" "$ICONSET/icon_128x128.png"; cp "$ICONSET/_256.png" "$ICONSET/icon_128x128@2x.png"
  cp "$ICONSET/_256.png" "$ICONSET/icon_256x256.png"; cp "$ICONSET/_512.png" "$ICONSET/icon_256x256@2x.png"
  cp "$ICONSET/_512.png" "$ICONSET/icon_512x512.png"; cp "$ICONSET/_1024.png" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "warning: rsvg-convert unavailable; app icon generation skipped" >&2
fi

SIGNING_IDENTITY="${NAFI_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && "${CI:-false}" != "true" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\) [0-9A-F]+ "((Apple Development|Developer ID Application):[^"]+)".*/\1/p' | head -n 1)"
fi
[[ -n "$SIGNING_IDENTITY" ]] || SIGNING_IDENTITY="-"
FP_ENTITLEMENTS="$ROOT/Extensions/NafiFileProvider/NafiFileProvider.Release.entitlements"
[[ "$SIGNING_IDENTITY" == "-" ]] && FP_ENTITLEMENTS="$ROOT/Extensions/NafiFileProvider/NafiFileProvider.entitlements"

SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_OPTIONS+=(--options runtime --timestamp)
fi

codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Helpers/rclone"
codesign "${SIGN_OPTIONS[@]}" "$HELPER"
codesign "${SIGN_OPTIONS[@]}" --entitlements "$FP_ENTITLEMENTS" "$APP/Contents/PlugIns/NafiFileProvider.appex"
codesign "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ "${NAFI_REGISTER_BUILD:-false}" == "true" && -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
else
  pluginkit -r "$APP/Contents/PlugIns/NafiFileProvider.appex" >/dev/null 2>&1 || true
fi

echo "Built: $APP"
if [[ "${NAFI_REVEAL_BUILD:-false}" == "true" ]]; then
  open -R "$APP"
fi
