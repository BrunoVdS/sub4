//
//  Sub4Import+Recording.swift
//  Sub4
//
//  The traces and the details — patch 243, ADR-0003 §12.12.
//
//  TWO STORES, ONE KEY
//  -------------------
//  `DetailStore` holds both, dictionaries keyed by Strava activity id, and
//  neither can be written without resolving that id to the canonical activity
//  through `activity_alias` — the same re-keying weather needed in §12.9. So
//  they are imported together, after the activities, and both count an
//  unresolvable id rather than refusing it: an activity the app has excluded
//  still has a trace on disk, and that is the exclusion working.
//
//  A TRACE IS ONE OBJECT, REPLACED WHOLE
//  -------------------------------------
//  A recording is not merged sample by sample. Merging would need an identity
//  for a sample, and it has none — it is the four hundredth reading in a list.
//  So an existing recording whose `fetchedUTC` differs is deleted and rewritten
//  entire, with `ON DELETE CASCADE` clearing its samples; one whose stamp
//  matches is left alone and counted as unchanged. Same for a detail and its
//  splits, laps and best efforts.
//
//  THE ONE RULE THE SCHEMA CANNOT STATE
//  ------------------------------------
//  `recording_sample.distanceM` is CHECKed as non-negative, and the migration
//  says the rest out loud: "never decreasing — the second of those is not
//  expressible as a column CHECK and belongs to the importer". So it is here.
//
//  A trace whose x axis goes backwards draws a chart that lies — the line
//  doubles back and every pace read off it between those two points is
//  nonsense. Such a recording is refused whole and the ordinal is named,
//  because storing it would put a defect into the one table nothing else can
//  cross-check.
//
//  SHORT TRACES ARE STORED AND COUNTED
//  -----------------------------------
//  `ActivityStreams.isUsable` is `count >= 8`, and the app will not chart
//  anything below that. It is still imported: eight is a charting threshold,
//  not a truth threshold, and a three-sample trace is a fact about a recording
//  that stopped. Counted separately so the number is visible rather than
//  discovered later as a puzzle.
//

import Foundation
import GRDB

extension Sub4Import {

    // MARK: Traces

    nonisolated static func importRecordings(
        _ d: Database,
        streams: [ActivityStreams],
        now: String,
        into report: inout Report
    ) throws {
        for s in streams.sorted(by: { $0.activityId < $1.activityId }) {
            // BEFORE `recordingsSeen` — patch 256. A trace belonging to a
            // recording the app has excluded is not a trace this import has
            // anything to say about, and counting it as seen-then-unmatched
            // reported a decision as a gap. See `DataCorrections`.
            if DataCorrections.isIgnored(id: s.activityId) {
                report.recordingsIgnored += 1
                continue
            }
            report.recordingsSeen += 1

            guard let activityID = try canonicalActivity(d, externalID: s.activityId) else {
                report.recordingsUnmatched += 1
                continue
            }

            // Checked BEFORE anything is written, so a refusal costs no work
            // and leaves no half-recording behind.
            if let bad = firstDecrease(in: s.distanceM) {
                report.refusals.append(.init(
                    externalID: "trace \(s.activityId)",
                    reason: "distance decreases at sample \(bad): "
                          + "\(s.distanceM[bad - 1]) → \(s.distanceM[bad])"))
                continue
            }
            if !s.isUsable { report.recordingsShort += 1 }

            let fetched = iso8601(s.fetched)
            let existing = try Row.fetchOne(d, sql: """
                SELECT id, fetchedUTC FROM recording
                WHERE activityID = ? AND sourceID = ?
                """, arguments: [activityID, sourceID])

            if let existing, existing["fetchedUTC"] as String? == fetched {
                report.recordingsUnchanged += 1
                continue
            }

            do {
                try d.inSavepoint {
                    if let existing, let id = existing["id"] as String? {
                        // Cascade clears the samples. Deleting the parent is
                        // one statement against a table with tens of thousands
                        // of rows in it.
                        try d.execute(sql: "DELETE FROM recording WHERE id = ?",
                                      arguments: [id])
                    }
                    let id = UUID().uuidString
                    try d.execute(sql: """
                        INSERT INTO recording
                          (id, activityID, fetchedUTC, sampleCount, sourceID)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [id, activityID, fetched, s.count, sourceID])

                    for i in 0..<s.count {
                        try d.execute(sql: """
                            INSERT INTO recording_sample
                              (recordingID, ordinal, distanceM, heartRate,
                               speedMS, altitudeM, gradePercent, watts,
                               latitude, longitude)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [id, i, s.distanceM[i],
                                             at(s.heartRate, i), at(s.speed, i),
                                             at(s.altitude, i), at(s.grade, i),
                                             at(s.power, i), at(s.latitude, i),
                                             at(s.longitude, i)])
                        report.samplesImported += 1
                    }
                    return .commit
                }
                if existing != nil { report.recordingsUpdated += 1 }
                else { report.recordingsImported += 1 }
            } catch {
                report.refusals.append(.init(externalID: "trace \(s.activityId)",
                                             reason: String(describing: error)))
            }
        }
    }

    /// Index into a series that may be absent or shorter than the x axis.
    ///
    /// Strava returns each stream separately and they are supposed to be the
    /// same length. "Supposed to" is not a guarantee, and an index out of range
    /// here would crash the import rather than lose one reading — so a short
    /// series simply runs out and the rest of the samples carry NULL, which is
    /// what NULL means in this table.
    private nonisolated static func at(_ series: [Double]?, _ i: Int) -> Double? {
        guard let series, i < series.count else { return nil }
        return series[i]
    }

    /// The index at which the x axis goes backwards, or nil.
    nonisolated static func firstDecrease(in xs: [Double]) -> Int? {
        guard xs.count > 1 else { return nil }
        for i in 1..<xs.count where xs[i] < xs[i - 1] { return i }
        return nil
    }

    // MARK: Details

    nonisolated static func importDetails(
        _ d: Database,
        details: [ActivityDetail],
        now: String,
        into report: inout Report
    ) throws {
        for detail in details.sorted(by: { $0.activityId < $1.activityId }) {
            // Same rule as the traces above, and the same reason.
            if DataCorrections.isIgnored(id: detail.activityId) {
                report.detailsIgnored += 1
                continue
            }
            report.detailsSeen += 1

            guard let activityID = try canonicalActivity(d, externalID: detail.activityId) else {
                report.detailsUnmatched += 1
                continue
            }

            let fetched = iso8601(detail.fetched)
            let existing = try Row.fetchOne(d, sql: """
                SELECT id, fetchedUTC FROM activity_detail
                WHERE activityID = ? AND sourceID = ?
                """, arguments: [activityID, sourceID])

            if let existing, existing["fetchedUTC"] as String? == fetched {
                report.detailsUnchanged += 1
                continue
            }

            do {
                try d.inSavepoint {
                    if let existing, let id = existing["id"] as String? {
                        try d.execute(sql: "DELETE FROM activity_detail WHERE id = ?",
                                      arguments: [id])
                    }
                    let id = UUID().uuidString
                    try d.execute(sql: """
                        INSERT INTO activity_detail
                          (id, activityID, sourceID, calories, descriptionText,
                           averageCadence, averageWatts, maxWatts, deviceName,
                           polyline, fetchedUTC)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [id, activityID, sourceID,
                                         detail.calories, detail.descriptionText,
                                         detail.averageCadence, detail.averageWatts,
                                         detail.maxWatts, detail.deviceName,
                                         detail.polyline, fetched])

                    for split in detail.splits {
                        try d.execute(sql: """
                            INSERT INTO activity_split
                              (id, activityDetailID, ordinal, distanceM,
                               movingSeconds, elapsedSeconds, elevationDiffM,
                               averageHeartrate)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, id, split.index,
                                             split.distanceM, split.movingTime,
                                             split.elapsedTime, split.elevationDiff,
                                             positiveOrNil(split.averageHR)])
                        report.splitsImported += 1
                    }
                    for lap in detail.laps {
                        try d.execute(sql: """
                            INSERT INTO activity_lap
                              (id, activityDetailID, ordinal, distanceM,
                               movingSeconds, averageHeartrate)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, id, lap.index,
                                             lap.distanceM, lap.movingTime,
                                             positiveOrNil(lap.averageHR)])
                        report.lapsImported += 1
                    }
                    for (i, effort) in detail.bestEfforts.enumerated() {
                        try d.execute(sql: """
                            INSERT INTO activity_best_effort
                              (id, activityDetailID, ordinal, name, seconds)
                            VALUES (?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, id, i,
                                             effort.name, effort.seconds])
                        report.effortsImported += 1
                    }
                    return .commit
                }
                if existing != nil { report.detailsUpdated += 1 }
                else { report.detailsImported += 1 }
            } catch {
                report.refusals.append(.init(externalID: "detail \(detail.activityId)",
                                             reason: String(describing: error)))
            }
        }
    }

    /// Zero bpm is a strap that was not worn — patch 244.
    ///
    /// `ActivityDetail` now converts this at the DTO boundary, so freshly
    /// fetched details arrive clean. This is here as well because `details.json`
    /// ALREADY HOLDS THE ZEROS: 378 details were cached before that fix
    /// existed, and they are not re-fetched. Without this the twelve that
    /// carry a zero-heart-rate lap would keep being refused whole on every
    /// import until something happened to re-download them.
    ///
    /// Two places, one rule, and the duplication is the point — the boundary
    /// stops new ones arriving, this stops old ones failing.
    nonisolated static func positiveOrNil(_ v: Double?) -> Double? {
        guard let v, v > 0 else { return nil }
        return v
    }

    // MARK: Shared

    /// Strava's id → the canonical activity, through the alias the activity
    /// loop wrote. The same resolution weather uses, and the reason both of
    /// these run after the activities rather than beside them.
    private nonisolated static func canonicalActivity(_ d: Database,
                                                      externalID: String) throws -> String? {
        try String.fetchOne(d, sql: """
            SELECT activityID FROM activity_alias
            WHERE sourceID = ? AND externalID = ?
            """, arguments: [sourceID, externalID])
    }
}
