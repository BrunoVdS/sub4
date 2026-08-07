//
//  RecordingRepository.swift
//  Sub4
//
//  D6a's third reader — patch 292, ADR-0003 §12.38.
//  Design: docs/D6A-RECORDING-GROUNDWORK.md, settled before this was written.
//
//  SPLIT FROM ITS COMPARISON, like 289 was from 290. This patch is the reader
//  and its tests; the round trip and the read-back row follow. 645 recordings
//  and 192,954 samples is enough work for one patch on its own.
//
//  FOUR RENAMES, AND `power` IS THE ONE
//  ------------------------------------
//    speed     → speedMS
//    altitude  → altitudeM
//    grade     → gradePercent
//    power     → watts        ← the one most likely to be typed straight through
//
//  `ordinal` IS THE ARRAY POSITION
//  -------------------------------
//  Third convention across four child tables — `activity_split` and
//  `activity_lap` store a domain index, `activity_best_effort` and this store
//  the array position. Ordered by, then discarded: `ActivityStreams` has no
//  per-sample identity at all.
//
//  READ ONE AT A TIME
//  ------------------
//  `ids(_:)` then `streams(_:storeID:)`, rather than materialising all 645.
//  ~12 MB of `Double` is survivable and pointless: the comparison builds one,
//  checks it and discards it. `all(_:)` exists for the tests and for a caller
//  that genuinely wants the lot, and says so in its own comment.
//
//  THE LOSSY STEP, NAMED RATHER THAN DISCOVERED
//  --------------------------------------------
//  The importer writes `at(series, i)`, which is `nil` for an absent array AND
//  `nil` past its end — no padding, no default. So a stream that was present
//  but SHORTER than `distanceM` was stored with trailing NULLs, and cannot be
//  told apart on the way back from a full-length stream missing its tail.
//
//  This reconstructs optional streams at `distanceM.count` and does not guess
//  at trimming. A NULL inside a present stream becomes `0`, which is already
//  what `ActivityStreams.has(_:)` treats as nothing there — it tests
//  `contains { $0 > 0 }`. Both are real losses and both are left visible for
//  the comparison to report.
//

import Foundation
import GRDB

/// What a read of the recording tables produced.
nonisolated enum RecordingLoad: Sendable {
    case loaded(recordings: [ActivityStreams], skipped: Int)
    case unavailable
    case failed(String)

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Optional, never `[]`.
    var recordings: [ActivityStreams]? {
        if case .loaded(let r, _) = self { return r }
        return nil
    }

    var skipped: Int {
        if case .loaded(_, let n) = self { return n }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(let r, let skipped):
            skipped == 0
                ? "\(r.count) recordings."
                : "\(r.count) recordings; \(skipped) rows could not be read."
        case .unavailable: "The database is not open."
        case .failed(let why): "The database could not be read — \(why)"
        }
    }
}

/// A reason a read failed, as something `Result` will accept — 292a.
///
/// `Result<[String], String>` does not compile: the failure type must conform
/// to `Error`. A named type is also better than `any Error`, which is not
/// `Sendable` — the same argument `HealthStore.HealthQueryError` records at
/// 286b, where this exact mistake was made six patches earlier.
nonisolated struct RepositoryError: Error, Sendable, Equatable {
    let message: String
}

nonisolated enum RecordingRepository {

    /// The store ids of every recording, oldest first by nothing in
    /// particular — order is not meaningful here, and a caller that wants one
    /// asks for it.
    ///
    /// THE ENTRY POINT THE COMPARISON USES. One id at a time keeps 192,954
    /// samples out of memory at once.
    static func ids(_ db: Sub4Database,
                    accountID: String = Sub4Import.accountID,
                    sourceID: String = Sub4Import.sourceID) -> Result<[String], RepositoryError> {
        do {
            return .success(try db.queue.read { d in
                try String.fetchAll(d, sql: """
                    SELECT r.externalID
                    FROM recording rec
                    JOIN activity a ON a.id = rec.activityID
                    JOIN activity_source_record r
                      ON r.activityID = rec.activityID AND r.sourceID = ?
                    WHERE rec.sourceID = ? AND a.accountID = ?
                    ORDER BY r.externalID
                    """, arguments: [sourceID, sourceID, accountID])
            })
        } catch {
            return .failure(RepositoryError(message: String(describing: error)))
        }
    }

    /// What the IMPORTER said it wrote, per store id — `recording.sampleCount`.
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

    /// One recording, by the id the STORE uses.
    static func streams(_ db: Sub4Database, storeID: String,
                        accountID: String = Sub4Import.accountID,
                        sourceID: String = Sub4Import.sourceID) -> RecordingLoad {
        do {
            return try db.queue.read { d -> RecordingLoad in
                guard let head = try Row.fetchOne(d, sql: headSQL + "\n  AND r.externalID = ?",
                                                   arguments: [sourceID, sourceID,
                                                               accountID, storeID]),
                      let recordingID: String = head["recordingID"] else {
                    return .loaded(recordings: [], skipped: 0)
                }
                let one = try build(d, recordingID: recordingID,
                                    storeID: storeID, head: head)
                return .loaded(recordings: [one], skipped: 0)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// EVERY recording at once. ~12 MB of `Double` on this device.
    ///
    /// Here for the tests and for a caller that genuinely wants the lot. The
    /// comparison should use `ids` and `streams` instead — building one,
    /// checking it and discarding it — which is the whole reason those exist.
    static func all(_ db: Sub4Database,
                    accountID: String = Sub4Import.accountID,
                    sourceID: String = Sub4Import.sourceID) -> RecordingLoad {
        do {
            return try db.queue.read { d -> RecordingLoad in
                let heads = try Row.fetchAll(d, sql: headSQL,
                                             arguments: [sourceID, sourceID, accountID])
                var out: [ActivityStreams] = []
                var skipped = 0
                for head in heads {
                    guard let recordingID: String = head["recordingID"],
                          let storeID: String = head["storeID"] else { skipped += 1; continue }
                    out.append(try build(d, recordingID: recordingID,
                                         storeID: storeID, head: head))
                }
                return .loaded(recordings: out, skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: Building one

    private static func build(_ d: Database, recordingID: String,
                              storeID: String, head: Row) throws -> ActivityStreams {
        let rows = try Row.fetchAll(d, sql: """
            SELECT distanceM, heartRate, speedMS, altitudeM, gradePercent,
                   watts, latitude, longitude
            FROM recording_sample WHERE recordingID = ? ORDER BY ordinal
            """, arguments: [recordingID])

        return ActivityStreams(
            activityId: storeID,
            distanceM: rows.map { $0["distanceM"] },
            heartRate: series(rows, "heartRate"),
            speed: series(rows, "speedMS"),
            altitude: series(rows, "altitudeM"),
            grade: series(rows, "gradePercent"),
            power: series(rows, "watts"),
            latitude: series(rows, "latitude"),
            longitude: series(rows, "longitude"),
            fetched: ActivityDetailRepository.parseUTC(head["fetchedUTC"]) ?? .distantPast)
    }

    /// ALL NULL MEANS THE ARRAY WAS ABSENT. Anything else is an array of the
    /// full length with its NULLs read as zero — see the header. There is no
    /// third answer available: `[Double]?` cannot hold a per-element nil, and
    /// the original length of a short stream is not recoverable.
    private static func series(_ rows: [Row], _ column: String) -> [Double]? {
        var out: [Double] = []
        var any = false
        out.reserveCapacity(rows.count)
        for row in rows {
            if let v: Double = row[column] { any = true; out.append(v) }
            else { out.append(0) }
        }
        return any ? out : nil
    }

    // MARK: The head query

    private static let headSQL = """
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

