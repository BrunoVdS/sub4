//
//  SyncStateTests.swift
//  Sub4CoreTests
//
//  Where the sync has got to — patch 275, ADR-0003 §12.22. D5 slice 1.
//
//  THE ONE THAT MATTERS IS `theCursorSurvivesTheRoundTripExactly`. The column
//  is opaque text and the store holds a `Double`; if the two ever disagreed by
//  a single second, D7 would resume a sync from the wrong place and the
//  activities in between would be skipped for ever — which is the exact defect
//  patch 249 fixed and the reason `ActivityStore.cursor` is now a high-water
//  mark rather than a query bound.
//
//  `theVerifierCatchesADriftedCursor` is its complement: proving the check can
//  FAIL is what makes a passing check evidence.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct SyncStateTests {

    private func state(cursor: String? = "1785945872.0",
                       lastSync: Date? = Date(timeIntervalSince1970: 1_785_945_872),
                       lastResult: String? = nil) -> SyncState {
        SyncState(sourceID: Sub4Import.sourceID, cursor: cursor,
                  lastSync: lastSync, lastResult: lastResult)
    }

    private func row(_ db: Sub4Database) throws -> Row? {
        try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM sync_state")
        }
    }

    private func count(_ db: Sub4Database) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM sync_state") ?? 0
        }
    }

    // MARK: The row

    @Test("Every field of the sync position arrives")
    func thePositionArrivesWhole() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        syncState: state(lastResult: "Strava timed out."))

        #expect(report.syncStateSeen == 1)
        #expect(report.syncStateImported == 1)

        let fetched = try row(db)
        let r = try #require(fetched)
        #expect(r["sourceID"] as String? == "strava")
        #expect(r["cursor"] as String? == "1785945872.0")
        #expect(r["lastResult"] as String? == "Strava timed out.")
        let stamp = r["lastSyncUTC"] as String?
        #expect(stamp?.hasPrefix("2026-") == true)
    }

    /// THE ONE THAT MATTERS. Text in, `Double` out, and the same number.
    @Test("The cursor survives the round trip exactly")
    func theCursorSurvivesTheRoundTripExactly() throws {
        let db = try Sub4Database.inMemory()
        let original: TimeInterval = 1_785_945_872
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               syncState: state(cursor: "\(original)"))

        let fetched = try row(db)
        let r = try #require(fetched)
        let stored = try #require(r["cursor"] as String?)
        let back = try #require(Double(stored))
        #expect(back == original)
    }

    @Test("Nothing to report leaves lastResult NULL rather than saying ok")
    func nothingToReportIsNull() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               syncState: state())

        let fetched = try row(db)
        let r = try #require(fetched)
        // "Whether a sync ran" is `lastSyncUTC`'s job. Writing "ok" here would
        // be inventing a word the app never said, to fill a column.
        #expect(r["lastResult"] as String? == nil)
        #expect(r["lastSyncUTC"] as String? != nil)
    }

    @Test("No state offered writes no row")
    func noStateWritesNothing() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [])
        #expect(report.syncStateSeen == 0)
        let rows = try count(db)
        #expect(rows == 0)
    }

    @Test("A phone that has never synced still has a position")
    func neverSyncedStillHasAPosition() throws {
        let db = try Sub4Database.inMemory()
        // The cursor starts at the plan cutoff, not at nothing — so the row
        // says where a first sync would begin rather than staying empty.
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               syncState: state(lastSync: nil))

        let fetched = try row(db)
        let r = try #require(fetched)
        #expect(r["cursor"] as String? == "1785945872.0")
        #expect(r["lastSyncUTC"] as String? == nil)
    }

    // MARK: Idempotency

    @Test("Importing twice keeps one row and calls the second a refresh")
    func importingTwiceKeepsOneRow() throws {
        let db = try Sub4Database.inMemory()
        let first = try Sub4Import.run(into: db, activities: [], shoes: [],
                                       syncState: state())
        let second = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        syncState: state())

        #expect(first.syncStateImported == 1)
        #expect(second.syncStateImported == 0)
        #expect(second.syncStateUpdated == 1)
        let rows = try count(db)
        #expect(rows == 1)
    }

    @Test("A moved cursor overwrites rather than accumulating")
    func aMovedCursorOverwrites() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               syncState: state(cursor: "1785945872.0"))
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               syncState: state(cursor: "1786000000.0"))

        let rows = try count(db)
        #expect(rows == 1)
        let fetched = try row(db)
        let r = try #require(fetched)
        #expect(r["cursor"] as String? == "1786000000.0")
    }

    // MARK: The verifier

    @Test("A faithful sync position verifies")
    func aFaithfulPositionVerifies() throws {
        let db = try Sub4Database.inMemory()
        let s = state()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], syncState: s)

        let report = try SemanticVerifier.verify(db, activities: [], syncState: s)
        #expect(report.passed, "a faithful sync position failed verification")
        let tables = Set(report.checks.map(\.table))
        #expect(tables.contains("sync_state"))
    }

    /// Proving the check can fail is what makes a passing check evidence — the
    /// acceptance criterion §12.16 was written against.
    @Test("The verifier catches a cursor that has drifted")
    func theVerifierCatchesADriftedCursor() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               syncState: state(cursor: "1785945872.0"))

        // The store has moved on and the table has not — which is what a
        // half-written import looks like, and what D7 would resume from.
        let report = try SemanticVerifier.verify(
            db, activities: [], syncState: state(cursor: "1786000000.0"))

        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "sync_state" })
    }

    @Test("A missing row is caught, not just a wrong one")
    func aMissingRowIsCaught() throws {
        let db = try Sub4Database.inMemory()
        let s = state()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], syncState: s)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM sync_state")
        }

        let report = try SemanticVerifier.verify(db, activities: [], syncState: s)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "sync_state" })
    }

    @Test("No state offered means nothing is expected")
    func noStateExpectsNothing() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])
        let report = try SemanticVerifier.verify(db, activities: [])
        #expect(report.passed)
    }

    // MARK: The store's own answer

    @Test("The store names a source the database will accept")
    func theStoreNamesASeededSource() throws {
        let db = try Sub4Database.inMemory()
        // `sync_state.sourceID` is a RESTRICTED foreign key, so an id this app
        // has not seeded is refused rather than stored. `ActivityStore` builds
        // its state from `Sub4Import.sourceID` for exactly this reason.
        let seeded = try db.queue.read { d in
            try Bool.fetchOne(d, sql: "SELECT 1 FROM source WHERE id = ?",
                              arguments: [Sub4Import.sourceID]) ?? false
        }
        // `ActivityStore.syncState` names `Sub4Import.sourceID` rather than a
        // literal, so the two cannot drift. Asserted here by checking the id
        // the importer uses is the id the schema seeded — waking the real
        // singleton to read its property would load `activities.json` and give
        // this suite side effects it has no business having.
        #expect(seeded)
    }
}
