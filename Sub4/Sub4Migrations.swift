//
//  Sub4Migrations.swift
//  Sub4
//
//  The schema, as ordered functions — patch 195, plan step 3.2a, ADR-0003 §3,
//  §4, §6, §7 and §8.
//
//  WHAT IS IN THIS FIRST MIGRATION AND WHAT IS NOT
//  ----------------------------------------------
//  Groups 1 and 3 of ADR-0003 §8 only: `account`, `source`, and the three
//  tables identity is built from — `activity`, `activity_source_record`,
//  `activity_alias`. Everything else (the plan, recordings, notes, reviews,
//  weather, operational state) is 3.2b.
//
//  Split that way because these five are the ones every other table will point
//  at. If the identity model is wrong, it is cheap to find out now and
//  expensive to find out after nine more tables reference it — which is the
//  entire argument of ADR-0003 §1, applied to the order the tables are written
//  in rather than to the document.
//
//  MIGRATIONS ARE NAMED WITH A DATE AND ARE NEVER EDITED
//  ----------------------------------------------------
//  Once a migration has run on a device that holds real data, its identifier is
//  recorded and its body is history. Changing the body afterwards does not
//  change the database — it changes what a FRESH install gets, so the two
//  diverge silently and every later assumption is true on one of them.
//
//  A change to the schema is a NEW migration with a new date. This will feel
//  wasteful the first time a column name is regretted, and it is the property
//  that makes the thirteen-month import in 3.3 survivable.
//
//  `eraseDatabaseOnSchemaChange` IS DELIBERATELY NOT SET
//  ----------------------------------------------------
//  GRDB offers it, every tutorial enables it under `#if DEBUG`, and it wipes
//  the database whenever a registered migration's body changes. On a project
//  whose entire purpose is carrying thirteen months of training through a
//  rewrite, that is a loaded gun aimed at the thing being protected — and DEBUG
//  is the configuration this app is developed and tested in, on the device that
//  holds the real history. It stays off. The cost is deleting the app by hand
//  after a schema change during development, which is a chore rather than a
//  loss.
//

import Foundation
import GRDB

nonisolated enum Sub4Migrations {

    // MARK: The list

    static let initial = "2026-08-03-initial"

    /// Every migration, in the order they must run. `IntegrityReport` compares
    /// against this, so a migration registered below and forgotten here reports
    /// as "not migrated" rather than passing quietly.
    static let all: [String] = [initial, domain, activityInputs, gearReference,
                                proposalInputs, openTopZone, zoneFloorZero,
                                planContent, activityDetail, migrationRun,
                                runTrigger, confidenceScale, reviewRecordKey,
                                interruptedRun, runRecovered]

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // See the header. Not set, and not to be set.
        registerInitial(&m)
        registerDomain(&m)          // Sub4Migrations+Domain.swift
        registerActivityInputs(&m)  // Sub4Migrations+Inputs.swift
        registerGearReference(&m)   // Sub4Migrations+GearReference.swift
        registerProposalInputs(&m)  // Sub4Migrations+ProposalInputs.swift
        registerOpenTopZone(&m)     // Sub4Migrations+OpenTopZone.swift
        registerZoneFloorZero(&m)   // Sub4Migrations+ZoneFloorZero.swift
        registerPlanContent(&m)     // Sub4Migrations+PlanContent.swift
        registerActivityDetail(&m)  // Sub4Migrations+ActivityDetail.swift
        registerMigrationRun(&m)    // Sub4Migrations+MigrationRun.swift
        registerRunTrigger(&m)      // Sub4Migrations+RunTrigger.swift
        registerConfidenceScale(&m) // Sub4Migrations+ConfidenceScale.swift
        registerReviewRecordKey(&m) // Sub4Migrations+ReviewRecordKey.swift
        registerInterruptedRun(&m)  // Sub4Migrations+InterruptedRun.swift
        registerRunRecovered(&m)    // Sub4Migrations+RunRecovered.swift
        return m
    }

    // MARK: Frozen vocabularies
    //
    // WHY THESE ARE WRITTEN OUT RATHER THAN READ FROM `DataSource` AND
    // `Discipline`, WHICH WAS THE FIRST VERSION OF THIS FILE.
    //
    // Deriving them from the enums looked like the drift-proof choice and is
    // the opposite. A migration body is HISTORY: once `2026-08-03-initial` has
    // run on a device, its identifier is recorded and its body never runs there
    // again. If the body reads a live Swift enum, then adding `case garmin` to
    // `DataSource` silently changes what a FRESH install gets while every
    // existing device keeps three rows — two different databases under one
    // migration identifier, with nothing to say which one you are looking at.
    //
    // So the lists are frozen here at the values they had on 3 August 2026, and
    // the agreement with the enums is asserted in `SchemaAgreementTests`
    // instead. When a case is added, that test fails and the fix is a NEW
    // migration that inserts the new row — which is the correct amount of work
    // for a change to a shipped schema, and the amount this file's header asks
    // for.

    /// The sources known at `2026-08-03-initial`. Compared against
    /// `DataSource.allCases` by test; a mismatch means a new migration is owed.
    static let initialSources: [(id: String, label: String)] = [
        ("strava", "Strava"),
        ("appleHealth", "Apple Health"),
        ("authored", "You"),
        ("bundled", "Shipped with the app"),
        ("weatherProvider", "Weather provider"),
        ("device", "This phone")
    ]

    /// The disciplines known at `2026-08-03-initial`. Same rule, same test.
    static let initialDisciplines = ["run", "bike", "swim", "strength", "rest", "other"]

    // MARK: Sanity bounds
    //
    // AN HONEST CORRECTION TO ADR-0003 §7. The ADR says the CHECK constraints
    // — "distance ≥ 0, duration ≥ 0, latitude in −90…90, longitude in
    // −180…180" — are "exactly what these reject" for the 199 km / 694,865 s
    // "Afternoon Ride" artifact from August 2025.
    //
    // They are not. 694,865 is a positive number and passes `duration ≥ 0`
    // without complaint, and 199 km is an ordinary long ride. The ADR
    // overstates what a non-negativity check can do, and writing the migration
    // is where that became obvious.
    //
    // What actually rejects it is an upper bound, so there is one. Seven days
    // is far past any session this athlete will record and comfortably below
    // the 8.04 days that artifact claims. A bound is a judgement rather than a
    // law of nature, which is why it is named, tested against the real
    // artifact, and stated here rather than buried in a SQL string.

    /// 7 days. An "activity" longer than this is a recording that never
    /// stopped, not a session.
    static let maximumPlausibleElapsedSeconds = 604_800

    /// 1,000 km. Generous for a single recording and still an order of
    /// magnitude below the values a stuck GPS produces.
    static let maximumPlausibleDistanceM = 1_000_000.0

    // MARK: 2026-08-03-initial

    private static func registerInitial(_ m: inout DatabaseMigrator) {
        m.registerMigration(initial) { db in

            // MARK: account — ADR-0003 §8 group 1, §9.6
            //
            // ONE ROW, FOREVER, and §9.6 says so in as many words: Sub4 has one
            // athlete, there is no sign-up and none is planned. The table exists
            // because `(account, source, externalID)` is the uniqueness key that
            // has to survive the Strava-to-Health cutover, and because adding a
            // column to every table during a migration is worse than carrying
            // it from the start.
            //
            // Anyone reading this and inferring a multi-user product should
            // read §9.6 instead.
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("label", .text).notNull()
                t.column("createdUTC", .text).notNull()
            }

            // MARK: source — ADR-0003 §8 group 1
            //
            // A TABLE RATHER THAN A CHECK CONSTRAINT, and the reason is that a
            // foreign key does the same work while staying queryable: `SELECT
            // label FROM source` answers "what can this app read from" in a
            // terminal, where a CHECK constraint has to be read out of the
            // schema text.
            //
            // Seeded from `initialSources`, which is frozen — see the note
            // beside it — and held to `DataSource` by test.
            try db.create(table: "source") { t in
                t.primaryKey("id", .text)
                t.column("label", .text).notNull()
            }
            for s in initialSources {
                try db.execute(sql: "INSERT INTO source (id, label) VALUES (?, ?)",
                               arguments: [s.id, s.label])
            }

            // MARK: activity — ADR-0003 §3.1, §4.1, §5, §6
            try db.create(table: "activity") { t in

                // §3.1. A UUID minted here, never derived from anything
                // external, never reused. This is the decision the whole ADR
                // exists for.
                t.primaryKey("id", .text)

                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)

                // §4.1 — four representations of when.
                //
                // `startUTC` is authoritative for ORDER. `dayKey` is
                // authoritative for BELONGING. They are not redundant: a run at
                // 23:40 and one at 00:20 are forty minutes and one training day
                // apart, and a session in Tokyo belongs to the day it felt like.
                t.column("startUTC", .text).notNull()
                t.column("startLocal", .text).notNull()
                t.column("dayKey", .text).notNull()

                // §4.3. NULLABLE, AND NULL MEANS UNKNOWN — this is the column
                // where §6 stops being an abstraction. An offset of 0 is
                // Greenwich; it is not "no information". Every activity
                // imported from the existing JSON has neither of these, because
                // Strava sends `timezone` and `utc_offset` and the app has
                // never decoded them. §4.4 has a deadline for that, in
                // September, independent of Phase 3.
                t.column("startOffsetSeconds", .integer)
                t.column("timeZoneIdentifier", .text)

                // The app's own vocabulary, checked. `Discipline` is a closed
                // set this project owns — unlike `sportLabel` below.
                t.column("discipline", .text).notNull()
                    .check(sql: "discipline IN (\(quotedList(initialDisciplines)))")

                // What the SOURCE called it — "VirtualRun", "WeightTraining".
                // Provenance, not identity, and deliberately unchecked: a
                // closed list of another company's strings is a constraint that
                // fails on the day they add one. Nullable because a hand-entered
                // activity has no source label at all.
                t.column("sportLabel", .text)

                t.column("name", .text).notNull()

                // §5 — SI, unrounded. §6 — zero is a legitimate distance for a
                // strength session, so NOT NULL rather than nullable.
                t.column("distanceM", .double).notNull()
                    .check(sql: "distanceM >= 0 AND distanceM <= \(maximumPlausibleDistanceM)")
                t.column("movingSeconds", .integer).notNull()
                    .check(sql: "movingSeconds >= 0 AND movingSeconds <= \(maximumPlausibleElapsedSeconds)")
                t.column("elapsedSeconds", .integer).notNull()
                    .check(sql: "elapsedSeconds >= 0 AND elapsedSeconds <= \(maximumPlausibleElapsedSeconds)")

                // Absent for an indoor session with no barometer. Unknown, not
                // zero — §6.
                t.column("elevationGainM", .double)
                    .check(sql: "elevationGainM IS NULL OR elevationGainM >= 0")

                // The §6 case that is already load-bearing: no strap means no
                // heart rate, and the training-load engine must SKIP the
                // session rather than score it as easy. A NOT NULL DEFAULT 0
                // here would silently make every unstrapped run a recovery run.
                t.column("averageHeartrate", .double)
                    .check(sql: "averageHeartrate IS NULL OR averageHeartrate > 0")
                t.column("maxHeartrate", .double)
                    .check(sql: "maxHeartrate IS NULL OR maxHeartrate > 0")

                // WGS-84 decimal degrees. Nullable — an indoor session has no
                // start point, and that is the difference between a treadmill
                // run and one that began at the equator.
                t.column("startLatitude", .double)
                    .check(sql: "startLatitude IS NULL OR (startLatitude >= -90 AND startLatitude <= 90)")
                t.column("startLongitude", .double)
                    .check(sql: "startLongitude IS NULL OR (startLongitude >= -180 AND startLongitude <= 180)")

                t.column("createdUTC", .text).notNull()
                t.column("updatedUTC", .text).notNull()
            }

            try db.create(index: "activity_on_dayKey", on: "activity", columns: ["dayKey"])
            try db.create(index: "activity_on_startUTC", on: "activity", columns: ["startUTC"])
            try db.create(index: "activity_on_account", on: "activity", columns: ["accountID"])

            // MARK: activity_source_record — ADR-0003 §3.1
            //
            // One row per arrival. THE ONLY PLACE AN EXTERNAL IDENTIFIER
            // APPEARS, and the unique key is the idempotency key for ingestion:
            // re-syncing the same Strava activity finds this row and updates
            // rather than creating a second canonical activity.
            //
            // Cascades with the activity. A source record for an activity that
            // no longer exists describes nothing.
            try db.create(table: "activity_source_record") { t in
                t.primaryKey("id", .text)
                t.column("activityID", .text).notNull()
                    .references("activity", onDelete: .cascade)
                t.column("accountID", .text).notNull()
                    .references("account", onDelete: .cascade)
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)
                t.column("externalID", .text).notNull()
                t.column("firstSeenUTC", .text).notNull()
                t.column("lastSeenUTC", .text).notNull()

                t.uniqueKey(["accountID", "sourceID", "externalID"])
            }

            try db.create(index: "source_record_on_activity",
                          on: "activity_source_record", columns: ["activityID"])

            // MARK: activity_alias — ADR-0003 §3.1
            //
            // THE TABLE THIS ADR EXISTS TO PRODUCE. Every external id an
            // activity has ever been known by, kept whether or not the source
            // is still connected.
            //
            // IT DOES NOT CASCADE WITH THE SOURCE RECORD, and that is the whole
            // design. At Phase 4A the Strava source records are purged under
            // ADR-0002 while these rows stay, so a note written against Strava
            // id 19580875358 still resolves to the run it was about — thirteen
            // months after Strava is gone. Deleting an alias with its source
            // record would make this table an index rather than a memory, and
            // would quietly orphan every authored record at the cutover.
            //
            // It cascades with the ACTIVITY, because an alias for an activity
            // that no longer exists points at nothing.
            try db.create(table: "activity_alias") { t in
                t.primaryKey("id", .text)
                t.column("activityID", .text).notNull()
                    .references("activity", onDelete: .cascade)
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)
                t.column("externalID", .text).notNull()
                t.column("notedUTC", .text).notNull()
                // Retired rather than deleted: an alias that stopped being the
                // current identifier is still the one old records were written
                // against.
                t.column("retiredUTC", .text)

                t.uniqueKey(["sourceID", "externalID"])
            }

            try db.create(index: "alias_on_activity",
                          on: "activity_alias", columns: ["activityID"])
        }
    }

    /// `'a', 'b', 'c'` — for a CHECK generated from a Swift enum rather than
    /// typed twice.
    ///
    /// Escapes the SQL quote. No case name contains one today, and a helper
    /// that produces valid SQL only for the inputs it happens to have is how
    /// injection gets written by someone who was not thinking about injection.
    private static func quotedList(_ values: [String]) -> String {
        values
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
    }
}
