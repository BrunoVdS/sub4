//
//  RecordingRepositoryTests.swift
//  Sub4CoreTests
//
//  D6a's third reader — patch 292, ADR-0003 §12.38.
//
//  `theAbsentStreamStaysAbsent` is the one with teeth. `[Double]?` cannot hold
//  a per-element nil, so "this activity has no power meter" and "this activity
//  has power that happened to read zero" are one bit apart in the database and
//  a whole feature apart in the app — `has(_:)` decides whether a chart is
//  drawn at all.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct RecordingRepositoryTests {

    private let storeID = "19580875358"

    private func activity() -> Activity {
        Activity(id: storeID, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 24_300,
                 movingTime: 3_240, elapsedTime: 3_600,
                 elevationGain: 142, averageHeartrate: 131, isTrainer: false,
                 maxHeartrate: 168, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: true, averageWatts: 168,
                 startUTC: "2026-07-28T16:02:00Z", startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func streams(heartRate: [Double]? = [120, 131, 145],
                         power: [Double]? = nil,
                         latitude: [Double]? = nil,
                         fetched: Date = Date(timeIntervalSince1970: 1_785_000_000))
    -> ActivityStreams {
        ActivityStreams(activityId: storeID,
                        distanceM: [0, 500, 1000],
                        heartRate: heartRate,
                        speed: [3.1, 3.4, 3.3],
                        altitude: [12, 14, 11],
                        grade: [0, 1.2, -0.4],
                        power: power,
                        latitude: latitude,
                        longitude: nil,
                        fetched: fetched)
    }

    private func imported(_ s: ActivityStreams) throws -> (Sub4Database, ActivityStreams) {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity()], shoes: [],
                               streams: [s])
        let load = RecordingRepository.all(db)
        let list = try #require(load.recordings)
        #expect(load.skipped == 0)
        return (db, try #require(list.first))
    }

    // MARK: Nothing there is not could not look

    @Test("An empty database loads as empty, and says so")
    func emptyIsAnAnswer() throws {
        let db = try Sub4Database.inMemory()
        let load = RecordingRepository.all(db)
        #expect(load.isTrustworthy)
        #expect(load.recordings?.isEmpty == true)
        #expect(load.line == "0 recordings.")
    }

    @Test("An untrustworthy read hands back nothing, not an empty list")
    func untrustworthyIsNotEmpty() {
        for load: RecordingLoad in [.unavailable, .failed("locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.recordings == nil)
        }
    }

    // MARK: The round trip

    @Test("A recording survives the round trip")
    func theRecordingRoundTrips() throws {
        let original = streams()
        let (_, back) = try imported(original)

        #expect(back.activityId == original.activityId,
                "the store's id is Strava's, not the row's UUID")
        #expect(back.distanceM == original.distanceM)
        #expect(back.heartRate == original.heartRate)
        #expect(back.speed == original.speed, "speed is stored as speedMS")
        #expect(back.altitude == original.altitude, "stored as altitudeM")
        #expect(back.grade == original.grade, "stored as gradePercent")
        #expect(DetailRoundTrip.sameSecond(back.fetched, original.fetched))
    }

    /// THE ONE WITH TEETH. `has(_:)` decides whether a chart is drawn, and it
    /// tests `contains { $0 > 0 }` — so an absent stream and a stream of zeros
    /// are one bit apart in the database and a whole feature apart in the app.
    @Test("An absent stream stays absent, and a present one stays present")
    func theAbsentStreamStaysAbsent() throws {
        let (_, back) = try imported(streams(power: nil, latitude: nil))
        #expect(back.power == nil, "no power meter — every sample is NULL")
        #expect(back.latitude == nil)
        #expect(back.longitude == nil)
        #expect(back.heartRate != nil)
        #expect(back.has(.heartRate))
    }

    @Test("A present stream of real values comes back whole")
    func aPresentStreamComesBack() throws {
        let (_, back) = try imported(streams(power: [180, 220, 195]))
        #expect(back.power == [180, 220, 195])
    }

    /// `power` is stored in a column called `watts`. The rename most likely to
    /// be typed straight through, so it gets its own named test.
    @Test("Power comes back from the watts column")
    func powerComesFromWatts() throws {
        let (db, back) = try imported(streams(power: [180, 220, 195]))
        let stored = try db.queue.read { d in
            try Double.fetchAll(d, sql: "SELECT watts FROM recording_sample ORDER BY ordinal")
        }
        #expect(stored == [180, 220, 195])
        #expect(back.power == stored)
    }

    /// Ordinal is the array position here — third convention across four child
    /// tables — so order is the only thing it carries and it must survive.
    @Test("Samples come back in the order they went in")
    func orderSurvives() throws {
        let original = ActivityStreams(activityId: storeID,
                                       distanceM: [0, 100, 200, 300, 400],
                                       heartRate: [100, 110, 120, 130, 140],
                                       speed: nil, altitude: nil, grade: nil,
                                       power: nil, latitude: nil, longitude: nil,
                                       fetched: Date(timeIntervalSince1970: 1_785_000_000))
        let (_, back) = try imported(original)
        #expect(back.distanceM == [0, 100, 200, 300, 400])
        #expect(back.heartRate == [100, 110, 120, 130, 140])
    }

    // MARK: The lossy step, made visible

    /// A NULL inside a present stream becomes zero — `[Double]?` has nowhere
    /// else to put it, and zero is already what `has(_:)` reads as nothing.
    /// Asserted so the loss is a decision somebody made, not a surprise.
    @Test("A short stream comes back padded, and the original length is gone")
    func aShortStreamIsPadded() throws {
        // Three distances, two heart rates — `at(series, i)` writes NULL for
        // the third, and nothing on the way back can know the array was short.
        let original = ActivityStreams(activityId: storeID,
                                       distanceM: [0, 500, 1000],
                                       heartRate: [120, 131],
                                       speed: nil, altitude: nil, grade: nil,
                                       power: nil, latitude: nil, longitude: nil,
                                       fetched: Date(timeIntervalSince1970: 1_785_000_000))
        let (_, back) = try imported(original)
        #expect(back.heartRate?.count == 3, "padded to the length of distanceM")
        #expect(back.heartRate == [120, 131, 0])
        #expect(back.heartRate != original.heartRate,
                "a real loss, and the comparison should report it")
    }

    // MARK: One at a time

    /// The entry point the comparison uses: ids, then one recording each. 645
    /// recordings and 192,954 samples never need to be in memory together.
    @Test("The ids come back, and each one fetches its own recording")
    func idsThenOneAtATime() throws {
        let (db, _) = try imported(streams())

        guard case .success(let ids) = RecordingRepository.ids(db) else {
            Issue.record("ids failed"); return
        }
        #expect(ids == [storeID])

        let one = RecordingRepository.streams(db, storeID: storeID)
        #expect(one.recordings?.count == 1)
        #expect(one.recordings?.first?.distanceM.count == 3)
    }

    @Test("An id the database does not have is not a failure")
    func missingIDIsNotAFailure() throws {
        let (db, _) = try imported(streams())
        let none = RecordingRepository.streams(db, storeID: "99999999999")
        #expect(none.isTrustworthy)
        #expect(none.recordings?.isEmpty == true)
    }

    @Test("Another account's recordings are not this account's")
    func accountScoped() throws {
        let (db, _) = try imported(streams())
        let other = RecordingRepository.all(db, accountID: "someone-else")
        #expect(other.isTrustworthy)
        #expect(other.recordings?.isEmpty == true)
    }
}
