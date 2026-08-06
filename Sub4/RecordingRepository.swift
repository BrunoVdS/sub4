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
