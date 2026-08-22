#!/usr/bin/env bash
# Proves the package validator refuses what it claims to refuse — patch 445,
# ADR-0003 §12.201.
#
# The runbook names the fixtures: "exact success, omitted DB, missing
# preference, partial snapshot, changed same-count file, tampered manifest,
# hot-WAL input, duplicate/unsafe path, mismatched pre/post state, an
# unowned-writer negative control, low-space/interrupt output and deterministic
# repeat." This is that list, plus four the shape of the manifest owes.
#
# EACH CASE CHECKS THE REASON, NOT ONLY THE EXIT STATUS. A validator that fails
# for the wrong reason will pass the day the real defect arrives — §12.191.3,
# and 444 lost a sabotage to exactly that three patches ago.
#
# The fixtures are BUILT, not committed: a package holds a SQLite file, and a
# committed binary whose hash must stay in step with a JSON file beside it rots
# the first time either is touched.

set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT
ID="2026-08-22-081500"
V="python3 scripts/validate-evidence-package.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok — $*"; }

python3 scripts/make-evidence-package-fixture.py "$FIXTURES" > /dev/null

# refuses <fixture> <expected substring> <description>
refuses() {
  local name="$1" want="$2" what="$3" out status
  set +e
  out="$($V "$FIXTURES/$name/$ID" 2>&1)"
  status=$?
  set -e
  (( status == 1 )) || fail "$what: expected exit 1, got $status
$out"
  grep -qF -- "$want" <<< "$out" || fail "$what: failed, but not for the stated reason.
wanted a line containing: $want
got:
$out"
  ok "$what"
}

echo "1. EXACT SUCCESS — a package that is entirely true"
OUT="$($V "$FIXTURES/good/$ID")" || fail "the good fixture did not validate:
$OUT"
grep -q "no problems" <<< "$OUT" || fail "expected a clean pass:
$OUT"
CHECKS="$(sed -E 's/.*ok — ([0-9]+) checks.*/\1/' <<< "$(grep 'ok —' <<< "$OUT")")"
(( CHECKS > 20 )) || fail "only $CHECKS checks ran; a pass that examined almost
nothing reads exactly like a pass that examined everything"
ok "$CHECKS checks, no problems"

echo "2. OMITTED DATABASE — the .xcappdata's headline failure"
refuses no-database "is recorded and MISSING" "the database is gone"

echo "3. MISSING PREFERENCE — the snapshot is preference-inclusive or it is not"
refuses missing-preference "preferences.json" "the preference supplement is gone"

echo "4. PARTIAL SNAPSHOT — every hash still matches, and a file is missing"
refuses partial-snapshot "the snapshot says it copied are not in the package" \
        "a file the snapshot copied is not carried"

echo "5. CHANGED SAME-COUNT FILE — identical length, different bytes"
refuses same-count-changed-file "is STALE" "a file changed without changing size"

echo "6. TAMPERED MANIFEST"
refuses tampered-manifest "is STALE" "the manifest's recorded hash was edited"

echo "7. HOT WAL — the copy's hash would describe half of it"
refuses hot-wal "journal sidecars sit beside the database copy" "a live journal"

echo "8. UNSAFE PATH"
refuses unsafe-path "climbs out of the package" "a path escaping the package"

echo "9. DUPLICATE PATH"
refuses duplicate-path "is listed twice" "the same file recorded twice"

echo "10. MISMATCHED PRE/POST — the package's central claim"
refuses moved-during-capture "the two fingerprints disagree" "something moved"

echo "11. THE UNOWNED-WRITER NEGATIVE CONTROL"
# The barrier catches an unowned writer by the fingerprints disagreeing; the
# validator catches a package that hid the fact by not saying what it did not
# watch. Both halves, because either alone can be talked around.
refuses unwatched-unexplained "gives no reason" "an unwatched location with no reason"

echo "12. LOW SPACE OR INTERRUPT — what a half-finished copy leaves"
refuses truncated-database "is STALE" "a truncated database copy"

echo "13. A PACKAGE THAT CLAIMS TO BE A RESTORE ARTIFACT"
refuses restore-claim "supported restore artifact" "a diagnostic copy claiming to be a backup"

echo "14. A SCHEMA VERSION THIS VALIDATOR CANNOT READ"
refuses bad-version "is not one this validator knows" "a package from elsewhere"

echo "15. A FILE RECORDED AS ABSENT, PRESENT ANYWAY"
refuses resurrected-absence "are in the package anyway" "a declared absence that is there"

echo "16. THE FOLDER AND THE MANIFEST DISAGREE ABOUT WHICH CAPTURE THIS IS"
refuses wrong-capture-id "the package folder is" "a mismatched capture id"

echo "17. THE SNAPSHOT'S OWN MANIFEST DISAGREES WITH THE OUTER ONE"
refuses inner-manifest-disagrees "does not match the one" \
        "an inner manifest edited to match its own hash"

echo "18. A DECLARED EMPTY DIRECTORY REPLACED BY SOMETHING ELSE"
refuses directory-became-a-file "does not hold one" "a directory that is not one"

echo "19. VALIDATING NOTHING IS NOT A PASS"
set +e
$V > /dev/null 2>&1
STATUS=$?
set -e
(( STATUS == 2 )) || fail "an empty run exited $STATUS; it must be 2"
ok "exit 2"

echo "20. DETERMINISTIC REPEAT"
A="$($V "$FIXTURES/good/$ID")"
B="$($V "$FIXTURES/good/$ID")"
[[ "$A" == "$B" ]] || fail "two runs over one package disagree:
$(diff <(echo "$A") <(echo "$B") || true)"
ok "identical output"

echo "21. AND IT NEVER WRITES TO WHAT IT READS"
# A validator that tidied its input would destroy the evidence it was asked to
# check — and a package is often the only copy of the state it describes.
BEFORE="$(find "$FIXTURES/good/$ID" -type f -exec shasum -a 256 {} \; | sort)"
$V "$FIXTURES/good/$ID" > /dev/null
AFTER="$(find "$FIXTURES/good/$ID" -type f -exec shasum -a 256 {} \; | sort)"
[[ "$BEFORE" == "$AFTER" ]] || fail "the validator changed the package it read:
$(diff <(echo "$BEFORE") <(echo "$AFTER") || true)"
ok "the package is byte-identical afterwards"

echo
echo "all evidence-package properties hold"
