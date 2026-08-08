#!/usr/bin/env bash
# Run the Sub4 test suite on a simulator.
#
# Why this exists: Cmd-R compiles the APP TARGET ONLY, so test-target compile
# errors accumulate invisibly. Patches 275, 276 and 277 all ran on the phone
# while the suite had not compiled since 273. Run this before every device build.
#
# PATCH 325b — THIS SCRIPT COULD NOT DO THAT, AND SAID SO CHEERFULLY.
#
# It passed `-quiet` to xcodebuild, which suppresses swift-testing's summary
# along with everything else. The log held one line — "Testing started" — the
# summary grep matched nothing, and the footer below still printed its sanity
# check about expecting ~931 tests. A reader saw a script that ran, produced no
# errors and gave advice: a pass, in every respect except having checked
# anything. Every count trusted between 318 and 325 came from typing xcodebuild
# by hand instead.
#
# Two changes: `-quiet` is gone, and a run that produces no summary line now
# FAILS rather than printing guidance about a number it never saw.
# ADR-0003 §12.69.

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${SUB4_SCHEME:-Sub4}"
PROJECT="Sub4.xcodeproj"
LOG="${SUB4_LOG:-/tmp/sub4-test.log}"

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
echo "log:         $LOG"
echo

# NO `-quiet`. The whole output goes to the log; only the lines worth reading
# reach the terminal. That is the same trade the old version wanted and the flag
# took away.
#
# `|| true` on the pipeline, deliberately: a FAILING test run must reach the
# summary below rather than abort under `set -e` with the failures unprinted.
# The exit status is captured and re-applied at the end.
set +e
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DEST" \
  > "$LOG" 2>&1
STATUS=$?
set -e

echo "--- failures and errors ---"
grep -E "^.*(✘|error:|fatal error:|\*\* TEST FAILED \*\*)" "$LOG" | head -40 || true

echo
echo "--- summary ---"
SUMMARY="$(grep -E "Test run with .* tests" "$LOG" | tail -1 || true)"

# THE GUARD THAT WAS MISSING. A run with no summary line has not told us
# anything, and the one thing this script must never do is look like a pass
# while knowing nothing — that is what it did from 318 to 325.
if [[ -z "$SUMMARY" ]]; then
  echo "error: the run produced no 'Test run with N tests' line." >&2
  echo "       That is not a pass. The suite did not report, which usually means" >&2
  echo "       the test target did not build — the exact failure this script" >&2
  echo "       exists to catch. Read $LOG." >&2
  grep -E "error:|fatal error:" "$LOG" | head -20 >&2 || true
  exit 1
fi

echo "$SUMMARY"
grep -E "\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG" | tail -1 || true
echo
echo "full log: $LOG"

# The count grows with the suite; the point is the order of magnitude, not the
# figure. 1005 tests in 92 suites as of patch 322b. A run reporting tens rather
# than hundreds built a fraction of the target.
COUNT="$(sed -E 's/.*Test run with ([0-9]+) tests.*/\1/' <<< "$SUMMARY")"
if [[ "$COUNT" =~ ^[0-9]+$ ]] && (( COUNT < 500 )); then
  echo "error: only $COUNT tests ran. The suite has held four figures since 322;" >&2
  echo "       a number this small means most of the target did not build." >&2
  exit 1
fi

exit "$STATUS"
