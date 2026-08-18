//
//  DatabaseWriteThroughTests.swift
//  Sub4CoreTests
//
//  D6b step 2 — patch 302, ADR-0003 §12.46.
//
//  `anAutomaticRunDoesNotDelete` is the one with teeth, and it is a test about
//  blast radius rather than about correctness. `AppStores.current()` sets
//  `reconcile` to `.run` whenever the four gated stores read trustworthily, and
//  reconciliation DELETES rows the app no longer has. Doing that by hand with
//  the report on screen is one thing; doing it unattended, several times a day,
//  is another.
//
//  The override lives inside `writeThrough` rather than at the call site
//  precisely so a future trigger cannot forget it — and this is the test that
//  fails if somebody moves it.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct DatabaseWriteThroughTests {

    private func ride(_ id: String = "19580875358") -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 24_300,
                 movingTime: 3_240, elapsedTime: 3_600,
                 elevationGain: 142, averageHeartrate: 131, isTrainer: false,
                 maxHeartrate: 168, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: true, averageWatts: 168,
                 startUTC: "2026-07-28T16:02:00Z", startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func stores(_ activities: [Activity]) -> AppStores {
        var s = AppStores()
        s.activities = activities
        return s
    }

    // MARK: The teeth

    /// THE ONE WITH TEETH. A caller handing in `.run` must not get deletion.
    @Test("An automatic run refuses to reconcile, whatever it is handed")
    func anAutomaticRunDoesNotDelete() throws {
        let db = try Sub4Database.inMemory()
        var asked = stores([ride()])
        asked.reconcile = .run

        let outcome = DatabaseWriteThrough.writeThrough(db, stores: asked,
                                                        appVersion: "302-test",
                                                        trigger: .backgrounded, cause: "a test")
        guard case .wrote(let report, _) = outcome else {
            Issue.record("expected a write, got \(outcome)"); return
        }
        #expect(report.reconciled != .run,
                "the override belongs inside writeThrough, not at the call site")
        #expect(report.notesRemoved == 0)
        #expect(report.matchDecisionsRemoved == 0)
    }

    // MARK: It does the work

    @Test("It writes what the stores hold")
    func itWrites() throws {
        let db = try Sub4Database.inMemory()
        let outcome = DatabaseWriteThrough.writeThrough(db, stores: stores([ride()]),
                                                        appVersion: "302-test",
                                                        trigger: .backgrounded, cause: "a test")
        guard case .wrote(let report, let at) = outcome else {
            Issue.record("expected a write, got \(outcome)"); return
        }
        #expect(report.activitiesSeen == 1)
        #expect(report.activitiesInserted == 1)
        #expect(report.refusals.isEmpty)
        #expect(at.hasSuffix("Z"), "the timestamp is the writer's own format")

        // Through D6a's reader, which is the check that means anything.
        #expect(ActivityRepository.all(db).activities?.count == 1)
    }

    /// Idempotent, because the whole design rests on it: a missed trigger being
    /// LATE rather than a gap only holds if running twice is free.
    @Test("Running it twice writes nothing twice")
    func twiceIsFree() throws {
        let db = try Sub4Database.inMemory()
        let s = stores([ride()])
        _ = DatabaseWriteThrough.writeThrough(db, stores: s, appVersion: "302-test",
                                              trigger: .backgrounded, cause: "a test")
        let second = DatabaseWriteThrough.writeThrough(db, stores: s,
                                                       appVersion: "302-test",
                                                       trigger: .foregrounded, cause: "a test")

        guard case .wrote(let report, _) = second else {
            Issue.record("expected a write, got \(second)"); return
        }
        #expect(report.activitiesInserted == 0, "already there")
        #expect(report.activitiesUpdated == 1, "refreshed, not duplicated")
        #expect(ActivityRepository.all(db).activities?.count == 1)
    }

    @Test("An empty set of stores is a write of nothing, not a failure")
    func emptyIsNotAFailure() throws {
        let db = try Sub4Database.inMemory()
        let outcome = DatabaseWriteThrough.writeThrough(db, stores: AppStores(),
                                                        appVersion: "302-test",
                                                        trigger: .backgrounded, cause: "a test")
        guard case .wrote(let report, _) = outcome else {
            Issue.record("expected a write, got \(outcome)"); return
        }
        #expect(report.activitiesSeen == 0)
    }

    // MARK: What the screen reads

    /// `.never` is not a success and not a failure. Sixth instance of §12.15's
    /// shape, and the reason `Outcome` is an enum rather than an optional
    /// report — an optional would make "has not run" and "ran and found
    /// nothing" the same nil.
    @Test("Never having run is its own answer")
    func neverIsAnAnswer() {
        let w = DatabaseWriteThrough.shared
        // Fresh launch inside the test process: nothing has triggered it.
        if case .never = w.last {
            #expect(w.isHealthy, "not having run yet is not a fault")
            #expect(w.line == "Not run since this launch.")
        }
    }

    @Test("No database is not the same as a failed write")
    func noDatabaseIsItsOwnAnswer() {
        let outcomes: [DatabaseWriteThrough.Outcome] = [
            .noDatabase,
            .failed("disk full", atUTC: "2026-08-07T12:00:00Z"),
        ]
        for o in outcomes {
            #expect(o != .never)
        }
        #expect(DatabaseWriteThrough.Outcome.noDatabase
                != .failed("disk full", atUTC: "2026-08-07T12:00:00Z"),
                "one is the launch gate, the other is the write")
    }

    // MARK: The ledger link — patch 303

    /// Contract item 11 asks every run to record which snapshot of its inputs
    /// was taken first. An automatic run takes none, but one EXISTS, and it is
    /// the snapshot that preceded this run — so recording it is accurate.
    ///
    /// 302 passed nil, and the ledger renders a missing snapshot in RED. Every
    /// backgrounding left the newest row flagged for a problem it did not have.
    @Test("An automatic run records the snapshot that preceded it")
    func theSnapshotReachesTheLedger() throws {
        let db = try Sub4Database.inMemory()
        _ = DatabaseWriteThrough.writeThrough(db, stores: stores([ride()]),
                                              appVersion: "303-test",
                                              snapshotID: "2026-08-05-202320",
                                              trigger: .backgrounded, cause: "a test")
        let run = try #require(try MigrationLedger.latest(db))
        #expect(run.snapshotID == "2026-08-05-202320")
        #expect(run.appVersion == "303-test")
    }

    /// AND NIL IS STILL NIL. On a device where no snapshot has ever been taken
    /// there is nothing to record, and inventing one would be worse than the
    /// red row — it would say a protected copy exists when none does.
    @Test("No snapshot anywhere is recorded as no snapshot")
    func noSnapshotStaysNone() throws {
        let db = try Sub4Database.inMemory()
        _ = DatabaseWriteThrough.writeThrough(db, stores: stores([ride()]),
                                              appVersion: "303-test",
                                              trigger: .backgrounded, cause: "a test")
        let run = try #require(try MigrationLedger.latest(db))
        #expect(run.snapshotID == nil)
    }

    /// WHAT STARTED IT REACHES THE ROW — patch 311.
    ///
    /// Until 303 an automatic run could be told from a manual one BY ACCIDENT:
    /// it passed no snapshot id. 303 fixed a real defect and removed the only
    /// distinction the table had, so `migration_run: 45` in the diagnostics
    /// paste was forty-five rows nobody could sort. The trigger is a column
    /// now, and this is the wiring that fills it.
    @Test("A write-through records what started it")
    func theTriggerReachesTheLedger() throws {
        let db = try Sub4Database.inMemory()
        _ = DatabaseWriteThrough.writeThrough(db, stores: stores([ride()]),
                                              appVersion: "311-test",
                                              trigger: .foregrounded, cause: "a test")
        let run = try #require(try MigrationLedger.latest(db))
        #expect(run.triggeredBy == .foregrounded)
        #expect(run.triggerLabel == "coming back to the app")
    }

    /// Every run reaches the ledger, so the ledger — not the in-memory counter
    /// — is what answers "did this happen while I was not looking".
    @Test("Every write-through leaves a ledger row")
    func everyRunIsRecorded() throws {
        let db = try Sub4Database.inMemory()
        let s = stores([ride()])
        _ = DatabaseWriteThrough.writeThrough(db, stores: s, appVersion: "303-test",
                                              trigger: .backgrounded, cause: "a test")
        _ = DatabaseWriteThrough.writeThrough(db, stores: s, appVersion: "303-test",
                                              trigger: .foregrounded, cause: "a test")
        #expect(try MigrationLedger.all(db).count == 2)
    }
}
