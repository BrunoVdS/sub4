#!/usr/bin/env python3
"""
Patch 298 — two things the report could not say.

Both found by running 297's measurement. Neither is what 297 was looking for.

  1. "fetched differs" is a true sentence that supports no next step. The
     read-back said 17463863070 differs on `fetched`; the import thirty
     seconds later said `0 replaced`, meaning its own string comparison of the
     same column called it unchanged. Two comparisons disagreeing and neither
     saying enough to decide which is wrong.

     The detail line now prints BOTH dates. The field name stays `fetched`,
     because §12.39.2's rule holds — the values go where they are already
     unique per record.

  1b. And `?? .distantPast` in RecordingRepository.build was hiding a third
     case: a timestamp the reader could not PARSE arrived as a data
     disagreement about when something was fetched. Named as
     `unreadableDate`, tested for first, reported as `fetched unreadable`.
     Sixth instance of §12.15's shape.

  2. `1 in the store, not in the database`, in red, straight after an import
     that wrote everything it was willing to write. Those are the two sessions
     DataCorrections refuses — permanently, on purpose. A red row that is
     correct for ever is a row that stops being read.

     `missing` and `excluded` are now separate, and `excluded` is dim.

     It also made the D6b exit gate unmeetable as written, the same morning it
     was written. Both the groundwork and §12.42.2.1 record the correction.

Also records what 297 measured: 0.361 s, and why that is the STEADY-STATE
number rather than a whole-world write.

Files touched
  Sub4/RecordingRepository.swift          unreadableDate, the fetched branch, excluded
  Sub4/ActivityDetailRepository.swift     excluded
  Sub4/DatabaseHealthView.swift           two rows
  Sub4CoreTests/RecordingRepositoryTests.swift        + RecordingReportHonestyTests
  Sub4CoreTests/ActivityDetailRepositoryTests.swift   + DetailExclusionTests
  docs/D6B-WRITE-THROUGH-GROUNDWORK.md    §4.3 measured, §5.5 corrected
  docs/ADR-0003-database-contract.md      + §12.42
  Sub4/AppVersion.swift                   298

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


REC = "Sub4/RecordingRepository.swift"
DET = "Sub4/ActivityDetailRepository.swift"
VIEW = "Sub4/DatabaseHealthView.swift"
TREC = "Sub4CoreTests/RecordingRepositoryTests.swift"
TDET = "Sub4CoreTests/ActivityDetailRepositoryTests.swift"
GW = "docs/D6B-WRITE-THROUGH-GROUNDWORK.md"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

# The link made visible. `?? .distantPast` and `?? unreadableDate` are the same
# value; only one of them says what it means to the code that reads it back.
edit(
    REC,
    r'''            fetched: ActivityDetailRepository.parseUTC(head["fetchedUTC"]) ?? .distantPast)''',
    r'''            // NAMED, not `.distantPast` — 298. The same value either
            // way; only one of them tells `RecordingRoundTrip` what it is
            // looking at. See `unreadableDate`.
            fetched: ActivityDetailRepository.parseUTC(head["fetchedUTC"])
                     ?? unreadableDate)''',
    "the sentinel is written where it is produced",
)

# --------------------------------------------------------------- 1. recordings

edit(
    REC,
    r'''    /// One recording, by the id the STORE uses.''',
    r'''    /// WHAT `build` USES WHEN `fetchedUTC` CANNOT BE PARSED — patch 298.
    ///
    /// It was `?? .distantPast` written inline, which is a sentinel either way.
    /// The difference is that an inline one is invisible to everything
    /// downstream: the comparison saw a date in the year 1 and reported
    /// `fetched` differing, which reads as *the database disagrees about when
    /// this was fetched* when what happened is *the reader could not read the
    /// column at all.*
    ///
    /// Named, so `RecordingRoundTrip` can tell those apart and say which. Sixth
    /// instance of the rule this project keeps rediscovering: **a diagnostic
    /// that cannot say why it has no answer will eventually be read as having
    /// one** — §12.15, §12.28.3, §12.32.4, §12.31.3, §12.35.
    ///
    /// A sentinel rather than an optional because `ActivityStreams.fetched` is
    /// not optional and should not become so to serve a reader. The model is
    /// the app's; this is the reader's problem to name.
    static let unreadableDate = Date.distantPast

    /// One recording, by the id the STORE uses.''',
    "unreadableDate, named rather than inline",
)

edit(
    REC,
    r'''        var missing: [String] = []
        var unreadable: [Unreadable] = []''',
    r'''        /// In the store and not in the database, and nobody meant that.
        var missing: [String] = []
        /// In the store and not in the database ON PURPOSE — patch 298.
        /// See the guard in `compare`.
        var excluded: [String] = []
        var unreadable: [Unreadable] = []
''',
    "Report gains excluded",
)

edit(
    REC,
    r'''            guard let back = load.recordings?.first else {
                report.missing.append(s.activityId)
                continue
            }''',
    r'''            guard let back = load.recordings?.first else {
                // ABSENT ON PURPOSE IS NOT ABSENT — patch 298.
                //
                // `DataCorrections.ignoredActivities` holds two sessions the
                // app refuses, and `Sub4Import` declines their traces at the
                // door (§256). `DetailStore` keys by Strava id and never sees
                // an `Activity`, so it keeps them — which means the store will
                // ALWAYS hold recordings the database does not, and the count
                // can never reach zero.
                //
                // Reported as a shortfall, that is a red row that is correct
                // for ever and therefore stops being read. It also made the
                // D6b exit gate in the groundwork unmeetable as written.
                if DataCorrections.isIgnored(id: s.activityId) {
                    report.excluded.append(s.activityId)
                } else {
                    report.missing.append(s.activityId)
                }
                continue
            }
''',
    "excluded on purpose is not missing",
)

edit(
    REC,
    r'''        if !DetailRoundTrip.sameSecond(s.fetched, d.fetched) {
            c.fields.append("fetched")
            c.detail.append("fetched differs")
        }''',
    r'''        // THREE OUTCOMES, NOT TWO — patch 298, and the third one is why.
        //
        // The run on 7 August reported `17463863070 — fetched differs`, and the
        // import immediately afterwards reported `0 replaced`. The importer
        // compares `iso8601(store.fetched)` to the stored string and called it
        // unchanged; this comparison called it different. One of them was
        // wrong and neither said enough to tell which.
        //
        // "fetched differs" was the defect. A date comparison that does not
        // print the two dates cannot be acted on — the same lesson as §12.40,
        // one field down. §12.42.
        if d.fetched == RecordingRepository.unreadableDate {
            c.fields.append("fetched unreadable")
            c.detail.append("the database's fetchedUTC could not be parsed")
        } else if !DetailRoundTrip.sameSecond(s.fetched, d.fetched) {
            c.fields.append("fetched")
            c.detail.append("fetched: store \(Sub4Import.iso8601(s.fetched)), "
                            + "database \(Sub4Import.iso8601(d.fetched))")
        }
''',
    "three outcomes, and the dates are printed",
)

# ------------------------------------------------------------------ 2. details

edit(
    DET,
    r'''        var compared = 0
        /// In the store and not in the database at all.
        var missing: [String] = []
        var differences: [Difference] = []''',
    r'''        var compared = 0
        /// In the store and not in the database, and nobody meant that.
        var missing: [String] = []
        /// In the store and not in the database ON PURPOSE — patch 298.
        /// `DataCorrections` refuses two sessions and the importer declines
        /// their details at the door, while `DetailStore` keeps them because it
        /// keys by Strava id and never sees an `Activity`. A permanent, correct
        /// red row is a row that stops being read.
        var excluded: [String] = []
        var differences: [Difference] = []
''',
    "Report gains excluded",
)

edit(
    DET,
    r'''        var report = Report()
        for s in store {
            guard let d = byID[s.activityId] else {
                report.missing.append(s.activityId); continue
            }''',
    r'''        var report = Report()
        for s in store {
            guard let d = byID[s.activityId] else {
                // Absent on purpose is not absent — patch 298, §12.42.2.
                if DataCorrections.isIgnored(id: s.activityId) {
                    report.excluded.append(s.activityId)
                } else {
                    report.missing.append(s.activityId)
                }
                continue
            }
''',
    "excluded on purpose is not missing",
)

edit(
    DET,
    r'''        report.missing.sort()
        return report''',
    r'''        report.missing.sort()
        report.excluded.sort()
        return report''',
    "both lists sorted",
)

# --------------------------------------------------------------------- 3. view

edit(
    VIEW,
    r'''                    if !r.missing.isEmpty {
                        LabeledContent("In the store, not in the database",
                                       value: "\(r.missing.count)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if !r.unreadable.isEmpty {''',
    r'''                    if !r.missing.isEmpty {
                        LabeledContent("In the store, not in the database",
                                       value: "\(r.missing.count)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    // DIM, NOT RED — patch 298. These are the sessions
                    // DataCorrections refuses; the store keeps their traces and
                    // the database declines them, permanently and on purpose.
                    // A red row that is correct for ever stops being read.
                    if !r.excluded.isEmpty {
                        LabeledContent("Excluded on purpose", value: "\(r.excluded.count)")
                            .font(.caption).foregroundStyle(Color.dim)
                    }
                    if !r.unreadable.isEmpty {''',
    "the recording row",
)

edit(
    VIEW,
    r'''                if !r.missing.isEmpty {
                    LabeledContent("In the store, not in the database",
                                   value: "\(r.missing.count)")
                        .font(.caption).foregroundStyle(.red)
                }
                // The tally first, and this comment was RIGHT before the code''',
    r'''                if !r.missing.isEmpty {
                    LabeledContent("In the store, not in the database",
                                   value: "\(r.missing.count)")
                        .font(.caption).foregroundStyle(.red)
                }
                // Patch 298 — see the recording section. Dim, because it is a
                // decision rather than a shortfall.
                if !r.excluded.isEmpty {
                    LabeledContent("Excluded on purpose", value: "\(r.excluded.count)")
                        .font(.caption).foregroundStyle(Color.dim)
                }
                // The tally first, and this comment was RIGHT before the code''',
    "the detail row",
)

# -------------------------------------------------------------------- 4. tests

edit(
    TREC,
    r'''    @Test("An empty database is a trustworthy zero")
    func emptyIsTrustworthy() throws {
        let db = try Sub4Database.inMemory()
        let r = RecordingRoundTrip.compare(db, store: [])
        #expect(r.isTrustworthy)
        #expect(r.databaseCount == 0)
        #expect(r.line == "0 recordings in the database.")
        #expect(r.compared == 0)
    }
}''',
    r'''    @Test("An empty database is a trustworthy zero")
    func emptyIsTrustworthy() throws {
        let db = try Sub4Database.inMemory()
        let r = RecordingRoundTrip.compare(db, store: [])
        #expect(r.isTrustworthy)
        #expect(r.databaseCount == 0)
        #expect(r.line == "0 recordings in the database.")
        #expect(r.compared == 0)
    }
}

// MARK: -

/// What the report could not say — patch 298, ADR-0003 §12.42.
///
/// `aFetchedDifferenceSaysBothDates` is the one with teeth, and it is a test
/// about a string again. On 7 August the screen said `17463863070 — fetched
/// differs` and the import thirty seconds later said `0 replaced`. The importer
/// compared the same field and called it unchanged. One of them was wrong and
/// the report did not carry enough to tell which — which is the whole failure,
/// because the report exists to be the thing that tells you.
@Suite
@MainActor
struct RecordingReportHonestyTests {

    private let storeID = "19580875358"

    private func streams(_ id: String, fetched: Date) -> ActivityStreams {
        ActivityStreams(activityId: id, distanceM: [0, 500, 1000],
                        heartRate: [120, 131, 145],
                        speed: nil, altitude: nil, grade: nil,
                        power: nil, latitude: nil, longitude: nil,
                        fetched: fetched)
    }

    // MARK: The date

    /// THE ONE WITH TEETH.
    @Test("A fetched difference says both dates, not that there is one")
    func aFetchedDifferenceSaysBothDates() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        let s = streams("1", fetched: base)
        let d = streams("1", fetched: base.addingTimeInterval(90))

        let c = RecordingRoundTrip.compareOne(s, d)
        #expect(c.fields == ["fetched"], "the tally key stays stable — §12.39.2")
        #expect(c.line.contains(Sub4Import.iso8601(base)),
                "the store's value is printed")
        #expect(c.line.contains(Sub4Import.iso8601(base.addingTimeInterval(90))),
                "and the database's, so the two can be compared by eye")
    }

    /// A COLUMN THAT COULD NOT BE READ IS NOT A DISAGREEMENT ABOUT ITS VALUE.
    /// `build` writes `unreadableDate` when `parseUTC` fails, and before 298
    /// that arrived as an ordinary `fetched` difference — a reader defect
    /// wearing a data difference's clothes.
    @Test("An unparseable timestamp is named as unparseable")
    func anUnreadableDateIsItsOwnAnswer() {
        let s = streams("1", fetched: Date(timeIntervalSince1970: 1_785_000_000))
        let d = streams("1", fetched: RecordingRepository.unreadableDate)

        let c = RecordingRoundTrip.compareOne(s, d)
        #expect(c.fields == ["fetched unreadable"])
        #expect(!c.fields.contains("fetched"),
                "the two must never arrive under the same key")
        #expect(c.line.contains("could not be parsed"))
    }

    @Test("Matching dates say nothing at all")
    func agreementIsSilent() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        let c = RecordingRoundTrip.compareOne(streams("1", fetched: base),
                                              streams("1", fetched: base))
        #expect(c.agrees)
    }

    // MARK: Absent on purpose

    /// `DataCorrections` refuses two sessions; `Sub4Import` declines their
    /// traces; `DetailStore` keeps them because it keys by Strava id. So the
    /// store permanently holds recordings the database will never have, and
    /// counting those as missing is a red row that is correct for ever.
    @Test("A deliberately excluded recording is excluded, not missing")
    func excludedIsNotMissing() throws {
        let db = try Sub4Database.inMemory()
        let ignored = try #require(DataCorrections.ignoredActivities.keys.sorted().first)
        let base = Date(timeIntervalSince1970: 1_785_000_000)

        let r = RecordingRoundTrip.compare(db, store: [
            streams(ignored, fetched: base),
            streams("99999999999", fetched: base),
        ])
        #expect(r.excluded == [ignored])
        #expect(r.missing == ["99999999999"],
                "a recording nobody excluded is still a shortfall")
    }

    @Test("Nothing excluded is an empty list, not a zero")
    func noExclusionsIsEmpty() throws {
        let db = try Sub4Database.inMemory()
        let r = RecordingRoundTrip.compare(db, store: [])
        #expect(r.excluded.isEmpty)
        #expect(r.missing.isEmpty)
    }
}
''',
    "RecordingReportHonestyTests",
)

edit(
    TDET,
    r'''        #expect(r.fieldTally.map(\.field) == ["laps[*].averageHR", "calories"])
        #expect(r.fieldTally.map(\.details) == [2, 1])
    }
}''',
    r'''        #expect(r.fieldTally.map(\.field) == ["laps[*].averageHR", "calories"])
        #expect(r.fieldTally.map(\.details) == [2, 1])
    }
}

// MARK: -

/// Absent on purpose, one level up — patch 298, ADR-0003 §12.42.2.
@Suite
@MainActor
struct DetailExclusionTests {

    private func detail(_ id: String) -> ActivityDetail {
        ActivityDetail(activityId: id, calories: 812,
                       splits: [], bestEfforts: [], laps: [],
                       fetched: Date(timeIntervalSince1970: 1_785_000_000))
    }

    @Test("A deliberately excluded detail is excluded, not missing")
    func excludedIsNotMissing() throws {
        let ignored = try #require(DataCorrections.ignoredActivities.keys.sorted().first)
        let r = DetailRoundTrip.compare(store: [detail(ignored), detail("99999999999")],
                                        database: [])
        #expect(r.excluded == [ignored])
        #expect(r.missing == ["99999999999"])
        #expect(r.compared == 0)
    }

    /// The distinction only exists on the way in. A detail the database HAS is
    /// compared like any other, exclusion or not — the store and the database
    /// disagreeing about a row they both hold is news either way.
    @Test("An excluded detail the database does have is still compared")
    func excludedButPresentIsCompared() throws {
        let ignored = try #require(DataCorrections.ignoredActivities.keys.sorted().first)
        let d = detail(ignored)
        let r = DetailRoundTrip.compare(store: [d], database: [d])
        #expect(r.compared == 1)
        #expect(r.excluded.isEmpty)
        #expect(r.agreed == 1)
    }

    @Test("Both lists are sorted, so the screen does not reshuffle")
    func bothListsAreSorted() throws {
        let r = DetailRoundTrip.compare(store: [detail("3"), detail("1"), detail("2")],
                                        database: [])
        #expect(r.missing == ["1", "2", "3"])
    }
}
''',
    "DetailExclusionTests",
)

# ---------------------------------------------------------------- 5. groundwork

edit(
    GW,
    r'''### 5.5 What D6b's exit gate is

Proposed: **the three read-backs report 0 / 0 / 0 store-only records after a
sync the athlete did not trigger by hand**, and one deliberate failure — a
locked device, say — leaves a journal entry that Settings shows.

The first half proves it works. The second half proves it says so when it
doesn't, which is the half every rung of this ladder has needed.''',
    r'''### 5.5 What D6b's exit gate is

**Amended at 298, the same morning it was written, because as first stated it
could never be met.**

It said *"the three read-backs report 0 / 0 / 0 store-only records"*. Two of
those numbers can never be zero. `DataCorrections` refuses two sessions and the
importer declines their traces and details at the door, while `DetailStore`
keeps them because it keys by Strava id and never sees an `Activity`. The store
permanently holds records the database will never hold, by design.

A gate that cannot be met is worse than no gate: it gets quietly dropped rather
than argued with. §12.42.2.1.

**The gate, corrected:**

- the three read-backs report **`missing` at zero** after a sync the athlete did
  not trigger by hand, with `excluded` shown beside it and free to be non-zero
- one deliberate failure — a locked device, say — leaves a journal entry that
  Settings shows

The first half proves it works. The second half proves it says so when it
doesn't, which is the half every rung of this ladder has needed.
''',
    "§5.5 — a gate that could not be met",
)

edit(
    GW,
    r'''| measured | decision |
|---|---|
| under ~2 s | B unconditionally. Fire it after every sync, on a detached task. |
| 2–10 s | B on a detached task at `.utility`, coalesced so two syncs cannot queue two runs. |
| over ~10 s | B is still right, but it needs a changed-set. `DetailStore` already has one; `ActivityStore` would need one, and that is a real patch of its own. |

A is not chosen at any measured value. If B is too slow, the answer is to make B''',
    r'''| measured | decision |
|---|---|
| under ~2 s | B unconditionally. Fire it after every sync, on a detached task. |
| 2–10 s | B on a detached task at `.utility`, coalesced so two syncs cannot queue two runs. |
| over ~10 s | B is still right, but it needs a changed-set. `DetailStore` already has one; `ActivityStore` would need one, and that is a real patch of its own. |

**MEASURED 7 August: 0.361 s. The first row.**

And the third row is largely retired, because the reading needs care. That
0.361 s is the STEADY-STATE cost, not a whole-world write:
`Sub4Import+Recording` skips a trace whose stored `fetchedUTC` matches the
store's, so the run wrote 1,200 sample rows rather than 193,000 — `4 new, 0
replaced, 645 unchanged` on the screen. The changed-set §4.3 said `ActivityStore`
might need already exists where it matters, and `ActivityStore`'s 668 rows are
the part that does not need one.

**Not measured: the cold path.** After `resetCache()` or on a fresh install all
645 traces are new, which is ~193,000 inserts and plausibly two orders of
magnitude slower. It does not change the decision — `resetCache` is deliberate
and rare — and it is written down as unmeasured rather than assumed. §12.42.3.

A is not chosen at any measured value. If B is too slow, the answer is to make B
''',
    "§4.3 — the measurement",
)

edit(
    GW,
    r'''## 7. What is still unknown

One thing, and patch 297 exists to answer it: **how long a full import takes on
this device.** Everything else above was read out of the source and is settled.

Press Import on the Database screen, read the "Took" row, and §4.3 picks itself.''',
    r'''## 7. What is still unknown

**Answered at 297: 0.361 s steady-state, so §4.3's first row.** See §4.3 for
what that number does and does not cover.

Still unknown, and neither blocks starting:

- **The cold path.** A first import, or one after `resetCache()`, writes all
  ~193,000 sample rows instead of skipping 645 traces. Unmeasured.
- **Which of two things `17463863070` is.** The read-back says its `fetched`
  differs; the importer says the same column is unchanged. 298 makes the report
  print both dates and name an unparseable timestamp separately, so the next run
  answers it. §12.42.1.''',
    "§7 — answered, and what is left",
)

# ------------------------------------------------------------------- 6. the ADR

edit(
    ADR,
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.42 Two things the report could not say — patch 298

Both found by running 297's measurement, neither of them what 297 was looking
for. Both are the same rule the sixth and seventh time: **a diagnostic that
cannot say why it has no answer will eventually be read as having one** —
§12.15, §12.28.3, §12.31.3, §12.32.4, §12.35.

### 12.42.1 A date comparison that does not print the dates

On 7 August the recording read-back reported:

    fetched                     1
      17463863070 — fetched differs

An import thirty seconds later reported **`Traces: 4 new, 0 replaced, 645
unchanged`**. The importer's rule for a trace is string equality on the
timestamp — `iso8601(store.fetched) == recording.fetchedUTC`, one row read, no
samples — and it found that row unchanged. A second read-back after the import
still reported the difference.

So the importer and the reader compared the same column on the same row and
disagreed, and **neither said enough to decide which was wrong.** "fetched
differs" is a true sentence that supports no next step.

This is §12.40's lesson one field down. There the tally fragmented and buried
the cause; here it collapsed to a single word and dropped it. Both are summaries
that cost the reader the thing they needed, and both were written by somebody
who already knew the answer at the time.

The detail line now carries both values:

    fetched: store 2026-08-05T09:12:33Z, database 2026-08-05T09:12:34Z

The **field name stays `fetched`** — §12.39.2's rule holds, the values go in the
detail where they are already unique per record.

#### 12.42.1.1 And a sentinel that was hiding a third case

`RecordingRepository.build` ended in `?? .distantPast`, written inline at 292.

A `fetchedUTC` the reader cannot parse therefore became a date in the year 1,
which the comparison reported as `fetched` — *the database disagrees about when
this was fetched* — when what happened was *the reader could not read the
column.* A reader defect wearing a data difference's clothes, and one of the two
live candidates for the row above.

It is now `RecordingRepository.unreadableDate`, named, and the comparison tests
for it **before** comparing values and reports `fetched unreadable`. A sentinel
rather than an optional because `ActivityStreams.fetched` is not optional and
should not become so to serve a reader; the model belongs to the app, and this
is the reader's problem to name.

Which of the two the 7 August row actually is will be on screen at the next run.
Recorded here as an open question rather than a conclusion — §12.29.2.1.

### 12.42.2 A shortfall that was a decision

The same run reported **1 recording and 1 detail "in the store, not in the
database"**, in red, immediately after an import that had just written
everything it was willing to write.

`DataCorrections.ignoredActivities` refuses two sessions — a swim recording 400
m across 45 minutes, and a Romanian ride with 8.04 days of elapsed time.
`Sub4Import` declines their traces and details at the door (§256). `DetailStore`
keys by Strava id and never sees an `Activity`, so it keeps them.

The store therefore holds records the database will **never** hold, by design,
for ever. Counting them as missing produces a red row that is permanently
correct — which is a row that stops being read, and takes the real ones with it
when they arrive.

`missing` and `excluded` are now separate, and `excluded` is dim rather than
red, because it is a decision and not a shortfall.

#### 12.42.2.1 It also made D6b's exit gate unmeetable

`D6B-WRITE-THROUGH-GROUNDWORK.md` §5.5 proposed the gate as *the three
read-backs report 0 / 0 / 0 store-only records after a sync nobody triggered by
hand.* Written the same morning, and unreachable: two of those numbers can never
be zero while the exclusions exist.

A gate that cannot be met is worse than no gate, because it gets quietly dropped
rather than argued with. Amended in the same patch that made the distinction
visible — the gate is now **`missing` at zero**, with `excluded` shown beside it
and free to be non-zero.

### 12.42.3 What 297 actually measured, since it is worth writing down

**0.361 s**, and the reading needs care: it is the STEADY-STATE cost.

`Sub4Import+Recording` skips a trace whose stored `fetchedUTC` matches the
store's, so the run wrote 1,200 sample rows rather than 193,000 — `4 new, 0
replaced, 645 unchanged`. The expensive tables already have a changed-set, keyed
on the timestamp. The cheap ones (668 activities, 580 weather readings, 15
resting months) are re-upserted every time and cost nothing.

That settles §4.3's first row: **fire the import after every sync.** It also
retires most of §4.3's third row — the changed-set that would have been needed
already exists where it matters.

**The cold path is not measured.** After `resetCache()` or on a fresh install,
645 traces are all new and that is ~193,000 inserts, plausibly two orders of
magnitude slower. It does not change the decision, because `resetCache` is
deliberate and rare, but it is written down as unmeasured rather than assumed.

## 12.10 The athlete profile, the zones and the resting series''',
    "§12.42",
)

# --------------------------------------------------------------- 7. the version

edit(
    VER,
    r'''    static let patch = 297''',
    r'''    static let patch = 298''',
    "298",
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
    print("  2. ⌘R, Settings → Database, 'Read the recordings back out'")
    print("     — the fetched row now prints BOTH dates, or says 'fetched")
    print("       unreadable' if the reader could not parse the column")
    print("  3. that line decides whether 299 is a reader fix or nothing at all")
    return 0


if __name__ == "__main__":
    sys.exit(main())
