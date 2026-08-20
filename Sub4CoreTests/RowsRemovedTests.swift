//
//  RowsRemovedTests.swift
//  Sub4CoreTests
//
//  What a run deleted, kept — patch 369, ADR-0003 §12.113.
//
//  THE ONE THAT IS THE WHOLE COLUMN
//  --------------------------------
//  `zeroIsNotTheSameAsNotRecorded`. A `DEFAULT 0` would have made all 241
//  existing rows claim they deleted nothing — a claim none of them made. The
//  column exists to tell "recorded, and it was none" from "nobody recorded
//  anything", and a test that only ever wrote a positive number would not
//  notice the two collapsing.
//
//  AND THE ONE 360 IS ABOUT
//  ------------------------
//  `theNewestRemovalNamesItsTrigger`. 360 permits deletion on `.authored`
//  alone. Until this patch that rule could not be checked against a run that
//  had actually deleted something; the trigger on that line is the audit.
//

import Testing
import Foundation
@testable import Sub4

@Suite("A run's deletions survive the run")
@MainActor
struct RowsRemovedTests {

    private func database() throws -> Sub4Database {
        try Sub4Database.inMemory(label: "rows-removed")
    }

    @discardableResult
    private func run(_ db: Sub4Database,
                     trigger: MigrationRunTrigger,
                     removed: Int?,
                     at: String) throws -> String {
        let id = try MigrationLedger.open(db, appVersion: "test",
                                          snapshotID: nil,
                                          trigger: trigger, now: at)
        if let removed {
            try MigrationLedger.recordRemovals(db, id: id, rows: removed)
        }
        try MigrationLedger.finish(db, id: id, state: .pending,
                                   note: nil, now: at)
        return id
    }

    // MARK: The column

    /// **§12.113.2, AND IT IS THE WHOLE PATCH.** A run that recorded zero is
    /// not a run that removed rows, and it is not one whose count is unknown
    /// either. Collapse those and the figures read as evidence and are not.
    @Test("Zero is not the same as not recorded")
    func zeroIsNotTheSameAsNotRecorded() throws {
        let db = try database()
        try run(db, trigger: .manual, removed: 0, at: "2026-08-18T09:00:00Z")
        try run(db, trigger: .manual, removed: nil, at: "2026-08-18T09:01:00Z")

        let c = try MigrationLedger.census(db)
        #expect(c.runsThatRemoved == 0, "a run recording zero was counted")
        #expect(c.rowsRemovedEver == 0)
        #expect(c.notRecorded == 1,
                "the run that never recorded a count reads as having removed none")
    }

    @Test("A run that removed nothing is not counted")
    func aRunThatRemovedNothingIsNotCounted() throws {
        let db = try database()
        try run(db, trigger: .authored, removed: 0, at: "2026-08-18T09:00:00Z")
        try run(db, trigger: .authored, removed: 3, at: "2026-08-18T09:01:00Z")

        let c = try MigrationLedger.census(db)
        #expect(c.runsThatRemoved == 1)
        #expect(c.rowsRemovedEver == 3)
        #expect(c.notRecorded == 0)
    }

    @Test("The rows are summed across runs")
    func theRowsAreSummed() throws {
        let db = try database()
        try run(db, trigger: .authored, removed: 2, at: "2026-08-18T09:00:00Z")
        try run(db, trigger: .authored, removed: 5, at: "2026-08-18T09:01:00Z")

        let c = try MigrationLedger.census(db)
        #expect(c.runsThatRemoved == 2)
        #expect(c.rowsRemovedEver == 7)
    }

    // MARK: The total the ledger records — patch 369a

    /// **§12.113.5.** `removedTotal` summed three of the six families.
    /// `pruneCommutes` and `pruneMoves` both delete rows from `correction`, and
    /// neither reached the figure 369 writes into the ledger — so the run that
    /// pruned a plan move would have recorded zero, permanently.
    ///
    /// ONE FAMILY AT A TIME, because a single call setting all five and
    /// checking the sum passes just as happily on a total that adds the same
    /// number twice. Each of these fails alone if its own counter is dropped.
    @Test("Every removal family reaches the total")
    func everyReconcileFamilyReachesTheTotal() {
        var r = Sub4Import.Report()
        #expect(r.removedTotal == 0, "an empty report claims it removed rows")

        r = Sub4Import.Report(); r.notesRemoved = 1
        #expect(r.removedTotal == 1, "notes do not reach the total")

        r = Sub4Import.Report(); r.matchDecisionsRemoved = 1
        #expect(r.removedTotal == 1, "match decisions do not reach the total")

        r = Sub4Import.Report(); r.reviewsRemoved = 1
        #expect(r.removedTotal == 1, "reviews do not reach the total")

        r = Sub4Import.Report(); r.correctionsRemoved = 1
        #expect(r.removedTotal == 1,
                "commute corrections do not reach the total")

        r = Sub4Import.Report(); r.movesRemoved = 1
        #expect(r.removedTotal == 1, "moved sessions do not reach the total")

        r = Sub4Import.Report(); r.workItemsRemoved = 1
        #expect(r.removedTotal == 1, "stopped-asking rows do not reach the total")
    }

    /// And they add rather than replace, so a total that returned the largest
    /// counter would fail here.
    @Test("The families sum")
    func theFamiliesSum() {
        var r = Sub4Import.Report()
        r.notesRemoved = 1
        r.matchDecisionsRemoved = 2
        r.reviewsRemoved = 4
        r.correctionsRemoved = 8
        r.movesRemoved = 16
        r.workItemsRemoved = 32
        #expect(r.removedTotal == 63)
    }

    // MARK: The audit 360 is about

    /// **360'S RULE, CHECKABLE FOR THE FIRST TIME.** `.authored` is the only
    /// trigger permitted to delete. The census names the trigger of the newest
    /// run that did, which is the only place that claim meets a run that
    /// actually deleted something.
    @Test("The newest removal names its trigger")
    func theNewestRemovalNamesItsTrigger() throws {
        let db = try database()
        try run(db, trigger: .manual, removed: 4, at: "2026-08-18T09:00:00Z")
        try run(db, trigger: .authored, removed: 1, at: "2026-08-18T09:05:00Z")
        try run(db, trigger: .foregrounded, removed: 0,
                at: "2026-08-18T09:09:00Z")

        let newest = try #require(try MigrationLedger.census(db).newestRemoval)
        #expect(newest.trigger == "authored",
                "a later run that removed nothing displaced the real one")
        #expect(newest.rows == 1)
        #expect(newest.startedUTC == "2026-08-18T09:05:00Z")
        #expect(newest.line.contains("authored"))
        #expect(newest.line.contains("1 row"))
        #expect(!newest.line.contains("1 rows"), "the singular is not plural")
    }

    /// **§12.54.2.** An absent answer says so. A line that disappeared when
    /// nothing had ever been deleted could not be told from one nobody wired
    /// in — which is the defect this whole patch exists to end.
    @Test("The census says never rather than nothing")
    func theCensusSaysNeverRatherThanNothing() throws {
        let db = try database()
        try run(db, trigger: .manual, removed: 0, at: "2026-08-18T09:00:00Z")

        let c = try MigrationLedger.census(db)
        #expect(c.newestRemoval == nil)

        let lines = c.diagnosticLines.joined(separator: "\n")
        #expect(lines.contains("runs that removed rows: 0"))
        #expect(lines.contains("rows removed in all runs: 0"))
        #expect(lines.contains("never — no run has deleted anything"))
        #expect(lines.contains("runs that finished before this was recorded: 0"))
    }

    /// Every one of the four lines prints on every census, whatever the
    /// answers. Three of them were the point; the fourth is what stops the
    /// three being a new instance of the same problem.
    @Test("All four lines print unconditionally")
    func allFourLinesPrintUnconditionally() throws {
        let db = try database()
        try run(db, trigger: .authored, removed: 2, at: "2026-08-18T09:00:00Z")

        let lines = try MigrationLedger.census(db).diagnosticLines
            .joined(separator: "\n")
        for needed in ["runs that removed rows:", "rows removed in all runs:",
                       "newest removal:",
                       "runs that finished before this was recorded:"] {
            #expect(lines.contains(needed))
        }
    }

    // MARK: What the write refuses

    /// **§12.20 — AN UPDATE NAMING NO ROW SUCCEEDS SILENTLY.** A count written
    /// against a run id that does not exist is a write nobody checked, on the
    /// table whose job is now to be checkable.
    @Test("Recording against no run throws")
    func recordingAgainstNoRunThrows() throws {
        let db = try database()
        #expect(throws: (any Error).self) {
            try MigrationLedger.recordRemovals(db, id: "never-opened", rows: 1)
        }
    }

    /// A count can be written more than once for one run — the second is the
    /// answer. The importer writes once, but an UPDATE that refused would make
    /// a retry impossible for no stated reason.
    @Test("Recording twice keeps the second answer")
    func recordingTwiceKeepsTheSecond() throws {
        let db = try database()
        let id = try MigrationLedger.open(db, appVersion: "test",
                                          snapshotID: nil,
                                          trigger: .authored,
                                          now: "2026-08-18T09:00:00Z")
        try MigrationLedger.recordRemovals(db, id: id, rows: 1)
        try MigrationLedger.recordRemovals(db, id: id, rows: 6)
        try MigrationLedger.finish(db, id: id, state: .pending, note: nil,
                                   now: "2026-08-18T09:00:01Z")

        #expect(try MigrationLedger.census(db).rowsRemovedEver == 6)
    }

    // MARK: What "not recorded" does not include

    /// **§12.113.4.** A run that is still open, or that failed, never reached
    /// the write. That is a different fact from a run which finished before the
    /// column existed, and counting them together would inflate the one line
    /// whose job is saying what the figures cannot know.
    @Test("An open run is not counted as unrecorded")
    func anOpenRunIsNotUnrecorded() throws {
        let db = try database()
        _ = try MigrationLedger.open(db, appVersion: "test", snapshotID: nil,
                                     trigger: .manual,
                                     now: "2026-08-18T09:00:00Z")

        let c = try MigrationLedger.census(db)
        #expect(c.notRecorded == 0,
                "a run still running was counted as one that predates the column")
    }
}
