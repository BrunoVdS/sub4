//
//  AthleteImportTests.swift
//  Sub4CoreTests
//
//  The profile, the zones and the resting series — patch 228, ADR-0003 §12.10.
//
//  WHY THIS FILE IS LONGER THAN THE DATA IT COVERS
//  -----------------------------------------------
//  Three scalars, five zones and a month-keyed dictionary — a few hundred
//  bytes against 661 activities. It is also the denominator of every training
//  load figure in the app. A wrong resting rate for one month rescores every
//  session in that month, and nothing on any chart would look broken.
//
//  So the assertions here are about the two ways this data can be quietly
//  destroyed rather than about round-tripping:
//
//    `theOpenTopZoneSurvives`     — the NOT NULL that would have dropped Z5
//    `anAgedOutMonthIsNotDeleted` — the delete-and-rewrite that would have
//                                   silently rescored the history
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct AthleteImportTests {

    private func activity(_ id: String,
                          name: String = "Session",
                          startLocal: String = "2026-07-28T07:24:06",
                          maxHR: Double? = nil) -> Activity {
        Activity(id: id, name: name, sportType: "Run",
                 startLocal: startLocal, distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: maxHR, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T05:24:06Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    /// Strava's five, with the top one open-ended exactly as `fetchZones`
    /// produces it.
    private var zones: [AthleteStore.HRZone] {
        [.init(index: 1, min: 0, max: 115),
         .init(index: 2, min: 116, max: 139),
         .init(index: 3, min: 140, max: 155),
         .init(index: 4, min: 156, max: 172),
         .init(index: 5, min: 173, max: nil)]
    }

    private func constants(hrMaxObserved: Int? = nil,
                           on day: String? = nil,
                           named: String? = nil,
                           rest: [String: Int] = [:]) -> AthleteConstants {
        var c = AthleteConstants()
        c.hrMaxObserved = hrMaxObserved
        c.hrMaxObservedOn = day
        c.hrMaxObservedName = named
        c.restByMonth = rest
        return c
    }

    // MARK: Zones

    /// THE ONE THAT MATTERS. `HRZone.max` is nil for the top zone and
    /// `hr_zone.maxBpm` was NOT NULL, so Z5 — the zone every hard session
    /// finishes in, and the one `topZoneFloor` reads — would have been refused
    /// while Z1 to Z4 imported cleanly. A zone set with a hole in it, reported
    /// as four successes.
    @Test("The open-ended top zone is stored, with no ceiling")
    func theOpenTopZoneSurvives() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        zones: zones)
        #expect(report.zonesImported == 5)
        #expect(report.refusals.isEmpty)

        let (count, topMax, topMin) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM hr_zone") ?? -1,
             try Int.fetchOne(d, sql: "SELECT maxBpm FROM hr_zone WHERE ordinal = 5"),
             try Int.fetchOne(d, sql: "SELECT minBpm FROM hr_zone WHERE ordinal = 5"))
        }
        #expect(count == 5)
        #expect(topMax == nil, "the top zone was given a ceiling nobody measured")
        #expect(topMin == 173)
    }

    /// THE OTHER END OF THE SAME PROBLEM, and it was this file that found it:
    /// `minBpm > 0` refused Z1, which starts at zero — `HRZone.range` says so
    /// itself. Written after `theOpenTopZoneSurvives` reported five zones
    /// stored as zero rather than as four.
    @Test("The bottom zone starts at zero, and zero is stored")
    func theBottomZoneFloorIsZero() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        zones: zones)
        #expect(report.refusals.isEmpty)
        let floor = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT minBpm FROM hr_zone WHERE ordinal = 1")
        }
        #expect(floor == 0, "the bottom zone was given a floor it does not have")
    }

    /// A negative floor is still not a zone. Relaxing `> 0` to `>= 0` must not
    /// relax it to nothing.
    @Test("A negative zone floor is still rejected")
    func aNegativeFloorIsRejected() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], zones: [])
        #expect(throws: DatabaseError.self) {
            try db.queue.write { d in
                try d.execute(sql: """
                    INSERT INTO hr_zone (id, accountID, ordinal, minBpm, maxBpm)
                    VALUES ('Z-NEG', ?, 9, -1, 120)
                    """, arguments: [Sub4Import.accountID])
            }
        }
    }

    /// `ordinal` is Strava's 1-based zone number, not an array index. Off by
    /// one here and the database disagrees with every label in the app.
    @Test("Ordinals are the zone numbers the app prints")
    func ordinalsAreOneBased() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], zones: zones)
        let ordinals = try db.queue.read { d in
            try Int.fetchAll(d, sql: "SELECT ordinal FROM hr_zone ORDER BY ordinal")
        }
        #expect(ordinals == [1, 2, 3, 4, 5])
    }

    /// A zone set is one object. If the boundaries move from five zones to
    /// three, upserting by ordinal would leave Z4 and Z5 behind as rows nobody
    /// wrote and nothing deletes, and a lookup would answer from a set that
    /// never existed.
    @Test("A smaller zone set replaces the larger one whole")
    func zonesAreReplacedNotMerged() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], zones: zones)
        let three: [AthleteStore.HRZone] = [.init(index: 1, min: 0, max: 130),
                                            .init(index: 2, min: 131, max: 160),
                                            .init(index: 3, min: 161, max: nil)]
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], zones: three)

        let (count, topOrdinal) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM hr_zone") ?? -1,
             try Int.fetchOne(d, sql: "SELECT MAX(ordinal) FROM hr_zone"))
        }
        #expect(count == 3, "zones from the previous set survived as ghosts")
        #expect(topOrdinal == 3)
    }

    /// No zones held is not the same as an empty zone set. An import that
    /// deleted on the way past would throw away a good set the first time it
    /// ran before Strava had answered.
    @Test("An import with no zones does not clear the stored ones")
    func absentZonesDoNotDelete() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], zones: zones)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], zones: [])
        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM hr_zone") ?? -1
        }
        #expect(count == 5)
    }

    // MARK: The profile

    /// One row from two stores — `sexCoefficient` from `AthleteConstants`,
    /// `ftpWatts` from `AthleteStore`. Neither store can produce this row on
    /// its own, which is the whole reason the mapping was written first.
    @Test("The profile is assembled from both stores")
    func theProfileComesFromBothStores() throws {
        let db = try Sub4Database.inMemory()
        var c = constants()
        c.hrMaxOverride = 191
        c.restOverride = 44
        c.sexCoefficient = 1.92

        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        constants: c, ftpWatts: 244)
        #expect(report.profileImported == 1)

        let row = try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM athlete_profile")
        }
        let r = try #require(row)
        #expect(r["hrMaxOverride"] as Int? == 191)
        #expect(r["restOverride"] as Int? == 44)
        #expect(r["sexCoefficient"] as Double? == 1.92)
        #expect(r["ftpWatts"] as Int? == 244)
    }

    @Test("Re-importing the profile refreshes it rather than adding a second")
    func theProfileConverges() throws {
        let db = try Sub4Database.inMemory()
        var c = constants()
        c.hrMaxOverride = 191
        let first = try Sub4Import.run(into: db, activities: [], shoes: [], constants: c)
        c.hrMaxOverride = 188
        let second = try Sub4Import.run(into: db, activities: [], shoes: [], constants: c)

        #expect(first.profileImported == 1)
        #expect(second.profileImported == 0)
        #expect(second.profileUpdated == 1)

        let (count, value) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM athlete_profile") ?? -1,
             try Int.fetchOne(d, sql: "SELECT hrMaxOverride FROM athlete_profile"))
        }
        #expect(count == 1, "the unique constraint on accountID did not hold")
        #expect(value == 188)
    }

    /// The provenance column has no field behind it — the store keeps a NAME.
    /// It is resolved from the day and the recorded maximum, and the result
    /// must be the CANONICAL id, not Strava's.
    @Test("The observed maximum is traced to the activity that produced it")
    func provenanceResolvesThroughTheAlias() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("19580875358", name: "Hill repeats",
                             startLocal: "2026-07-28T07:24:06", maxHR: 189.4),
                    activity("19580875359", name: "Easy", maxHR: 141)]
        let c = constants(hrMaxObserved: 189, on: "2026-07-28", named: "Hill repeats")

        let report = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        constants: c)
        #expect(report.profileProvenanceUnresolved == 0)

        let (stored, canonical) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT hrMaxObservedActivityID FROM athlete_profile"),
             try String.fetchOne(d, sql: """
                SELECT activityID FROM activity_alias WHERE externalID = ?
                """, arguments: ["19580875358"]))
        }
        #expect(stored != nil)
        #expect(stored == canonical)
        #expect(stored != "19580875358", "the Strava id was carried into the profile")
    }

    /// `hrMaxObserved` is `Int(maxHeartrate.rounded())`, so the same rounding
    /// has to be applied on the way back or a 189.4 bpm activity never matches
    /// the 189 that came from it.
    @Test("The match survives the rounding that produced the figure")
    func provenanceMatchesRoundedHeartRate() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("1", maxHR: 188.6)]
        let c = constants(hrMaxObserved: 189, on: "2026-07-28")
        let report = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        constants: c)
        #expect(report.profileProvenanceUnresolved == 0)
        let stored = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT hrMaxObservedActivityID FROM athlete_profile")
        }
        #expect(stored != nil)
    }

    /// Two candidates is not a reason to pick one. A provenance column holding
    /// a plausible wrong activity is worse than an empty one, because the empty
    /// one is visibly empty.
    @Test("An ambiguous maximum leaves the column empty and says so")
    func ambiguousProvenanceIsRefusedNotGuessed() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("1", name: "Intervals", maxHR: 189),
                    activity("2", name: "Intervals", maxHR: 189)]
        let c = constants(hrMaxObserved: 189, on: "2026-07-28", named: "Intervals")

        let report = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        constants: c)
        #expect(report.profileImported == 1, "the profile was lost over its provenance")
        #expect(report.profileProvenanceUnresolved == 1)
        #expect(report.refusals.isEmpty, "a missing provenance was reported as a refusal")

        let stored = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT hrMaxObservedActivityID FROM athlete_profile")
        }
        #expect(stored == nil)
    }

    /// The observed maximum still imports when its activity is not here at all
    /// — the figure is the fact, the activity is the provenance, and losing the
    /// second is not a reason to lose the first.
    @Test("An observed maximum with no matching activity still imports")
    func theFigureSurvivesWithoutItsActivity() throws {
        let db = try Sub4Database.inMemory()
        let c = constants(hrMaxObserved: 189, on: "2026-07-28", named: "Gone")
        let report = try Sub4Import.run(into: db, activities: [], shoes: [], constants: c)

        #expect(report.profileImported == 1)
        #expect(report.profileProvenanceUnresolved == 1)
        let observed = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT hrMaxObserved FROM athlete_profile")
        }
        #expect(observed == 189)
    }

    // MARK: The resting series

    @Test("Every month of the resting series arrives")
    func theRestingSeriesArrives() throws {
        let db = try Sub4Database.inMemory()
        let c = constants(rest: ["2026-05": 46, "2026-06": 44, "2026-07": 45])
        let report = try Sub4Import.run(into: db, activities: [], shoes: [], constants: c)

        #expect(report.restingSeen == 3)
        #expect(report.restingImported == 3)

        let rows = try db.queue.read { d in
            try Row.fetchAll(d, sql: "SELECT month, bpm FROM resting_month ORDER BY month")
        }
        let months = rows.map { $0["month"] as String? }
        let bpms = rows.map { $0["bpm"] as Int? }
        #expect(months == ["2026-05", "2026-06", "2026-07"])
        #expect(bpms == [46, 44, 45])
    }

    /// THE SECOND ONE THAT MATTERS. `restByMonth` is recomputed from a rolling
    /// window, so a month that has aged out of Health's range is absent from
    /// the store and is still the only figure the app has ever had for it.
    /// Every activity in that month is scored against it. A delete-and-rewrite
    /// — the call made for zones two screens up — would rescore the history
    /// with no error and nothing visibly wrong.
    @Test("A month that has aged out of the store is not deleted")
    func anAgedOutMonthIsNotDeleted() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               constants: constants(rest: ["2025-08": 47,
                                                           "2026-06": 44]))
        // The window has moved on; August 2025 is no longer computed.
        let second = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        constants: constants(rest: ["2026-06": 44,
                                                                    "2026-07": 45]))
        #expect(second.restingImported == 1)
        #expect(second.restingUpdated == 1)

        let rows = try db.queue.read { d in
            try String.fetchAll(d, sql: "SELECT month FROM resting_month ORDER BY month")
        }
        #expect(rows == ["2025-08", "2026-06", "2026-07"],
                "a month aged out of the store was deleted from the database")
    }

    @Test("A month re-imported with a new figure is refreshed, not duplicated")
    func theRestingSeriesConverges() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               constants: constants(rest: ["2026-06": 44]))
        let second = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        constants: constants(rest: ["2026-06": 42]))
        #expect(second.restingUpdated == 1)
        let (count, bpm) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM resting_month") ?? -1,
             try Int.fetchOne(d, sql: "SELECT bpm FROM resting_month"))
        }
        #expect(count == 1)
        #expect(bpm == 42)
    }

    // MARK: Nothing offered

    /// An import run before any of this is held must not invent a profile.
    /// `profileSeen == 0` is what lets the screen say "not offered" instead of
    /// showing a blank row that reads like a failure.
    @Test("An import with no profile writes nothing and says nothing happened")
    func nothingOfferedIsNotAnEmptyProfile() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [])
        #expect(report.profileSeen == 0)
        #expect(report.profileImported == 0)
        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM athlete_profile") ?? -1
        }
        #expect(count == 0)
    }

    /// Declared and applied. Not "and last" — see the note in
    /// `AuthoredImportTests`; the ordering invariant lives in
    /// `ActivityInputTests` as a property that survives future migrations.
    @Test("The new migration is declared and applied")
    func theMigrationIsDeclared() throws {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.openTopZone))
        #expect(Sub4Migrations.all.contains(Sub4Migrations.zoneFloorZero))
        let db = try Sub4Database.inMemory()
        let applied = try db.integrityReport().appliedMigrations
        #expect(applied.contains(Sub4Migrations.openTopZone))
        #expect(applied.contains(Sub4Migrations.zoneFloorZero))
    }

    /// THE ASSERTION THIS FILE DID NOT HAVE, and its absence is why eight green
    /// tests coexisted with five refused zones on the phone — patch 236.
    ///
    /// Every other test here builds a database from the CURRENT source and so
    /// cannot tell an edited migration body from an honest one. This one reads
    /// the shape SQLite actually holds after the whole history has run, which
    /// is the only thing a device has. If a body is ever edited in place again,
    /// the two disagree and this fails.
    @Test("The stored schema, not the source, admits a zone floor of zero")
    func theStoredSchemaAdmitsAZeroFloor() throws {
        let db = try Sub4Database.inMemory()
        let sql = try db.queue.read { d in
            try String.fetchOne(d, sql: """
                SELECT sql FROM sqlite_master
                WHERE type = 'table' AND name = 'hr_zone'
                """)
        }
        let schema = try #require(sql)
        #expect(schema.contains("minBpm >= 0"),
                "the live hr_zone schema still refuses the bottom zone")
        #expect(!schema.contains("minBpm > 0"),
                "an older definition of hr_zone is the one in force")
    }

    /// The relaxed column did not relax the constraint that matters. A zone
    /// ending below its start is still not a zone — `DomainSchemaTests` asserts
    /// this against the original table, and the rebuild has to keep it true.
    @Test("An inverted zone is still rejected after the rebuild")
    func theInvertedZoneCheckSurvivedTheRebuild() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], zones: [])
        #expect(throws: DatabaseError.self) {
            try db.queue.write { d in
                try d.execute(sql: """
                    INSERT INTO hr_zone (id, accountID, ordinal, minBpm, maxBpm)
                    VALUES ('Z-BAD', ?, 9, 160, 120)
                    """, arguments: [Sub4Import.accountID])
            }
        }
    }
}
