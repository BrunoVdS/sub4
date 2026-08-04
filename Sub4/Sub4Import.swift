//
//  Sub4Import.swift
//  Sub4
//
//  The cutover, first half — patch 218, plan step 3.3.2, ADR-0003 §9.7 and §12.
//
//  WHERE THE ROWS COME FROM, AND WHY NOT THE FILE
//  ----------------------------------------------
//  `activities.json` and `ActivityStore.activities` are NOT the same list. The
//  store applies a gate on load: `DataCorrections.ignoredActivities` (a curated
//  exclusion — one 2025 swim recording 400 m across 45 minutes) and the
//  self-contradiction rule. Rows the file holds and the app has decided are not
//  real never reach the screen.
//
//  A cutover's target is what the app SHOWS, not what the file happens to hold.
//  Importing straight from the file would resurrect activities Bruno has
//  already excluded, and re-implementing the gate here would give two copies of
//  a rule that has changed once already. So the import reads the stores.
//
//  The cost is stated plainly: this runs after the stores have loaded, so it
//  cannot be the thing that runs at launch before them. That is correct for
//  3.3.2, where the import is a button. When 3.3.3 makes the database
//  authoritative, the direction reverses and the stores read from here.
//
//  IDEMPOTENT BY LOOKUP, NOT BY LUCK — §12.1
//  -----------------------------------------
//  Every activity is looked up by `(sourceID, externalID)` in
//  `activity_source_record` before anything is written. Found means already
//  imported. Not found means mint a fresh opaque id.
//
//  Minting a `UUID()` unconditionally would look idempotent and duplicate the
//  whole history on every press, and NOTHING IN THE SCHEMA WOULD STOP IT —
//  nothing there knows two rows describe one session. The uniqueness that saves
//  us is `(accountID, sourceID, externalID)` on `activity_source_record`, and
//  it is the reason that constraint exists.
//
//  A REFUSED ROW DOES NOT ABORT THE IMPORT — §12.2
//  -----------------------------------------------
//  The CHECK constraints will refuse at least one row: the August 2025 artifact
//  at 199 km / 694,865 s. Each activity is therefore written inside its own
//  SAVEPOINT. A constraint violation rolls back that one activity and the loop
//  continues; the refusal is recorded with the reason SQLite gave.
//
//  Without the savepoint the first bad row would roll back the entire write and
//  the database would be left empty, with the screen reporting a failure whose
//  cause is one row out of six hundred.
//

import Foundation
import GRDB

nonisolated enum Sub4Import {

    // MARK: What comes out

    struct Refusal: Sendable, Equatable, Identifiable {
        /// The source's id, because that is the only handle the athlete has on
        /// a row that did not make it — it is what Strava's URL ends with.
        let externalID: String
        let reason: String
        var id: String { externalID }
    }

    struct Report: Sendable, Equatable {
        var activitiesSeen = 0
        var activitiesInserted = 0
        /// Rows already present, refreshed from the source rather than skipped.
        /// The name changed in patch 220 with the behaviour: "already present"
        /// described something that did nothing.
        var activitiesUpdated = 0
        var gearInserted = 0
        var gearAlreadyPresent = 0
        /// Activities naming gear the athlete profile does not hold. Counted
        /// rather than refused: a missing shoe is not a reason to lose a run.
        var gearUnresolved = 0

        // Patch 225 — the authored stores. Counted separately because losing a
        // note and losing an activity are not the same loss: one can be
        // re-fetched from Strava and the other cannot.
        var notesSeen = 0
        var notesImported = 0
        var notesUpdated = 0
        var reviewsSeen = 0
        var reviewsImported = 0
        var reviewsUpdated = 0

        /// WHICH ids did not resolve, and how many activities named each —
        /// patch 221.
        ///
        /// The first real run left 404 activities unresolved and the report
        /// could only say "404". Whether that is one untracked bike or forty
        /// missing shoes are completely different problems, and a number cannot
        /// tell them apart. Naming them is cheap and stops the next answer
        /// being a guess.
        var unresolvedGear: [String: Int] = [:]
        var refusals: [Refusal] = []
        var seconds: Double = 0

        var isClean: Bool { refusals.isEmpty }

        /// Most-named first, so the answer is in the first line rather than
        /// somewhere in a list of forty.
        var unresolvedGearRanked: [(external: String, count: Int)] {
            unresolvedGear
                .map { (external: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.external) > ($1.count, $0.external) }
        }

        var summary: String {
            var s = "\(activitiesInserted) imported"
            if activitiesUpdated > 0 { s += ", \(activitiesUpdated) refreshed" }
            if !refusals.isEmpty { s += ", \(refusals.count) refused" }
            return s
        }

        var diagnosticLines: [String] {
            var l = [String(format: "Import: %.2f s", seconds),
                     "Activities seen: \(activitiesSeen)",
                     "  inserted: \(activitiesInserted), refreshed: \(activitiesUpdated)",
                     "Notes seen: \(notesSeen) — imported \(notesImported), refreshed \(notesUpdated)",
                     "Reviews seen: \(reviewsSeen) — imported \(reviewsImported), refreshed \(reviewsUpdated)",
                     "Gear inserted: \(gearInserted), already present: \(gearAlreadyPresent)",
                     "Activities naming unknown gear: \(gearUnresolved)"]
            for (external, count) in unresolvedGearRanked {
                l.append("  \(external): \(count) activities")
            }
            l.append("Refused: \(refusals.count)")
            for r in refusals { l.append("  \(r.externalID): \(r.reason)") }
            return l
        }
    }

    // MARK: Fixed identities

    /// One account, minted here. §9.6: the column exists for Phase 4A, not
    /// because this app has users. A literal rather than a UUID so that a
    /// second import run finds the same account instead of making another.
    static let accountID = "local"
    static let accountLabel = "This phone"

    /// Everything imported in 3.3.2 arrived from Strava. When Apple Health
    /// becomes a source at 4A it gets its own value, and the same activity can
    /// then carry two source records.
    static let sourceID = "strava"

    // MARK: Running

    static func run(into db: Sub4Database,
                    activities: [Activity],
                    shoes: [AthleteStore.Shoe],
                    notes: [NotesStore.Note] = [],
                    proposals: [ProposalStore.Record] = []) throws -> Report {

        let clock = ContinuousClock()
        var report = Report()
        let now = iso8601(Date())

        let elapsed = try clock.measure {
            try db.queue.write { d in
                try ensureAccount(d, now: now)

                // GEAR FIRST — §12.3. `activity.gearID` references the
                // canonical gear id, so an activity written before its shoes
                // has nowhere to point and loses the attribution silently.
                let gearByExternal = try importGear(d, shoes: shoes, now: now, into: &report)

                for a in activities {
                    report.activitiesSeen += 1
                    try importOne(d, a, gearByExternal: gearByExternal,
                                  now: now, into: &report)
                }

                // AFTER the activities, and it does not currently matter — a
                // note references its plan session, not an activity, and
                // `activityID` is left NULL for the matcher to fill. Ordered
                // this way so that when the matcher does run, the rows it needs
                // are already there.
                try importNotes(d, notes: notes, now: now, into: &report)
                try importProposals(d, records: proposals, now: now, into: &report)
            }
        }
        report.seconds = seconds(elapsed)
        return report
    }

    // MARK: The account

    private static func ensureAccount(_ d: Database, now: String) throws {
        let exists = try Bool.fetchOne(
            d, sql: "SELECT 1 FROM account WHERE id = ?", arguments: [accountID]) ?? false
        guard !exists else { return }
        try d.execute(sql: """
            INSERT INTO account (id, label, createdUTC) VALUES (?, ?, ?)
            """, arguments: [accountID, accountLabel, now])
    }

    // MARK: Gear

    /// Returns Strava's gear id → canonical gear id, for the activity loop.
    private static func importGear(_ d: Database,
                                   shoes: [AthleteStore.Shoe],
                                   now: String,
                                   into report: inout Report) throws -> [String: String] {
        var map: [String: String] = [:]
        for shoe in shoes {
            if let existing = try String.fetchOne(d, sql: """
                SELECT id FROM gear
                WHERE accountID = ? AND sourceID = ? AND externalID = ?
                """, arguments: [accountID, sourceID, shoe.id]) {
                map[shoe.id] = existing
                report.gearAlreadyPresent += 1
                continue
            }
            let id = UUID().uuidString
            try d.execute(sql: """
                INSERT INTO gear (id, accountID, sourceID, externalID, name, distanceM)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id, accountID, sourceID, shoe.id, shoe.name, shoe.distanceM])
            map[shoe.id] = id
            report.gearInserted += 1
        }
        return map
    }

    // MARK: One activity

    private static func importOne(_ d: Database,
                                  _ a: Activity,
                                  gearByExternal: [String: String],
                                  now: String,
                                  into report: inout Report) throws {

        // §12.1, AND THE CORRECTION MADE IN PATCH 220.
        //
        // Found means this activity already has a canonical id minted by an
        // earlier run. The first version RETURNED here, and that was wrong: an
        // import tool has to CONVERGE, not merely insert once.
        //
        // The case that proved it took four minutes to find on real data. The
        // first run happened before `AthleteStore` had refreshed, so its shoe
        // list was empty and 474 activities imported with a null `gearID`.
        // Skipping on the second run would have left every one of them
        // unattributed for good, and the report would have said "already there"
        // with quiet confidence.
        //
        // So a known activity is UPDATED from the source. Safe precisely
        // because nothing reads the database yet — and after 3.3.3 it stays
        // safe, because the JSON stores remain the upstream until they are
        // retired.
        let existing = try String.fetchOne(d, sql: """
            SELECT activityID FROM activity_source_record
            WHERE accountID = ? AND sourceID = ? AND externalID = ?
            """, arguments: [accountID, sourceID, a.id])

        // `startUTC` is NOT NULL in the schema and optional in the JSON —
        // early rows predate the app recording it. Refused rather than
        // invented: a made-up instant would order wrongly against every other
        // activity and nobody would ever know why.
        guard let startUTC = a.startUTC, !startUTC.isEmpty else {
            report.refusals.append(.init(externalID: a.id,
                                         reason: "no start instant (startUTC is missing)"))
            return
        }

        let canonical = existing ?? UUID().uuidString
        let gearID = a.gearId.flatMap { gearByExternal[$0] }

        do {
            // THE SAVEPOINT — §12.2. A CHECK violation rolls back this
            // activity alone. Without it the first refused row would take the
            // whole import with it.
            try d.inSavepoint {
                if existing != nil {
                    // Everything the source owns, refreshed. `id`, `accountID`
                    // and `createdUTC` are NOT touched: the canonical id is
                    // ours and outlives the source, and when a row first
                    // arrived is not something a later run gets to rewrite.
                    try d.execute(sql: """
                        UPDATE activity SET
                          startUTC = ?, startLocal = ?, dayKey = ?,
                          startOffsetSeconds = ?, timeZoneIdentifier = ?,
                          discipline = ?, sportLabel = ?, name = ?,
                          distanceM = ?, movingSeconds = ?, elapsedSeconds = ?,
                          elevationGainM = ?, averageHeartrate = ?, maxHeartrate = ?,
                          startLatitude = ?, startLongitude = ?,
                          gearID = ?, averageWatts = ?, hasPowerMeter = ?,
                          isIndoor = ?, maxSpeedMS = ?, updatedUTC = ?
                        WHERE id = ?
                        """, arguments: [
                            startUTC, a.startLocal, a.dayKey,
                            a.startOffsetSeconds, a.timeZoneIdentifier,
                            (a.discipline ?? .other).rawValue, a.sportType, a.name,
                            a.distance, a.movingTime, a.elapsedTime,
                            a.elevationGain, a.averageHeartrate, a.maxHeartrate,
                            a.startLat, a.startLon,
                            gearID, a.averageWatts, a.deviceWatts, a.isTrainer,
                            a.maxSpeed, now, canonical
                        ])
                    try d.execute(sql: """
                        UPDATE activity_source_record SET lastSeenUTC = ?
                        WHERE accountID = ? AND sourceID = ? AND externalID = ?
                        """, arguments: [now, accountID, sourceID, a.id])
                    try recordGearReference(d, activityID: canonical,
                                            named: a.gearId, now: now)
                    return .commit
                }

                try d.execute(sql: """
                    INSERT INTO activity
                      (id, accountID, startUTC, startLocal, dayKey,
                       startOffsetSeconds, timeZoneIdentifier,
                       discipline, sportLabel, name,
                       distanceM, movingSeconds, elapsedSeconds,
                       elevationGainM, averageHeartrate, maxHeartrate,
                       startLatitude, startLongitude,
                       gearID, averageWatts, hasPowerMeter, isIndoor, maxSpeedMS,
                       createdUTC, updatedUTC)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        canonical, accountID, startUTC, a.startLocal, a.dayKey,
                        a.startOffsetSeconds, a.timeZoneIdentifier,
                        (a.discipline ?? .other).rawValue, a.sportType, a.name,
                        a.distance, a.movingTime, a.elapsedTime,
                        a.elevationGain, a.averageHeartrate, a.maxHeartrate,
                        a.startLat, a.startLon,
                        gearID, a.averageWatts, a.deviceWatts, a.isTrainer,
                        a.maxSpeed, now, now
                    ])

                try d.execute(sql: """
                    INSERT INTO activity_source_record
                      (id, activityID, accountID, sourceID, externalID,
                       firstSeenUTC, lastSeenUTC)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, canonical, accountID,
                                     sourceID, a.id, now, now])

                // The alias is what makes a note written against a Strava id
                // still resolve after Strava is gone — §3.1. Written at import
                // rather than at retirement, because at retirement the mapping
                // no longer exists to be written.
                try d.execute(sql: """
                    INSERT INTO activity_alias
                      (id, activityID, sourceID, externalID, notedUTC)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, canonical,
                                     sourceID, a.id, now])

                try recordGearReference(d, activityID: canonical,
                                        named: a.gearId, now: now)
                return .commit
            }
            if existing != nil { report.activitiesUpdated += 1 }
            else { report.activitiesInserted += 1 }

            // COUNTED HERE, NOT BEFORE THE WRITE — patch 224.
            //
            // The first version incremented these next to the lookup, which
            // counted gear for an activity the CHECK constraints then refused:
            // the phone reported "404 naming unknown gear" against 473 rows in
            // `activity_gear_reference`, and reconciling that took longer than
            // the bug was worth. These numbers are the cutover's audit trail —
            // an off-by-one in them is a wasted hour six weeks from now.
            if let named = a.gearId, gearID == nil {
                report.gearUnresolved += 1
                report.unresolvedGear[named, default: 0] += 1
            }
        } catch {
            // The reason SQLite gave, not a paraphrase. "CHECK constraint
            // failed: distanceM" names the column; "could not import" does not.
            report.refusals.append(.init(externalID: a.id,
                                         reason: String(describing: error)))
        }
    }

    /// What the source called the gear, kept whether or not it resolves —
    /// §3.1 and §12.6. Deleted and rewritten rather than upserted: an activity
    /// whose gear was cleared at the source must lose the reference too, and a
    /// row left behind would outlive the fact it recorded.
    private static func recordGearReference(_ d: Database,
                                            activityID: String,
                                            named externalID: String?,
                                            now: String) throws {
        try d.execute(sql: """
            DELETE FROM activity_gear_reference
            WHERE activityID = ? AND sourceID = ?
            """, arguments: [activityID, sourceID])
        guard let externalID, !externalID.isEmpty else { return }
        try d.execute(sql: """
            INSERT INTO activity_gear_reference
              (id, activityID, sourceID, externalID, notedUTC)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [UUID().uuidString, activityID, sourceID,
                             externalID, now])
    }

    // MARK: Small helpers

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
