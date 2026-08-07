#!/usr/bin/env python3
"""
Patch 295 — the tally that could not be read.

294's first run showed the DETAIL report doing exactly what §12.39.2 designed
the recording report around: thirteen details differing for one known reason,
printed as twenty-five tally rows with "+ 13 more fields" underneath.

Every key was correct. The report was still useless.

  · `tallyKey` collapses the element identity FOR GROUPING ONLY —
    `laps[index: 12].averageHR` → `laps[*].averageHR`.
  · `Difference.fields` is untouched, and the section now prints the first
    five ids with their precise names, so the collapsed row still leads to a
    lap somebody can open.
  · Each row carries two numbers: how many details, and how many elements.

Also fixes the comment at 291 that described `[*]` output the code never
produced — kept and amended rather than deleted, because having believed it is
the useful part. §12.40.5.

Files touched
  Sub4/ActivityDetailRepository.swift     + tallyKey, fieldTally rewritten
  Sub4/DatabaseHealthView.swift           the detail section, + fieldSummary
  Sub4CoreTests/ActivityDetailRepositoryTests.swift  + DetailTallyTests
  Sub4/AppVersion.swift                   295
  docs/ADR-0003-database-contract.md      + §12.40

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


REPO = "Sub4/ActivityDetailRepository.swift"
VIEW = "Sub4/DatabaseHealthView.swift"
TESTS = "Sub4CoreTests/ActivityDetailRepositoryTests.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

# ------------------------------------------------------------------ 1. the tally

edit(
    REPO,
    r'''        var fieldTally: [(field: String, count: Int)] {
            var counts: [String: Int] = [:]
            for d in differences { for f in d.fields { counts[f, default: 0] += 1 } }
            return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { (field: $0.key, count: $0.value) }
        }''',
    r'''        /// TWO NUMBERS PER ROW — patch 295, and the second one is new.
        ///
        /// `details` is how many DETAILS carry this field at all; `elements` is
        /// how many splits, laps or efforts inside them do. Thirteen details
        /// each with one bad lap and thirteen details with forty bad laps
        /// between them are the same first number and nothing alike in the
        /// second — the same wide-versus-deep split §12.39.2 built into the
        /// recording report.
        ///
        /// Grouped by `tallyKey`, so one cause is one row. See its comment for
        /// what that run actually looked like without it.
        var fieldTally: [(field: String, details: Int, elements: Int)] {
            var details: [String: Int] = [:]
            var elements: [String: Int] = [:]
            for d in differences {
                var seen: Set<String> = []
                for f in d.fields {
                    let key = DetailRoundTrip.tallyKey(f)
                    elements[key, default: 0] += 1
                    if seen.insert(key).inserted { details[key, default: 0] += 1 }
                }
            }
            return details.map { (field: $0.key,
                                  details: $0.value,
                                  elements: elements[$0.key] ?? 0) }
                .sorted { a, b in
                    if a.details != b.details { return a.details > b.details }
                    if a.elements != b.elements { return a.elements > b.elements }
                    return a.field < b.field
                }
        }
''',
    "fieldTally groups by tallyKey and counts two things",
)

edit(
    REPO,
    r'''    static func compare(store: [ActivityDetail], database: [ActivityDetail]) -> Report {''',
    r'''    /// THE TALLY KEY — patch 295, ADR-0003 §12.40.
    ///
    /// `differingFields` names an element precisely on purpose:
    /// `laps[index: 12].averageHR` is a lap somebody can open, and §12.37.2
    /// chose identity over position exactly so it would be. That precision is
    /// right on the difference and wrong on the tally.
    ///
    /// The first real run showed why. Thirteen details differed, one cause —
    /// the importer's `positiveOrNil` on a zero heart rate — and the tally had
    /// twenty-five keys, because every lap index is its own key. The screen
    /// truncated at twelve and printed "+ 13 more fields", so a single known
    /// normalisation arrived looking like twenty-five unrelated problems with
    /// an unknown number hidden behind a cut-off.
    ///
    /// This is the same defect §12.39.2 designed the recording report AROUND,
    /// found in the report written four patches earlier. The fix is to collapse
    /// the element identity **for grouping only**: `laps[*].averageHR`, one
    /// row, count thirteen. The precise name stays on `Difference.fields`,
    /// where it still leads to a lap.
    ///
    /// Rules, matching exactly what `differingFields` emits:
    ///
    ///     laps[index: 12].averageHR   →  laps[*].averageHR
    ///     bestEfforts[1k].seconds     →  bestEfforts[*].seconds
    ///     splits missing 12           →  splits missing
    ///     bestEfforts surplus 1500m   →  bestEfforts surplus
    ///     calories                    →  calories
    static func tallyKey(_ field: String) -> String {
        if let open = field.firstIndex(of: "["),
           let close = field.firstIndex(of: "]"),
           open < close {
            return String(field[..<open]) + "[*]"
                + String(field[field.index(after: close)...])
        }
        for word in [" missing ", " surplus "] {
            if let r = field.range(of: word) {
                return String(field[..<r.lowerBound]) + String(word.dropLast())
            }
        }
        return field
    }

    static func compare(store: [ActivityDetail], database: [ActivityDetail]) -> Report {''',
    "tallyKey",
)

# ------------------------------------------------------------------- 2. the view

edit(
    VIEW,
    r'''                // The tally first — "all on splits[*].averageHR" is one known
                // cause; a list of ids is an afternoon.
                ForEach(r.fieldTally.prefix(12), id: \.field) { entry in
                    LabeledContent("  \(entry.field)", value: "\(entry.count)")
                        .font(.caption2).foregroundStyle(.red)
                }
                if r.fieldTally.count > 12 {
                    Text("  + \(r.fieldTally.count - 12) more fields")
                        .font(.caption2).foregroundStyle(Color.dim)
                }''',
    r'''                // The tally first, and this comment was RIGHT before the code
                // was — "all on splits[*].averageHR" is what it always meant to
                // say, and until 295 the tally could not say it. §12.40.
                ForEach(r.fieldTally.prefix(12), id: \.field) { entry in
                    LabeledContent("  \(entry.field)",
                                   value: entry.elements == entry.details
                                       ? "\(entry.details)"
                                       : "\(entry.details) · \(entry.elements) elements")
                        .font(.caption2).foregroundStyle(.red)
                }
                if r.fieldTally.count > 12 {
                    Text("  + \(r.fieldTally.count - 12) more fields")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                // AND THE IDS. Collapsing the tally moved the lap index out of
                // it, so it has to arrive here or it is gone from the screen —
                // a summary that leaves nothing to open is a dead end.
                ForEach(r.differences.prefix(5)) { d in
                    Text("    \(d.id) — \(fieldSummary(d.fields))")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.differences.count > 5 {
                    Text("    + \(r.differences.count - 5) more")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
''',
    "the detail tally, and the ids under it",
)

edit(
    VIEW,
    r'''    private func runDetailReadBack(_ db: Sub4Database) {''',
    r'''    /// The precise names, trimmed. `laps[*].averageHR` in the tally says WHAT;
    /// this says which laps, on the ids it prints, so the collapsed row still
    /// leads somewhere.
    private func fieldSummary(_ fields: [String]) -> String {
        let shown = fields.prefix(4).joined(separator: ", ")
        return fields.count > 4 ? shown + " + \(fields.count - 4)" : shown
    }

    private func runDetailReadBack(_ db: Sub4Database) {''',
    "fieldSummary",
)

edit(
    VIEW,
    r'''                 + "position. A heart rate the importer normalised to nothing "
                 + "is expected to show here — see ADR-0003 §12.37.")''',
    r'''                 + "position. A heart rate the importer normalised to nothing "
                 + "is expected to show here, as one row rather than one per "
                 + "lap — see ADR-0003 §12.37 and §12.40.")''',
    "the footer says what the tally now does",
)

# ------------------------------------------------------------------ 3. the tests

edit(
    TESTS,
    r'''        // A whole second apart is still a difference, from either side.
        #expect(!DetailRoundTrip.sameSecond(base.addingTimeInterval(1), base))
    }
}''',
    r'''        // A whole second apart is still a difference, from either side.
        #expect(!DetailRoundTrip.sameSecond(base.addingTimeInterval(1), base))
    }
}

// MARK: -

/// The tally, after the first real run — patch 295, ADR-0003 §12.40.
///
/// `oneCauseIsOneRow` is the one with teeth, and it is a test about grouping
/// rather than about data. Thirteen details differed on the device for a single
/// known reason and the tally printed twenty-five keys with a "+ 13 more
/// fields" cut-off underneath. Every one of those keys was correct. The tally
/// was still useless, which is the whole point: a correct summary that cannot
/// be read is a summary that will be ignored, and then trusted when it is
/// finally read wrong.
@Suite
@MainActor
struct DetailTallyTests {

    private func lap(_ index: Int, hr: Double?) -> ActivityDetail.Lap {
        .init(index: index, distanceM: 1000, movingTime: 300, averageHR: hr)
    }

    private func detail(_ id: String,
                        laps: [ActivityDetail.Lap] = [],
                        splits: [ActivityDetail.Split] = [],
                        efforts: [ActivityDetail.BestEffort] = [],
                        calories: Double? = 812) -> ActivityDetail {
        ActivityDetail(activityId: id, calories: calories,
                       splits: splits, bestEfforts: efforts, laps: laps,
                       fetched: Date(timeIntervalSince1970: 1_785_000_000))
    }

    // MARK: The key

    @Test("The tally key drops the element identity and keeps the field")
    func theTallyKeyCollapses() {
        #expect(DetailRoundTrip.tallyKey("laps[index: 12].averageHR")
                    == "laps[*].averageHR")
        #expect(DetailRoundTrip.tallyKey("splits[index: 3].movingTime")
                    == "splits[*].movingTime")
        #expect(DetailRoundTrip.tallyKey("bestEfforts[1k].seconds")
                    == "bestEfforts[*].seconds")
        #expect(DetailRoundTrip.tallyKey("splits missing 12") == "splits missing")
        #expect(DetailRoundTrip.tallyKey("bestEfforts surplus 1500m")
                    == "bestEfforts surplus")
    }

    /// A scalar has no element identity to drop, and must come through whole.
    /// `fetched` collapsing to something else would have hidden 291a.
    @Test("A scalar field is its own key")
    func aScalarIsUnchanged() {
        for name in ["calories", "fetched", "polyline", "descriptionText"] {
            #expect(DetailRoundTrip.tallyKey(name) == name)
        }
    }

    // MARK: The tally

    /// THE ONE WITH TEETH. One cause, many laps, two details — one row.
    @Test("One cause across many laps is one tally row, not many")
    func oneCauseIsOneRow() {
        let storeA = detail("a", laps: [lap(1, hr: 140), lap(2, hr: 141), lap(3, hr: 142)])
        let dbA = detail("a", laps: [lap(1, hr: nil), lap(2, hr: nil), lap(3, hr: nil)])
        let storeB = detail("b", laps: [lap(1, hr: 150), lap(2, hr: 151)])
        let dbB = detail("b", laps: [lap(1, hr: nil), lap(2, hr: nil)])

        let r = DetailRoundTrip.compare(store: [storeA, storeB],
                                        database: [dbA, dbB])
        #expect(r.compared == 2)
        #expect(r.agreed == 0)

        #expect(r.fieldTally.map(\.field) == ["laps[*].averageHR"],
                "one cause, one row — not five")
        #expect(r.fieldTally.map(\.details) == [2], "two details carry it")
        #expect(r.fieldTally.map(\.elements) == [5], "across five laps")
    }

    /// Wide and deep are different questions and the row answers both. Two
    /// details off by one lap each, and one detail off by four, are the same
    /// `details` and nothing alike.
    @Test("Details and elements are counted separately")
    func detailsAndElementsAreDifferentNumbers() {
        let store = detail("a", laps: [lap(1, hr: 140), lap(2, hr: 141),
                                       lap(3, hr: 142), lap(4, hr: 143)])
        let db = detail("a", laps: [lap(1, hr: nil), lap(2, hr: nil),
                                    lap(3, hr: nil), lap(4, hr: nil)])
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        #expect(r.fieldTally.map(\.details) == [1])
        #expect(r.fieldTally.map(\.elements) == [4])
    }

    /// The tally collapses; the difference does not. §12.37.2 chose identity
    /// over position so a reader could open the lap, and that has to survive
    /// the fix to the thing above it.
    @Test("The difference keeps the index the tally drops")
    func theDifferenceKeepsTheIndex() {
        let store = detail("a", laps: [lap(7, hr: 140)])
        let db = detail("a", laps: [lap(7, hr: nil)])
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        #expect(r.differences.first?.fields == ["laps[index: 7].averageHR"])
        #expect(r.fieldTally.map(\.field) == ["laps[*].averageHR"])
    }

    /// Two genuinely different causes must stay two rows. A collapse that
    /// merged everything would read even more cleanly and say nothing.
    @Test("Different fields stay different rows")
    func differentFieldsStayApart() {
        let store = detail("a", laps: [lap(1, hr: 140)], calories: 812)
        let db = detail("a", laps: [lap(1, hr: nil)], calories: 900)
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        #expect(Set(r.fieldTally.map(\.field))
                    == ["laps[*].averageHR", "calories"])
    }

    /// Missing and surplus carry a count in the name too, and it is the same
    /// problem: twelve missing splits should not be twelve rows.
    @Test("Missing and surplus collapse, and stay distinct from each other")
    func missingAndSurplusCollapse() {
        let store = detail("a", splits: [
            .init(index: 1, distanceM: 1000, movingTime: 300, elapsedTime: 310,
                  elevationDiff: 0, averageHR: 140),
            .init(index: 2, distanceM: 1000, movingTime: 300, elapsedTime: 310,
                  elevationDiff: 0, averageHR: 141)])
        let db = detail("a", splits: [
            .init(index: 8, distanceM: 1000, movingTime: 300, elapsedTime: 310,
                  elevationDiff: 0, averageHR: 140),
            .init(index: 9, distanceM: 1000, movingTime: 300, elapsedTime: 310,
                  elevationDiff: 0, averageHR: 141)])
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        let keys = Set(r.fieldTally.map(\.field))
        #expect(keys == ["splits missing", "splits surplus"])
        #expect(r.fieldTally.allSatisfy { $0.elements == 2 })
        #expect(r.fieldTally.allSatisfy { $0.details == 1 })
    }

    @Test("Nothing differing is an empty tally, not a zero row")
    func agreementIsAnEmptyTally() {
        let d = detail("a", laps: [lap(1, hr: 140)])
        let r = DetailRoundTrip.compare(store: [d], database: [d])
        #expect(r.agreed == 1)
        #expect(r.fieldTally.isEmpty)
    }

    /// Ordered by how many details carry it, so the biggest cause is first —
    /// which is what makes the top row readable without scrolling.
    @Test("The biggest cause is first")
    func orderedByReach() {
        let store = [detail("a", laps: [lap(1, hr: 140)], calories: 812),
                     detail("b", laps: [lap(1, hr: 150)], calories: 812),
                     detail("c", laps: [lap(1, hr: 160)], calories: 812)]
        let db = [detail("a", laps: [lap(1, hr: nil)], calories: 812),
                  detail("b", laps: [lap(1, hr: nil)], calories: 812),
                  detail("c", laps: [lap(1, hr: 160)], calories: 900)]
        let r = DetailRoundTrip.compare(store: store, database: db)
        #expect(r.fieldTally.map(\.field) == ["laps[*].averageHR", "calories"])
        #expect(r.fieldTally.map(\.details) == [2, 1])
    }
}
''',
    "DetailTallyTests — appended, so no new file and no restart",
)

# -------------------------------------------------------------------- 4. the ADR

edit(
    ADR,
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.40 The tally that could not be read — patch 295

Patch 294 landed and the two older read-backs re-ran on the device. The detail
report looked like this:

    The read                              668 details.
    Compared                              668
    Agreed on every field                 655
    In the store, not in the database       5
      laps[index: 12].averageHR             3
      laps[index: 2].averageHR              3
      laps[index: 20].averageHR             2
      laps[index: 28].averageHR             2
      laps[index: 42].averageHR             2
      fetched                               1
      laps[index: 10].averageHR             1
      laps[index: 14].averageHR             1
      laps[index: 16].averageHR             1
      laps[index: 18].averageHR             1
      laps[index: 1].averageHR              1
      laps[index: 22].averageHR             1
      + 13 more fields

Thirteen details differ. One cause. **Twenty-five tally rows**, twelve of them
shown and the rest behind a cut-off.

Also on that run, and worth recording separately: **`fetched` is 1, not 320.**
291a's truncation fix is confirmed against the real 668. And the activity
read-back is still 668 compared, 668 agreed, with four in the store and not in
the database — five at the detail level, which means one activity reached the
database while its detail row did not. That gap is D6b's, not this patch's.

### 12.40.1 Every key was correct

Nothing in that list is wrong. `laps[index: 12].averageHR` differs on three
details, and saying so is accurate.

The report is still useless. A reader sees twenty-five findings and an unknown
number more, when what happened is one known normalisation — the importer's
`positiveOrNil` on a zero heart rate, §12.37.5 — touching about thirty laps
across thirteen details. The screen cannot say that, and the shape of the list
actively argues against it: twenty-five differently-named rows read as
twenty-five different problems.

**A correct summary that cannot be read is worse than a missing one.** A missing
summary sends somebody to the data. This one sends them to the wrong conclusion
and gives them twelve rows of evidence for it.

### 12.40.2 The same defect, four patches apart, found in the wrong order

§12.39.2 designed the recording report around exactly this: a field name
carrying an element identity is unique per record, and a tally of unique keys is
a list with extra steps. That was written for 294 **while 291's report already
had the disease**, and I did not look.

The reason is worth naming: 291's tally was *tested*, and every test passed. The
tests asserted that `differingFields` names the right element — which it does,
and should. Nothing tested what a hundred of those names look like stacked in a
list, because that is not a property of one comparison. It only appears at real
scale, on a screen, which is the argument §12.36 makes for running these against
the actual 668 rather than fixtures.

### 12.40.3 Collapse for grouping, keep for opening

`tallyKey` rewrites the element identity to `*` **for grouping only**:

    laps[index: 12].averageHR   →  laps[*].averageHR
    bestEfforts[1k].seconds     →  bestEfforts[*].seconds
    splits missing 12           →  splits missing

`Difference.fields` is untouched. §12.37.2 chose identity over position so a
reader could open the lap, and that has to survive a fix to the layer above it —
so the section now prints the first five ids with their precise field names
underneath the tally. Collapsing a summary that leads nowhere is a dead end
dressed as a tidy one.

### 12.40.4 Wide and deep, again

Each row now carries two numbers: `details` (how many details carry this field
at all) and `elements` (how many splits, laps or efforts inside them do).

Thirteen details each with one bad lap, and thirteen details with forty bad laps
between them, are the same first number and nothing alike in the second. This is
the same split §12.39.2 built into the recording report as `fieldTally` and
`sampleTally`; here both fit in one row because the denominators are small.

The list above becomes one line:

    laps[*].averageHR      13 · ~30 elements
    fetched                 1

### 12.40.5 The comment was right before the code was

The view already said it:

    // The tally first — "all on splits[*].averageHR" is one known
    // cause; a list of ids is an afternoon.

Written at 291, describing the output as though `[*]` were what the tally
produced. It never was. §12.34 records that prose in a `View` goes stale
silently; this is the sharper version — prose that was **never true**, sitting
directly above the code that failed to make it true, and reading as
documentation of working behaviour for four patches.

The comment is kept and amended rather than deleted, because the record of
having believed it is the useful part.

## 12.10 The athlete profile, the zones and the resting series''',
    "§12.40",
)

# ---------------------------------------------------------------- 5. the version

edit(
    VER,
    r'''    static let patch = 294''',
    r'''    static let patch = 295''',
    "295",
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
    print("  2. ⌘R, Settings → Database, 'Read the details back out'")
    print("     — expect ONE laps[*].averageHR row where there were twenty-five")
    print("  3. and press 'Read the recordings back out', which 294 is still owed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
