#!/usr/bin/env python3
"""
Patch 291 — D6a's second reader: activity detail.

Four tables, three nested arrays. Design settled in docs/D6A-DETAIL-GROUNDWORK.md
and docs/D6A-DETAIL-DECISIONS.md before a line was written, which is why this is
one patch and not three.

TWO NEW FILES, so this needs ⌘Q and a reopen:
  Sub4/ActivityDetailRepository.swift
  Sub4CoreTests/ActivityDetailRepositoryTests.swift

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


H = "Sub4/DatabaseHealthView.swift"

edit(
    H,
    r'''    @State private var readingBack = false''',
    r'''    @State private var readingBackDetail = false
    @State private var detailTrip: DetailRoundTrip.Report?
    @State private var detailLoad: DetailLoad?
    @State private var readingBack = false''',
    "the detail read-back state",
)

edit(
    H,
    r'''    private func runReadBack(_ db: Sub4Database) {''',
    r'''    /// PATCH 291. The same shape as the activity read-back, one level down.
    @ViewBuilder
    private func detailReadBackSection(_ db: Sub4Database) -> some View {
        Section {
            if readingBackDetail {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            } else {
                Button("Read the details back out") { runDetailReadBack(db) }
            }

            if let load = detailLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            }

            if let r = detailTrip {
                LabeledContent("Compared", value: "\(r.compared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Agreed on every field", value: "\(r.agreed)")
                    .font(.caption)
                    .foregroundStyle(r.agreed == r.compared ? Color.dim : Color.ink)
                if !r.missing.isEmpty {
                    LabeledContent("In the store, not in the database",
                                   value: "\(r.missing.count)")
                        .font(.caption).foregroundStyle(.red)
                }
                // The tally first — "all on splits[*].averageHR" is one known
                // cause; a list of ids is an afternoon.
                ForEach(r.fieldTally.prefix(12), id: \.field) { entry in
                    LabeledContent("  \(entry.field)", value: "\(entry.count)")
                        .font(.caption2).foregroundStyle(.red)
                }
                if r.fieldTally.count > 12 {
                    Text("  + \(r.fieldTally.count - 12) more fields")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            }
        } header: {
            Text("Read-back · details")
        } footer: {
            Text("The same comparison one level down: splits, laps and best "
                 + "efforts, matched by index and by name rather than by "
                 + "position. A heart rate the importer normalised to nothing "
                 + "is expected to show here — see ADR-0003 §12.37.")
                .font(.caption2)
        }
    }

    private func runDetailReadBack(_ db: Sub4Database) {
        readingBackDetail = true
        let store = Array(DetailStore.shared.details.values)
        Task {
            let load = ActivityDetailRepository.all(db)
            detailLoad = load
            detailTrip = load.details.map {
                DetailRoundTrip.compare(store: store, database: $0)
            }
            readingBackDetail = false
        }
    }

    private func runReadBack(_ db: Sub4Database) {''',
    "the detail read-back section",
)

edit(
    H,
    r'''                readBackSection(db)''',
    r'''                readBackSection(db)
                detailReadBackSection(db)''',
    "the section is shown",
)

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.37 The detail reader — D6a, patch 291

Four tables and three nested arrays, against `Activity`'s one table and twenty
scalars. Designed in `D6A-DETAIL-GROUNDWORK.md` and settled in
`D6A-DETAIL-DECISIONS.md` **before any code existed**, which is why it is one
patch — 289's `gearID` trap was found the same way and cost one fix-up rather
than a week of parity noise.

### 12.37.1 The ordinal is not one thing

All three child tables carry `ordinal`, NOT NULL, `>= 0`, unique per parent.
Read from `Sub4Import+Recording.swift`:

| table | `ordinal` is |
|---|---|
| `activity_split` | `split.index` — a domain value, 1-based |
| `activity_lap` | `lap.index` — a domain value |
| `activity_best_effort` | `i` — the array position, 0-based |

So `Split` and `Lap` take their `index` **from** the ordinal; `BestEffort` has
no index property at all — its identity is `name` — and its ordinal is ordered
by and then discarded.

Getting this backwards gives splits numbered from zero, or best efforts in
whatever order SQLite chose. **Neither fails a count comparison**, which is
§12.16's warning arriving in a place nobody would look for it.

### 12.37.2 Matched by identity, so ordering stopped being a question

The groundwork asked whether the store's arrays are in the order the importer
enumerated. The answer is not to find out: splits and laps match on `index`,
best efforts on `name`, and then neither side's order matters.

Three things fell out of that, all improvements. Failure messages name a
kilometre — `splits[index: 7].movingTime` — rather than an array slot.
**Missing** and **surplus** separate from **differing**, so a count mismatch is
not reported as nineteen field disagreements. And the ordering claim shrinks to
one small thing a single test pins.

### 12.37.3 The date, to the second

`fetched` is the only type change in the mapping. `Sub4Import.iso8601` is
`.withInternetDateTime` with no fractional seconds, and the store's value was
itself decoded from a second-precision string — so it round-trips.

`sameSecond` rounds both sides anyway. Not defensive clutter: **the column
cannot hold a fraction**, so a comparison demanding exactness asks the database
for something it was never designed to store. The case it protects is a
`fetched` set from `Date()` in memory and compared before any save.

### 12.37.4 The loss it reports rather than hides

The importer writes `positiveOrNil(...)` for **both** `split.averageHR` and
`lap.averageHR` — the groundwork said laps only, which was wrong and is
corrected here. A stored zero becomes NULL and comes back `nil`.

That is the importer's deliberate normalisation, and this reader **reports it**.
A reader that invented a zero to make the comparison green would be lying to
turn a screen a different colour, and the whole value of a read-back is that it
is believable when it says nothing differs.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.37",
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
