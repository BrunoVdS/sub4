#!/usr/bin/env bash
# Fail if a build log contains warnings from this project's own sources.
#
# WHY THIS EXISTS — patch 403, ADR-0003 §12.147
# --------------------------------------------
# On 17 August `CommuteStore.restore` bound a value it never used. The suite was
# green, the Release build succeeded, and BOTH GATES PASSED OVER IT. Bruno found
# it in Xcode's issue navigator — which means the project's stated gate had a
# hole only a human looking at the right pane could close.
#
# §6 already says a warning-shaped defect needs a test. Nothing read them.
#
# THE PATH ANCHOR IS THE WHOLE TRICK
# ----------------------------------
# A build log is full of warnings that are not ours: GRDB's, the SDK's, and
# Apple's `appintentsmetadataprocessor` announcing it found no AppIntents
# framework. Filtering those by KEYWORD would be a blacklist that rots — the
# next tool with a new message reopens the hole silently.
#
# So this anchors on PATH: a warning counts only if it comes from a file under
# the two folders `project.pbxproj` synchronizes. Those are the same two roots
# RULE 10 names, and they are what "our source" means.
#
# HARD FAIL, NOT A CEILING
# ------------------------
# `UNPROTECTED_STORE_CEILING` is a ceiling because that debt predated its rule
# by two hundred patches. Here the tree was at ZERO when this was written, so
# there is nothing to grandfather and a ceiling would only invite the first one.
#
# ONE SCRIPT, TWO CALLERS. `test.sh` reads the Debug log and `preflight.sh` the
# Release one — a Release-only warning is exactly the kind a Debug-only gate
# would pass over, and two copies of this rule could disagree about what counts.
# §12.43.

set -euo pipefail

LOG="${1:-}"
LABEL="${2:-build}"

if [[ -z "$LOG" ]]; then
  echo "usage: no-warnings.sh <log-file> [label]" >&2
  exit 2
fi

# NOT SILENT WHEN IT CANNOT RUN. A missing log means this checked nothing, and
# the one thing a gate must never do is look like a gate that passed. §12.15,
# and the same reason `test.sh` fails when it sees no summary line.
if [[ ! -f "$LOG" ]]; then
  echo "error: $LOG does not exist, so no warning check happened." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOUND="$(grep -E "^${ROOT}/(Sub4|Sub4CoreTests)/.*warning:" "$LOG" | sort -u || true)"

if [[ -n "$FOUND" ]]; then
  echo
  echo "--- warnings in project sources ($LABEL) ---" >&2
  echo "$FOUND" >&2
  echo >&2
  echo "error: the $LABEL produced warnings in this project's own sources." >&2
  echo "       Until patch 403 neither gate read them, so a green suite AND a" >&2
  echo "       successful Release build both passed over one. The tree was at" >&2
  echo "       zero when this gate was installed: there is no debt here to" >&2
  echo "       grandfather, and the first warning to arrive is the one to fix." >&2
  exit 1
fi

echo "no warnings in project sources ($LABEL)"
