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

    // MARK: The bulk read reads them apart — patch 397, §12.141

    private func second() -> Activity {
        Activity(id: "19580875999", name: "Morning Run", sportType: "Run",
                 startLocal: "2026-07-29T07:00:00", distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_050,
                 elevationGain: 40, averageHeartrate: 148, isTrainer: false,
                 maxHeartrate: 172, gearId: nil, maxSpeed: 4.2,
                 deviceWatts: false, averageWatts: nil,
                 startUTC: "2026-07-29T05:00:00Z", startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    /// **THE ONE 397 ADDED THE RISK FOR.**
    ///
    /// The bulk read was 668 separate queries and is now one, grouped by a
    /// change of `recordingID` as the cursor walks. Every existing test in this
    /// file imports ONE recording, so the entire grouping step — the only new
    /// logic in the patch — was invisible to all of them.
    ///
    /// The failure it guards is not a crash: samples bleeding across the
    /// boundary give both traces plausible lengths and plausible values, and
    /// the charts would draw. Deliberately different lengths and disjoint
    /// values, so a bleed cannot look like a pass.
    @Test("Two recordings do not bleed into one another")
    func twoRecordingsDoNotBleed() throws {
        let db = try Sub4Database.inMemory()
        let a = streams()                                    // 3 samples
        let b = ActivityStreams(activityId: "19580875999",
                                distanceM: [0, 100, 200, 300, 400],
                                heartRate: [150, 151, 152, 153, 154],
                                speed: nil, altitude: nil, grade: nil,
                                power: nil, latitude: nil, longitude: nil,
                                fetched: Date(timeIntervalSince1970: 1_785_000_001))
        _ = try Sub4Import.run(into: db, activities: [activity(), second()],
                               shoes: [], streams: [a, b])

        let load = RecordingRepository.all(db)
        let list = try #require(load.recordings)
        #expect(load.skipped == 0)
        #expect(list.count == 2)

        let readA = try #require(list.first { $0.activityId == storeID })
        let readB = try #require(list.first { $0.activityId == "19580875999" })
        #expect(readA.distanceM == [0, 500, 1000], "the first trace kept its own samples")
        #expect(readB.distanceM == [0, 100, 200, 300, 400], "and so did the second")
        #expect(readA.heartRate == [120, 131, 145])
        #expect(readB.heartRate == [150, 151, 152, 153, 154])
        // AND THE ABSENCES ARE PER RECORDING TOO. `b` carries no speed; `a`
        // does. A grouping bug that shared the `carried` flags would give `b` a
        // speed array of zeros, which reads as a stopped athlete rather than as
        // a trace that never had the series. §12.38.4.
        #expect(readA.speed == [3.1, 3.4, 3.3])
        #expect(readB.speed == nil, "b never carried speed, and zeros are not absence")
    }

    /// A `recording` row whose samples are gone comes back as a trace of length
    /// zero — NOT missing from the list. `RecordingRoundTrip` compares the
    /// store's array length, `recording.sampleCount` and the rows actually
    /// present precisely to catch that, and a reader that dropped the row would
    /// hide it from the check written to find it.
    @Test("A recording with no samples is a length, not an absence")
    func aRecordingWithNoSamplesIsALength() throws {
        let (db, _) = try imported(streams())
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM recording_sample")
        }

        let load = RecordingRepository.all(db)
        let list = try #require(load.recordings)
        #expect(load.skipped == 0, "the head row read fine; it is the samples that are gone")
        #expect(list.count == 1, "the recording is still there to be asked about")
        #expect(list.first?.distanceM.isEmpty == true)
        #expect(list.first?.heartRate == nil, "no row carried it, so it is absent")
    }

    /// `all` and `streams(_:storeID:)` are two entry points over one decoder
    /// since 397 — §12.43. If they disagree, one of them is reading a column
    /// the other is not, and the bulk path is the one nothing else checks.
    @Test("The bulk read and the single read agree exactly")
    func theBulkAndSingleReadsAgree() throws {
        let (db, fromAll) = try imported(streams(power: [210, 215, 208],
                                                 latitude: [51.2, 51.21, 51.22]))
        let single = try #require(RecordingRepository
            .streams(db, storeID: storeID).recordings?.first)

        #expect(single.distanceM == fromAll.distanceM)
        #expect(single.heartRate == fromAll.heartRate)
        #expect(single.speed == fromAll.speed)
        #expect(single.altitude == fromAll.altitude)
        #expect(single.grade == fromAll.grade)
        #expect(single.power == fromAll.power)
        #expect(single.latitude == fromAll.latitude)
        #expect(single.longitude == fromAll.longitude)
        #expect(single.fetched == fromAll.fetched)
    }
}

// MARK: -

/// The recording comparison — patch 294, ADR-0003 §12.39.
///
/// `theFieldNameIsStableAcrossRecordings` is the one with teeth. The tally is
/// the whole point of a read-back — `fetched 320 of 668` was a diagnosis on
/// sight — and a tally groups by field name. Put the count IN the name and
/// every recording gets its own key, the tally becomes a list, and the screen
/// goes back to being a list of ids somebody has to open one at a time.
@Suite
@MainActor
struct RecordingRoundTripTests {

    /// `day` so two recordings in one test are two DIFFERENT sessions. Two
    /// activities at the same instant is a matcher question, and this suite is
    /// not asking one.
    private func activity(_ id: String, day: Int = 28) -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-\(day)T18:02:00", distance: 24_300,
                 movingTime: 3_240, elapsedTime: 3_600,
                 elevationGain: 142, averageHeartrate: 131, isTrainer: false,
                 maxHeartrate: 168, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: true, averageWatts: 168,
                 startUTC: "2026-07-\(day)T16:02:00Z", startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func streams(_ id: String,
                         distanceM: [Double] = [0, 500, 1000],
                         heartRate: [Double]? = [120, 131, 145],
                         power: [Double]? = nil,
                         fetched: Date = Date(timeIntervalSince1970: 1_785_000_000))
    -> ActivityStreams {
        ActivityStreams(activityId: id,
                        distanceM: distanceM,
                        heartRate: heartRate,
                        speed: [3.1, 3.4, 3.3],
                        altitude: [12, 14, 11],
                        grade: [0, 1.2, -0.4],
                        power: power,
                        latitude: nil, longitude: nil,
                        fetched: fetched)
    }

    private func imported(_ s: [ActivityStreams]) throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        let activities = s.enumerated().map { i, x in activity(x.activityId, day: 10 + i) }
        _ = try Sub4Import.run(into: db, activities: activities,
                               shoes: [], streams: s)
        return db
    }

    // MARK: The whole run, against the importer

    @Test("A recording that went in unchanged agrees on every sample")
    func theRealRoundTripAgrees() throws {
        let one = streams("19580875358")
        let db = try imported([one])
        let r = RecordingRoundTrip.compare(db, store: [one])

        #expect(r.isTrustworthy)
        #expect(r.databaseCount == 1)
        #expect(r.compared == 1)
        #expect(r.agreed == 1)
        #expect(r.differences.isEmpty)
        #expect(r.missing.isEmpty)
        #expect(r.samplesWalked == 3 * 5, "distance, heart rate, speed, altitude, grade")
    }

    /// THE ONE WITH TEETH. Two recordings, the same defect, different ids —
    /// and it has to land under ONE key or the tally is a list.
    @Test("The field name is stable across recordings, so the tally adds up")
    func theFieldNameIsStableAcrossRecordings() throws {
        let a = streams("1"), b = streams("2")
        let db = try imported([a, b])
        try db.queue.write { d in
            try d.execute(sql: "UPDATE recording_sample SET heartRate = 999 WHERE ordinal = 0")
        }

        let r = RecordingRoundTrip.compare(db, store: [a, b])
        #expect(r.compared == 2)
        #expect(r.agreed == 0)

        #expect(r.fieldTally.map(\.field) == ["heartRate"],
                "one key, not one per recording")
        #expect(r.fieldTally.map(\.count) == [2])

        // How WIDE and how DEEP are different numbers, and both are here.
        #expect(r.sampleTally.map(\.stream) == ["heartRate"])
        #expect(r.sampleTally.map(\.differing) == [2])
        #expect(r.sampleTally.map(\.walked) == [6], "3 samples × 2 recordings")

        // The count lives in the printed line, where it is unique on purpose.
        #expect(r.differences.allSatisfy { $0.detail.contains("heartRate[1 of 3]") })
    }

    @Test("A recording the database does not have is missing, not different")
    func missingIsNotDifferent() throws {
        let there = streams("1")
        let db = try imported([there])
        let absent = streams("2")

        let r = RecordingRoundTrip.compare(db, store: [there, absent])
        #expect(r.compared == 1)
        #expect(r.missing == ["2"])
        #expect(r.differences.isEmpty)
    }

    /// §12.39.1's third number. Deleting a sample leaves the header claiming a
    /// count the table no longer has — a different defect from an array that
    /// arrived short, and indistinguishable from it without `sampleCount`.
    @Test("Rows lost after the header was written are named as that")
    func rowsLostAfterTheHeaderAreNamed() throws {
        let one = streams("19580875358")
        let db = try imported([one])
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM recording_sample WHERE ordinal = 2")
        }

        let r = RecordingRoundTrip.compare(db, store: [one])
        let fields = try #require(r.differences.first?.fields)
        #expect(fields.contains("sampleCount vs rows"),
                "the header says 3 and the table holds 2")
        #expect(fields.contains("sampleCount"),
                "and the store says 3 as well")
        #expect(!fields.contains("heartRate"),
                "the walk is skipped — one lost row must not report as three")
    }

    /// §12.38.4, now measured rather than asserted in isolation. A stream
    /// shorter than the distance axis is padded on the way in and cannot be
    /// unpadded on the way out.
    @Test("A short stream comes back as a length difference, not as zeros")
    func theShortStreamShowsAsALength() throws {
        let short = streams("19580875358", heartRate: [120, 131])
        let db = try imported([short])

        let r = RecordingRoundTrip.compare(db, store: [short])
        #expect(r.compared == 1)
        #expect(r.fieldTally.map(\.field) == ["heartRate length"])
        #expect(r.differences.first?.detail
                    .contains("heartRate: 2 in the store, 3 in the database") == true)
        #expect(r.sampleTally.isEmpty,
                "a length mismatch has no denominator, so it contributes no band")
    }

    @Test("The declared counts are what the importer wrote")
    func declaredCountsAreWhatWasWritten() throws {
        let db = try imported([streams("1"), streams("2", distanceM: [0, 100])])
        guard case .success(let counts) = RecordingRepository.declaredCounts(db) else {
            Issue.record("declaredCounts failed"); return
        }
        #expect(counts == ["1": 3, "2": 2])
    }

    // MARK: One recording, without a database

    @Test("Identical sides agree")
    func identicalSidesAgree() {
        let s = streams("1")
        #expect(RecordingRoundTrip.compareOne(s, s).agrees)
    }

    /// The gate. One sample missing near the start shifts every later one.
    @Test("The length gate stops the walk")
    func theLengthGateStopsTheWalk() {
        let s = streams("1")
        let d = streams("1", distanceM: [0, 500, 1000, 1500],
                        heartRate: [9, 9, 9, 9])
        let c = RecordingRoundTrip.compareOne(s, d)
        #expect(c.fields == ["sampleCount"])
        #expect(c.walked.isEmpty, "nothing was walked, so nothing claims to have been")
        #expect(c.line.contains("3 samples in the store, 4 in the database"))
    }

    /// §12.38.5. Absent and all-zero are one bit apart in the database and a
    /// whole feature apart in the app, so they get different names.
    @Test("A stream present on one side only is a stream, not a sample")
    func presenceIsNotASample() {
        let withPower = streams("1", power: [180, 220, 195])
        let without = streams("1", power: nil)

        let lost = RecordingRoundTrip.compareOne(withPower, without)
        #expect(lost.fields == ["power missing from the database"])
        #expect(lost.differing["power"] == nil, "no samples differed — there are none")

        let gained = RecordingRoundTrip.compareOne(without, withPower)
        #expect(gained.fields == ["power surplus in the database"])
    }

    /// 291a's lesson, carried across: the writer truncates, so the comparison
    /// truncates. Rounding here cost 320 phantom differences on the details.
    @Test("The fetched date is compared to the truncated second")
    func fetchedIsTruncated() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        let s = streams("1", fetched: base)
        let d = streams("1", fetched: base.addingTimeInterval(0.6))
        #expect(RecordingRoundTrip.compareOne(s, d).agrees,
                "a fraction of a second cannot reach the column")

        let later = streams("1", fetched: base.addingTimeInterval(2))
        #expect(RecordingRoundTrip.compareOne(s, later).fields == ["fetched"])
    }

    /// A timestamp is comparable whatever the lengths do, so it is checked
    /// before the gate rather than lost behind it.
    @Test("A date difference survives a length difference")
    func theDateIsCheckedBeforeTheGate() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        let s = streams("1", fetched: base)
        let d = streams("1", distanceM: [0, 500], heartRate: [120, 131],
                        fetched: base.addingTimeInterval(90))
        let c = RecordingRoundTrip.compareOne(s, d)
        #expect(c.fields.contains("fetched"))
        #expect(c.fields.contains("sampleCount"))
    }

    // MARK: The report's own honesty

    /// The first read is the id read, and if it fails everything under it is
    /// unknown rather than zero — the fifth instance of §12.15's shape.
    @Test("A failed read is not a comparison of nothing")
    func aFailedReadIsNotZero() {
        var r = RecordingRoundTrip.Report()
        r.readFailure = "the file is locked"
        #expect(!r.isTrustworthy)
        #expect(r.databaseCount == nil, "not 0 — nobody counted")
        #expect(r.line.contains("could not be read"))
    }

    @Test("An empty database is a trustworthy zero")
    func emptyIsTrustworthy() throws {
        let db = try Sub4Database.inMemory()
        let r = RecordingRoundTrip.compare(db, store: [])
        #expect(r.isTrustworthy)
        #expect(r.databaseCount == 0)
        #expect(r.line == "0 recordings in the database.")
        #expect(r.compared == 0)
    }
}

// MARK: -

/// What the report could not say — patch 298, ADR-0003 §12.42.
///
/// `aFetchedDifferenceSaysBothDates` is the one with teeth, and it is a test
/// about a string again. On 7 August the screen said `17463863070 — fetched
/// differs` and the import thirty seconds later said `0 replaced`. The importer
/// compared the same field and called it unchanged. One of them was wrong and
/// the report did not carry enough to tell which — which is the whole failure,
/// because the report exists to be the thing that tells you.
@Suite
@MainActor
struct RecordingReportHonestyTests {

    private let storeID = "19580875358"

    private func streams(_ id: String, fetched: Date) -> ActivityStreams {
        ActivityStreams(activityId: id, distanceM: [0, 500, 1000],
                        heartRate: [120, 131, 145],
                        speed: nil, altitude: nil, grade: nil,
                        power: nil, latitude: nil, longitude: nil,
                        fetched: fetched)
    }

    // MARK: The date

    /// THE ONE WITH TEETH.
    @Test("A fetched difference says both dates, not that there is one")
    func aFetchedDifferenceSaysBothDates() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        let s = streams("1", fetched: base)
        let d = streams("1", fetched: base.addingTimeInterval(90))

        let c = RecordingRoundTrip.compareOne(s, d)
        #expect(c.fields == ["fetched"], "the tally key stays stable — §12.39.2")
        #expect(c.line.contains(Sub4Import.iso8601(base)),
                "the store's value is printed")
        #expect(c.line.contains(Sub4Import.iso8601(base.addingTimeInterval(90))),
                "and the database's, so the two can be compared by eye")
    }

    /// A COLUMN THAT COULD NOT BE READ IS NOT A DISAGREEMENT ABOUT ITS VALUE.
    /// `build` writes `unreadableDate` when `parseUTC` fails, and before 298
    /// that arrived as an ordinary `fetched` difference — a reader defect
    /// wearing a data difference's clothes.
    @Test("An unparseable timestamp is named as unparseable")
    func anUnreadableDateIsItsOwnAnswer() {
        let s = streams("1", fetched: Date(timeIntervalSince1970: 1_785_000_000))
        let d = streams("1", fetched: RecordingRepository.unreadableDate)

        let c = RecordingRoundTrip.compareOne(s, d)
        #expect(c.fields == ["fetched unreadable"])
        #expect(!c.fields.contains("fetched"),
                "the two must never arrive under the same key")
        #expect(c.line.contains("could not be parsed"))
    }

    @Test("Matching dates say nothing at all")
    func agreementIsSilent() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)
        let c = RecordingRoundTrip.compareOne(streams("1", fetched: base),
                                              streams("1", fetched: base))
        #expect(c.agrees)
    }

    // MARK: Absent on purpose

    /// `DataCorrections` refuses two sessions; `Sub4Import` declines their
    /// traces; `DetailStore` keeps them because it keys by Strava id. So the
    /// store permanently holds recordings the database will never have, and
    /// counting those as missing is a red row that is correct for ever.
    @Test("A deliberately excluded recording is excluded, not missing")
    func excludedIsNotMissing() throws {
        let db = try Sub4Database.inMemory()
        let ignored = try #require(DataCorrections.ignoredActivities.keys.sorted().first)
        let base = Date(timeIntervalSince1970: 1_785_000_000)

        let r = RecordingRoundTrip.compare(db, store: [
            streams(ignored, fetched: base),
            streams("99999999999", fetched: base),
        ])
        #expect(r.excluded == [ignored])
        #expect(r.missing == ["99999999999"],
                "a recording nobody excluded is still a shortfall")
    }

    @Test("Nothing excluded is an empty list, not a zero")
    func noExclusionsIsEmpty() throws {
        let db = try Sub4Database.inMemory()
        let r = RecordingRoundTrip.compare(db, store: [])
        #expect(r.excluded.isEmpty)
        #expect(r.missing.isEmpty)
    }
}


