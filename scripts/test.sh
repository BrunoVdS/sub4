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

# --- one run at a time, and one log per run — patch 435, §12.190 ---
#
# `LOG` was `/tmp/sub4-test.log` for every run. Two suites at once overwrote
# each other's output, so a failing run's evidence could be replaced by a
# passing one and the reader would be looking at a summary of a run they did
# not start. The runbook's preamble had to carry a manual workaround —
# "prove no other suite is running and set a unique SUB4_LOG" — which is a rule
# nobody can be relied on to follow. This is that rule as code.
RUN_ID="${SUB4_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
LOG="${SUB4_LOG:-${TMPDIR:-/tmp}/sub4-test-$RUN_ID.log}"

# shellcheck source=scripts/lock.sh
. "$(dirname "$0")/lock.sh"
sub4_lock_acquire "test.sh $RUN_ID" || exit 1
# TRAP-SAFE. A lock that survives ⌃C is a lock that blocks the next honest run,
# and the first thing anybody does then is delete it by hand — which is how a
# lock stops being believed.
trap 'sub4_lock_release' EXIT INT TERM

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

# --- source invariants, before anything slow — patch 373, §12.117 ---
#
# These are rules that each caught a real defect once and then died with the
# patch that wrote them. A sum that must name every declared counter (369a) and
# a store that must refuse before it writes (372) are facts no expression in
# the app states, so neither the compiler nor the suite can see them.
#
# FIRST, and fatal. It costs a second, and a violation means the build is wrong
# whatever the simulator goes on to say — running the tests first would only
# delay the same answer by two minutes. `preflight.sh` gets it for nothing.
if [[ -f scripts/check-invariants.py ]]; then
  python3 scripts/check-invariants.py
  echo
else
  echo "error: scripts/check-invariants.py is missing." >&2
  echo "       It is not optional: it is the only thing re-running the checks" >&2
  echo "       that caught 369a and 372. See ADR-0003 §12.117." >&2
  exit 1
fi

echo "scheme:      $SCHEME"
echo "destination: $DEST"
echo "run:         $RUN_ID"
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

# PATCH 403 — WARNINGS ARE READ NOW. §12.147: one slipped past this script and
# past the Release build, and was found by eye in Xcode. Same shape as the
# summary guard above — a gate that does not read its own output is a gate that
# looks like a pass.
echo
./scripts/no-warnings.sh "$LOG" "test build"
echo
echo "full log: $LOG"
# A stable name for the newest run, for a human who does not want to read a
# timestamp. It is a CONVENIENCE and never the evidence: the run-stamped file
# above is what an acceptance manifest cites, because a symlink is exactly the
# shared mutable path this patch exists to stop relying on.
ln -sfn "$LOG" "${TMPDIR:-/tmp}/sub4-test-latest.log" 2>/dev/null || true

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
