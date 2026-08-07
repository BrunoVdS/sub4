//
//  ActivityDetailRepositoryTests.swift
//  Sub4CoreTests
//
//  D6a's second reader — patch 291, ADR-0003 §12.37.
//
//  `theOrdinalMeansWhatItMeans` is the one with teeth. All three child tables
//  carry an `ordinal`; in two of them it is a domain value and in the third it
//  is array position. Getting that backwards gives splits numbered from zero
//  or best efforts in whatever order SQLite chose — and NEITHER fails a count
//  comparison, which is §12.16's warning exactly.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct ActivityDetailRepositoryTests {

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

    private func split(_ index: Int, hr: Double? = 142) -> ActivityDetail.Split {
        .init(index: index, distanceM: 1000, movingTime: 300 + index,
              elapsedTime: 310 + index, elevationDiff: 4.5, averageHR: hr)
    }

    private func detail(splits: [ActivityDetail.Split]? = nil,
                        efforts: [ActivityDetail.BestEffort]? = nil,
                        laps: [ActivityDetail.Lap]? = nil,
                        fetched: Date = Date(timeIntervalSince1970: 1_785_000_000))
    -> ActivityDetail {
        ActivityDetail(activityId: storeID,
                       calories: 812, descriptionText: "Windy.",
                       averageCadence: 84, averageWatts: 168, maxWatts: 402,
                       deviceName: "Garmin Edge", polyline: "abc123",
                       splits: splits ?? [split(1), split(2), split(3)],
                       bestEfforts: efforts ?? [.init(name: "400m", seconds: 71),
                                                .init(name: "1k", seconds: 195),
                                                .init(name: "5k", seconds: 1080)],
                       laps: laps ?? [.init(index: 1, distanceM: 5000,
                                            movingTime: 1200, averageHR: 138)],
                       fetched: fetched)
    }

    private func loaded(_ db: Sub4Database) throws -> ActivityDetail {
        let load = ActivityDetailRepository.all(db)
        let list = try #require(load.details)
        #expect(load.skipped == 0)
        return try #require(list.first)
    }

    // MARK: Nothing there is not could not look

    @Test("An empty database loads as empty, and says so")
    func emptyIsAnAnswer() throws {
        let db = try Sub4Database.inMemory()
        let load = ActivityDetailRepository.all(db)
        #expect(load.isTrustworthy)
        #expect(load.details?.isEmpty == true)
        #expect(load.line == "0 details.")
    }

    @Test("An untrustworthy read hands back nothing, not an empty list")
    func untrustworthyIsNotEmpty() {
        for load: DetailLoad in [.unavailable, .failed("locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.details == nil)
        }
    }

    // MARK: The round trip

    @Test("A detail survives the round trip, field by field")
    func theDetailRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = detail()
        _ = try Sub4Import.run(into: db, activities: [activity()], shoes: [],
                               details: [original])

        let back = try loaded(db)
        #expect(back.activityId == original.activityId,
                "the store's id is Strava's, not the row's UUID")
        #expect(back.calories == original.calories)
        #expect(back.descriptionText == original.descriptionText)
        #expect(back.averageCadence == original.averageCadence)
        #expect(back.averageWatts == original.averageWatts)
        #expect(back.maxWatts == original.maxWatts)
        #expect(back.deviceName == original.deviceName)
        #expect(back.polyline == original.polyline)
        #expect(DetailRoundTrip.sameSecond(back.fetched, original.fetched),
                "fetchedUTC is second-precision by construction")

        #expect(DetailRoundTrip.differingFields(original, back).isEmpty,
                "nothing at all should differ")
    }

    /// THE ONE WITH TEETH.
    @Test("The ordinal means what it means, in each table")
    func theOrdinalMeansWhatItMeans() throws {
        let db = try Sub4Database.inMemory()
        let original = detail(splits: [split(1), split(2), split(3)],
                              efforts: [.init(name: "400m", seconds: 71),
                                        .init(name: "1k", seconds: 195)])
        _ = try Sub4Import.run(into: db, activities: [activity()], shoes: [],
                               details: [original])
        let back = try loaded(db)

        // Splits and laps: the ordinal IS the domain index, 1-based.
        #expect(back.splits.map(\.index) == [1, 2, 3],
                "split.index comes from ordinal and is 1-based, not 0-based")
        #expect(back.laps.map(\.index) == [1])

        // Best efforts: the ordinal is array POSITION and belongs nowhere in
        // the struct — it survives only as the order.
        #expect(back.bestEfforts.map(\.name) == ["400m", "1k"],
                "ordered by ordinal, which for efforts is the array position")
    }

    @Test("Every element of every array comes back")
    func everyElementComesBack() throws {
        let db = try Sub4Database.inMemory()
        let original = detail(splits: (1...12).map { split($0) })
        _ = try Sub4Import.run(into: db, activities: [activity()], shoes: [],
                               details: [original])
        let back = try loaded(db)
        #expect(back.splits.count == 12)
        #expect(back.bestEfforts.count == 3)
        #expect(back.laps.count == 1)
    }

    /// The importer writes `positiveOrNil` for both split and lap heart rate,
    /// so a stored zero comes back nil. REPORTED, not papered over — a reader
    /// that invented a zero to make this pass would be lying to make a
    /// comparison green.
    @Test("A zero heart rate is normalised by the importer, and it shows")
    func theZeroHeartRateLossIsReported() throws {
        let db = try Sub4Database.inMemory()
        let original = detail(splits: [split(1, hr: 0)])
        _ = try Sub4Import.run(into: db, activities: [activity()], shoes: [],
                               details: [original])
        let back = try loaded(db)

        #expect(back.splits.first?.averageHR == nil)
        #expect(DetailRoundTrip.differingFields(original, back)
                    == ["splits[index: 1].averageHR"],
                "the loss is named, and named precisely")
    }

    // MARK: The comparison

    @Test("Identical sides agree")
    func identicalSidesAgree() {
        let d = detail()
        let r = DetailRoundTrip.compare(store: [d], database: [d])
        #expect(r.compared == 1)
        #expect(r.agreed == 1)
        #expect(r.differences.isEmpty)
    }

    /// Matching by identity is what makes this message readable: a kilometre
    /// you can open, not an array slot.
    @Test("A differing split names its index, not its position")
    func aDifferingSplitNamesItsIndex() {
        let store = detail(splits: [split(1), split(2), split(3)])
        let db = detail(splits: [split(1), split(2),
                                 .init(index: 3, distanceM: 1000, movingTime: 999,
                                       elapsedTime: 313, elevationDiff: 4.5,
                                       averageHR: 142)])
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        #expect(r.differences.first?.fields == ["splits[index: 3].movingTime"])
    }

    /// Order is irrelevant once elements are matched by identity — which is
    /// the whole reason the ordering question was removed rather than answered.
    @Test("A different array order is not a difference")
    func orderIsNotADifference() {
        let store = detail(splits: [split(1), split(2), split(3)])
        let shuffled = detail(splits: [split(3), split(1), split(2)],
                              efforts: [.init(name: "5k", seconds: 1080),
                                        .init(name: "400m", seconds: 71),
                                        .init(name: "1k", seconds: 195)])
        let r = DetailRoundTrip.compare(store: [store], database: [shuffled])
        #expect(r.differences.isEmpty, "same elements, different order")
    }

    @Test("Missing and surplus elements are neither differences nor each other")
    func missingAndSurplusAreDistinct() {
        let store = detail(splits: [split(1), split(2)])
        let db = detail(splits: [split(1), split(9)])
        let fields = DetailRoundTrip.differingFields(store, db)
        #expect(fields.contains("splits missing 2"))
        #expect(fields.contains("splits surplus 9"))
        #expect(!fields.contains { $0.hasPrefix("splits[index:") },
                "a missing element has no fields to differ on")
    }

    @Test("A detail the database does not have is missing, not different")
    func missingDetailIsNotDifferent() {
        let a = detail()
        let r = DetailRoundTrip.compare(store: [a], database: [])
        #expect(r.compared == 0)
        #expect(r.missing == [storeID])
        #expect(r.differences.isEmpty)
    }

    @Test("A best effort is matched by name")
    func effortsMatchOnName() {
        let store = detail(efforts: [.init(name: "1k", seconds: 195)])
        let db = detail(efforts: [.init(name: "1k", seconds: 200)])
        #expect(DetailRoundTrip.differingFields(store, db)
                    == ["bestEfforts[1k].seconds"])
    }

    /// Sub-second precision cannot reach the column, so the comparison must
    /// not demand it.
    /// TRUNCATED, NOT ROUNDED — 291a. The writer drops the fraction, so the
    /// comparison must too. Rounding reported 320 of 668 details as differing
    /// on `fetched` when nothing differed at all.
    @Test("Dates are compared by truncation, the way the writer stores them")
    func datesAreTruncatedNotRounded() {
        let base = Date(timeIntervalSince1970: 1_785_000_000)

        // The case that was broken: a fraction of 0.5 or more. The writer
        // stores `base`; rounding turned this into base + 1.
        #expect(DetailRoundTrip.sameSecond(base.addingTimeInterval(0.6), base),
                "x.6 is written as x and must compare equal to x")
        #expect(DetailRoundTrip.sameSecond(base.addingTimeInterval(0.999), base))

        #expect(DetailRoundTrip.sameSecond(base, base.addingTimeInterval(0.3)))
        #expect(!DetailRoundTrip.sameSecond(base, base.addingTimeInterval(2)))
        // A whole second apart is still a difference, from either side.
        #expect(!DetailRoundTrip.sameSecond(base.addingTimeInterval(1), base))
    }
}

// MARK: -

/// The tally, after the first real run — patch 295, ADR-0003 §12.40.
///
/// `oneCauseIsOneRow` is the one with teeth, and it is a test about grouping
/// rather than about data. Thirteen details differed on the device for a single
/// known reason and the tally printed twenty-five keys with a "+ 13 more
/// fields" cut-off underneath. Every one of those keys was correct. The tally
/// was still useless, which is the whole point: a correct summary that cannot
/// be read is a summary that will be ignored, and then trusted when it is
/// finally read wrong.
@Suite
@MainActor
struct DetailTallyTests {

    private func lap(_ index: Int, hr: Double?) -> ActivityDetail.Lap {
        .init(index: index, distanceM: 1000, movingTime: 300, averageHR: hr)
    }

    private func detail(_ id: String,
                        laps: [ActivityDetail.Lap] = [],
                        splits: [ActivityDetail.Split] = [],
                        efforts: [ActivityDetail.BestEffort] = [],
                        calories: Double? = 812) -> ActivityDetail {
        ActivityDetail(activityId: id, calories: calories,
                       splits: splits, bestEfforts: efforts, laps: laps,
                       fetched: Date(timeIntervalSince1970: 1_785_000_000))
    }

    // MARK: The key

    @Test("The tally key drops the element identity and keeps the field")
    func theTallyKeyCollapses() {
        #expect(DetailRoundTrip.tallyKey("laps[index: 12].averageHR")
                    == "laps[*].averageHR")
        #expect(DetailRoundTrip.tallyKey("splits[index: 3].movingTime")
                    == "splits[*].movingTime")
        #expect(DetailRoundTrip.tallyKey("bestEfforts[1k].seconds")
                    == "bestEfforts[*].seconds")
        #expect(DetailRoundTrip.tallyKey("splits missing 12") == "splits missing")
        #expect(DetailRoundTrip.tallyKey("bestEfforts surplus 1500m")
                    == "bestEfforts surplus")
    }

    /// A scalar has no element identity to drop, and must come through whole.
    /// `fetched` collapsing to something else would have hidden 291a.
    @Test("A scalar field is its own key")
    func aScalarIsUnchanged() {
        for name in ["calories", "fetched", "polyline", "descriptionText"] {
            #expect(DetailRoundTrip.tallyKey(name) == name)
        }
    }

    // MARK: The tally

    /// THE ONE WITH TEETH. One cause, many laps, two details — one row.
    @Test("One cause across many laps is one tally row, not many")
    func oneCauseIsOneRow() {
        let storeA = detail("a", laps: [lap(1, hr: 140), lap(2, hr: 141), lap(3, hr: 142)])
        let dbA = detail("a", laps: [lap(1, hr: nil), lap(2, hr: nil), lap(3, hr: nil)])
        let storeB = detail("b", laps: [lap(1, hr: 150), lap(2, hr: 151)])
        let dbB = detail("b", laps: [lap(1, hr: nil), lap(2, hr: nil)])

        let r = DetailRoundTrip.compare(store: [storeA, storeB],
                                        database: [dbA, dbB])
        #expect(r.compared == 2)
        #expect(r.agreed == 0)

        #expect(r.fieldTally.map(\.field) == ["laps[*].averageHR"],
                "one cause, one row — not five")
        #expect(r.fieldTally.map(\.details) == [2], "two details carry it")
        #expect(r.fieldTally.map(\.elements) == [5], "across five laps")
    }

    /// Wide and deep are different questions and the row answers both. Two
    /// details off by one lap each, and one detail off by four, are the same
    /// `details` and nothing alike.
    @Test("Details and elements are counted separately")
    func detailsAndElementsAreDifferentNumbers() {
        let store = detail("a", laps: [lap(1, hr: 140), lap(2, hr: 141),
                                       lap(3, hr: 142), lap(4, hr: 143)])
        let db = detail("a", laps: [lap(1, hr: nil), lap(2, hr: nil),
                                    lap(3, hr: nil), lap(4, hr: nil)])
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        #expect(r.fieldTally.map(\.details) == [1])
        #expect(r.fieldTally.map(\.elements) == [4])
    }

    /// The tally collapses; the difference does not. §12.37.2 chose identity
    /// over position so a reader could open the lap, and that has to survive
    /// the fix to the thing above it.
    @Test("The difference keeps the index the tally drops")
    func theDifferenceKeepsTheIndex() {
        let store = detail("a", laps: [lap(7, hr: 140)])
        let db = detail("a", laps: [lap(7, hr: nil)])
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        #expect(r.differences.first?.fields == ["laps[index: 7].averageHR"])
        #expect(r.fieldTally.map(\.field) == ["laps[*].averageHR"])
    }

    /// Two genuinely different causes must stay two rows. A collapse that
    /// merged everything would read even more cleanly and say nothing.
    @Test("Different fields stay different rows")
    func differentFieldsStayApart() {
        let store = detail("a", laps: [lap(1, hr: 140)], calories: 812)
        let db = detail("a", laps: [lap(1, hr: nil)], calories: 900)
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        #expect(Set(r.fieldTally.map(\.field))
                    == ["laps[*].averageHR", "calories"])
    }

    /// Missing and surplus carry a count in the name too, and it is the same
    /// problem: twelve missing splits should not be twelve rows.
    @Test("Missing and surplus collapse, and stay distinct from each other")
    func missingAndSurplusCollapse() {
        let store = detail("a", splits: [
            .init(index: 1, distanceM: 1000, movingTime: 300, elapsedTime: 310,
                  elevationDiff: 0, averageHR: 140),
            .init(index: 2, distanceM: 1000, movingTime: 300, elapsedTime: 310,
                  elevationDiff: 0, averageHR: 141)])
        let db = detail("a", splits: [
            .init(index: 8, distanceM: 1000, movingTime: 300, elapsedTime: 310,
                  elevationDiff: 0, averageHR: 140),
            .init(index: 9, distanceM: 1000, movingTime: 300, elapsedTime: 310,
                  elevationDiff: 0, averageHR: 141)])
        let r = DetailRoundTrip.compare(store: [store], database: [db])
        let keys = Set(r.fieldTally.map(\.field))
        #expect(keys == ["splits missing", "splits surplus"])
        #expect(r.fieldTally.allSatisfy { $0.elements == 2 })
        #expect(r.fieldTally.allSatisfy { $0.details == 1 })
    }

    @Test("Nothing differing is an empty tally, not a zero row")
    func agreementIsAnEmptyTally() {
        let d = detail("a", laps: [lap(1, hr: 140)])
        let r = DetailRoundTrip.compare(store: [d], database: [d])
        #expect(r.agreed == 1)
        #expect(r.fieldTally.isEmpty)
    }

    /// Ordered by how many details carry it, so the biggest cause is first —
    /// which is what makes the top row readable without scrolling.
    @Test("The biggest cause is first")
    func orderedByReach() {
        let store = [detail("a", laps: [lap(1, hr: 140)], calories: 812),
                     detail("b", laps: [lap(1, hr: 150)], calories: 812),
                     detail("c", laps: [lap(1, hr: 160)], calories: 812)]
        let db = [detail("a", laps: [lap(1, hr: nil)], calories: 812),
                  detail("b", laps: [lap(1, hr: nil)], calories: 812),
                  detail("c", laps: [lap(1, hr: 160)], calories: 900)]
        let r = DetailRoundTrip.compare(store: store, database: db)
        #expect(r.fieldTally.map(\.field) == ["laps[*].averageHR", "calories"])
        #expect(r.fieldTally.map(\.details) == [2, 1])
    }
}

