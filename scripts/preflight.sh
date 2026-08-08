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

echo "=== 1/3  working tree ==="
git status --short
if [[ -n "$(git status --porcelain)" ]]; then
  echo "note: uncommitted changes above — that is fine, just know what they are."
fi
echo

echo "=== 2/3  test suite (simulator) ==="
./scripts/test.sh
echo

echo "=== 3/3  Release build ==="
# A Release-only problem is plausible and has happened; this stood in for CI
# on 2026-08-04 and passed.
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -quiet
echo "Release build OK"
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
