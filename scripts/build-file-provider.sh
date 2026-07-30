#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Extensions/NafiFileProvider/NafiFileProvider.xcodeproj"
DERIVED="$ROOT/.build/file-provider-derived"
OUTPUT="$ROOT/.build/extensions/NafiFileProvider.appex"
rm -rf "$DERIVED" "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -target NafiFileProvider \
  -configuration Release \
  SYMROOT="$DERIVED/Build/Products" \
  OBJROOT="$DERIVED/Build/Intermediates.noindex" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build >&2
BUILT="$DERIVED/Build/Products/Release/NafiFileProvider.appex"
[[ -d "$BUILT" ]] || { echo "File Provider build product missing: $BUILT" >&2; exit 1; }
/usr/bin/ditto "$BUILT" "$OUTPUT"
echo "$OUTPUT"
