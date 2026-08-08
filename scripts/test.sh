#!/usr/bin/env bash
# Run the Sub4 test suite on a simulator.
#
# Why this exists: Cmd-R compiles the APP TARGET ONLY, so test-target compile
# errors accumulate invisibly. Patches 275, 276 and 277 all ran on the phone
# while the suite had not compiled since 273. Run this before every device build.
#
# Expected: 931 tests in 88 suites, well under a second of actual test time.
# (Count as of patch 317; it grows as the suite does — the point is the order of
# magnitude.) A pass reporting far fewer tests means the test target did not build.

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${SUB4_SCHEME:-Sub4}"
PROJECT="Sub4.xcodeproj"

if [[ ! -d "$PROJECT" ]]; then
  echo "error: $PROJECT not found — run this from the repo root" >&2
  exit 1
fi

# Newest available iPhone simulator, unless SUB4_DEST overrides it.
if [[ -n "${SUB4_DEST:-}" ]]; then
  DEST="$SUB4_DEST"
else
  UDID="$(xcrun simctl list devices available \
    | grep -E '^\s+iPhone' \
    | tail -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
  if [[ -z "$UDID" ]]; then
    echo "error: no available iPhone simulator found." >&2
    echo "       install one in Xcode, or set SUB4_DEST explicitly." >&2
    exit 1
  fi
  DEST="platform=iOS Simulator,id=$UDID"
fi

echo "scheme:      $SCHEME"
echo "destination: $DEST"
echo

set -o pipefail
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  -quiet \
  | tee /tmp/sub4-test.log

echo
echo "--- summary ---"
grep -E "Test run with .* tests|Suite .* passed|Suite .* failed|error:|failed" /tmp/sub4-test.log \
  | tail -20 || true
echo
echo "full log: /tmp/sub4-test.log"
echo "sanity check: the run should report ~931 tests. Far fewer means the test"
echo "target did not build, which is the exact failure this script exists to catch."
