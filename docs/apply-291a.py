#!/usr/bin/env python3
"""
Patch 291a — the writer truncates and the comparison rounded.

The detail read-back reported `fetched` differing on 320 of 668 details. That
number IS the diagnosis: 47.9%, which is how many timestamps you would expect
to carry a fractional second of 0.5 or more.

`ISO8601DateFormatter` with `.withInternetDateTime` DROPS the fraction — it
truncates. `sameSecond` used `.rounded()`. So a store timestamp of x.6 was
written as x and compared as x+1, and disagreed with itself.

The reader is right and the database is right. The comparison was wrong, and it
was wrong in the direction that manufactures work: 320 differences that are not
differences.

A LETTER FIX-UP: ships `AppVersion.swift` with `patch = 291`, `revision = "a"`.

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


R = "Sub4/ActivityDetailRepository.swift"
T = "Sub4CoreTests/ActivityDetailRepositoryTests.swift"

edit(
    R,
    r'''    /// SECOND PRECISION, and it is not defensive clutter — the column holds
    /// `.withInternetDateTime` text and cannot store a fraction. A comparison
    /// demanding exactness asks the database for something it was never
    /// designed to hold.
    static func sameSecond(_ a: Date, _ b: Date) -> Bool {
        a.timeIntervalSince1970.rounded() == b.timeIntervalSince1970.rounded()
    }''',
    r'''    /// SECOND PRECISION, TRUNCATED — 291a, and the correction is the finding.
    ///
    /// This used `.rounded()`, and the read-back reported `fetched` differing
    /// on 320 of 668 details. 47.9% — which is how many timestamps carry a
    /// fractional second of 0.5 or more.
    ///
    /// `ISO8601DateFormatter` with `.withInternetDateTime` DROPS the fraction;
    /// it does not round it. So a store timestamp of x.6 was written as x and
    /// compared as x+1, and disagreed with itself. The reader was right, the
    /// database was right, and the comparison manufactured 320 differences
    /// that were not differences.
    ///
    /// **A comparison has to model what the writer did, not what would be
    /// tidy.** Truncation is not an approximation of rounding.
    static func sameSecond(_ a: Date, _ b: Date) -> Bool {
        floor(a.timeIntervalSince1970) == floor(b.timeIntervalSince1970)
    }''',
    "sameSecond truncates, like the writer",
)

edit(
    T,
    r'''    @Test("Dates are compared to the second")
    func datesAreComparedToTheSecond() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(DetailRoundTrip.sameSecond(base, base.addingTimeInterval(0.3)))
        #expect(!DetailRoundTrip.sameSecond(base, base.addingTimeInterval(2)))
    }''',
    r'''    /// TRUNCATED, NOT ROUNDED — 291a. The writer drops the fraction, so the
    /// comparison must too. Rounding reported 320 of 668 details as differing
    /// on `fetched` when nothing differed at all.
    @Test("Dates are compared by truncation, the way the writer stores them")
    func datesAreTruncatedNotRounded() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)

        // The case that was broken: a fraction of 0.5 or more. The writer
        // stores `base`; rounding turned this into base + 1.
        #expect(DetailRoundTrip.sameSecond(base.addingTimeInterval(0.6), base),
                "x.6 is written as x and must compare equal to x")
        #expect(DetailRoundTrip.sameSecond(base.addingTimeInterval(0.999), base))

        #expect(DetailRoundTrip.sameSecond(base, base.addingTimeInterval(0.3)))
        #expect(!DetailRoundTrip.sameSecond(base, base.addingTimeInterval(2)))
        // A whole second apart is still a difference, from either side.
        #expect(!DetailRoundTrip.sameSecond(base.addingTimeInterval(1), base))
    }''',
    "the truncation regression test",
)

edit(
    "docs/ADR-0003-database-contract.md",
    r'''### 12.37.4 The loss it reports rather than hides''',
    r'''### 12.37.4 What the read-back found, on the first run

**`fetched`, 320 of 668 — and the comparison was the defect.**

`sameSecond` rounded. `ISO8601DateFormatter` truncates. A store timestamp of
x.6 was written as x and compared as x+1, so it disagreed with itself; 47.9%
of timestamps carry a fraction of 0.5 or more, and 320/668 is 47.9%.

**The number was the diagnosis.** Not "some dates differ" — a proportion that
could only come from one cause. That is the argument for reporting by field
with counts rather than by row: `fetched 320` is a hypothesis, and it was the
right one on sight.

Corrected in 291a. The rule it earns: **a comparison has to model what the
writer did, not what would be tidy.** Truncation is not an approximation of
rounding, and the two disagree on exactly half the data.

**`laps[*].averageHR`, spread thinly across many lap indices** — the
`positiveOrNil` normalisation, predicted in §12.37.5 and confirmed. Intended,
and left alone.

**Four details in the store and not in the database** — the activities synced
since the last import, the same staleness the activity read-back measures.

### 12.37.5 The loss it reports rather than hides''',
    "§12.37.4 records the finding",
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
