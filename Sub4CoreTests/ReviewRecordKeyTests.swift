//
//  ReviewRecordKeyTests.swift
//  Sub4CoreTests
//
//  Patch 337. The review carries the app's own identity.
//
//  WHAT THESE CAN AND CANNOT PROVE
//  -------------------------------
//  Same caveat as `ConfidenceScaleTests`: the suite tests the schema the source
//  describes, a device holds the schema its migration history built, and those
//  agree only if no migration body has ever been edited after running. The
//  `Migrations:` and `Expected:` lines in the diagnostics paste are what checks
//  the phone.
//
//  What they CAN prove is the thing 327 got wrong and nobody noticed for ten
//  patches: that two reviews written in the same second are two reviews.
//
//  THE ADOPTION TESTS ARE THE ONES THAT MATTER TODAY. Bruno's device holds five
//  rows written before this migration, and they have no `recordKey`. If
//  adoption is wrong, the first import after 337 either duplicates all five or
//  leaves them unreachable — and both look like a working app until somebody
//  counts. Forcing that state here needs raw SQL, because no code path can
//  produce a pre-337 row any more.
//
//  NO `Sub4Migrations.all.last ==` ASSERTION. CLAUDE.md's rule: the next
//  migration would break a test that has nothing to do with it.
//

// `Foundation` FOR `Date` — patch 337a. The import block was copied from
// `ConfidenceScaleTests`, which builds its fixtures entirely in SQL and needs
// no Foundation type. This file constructs a `ProposalStore.Record`, and
// `ranAt` is a `Date`. `ReviewRepositoryTests` beside it has the right three
// lines; copying the wrong neighbour is how this happened.
import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A review is keyed by the app's record id")
struct ReviewRecordKeyTests {

    // MARK: The migration reached both lists

    @Test func theMigrationIsRegisteredInBothPlaces() {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.reviewRecordKey))
        #expect(Sub4Migrations.all == Sub4Migrations.all.sorted())
    }

    /// Asks the database what it built, not the source what it meant to build.
    @Test func theColumnAndTheIndexExist() throws {
        let db = try Sub4Database.inMemory()

        let table = try db.queue.read {
            try String.fetchOne($0, sql: """
                SELECT sql FROM sqlite_master
                 WHERE type = 'table' AND name = 'review'
                """)
        }
        // HOISTED. CLAUDE.md: never put `try` inside `#expect` / `#require`.
        let tableSQL = try #require(table)
        #expect(tableSQL.contains("recordKey"))

        let index = try db.queue.read {
            try String.fetchOne($0, sql: """
                SELECT sql FROM sqlite_master
                 WHERE type = 'index' AND name = 'review_on_record_key'
                """)
        }
        let sql = try #require(index)
        #expect(sql.contains("UNIQUE"))
        #expect(sql.contains("accountID"))
        #expect(sql.contains("recordKey IS NOT NULL"),
                "the partial clause is what lets the unadopted rows coexist")
    }

    /// THE INDEX MUST ADMIT MANY NULLS AND REFUSE ONE REPEAT.
    ///
    /// Both halves, because either alone passes for the wrong reason: an index
    /// that refused the NULLs would break every device holding pre-337 rows,
    /// and one that admitted the repeat would not be doing its job.
    @Test func theIndexAdmitsNullsAndRefusesARepeatedKey() throws {
        let db = try Sub4Database.inMemory()
        try seedAccount(db)
        try insertReview(db, id: "r1", recordKey: nil, ranUTC: "2026-08-09T12:29:35Z")
        try insertReview(db, id: "r2", recordKey: nil, ranUTC: "2026-08-09T12:29:35Z")
        try insertReview(db, id: "r3", recordKey: "k1", ranUTC: "2026-08-09T12:29:35Z")

        #expect(throws: DatabaseError.self) {
            try insertReview(db, id: "r4", recordKey: "k1",
                             ranUTC: "2026-08-09T13:00:00Z")
        }
    }

    // MARK: Adoption — the five rows already on the device

    /// A pre-337 row is claimed by the record whose run time matches, ONCE,
    /// and the row keeps its own database id so nothing referencing it breaks.
    @Test func anUnkeyedRowIsAdoptedRatherThanDuplicated() throws {
        let db = try Sub4Database.inMemory()
        let a = Self.record(id: "2026-06-01_2026-06-28_1-abc123",
                            ranAt: 1_780_100_000)
        try seedUnkeyed(db, from: a)

        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               proposals: [a], plan: nil)

        let rows = try db.queue.read {
            try Row.fetchAll($0, sql: "SELECT id, recordKey FROM review")
        }
        #expect(rows.count == 1, "adopted, not duplicated")
        // HOISTED — `rows.first?["id"]` is a double optional and the cast on it
        // does not mean what it looks like it means.
        let row = try #require(rows.first)
        #expect(row["id"] as String? == "pre337",
                "the row keeps its own id, so nothing referencing it breaks")
        #expect(row["recordKey"] as String? == a.id)
    }

    /// THE 9 AUGUST SHAPE, WITH ADOPTION IN THE MIDDLE.
    ///
    /// One pre-337 row, two records sharing its run time. One adopts it, the
    /// other inserts — which is how the sixth review comes back rather than
    /// staying merged into the fifth.
    @Test func aSecondRecordAtTheSameRunTimeInsertsRatherThanStealingTheRow() throws {
        let db = try Sub4Database.inMemory()
        let a = Self.record(id: "2026-06-01_2026-06-28_1-aaa111",
                            ranAt: 1_780_100_000)
        let b = Self.record(id: "2026-05-01_2026-05-28_1-bbb222",
                            ranAt: 1_780_100_000, startDay: "2026-05-01",
                            endDay: "2026-05-28")
        try seedUnkeyed(db, from: a)

        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               proposals: [a, b], plan: nil)

        let keys = try db.queue.read {
            try String.fetchSet($0, sql: "SELECT recordKey FROM review")
        }
        #expect(keys == [a.id, b.id])

        let r = ReviewRoundTrip.compare(storeRecords: [a, b],
                                        database: ReviewRepository.load(db))
        #expect(r.reviewsCompared == 2)
        #expect(r.reviewsAwaitingAKey == 0, "adoption closes the window")
        #expect(r.unexplained == 0)
    }

    /// The window, seen from the read-back, before the import that closes it.
    /// A device that has not imported since 337 must SAY so rather than look
    /// identical to one that has — §12.54.2.
    @Test func theUnadoptedStateIsVisibleAndIsNotAFault() throws {
        let db = try Sub4Database.inMemory()
        let a = Self.record(id: "2026-06-01_2026-06-28_1-ccc333",
                            ranAt: 1_780_100_000)
        try seedUnkeyed(db, from: a)

        let r = ReviewRoundTrip.compare(storeRecords: [a],
                                        database: ReviewRepository.load(db))
        #expect(r.reviewsAwaitingAKey == 1)
        #expect(r.pairedByRunTime == 1)
        #expect(r.pairedByRecordKey == 0)
        #expect(r.reviewsCompared == 1, "it still compares — the fallback exists for this")
        #expect(r.rowsSkipped == 0, "a NULL key is not an unreadable row")
    }

    /// Adoption runs once. A second import finds the row by its key, and
    /// `pairedByRunTime` going to zero is the number that says the window shut.
    @Test func theFallbackStopsFiringAfterAdoption() throws {
        let db = try Sub4Database.inMemory()
        let a = Self.record(id: "2026-06-01_2026-06-28_1-ddd444",
                            ranAt: 1_780_100_000)
        try seedUnkeyed(db, from: a)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               proposals: [a], plan: nil)

        let r = ReviewRoundTrip.compare(storeRecords: [a],
                                        database: ReviewRepository.load(db))
        #expect(r.pairedByRecordKey == 1)
        #expect(r.pairedByRunTime == 0)
        #expect(r.reviewsAwaitingAKey == 0)
    }

    // MARK: The paste says which rule paired what

    /// §12.15. Three unconditional lines, present whatever the counts are.
    @Test func thePasteNamesBothPairingRules() throws {
        let db = try Sub4Database.inMemory()
        let a = Self.record(id: "2026-06-01_2026-06-28_1-eee555",
                            ranAt: 1_780_100_000)
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               proposals: [a], plan: nil)

        let r = ReviewRoundTrip.compare(storeRecords: [a],
                                        database: ReviewRepository.load(db))
        let text = r.diagnosticLines.joined(separator: "\n")
        #expect(text.contains("reviews paired by record key: 1"))
        #expect(text.contains("reviews paired by run time, not yet keyed: 0"))
        #expect(text.contains("database rows awaiting a record key: 0"))
        #expect(text.contains("app records sharing a run time: 0"))
    }

    // MARK: Fixtures

    /// A pre-337 row cannot be produced by any code path any more, so it is
    /// written by hand — the same reasoning as `ConfidenceScaleTests.insert`.
    /// `label` is NOT NULL and `Sub4Import.ensureAccount` guards on existence,
    /// so `OR IGNORE` keeps this safe to call before an import that will also
    /// want the row.
    private func seedAccount(_ db: Sub4Database) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT OR IGNORE INTO account (id, label, createdUTC)
                VALUES (?, ?, ?)
                """, arguments: [Sub4Import.accountID, "test",
                                 "2026-08-01T00:00:00Z"])
        }
    }

    private func seedUnkeyed(_ db: Sub4Database,
                             from record: ProposalStore.Record) throws {
        try seedAccount(db)
        try insertReview(db, id: "pre337", recordKey: nil,
                         ranUTC: Sub4Import.iso8601(record.ranAt),
                         startDay: record.startDay, endDay: record.endDay)
    }

    private func insertReview(_ db: Sub4Database, id: String,
                              recordKey: String?, ranUTC: String,
                              startDay: String = "2026-06-01",
                              endDay: String = "2026-06-28") throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO review
                  (id, accountID, recordKey, ranUTC, windowStartDayKey,
                   windowEndDayKey, provider, model, appVersion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, Sub4Import.accountID, recordKey, ranUTC,
                                 startDay, endDay, Sub4Import.reviewProvider,
                                 "rehearsal", "1.0 (1) · patch 335b"])
        }
    }

    private static func record(id: String, ranAt: Double,
                               startDay: String = "2026-06-01",
                               endDay: String = "2026-06-28")
                               -> ProposalStore.Record {
        .init(id: id,
              ranAt: Date(timeIntervalSince1970: ranAt),
              windowLabel: "\(startDay) → \(endDay)",
              startDay: startDay, endDay: endDay,
              evidence: "## Load\nCTL 41, ATL 63, TSB −22.",
              proposal: .init(verdict: .easier,
                              summary: "Ease the next week.",
                              reasoning: "Freshness has been deep for five days.",
                              changes: [], watchFor: [], confidence: 3),
              appVersion: "1.0 (1) · patch 337",
              model: "rehearsal")
    }
}
