//
//  RejectionTests.swift
//  Sub4CoreTests
//
//  What a rule threw away — patch 278, ADR-0003 §12.24. D5 slice 3.
//
//  `aMigratedReceiptKeepsTheLineAndAdmitsTheRest` is the one that matters. The
//  retired shape stored a rendered sentence and nothing else, and every field
//  `rejection` wants is inside it as text. The temptation is to parse it back;
//  the assertion here is that we did not — the four columns it could have
//  guessed at stay NULL, and the line survives verbatim because on a migrated
//  receipt it is the only thing that was ever recorded.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct RejectionTests {

    private let noticedAt = Date(timeIntervalSince1970: 1_785_000_000)

    /// A ride whose average speed contradicts its own maximum — the shape the
    /// rule exists for. 41.3 km in 22:14 is 111 km/h against a max of 19.
    private func contradictory(_ id: String = "18883849470") -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2025-04-12T18:02:00", distance: 41_300,
                 movingTime: 1_334, elapsedTime: 1_500,
                 elevationGain: 120, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 5.3,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2025-04-12T16:02:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func row(_ db: Sub4Database) throws -> Row? {
        try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM rejection")
        }
    }

    private func count(_ db: Sub4Database) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM rejection") ?? 0
        }
    }

    // MARK: The record

    @Test("The rule this app has is the rule the receipt names")
    func oneRuleOnly() {
        // A second rule would make the migration below wrong, and the
        // migration cannot be re-run once it has. So the count is pinned.
        #expect(RejectionRule.allCases.count == 1)
        #expect(RejectionRule.selfContradictoryDistance.rawValue
                == "selfContradictoryDistance")
    }

    @Test("A receipt made now carries every field")
    func aFreshReceiptIsWhole() {
        let r = RejectionReceipt(contradictory(),
                                 rule: .selfContradictoryDistance,
                                 now: noticedAt)
        #expect(r.activityId == "18883849470")
        #expect(r.dateIsKnown)
        #expect(r.name == "Evening Ride")
        #expect(r.dayKey == contradictory().dayKey)
        #expect(r.distanceM == 41_300)
        #expect(r.elapsedSeconds == 1_500)
        #expect(r.label.contains("Evening Ride"))
        #expect(r.label.contains("41.3 km"))
    }

    /// THE ONE THAT MATTERS.
    @Test("A migrated receipt keeps the line and admits the rest is unknown")
    func aMigratedReceiptKeepsTheLineAndAdmitsTheRest() {
        let line = "2025-04-12 Evening Ride — 41.3 km in 22:14 = 111 km/h avg, max 19"
        let out = RejectionReceipt.migrate(["18883849470": line], now: noticedAt)

        let r = out[0]
        #expect(r.activityId == "18883849470")
        #expect(r.label == line)
        // The temptation was to parse the four fields back out of the
        // sentence. Every one of them is in there as text, and none of them is
        // a fact this app recorded.
        #expect(r.name == nil)
        #expect(r.dayKey == nil)
        #expect(r.distanceM == nil)
        #expect(r.elapsedSeconds == nil)
        #expect(r.dateIsKnown == false)
        #expect(r.rule == .selfContradictoryDistance)
    }

    @Test("Migration is sorted, so the list does not reshuffle")
    func migrationIsSorted() {
        let out = RejectionReceipt.migrate(["3": "c", "1": "a", "2": "b"],
                                           now: noticedAt)
        #expect(out.map(\.activityId) == ["1", "2", "3"])
        #expect(out.map(\.label) == ["a", "b", "c"])
    }

    // MARK: The import

    @Test("Every field of a fresh receipt reaches its column")
    func theReceiptArrivesWhole() throws {
        let db = try Sub4Database.inMemory()
        let receipt = RejectionReceipt(contradictory(),
                                       rule: .selfContradictoryDistance,
                                       now: noticedAt)
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        rejections: [receipt])

        #expect(report.rejectionsSeen == 1)
        #expect(report.rejectionsImported == 1)

        let fetched = try row(db)
        let r = try #require(fetched)
        #expect(r["externalID"] as String? == "18883849470")
        #expect(r["rule"] as String? == "selfContradictoryDistance")
        #expect(r["name"] as String? == "Evening Ride")
        #expect(r["distanceM"] as Double? == 41_300)
        #expect(r["elapsedSeconds"] as Int? == 1_500)
        #expect(r["noticedUTC"] as String? != nil)
    }

    @Test("A migrated receipt lands with its nullable columns null")
    func aMigratedReceiptLandsThin() throws {
        let db = try Sub4Database.inMemory()
        let receipts = RejectionReceipt.migrate(["111": "a line"], now: noticedAt)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               rejections: receipts)

        let fetched = try row(db)
        let r = try #require(fetched)
        #expect(r["externalID"] as String? == "111")
        // NOT NULL columns, and both honestly supplied.
        #expect(r["rule"] as String? == "selfContradictoryDistance")
        #expect(r["noticedUTC"] as String? != nil)
        // Nullable, and null.
        #expect(r["name"] as String? == nil)
        #expect(r["dayKey"] as String? == nil)
        #expect(r["distanceM"] as Double? == nil)
        #expect(r["elapsedSeconds"] as Int? == nil)
    }

    /// The receipt outlives the recording it describes — ADR-0002 names that
    /// as a deliberate gap. Nothing here references `activity`, so a rejection
    /// can be stored for a recording the database has never held.
    @Test("A receipt needs no activity to exist")
    func aReceiptNeedsNoActivity() throws {
        let db = try Sub4Database.inMemory()
        let receipts = RejectionReceipt.migrate(["999": "a line"], now: noticedAt)
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        rejections: receipts)
        #expect(report.rejectionsImported == 1)
        #expect(report.isClean)
    }

    @Test("Importing twice keeps one row and calls the second a refresh")
    func importingTwiceKeepsOneRow() throws {
        let db = try Sub4Database.inMemory()
        let receipt = RejectionReceipt(contradictory(),
                                       rule: .selfContradictoryDistance,
                                       now: noticedAt)
        let first = try Sub4Import.run(into: db, activities: [], shoes: [],
                                       rejections: [receipt])
        let second = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        rejections: [receipt])

        #expect(first.rejectionsImported == 1)
        #expect(second.rejectionsImported == 0)
        #expect(second.rejectionsUpdated == 1)
        let n = try count(db)
        #expect(n == 1)
    }

    /// A migrated receipt that is later re-recorded from a live activity
    /// should FILL IN, not duplicate. That is the shape of the real upgrade
    /// path: the thin row lands first, and a re-sync of the same recording
    /// replaces it with everything.
    @Test("A thin receipt is filled in rather than duplicated")
    func aThinReceiptIsFilledIn() throws {
        let db = try Sub4Database.inMemory()
        let thin = RejectionReceipt.migrate(["18883849470": "a line"], now: noticedAt)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], rejections: thin)

        let whole = RejectionReceipt(contradictory(),
                                     rule: .selfContradictoryDistance,
                                     now: noticedAt)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], rejections: [whole])

        let n = try count(db)
        #expect(n == 1)
        let fetched = try row(db)
        let r = try #require(fetched)
        #expect(r["name"] as String? == "Evening Ride")
    }

    // MARK: The verifier

    @Test("A faithful set of receipts verifies")
    func aFaithfulSetVerifies() throws {
        let db = try Sub4Database.inMemory()
        let receipts = RejectionReceipt.migrate(["1": "a", "2": "b"], now: noticedAt)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], rejections: receipts)

        let report = try SemanticVerifier.verify(db, activities: [],
                                                 rejections: receipts)
        #expect(report.passed, "faithful receipts failed verification")
        let tables = Set(report.checks.map(\.table))
        #expect(tables.contains("rejection"))
    }

    @Test("Deleting a receipt is caught, and names its table")
    func deletingAReceiptIsCaught() throws {
        let db = try Sub4Database.inMemory()
        let receipts = RejectionReceipt.migrate(["1": "a", "2": "b"], now: noticedAt)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], rejections: receipts)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM rejection WHERE externalID = '1'")
        }

        let report = try SemanticVerifier.verify(db, activities: [],
                                                 rejections: receipts)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "rejection" })
    }

    // MARK: The inventory

    @Test("The keys ActivityStore writes for rejections are covered")
    func rejectionKeysAreCoveredAtTheirSource() {
        let covered = Set(DataLifecycle.preferenceKeys)
        let missing = ActivityStore.rejectionKeys.filter { !covered.contains($0) }
        #expect(missing.isEmpty, "not covered by any category: \(missing)")
        #expect(ActivityStore.rejectionKeys.count == 2)
    }
}
