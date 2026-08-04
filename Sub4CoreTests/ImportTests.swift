//
//  ImportTests.swift
//  Sub4CoreTests
//
//  The cutover — patch 218, ADR-0003 §9.7 and §12.
//
//  THE TWO THAT EARN THEIR PLACE are `runningTwiceDoesNotDuplicate` and
//  `oneRefusedRowDoesNotTakeTheOthersWithIt`. Both describe failures that would
//  look like success: a doubled history reads as a working import until you
//  count, and an aborted transaction leaves an empty database that the health
//  screen reports as healthy, because an empty database IS healthy.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct ImportTests {

    private func activity(_ id: String,
                          day: String = "2026-07-28",
                          distance: Double = 10_000,
                          elapsed: Int = 3_100,
                          startUTC: String? = "2026-07-28T05:24:06Z",
                          gearId: String? = nil,
                          sport: String = "Run",
                          watts: Double? = nil,
                          trainer: Bool? = nil) -> Activity {
        Activity(id: id, name: "Session", sportType: sport,
                 startLocal: "\(day)T07:24:06", distance: distance,
                 movingTime: 3_000, elapsedTime: elapsed,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: trainer,
                 maxHeartrate: nil, gearId: gearId, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: watts,
                 startUTC: startUTC, startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private let shoe = AthleteStore.Shoe(id: "g29433600", name: "Novablast 5 TR",
                                         distanceM: 340_000, primary: true)

    // MARK: Idempotency

    /// §12.1, AND THE FAILURE IT PREVENTS.
    ///
    /// Minting a `UUID()` for every activity on every run would look idempotent
    /// and double the entire history each time the button is pressed. Nothing
    /// in the schema forbids it — nothing there knows two rows describe one
    /// session. The lookup on `(accountID, sourceID, externalID)` is the whole
    /// mechanism, and this is the test that says so.
    @Test("Running the import twice does not duplicate anything")
    func runningTwiceDoesNotDuplicate() throws {
        let db = try Sub4Database.inMemory()
        let rows = [activity("1"), activity("2"), activity("3")]

        let first = try Sub4Import.run(into: db, activities: rows, shoes: [shoe])
        #expect(first.activitiesInserted == 3)
        #expect(first.activitiesUpdated == 0)

        let second = try Sub4Import.run(into: db, activities: rows, shoes: [shoe])
        #expect(second.activitiesInserted == 0, "the import duplicated its own work")
        #expect(second.activitiesUpdated == 3)

        let counted = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM activity") ?? -1
        }
        #expect(counted == 3, "\(counted) rows after two runs of three activities")
    }

    @Test("Gear is imported once and reused")
    func gearIsNotDuplicated() throws {
        let db = try Sub4Database.inMemory()
        let first = try Sub4Import.run(into: db, activities: [], shoes: [shoe])
        let second = try Sub4Import.run(into: db, activities: [], shoes: [shoe])
        #expect(first.gearInserted == 1)
        #expect(second.gearInserted == 0)
        #expect(second.gearAlreadyPresent == 1)
    }

    /// THE ONE REAL DATA FOUND, four minutes after the first import ran.
    ///
    /// The first run happened before `AthleteStore` had refreshed, so its shoe
    /// list was empty and 474 activities imported with a null `gearID`. The
    /// original `importOne` RETURNED on an already-present row, so re-running
    /// once the shoes arrived would have reported "already there: 661" and left
    /// every one of them unattributed for good.
    ///
    /// An import tool has to converge, not merely insert once.
    @Test("Gear arriving after the first run is attributed on the second")
    func gearArrivingLaterIsAttributedOnReimport() throws {
        let db = try Sub4Database.inMemory()
        let rows = [activity("1", gearId: "g29433600")]

        let first = try Sub4Import.run(into: db, activities: rows, shoes: [])
        #expect(first.activitiesInserted == 1)
        #expect(first.gearUnresolved == 1)

        let second = try Sub4Import.run(into: db, activities: rows, shoes: [shoe])
        #expect(second.activitiesInserted == 0)
        #expect(second.activitiesUpdated == 1)
        #expect(second.gearUnresolved == 0)

        let (gearID, canonicalGear, count) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT gearID FROM activity"),
             try String.fetchOne(d, sql: "SELECT id FROM gear"),
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM activity") ?? -1)
        }
        #expect(gearID != nil, "the second run did not attribute the gear")
        #expect(gearID == canonicalGear)
        #expect(count == 1, "the refresh duplicated the activity")
    }

    /// A refresh must not mint a second canonical id, or every note and
    /// correction written against the first one is orphaned.
    @Test("A refresh keeps the canonical id it minted")
    func aRefreshKeepsTheCanonicalId() throws {
        let db = try Sub4Database.inMemory()
        let rows = [activity("1")]
        _ = try Sub4Import.run(into: db, activities: rows, shoes: [])
        let before = try db.queue.read { d in try String.fetchOne(d, sql: "SELECT id FROM activity") }
        _ = try Sub4Import.run(into: db, activities: rows, shoes: [])
        let after = try db.queue.read { d in try String.fetchOne(d, sql: "SELECT id FROM activity") }
        #expect(before == after, "the canonical id changed under the notes that reference it")

        let aliases = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM activity_alias") ?? -1
        }
        #expect(aliases == 1, "the refresh wrote a second alias")
    }

    // MARK: Identity

    /// §3.1. If the canonical id ever equals the Strava id, the whole alias
    /// mechanism is decoration and Phase 4A orphans thirteen months of notes.
    @Test("The canonical id is not the Strava id, and the alias points home")
    func theCanonicalIdIsNotTheExternalId() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity("19580875358")], shoes: [])

        let (canonical, external, aliasTarget) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT id FROM activity"),
             try String.fetchOne(d, sql: "SELECT externalID FROM activity_source_record"),
             try String.fetchOne(d, sql: "SELECT activityID FROM activity_alias WHERE externalID = '19580875358'"))
        }
        #expect(external == "19580875358")
        #expect(canonical != "19580875358", "the Strava id became the primary key")
        #expect(aliasTarget == canonical, "the alias does not resolve to the activity")
    }

    // MARK: Refusals

    /// §12.2, AND THE FAILURE IT PREVENTS.
    ///
    /// Without a savepoint per activity, the first row the CHECK constraints
    /// refuse rolls back the whole write. The database is then EMPTY — and an
    /// empty database passes every integrity check there is, so the health
    /// screen reports it as healthy and nobody looks further.
    @Test("One refused row does not take the others with it")
    func oneRefusedRowDoesNotTakeTheOthersWithIt() throws {
        let db = try Sub4Database.inMemory()
        let rows = [
            activity("good-1"),
            // The August 2025 artifact: 199 km across 694,865 seconds. Refused
            // by the upper bound added after the §7 correction.
            activity("artifact", distance: 199_000, elapsed: 694_865),
            activity("good-2")
        ]
        let report = try Sub4Import.run(into: db, activities: rows, shoes: [])

        #expect(report.activitiesSeen == 3)
        #expect(report.activitiesInserted == 2)
        #expect(report.refusals.count == 1)
        #expect(report.refusals.first?.externalID == "artifact")

        let counted = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM activity") ?? -1
        }
        #expect(counted == 2, "the refusal rolled back more than its own row")
    }

    /// A refusal names the column SQLite objected to, not a paraphrase. "Could
    /// not import" sends the reader nowhere.
    @Test("A refusal carries the reason it was given")
    func aRefusalNamesTheConstraint() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db,
                                        activities: [activity("bad", distance: -1)],
                                        shoes: [])
        let reason = report.refusals.first?.reason ?? ""
        #expect(reason.lowercased().contains("check") || reason.contains("distanceM"),
                "the reason does not name what failed: \(reason)")
    }

    /// `startUTC` is optional in the JSON and NOT NULL in the schema. Inventing
    /// an instant would order the activity wrongly against every other one, and
    /// nobody would ever find out why — so it is refused, visibly.
    @Test("An activity with no start instant is refused rather than invented")
    func aMissingStartInstantIsRefused() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db,
                                        activities: [activity("no-utc", startUTC: nil)],
                                        shoes: [])
        #expect(report.activitiesInserted == 0)
        #expect(report.refusals.count == 1)
        #expect(report.refusals.first?.reason.contains("start instant") == true)
    }

    // MARK: Gear attribution

    @Test("An activity is attributed to the canonical gear id")
    func gearIsResolvedToTheCanonicalId() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db,
                               activities: [activity("1", gearId: "g29433600")],
                               shoes: [shoe])
        let (gearID, canonicalGear, external) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT gearID FROM activity"),
             try String.fetchOne(d, sql: "SELECT id FROM gear"),
             try String.fetchOne(d, sql: "SELECT externalID FROM gear"))
        }
        #expect(gearID == canonicalGear)
        #expect(gearID != "g29433600", "Strava's gear id became the key")
        #expect(external == "g29433600")
    }

    /// THE ONE THE FIRST REAL IMPORT WROTE — patch 222.
    ///
    /// 404 of 662 activities named gear `AthleteStore` does not hold: three
    /// bikes (it decodes only `shoes`) and one retired pair (Strava's
    /// `/athlete` returns only active gear). Their `gearId` was in the JSON and
    /// NULL in the database — a field present in the source and absent after
    /// the cutover, which is the failure §12 exists to prevent.
    ///
    /// `activity_gear_reference` keeps what the source said. A column on
    /// `activity` was the first attempt and `IdentityTests` refused it — §3.1
    /// puts external identifiers in their own table, and this is that table.
    @Test("An unresolved gear id is still recorded, not dropped")
    func anUnresolvedGearIdSurvives() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db,
                               activities: [activity("1", gearId: "b6932581")],
                               shoes: [])
        let (canonical, raw) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT gearID FROM activity"),
             try String.fetchOne(d, sql: "SELECT externalID FROM activity_gear_reference"))
        }
        #expect(canonical == nil, "an unknown bike resolved to a gear row")
        #expect(raw == "b6932581", "the source's gear id was dropped")
    }

    /// §3.1, structurally. The reference points AT the canonical activity; it
    /// is not a property of it. `IdentityTests` bans the column, and this says
    /// where the value went instead.
    @Test("The reference names the canonical activity, not the other way round")
    func theReferencePointsAtTheActivity() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db,
                               activities: [activity("1", gearId: "b6932581")],
                               shoes: [])
        let (activityID, referenced) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT id FROM activity"),
             try String.fetchOne(d, sql: "SELECT activityID FROM activity_gear_reference"))
        }
        #expect(referenced == activityID)
    }

    /// A refresh must not accumulate references. The unique index would refuse
    /// a second row, so a bug here surfaces as a refusal rather than silently —
    /// which is why the delete-then-insert exists.
    @Test("Refreshing does not stack up gear references")
    func refreshingKeepsOneReference() throws {
        let db = try Sub4Database.inMemory()
        let rows = [activity("1", gearId: "b6932581")]
        _ = try Sub4Import.run(into: db, activities: rows, shoes: [])
        let second = try Sub4Import.run(into: db, activities: rows, shoes: [])
        #expect(second.refusals.isEmpty, "the refresh could not rewrite the reference")

        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM activity_gear_reference") ?? -1
        }
        #expect(count == 1, "\(count) references after two runs of one activity")
    }

    /// Gear cleared at the source must clear the reference too, or the row
    /// outlives the fact it recorded.
    @Test("Gear removed at the source removes the reference")
    func clearingGearClearsTheReference() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db,
                               activities: [activity("1", gearId: "b6932581")],
                               shoes: [])
        _ = try Sub4Import.run(into: db,
                               activities: [activity("1", gearId: nil)],
                               shoes: [])
        let count = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM activity_gear_reference") ?? -1
        }
        #expect(count == 0, "the reference survived the gear being cleared")
    }

    /// And a resolved one keeps BOTH: the canonical reference for joins, the
    /// raw id for what the source called it. They answer different questions.
    @Test("A resolved gear id keeps the raw value too")
    func aResolvedGearIdKeepsTheRawValue() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db,
                               activities: [activity("1", gearId: "g29433600")],
                               shoes: [shoe])
        let (canonical, raw) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT gearID FROM activity"),
             try String.fetchOne(d, sql: "SELECT externalID FROM activity_gear_reference"))
        }
        #expect(canonical != nil)
        #expect(canonical != "g29433600")
        #expect(raw == "g29433600")
    }

    /// A shoe the profile does not hold must not cost the run. Counted, not
    /// refused.
    @Test("Unknown gear leaves the activity intact and is counted")
    func unknownGearDoesNotLoseTheRun() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db,
                                        activities: [activity("1", gearId: "g-unknown")],
                                        shoes: [])
        #expect(report.activitiesInserted == 1)
        #expect(report.gearUnresolved == 1)
        #expect(report.refusals.isEmpty)

        let gearID = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT gearID FROM activity")
        }
        #expect(gearID == nil)
    }

    // MARK: The five columns from patch 217

    @Test("The power inputs survive the import")
    func thePowerInputsArrive() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db,
                               activities: [activity("1", watts: 210, trainer: true)],
                               shoes: [])
        let (watts, indoor) = try db.queue.read { d in
            (try Double.fetchOne(d, sql: "SELECT averageWatts FROM activity"),
             try Bool.fetchOne(d, sql: "SELECT isIndoor FROM activity"))
        }
        #expect(watts == 210)
        #expect(indoor == true, "isTrainer did not reach isIndoor")
    }

    /// An unmapped sport is stored raw AND bucketed to `other` — the discipline
    /// column is constrained, the label is not, and losing either loses
    /// something different.
    @Test("An unknown sport keeps its label and becomes other")
    func anUnknownSportIsKeptAndBucketed() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db,
                               activities: [activity("1", sport: "Kitesurf")],
                               shoes: [])
        let (discipline, label) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT discipline FROM activity"),
             try String.fetchOne(d, sql: "SELECT sportLabel FROM activity"))
        }
        #expect(discipline == "other")
        #expect(label == "Kitesurf")
    }

    /// §12.3. Strava holds the same ride twice from 21 April 2026, uploaded by
    /// two devices under two ids. Merging them is a matching decision and the
    /// importer is not the matcher — silently dropping one would be a judgement
    /// nobody could audit afterwards.
    @Test("Two uploads of one ride import as two activities")
    func duplicatesArePreservedNotMerged() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [
            activity("upload-a", distance: 61_700),
            activity("upload-b", distance: 60_400)
        ], shoes: [])
        #expect(report.activitiesInserted == 2)
    }
}
