#!/usr/bin/env python3
"""
Patch 289 — D6a begins. The first thing that reads the database.

`ActivityRepository` is read-only and nothing calls it. That is the point:
shadow parity needs a reader before it needs anything else, and "can the
database give back what the store holds" is answerable NOW in a test rather
than as divergence on 669 rows six weeks from now.

TWO NEW FILES, so this needs ⌘Q and a reopen:
  Sub4/ActivityRepository.swift
  Sub4CoreTests/ActivityRepositoryTests.swift

The apply script only adds ADR §12.35.

Run from ~/Documents/Developer/sub4/Sub4/docs
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.35 The first reader — D6a, patch 289

### 12.35.1 Read-only, and called by nothing

`ActivityRepository` reads and does not write. Writes are D6b's. It is wired
into no screen, and that is deliberate — a reader on a screen before parity
has run is D7 arriving by accident, and §12.27's test would not catch it
because the flag would still be false.

What it buys immediately is the question D6c exists to ask, asked six weeks
early and in a test: **can the database give back what the store holds?**

### 12.35.2 Four renames and a trap

The `activity` table round-trips a full `Activity`, but five of the names
differ:

| `Activity` | column |
|---|---|
| `id` | `activity_source_record.externalID` — `activity.id` is a minted UUID |
| `sportType` | `sportLabel` — nullable |
| `isTrainer` | `isIndoor` |
| `deviceWatts` | `hasPowerMeter` |
| `maxSpeed` | `maxSpeedMS` |
| `gearId` | **not `activity.gearID`** — see below |

**The trap.** `activity.gearID` holds the CANONICAL gear id, which is §3.1's
whole purpose; `Activity.gearId` holds Strava's, because that is what
`AthleteStore.shoes` is keyed by. Reading the column straight through hands
every one of the 479 gear-bearing activities an id that matches nothing, and
shadow parity reports it as a data divergence rather than as a join this
reader got wrong.

**And the column is not always set.** When the importer cannot resolve the
gear — a retired shoe, a bike added after the last athlete fetch — `gearID`
stays null and the name Strava gave is recorded in `activity_gear_reference`.
A reader looking only at the column loses gear on precisely those rows. Hence
the second `LEFT JOIN` and the `COALESCE`, and
`unresolvedGearStillComesBack` is what holds it.

### 12.35.3 The fifth instance of one idea

`ActivityLoad` distinguishes a read that ran from one that could not:
`StoreLoad` for a file (§12.15), `Reading` for a Health query (§12.28.3),
`RouteCensus` for one measure inside it (§12.32.4), `hasRoute: Bool?` for one
field (§12.31.3), and now this for a table.

`activities` returns `[Activity]?` and not `[]`, so a caller cannot reach the
happy path without deciding what an untrustworthy read means. **An empty
training history is a legitimate answer on a fresh install**, which is exactly
why it must not be reachable by the same path as a failure.

### 12.35.4 `skipped` — honest about its own coverage

A row with no `sportLabel` cannot become an `Activity`, because `sportType` is
not optional. Mapping null to `""` would produce an activity whose
`discipline` is nil — an activity of no sport, which is worse than an absent
one.

So such rows are **counted**, not dropped. A reader that quietly returns fewer
rows than the table holds is what shadow parity would report as missing data,
and the count is the difference between a reader that is wrong and one that
says where it stopped.

### 12.35.5 A query built rather than concatenated

The first version appended `AND r.externalID = ?` to a statement ending in
`ORDER BY a.startUTC DESC`, which is not SQL. Caught while writing, and
recorded because the shape is the lesson: **text added to the end of a query
only works while nothing is at the end.** `statement(and:)` composes the
clauses instead.

Ordering is by `startUTC`, which §4.1 makes authoritative for order —
`startLocal` is authoritative for BELONGING. Ordering by the wrong one is
invisible until two sessions fall either side of midnight.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.35",
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
