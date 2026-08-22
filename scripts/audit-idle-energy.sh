#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PANE="$ROOT/Sources/NafiFileManager/Views/FilePaneView.swift"
THUMB="$ROOT/Sources/NafiFileManager/Views/FileThumbnailView.swift"
POLICY="$ROOT/Sources/NafiFileManager/App/EnergyPolicy.swift"
ENUM="$ROOT/Extensions/NafiFileProvider/Sources/FileProviderEnumerator.swift"
ITEM="$ROOT/Extensions/NafiFileProvider/Sources/FileProviderItem.swift"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

# Gallery must never start media playback merely because the browser is visible.
if ! grep -q 'preview.autostarts = false' "$PANE"; then
  fail "embedded Quick Look can auto-start media"
fi
pass "embedded Quick Look auto-play disabled"

# The default idle policy must bypass embedded Quick Look and dataless thumbnail work.
if ! grep -q 'EnergyPreferenceKey.ultraEfficiency' "$PANE"; then
  fail "Gallery preview is not energy-policy gated"
fi
if ! grep -q 'suppressAutomaticThumbnail' "$THUMB"; then
  fail "automatic thumbnail generation is not energy-policy gated"
fi
if ! grep -q 'static func suppressAutomaticThumbnail(ultraEfficiency: Bool)' "$POLICY" \
  || ! grep -A2 'static func suppressAutomaticThumbnail(ultraEfficiency: Bool)' "$POLICY" | grep -q 'ultraEfficiency'; then
  fail "ultra-efficiency does not suppress automatic thumbnail generation"
fi
pass "all automatic preview/thumbnail work gated by ultra-efficiency policy"

# A replicated provider's working set must not be a fake empty set. Use the
# system-local materialized-set enumerator so idle working-set bookkeeping is remote-I/O free.
if ! grep -q 'enumeratorForMaterializedItems()' "$ENUM"; then
  fail "working set is not backed by the system materialized-item enumerator"
fi
if grep -q 'workingSetAnchor' "$ENUM"; then
  fail "legacy static/empty working-set anchor still present"
fi
pass "working set mirrors materialized items without remote polling"

if ! grep -q 'allowsContentEnumerating' "$ITEM"; then
  fail "directory enumeration capability missing"
fi
pass "directory capabilities advertise content enumeration"

echo "Idle-energy invariants passed."
