//
//  ConfidenceScaleTests.swift
//  Sub4CoreTests
//
//  Patch 334. The column now means what the screen draws.
//
//  WHAT A GREEN SUITE CANNOT SEE, AND WHY THESE ARE STILL WORTH WRITING
//  -------------------------------------------------------------------
//  `Sub4Migrations+ZoneFloorZero`'s header is the warning: the suite tests the
//  schema the source describes, a device holds the schema its migration
//  history built, and those are the same thing only if no migration body has
//  ever been edited after running. So none of the assertions below can prove
//  the phone is right — that is what the `Migrations:` and `Expected:` lines in
//  the diagnostics paste are for.
//
//  What they CAN prove is that the constraint exists, refuses what it should,
//  and that the identifier reached both lists. A migration registered in the
//  migrator and forgotten in `all` reports as "not migrated" and passes
//  quietly, which is the failure `all` exists to catch.
//
//  NO `Sub4Migrations.all.last ==` ASSERTION HERE. That is CLAUDE.md's rule and
//  it is not decoration: the next migration would break a test that has nothing
//  to do with it, and a vocabulary inside a migration is frozen precisely so
//  the list can keep growing.
//

import Testing
import GRDB
@testable import Sub4

@Suite("Confidence is 1 to 5")
struct ConfidenceScaleTests {

    /// Both lists, and the order. An identifier in the migrator and not in
    /// `all` is a migration `IntegrityReport` reports as missing.
    @Test func theMigrationIsRegisteredInBothPlaces() {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.confidenceScale))
        #expect(Sub4Migrations.all == Sub4Migrations.all.sorted())
    }

    /// THE DECISIVE ONE, and it depends on nothing but the schema.
    ///
    /// Reading `sqlite_master` asks the database what it actually built rather
    /// than asking the source what it meant to build, which is the only
    /// question worth putting to a rebuilt table.
    @Test func theColumnCarriesTheNarrowedCheckAndNotTheOldOne() throws {
        let db = try Sub4Database.inMemory()
        let sql = try db.queue.read {
            try String.fetchOne($0, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'proposal'
                """)
        }
        let schema = try #require(sql)
        #expect(schema.contains("confidence >= 1"))
        #expect(schema.contains("confidence <= 5"))
        #expect(!schema.contains("confidence <= 100"))
    }

    /// The rebuild copied every other constraint verbatim. A migration that
    /// quietly changed a second thing would be one nobody could read
    /// afterwards, so the neighbours are pinned too.
    @Test func therebuildKeptTheDecisionConstraint() throws {
        let db = try Sub4Database.inMemory()
        let sql = try db.queue.read {
            try String.fetchOne($0, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'proposal'
                """)
        }
        let schema = try #require(sql)
        #expect(schema.contains("'accepted'"))
        #expect(schema.contains("'rejected'"))
        #expect(schema.contains("decidedUTC"))
    }

    // MARK: What it accepts and refuses

    /// `db.queue`, not `db` — patch 334a. `Sub4Database` wraps a
    /// `DatabaseQueue` and exposes it; it does not forward `read`/`write`.
    /// `ReviewRepositoryTests:431` had the right form and I did not read it.
    ///
    /// Foreign keys off for the insert, on immediately after.
    ///
    /// The subject is one column's CHECK. Building a valid `account` and
    /// `review` to satisfy the parent reference would make every assertion
    /// below depend on two schemas this test is not about — and CLAUDE.md's
    /// rule for forcing a state the schema would otherwise refuse is exactly
    /// this shape.
    private func insert(_ db: Sub4Database, id: String, confidence: Int?) throws {
        try db.queue.writeWithoutTransaction { d in
            try d.execute(sql: "PRAGMA foreign_keys = OFF")
            defer { try? d.execute(sql: "PRAGMA foreign_keys = ON") }
            try d.execute(sql: """
                INSERT INTO proposal
                  (id, reviewID, verdict, summary, reasoning, confidence, receivedUTC)
                VALUES (?, 'no-such-review', 'easier', 's', 'why', ?,
                        '2026-06-29T06:00:00Z')
                """, arguments: [id, confidence])
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func everyLevelTheScreenCanDrawIsAccepted(level: Int) throws {
        let db = try Sub4Database.inMemory()
        try insert(db, id: "p\(level)", confidence: level)
        let stored = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT confidence FROM proposal WHERE id = 'p\(level)'")
        }
        #expect(stored == level)
    }

    /// NULL is not a level and never was. A proposal that arrived without a
    /// confidence, and one whose out-of-range value the migration could not
    /// translate, land in the same place — and `ReviewRoundTrip` already
    /// prints that as `confidence range seen: —`.
    @Test func nullIsStillPermitted() throws {
        let db = try Sub4Database.inMemory()
        try insert(db, id: "pn", confidence: nil)
        let n = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM proposal")
        }
        #expect(n == 1)
    }

    /// 70 IS THE ONE THAT MATTERS. It satisfied the old column, overflowed the
    /// view, and was written by the test fixtures from patch 225 to patch 334.
    @Test(arguments: [0, 6, 70, 100, -1])
    func everythingOutsideOneToFiveRefuses(bad: Int) throws {
        let db = try Sub4Database.inMemory()
        #expect(throws: DatabaseError.self) {
            try insert(db, id: "pb", confidence: bad)
        }
    }

    /// A GUARD THAT CANNOT FAIL HAS NOT BEEN TESTED — §12.69. This is the
    /// deliberate break, kept rather than run once and deleted: it names the
    /// constraint in the error, so a future rebuild that drops the CHECK
    /// entirely fails here rather than passing everywhere.
    @Test func theRefusalNamesTheConstraint() throws {
        let db = try Sub4Database.inMemory()
        do {
            try insert(db, id: "p70", confidence: 70)
            Issue.record("70 was accepted — the CHECK did not run")
        } catch let e as DatabaseError {
            #expect(e.message?.contains("CHECK") == true)
        }
    }
}
