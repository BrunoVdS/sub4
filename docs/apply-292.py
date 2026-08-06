#!/usr/bin/env python3
"""
Patch 292 — D6a's third reader: recordings.

Split from its comparison the way 289 was from 290. 645 recordings and 192,954
samples is enough for one patch; the round trip and the read-back row follow.

Design settled in docs/D6A-RECORDING-GROUNDWORK.md before any code existed.

TWO NEW FILES, so this needs ⌘Q and a reopen:
  Sub4/RecordingRepository.swift
  Sub4CoreTests/RecordingRepositoryTests.swift

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
    r'''## 12.38 The recording reader — D6a, patch 292

The last of the three. Split from its comparison the way §12.35 was from
§12.36 — 645 recordings and 192,954 samples is enough for one patch.

### 12.38.1 A third meaning for `ordinal`

Across four child tables the project now has three conventions:

| table | `ordinal` is |
|---|---|
| `activity_split` | `split.index` — a domain value, 1-based |
| `activity_lap` | `lap.index` — a domain value |
| `activity_best_effort` | the array position |
| `recording_sample` | the array position |

`recording_sample` behaves like best efforts: ordered by, then discarded.
`ActivityStreams` has no per-sample identity at all, so there is nowhere to put
it and nothing to match on.

`recording_sample` is also the only child table with a **composite primary key**
— `(recordingID, ordinal)` — and no `id` column.

### 12.38.2 Four renames, and `power` is the one

`speed → speedMS`, `altitude → altitudeM`, `grade → gradePercent`, and
**`power → watts`**. The last has its own named test because it is the one that
would be typed straight through and produce a reader that silently drops every
power trace.

### 12.38.3 One at a time, not all at once

`ids(_:)` then `streams(_:storeID:)`. All 645 recordings materialised together
is roughly 12 MB of `Double` — survivable and pointless, since the comparison
builds one, checks it and discards it.

`all(_:)` exists for the tests and says in its own comment that the comparison
should not use it. `ActivityDetailRepository.all` materialises everything
because 668 details is nothing; copying that shape here would have been the
easy wrong answer.

### 12.38.4 The lossy step, named rather than discovered

The importer writes `at(series, i)`:

```swift
guard let series, i < series.count else { return nil }
```

`nil` for an absent array **and** `nil` past its end — no padding, no default.
Two consequences, both irreversible:

1. **A stream shorter than `distanceM`** was stored with trailing NULLs and
   cannot be told apart on the way back from a full-length stream missing its
   tail. The reader reconstructs at `distanceM.count` and does not guess at
   trimming.
2. **A NULL inside a present stream** becomes `0`. `[Double]?` cannot hold a
   per-element nil, and zero is already what `ActivityStreams.has(_:)` reads as
   nothing there — it tests `contains { $0 > 0 }`.

`aShortStreamIsPadded` asserts the loss rather than hiding it, so it is a
decision somebody made and can find, not a surprise the comparison springs.

### 12.38.5 Absent and all-zero are one bit apart

`series(_:_:)` returns `nil` only when **every** sample is NULL. That single
rule decides whether `has(.power)` is true, and `has` decides whether a chart
is drawn at all — so "this ride had no power meter" and "this ride had power
that read zero" are one bit apart in the database and a whole feature apart in
the app. `theAbsentStreamStaysAbsent` is the test with teeth for that reason.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.38",
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
