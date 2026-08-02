#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$ROOT/Extensions/NafiFileProvider/Sources"
RUNTIME="$ROOT/Sources/NafiFileManager/Services/Rclone/RcloneRuntime.swift"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

# Point metadata/version checks must not regress to parent-directory enumeration.
if ! grep -q 'bridge.call("operations/stat"' "$EXT/FileProviderExtension.swift"; then
  fail "File Provider point lookups are not using operations/stat"
fi
pass "point lookups use operations/stat"

# Normal directory enumeration intentionally avoids hashes; content is fetched lazily.
if ! grep -A12 'bridge.call("operations/list"' "$EXT/FileProviderEnumerator.swift" | grep -q '"showHash": false'; then
  fail "directory enumeration unexpectedly requests hashes"
fi
pass "directory enumeration does not request hashes"

# No File Provider code may request download-based verification merely to detect change.
if grep -R -n -E '"download"[[:space:]]*:[[:space:]]*true' "$EXT"; then
  fail "File Provider enables download-based checking"
fi
pass "no download-based hash/check verification"

# Materialization should take the exact single-object route first.
if ! grep -q 'bridge.runJob("operations/copyfile"' "$EXT/FileProviderExtension.swift"; then
  fail "single-file materialization is not using operations/copyfile"
fi
pass "single-file materialization uses operations/copyfile"

# rclone must be able to reach a daemon-free idle state.
if ! grep -q 'shutdownIfStillIdle' "$RUNTIME"; then
  fail "idle rclone shutdown path missing"
fi
pass "idle rclone shutdown path present"

# The optimized File Provider must not grow a clock-driven poll loop.
if grep -R -n -E 'scheduledTimer|Timer\.publish|DispatchSource\.makeTimerSource' "$EXT"; then
  fail "clock-driven polling found in File Provider extension"
fi
pass "no File Provider timer polling"

echo "File Provider energy invariants passed."
