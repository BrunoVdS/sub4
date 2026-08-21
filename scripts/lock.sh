#!/usr/bin/env bash
# Sub4 — one exclusive holder per repository, for anything that drives the
# simulator or writes shared evidence.
#
# Patch 435, ADR-0003 §12.190. Task 0A tranche 4 of
# docs/PLAN-post-B5-database-cutover-execution.md.
#
# WHY THIS EXISTS
# ---------------
# `xcodebuild test` mutates a simulator and DerivedData, and `test.sh` wrote
# every run's output to one path, `/tmp/sub4-test.log`. Two runs at once
# therefore did three things at once: fought over a simulator, fought over
# DerivedData — CLAUDE.md already records that pair as producing
# `invalid reuse after initialization failure` on files that are fine — and
# overwrote each other's evidence.
#
# The third is the dangerous one. A suite that fails can have its log replaced
# by a suite that passes, and the reader is looking at a summary of a run that
# is not the one they started. **Evidence that can be overwritten by a
# concurrent run is evidence nobody can cite.**
#
# WHY A DIRECTORY AND NOT A FILE
# ------------------------------
# `mkdir` is atomic on POSIX and needs no `flock`, which macOS does not ship.
# Creating the directory IS acquiring the lock; there is no test-then-create
# window for a second process to win.
#
# WHY IT IS KEYED ON THE REPOSITORY AND KEPT OUT OF IT
# ----------------------------------------------------
# Scoped to the repository, because two checkouts are two independent bodies of
# work and neither should block the other. Stored under the system temporary
# directory, because `.gitignore`'s own rule is that this repository holds
# source and nothing a local session produces — and a lock left behind by a
# killed process must not turn up in `git status` as a mystery.
#
# STALE LOCKS ARE RECLAIMED, NOT WAITED ON
# ----------------------------------------
# The holder's PID is written inside. A lock whose holder is gone is a crash or
# a `kill -9`, and refusing forever on the strength of it would make the next
# honest run look like contention. It is reclaimed, LOUDLY — silence there would
# make a real overlap indistinguishable from a tidy-up.

sub4_lock_path() {
  # One key per checkout. `cksum` is in POSIX and needs no shasum/md5 choice.
  local repo key
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  key="$(printf '%s' "$repo" | cksum | tr -d ' \t' )"
  printf '%s/sub4-%s.lock' "${TMPDIR:-/tmp}" "$key"
}

# sub4_lock_acquire <what>
# Sets SUB4_LOCK_DIR on success. Returns 1 if another live run holds it.
sub4_lock_acquire() {
  local what="${1:-a run}" dir holder
  dir="$(sub4_lock_path)"

  # **INHERITED, NOT RE-TAKEN.** `preflight.sh` holds the lock for its whole
  # run and then calls `test.sh`, which would otherwise refuse its own parent.
  # A nested caller adopts the lock and — through `SUB4_LOCK_INHERITED` — does
  # not release it on the way out, because the outer run is still using the
  # simulator it protects.
  if [[ -n "${SUB4_LOCK_DIR:-}" && -d "${SUB4_LOCK_DIR}" ]]; then
    holder="$(cat "${SUB4_LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
      SUB4_LOCK_INHERITED=1
      export SUB4_LOCK_INHERITED
      return 0
    fi
  fi

  if ! mkdir "$dir" 2>/dev/null; then
    holder="$(cat "$dir/pid" 2>/dev/null || true)"
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
      echo "error: another Sub4 run already holds this repository's lock." >&2
      echo "       holder: pid $holder — $(cat "$dir/what" 2>/dev/null || echo "unknown")" >&2
      echo "       started: $(cat "$dir/started" 2>/dev/null || echo "unknown")" >&2
      echo "       Two runs share a simulator, DerivedData and their evidence." >&2
      echo "       Wait for it, or stop it. Do not delete $dir while it runs." >&2
      return 1
    fi
    # LOUD, because a stale lock and a real overlap must not look alike.
    echo "note: reclaiming a stale lock left by pid ${holder:-unknown}" >&2
    rm -rf "$dir"
    mkdir "$dir" || { echo "error: could not take $dir" >&2; return 1; }
  fi

  printf '%s' "$$"                       > "$dir/pid"
  printf '%s' "$what"                    > "$dir/what"
  date -u +%Y-%m-%dT%H:%M:%SZ            > "$dir/started"
  SUB4_LOCK_DIR="$dir"
  export SUB4_LOCK_DIR
  return 0
}

# Releases only a lock this process owns. A run that reclaimed a stale lock and
# was then itself superseded must not delete its successor's.
sub4_lock_release() {
  local dir="${SUB4_LOCK_DIR:-}"
  # An inherited lock belongs to the outer run and is its to release.
  [[ -z "${SUB4_LOCK_INHERITED:-}" ]] || return 0
  [[ -n "$dir" && -d "$dir" ]] || return 0
  if [[ "$(cat "$dir/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$dir"
  fi
  unset SUB4_LOCK_DIR
}
