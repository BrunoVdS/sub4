#!/usr/bin/env bash
# Proves the repository lock without running the suite twice — patch 435,
# §12.190, and the runbook asks for exactly that: "test contention without
# launching two full suites."
#
# Two real `xcodebuild test` runs would take four minutes, need two simulators
# to be honest about, and would be run once and never again. These are the four
# properties the lock actually has to hold, each in a fraction of a second.

set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lock.sh

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok — $*"; }

DIR="$(sub4_lock_path)"
rm -rf "$DIR"

echo "1. a free lock is taken"
sub4_lock_acquire "selftest" || fail "could not take a free lock"
[[ -d "$DIR" ]] || fail "no lock directory"
[[ "$(cat "$DIR/pid")" == "$$" ]] || fail "the holder is not this process"
ok "held by $$"

echo "2. a second live holder is refused"
# **`env -u SUB4_LOCK_DIR`, AND THAT IS THE WHOLE POINT OF THE TEST.** A bare
# subshell is a CHILD of the holder and inherits the lock on purpose — that is
# property 6, and it is what lets `preflight.sh` call `test.sh`. An independent
# run is a fresh invocation that never saw the variable, so the test has to
# model that rather than a child. The first draft did not, and it turned a
# passing inheritance into a failing contention.
# `set +e` because refusal IS the pass.
set +e
env -u SUB4_LOCK_DIR -u SUB4_LOCK_INHERITED \
  bash -c '. scripts/lock.sh; sub4_lock_acquire "intruder"' 2>/dev/null
SECOND=$?
set -e
(( SECOND != 0 )) || fail "a second run took a lock somebody else holds"
ok "refused, status $SECOND"

echo "3. releasing frees it"
sub4_lock_release
[[ ! -d "$DIR" ]] || fail "release left the lock behind"
ok "gone"

echo "4. a stale lock is reclaimed rather than waited on"
unset SUB4_LOCK_DIR SUB4_LOCK_INHERITED
mkdir "$DIR"
# A pid that cannot be alive: the kernel's own reserved 0 is not a user process,
# so `kill -0` fails for it exactly as it would for a dead holder.
printf '%s' 99999999 > "$DIR/pid"
printf '%s' "a run that was killed" > "$DIR/what"
sub4_lock_acquire "after a crash" 2>/dev/null || fail "a stale lock blocked a new run"
[[ "$(cat "$DIR/pid")" == "$$" ]] || fail "the stale lock was not taken over"
ok "reclaimed"
sub4_lock_release

echo "5. a release does not remove somebody else's lock"
mkdir "$DIR"; printf '%s' 12345 > "$DIR/pid"
SUB4_LOCK_DIR="$DIR" sub4_lock_release || true
[[ -d "$DIR" ]] || fail "released a lock this process did not hold"
ok "left alone"
rm -rf "$DIR"


echo "6. a nested run inherits the lock and does not release it"
sub4_lock_acquire "outer" || fail "outer could not take the lock"
OUTER="$DIR"
( . scripts/lock.sh
  sub4_lock_acquire "inner" || exit 3
  [[ "${SUB4_LOCK_INHERITED:-}" == "1" ]] || exit 4
  sub4_lock_release ) || fail "the nested run refused its own parent ($?)"
[[ -d "$OUTER" ]] || fail "the nested run released its parent's lock"
ok "inherited, and left standing"
sub4_lock_release
[[ ! -d "$OUTER" ]] || fail "the outer run could not release"
ok "outer released"

echo
echo "all lock properties hold"
