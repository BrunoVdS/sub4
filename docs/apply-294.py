#!/usr/bin/env python3
"""
Patch 294 — the recording round trip, and D6a's last comparison.

292 built the reader and proved it against fixtures. This runs it against the
645 real recordings and 192,954 real samples on the phone.

Three things this comparison does that the other two did not need:

  1. THREE NUMBERS. The store's array length, `recording.sampleCount` (what the
     importer said it wrote) and the rows the table actually holds. With two,
     "an array arrived short" and "rows went missing" are the same message.

  2. A GATE BEFORE THE WALK. One lost sample shifts every later one, and a
     positional walk would report ~300 differences on a single defect.

  3. STABLE FIELD NAMES. `heartRate[3 of 1204]` is unique per recording, and a
     tally of unique keys is a list. The counts moved into `detail` and into a
     second tally that adds bands up per stream.

And it runs OFF the main actor — 645 read transactions and ~1.5M comparisons is
a frozen screen otherwise.

Files touched
  Sub4/RecordingRepository.swift          + declaredCounts, + RecordingRoundTrip
  Sub4/DatabaseHealthView.swift           + the third read-back row
  Sub4CoreTests/RecordingRepositoryTests.swift  + RecordingRoundTripTests
  Sub4/AppVersion.swift                   294
  docs/ADR-0003-database-contract.md      + §12.39

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


REPO = "Sub4/RecordingRepository.swift"
VIEW = "Sub4/DatabaseHealthView.swift"
TESTS = "Sub4CoreTests/RecordingRepositoryTests.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

# ---------------------------------------------------------------- 1. the reader

edit(
    REPO,
    r'''    /// One recording, by the id the STORE uses.''',
    r'''    /// What the IMPORTER said it wrote, per store id — `recording.sampleCount`.
    ///
    /// PATCH 294. One row per recording and no samples, which makes it cheap
    /// enough to read before the walk. It is the third number in §12.39.1: an
    /// array that arrived short and rows that vanished after they were written
    /// are the same length mismatch without it, and different defects with it.
    static func declaredCounts(_ db: Sub4Database,
                               accountID: String = Sub4Import.accountID,
                               sourceID: String = Sub4Import.sourceID)
    -> Result<[String: Int], RepositoryError> {
        do {
            return .success(try db.queue.read { d in
                var out: [String: Int] = [:]
                for row in try Row.fetchAll(d, sql: headSQL,
                                            arguments: [sourceID, sourceID, accountID]) {
                    guard let id: String = row["storeID"] else { continue }
                    let declared: Int = row["sampleCount"] ?? 0
                    out[id] = declared
                }
                return out
            })
        } catch {
            return .failure(RepositoryError(message: String(describing: error)))
        }
    }

    /// One recording, by the id the STORE uses.''',
    "declaredCounts — the third number",
)

edit(
    REPO,
    r'''    private static let headSQL = """
        SELECT rec.id            AS recordingID,
               r.externalID      AS storeID,
               rec.fetchedUTC    AS fetchedUTC,
               rec.sampleCount   AS sampleCount
        FROM recording rec
        JOIN activity a ON a.id = rec.activityID
        JOIN activity_source_record r
          ON r.activityID = rec.activityID AND r.sourceID = ?
        WHERE rec.sourceID = ? AND a.accountID = ?
        """
}''',
    r'''    private static let headSQL = """
        SELECT rec.id            AS recordingID,
               r.externalID      AS storeID,
               rec.fetchedUTC    AS fetchedUTC,
               rec.sampleCount   AS sampleCount
        FROM recording rec
        JOIN activity a ON a.id = rec.activityID
        JOIN activity_source_record r
          ON r.activityID = rec.activityID AND r.sourceID = ?
        WHERE rec.sourceID = ? AND a.accountID = ?
        """
}

/// The recording comparison — D6a's last, patch 294, ADR-0003 §12.39.
///
/// SPLIT FROM ITS READER, like 290 was from 289. 292 built the reader and
/// proved it against fixtures; this runs it against 645 real recordings and
/// 192,954 real samples.
///
/// THREE NUMBERS, NOT TWO
/// ----------------------
/// Every other comparison in this project has two sides. This one has three:
///
///   the store's array length        `ActivityStreams.distanceM.count`
///   what the importer said it wrote `recording.sampleCount`
///   what the table actually holds   rows in `recording_sample`
///
/// The second exists because the importer wrote it, it costs one row per
/// recording to read, and it separates two failures that otherwise look
/// identical: an array that arrived short, and rows that went missing after
/// they were written. A comparison with only two numbers would report both as
/// "the lengths disagree" and leave somebody to work out which.
///
/// THE GATE BEFORE THE WALK
/// ------------------------
/// If the lengths disagree the per-sample walk is SKIPPED for that recording.
/// One sample missing near the start shifts every later one, and the walk would
/// report ~300 differences on a single defect — enough to bury everything else
/// the run found under one recording's noise. The groundwork decided this
/// before any of it was written (§4).
///
/// A FIELD NAME THAT CARRIES A COUNT IS NOT A FIELD NAME
/// -----------------------------------------------------
/// The whole value of the last two read-backs was the tally: `fetched 320 of
/// 668` was a diagnosis on sight. A tally groups by field name, so the name has
/// to be the SAME string on every recording that has the problem. `heartRate[3
/// of 1204]` is unique per recording, and a tally of unique keys is just a list
/// with extra steps.
///
/// So `fields` carries stable names — `heartRate`, `sampleCount`, `power
/// missing from the database` — and the counts live in two places instead:
/// `detail`, for the handful of ids the screen prints, and `sampleTally`, which
/// adds the bands up across the whole run.
nonisolated enum RecordingRoundTrip {

    /// The eight streams in the order a report should read them. `distanceM`
    /// is first because it is the only one that cannot be absent.
    static let streamNames = ["distanceM", "heartRate", "speed", "altitude",
                              "grade", "power", "latitude", "longitude"]

    struct Difference: Sendable, Identifiable {
        /// The store's activity id — Strava's.
        let id: String
        /// STABLE names, so the tally aggregates. See the header.
        let fields: [String]
        /// The same findings with their numbers, for the few ids printed.
        let detail: String
    }

    /// A recording whose read FAILED — not one the database does not have.
    /// Kept apart from `missing` for the same reason `RecordingLoad` exists.
    struct Unreadable: Sendable, Identifiable {
        let id: String
        let why: String
    }

    /// What one recording's comparison produced, before it is folded into the
    /// report. Separate so it can be tested without a database.
    struct Comparison: Sendable {
        var fields: [String] = []
        var detail: [String] = []
        /// Samples walked and samples that disagreed, per stream. Only streams
        /// that were actually walked appear — a length mismatch contributes a
        /// field and no denominator, because there isn't one.
        var walked: [String: Int] = [:]
        var differing: [String: Int] = [:]

        var agrees: Bool { fields.isEmpty }
        var line: String { detail.joined(separator: "; ") }
    }

    struct Report: Sendable {
        /// How many recordings the database holds. Nil when the id read failed
        /// — which is not zero, and must not be reachable as zero.
        var databaseCount: Int?
        var readFailure: String?
        var compared = 0
        /// In the store and not in the database at all.
        var missing: [String] = []
        var unreadable: [Unreadable] = []
        var differences: [Difference] = []
        var walked: [String: Int] = [:]
        var differing: [String: Int] = [:]

        var agreed: Int { compared - differences.count }
        var isTrustworthy: Bool { readFailure == nil }

        var line: String {
            if let why = readFailure {
                return "The database could not be read — \(why)"
            }
            let n = databaseCount ?? 0
            return unreadable.isEmpty
                ? "\(n) recordings in the database."
                : "\(n) recordings in the database; \(unreadable.count) could not be read."
        }

        /// Recordings differing, by field. Same shape as the other two reports.
        var fieldTally: [(field: String, count: Int)] {
            var counts: [String: Int] = [:]
            for d in differences { for f in d.fields { counts[f, default: 0] += 1 } }
            return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { (field: $0.key, count: $0.value) }
        }

        /// SAMPLES differing, by stream, across everything walked. The band —
        /// "91 of 186,204" — is the finding a per-recording count cannot give.
        var sampleTally: [(stream: String, differing: Int, walked: Int)] {
            RecordingRoundTrip.streamNames.compactMap { name in
                let d = differing[name] ?? 0
                guard d > 0 else { return nil }
                return (stream: name, differing: d, walked: walked[name] ?? 0)
            }
        }

        var samplesWalked: Int { walked.values.reduce(0, +) }
    }

    // MARK: The run

    /// ONE AT A TIME. The store side is already in memory; the database side is
    /// built, checked and dropped per recording, so 192,954 samples are never
    /// all resident at once. That is the entire reason `ids` and
    /// `streams(_:storeID:)` exist — see this file's header.
    static func compare(_ db: Sub4Database, store: [ActivityStreams]) -> Report {
        var report = Report()

        let declared: [String: Int]
        switch RecordingRepository.declaredCounts(db) {
        case .failure(let e):
            // The FIRST read failed, so nothing below it can be trusted. A
            // report of "0 compared" here would read as "nothing to compare".
            report.readFailure = e.message
            return report
        case .success(let counts):
            declared = counts
        }
        report.databaseCount = declared.count

        for s in store.sorted(by: { $0.activityId < $1.activityId }) {
            let load = RecordingRepository.streams(db, storeID: s.activityId)
            guard load.isTrustworthy else {
                report.unreadable.append(Unreadable(id: s.activityId, why: load.line))
                continue
            }
            guard let back = load.recordings?.first else {
                report.missing.append(s.activityId)
                continue
            }

            report.compared += 1
            let c = compareOne(s, back, declared: declared[s.activityId])
            for (k, v) in c.walked { report.walked[k, default: 0] += v }
            for (k, v) in c.differing { report.differing[k, default: 0] += v }
            if !c.agrees {
                report.differences.append(Difference(id: s.activityId,
                                                     fields: c.fields,
                                                     detail: c.line))
            }
        }
        return report
    }

    /// OFF THE MAIN ACTOR, unlike the other two read-backs, and the difference
    /// is size rather than taste. The activity and detail comparisons are 668
    /// structs against one query each. This is 645 read transactions and about
    /// 1.5 million `Double` comparisons, which on the main actor is a frozen
    /// screen for as long as it takes — and a diagnostic that looks like a
    /// hang is a diagnostic nobody presses twice.
    ///
    /// Safe because `Sub4Database` is `Sendable` (it holds a GRDB
    /// `DatabaseQueue`, which serialises its own access) and `ActivityStreams`
    /// is a `nonisolated` value type.
    static func compareOffMain(_ db: Sub4Database,
                               store: [ActivityStreams]) async -> Report {
        await Task.detached(priority: .userInitiated) {
            compare(db, store: store)
        }.value
    }

    // MARK: One recording

    /// `declared` is `recording.sampleCount` — what the importer recorded it
    /// wrote — or nil when the caller has not read it.
    static func compareOne(_ s: ActivityStreams, _ d: ActivityStreams,
                           declared: Int? = nil) -> Comparison {
        var c = Comparison()

        // Before the gate: a timestamp is comparable whatever the lengths do.
        // Truncated to the second, because the writer truncates — 291a, and
        // that correction cost 320 phantom differences to find.
        if !DetailRoundTrip.sameSecond(s.fetched, d.fetched) {
            c.fields.append("fetched")
            c.detail.append("fetched differs")
        }

        // The header against the table. Rows lost after the insert look
        // exactly like a short array unless this is asked separately.
        if let declared, declared != d.count {
            c.fields.append("sampleCount vs rows")
            c.detail.append("recording.sampleCount says \(declared), "
                            + "the table holds \(d.count)")
        }

        // THE GATE. Past here the walk would compare sample i to sample i of a
        // different recording length and report noise — see the header.
        guard s.count == d.count else {
            c.fields.append("sampleCount")
            c.detail.append("\(s.count) samples in the store, \(d.count) in the database")
            return c
        }

        walkSamples("distanceM", s.distanceM, d.distanceM, &c)
        walk("heartRate", s.heartRate, d.heartRate, &c)
        walk("speed", s.speed, d.speed, &c)
        walk("altitude", s.altitude, d.altitude, &c)
        walk("grade", s.grade, d.grade, &c)
        walk("power", s.power, d.power, &c)
        walk("latitude", s.latitude, d.latitude, &c)
        walk("longitude", s.longitude, d.longitude, &c)
        return c
    }

    /// Present on one side and absent on the other is NOT a differing sample —
    /// it is a differing stream, and §12.38.5 is why it gets its own name:
    /// `has(_:)` decides whether a chart is drawn at all.
    private static func walk(_ name: String, _ s: [Double]?, _ d: [Double]?,
                             _ c: inout Comparison) {
        switch (s, d) {
        case (nil, nil):
            return
        case (nil, .some(let y)):
            c.fields.append("\(name) surplus in the database")
            c.detail.append("\(name): absent in the store, \(y.count) in the database")
        case (.some(let x), nil):
            c.fields.append("\(name) missing from the database")
            c.detail.append("\(name): \(x.count) in the store, absent in the database")
        case (.some(let x), .some(let y)):
            walkSamples(name, x, y, &c)
        }
    }

    private static func walkSamples(_ name: String, _ x: [Double], _ y: [Double],
                                    _ c: inout Comparison) {
        // The short-stream loss lands here: the importer pads to
        // `distanceM.count` with NULL, the reader reads NULL as zero, and the
        // original length is not recoverable — §12.38.4. Reported as a length,
        // which is what it is, rather than as N differing samples.
        guard x.count == y.count else {
            c.fields.append("\(name) length")
            c.detail.append("\(name): \(x.count) in the store, \(y.count) in the database")
            return
        }
        var differing = 0
        for i in 0..<x.count where x[i] != y[i] { differing += 1 }
        c.walked[name] = x.count
        if differing > 0 {
            c.differing[name] = differing
            c.fields.append(name)
            c.detail.append("\(name)[\(differing) of \(x.count)]")
        }
    }
}
''',
    "RecordingRoundTrip, beside its reader like ActivityRoundTrip is",
)

# ------------------------------------------------------------------ 2. the view

edit(
    VIEW,
    r'''    @State private var readingBack = false
    @State private var roundTrip: ActivityRoundTrip.Report?
    @State private var roundTripLoad: ActivityLoad?''',
    r'''    @State private var readingBack = false
    @State private var roundTrip: ActivityRoundTrip.Report?
    @State private var roundTripLoad: ActivityLoad?
    /// Patch 294. No separate load state: this comparison does its own reading
    /// and the report carries the read's own outcome, because the id read
    /// failing means everything under it is unknown rather than zero.
    @State private var readingBackRecording = false
    @State private var recordingTrip: RecordingRoundTrip.Report?''',
    "state for the third read-back",
)

edit(
    VIEW,
    r'''                readBackSection(db)
                detailReadBackSection(db)''',
    r'''                readBackSection(db)
                detailReadBackSection(db)
                recordingReadBackSection(db)''',
    "the row, under the other two",
)

edit(
    VIEW,
    r'''    private func runDetailReadBack(_ db: Sub4Database) {''',
    r'''    /// PATCH 294. The third read-back, and the only one that walks samples.
    ///
    /// The tally is in TWO parts here and one part on the other two screens.
    /// "12 recordings differ on heartRate" is a different question from "91
    /// samples out of 186,204 differ on heartRate" — the first says how wide
    /// the problem is, the second says how deep — and one number cannot answer
    /// both. §12.39.2.
    @ViewBuilder
    private func recordingReadBackSection(_ db: Sub4Database) -> some View {
        Section {
            if readingBackRecording {
                HStack { ProgressView(); Text("Walking samples…").font(.caption) }
            } else {
                Button("Read the recordings back out") { runRecordingReadBack(db) }
            }

            if let r = recordingTrip {
                LabeledContent("The read", value: r.line)
                    .font(.caption)
                    .foregroundStyle(r.isTrustworthy ? Color.dim : .red)

                if r.isTrustworthy {
                    LabeledContent("Compared", value: "\(r.compared)")
                        .font(.caption).foregroundStyle(Color.dim)
                    LabeledContent("Agreed on every sample", value: "\(r.agreed)")
                        .font(.caption)
                        .foregroundStyle(r.agreed == r.compared ? Color.dim : Color.ink)
                    LabeledContent("Samples walked", value: "\(r.samplesWalked)")
                        .font(.caption).foregroundStyle(Color.dim)

                    if !r.missing.isEmpty {
                        LabeledContent("In the store, not in the database",
                                       value: "\(r.missing.count)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if !r.unreadable.isEmpty {
                        LabeledContent("Could not be read", value: "\(r.unreadable.count)")
                            .font(.caption).foregroundStyle(.red)
                    }

                    // How WIDE — recordings, by field.
                    ForEach(r.fieldTally.prefix(12), id: \.field) { entry in
                        LabeledContent("  \(entry.field)", value: "\(entry.count)")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    if r.fieldTally.count > 12 {
                        Text("  + \(r.fieldTally.count - 12) more fields")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }

                    // How DEEP — samples, by stream.
                    ForEach(r.sampleTally, id: \.stream) { entry in
                        LabeledContent("  \(entry.stream) samples",
                                       value: "\(entry.differing) of \(entry.walked)")
                            .font(.caption2).foregroundStyle(.red)
                    }

                    ForEach(r.differences.prefix(5)) { d in
                        Text("    \(d.id) — \(d.detail)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    if r.differences.count > 5 {
                        Text("    + \(r.differences.count - 5) more")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                }
            }
        } header: {
            Text("Read-back · recordings")
        } footer: {
            Text("Every sample of every stream, compared one recording at a "
                 + "time. A recording whose lengths disagree is reported as a "
                 + "length and not walked, so one missing sample cannot report "
                 + "as three hundred. A stream that was shorter than the "
                 + "distance axis comes back padded with zeros and its "
                 + "original length is gone — that is a real loss and it is "
                 + "expected to show here. See ADR-0003 §12.39.")
                .font(.caption2)
        }
    }

    private func runRecordingReadBack(_ db: Sub4Database) {
        readingBackRecording = true
        let store = Array(DetailStore.shared.streams.values)
        Task {
            // OFF the main actor, unlike the two above — 645 read transactions
            // and ~1.5 million comparisons. See `compareOffMain`.
            recordingTrip = await RecordingRoundTrip.compareOffMain(db, store: store)
            readingBackRecording = false
        }
    }

    private func runDetailReadBack(_ db: Sub4Database) {''',
    "the section and its runner",
)

# ----------------------------------------------------------------- 3. the tests

edit(
    TESTS,
    r'''        let other = RecordingRepository.all(db, accountID: "someone-else")
        #expect(other.isTrustworthy)
        #expect(other.recordings?.isEmpty == true)
    }
}''',
    r'''        let other = RecordingRepository.all(db, accountID: "someone-else")
        #expect(other.isTrustworthy)
        #expect(other.recordings?.isEmpty == true)
    }
}

// MARK: -

/// The recording comparison — patch 294, ADR-0003 §12.39.
///
/// `theFieldNameIsStableAcrossRecordings` is the one with teeth. The tally is
/// the whole point of a read-back — `fetched 320 of 668` was a diagnosis on
/// sight — and a tally groups by field name. Put the count IN the name and
/// every recording gets its own key, the tally becomes a list, and the screen
/// goes back to being a list of ids somebody has to open one at a time.
@Suite
@MainActor
struct RecordingRoundTripTests {

    /// `day` so two recordings in one test are two DIFFERENT sessions. Two
    /// activities at the same instant is a matcher question, and this suite is
    /// not asking one.
    private func activity(_ id: String, day: Int = 28) -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-\(day)T18:02:00", distance: 24_300,
                 movingTime: 3_240, elapsedTime: 3_600,
                 elevationGain: 142, averageHeartrate: 131, isTrainer: false,
                 maxHeartrate: 168, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: true, averageWatts: 168,
                 startUTC: "2026-07-\(day)T16:02:00Z", startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func streams(_ id: String,
                         distanceM: [Double] = [0, 500, 1000],
                         heartRate: [Double]? = [120, 131, 145],
                         power: [Double]? = nil,
                         fetched: Date = Date(timeIntervalSince1970: 1_785_000_000))
    -> ActivityStreams {
        ActivityStreams(activityId: id,
                        distanceM: distanceM,
                        heartRate: heartRate,
                        speed: [3.1, 3.4, 3.3],
                        altitude: [12, 14, 11],
                        grade: [0, 1.2, -0.4],
                        power: power,
                        latitude: nil, longitude: nil,
                        fetched: fetched)
    }

    private func imported(_ s: [ActivityStreams]) throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        let activities = s.enumerated().map { i, x in activity(x.activityId, day: 10 + i) }
        _ = try Sub4Import.run(into: db, activities: activities,
                               shoes: [], streams: s)
        return db
    }

    // MARK: The whole run, against the importer

    @Test("A recording that went in unchanged agrees on every sample")
    func theRealRoundTripAgrees() throws {
        let one = streams("19580875358")
        let db = try imported([one])
        let r = RecordingRoundTrip.compare(db, store: [one])

        #expect(r.isTrustworthy)
        #expect(r.databaseCount == 1)
        #expect(r.compared == 1)
        #expect(r.agreed == 1)
        #expect(r.differences.isEmpty)
        #expect(r.missing.isEmpty)
        #expect(r.samplesWalked == 3 * 5, "distance, heart rate, speed, altitude, grade")
    }

    /// THE ONE WITH TEETH. Two recordings, the same defect, different ids —
    /// and it has to land under ONE key or the tally is a list.
    @Test("The field name is stable across recordings, so the tally adds up")
    func theFieldNameIsStableAcrossRecordings() throws {
        let a = streams("1"), b = streams("2")
        let db = try imported([a, b])
        try db.queue.write { d in
            try d.execute(sql: "UPDATE recording_sample SET heartRate = 999 WHERE ordinal = 0")
        }

        let r = RecordingRoundTrip.compare(db, store: [a, b])
        #expect(r.compared == 2)
        #expect(r.agreed == 0)

        #expect(r.fieldTally.map(\.field) == ["heartRate"],
                "one key, not one per recording")
        #expect(r.fieldTally.map(\.count) == [2])

        // How WIDE and how DEEP are different numbers, and both are here.
        #expect(r.sampleTally.map(\.stream) == ["heartRate"])
        #expect(r.sampleTally.map(\.differing) == [2])
        #expect(r.sampleTally.map(\.walked) == [6], "3 samples × 2 recordings")

        // The count lives in the printed line, where it is unique on purpose.
        #expect(r.differences.allSatisfy { $0.detail.contains("heartRate[1 of 3]") })
    }

    @Test("A recording the database does not have is missing, not different")
    func missingIsNotDifferent() throws {
        let there = streams("1")
        let db = try imported([there])
        let absent = streams("2")

        let r = RecordingRoundTrip.compare(db, store: [there, absent])
        #expect(r.compared == 1)
        #expect(r.missing == ["2"])
        #expect(r.differences.isEmpty)
    }

    /// §12.39.1's third number. Deleting a sample leaves the header claiming a
    /// count the table no longer has — a different defect from an array that
    /// arrived short, and indistinguishable from it without `sampleCount`.
    @Test("Rows lost after the header was written are named as that")
    func rowsLostAfterTheHeaderAreNamed() throws {
        let one = streams("19580875358")
        let db = try imported([one])
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM recording_sample WHERE ordinal = 2")
        }

        let r = RecordingRoundTrip.compare(db, store: [one])
        let fields = try #require(r.differences.first?.fields)
        #expect(fields.contains("sampleCount vs rows"),
                "the header says 3 and the table holds 2")
        #expect(fields.contains("sampleCount"),
                "and the store says 3 as well")
        #expect(!fields.contains("heartRate"),
                "the walk is skipped — one lost row must not report as three")
    }

    /// §12.38.4, now measured rather than asserted in isolation. A stream
    /// shorter than the distance axis is padded on the way in and cannot be
    /// unpadded on the way out.
    @Test("A short stream comes back as a length difference, not as zeros")
    func theShortStreamShowsAsALength() throws {
        let short = streams("19580875358", heartRate: [120, 131])
        let db = try imported([short])

        let r = RecordingRoundTrip.compare(db, store: [short])
        #expect(r.compared == 1)
        #expect(r.fieldTally.map(\.field) == ["heartRate length"])
        #expect(r.differences.first?.detail
                    .contains("heartRate: 2 in the store, 3 in the database") == true)
        #expect(r.sampleTally.isEmpty,
                "a length mismatch has no denominator, so it contributes no band")
    }

    @Test("The declared counts are what the importer wrote")
    func declaredCountsAreWhatWasWritten() throws {
        let db = try imported([streams("1"), streams("2", distanceM: [0, 100])])
        guard case .success(let counts) = RecordingRepository.declaredCounts(db) else {
            Issue.record("declaredCounts failed"); return
        }
        #expect(counts == ["1": 3, "2": 2])
    }

    // MARK: One recording, without a database

    @Test("Identical sides agree")
    func identicalSidesAgree() {
        let s = streams("1")
        #expect(RecordingRoundTrip.compareOne(s, s).agrees)
    }

    /// The gate. One sample missing near the start shifts every later one.
    @Test("The length gate stops the walk")
    func theLengthGateStopsTheWalk() {
        let s = streams("1")
        let d = streams("1", distanceM: [0, 500, 1000, 1500],
                        heartRate: [9, 9, 9, 9])
        let c = RecordingRoundTrip.compareOne(s, d)
        #expect(c.fields == ["sampleCount"])
        #expect(c.walked.isEmpty, "nothing was walked, so nothing claims to have been")
        #expect(c.line.contains("3 samples in the store, 4 in the database"))
    }

    /// §12.38.5. Absent and all-zero are one bit apart in the database and a
    /// whole feature apart in the app, so they get different names.
    @Test("A stream present on one side only is a stream, not a sample")
    func presenceIsNotASample() {
        let withPower = streams("1", power: [180, 220, 195])
        let without = streams("1", power: nil)

        let lost = RecordingRoundTrip.compareOne(withPower, without)
        #expect(lost.fields == ["power missing from the database"])
        #expect(lost.differing["power"] == nil, "no samples differed — there are none")

        let gained = RecordingRoundTrip.compareOne(without, withPower)
        #expect(gained.fields == ["power surplus in the database"])
    }

    /// 291a's lesson, carried across: the writer truncates, so the comparison
    /// truncates. Rounding here cost 320 phantom differences on the details.
    @Test("The fetched date is compared to the truncated second")
    func fetchedIsTruncated() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        let s = streams("1", fetched: base)
        let d = streams("1", fetched: base.addingTimeInterval(0.6))
        #expect(RecordingRoundTrip.compareOne(s, d).agrees,
                "a fraction of a second cannot reach the column")

        let later = streams("1", fetched: base.addingTimeInterval(2))
        #expect(RecordingRoundTrip.compareOne(s, later).fields == ["fetched"])
    }

    /// A timestamp is comparable whatever the lengths do, so it is checked
    /// before the gate rather than lost behind it.
    @Test("A date difference survives a length difference")
    func theDateIsCheckedBeforeTheGate() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        let s = streams("1", fetched: base)
        let d = streams("1", distanceM: [0, 500], heartRate: [120, 131],
                        fetched: base.addingTimeInterval(90))
        let c = RecordingRoundTrip.compareOne(s, d)
        #expect(c.fields.contains("fetched"))
        #expect(c.fields.contains("sampleCount"))
    }

    // MARK: The report's own honesty

    /// The first read is the id read, and if it fails everything under it is
    /// unknown rather than zero — the fifth instance of §12.15's shape.
    @Test("A failed read is not a comparison of nothing")
    func aFailedReadIsNotZero() {
        var r = RecordingRoundTrip.Report()
        r.readFailure = "the file is locked"
        #expect(!r.isTrustworthy)
        #expect(r.databaseCount == nil, "not 0 — nobody counted")
        #expect(r.line.contains("could not be read"))
    }

    @Test("An empty database is a trustworthy zero")
    func emptyIsTrustworthy() throws {
        let db = try Sub4Database.inMemory()
        let r = RecordingRoundTrip.compare(db, store: [])
        #expect(r.isTrustworthy)
        #expect(r.databaseCount == 0)
        #expect(r.line == "0 recordings in the database.")
        #expect(r.compared == 0)
    }
}
''',
    "RecordingRoundTripTests — appended, so no new file and no restart",
)

# ------------------------------------------------------------------- 4. the ADR

edit(
    ADR,
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.39 The recording round trip — D6a's last comparison, patch 294

Patch 292 built the reader and proved it against fixtures. This runs it against
645 real recordings and 192,954 real samples, and it is the last of the three
read-backs D6a set out to build.

Three comparisons, three shapes, and the differences between them are the
interesting part:

| | compares | matched by | reports |
|---|---|---|---|
| 290 activities | 19 scalar fields | store id | field, per activity |
| 291 details | 8 scalars + 3 arrays | `index` and `name` | field, per element |
| 294 recordings | 8 parallel arrays | array position | **stream, and a band** |

### 12.39.1 Three numbers, not two

Every other comparison in this project has two sides. This one has three:

    the store's array length          ActivityStreams.distanceM.count
    what the importer said it wrote   recording.sampleCount
    what the table actually holds     rows in recording_sample

The middle one exists because the importer already wrote it — `INSERT INTO
recording (…, sampleCount, …) VALUES (…, s.count, …)` — and reading it costs one
row per recording and no samples at all.

It earns its place by separating two failures that are otherwise identical. An
array that arrived from Strava shorter than the distance axis, and rows that
went missing from `recording_sample` after they were written, are both "the
lengths disagree" with two numbers. With three they are `sampleCount` and
`sampleCount vs rows`, and one of them is a data question while the other is a
database question.

This is the same argument as §12.35.4's `skipped`: a diagnostic that cannot say
which of two things happened will eventually be read as having said one.

### 12.39.2 A field name that carries a count is not a field name

The whole value of the previous two read-backs was the **tally**. `fetched 320
of 668` was a diagnosis on sight — 47.9% is the fraction of timestamps with a
fractional second of 0.5 or more, and the proportion named the bug (§12.37.4).
A list of 320 activity ids would have named nothing.

A tally groups by field name. So the name has to be the *same string* on every
recording that has the problem. The obvious field name here —
`heartRate[3 of 1204]` — is unique per recording, which turns the tally back
into a list with extra steps.

So the counts were moved out of the name and into two other places:

- **`fields`** carries stable names: `heartRate`, `sampleCount`,
  `power missing from the database`, `heartRate length`.
- **`detail`** carries the same finding with its numbers, printed for the
  handful of ids the screen shows.
- **`sampleTally`** adds the bands up across the whole run, per stream.

Which gives the screen two tallies rather than one, and they answer different
questions. `fieldTally` says how WIDE — *twelve recordings differ on heart
rate*. `sampleTally` says how DEEP — *ninety-one samples out of 186,204*.
Twelve recordings each off by one sample and twelve recordings off by three
hundred are the same number in the first tally and nothing alike in the second.

`theFieldNameIsStableAcrossRecordings` is the test with teeth, and it is a test
about a string.

### 12.39.3 The gate before the walk

If the two lengths disagree, the per-sample walk is **skipped** for that
recording.

One sample missing near the start shifts every later sample by one position,
and a positional walk would report roughly three hundred differences on a single
defect — enough for one bad recording to bury everything else the run found.
The groundwork decided this before any of it was written (`D6A-RECORDING-
GROUNDWORK.md` §4), which is the point of writing groundwork.

The date is checked *before* the gate rather than behind it: a timestamp is
comparable whatever the lengths do, and losing it to an unrelated length
mismatch would be a second silent gap of exactly the kind §12.35.4 exists to
prevent.

### 12.39.4 Off the main actor, and why only this one

The activity and detail read-backs run their comparison inside a `Task` on the
main actor, which is fine: 668 structs against one query each.

This one is 645 read transactions and roughly 1.5 million `Double` comparisons.
On the main actor that is a screen frozen for as long as it takes, and **a
diagnostic that looks like a hang is a diagnostic nobody presses twice.** So
`compareOffMain` hands the whole run to `Task.detached`.

It is safe rather than lucky: `Sub4Database` is `Sendable` and holds a GRDB
`DatabaseQueue`, which serialises its own access, and `ActivityStreams` is a
`nonisolated` value type whose stored properties are all `Sendable`. The type
work that patches 219, 230, 237 and 245 did is what makes this a one-line
change instead of a refactor.

### 12.39.5 What it is expected to find, stated as a prediction

Written before the device run, and labelled as a prediction on purpose —
§12.29.2.1 records what happens when a conclusion gets written into this file
from a measurement that did not exist yet.

The expectation is **`heartRate length` on some number of recordings**: a stream
that Strava returned shorter than the distance axis is written with trailing
NULLs, read back as zeros at full length, and its original length is not
recoverable (§12.38.4). `aShortStreamIsPadded` has pinned that loss since 292;
what is not known is how many recordings carry it, and that number is the whole
reason to run this.

Anything else — a `sampleCount vs rows`, a differing `distanceM` — is not
expected and would be a real finding.

The measurement goes in §12.39.6 after the run, and not before.

## 12.10 The athlete profile, the zones and the resting series''',
    "§12.39",
)

# --------------------------------------------------------------- 5. the version

edit(
    VER,
    r'''    static let patch = 293''',
    r'''    static let patch = 294''',
    "294",
)


# ---------------------------------------------------------------------- machinery

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
    print("  1. run the suite — xcodebuild test is the only compiler in this loop")
    print("  2. ⌘R, Settings → Database, press 'Read the recordings back out'")
    print("  3. the numbers go in ADR §12.39.6, after they exist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
