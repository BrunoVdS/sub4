#!/usr/bin/env python3
"""
Patch 299 — do not reimplement the writer. Call it.

298 printed both values and the screen said:

    17463863070 — fetched: store    2026-08-04T17:58:58Z,
                           database 2026-08-04T17:58:58Z

Two dates that render identically, reported as different. `Sub4Import.iso8601`
is the function that WROTE that column, so if two instants produce the same
output from it the database cannot tell them apart — and a comparison that does
is disagreeing with the writer rather than reporting on the data.

It also explains why the importer said `0 replaced` about the same row: its rule
for an unchanged trace is string equality on the writer's own output. The
importer was right, and had been all along.

Three versions of four lines:

    291    .rounded()   →  320 of 668 differing
    291a   floor()      →  1 of 668, and 1 of 645 recordings
    299    iso8601(a) == iso8601(b)

291a's note said "a comparison has to model what the writer did, not what would
be tidy". Correct, and one word short: FLOORING IS STILL A MODEL. A better model
is still a second implementation of something that already exists.

And the tests missed it twice because they checked chosen pairs against a chosen
rule. The property is "a date must agree with what the database holds for it,
for every date" — asserted now, and it would have failed at 291 and 291a.

Files touched
  Sub4/ActivityDetailRepository.swift              sameSecond
  Sub4CoreTests/ActivityDetailRepositoryTests.swift  + StoredDateTests
  docs/ADR-0003-database-contract.md               + §12.43
  Sub4/AppVersion.swift                            299

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


DET = "Sub4/ActivityDetailRepository.swift"
TDET = "Sub4CoreTests/ActivityDetailRepositoryTests.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(
    DET,
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
    r'''    /// THE WRITER'S OWN FUNCTION, not a model of it — 299, and this is the
    /// third version of four lines of code. The history is the point.
    ///
    /// **291: `.rounded()`.** The read-back reported `fetched` differing on
    /// **320 of 668** details. 47.9%, which is how many timestamps carry a
    /// fractional second of 0.5 or more — the proportion was the diagnosis.
    /// `ISO8601DateFormatter` with `.withInternetDateTime` drops the fraction
    /// rather than rounding it, so a store value of x.6 was written as x and
    /// compared as x+1, and disagreed with itself.
    ///
    /// **291a: `floor()`.** 320 became **1**, and the note written at the time
    /// said *"a comparison has to model what the writer did, not what would be
    /// tidy."* Correct, and it stopped one word short. Flooring is still a
    /// MODEL of the writer.
    ///
    /// **298 made the last one legible** by printing both values, and the
    /// screen said:
    ///
    ///     17463863070 — fetched: store 2026-08-04T17:58:58Z,
    ///                   database 2026-08-04T17:58:58Z
    ///
    /// The two dates render identically and the comparison called them
    /// different. That is proof — whatever the mechanism — that `floor` on a
    /// `TimeInterval` and Foundation's calendar arithmetic do not agree on
    /// every instant, and one of them is the one that actually wrote the row.
    ///
    /// **299: call the writer.** `Sub4Import.iso8601` is the function that
    /// produced `fetchedUTC`. Comparing its output cannot drift from it,
    /// because it is not an approximation of the writer — it IS the writer.
    /// It is also exactly what `Sub4Import+Recording` does when it decides a
    /// trace is unchanged, which is why the importer said `0 replaced` about
    /// the same row this reported as a difference. The importer was right.
    ///
    /// The name still holds: the database is second-precision by construction,
    /// and this asks whether two instants land on the same stored second.
    ///
    /// **The general form, and it has cost three patches to learn:** when a
    /// comparison and a writer must agree, do not reimplement the writer.
    /// Call it.
    static func sameSecond(_ a: Date, _ b: Date) -> Bool {
        Sub4Import.iso8601(a) == Sub4Import.iso8601(b)
    }
''',
    "sameSecond calls the writer",
)

edit(
    TDET,
    r'''    @Test("Both lists are sorted, so the screen does not reshuffle")
    func bothListsAreSorted() throws {
        let r = DetailRoundTrip.compare(store: [detail("3"), detail("1"), detail("2")],
                                        database: [])
        #expect(r.missing == ["1", "2", "3"])
    }
}''',
    r'''    @Test("Both lists are sorted, so the screen does not reshuffle")
    func bothListsAreSorted() throws {
        let r = DetailRoundTrip.compare(store: [detail("3"), detail("1"), detail("2")],
                                        database: [])
        #expect(r.missing == ["1", "2", "3"])
    }
}

// MARK: -

/// The invariant that three versions of `sameSecond` did not hold — patch 299,
/// ADR-0003 §12.43.
///
/// `aDateAlwaysAgreesWithItsStoredForm` is the whole patch. Every earlier test
/// of this function checked chosen pairs of dates against a chosen rule, and
/// each version passed its own tests while disagreeing with the writer on real
/// data — 320 details at 291, one recording and one detail at 291a.
///
/// The property is not "these two dates compare thus". It is **a date must
/// agree with what the database holds for it**, for every date, and that is the
/// thing a hand-chosen pair cannot express.
@Suite
@MainActor
struct StoredDateTests {

    /// Around a real value from the device — `2026-08-04T17:58:58Z`, which is
    /// the recording that survived 291a.
    private let base = 1_786_139_938.0

    /// THE ONE WITH TEETH, and it is a property rather than a case.
    @Test("A date always agrees with its own stored form")
    func aDateAlwaysAgreesWithItsStoredForm() throws {
        for delta in [-0.999_999, -0.5, -0.001, -0.000_001, -0.000_000_01,
                      0.0,
                      0.000_000_01, 0.001, 0.4, 0.5, 0.6, 0.999, 0.999_999] {
            let d = Date(timeIntervalSince1970: base + delta)
            let stored = Sub4Import.iso8601(d)
            let back = try #require(ActivityDetailRepository.parseUTC(stored),
                                    "the writer's output must be parseable")
            let why = "delta \(delta) stored as \(stored)"
            #expect(DetailRoundTrip.sameSecond(d, back), "\(why)")
        }
    }

    /// The other half. A comparison that returns true for everything holds the
    /// property above trivially and is worthless.
    @Test("Dates a whole second apart still differ")
    func awholeSecondStillDiffers() {
        let a = Date(timeIntervalSince1970: base)
        for delta in [-2.0, -1.0, 1.0, 2.0, 60.0, 86_400.0] {
            #expect(!DetailRoundTrip.sameSecond(a, a.addingTimeInterval(delta)),
                    "\(delta)")
        }
    }

    /// 291's original finding, kept as a case because the number 320 is worth
    /// remembering: a fraction of 0.5 or more must not round up.
    @Test("A fraction is dropped, not rounded")
    func aFractionIsDropped() {
        let a = Date(timeIntervalSince1970: base)
        #expect(DetailRoundTrip.sameSecond(a.addingTimeInterval(0.6), a))
        #expect(DetailRoundTrip.sameSecond(a.addingTimeInterval(0.999), a))
        #expect(DetailRoundTrip.sameSecond(a, a.addingTimeInterval(0.3)))
    }

    /// It agrees with the importer BY CONSTRUCTION, and that is the point of
    /// 299 rather than a happy consequence: `Sub4Import+Recording` decides a
    /// trace is unchanged with `iso8601(store.fetched) == recording.fetchedUTC`,
    /// and this now runs the same comparison.
    @Test("It agrees with the rule the importer uses to skip a trace")
    func itAgreesWithTheImporter() throws {
        for delta in [-0.000_000_01, 0.0, 0.4, 0.6, 0.999] {
            let d = Date(timeIntervalSince1970: base + delta)
            let stored = Sub4Import.iso8601(d)
            let back = try #require(ActivityDetailRepository.parseUTC(stored))

            // The importer's test, spelled out.
            let importerSaysUnchanged = Sub4Import.iso8601(d) == stored
            #expect(importerSaysUnchanged, "\(stored)")
            #expect(DetailRoundTrip.sameSecond(d, back) == importerSaysUnchanged,
                    "the reader and the importer must never disagree")
        }
    }
}
''',
    "StoredDateTests — the property, not the pairs",
)

edit(
    ADR,
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.43 Do not reimplement the writer. Call it. — patch 299

Four lines of code, three versions, three patches, and the third one is the
lesson.

### 12.43.1 What 298 put on the screen

    17463863070 — fetched: store    2026-08-04T17:58:58Z,
                           database 2026-08-04T17:58:58Z

**The two dates render identically and the comparison called them different.**

That is a proof, and it does not depend on knowing why. `Sub4Import.iso8601` is
the function that wrote `fetchedUTC`. If two instants produce the same output
from it, the database cannot tell them apart, and a comparison that does is
disagreeing with the writer rather than reporting on the data.

It also explains the contradiction §12.42.1 recorded: the importer said `0
replaced` about this row, because the importer's rule for an unchanged trace is
`iso8601(store.fetched) == recording.fetchedUTC` — string equality on the
writer's own output. **The importer was right. It had been right all along.**

### 12.43.2 The three versions

| patch | rule | `fetched` differing |
|---|---|---|
| 291 | `.rounded()` | **320 of 668** |
| 291a | `floor()` | **1 of 668**, and 1 of 645 recordings |
| 299 | `Sub4Import.iso8601(a) == Sub4Import.iso8601(b)` | expected 0 — see §12.43.5 |

291's note, written at the fix, said:

> **A comparison has to model what the writer did, not what would be tidy.**
> Truncation is not an approximation of rounding.

Correct, and one word short. **Flooring is still a model of the writer.** It was
a much better model — 320 down to 1 — and a better model is still a second
implementation of something that already exists, which means it can differ from
the original, which means eventually it will.

The general form, and it cost three patches:

> **When a comparison and a writer must agree, do not reimplement the writer.
> Call it.**

### 12.43.3 What is proven and what is inferred

Kept apart on purpose — §12.29.2.1 is in this file because a conclusion was once
written from a measurement that did not exist.

**Proven.** `floor` on a `TimeInterval` and `ISO8601DateFormatter` do not agree
on every instant. The screen is the evidence: two dates, one rendering, one
disagreement.

**Inferred, and not needed for the fix.** The likely mechanism is an instant a
hair below a second boundary, where Foundation's calendar arithmetic and a
`Double` floor land on different sides. The store holds this trace's `fetched`
as a decoded JSON number, which is exactly where such a value comes from.

The fix does not rest on the inference. Calling the writer is correct whatever
the mechanism, and if the count does not go to zero the inference was wrong and
the finding is still real.

### 12.43.4 Why the tests did not catch it, twice

Every test of `sameSecond` from 291 onward checked **chosen pairs of dates
against a chosen rule**: a fraction of 0.6 compares equal, two seconds apart do
not. Each version passed its own tests and disagreed with the writer on real
data.

The property was never the pairs. It is:

> **A date must agree with what the database holds for it.** For every date.

`aDateAlwaysAgreesWithItsStoredForm` asserts exactly that — round-trip a date
through the writer and the parser and require agreement — across a spread of
fractions including boundary-adjacent ones. It would have failed at 291 and at
291a. `itAgreesWithTheImporter` pins the other half by spelling out the
importer's rule and requiring the two to reach the same verdict.

This is §12.16's warning in a new place. Equal counts hide changed values; here,
passing cases hid a wrong rule. **A test that checks the examples you thought of
cannot check the rule.**

### 12.43.5 The prediction

Stated so it can be falsified, the way §12.39.5 was:

**The next recording read-back reports `fetched 0`, and the next detail
read-back reports 12 differing rather than 13** — the `fetched` row leaving the
detail tally with the eleven `laps[*].averageHR` and one `splits[*].averageHR`
still there, because those are the importer's intended `positiveOrNil`
normalisation and nothing in this patch touches them.

If either number is different, the inference in §12.43.3 was wrong and there is
a second cause. The measurement goes in §12.43.6, after the run.

## 12.10 The athlete profile, the zones and the resting series''',
    "§12.43",
)

edit(
    VER,
    r'''    static let patch = 298''',
    r'''    static let patch = 299''',
    "299",
)


# --------------------------------------------------------------------- machinery

def main():
    check = "--check" in sys.argv
    print(f"ROOT = {ROOT}")
    if not (ROOT / "Sub4.xcodeproj").exists():
        print("!! that is not the project root — expected Sub4.xcodeproj beside Sub4/")
        return 1

    failures = 0
    writes = {}
    for path, old, new, why in EDITS:
        if not path.exists():
            print(f"MISSING  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        text = writes.get(path, path.read_text(encoding="utf-8"))
        if new in text and old not in text:
            print(f"already  {path.relative_to(ROOT)}  ({why})")
            continue
        n = text.count(old)
        if n != 1:
            print(f"ANCHOR x{n}  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        writes[path] = text.replace(old, new, 1)
        print(f"ok       {path.relative_to(ROOT)}  ({why})")

    if failures:
        print(f"\n{failures} anchor(s) failed — nothing written.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. run the suite")
    print("  2. ⌘R, Settings → Database, both read-backs")
    print("  3. PREDICTED: recordings `fetched 0`; details 12 differing not 13,")
    print("     with laps[*].averageHR 11 and splits[*].averageHR 1 unchanged.")
    print("     Anything else and §12.43.3's inference was wrong.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
