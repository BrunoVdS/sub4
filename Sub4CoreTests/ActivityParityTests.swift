//
//  ActivityParityTests.swift
//  Sub4CoreTests
//
//  D6c slice 1 — patch 312, groundwork §2.1, ADR-0003 §12.56.
//
//  THIS FILE IS THE NEGATIVE CONTROL, AND THAT IS ITS WHOLE JOB.
//
//  The groundwork says the first comparison will almost certainly report zero
//  differences, because D6a already proved both sides hold the same 672
//  activities and both sides now pass through the same rules. A check whose
//  answer is always "no differences" cannot be told from a check that is
//  broken — and D7 would be flipped on the strength of it.
//
//  So every test below except two hands the comparison a difference that is
//  KNOWN to exist and demands it be reported: one activity missing, one extra,
//  a swapped pair, one moved to another day, one on a different clock, one the
//  rules refuse, and a store holding a list its own rules would change.
//
//  BOTH SIDES ARE BUILT FROM DIFFERENT PLACES. Every test writes through the
//  real `Sub4Import` and reads back through the real `ActivityRepository`, then
//  perturbs the STORE side. Groundwork §2.1's third failure — both sides
//  secretly being the same object — has no runtime answer, and constructing
//  them this way is the only answer there is.
//
//  `nothingComparedIsNotAgreement` is the one with teeth. Zero compared against
//  zero agrees perfectly, and a screen reporting that as healthy would be the
//  green tick that means nothing.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct ActivityParityTests {

    /// Every test states its own offset. A test that reads the machine's clock
    /// passes on the machine that wrote it and proves nothing — §12.48.5.
    private let offset = 3_600

    private nonisolated struct NoRows: Error {}

    private func ride(_ id: String, at startLocal: String,
                      movingTime: Int = 3_600, distance: Double = 24_300,
                      sport: String = "Ride", offsetSeconds: Int = 7_200) -> Activity {
        Activity(id: id, name: "Ride", sportType: sport,
                 startLocal: startLocal, distance: distance,
                 movingTime: movingTime, elapsedTime: movingTime + 300,
                 elevationGain: 100, averageHeartrate: 130, isTrainer: false,
                 maxHeartrate: 160, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: false, averageWatts: nil,
                 startUTC: startLocal + "Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: "Europe/Brussels",
                 startOffsetSeconds: offsetSeconds)
    }

    /// Through the real importer and the real reader. The database side of
    /// every test below comes out of here and never out of the same array the
    /// store side was built from.
    private func imported(_ activities: [Activity]) throws -> (rows: [Activity], skipped: Int) {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: activities, shoes: [])
        let load = ActivityRepository.all(db)
        guard let rows = load.activities else { throw NoRows() }
        return (rows, load.skipped)
    }

    private func three() -> [Activity] {
        [ride("c", at: "2026-04-23T09:00:00"),
         ride("b", at: "2026-04-22T09:00:00"),
         ride("a", at: "2026-04-21T09:00:00")]
    }

    // MARK: The boring case, which is the one that runs every day

    @Test("The same activities through both paths agree, and say how many")
    func identicalListsAgree() throws {
        let store = three()
        let db = try imported(store)

        let r = ActivityParity.compare(store: store, databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(r.common == 3, "the denominator, without which zero says nothing")
        #expect(r.unexplained == 0)
        #expect(r.lookedAtSomething)
        #expect(r.storeOnly.isEmpty)
        #expect(r.databaseOnly.isEmpty)
        #expect(r.orderDiffered == 0)
        #expect(r.daysCompared == 3)
        #expect(r.zonesAgree)
        #expect(r.storeIsSettled)
        #expect(r.databaseSkipped == 0, "every row reconstituted")
        #expect(r.isHealthy)
    }

    /// THE ONE WITH TEETH. Zero compared against zero agrees perfectly and
    /// proves nothing — groundwork §2.1 case 2. The report has to refuse to be
    /// read as healthy.
    @Test("Comparing nothing is not agreement")
    func nothingComparedIsNotAgreement() throws {
        let db = try imported([])
        let r = ActivityParity.compare(store: [], databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(r.common == 0)
        #expect(r.unexplained == 0, "nothing disagreed, because nothing was looked at")
        #expect(!r.lookedAtSomething)
        #expect(r.summary.hasPrefix("nothing compared"))
        #expect(!r.isHealthy, "a comparison of nothing must not read as a pass")
    }

    // MARK: The negative controls

    @Test("An activity the database does not have is reported")
    func oneMissingFromTheDatabaseIsReported() throws {
        let store = three()
        let db = try imported(Array(store.dropLast()))

        let r = ActivityParity.compare(store: store, databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(r.storeOnly == ["a"])
        #expect(r.databaseOnly.isEmpty)
        #expect(r.common == 2, "the two they share")
        #expect(r.unexplained > 0)
        #expect(!r.isHealthy)
    }

    @Test("An activity only the database has is reported")
    func oneExtraInTheDatabaseIsReported() throws {
        let store = three()
        let db = try imported(store + [ride("d", at: "2026-04-24T09:00:00")])

        let r = ActivityParity.compare(store: store, databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(r.databaseOnly == ["d"])
        #expect(r.storeOnly.isEmpty)
        #expect(r.databaseKept == 4)
        #expect(r.common == 3)
    }

    /// ORDER IS THE THING D6a CANNOT SEE. Both sides hold the same three
    /// records with every field agreeing; only the sequence differs, and the
    /// sequence is what every screen in this app reads.
    @Test("A swapped pair is reported as order, not as missing activities")
    func aSwappedPairIsReportedAsOrder() throws {
        let correct = three()
        let db = try imported(correct)
        // Same three, two of them the wrong way round.
        let store = [correct[0], correct[2], correct[1]]

        let r = ActivityParity.compare(store: store, databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(r.storeOnly.isEmpty, "nothing is missing — only the order moved")
        #expect(r.databaseOnly.isEmpty)
        #expect(r.orderCompared == 3, "the denominator beside the difference")
        #expect(r.orderDiffered == 2)
        #expect(r.firstOrderDisagreement == 1)
        #expect(!r.storeIsSettled, "the store's own rules would re-sort that list")
    }

    /// `dayKey` is `startLocal.prefix(10)`, and the day is what `activities(on:)`
    /// keys on — so an activity in the wrong bucket is invisible to every field
    /// comparison and visible to every screen.
    @Test("An activity in a different day bucket is reported")
    func aMovedActivityChangesTheBuckets() throws {
        let db = try imported(three())
        // Same ids, same fields — one of them a day later on the store side.
        let store = [ride("c", at: "2026-04-23T09:00:00"),
                     ride("b", at: "2026-04-22T09:00:00"),
                     ride("a", at: "2026-04-20T09:00:00")]

        let r = ActivityParity.compare(store: store, databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(r.storeOnly.isEmpty, "the same three activities")
        #expect(r.daysOnlyInStore == ["2026-04-20"])
        #expect(r.daysOnlyInDatabase == ["2026-04-21"])
        #expect(r.daysCompared == 2, "the two days they share")
        #expect(!r.isHealthy)
    }

    @Test("A different offset is reported as the zones disagreeing")
    func aChangedOffsetIsReportedAsZones() throws {
        let db = try imported(three())
        // Identical apart from the clock the last one was lived on.
        let store = [ride("c", at: "2026-04-23T09:00:00"),
                     ride("b", at: "2026-04-22T09:00:00"),
                     ride("a", at: "2026-04-21T09:00:00", offsetSeconds: 10_800)]

        let r = ActivityParity.compare(store: store, databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(r.storeOnly.isEmpty)
        #expect(r.orderDiffered == 0)
        #expect(r.daysWithDifferentMembers.isEmpty,
                "the buckets hold the same ids in the same sequence")
        #expect(!r.zonesAgree)
        #expect(r.zoneChangesCompared > 0, "the denominator beside the verdict")
        #expect(r.unexplained == 1, "one thing wrong, counted once")
    }

    /// THE TWIN APPLIES THE SAME RULES, so a row the rules refuse is not a
    /// difference — it is a row the database is still carrying. That number is
    /// the first instrument for §12.46.3: automatic write-throughs do not
    /// reconcile, so a record deleted in the app stays here until Import.
    @Test("A row the rules refuse is dropped, not reported as a difference")
    func aRefusedRowIsDroppedNotDiffered() throws {
        let store = three()
        // Before `MatchRules.cutoffDayKey`. The importer writes it; `isKept`
        // refuses it on both sides.
        let db = try imported(store + [ride("old", at: "2020-01-01T09:00:00")])

        let r = ActivityParity.compare(store: store, databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(r.databaseOffered == 4, "the reader returned all four")
        #expect(r.databaseDropped == 1, "and the rules refused one")
        #expect(r.databaseKept == 3)
        #expect(r.databaseOnly.isEmpty, "a refused row is not a disagreement")
        #expect(r.unexplained == 0)
        #expect(r.isHealthy)
    }

    /// A FREE CONTINUOUS CONTROL, about the store rather than the database.
    /// `settle` is idempotent, so this is true on every healthy launch — and
    /// false the day something writes to `activities` without going through a
    /// door.
    @Test("A store list its own rules would change is reported")
    func anUnsettledStoreListIsReported() throws {
        let long = ride("long", at: "2026-04-21T09:00:00",
                        movingTime: 7_500, distance: 61_700)
        let short = ride("short", at: "2026-04-21T09:05:00",
                         movingTime: 7_200, distance: 60_400)
        let db = try imported([long])

        let r = ActivityParity.compare(store: [long, short], databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)
        #expect(!r.storeIsSettled, "the pair would collapse")
        #expect(r.unexplained > 0)
    }

    // MARK: What the screen and the paste get

    /// UNCONDITIONAL, every line, including the zeros — 266c's rule and
    /// §12.54.2's correction. This is the case that runs on the device every
    /// day and the one that would otherwise render as nothing at all.
    @Test("Every line is there when everything agrees")
    func everyLineIsThereWhenEverythingAgrees() throws {
        let store = three()
        let db = try imported(store)
        let r = ActivityParity.compare(store: store, databaseRows: db.rows,
                                       databaseSkipped: db.skipped,
                                       deviceOffset: offset)

        let lines = r.diagnosticLines
        // 17 UNTIL 381, WHICH ADDED THE PROVENANCE PAIR, AND 19 UNTIL 381a,
        // WHICH ADDED THE LIVE-STORE CONTROL. The pin is the point — a line
        // added without a decision is what it exists to stop — and 381 is the
        // patch that moved it without taking the decision. §12.125.7.
        #expect(lines.count == 20, "got \(lines.count)")
        #expect(lines.first == "Activity parity: 3 compared of 3 in the app")
        // PATCH 381a. NOT JUST THE COUNT. A count that moved could be any
        // three lines; naming them is what says the block gained the ones it
        // was meant to. This report was built without a caller telling it
        // anything, so the default must announce itself and the live-store
        // question must read as unasked rather than as a cheerful yes.
        #expect(lines.contains("  the app side came from: ActivityStore.shared"),
                "a report nobody told announces itself rather than hiding")
        #expect(lines.contains("  the app side was read cleanly: yes"))
        #expect(lines.contains("  the live store's list is settled: not asked"),
                "nobody asked, and that is not the same as yes")
        #expect(lines.contains("  in the app only: 0"))
        #expect(lines.contains("  order disagreements: 0 of 3"))
        #expect(lines.contains("  unexplained differences: 0"))
        #expect(r.summary == "3 compared · no differences")
    }

    // `Outcome` moved to `ShadowParity` at 313, and its tests moved with it —
    // see `VolumeParityTests.neverIsAnAnswer`.
}
