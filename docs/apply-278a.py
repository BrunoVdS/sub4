#!/usr/bin/env python3
"""
Patch 278a — two lines the sweep missed.

  1. `dropInMemory()` assigns `rejected = []`, and `rejected` is now computed.
     The sweep grep was `\\.rejected\\b` — which requires a dot, and a bare
     assignment has none.

  2. `RejectionReceipt.line` is nonisolated and reads `a.km`, which is a
     MainActor-isolated computed property. `distance` beside it is a stored
     property and needs nothing. The 264a lesson, in a file written to avoid it.

No AppVersion bump: a fix-up inside 278.

Run from ~/Documents/Developer/sub4/Sub4/docs
Stops without changing anything if any anchor is missing or not unique.
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


# ------------------------------------------- 1. the assignment the sweep missed

edit(
    "Sub4/ActivityStore.swift",
    r'''    func dropInMemory() {
        activities = []
        rejected = []''',
    r'''    func dropInMemory() {
        activities = []
        // `receipts` since patch 278 — `rejected` is computed from it now.
        // This line is why 278 did not build: the sweep looked for
        // `.rejected`, and an assignment has no dot in front of it.
        receipts = []''',
    "dropInMemory clears the receipts",
)

# ------------------------------------------------- 2. the isolated computed km

edit(
    "Sub4/Sub4Import+Rejection.swift",
    r'''        return String(format: "%@ %@ — %.1f km in %d:%02d = %.0f km/h avg, max %.0f",
                      String(a.startLocal.prefix(10)), a.name,
                      a.km, mins, secs, kmh, maxKmh)''',
    r'''        // `a.distance / 1000` AND NOT `a.km`. `Activity` is a plain struct, so
        // the type is main-actor by default: its STORED properties are
        // nonisolated and its COMPUTED ones are not, unless they say so —
        // `dayKey` two lines above `km` says `nonisolated` and `km` does not.
        // This function was main-actor where it used to live and is not here.
        return String(format: "%@ %@ — %.1f km in %d:%02d = %.0f km/h avg, max %.0f",
                      String(a.startLocal.prefix(10)), a.name,
                      a.distance / 1000, mins, secs, kmh, maxKmh)''',
    "the label stops reaching for an isolated property",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''### 12.24.5 Two lines the sweep missed — patch 278a

Patch 278 did not build. Both failures are rules this document already states,
and both are worth recording at the point they were broken rather than only at
the point they were written down.

**1. The sweep pattern was narrower than the sweep.** `rejected` went from a
stored property to a computed one, so every WRITE to it had to move. The search
used was `\.rejected\b` — which requires a dot, and `dropInMemory()`'s
`rejected = []` has none. The rule says *"enumerate every USE of every value
whose type changed"*; a member-access pattern finds reads and misses
assignments. **Grep for the bare identifier, then filter.**

Worse: `dropInMemory` had already been read aloud in the same session, while
establishing that nothing prunes this table. It was looked at for one question
and not remembered for the other.

**2. `a.km` is main-actor and `a.distance` is not.** `Activity` is a plain
`struct`, so the type is main-actor by default; its stored properties are
implicitly nonisolated and its computed ones inherit the isolation unless they
say otherwise. `dayKey` says `nonisolated` — two lines above `km`, which does
not.

`rejectionLabel` was a `private static func` on a main-actor class and could
read `km` freely. Moving it onto a `nonisolated struct` changed that, and
nothing in the move signalled it. This is §12.17's isolation lesson for the
fourth time, and the shape is always the same: **code that moves from an
isolated home to a nonisolated one inherits nothing and must be re-read line by
line, not just re-indented.**

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.24.5",
)


def fail(msg):
    print("STOPPED — nothing was changed.")
    print("  " + msg)
    sys.exit(1)


buffers, applied = {}, []
for path, old, new, why in EDITS:
    if not path.exists():
        fail(f"missing: {path}")
    text = buffers.get(path, path.read_text())
    if new in text:
        fail(f"already applied? {path.name} — {why}")
    n = text.count(old)
    if n != 1:
        fail(f"{path.name} — {why}: expected one match, found {n}")
    buffers[path] = text.replace(old, new)
    applied.append((path, why))

if "--check" in sys.argv:
    print(f"All {len(applied)} anchors found. Nothing written (--check).")
    sys.exit(0)

for path, text in buffers.items():
    path.write_text(text)
for path, why in applied:
    print(f"  {path.relative_to(ROOT)} — {why}")
print(f"Done. {len(buffers)} files, {len(applied)} edits.")
