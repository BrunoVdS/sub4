//
//  Sub4Import+Athlete.swift
//  Sub4
//
//  The profile, the zones and the resting series — patch 228, ADR-0003 §12.10.
//
//  WHAT THIS IS AND WHY IT IS SMALL BUT NOT MINOR
//  ----------------------------------------------
//  Three scalars, five zone boundaries and a month-keyed series. Perhaps two
//  hundred bytes, against 661 activities and 576 weather readings. It is also
//  the denominator of every training-load figure the app has ever produced:
//  TRIMP divides by the resting rate for the month and scales by the reserve
//  between rest and maximum, then raises the result to `sexCoefficient`. Lose
//  this and 661 activities are still there and every CTL, ATL and TSB computed
//  from them is wrong — with no error, no gap and no way to see it on a chart.
//
//  So it is imported like the authored stores rather than like the cheap ones.
//
//  WHY EVERY FUNCTION HERE SAYS `nonisolated`
//  ------------------------------------------
//  `Sub4Import` is declared `nonisolated enum`, and that DOES NOT REACH ITS
//  EXTENSIONS. The keyword applies to members written in the enum's own body;
//  everything in an `extension Sub4Import { }` takes the module's default
//  isolation instead, which is MainActor. `run` is nonisolated and called these
//  from a synchronous context, which is a warning today and an error under a
//  stricter mode.
//
//  Fourth time this project has been caught by the same rule — patches 207,
//  219, and now here. `Sub4Import+Weather` and `Sub4Import+Authored` were
//  marked in the same patch: they had the identical defect and were not warning
//  yet, which is worse, not better.
//
//  THREE THINGS THAT LIVE IN TWO STORES
//  ------------------------------------
//  `athlete_profile` is one row assembled from BOTH stores, which is not
//  visible from either side alone:
//
//      AthleteConstants   hrMaxOverride, hrMaxObserved, hrMaxObservedOn,
//                         restOverride, sexCoefficient
//      AthleteStore       ftpWatts, and the zones
//
//  `AthleteConstants` is computed on this phone from recorded activities.
//  `AthleteStore` is fetched from Strava. They have different lifetimes and
//  different provenance and they were never going to be one file, but they are
//  one row — the profile is the athlete, not the source.
//
//  THE PROVENANCE COLUMN THAT HAS NO FIELD
//  ---------------------------------------
//  `athlete_profile.hrMaxObservedActivityID` references `activity`. The store
//  holds `hrMaxObservedName` — a NAME, a String, because that is what the
//  Settings row prints. There is no id anywhere in `AthleteConstants`;
//  `refreshFromSources` carries `(bpm, day, name)` and drops the id it had.
//
//  Rather than leave the column permanently NULL, the activity is resolved
//  arithmetically: the one activity on that dayKey whose recorded maximum heart
//  rate IS the observed maximum. That is not name matching — it is an exact
//  integer and an exact date, with the name as a third filter. If exactly one
//  activity satisfies all three the column is filled; if none or several do it
//  stays NULL and `profileProvenanceUnresolved` counts it.
//
//  Refusing to guess is the point. A provenance column filled with a plausible
//  wrong activity is worse than an empty one, because the empty one is visibly
//  empty.
//
//  ZONES ARE REPLACED WHOLE
//  ------------------------
//  Five rows, deleted and rewritten every run. A zone set is one object: if
//  Strava moves the boundaries from five zones to three, upserting by ordinal
//  would leave Z4 and Z5 behind as rows nobody wrote and nothing deletes, and
//  `zone(forHR:)` would answer from a set that never existed. Delete-then-write
//  costs nothing at this size and cannot leave a ghost.
//
//  THE RESTING SERIES IS NOT REPLACED WHOLE
//  ----------------------------------------
//  The opposite call, deliberately. `restByMonth` is recomputed from a rolling
//  window of Health data, so a month that has aged out of that window is absent
//  from the store but is still the only figure the app has ever had for it —
//  and every activity in that month is scored against it. Deleting the series
//  would silently rescore the whole history. Upsert by month, never delete.
//

import Foundation
import GRDB

extension Sub4Import {

    // MARK: The profile

    nonisolated static func importAthleteProfile(
        _ d: Database,
        constants: AthleteConstants,
        ftpWatts: Int?,
        activities: [Activity],
        now: String,
        into report: inout Report
    ) throws {
        report.profileSeen += 1

        let provenance = try resolveObservedActivity(d, constants: constants,
                                                     activities: activities)
        if constants.hrMaxObserved != nil && provenance == nil {
            report.profileProvenanceUnresolved += 1
        }

        let existing = try String.fetchOne(d, sql: """
            SELECT id FROM athlete_profile WHERE accountID = ?
            """, arguments: [accountID])

        do {
            try d.inSavepoint {
                if let id = existing {
                    try d.execute(sql: """
                        UPDATE athlete_profile
                        SET hrMaxOverride = ?, hrMaxObserved = ?,
                            hrMaxObservedOnDayKey = ?, hrMaxObservedActivityID = ?,
                            restOverride = ?, sexCoefficient = ?, ftpWatts = ?,
                            updatedUTC = ?
                        WHERE id = ?
                        """, arguments: [constants.hrMaxOverride,
                                         constants.hrMaxObserved,
                                         constants.hrMaxObservedOn,
                                         provenance,
                                         constants.restOverride,
                                         constants.sexCoefficient,
                                         ftpWatts, now, id])
                } else {
                    try d.execute(sql: """
                        INSERT INTO athlete_profile
                          (id, accountID, hrMaxOverride, hrMaxObserved,
                           hrMaxObservedOnDayKey, hrMaxObservedActivityID,
                           restOverride, sexCoefficient, ftpWatts, updatedUTC)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [UUID().uuidString, accountID,
                                         constants.hrMaxOverride,
                                         constants.hrMaxObserved,
                                         constants.hrMaxObservedOn,
                                         provenance,
                                         constants.restOverride,
                                         constants.sexCoefficient,
                                         ftpWatts, now])
                }
                return .commit
            }
            if existing != nil { report.profileUpdated += 1 }
            else { report.profileImported += 1 }
        } catch {
            report.refusals.append(.init(externalID: "athlete profile",
                                         reason: String(describing: error)))
        }
    }

    /// The canonical activity that produced the observed maximum, or nil.
    ///
    /// Three filters, all exact: the day, the recorded maximum as an integer,
    /// and the name. `hrMaxObserved` was produced by rounding `maxHeartrate`,
    /// so the same rounding is applied here rather than comparing a Double to
    /// an Int and hoping.
    nonisolated private static func resolveObservedActivity(
        _ d: Database,
        constants: AthleteConstants,
        activities: [Activity]
    ) throws -> String? {
        guard let bpm = constants.hrMaxObserved,
              let day = constants.hrMaxObservedOn else { return nil }

        let matches = activities.filter { a in
            guard a.dayKey == day, let m = a.maxHeartrate, m.isFinite,
                  Int(m.rounded()) == bpm else { return false }
            // The name only narrows. An activity that has been renamed on
            // Strava since the maximum was recorded still matches on the two
            // facts that cannot be edited.
            guard let named = constants.hrMaxObservedName else { return true }
            return a.name == named
        }
        guard matches.count == 1, let match = matches.first else { return nil }

        // The store's id is Strava's. The column references the canonical
        // activity, so it goes through the alias like weather does.
        return try String.fetchOne(d, sql: """
            SELECT activityID FROM activity_alias
            WHERE sourceID = ? AND externalID = ?
            """, arguments: [sourceID, match.id])
    }

    // MARK: Zones

    nonisolated static func importHRZones(
        _ d: Database,
        zones: [AthleteStore.HRZone],
        now: String,
        into report: inout Report
    ) throws {
        report.zonesSeen += zones.count
        guard !zones.isEmpty else { return }

        do {
            try d.inSavepoint {
                try d.execute(sql: "DELETE FROM hr_zone WHERE accountID = ?",
                              arguments: [accountID])
                for z in zones {
                    try d.execute(sql: """
                        INSERT INTO hr_zone (id, accountID, ordinal, minBpm, maxBpm)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [UUID().uuidString, accountID,
                                         z.index, z.min, z.max])
                }
                return .commit
            }
            report.zonesImported += zones.count
        } catch {
            // The whole set or none of it. Half a zone set is not a smaller
            // problem than no zone set — it is a zone set with a hole, and
            // `zone(forHR:)` would answer confidently from it.
            report.refusals.append(.init(externalID: "hr zones",
                                         reason: String(describing: error)))
        }
    }

    // MARK: The resting series

    nonisolated static func importRestingMonths(
        _ d: Database,
        byMonth: [String: Int],
        now: String,
        into report: inout Report
    ) throws {
        // Sorted so a refusal list reads chronologically rather than in
        // whatever order the dictionary happened to hash.
        for month in byMonth.keys.sorted() {
            guard let bpm = byMonth[month] else { continue }
            report.restingSeen += 1

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM resting_month WHERE accountID = ? AND month = ?
                """, arguments: [accountID, month])

            do {
                try d.inSavepoint {
                    if let id = existing {
                        try d.execute(sql: """
                            UPDATE resting_month SET bpm = ?, computedUTC = ?
                            WHERE id = ?
                            """, arguments: [bpm, now, id])
                    } else {
                        // `computedUTC` is the import time, not the time the
                        // figure was computed — the store keeps no such stamp.
                        // Recorded in §12.10 rather than dressed up: this
                        // column currently answers "when did this row arrive",
                        // and will answer its real question the day the store
                        // starts keeping one.
                        try d.execute(sql: """
                            INSERT INTO resting_month
                              (id, accountID, month, bpm, computedUTC)
                            VALUES (?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, accountID,
                                             month, bpm, now])
                    }
                    return .commit
                }
                if existing != nil { report.restingUpdated += 1 }
                else { report.restingImported += 1 }
            } catch {
                report.refusals.append(.init(externalID: "resting \(month)",
                                             reason: String(describing: error)))
            }
        }
    }
}
