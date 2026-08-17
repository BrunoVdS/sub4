//
//  ActivityRepository.swift
//  Sub4
//
//  The first thing that reads the database — D6a, patch 289, ADR-0003 §12.35.
//
//  READ-ONLY, AND NOTHING CALLS IT YET
//  -----------------------------------
//  Writes belong to D6b write-through; this exists because D6c shadow parity
//  needs a reader before it needs anything else, and because the question
//  "can the database give back what the store holds" is answerable NOW, in a
//  test, rather than as divergence on 669 rows six weeks from now.
//
//  Nothing in the app calls it. That is deliberate and temporary: a reader
//  wired into a screen before parity has run would be D7 arriving by accident.
//
//  IT DISTINGUISHES "NOTHING THERE" FROM "COULD NOT LOOK"
//  -----------------------------------------------------
//  A repository that returns `[]` when the read failed is the defect this
//  project has caught four times — `StoreLoad` for a file (§12.15), `Reading`
//  for a Health query (§12.28.3), `RouteCensus` for one measure inside it
//  (§12.32.4), `hasRoute: Bool?` for one field (§12.31.3). An empty training
//  history is indistinguishable from a database that would not open, and the
//  first one is a legitimate answer on a fresh install.
//
//  So `ActivityLoad` is what comes back, and `isTrustworthy` is the question
//  every caller has to ask first.
//
//  AND IT COUNTS WHAT IT COULD NOT RECONSTITUTE
//  -------------------------------------------
//  `skipped` is rows that are in the table and could not become an `Activity`.
//  Today that is exactly one case: `sportLabel` is nullable — a hand-entered
//  activity has no source label — and `Activity.sportType` is not. Mapping a
//  null to `""` would produce an `Activity` whose `discipline` is nil, which
//  reads downstream as an activity of no sport rather than as a row this
//  reader could not handle.
//
//  A count is not a fix. It is the difference between a reader that is honest
//  about its own coverage and one that quietly returns fewer rows than the
//  table holds — which is what shadow parity would then report as missing
//  data.
//
//  THE COLUMN NAMES ARE NOT THE FIELD NAMES
//  ----------------------------------------
//  Five differ, and one is a trap:
//
//    sportType   ← sportLabel        nullable; see `skipped`
//    isTrainer   ← isIndoor          renamed deliberately (Inputs migration)
//    deviceWatts ← hasPowerMeter     likewise
//    maxSpeed    ← maxSpeedMS
//    gearId      ← gear.externalID, falling back to
//                  activity_gear_reference.externalID  *** NOT `activity.gearID` ***
//
//  `activity.gearID` holds the CANONICAL gear id — §3.1's whole point — while
//  `Activity.gearId` holds Strava's, because that is what `AthleteStore.shoes`
//  is keyed by. Reading the column straight through would hand every one of
//  the 479 gear-bearing activities a gear id that matches nothing, and shadow
//  parity would report it as a data divergence rather than as a join this
//  reader got wrong.
//
//  AND THE COLUMN IS NOT ALWAYS SET. The importer resolves `a.gearId` against
//  the gear it knows; when it cannot, `activity.gearID` stays null and the
//  name Strava gave is recorded in `activity_gear_reference` instead — a
//  retired shoe, a bike added after the last athlete fetch. Reading only the
//  column would return `nil` for precisely those activities while the store
//  holds a value, which is a round-trip loss that looks like missing data.
//  Hence the second `LEFT JOIN` and the `COALESCE`.
//
//  Likewise `Activity.id` is Strava's id and `activity.id` is a minted UUID.
//  The store's id comes from `activity_source_record.externalID`.
//

import Foundation
import GRDB

/// What a read of the activity table produced.
///
/// NOT `Equatable` — 289a. `Activity`'s synthesised conformance is
/// MainActor-isolated in this target, so a `nonisolated` type carrying
/// `[Activity]` cannot use it: "this is an error in the Swift 6 language
/// mode". Nothing needs to compare two loads, so the conformance is dropped
/// rather than worked around. A warning with a version number on it is a
/// deadline, not an opinion.
nonisolated enum ActivityLoad: Sendable {
    /// The read ran. `skipped` counts rows the reader could not turn into an
    /// `Activity` — see the header. Zero on a healthy database.
    case loaded(activities: [Activity], skipped: Int)
    /// There is no open database. `Sub4Launch.database` is optional and is
    /// `nil` when the migration failed, which until D7 is a survivable state.
    case unavailable
    case failed(String)

    /// The question every caller asks first.
    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    // MARK: The two verdicts — patch 379, §12.92

    /// DID THE READ SUCCEED. True for a clean read of a database holding no
    /// activities.
    ///
    /// `isTrustworthy` above answers the same question and keeps its name
    /// because `ReadBacks` and the health screen ask it; this exists so the
    /// bootstrap can ask it in the same words as the other six families.
    /// `AuthoredLoad` carries the identical pair for the identical reason.
    var wasReadCleanly: Bool { isTrustworthy }

    /// IS THERE ANYTHING HERE TO HYDRATE A STORE FROM.
    ///
    /// **FALSE IS NOT A FAULT AND IS NOT RARE HERE.** A database with a
    /// bundled plan imported and no Strava sync yet reads cleanly and holds no
    /// activities — that is a fresh install between the first launch and the
    /// first sync, and it is why `.activities` is deliberately absent from
    /// `DatabaseBootstrap.canHydrate`. §12.123.
    var holdsContent: Bool {
        guard case .loaded(let a, _) = self else { return false }
        return !a.isEmpty
    }

    /// The rows, or `nil` — deliberately not `[]`, so a caller cannot reach
    /// for the happy path without deciding what an untrustworthy read means.
    var activities: [Activity]? {
        if case .loaded(let a, _) = self { return a }
        return nil
    }

    var skipped: Int {
        if case .loaded(_, let n) = self { return n }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(let a, let skipped):
            skipped == 0
                ? "\(a.count) activities."
                : "\(a.count) activities; \(skipped) rows could not be read."
        case .unavailable: "The database is not open."
        case .failed(let why): "The database could not be read — \(why)"
        }
    }
}

/// The store against the database, one activity at a time — patch 290.
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

        /// **THE PASTE HAS NEVER CARRIED THIS — patch 391, §12.135.**
        ///
        /// This report is 694 activities × nineteen named fields, and until now
        /// it existed only inside the sheet that produced it. The roll-up
        /// (patch 333) fixed the VERDICT — `Activities: 694 compared, no
        /// differences` survives and reaches the paste — and left the
        /// BREAKDOWN unreachable, so the only way to read which field differed
        /// was a screenshot. §12.57's evaporation, one level down from the
        /// defect 333 was written to close.
        ///
        /// UNCONDITIONAL, every line including the zeros — 266c's rule.
        ///
        /// **COUNTS AND FIELD NAMES ONLY. NO IDS**, following what
        /// `ActivityParity.diagnosticLines` does rather than what its comment
        /// says: the ids are in the report for the screen, and the screen is
        /// where they stay. §12.7.
        var diagnosticLines: [String] {
            var out = ["Activity read-back: \(compared) compared",
                       "  agreed: \(agreed)",
                       "  in the app and not in the database: \(missing.count)",
                       "  activities with a differing field: \(differences.count)"]
            // THE TALLY IS THE LINE WORTH READING FIRST and it is named rather
            // than counted — §12.39. "3 differ" sends somebody through nineteen
            // fields; "distance 3" is a diagnosis.
            out.append("  fields that differ: "
                       + (fieldTally.isEmpty ? "none"
                          : fieldTally.map { "\($0.field) \($0.count)" }
                              .joined(separator: ", ")))
            return out
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

nonisolated enum ActivityRepository {

    /// Every activity this account holds, newest first.
    ///
    /// ORDERED BY `startUTC`, which §4.1 makes authoritative for order — not
    /// by `startLocal`, which is authoritative for BELONGING. A run at 23:40
    /// and one at 00:20 are forty minutes and one training day apart, and only
    /// one of those two questions is "which came first".
    static func all(_ db: Sub4Database,
                    accountID: String = Sub4Import.accountID,
                    sourceID: String = Sub4Import.sourceID) -> ActivityLoad {
        do {
            return try db.queue.read { d -> ActivityLoad in
                let rows = try Row.fetchAll(d, sql: statement(),
                                            arguments: [sourceID, sourceID, accountID])
                var out: [Activity] = []
                var skipped = 0
                for row in rows {
                    if let a = activity(from: row) { out.append(a) } else { skipped += 1 }
                }
                return .loaded(activities: out, skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// One activity by the id the STORE uses — Strava's, not the canonical
    /// one. Callers hold `Activity.id`, and that is what this takes.
    static func activity(_ db: Sub4Database, storeID: String,
                         accountID: String = Sub4Import.accountID,
                         sourceID: String = Sub4Import.sourceID) -> ActivityLoad {
        do {
            return try db.queue.read { d -> ActivityLoad in
                let row = try Row.fetchOne(d,
                                           sql: statement(and: "r.externalID = ?"),
                                           arguments: [sourceID, sourceID,
                                                       accountID, storeID])
                guard let row else { return .loaded(activities: [], skipped: 0) }
                guard let a = activity(from: row) else {
                    return .loaded(activities: [], skipped: 1)
                }
                return .loaded(activities: [a], skipped: 0)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: The query

    /// The statement, with an optional extra `WHERE` term.
    ///
    /// BUILT RATHER THAN CONCATENATED, and that is a correction: the first
    /// version appended `AND r.externalID = ?` to a string ending in
    /// `ORDER BY`, which is not SQL. A query assembled by adding text to the
    /// end only works while nothing is at the end.
    private static func statement(and extra: String? = nil) -> String {
        body
        + (extra.map { "\n  AND \($0)" } ?? "")
        + "\nORDER BY a.startUTC DESC"
    }

    /// `JOIN` on the source record, not on `activity.id` — the store's id is
    /// Strava's and lives there. `LEFT JOIN` on gear, because most activities
    /// have none and an inner join would silently drop them.
    private static let body = """
        SELECT r.externalID          AS storeID,
               a.name                AS name,
               a.sportLabel          AS sportLabel,
               a.startLocal          AS startLocal,
               a.startUTC            AS startUTC,
               a.startOffsetSeconds  AS startOffsetSeconds,
               a.timeZoneIdentifier  AS timeZoneIdentifier,
               a.distanceM           AS distanceM,
               a.movingSeconds       AS movingSeconds,
               a.elapsedSeconds      AS elapsedSeconds,
               a.elevationGainM      AS elevationGainM,
               a.averageHeartrate    AS averageHeartrate,
               a.maxHeartrate        AS maxHeartrate,
               a.startLatitude       AS startLatitude,
               a.startLongitude      AS startLongitude,
               a.averageWatts        AS averageWatts,
               a.hasPowerMeter       AS hasPowerMeter,
               a.isIndoor            AS isIndoor,
               a.maxSpeedMS          AS maxSpeedMS,
               COALESCE(g.externalID, ref.externalID) AS gearExternalID
        FROM activity a
        JOIN activity_source_record r
          ON r.activityID = a.id AND r.accountID = a.accountID AND r.sourceID = ?
        LEFT JOIN gear g ON g.id = a.gearID
        LEFT JOIN activity_gear_reference ref
               ON ref.activityID = a.id AND ref.sourceID = ?
        WHERE a.accountID = ?
        """

    /// `nil` when the row cannot become an `Activity`. See `skipped`.
    private static func activity(from row: Row) -> Activity? {
        guard let sportType: String = row["sportLabel"] else { return nil }
        return Activity(
            id: row["storeID"],
            name: row["name"],
            sportType: sportType,
            startLocal: row["startLocal"],
            distance: row["distanceM"],
            movingTime: row["movingSeconds"],
            elapsedTime: row["elapsedSeconds"],
            elevationGain: row["elevationGainM"],
            averageHeartrate: row["averageHeartrate"],
            isTrainer: row["isIndoor"],
            maxHeartrate: row["maxHeartrate"],
            gearId: row["gearExternalID"],
            maxSpeed: row["maxSpeedMS"],
            deviceWatts: row["hasPowerMeter"],
            averageWatts: row["averageWatts"],
            startUTC: row["startUTC"],
            startLat: row["startLatitude"],
            startLon: row["startLongitude"],
            timeZoneIdentifier: row["timeZoneIdentifier"],
            startOffsetSeconds: row["startOffsetSeconds"])
    }
}
