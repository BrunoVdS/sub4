#!/usr/bin/env python3
"""
Patch 290 — the reader meets the real 669.

289 proved the round trip on one synthetic activity. This runs it against the
actual database on the phone, field by field, and reports what differs.

It is D6c shadow parity's first real measurement, deliberately scoped small:
one table, no derived metrics, counts and field names rather than a diff.

WHY THE DATABASE SCREEN IS NOT "D7 BY ACCIDENT". A reader wired into a screen
that SHOWS TRAINING would be. This one sits beside `SemanticVerifier`, which
has read the database for diagnostic purposes since 3.2 — the Database screen
is where the app looks at itself.

No new files, so no ⌘Q.

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


R = "Sub4/ActivityRepository.swift"
H = "Sub4/DatabaseHealthView.swift"
T = "Sub4CoreTests/ActivityRepositoryTests.swift"

# ------------------------------------------------------------ the comparison

edit(
    R,
    r'''nonisolated enum ActivityRepository {''',
    r'''/// The store against the database, one activity at a time — patch 290.
///
/// D6c asks this of everything. This asks it of one table, on the real data,
/// now — because a round trip proven on one synthetic activity says nothing
/// about 669 real ones with retired shoes, missing sport labels and eight
/// months of whatever Strava sent.
///
/// IT NAMES FIELDS, NOT ROWS. "12 activities differ" sends somebody looking
/// through 12 activities; "12 differ, all on `maxSpeed`" is a one-line fix and
/// usually a units mistake. Equal counts hiding changed values is §12.16's
/// warning, and a count of differences is the same failure one level down.
nonisolated enum ActivityRoundTrip {

    struct Difference: Sendable, Identifiable {
        /// The store's id — Strava's.
        let id: String
        let fields: [String]
    }

    struct Report: Sendable {
        var compared = 0
        /// In the store and not in the database at all.
        var missing: [String] = []
        var differences: [Difference] = []

        var agreed: Int { compared - differences.count }

        /// Every field that differs anywhere, with how often. The line worth
        /// reading first.
        var fieldTally: [(field: String, count: Int)] {
            var counts: [String: Int] = [:]
            for d in differences { for f in d.fields { counts[f, default: 0] += 1 } }
            return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { (field: $0.key, count: $0.value) }
        }
    }

    static func compare(store: [Activity], database: [Activity]) -> Report {
        var byID: [String: Activity] = [:]
        for a in database { byID[a.id] = a }

        var report = Report()
        for s in store {
            guard let d = byID[s.id] else { report.missing.append(s.id); continue }
            report.compared += 1
            let fields = differingFields(s, d)
            if !fields.isEmpty {
                report.differences.append(Difference(id: s.id, fields: fields))
            }
        }
        report.missing.sort()
        return report
    }

    /// EVERY STORED FIELD, NAMED. Adding one to `Activity` and not to this
    /// list makes the comparison quietly weaker, which is why the names are
    /// spelled out rather than derived — there is no reflection here that
    /// would not also silently skip something.
    static func differingFields(_ s: Activity, _ d: Activity) -> [String] {
        var out: [String] = []
        func check(_ name: String, _ same: Bool) { if !same { out.append(name) } }

        check("name", s.name == d.name)
        check("sportType", s.sportType == d.sportType)
        check("startLocal", s.startLocal == d.startLocal)
        check("startUTC", s.startUTC == d.startUTC)
        check("distance", s.distance == d.distance)
        check("movingTime", s.movingTime == d.movingTime)
        check("elapsedTime", s.elapsedTime == d.elapsedTime)
        check("elevationGain", s.elevationGain == d.elevationGain)
        check("averageHeartrate", s.averageHeartrate == d.averageHeartrate)
        check("maxHeartrate", s.maxHeartrate == d.maxHeartrate)
        check("isTrainer", s.isTrainer == d.isTrainer)
        check("gearId", s.gearId == d.gearId)
        check("maxSpeed", s.maxSpeed == d.maxSpeed)
        check("deviceWatts", s.deviceWatts == d.deviceWatts)
        check("averageWatts", s.averageWatts == d.averageWatts)
        check("startLat", s.startLat == d.startLat)
        check("startLon", s.startLon == d.startLon)
        check("timeZoneIdentifier", s.timeZoneIdentifier == d.timeZoneIdentifier)
        check("startOffsetSeconds", s.startOffsetSeconds == d.startOffsetSeconds)
        return out
    }
}

nonisolated enum ActivityRepository {''',
    "the round-trip comparison",
)

# ------------------------------------------------------------------ the state

edit(
    H,
    r'''    @State private var verifying = false''',
    r'''    @State private var readingBack = false
    @State private var roundTrip: ActivityRoundTrip.Report?
    @State private var roundTripLoad: ActivityLoad?
    @State private var verifying = false''',
    "the read-back state",
)

# ----------------------------------------------------------------- the section

edit(
    H,
    r'''        } header: {
            Text("Verification")
        } footer: {''',
    r'''        } header: {
            Text("Verification")
        } footer: {'''.replace("PLACEHOLDER", ""),
    "anchor untouched",
)

edit(
    H,
    r'''    private func runVerify(_ db: Sub4Database) {''',
    r'''    /// PATCH 290. The reader against the real data.
    ///
    /// Beside verification rather than inside it: the verifier compares COUNTS
    /// and a few figures, this compares one activity to another field by
    /// field. Equal counts can hide changed values — §12.16 — and this is the
    /// check that would notice.
    @ViewBuilder
    private func readBackSection(_ db: Sub4Database) -> some View {
        Section {
            if readingBack {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            } else {
                Button("Read the activities back out") { runReadBack(db) }
            }

            if let load = roundTripLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            }

            if let r = roundTrip {
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

                // THE FIELD TALLY FIRST. "12 differ" sends somebody through
                // twelve activities; "12, all on maxSpeed" is one fix.
                ForEach(r.fieldTally, id: \.field) { entry in
                    LabeledContent("  \(entry.field)", value: "\(entry.count)")
                        .font(.caption2).foregroundStyle(.red)
                }

                // A few ids to open, and the rest counted rather than dropped.
                ForEach(r.differences.prefix(5)) { d in
                    Text("    \(d.id) — \(d.fields.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.differences.count > 5 {
                    Text("    + \(r.differences.count - 5) more")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            }
        } header: {
            Text("Read-back")
        } footer: {
            Text("Reads every activity out of the database through "
                 + "ActivityRepository and compares it, field by field, to the "
                 + "one the app is running on. This is the question D6c asks of "
                 + "everything, asked of one table now. Nothing is written.")
                .font(.caption2)
        }
    }

    private func runReadBack(_ db: Sub4Database) {
        readingBack = true
        let store = ActivityStore.shared.activities
        Task {
            let load = ActivityRepository.all(db)
            roundTripLoad = load
            roundTrip = load.activities.map {
                ActivityRoundTrip.compare(store: store, database: $0)
            }
            readingBack = false
        }
    }

    private func runVerify(_ db: Sub4Database) {''',
    "the read-back section",
)

edit(
    H,
    r'''                verifySection(db)''',
    r'''                verifySection(db)
                readBackSection(db)''',
    "the section is shown",
)

# ---------------------------------------------------------------------- tests

edit(
    T,
    r'''    // MARK: Coverage it cannot provide''',
    r'''    // MARK: The round-trip comparison — 290

    @Test("Identical sides agree on every field")
    func identicalSidesAgree() {
        let a = ride()
        let r = ActivityRoundTrip.compare(store: [a], database: [a])
        #expect(r.compared == 1)
        #expect(r.agreed == 1)
        #expect(r.differences.isEmpty)
        #expect(r.missing.isEmpty)
    }

    /// THE POINT OF THE FIELD TALLY. A count of differing activities sends
    /// somebody through them one at a time; a count by field is usually one
    /// fix.
    @Test("A difference names the field, not just the activity")
    func aDifferenceNamesTheField() {
        let store = ride()
        var altered = ride()
        altered.maxSpeed = 99
        let r = ActivityRoundTrip.compare(store: [store], database: [altered])

        #expect(r.differences.count == 1)
        #expect(r.differences.first?.fields == ["maxSpeed"])
        #expect(r.fieldTally.map(\.field) == ["maxSpeed"])
        #expect(r.fieldTally.first?.count == 1)
    }

    @Test("The tally counts a field once per activity that differs on it")
    func theTallyCountsPerActivity() {
        var a = ride("1"); a.maxSpeed = 1
        var b = ride("2"); b.maxSpeed = 2
        let r = ActivityRoundTrip.compare(store: [ride("1"), ride("2")],
                                          database: [a, b])
        #expect(r.fieldTally.first?.field == "maxSpeed")
        #expect(r.fieldTally.first?.count == 2)
        #expect(r.agreed == 0)
    }

    @Test("An activity the database does not have is missing, not different")
    func missingIsNotDifferent() {
        let r = ActivityRoundTrip.compare(store: [ride("1"), ride("2")],
                                          database: [ride("1")])
        #expect(r.compared == 1, "only the one present can be compared")
        #expect(r.missing == ["2"])
        #expect(r.differences.isEmpty)
    }

    /// The whole comparison is only as good as this list. A field added to
    /// `Activity` and not to `differingFields` makes it quietly weaker.
    @Test("Every stored field of an Activity is compared")
    func everyFieldIsCompared() {
        let names = Set(ActivityRoundTrip.differingFields(
            ride(gearId: "a"),
            Activity(id: "19580875358", name: "x", sportType: "Run",
                     startLocal: "2020-01-01T00:00:00", distance: 1,
                     movingTime: 1, elapsedTime: 1, elevationGain: 1,
                     averageHeartrate: 1, isTrainer: true, maxHeartrate: 1,
                     gearId: "b", maxSpeed: 1, deviceWatts: false,
                     averageWatts: 1, startUTC: "2020-01-01T00:00:00Z",
                     startLat: 1, startLon: 1, timeZoneIdentifier: "UTC",
                     startOffsetSeconds: 0)))

        // Nineteen: every stored property except `id`, which is the key the
        // two sides are matched ON and cannot differ.
        #expect(names.count == 19, "found \(names.count) differing fields")
        for expected in ["name", "sportType", "startLocal", "startUTC", "distance",
                         "movingTime", "elapsedTime", "elevationGain",
                         "averageHeartrate", "maxHeartrate", "isTrainer", "gearId",
                         "maxSpeed", "deviceWatts", "averageWatts", "startLat",
                         "startLon", "timeZoneIdentifier", "startOffsetSeconds"] {
            #expect(names.contains(expected), "\(expected) is not compared")
        }
    }

    // MARK: Coverage it cannot provide''',
    "the comparison tests",
)

# ------------------------------------------------------------------------ ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.36 The reader meets the real 669 — patch 290

§12.35 proved the round trip on one synthetic activity. That is worth exactly
as much as one synthetic activity: it says the column names are right, and
nothing about 669 real ones with retired shoes, missing sport labels and eight
months of whatever Strava happened to send.

`ActivityRoundTrip` runs the comparison on the phone, and it is **D6c's first
real measurement** — deliberately one table, no derived metrics, no CTL.

### 12.36.1 It names fields, not rows

*"12 activities differ"* sends somebody through twelve activities. *"12
differ, all on `maxSpeed`"* is one fix, and usually a units mistake.

That is §12.16's warning one level down: equal counts can hide changed values,
and a bare count of differences hides which value. `fieldTally` is the line to
read first, and the screen puts it above the ids.

### 12.36.2 The field list is written out, not derived

`differingFields` names all nineteen comparable properties by hand. There is
no reflection in Swift that would enumerate them without also silently
skipping something, and a comparison that quietly stops covering a field is
worse than one that does not cover it — the first reports agreement.

`everyFieldIsCompared` holds the count. Add a property to `Activity` and that
test fails, which is the only moment anybody would think to update this.

### 12.36.3 Why this is not D7 arriving by accident

A reader wired into a screen that SHOWS TRAINING would be. This sits beside
`SemanticVerifier`, which has read the database for diagnostic purposes since
3.2. The Database screen is where the app looks at itself, and looking is not
depending.

`Sub4Launch.migrationFailureBlocksTheApp` stays false, and §12.27's test still
holds the disconnect rule to it.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.36",
)


def fail(msg):
    print("STOPPED — nothing was changed.")
    print("  " + msg)
    sys.exit(1)


buffers, applied = {}, []
for path, old, new, why in EDITS:
    if why == "anchor untouched":
        continue
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
