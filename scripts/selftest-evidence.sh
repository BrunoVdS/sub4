#!/usr/bin/env bash
# Proves the evidence-manifest validator refuses what it claims to refuse —
# patch 438, ADR-0003 §12.193.
#
# The runbook names four failures by hand: "Prove invalid/missing/stale/circular
# manifests fail before any later task treats them as machine-evaluable." This
# is that sentence as code, plus the two the shape check owes and the two the
# runner owes.
#
# EACH CASE CHECKS THE REASON, NOT ONLY THE EXIT STATUS. A validator that fails
# for the wrong reason is a validator that will pass the day the real defect
# arrives — §12.191.3, where a grep for failures was read as a pass because it
# printed nothing.

set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURES="docs/evidence/post-b5/fixtures"
V="python3 scripts/evidence-manifest.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok — $*"; }

# refuses <dir> <expected substring> <description>
refuses() {
  local dir="$1" want="$2" what="$3" out status
  set +e
  out="$($V validate "$FIXTURES/$dir"/*.json 2>&1)"
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

echo "1. a manifest chain that is entirely true passes"
OUT="$($V validate "$FIXTURES/valid"/*.json)" || fail "the valid fixture did not validate:
$OUT"
grep -q "2 of 2 manifests validate" <<< "$OUT" || fail "expected 2 of 2:
$OUT"
grep -q "NOT recomputed" <<< "$OUT" || fail "the fixture names a commit that is not HEAD,
so the validator must SAY it did not recompute the tree digest rather than
passing in silence. It did not say so:
$OUT"
ok "2 of 2, and the un-recomputable digest is named rather than assumed"

echo "2. INVALID — shape, version, format and a binding that names another commit"
refuses invalid "missing required key 'owner'"      "a required key nobody stated"
refuses invalid "unknown key 'extra'"               "a key nobody reads"
refuses invalid "is not one this validator knows"   "a schemaVersion from elsewhere"
refuses invalid "names a different commit"          "binding.commit ≠ tree.commit"

echo "3. MISSING — an evidence file that is not there"
refuses missing "is MISSING" "a cited file that does not exist"

echo "4. STALE — an evidence file that moved after it was cited"
refuses stale "is STALE" "a cited file whose bytes changed"

echo "5. STALE — a predecessor revised underneath the manifest citing it"
refuses stale-predecessor "revised after this manifest cited it" "a revised predecessor"

echo "6. MISSING — a predecessor nobody wrote"
refuses missing-predecessor "is MISSING" "a predecessor id with no manifest"

echo "7. CIRCULAR — a predecessor chain that closes on itself"
refuses circular "is CIRCULAR" "a cycle"

echo "8. an acceptance with nobody's name against it"
refuses unsigned "an acceptance nobody signed" "status accepted, approval null"

echo "9. a manifest citing no evidence at all"
refuses empty "proves nothing" "an empty evidence list"

echo "10. a file that is not JSON is a failure, not a skip"
refuses notjson "is not valid JSON" "unparseable input"

echo "11. VALIDATING NOTHING IS NOT A PASS"
# The failure this whole script exists downstream of: a run that examined no
# input and exited 0 reads exactly like a run that examined everything.
set +e
$V validate >/dev/null 2>&1
STATUS=$?
set -e
(( STATUS == 2 )) || fail "an empty run exited $STATUS; it must be 2"
ok "exit 2"

echo "12. --require-recompute turns 'I could not check' into a failure"
# The acceptance run uses this. Without it the tree digest is a number nobody
# recomputed, and §12.15's whole point is that such a number reads like an
# answer.
set +e
OUT="$($V validate --require-recompute "$FIXTURES/valid"/*.json 2>&1)"
STATUS=$?
set -e
(( STATUS == 1 )) || fail "--require-recompute passed a digest it could not recompute"
grep -q "NOT recomputed" <<< "$OUT" || fail "wrong reason:
$OUT"
ok "refused"

echo "13. the tree digest is deterministic"
A="$($V digest)"; B="$($V digest)"
[[ "$A" == "$B" ]] || fail "two digests of one tree differ: $A vs $B"
[[ "${#A}" == 64 ]] || fail "the digest is not a sha256: $A"
ok "$A"

echo
echo "all evidence-manifest properties hold"
