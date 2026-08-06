//
//  ActivityRepositoryTests.swift
//  Sub4CoreTests
//
//  The first reader — D6a, patch 289, ADR-0003 §12.35.
//
//  `theActivityRoundTrips` is the one that matters, and it is D6c's question
//  asked six weeks early: put an `Activity` through the importer, read it back
//  out of the database, and check every field. Every column rename is a chance
//  to be wrong — `isTrainer` is stored as `isIndoor`, `deviceWatts` as
//  `hasPowerMeter`, and `gearId` is not `activity.gearID` at all — and a
//  reader that is wrong about one of them makes shadow parity report a data
//  divergence that has nothing to do with the data.
//
//  Field by field rather than one `==`, so a failure names the field.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct ActivityRepositoryTests {

    private func ride(_ id: String = "19580875358",
                      gearId: String? = nil,
                      startUTC: String = "2026-07-28T16:02:00Z") -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 24_300,
                 movingTime: 3_240, elapsedTime: 3_600,
                 elevationGain: 142, averageHeartrate: 131, isTrainer: false,
                 maxHeartrate: 168, gearId: gearId, maxSpeed: 12.4,
                 deviceWatts: true, averageWatts: 168,
                 startUTC: startUTC, startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    // MARK: Nothing there is not the same as could not look

    /// THE REASON THIS TYPE EXISTS. An empty database is a legitimate answer
    /// on a fresh install, and it must not be reachable by the same path as a
    /// read that failed.
    @Test("An empty database loads as empty, and says so")
    func emptyIsAnAnswerNotAFailure() throws {
        let db = try Sub4Database.inMemory()
        let load = ActivityRepository.all(db)

        #expect(load.isTrustworthy)
        #expect(load.activities?.isEmpty == true)
        #expect(load.skipped == 0)
        #expect(load.line == "0 activities.")
    }

    @Test("An untrustworthy read hands back nothing, not an empty list")
    func anUntrustworthyReadIsNotEmpty() {
        for load: ActivityLoad in [.unavailable, .failed("the file is locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.activities == nil,
                    "a caller must not be able to reach [] without deciding what this means")
        }
    }

    // MARK: The round trip

    /// THE ONE THAT MATTERS.
    @Test("An activity survives the round trip, field by field")
    func theActivityRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = ride()
        _ = try Sub4Import.run(into: db, activities: [original], shoes: [])

        let load = ActivityRepository.all(db)
        let list = try #require(load.activities)
        #expect(list.count == 1)
        let back = try #require(list.first)

        #expect(back.id == original.id, "the store's id is Strava's, not the row's UUID")
        #expect(back.name == original.name)
        #expect(back.sportType == original.sportType, "sportType is stored as sportLabel")
        #expect(back.startLocal == original.startLocal)
        #expect(back.startUTC == original.startUTC)
        #expect(back.distance == original.distance)
        #expect(back.movingTime == original.movingTime)
        #expect(back.elapsedTime == original.elapsedTime)
        #expect(back.elevationGain == original.elevationGain)
        #expect(back.averageHeartrate == original.averageHeartrate)
        #expect(back.maxHeartrate == original.maxHeartrate)
        #expect(back.startLat == original.startLat)
        #expect(back.startLon == original.startLon)
        #expect(back.timeZoneIdentifier == original.timeZoneIdentifier)
        #expect(back.startOffsetSeconds == original.startOffsetSeconds)

        // THE FOUR RENAMES. Each of these was added by a later migration under
        // a different name, and each is a chance for this reader to be wrong
        // in a way that looks like missing data.
        #expect(back.isTrainer == original.isTrainer, "isTrainer is stored as isIndoor")
        #expect(back.deviceWatts == original.deviceWatts,
                "deviceWatts is stored as hasPowerMeter")
        #expect(back.averageWatts == original.averageWatts)
        #expect(back.maxSpeed == original.maxSpeed, "maxSpeed is stored as maxSpeedMS")
    }

    @Test("One activity can be fetched by the id the store uses")
    func fetchByStoreID() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [])

        let found = ActivityRepository.activity(db, storeID: "19580875358")
        #expect(found.activities?.count == 1)

        // Not a failure — the database was read and holds no such row.
        let missing = ActivityRepository.activity(db, storeID: "99999999999")
        #expect(missing.isTrustworthy)
        #expect(missing.activities?.isEmpty == true)
    }

    // MARK: Gear — the trap

    /// `activity.gearID` holds the CANONICAL id and `Activity.gearId` holds
    /// Strava's. Reading the column straight through would give every
    /// gear-bearing activity an id that matches nothing in `AthleteStore`.
    /// THE SHOE HAS TO GO THROUGH THE IMPORTER — 289a, and the first version
    /// of this test is the finding. It inserted a `gear` row with SQL and
    /// expected the importer to resolve against it. The importer builds its
    /// external-id map from the SHOES it is handed, not from the table, so
    /// with `shoes: []` nothing resolved and the row took the fallback path.
    ///
    /// The repository was right either way — `gearId` came back — but the test
    /// was proving the fallback while claiming to prove the join.
    @Test("Gear comes back as the id the store uses, not the canonical one")
    func gearComesBackAsTheStoreID() throws {
        let db = try Sub4Database.inMemory()
        let shoe = AthleteStore.Shoe(id: "g12345678", name: "Vaporfly",
                                     distanceM: 412_000, primary: true)
        _ = try Sub4Import.run(into: db, activities: [ride(gearId: "g12345678")],
                               shoes: [shoe])

        let canonical = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT gearID FROM activity")
        }
        let external = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT externalID FROM gear")
        }
        let back = try #require(ActivityRepository.all(db).activities?.first)

        #expect(canonical != nil, "the importer minted a gear row and linked it")
        #expect(canonical != "g12345678",
                "and the column holds the CANONICAL id, not Strava's")
        #expect(external == "g12345678")
        #expect(back.gearId == "g12345678", "the reader must hand back Strava's")
    }

    /// The gear the importer could not resolve. `activity.gearID` stays null
    /// and the name Strava gave is recorded in `activity_gear_reference` — a
    /// retired shoe, a bike added after the last athlete fetch. A reader that
    /// looked only at the column would lose the gear on exactly those rows.
    @Test("Gear the importer could not resolve still comes back")
    func unresolvedGearStillComesBack() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride(gearId: "g-unknown")],
                               shoes: [])

        let canonical = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT gearID FROM activity")
        }
        #expect(canonical == nil, "nothing to resolve it to, so the column is null")

        let back = try #require(ActivityRepository.all(db).activities?.first)
        #expect(back.gearId == "g-unknown",
                "the reference table is the fallback, and the reader must use it")
    }

    @Test("An activity with no gear has none, rather than failing to load")
    func noGearIsFine() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [])
        let back = try #require(ActivityRepository.all(db).activities?.first)
        #expect(back.gearId == nil)
    }

    // MARK: Order and scope

    /// §4.1: `startUTC` is authoritative for ORDER, `startLocal` for
    /// BELONGING. Ordering by the wrong one is invisible until two sessions
    /// fall either side of midnight.
    @Test("Newest first, by startUTC")
    func newestFirst() throws {
        let db = try Sub4Database.inMemory()
        let older = ride("1", startUTC: "2026-07-27T16:02:00Z")
        let newer = ride("2", startUTC: "2026-07-29T16:02:00Z")
        _ = try Sub4Import.run(into: db, activities: [older, newer], shoes: [])

        let list = try #require(ActivityRepository.all(db).activities)
        #expect(list.map(\.id) == ["2", "1"])
    }

    @Test("Another account's rows are not this account's")
    func accountScoped() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [])

        let other = ActivityRepository.all(db, accountID: "someone-else")
        #expect(other.isTrustworthy)
        #expect(other.activities?.isEmpty == true)
    }

    // MARK: The round-trip comparison — 290

    @Test("Identical sides agree on every field")
    func identicalSidesAgree() {
        let a = ride()
        let r = ActivityRoundTrip.compare(store: [a], database: [a])
        #expect(r.compared == 1)
        #expect(r.agreed == 1)
        #expect(r.differences.isEmpty)
        #expect(r.missing.isEmpty)
    }

    /// THE POINT OF THE FIELD TALLY. A count of differing activities sends
    /// somebody through them one at a time; a count by field is usually one
    /// fix.
    @Test("A difference names the field, not just the activity")
    func aDifferenceNamesTheField() {
        let store = ride()
        var altered = ride()
        altered.maxSpeed = 99
        let r = ActivityRoundTrip.compare(store: [store], database: [altered])

        #expect(r.differences.count == 1)
        #expect(r.differences.first?.fields == ["maxSpeed"])
        #expect(r.fieldTally.map(\.field) == ["maxSpeed"])
        #expect(r.fieldTally.first?.count == 1)
    }

    @Test("The tally counts a field once per activity that differs on it")
    func theTallyCountsPerActivity() {
        var a = ride("1"); a.maxSpeed = 1
        var b = ride("2"); b.maxSpeed = 2
        let r = ActivityRoundTrip.compare(store: [ride("1"), ride("2")],
                                          database: [a, b])
        #expect(r.fieldTally.first?.field == "maxSpeed")
        #expect(r.fieldTally.first?.count == 2)
        #expect(r.agreed == 0)
    }

    @Test("An activity the database does not have is missing, not different")
    func missingIsNotDifferent() {
        let r = ActivityRoundTrip.compare(store: [ride("1"), ride("2")],
                                          database: [ride("1")])
        #expect(r.compared == 1, "only the one present can be compared")
        #expect(r.missing == ["2"])
        #expect(r.differences.isEmpty)
    }

    /// The whole comparison is only as good as this list. A field added to
    /// `Activity` and not to `differingFields` makes it quietly weaker.
    @Test("Every stored field of an Activity is compared")
    func everyFieldIsCompared() {
        let names = Set(ActivityRoundTrip.differingFields(
            ride(gearId: "a"),
            Activity(id: "19580875358", name: "x", sportType: "Run",
                     startLocal: "2020-01-01T00:00:00", distance: 1,
                     movingTime: 1, elapsedTime: 1, elevationGain: 1,
                     averageHeartrate: 1, isTrainer: true, maxHeartrate: 1,
                     gearId: "b", maxSpeed: 1, deviceWatts: false,
                     averageWatts: 1, startUTC: "2020-01-01T00:00:00Z",
                     startLat: 1, startLon: 1, timeZoneIdentifier: "UTC",
                     startOffsetSeconds: 0)))

        // Nineteen: every stored property except `id`, which is the key the
        // two sides are matched ON and cannot differ.
        #expect(names.count == 19, "found \(names.count) differing fields")
        for expected in ["name", "sportType", "startLocal", "startUTC", "distance",
                         "movingTime", "elapsedTime", "elevationGain",
                         "averageHeartrate", "maxHeartrate", "isTrainer", "gearId",
                         "maxSpeed", "deviceWatts", "averageWatts", "startLat",
                         "startLon", "timeZoneIdentifier", "startOffsetSeconds"] {
            #expect(names.contains(expected), "\(expected) is not compared")
        }
    }

    // MARK: Coverage it cannot provide

    /// A row with no `sportLabel` cannot become an `Activity` — `sportType` is
    /// not optional. It is COUNTED rather than dropped, because a reader
    /// quietly returning fewer rows than the table holds is what shadow parity
    /// would report as missing data.
    @Test("A row this reader cannot reconstitute is counted, not dropped")
    func anUnreadableRowIsCounted() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [])
        try db.queue.write { d in
            try d.execute(sql: "UPDATE activity SET sportLabel = NULL")
        }

        let load = ActivityRepository.all(db)
        #expect(load.isTrustworthy, "the read itself worked")
        #expect(load.activities?.isEmpty == true)
        #expect(load.skipped == 1)
        #expect(load.line.contains("1 rows could not be read"))
    }
}
