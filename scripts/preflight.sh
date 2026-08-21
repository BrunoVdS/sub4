#!/usr/bin/env bash
# Full local verification. Run before anything destructive, and before any
# migration lands on the phone.
#
# CI is NOT a check: the free GitHub Actions allowance is spent until
# 2026-09-01, and exhaustion looks like an instant failure of every job.
# Local verification is the source of truth. See docs/context/ci-budget.md.

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${SUB4_SCHEME:-Sub4}"
PROJECT="Sub4.xcodeproj"

# --- one preflight at a time, and one log per run — patch 435, §12.190 ---
#
# `test.sh` takes the lock for its own stage, but stage 3's Release build drives
# the same DerivedData and wrote to one shared `/tmp/sub4-release.log`. Holding
# the lock across the WHOLE run is what makes "preflight passed" a statement
# about one tree rather than about whichever run finished last; `test.sh`
# inherits it rather than refusing its own parent.
RUN_ID="${SUB4_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
export SUB4_RUN_ID="$RUN_ID"
# shellcheck source=scripts/lock.sh
. "$(dirname "$0")/lock.sh"
sub4_lock_acquire "preflight.sh $RUN_ID" || exit 1
trap 'sub4_lock_release' EXIT INT TERM

echo "=== 1/4  working tree ==="
git status --short
if [[ -n "$(git status --porcelain)" ]]; then
  echo "note: uncommitted changes above — that is fine, just know what they are."
fi
echo

echo "=== 2/4  test suite (simulator) ==="
./scripts/test.sh
echo

echo "=== 3/4  Release build ==="
# A Release-only problem is plausible and has happened; this stood in for CI
# on 2026-08-04 and passed.
# NO `-quiet`, AND THAT IS PATCH 403. The flag hid swift-testing's summary
# from 318 to 325 and this script's own header records what that cost; it hides
# WARNINGS just as completely, so the Release configuration — the one that
# ships, and the one a Debug-only gate cannot see — was unreadable here too.
# Output goes to a log; only the lines worth reading reach the terminal.
RELEASE_LOG="${SUB4_RELEASE_LOG:-${TMPDIR:-/tmp}/sub4-release-$RUN_ID.log}"
set +e
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  > "$RELEASE_LOG" 2>&1
STATUS=$?
set -e
if (( STATUS != 0 )); then
  grep -E "error:|\*\* BUILD FAILED \*\*" "$RELEASE_LOG" | head -20 >&2 || true
  echo "error: the Release build failed. Read $RELEASE_LOG." >&2
  exit "$STATUS"
fi
echo "Release build OK"
./scripts/no-warnings.sh "$RELEASE_LOG" "Release build"
echo

echo "=== 4/4  evidence manifests ==="
# PATCH 438, §12.193. The runbook's later tasks key off the word "accepted" in
# these files, so the files have to be machine-evaluable — and the checker has
# to be provably able to refuse. `selftest-evidence.sh` drives the four
# failures the runbook names by hand (invalid, missing, stale, circular) plus
# the four the runner and the shape owe, in under a second.
./scripts/selftest-evidence.sh
echo
# And then the REAL manifests, if any exist yet. A glob that matches nothing is
# not an empty pass here: the validator exits 2 when given no input, so the
# absence is stated rather than skipped.
REAL=()
while IFS= read -r m; do REAL+=("$m"); done < <(
  find docs/evidence/post-b5 -maxdepth 1 -name '*.json' \
       ! -name 'manifest.schema.json' | sort)
if (( ${#REAL[@]} )); then
  python3 scripts/evidence-manifest.py validate "${REAL[@]}"
else
  echo "no accepted evidence manifests yet — docs/evidence/post-b5/ holds the"
  echo "schema, the fixtures and PROGRESS.md, and nothing claiming acceptance."
fi
echo

cat <<'EOF'
--- what this does NOT cover ---
Six of eleven Phase 2 defects were hardware-only. The simulator cannot answer
anything about real activity data, HealthKit, the Keychain, or on-device row
counts — and the app logs nothing, so the console cannot confirm success either.

Before a destructive change, also:
  - take a fresh protected snapshot on the device (the patch-247 one is stale)
  - ask Bruno to read the numbers off the phone
EOF
