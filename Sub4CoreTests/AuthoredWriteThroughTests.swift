//
//  AuthoredWriteThroughTests.swift
//  Sub4CoreTests
//
//  The authored write-through — patch 348, ADR-0003 §12.94.
//
//  WHAT IS WORTH TESTING HERE AND WHAT IS NOT
//  ------------------------------------------
//  That five stores call `noteAuthoredChange` is a call site, and the apply
//  script guards it by name — a test asserting the same thing would only be a
//  second copy of the list. That a fired trigger produces a run is
//  `DatabaseWriteThrough`'s own behaviour, unchanged since 302.
//
//  What is new and what can fail is the MIGRATION, and one part of it is
//  frightening in a way the rest of this patch is not: it rebuilds
//  `migration_run`, which is the table holding the verified run that D7's
//  activation reads. A rebuild that dropped a row, or a state, or a note,
//  would take the entry-gate evidence with it — and would do it silently, on a
//  launch, with no screen saying anything.
//
//  TWO TESTS WERE WRITTEN FOR THIS FILE AND DELETED BEFORE IT SHIPPED.
//  `MigrationLedgerTests.theCensusSpeaksAtZero` already asserts every case in
//  `allCases` has a census line, and `everyTriggerIsStorable` there already
//  drives every case through `MigrationLedger.open` and reads it back. Both
//  cover `.authored` the moment the case exists, which is what a suite written
//  against `allCases` is for. §12.43 — do not write a second copy.
//
//  So `theRebuildPreservesEveryRun` runs the migrator to the patch BEFORE this
//  one, writes rows into the old shape by hand, and then lets this migration
//  run over them. It is the only test in this file that could have caught a
//  real defect, and it is the reason the file exists.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A save reaches the database")
struct AuthoredWriteThroughTests {

    // MARK: The vocabulary

    /// FIVE CASES, AND THE FIFTH IS NOT `manual`.
    ///
    /// `manual` means a person pressed Import, and its successful runs are kept
    /// for ever on that basis. An authored run is the app noticing a save.
    /// Collapsing them would make `manual: 14` mean two things.
    @Test("The fifth trigger exists and is its own thing")
    func theFifthTriggerIsItsOwnThing() {
        #expect(MigrationRunTrigger.allCases.count == 5)
        #expect(MigrationRunTrigger(rawValue: "authored") == .authored)
        #expect(MigrationRunTrigger.authored != .manual)
        #expect(!MigrationRunTrigger.authored.label.isEmpty,
                "the label is what a screen prints after Started by")
    }

    /// THE QUESTION `prunableIsEveryAutomaticTrigger` EXISTS TO FORCE, answered.
    ///
    /// There will be one authored run per note, per commute decision, per match
    /// decision and per typed constant. Keeping every one of them for ever
    /// would drown the fourteen runs a person actually chose to make.
    @Test("Authored runs are disposable")
    func authoredRunsAreDisposable() {
        #expect(MigrationLedger.prunableTriggers.contains(.authored))
        #expect(!MigrationLedger.prunableTriggers.contains(.manual),
                "the one a person chose is still kept for ever")
    }

    // MARK: The migration

    @Test("The migration is registered, named, and in date order")
    func theMigrationIsRegistered() {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.authoredTrigger))
        #expect(Sub4Migrations.all == Sub4Migrations.all.sorted(),
                "the identifiers are dates and the order is the history")
        #expect(Sub4Migrations.authoredTrigger > Sub4Migrations.runRecovered,
                "it rebuilds the table 339 rebuilt, so it must run after it")
    }

    /// **THE ONE THAT COULD HAVE CAUGHT SOMETHING.**
    ///
    /// Migrated to the patch before this one, rows written by hand into the old
    /// shape, then this migration run over them. Every column that carries
    /// meaning is checked on the way out — and `verified` above all, because
    /// that is the row `MigrationLedger.census().newestVerified` reads and the
    /// row D7's activation depends on.
    @Test("The rebuild preserves every run, including the verified one")
    func theRebuildPreservesEveryRun() throws {
        let q = try DatabaseQueue()
        let m = Sub4Migrations.migrator
        try m.migrate(q, upTo: Sub4Migrations.runRecovered)

        try q.write { db in
            try db.execute(sql: """
                INSERT INTO migration_run
                  (id, startedUTC, finishedUTC, recoveredUTC, state,
                   snapshotID, appVersion, note, triggeredBy)
                VALUES
                  ('r1', '2026-08-01T00:00:00Z', '2026-08-01T00:00:01Z', NULL,
                   'pending', 'snap-1', '338', NULL, 'backgrounded'),
                  ('r2', '2026-08-02T00:00:00Z', '2026-08-02T00:00:02Z', NULL,
                   'verified', 'snap-2', '340', '20 comparisons, all agreed',
                   'manual'),
                  ('r3', '2026-08-03T00:00:00Z', NULL, '2026-08-04T00:00:00Z',
                   'interrupted', NULL, '339', NULL, 'foregrounded')
                """)
        }

        try m.migrate(q)

        try q.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, startedUTC, finishedUTC, recoveredUTC, state,
                       snapshotID, appVersion, note, triggeredBy, sequence
                  FROM migration_run ORDER BY sequence
                """)
            #expect(rows.count == 3, "no run may be lost in a rebuild")

            #expect(rows[0]["id"] as String? == "r1", "and the order is preserved")
            #expect(rows[1]["id"] as String? == "r2")
            #expect(rows[2]["id"] as String? == "r3")

            // THE ROW D7 DEPENDS ON, field by field.
            let verified = rows[1]
            #expect(verified["state"] as String? == "verified")
            #expect(verified["note"] as String? == "20 comparisons, all agreed")
            #expect(verified["appVersion"] as String? == "340")
            #expect(verified["snapshotID"] as String? == "snap-2")
            #expect(verified["triggeredBy"] as String? == "manual")
            #expect(verified["finishedUTC"] as String? == "2026-08-02T00:00:02Z")
            #expect(verified["recoveredUTC"] as String? == nil)

            // The interrupted shape survives its own CHECK on the way in.
            let interrupted = rows[2]
            #expect(interrupted["state"] as String? == "interrupted")
            #expect(interrupted["finishedUTC"] as String? == nil)
            #expect(interrupted["recoveredUTC"] as String? == "2026-08-04T00:00:00Z")

            // Renumbered, ascending, gap-free — the rebuild is what assigns it.
            let sequences = rows.compactMap { $0["sequence"] as Int64? }
            #expect(sequences == sequences.sorted())
            #expect(sequences.count == 3)
        }
    }

    /// THE CONSTRAINT, FROM BOTH SIDES. `authored` must now be accepted, and a
    /// value nobody declared must still be refused — a widened CHECK that
    /// accidentally became no CHECK would let a typo into the column that the
    /// census groups by.
    @Test("The widened CHECK accepts the fifth trigger and nothing more")
    func theCheckAcceptsTheFifthAndNothingMore() throws {
        let d = try Sub4Database.inMemory(label: "authored-check")

        try d.queue.write { db in
            try db.execute(sql: """
                INSERT INTO migration_run
                  (id, startedUTC, finishedUTC, state, appVersion, triggeredBy)
                VALUES ('ok', '2026-08-05T00:00:00Z', '2026-08-05T00:00:01Z',
                        'pending', '348', 'authored')
                """)
        }

        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion, triggeredBy)
                    VALUES ('no', '2026-08-05T00:00:00Z', '2026-08-05T00:00:01Z',
                            'pending', '348', 'whenever')
                    """)
            }
        }
    }
}
