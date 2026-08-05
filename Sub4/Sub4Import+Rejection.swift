//
//  Sub4Import+Rejection.swift
//  Sub4
//
//  What a rule threw away — D5 slice 3, patch 278, ADR-0003 §12.24.
//
//  THE RECEIPT IS THE POINT, AND IT ALREADY EXISTED AS PROSE
//  ---------------------------------------------------------
//  `ActivityStore.rejected`'s declaration says it plainly: "A rejected activity
//  is not written to activities.json and the cursor moves past it, so after one
//  launch there is nothing left in the app that remembers it existed. A rule
//  that silently deletes data is worse than the data it deleted — this is the
//  receipt, and Settings prints it."
//
//  It was stored as a rendered line:
//
//      "2025-04-12 Evening Ride — 41.3 km in 22:14 = 111 km/h avg, max 19"
//
//  Everything `rejection`'s columns want is in there and none of it is a field.
//  Parsing it back would be inventing structure out of prose, so — exactly as
//  `Matcher` in §12.19 — the STORE learns the shape first and the import is the
//  easy half.
//
//  ONE RULE, AND IT IS NAMED RATHER THAN DESCRIBED
//  -----------------------------------------------
//  `Activity.selfContradictoryDistance`: an average speed more than 1.5× the
//  recorded maximum. §12.24 records why 1.5 is a margin and not a number chosen
//  to fit — the three rides it caught are 5.8×, 9.5× and 16.4×, and the closest
//  survivor is 1.08×.
//
//  `rule` is a column with no CHECK, so this is a Swift convention rather than
//  a contract. It is an enum anyway: a second rule spelled differently in the
//  store and the importer would produce two vocabularies nobody chose.
//
//  WHAT A MIGRATED RECEIPT CANNOT SAY
//  ----------------------------------
//  The old shape stored no timestamp and no fields, so a receipt made from one
//  carries `dateIsKnown == false` and NULL for name, day, distance and
//  duration. Those four columns are nullable; `rule` and `noticedUTC` are not,
//  and both can be supplied honestly — the rule because there has only ever
//  been one, the date as the migration instant, disclosed.
//
//  §12.19.3 refused to invent a plausible date and §12.23.4 accepted one. This
//  is the first case, not the second: a rejection is filed under "authored" in
//  §8's grouping and outlives the activity it describes, so it is history
//  rather than bookkeeping. The label is kept verbatim on every receipt,
//  because for a migrated one it is the only thing that was ever true.
//
//  NOTHING PRUNES THIS TABLE, AND THAT IS CHECKED RATHER THAN ASSUMED
//  ------------------------------------------------------------------
//  `resetCache()` clears activities, the cursor and the last sync — and NOT the
//  receipts. `dropInMemory()` clears them without writing, and only
//  `DataLifecycleCoordinator.deleteEverything` removes the key, which removes
//  the database in the same breath. So a receipt never disappears from the
//  store while the row survives, and §12.21's reconciliation problem does not
//  arise here.
//

import Foundation
import GRDB

/// Why a recording was refused. One case, and the enum exists so a second one
/// cannot be spelled two ways.
nonisolated enum RejectionRule: String, CaseIterable, Codable, Sendable {
    /// Average speed more than 1.5× the recorded maximum.
    case selfContradictoryDistance
}

nonisolated struct RejectionReceipt: Codable, Hashable, Sendable, Identifiable {

    var activityId: String
    var rule: RejectionRule
    var noticed: Date

    /// False on a receipt made from the retired `[id: line]` shape, which
    /// stored no time. See the header.
    var dateIsKnown: Bool

    // Nullable in the schema, and nil on a migrated receipt.
    var name: String?
    var dayKey: String?
    var distanceM: Double?
    var elapsedSeconds: Int?

    /// The line Settings has printed since the rule was written. Kept verbatim
    /// rather than recomputed, because on a migrated receipt it is the only
    /// thing that was ever recorded.
    var label: String

    var id: String { activityId }

    /// A receipt for a recording being refused now — everything known.
    init(_ a: Activity, rule: RejectionRule, now: Date = Date()) {
        activityId = a.id
        self.rule = rule
        noticed = now
        dateIsKnown = true
        name = a.name
        dayKey = a.dayKey
        distanceM = a.distance
        elapsedSeconds = a.elapsedTime
        label = Self.line(a)
    }

    /// A receipt rebuilt from the retired shape — the line, and nothing else.
    init(migrating activityId: String, label: String, now: Date) {
        self.activityId = activityId
        // There has only ever been one rule, so naming it is a fact rather
        // than a guess. A second rule would make this migration wrong, and a
        // second rule cannot be added to a build that has already run this.
        rule = .selfContradictoryDistance
        noticed = now
        dateIsKnown = false
        name = nil
        dayKey = nil
        distanceM = nil
        elapsedSeconds = nil
        self.label = label
    }

    /// Sorted by id, so the list does not reshuffle between launches.
    static func migrate(_ legacy: [String: String],
                        now: Date = Date()) -> [RejectionReceipt] {
        legacy.keys.sorted().compactMap { id in
            legacy[id].map { RejectionReceipt(migrating: id, label: $0, now: now) }
        }
    }

    /// Everything needed to look the recording up in Strava and see for
    /// yourself: when, what it was called, and the two figures that disagree.
    ///
    /// MOVED HERE FROM `ActivityStore` IN 278, unchanged. The receipt owns its
    /// own rendering now that the receipt is a thing.
    static func line(_ a: Activity) -> String {
        let kmh = (a.distance / Double(max(a.movingTime, 1))) * 3.6
        let maxKmh = (a.maxSpeed ?? 0) * 3.6
        let mins = a.movingTime / 60, secs = a.movingTime % 60
        // `a.distance / 1000` AND NOT `a.km`. `Activity` is a plain struct, so
        // the type is main-actor by default: its STORED properties are
        // nonisolated and its COMPUTED ones are not, unless they say so —
        // `dayKey` two lines above `km` says `nonisolated` and `km` does not.
        // This function was main-actor where it used to live and is not here.
        return String(format: "%@ %@ — %.1f km in %d:%02d = %.0f km/h avg, max %.0f",
                      String(a.startLocal.prefix(10)), a.name,
                      a.distance / 1000, mins, secs, kmh, maxKmh)
    }
}

extension Sub4Import {

    /// Copies the receipts. Never deletes — see the header.
    nonisolated static func importRejections(
        _ d: Database,
        receipts: [RejectionReceipt],
        now: String,
        into report: inout Report
    ) throws {
        for receipt in receipts {
            report.rejectionsSeen += 1

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM rejection
                WHERE accountID = ? AND sourceID = ? AND externalID = ?
                """, arguments: [accountID, sourceID, receipt.activityId])

            do {
                try d.inSavepoint {
                    if let id = existing {
                        try d.execute(sql: """
                            UPDATE rejection
                            SET rule = ?, noticedUTC = ?, name = ?, dayKey = ?,
                                distanceM = ?, elapsedSeconds = ?
                            WHERE id = ?
                            """, arguments: [receipt.rule.rawValue,
                                             iso8601(receipt.noticed),
                                             receipt.name, receipt.dayKey,
                                             receipt.distanceM,
                                             receipt.elapsedSeconds, id])
                    } else {
                        try d.execute(sql: """
                            INSERT INTO rejection
                              (id, accountID, sourceID, externalID, rule,
                               noticedUTC, name, dayKey, distanceM, elapsedSeconds)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, accountID,
                                             sourceID, receipt.activityId,
                                             receipt.rule.rawValue,
                                             iso8601(receipt.noticed),
                                             receipt.name, receipt.dayKey,
                                             receipt.distanceM,
                                             receipt.elapsedSeconds])
                    }
                    return .commit
                }
                if existing != nil { report.rejectionsUpdated += 1 }
                else { report.rejectionsImported += 1 }
            } catch {
                // THE STRAVA ID AND NOT THE NAME. This row is the one place in
                // the database that describes a recording the app refused, and
                // a refusal message is read on a screen the athlete may hand to
                // somebody else.
                report.refusals.append(
                    .init(externalID: "rejection \(receipt.activityId)",
                          reason: String(describing: error)))
            }
        }
    }
}
