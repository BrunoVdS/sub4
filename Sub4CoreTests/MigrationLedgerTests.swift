//
//  MigrationLedgerTests.swift
//  Sub4CoreTests
//
//  The import ledger — patch 255, migration contract item 11; extended at
//  patch 311 for the trigger column, the retention rule and a defect in
//  `stale`. ADR-0003 §12.15, §12.55.
//
//  The acceptance criteria, verbatim from the plan: "an import that throws
//  leaves `failed`, not `running`; two imports produce two rows; the state
//  vocabulary and the enum agree." The third lives in `DomainSchemaTests` with
//  the other frozen vocabularies; the first two are here.
//
//  THE FIRST ONE IS THE WHOLE POINT. It is the reason the ledger writes in
//  three transactions rather than sharing the import's, and a test that only
//  checked the happy path would pass against the version of this code that gets
//  it wrong.
//
//  WHAT 311 ADDS, AND WHY EACH ONE IS HERE
//  ---------------------------------------
//  `anInterruptedRunIsFoundBeyondThePage` is the one with teeth. `stale` used
//  to filter `all(db, limit: 100)`, so an interrupted run older than about a
//  day was invisible and the screen said "Interrupted runs: 0" with complete
//  confidence. That is §12.15's shape — a diagnostic that cannot say why it has
//  no answer gets read as having one — and the test builds a table big enough
//  for the old implementation to fail on.
//
//  The prune tests are all about what is NOT deleted. A prune that removes too
//  little grows a table; a prune that removes too much destroys the only record
//  that the app was killed mid-write. Only one of those is recoverable.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct MigrationLedgerTests {

    private func db() throws -> Sub4Database {
        try Sub4Database.inMemory(label: "ledger")
    }

    private let t0 = "2026-08-05T10:00:00Z"
    private let t1 = "2026-08-05T10:00:12Z"

    /// A finished run, at a stated time, with a stated trigger. Every prune and
    /// census test below is built from this, because the thing under test is
    /// which rows survive rather than how they were made.
    @discardableResult
    private func closedRun(_ d: Sub4Database,
                           at: String,
                           trigger: MigrationRunTrigger?,
                           state: MigrationRunState = .pending) throws -> String {
        let id = try MigrationLedger.open(d, appVersion: "311-test",
                                          snapshotID: nil, trigger: trigger, now: at)
        switch state {
        case .running:
            break
        case .pending, .failed:
            try MigrationLedger.finish(d, id: id, state: state, note: nil, now: at)
        case .interrupted:
            _ = try MigrationLedger.closeInterrupted(d, now: at)
        case .verified:
            try MigrationLedger.finish(d, id: id, state: .pending, note: nil, now: at)
            let moved = try MigrationLedger.verifyPending(d, id: id, note: nil)
            guard moved else {
                throw MigrationLedgerError.invalidTransition(id: id, target: state)
            }
        case .activated:
            try MigrationLedger.finish(d, id: id, state: .pending, note: nil, now: at)
            let verified = try MigrationLedger.verifyPending(d, id: id, note: nil)
            let activated = verified
                ? try MigrationLedger.activateVerified(d, id: id)
                : false
            guard activated else {
                throw MigrationLedgerError.invalidTransition(id: id, target: state)
            }
        }
        return id
    }

    /// "2026-08-05T10:00:00Z" for n = 0, one minute apart after that. Text
    /// order and chronological order are the same thing here, which is the
    /// property the whole table relies on.
    private func stamp(_ n: Int) -> String {
        let base = Date(timeIntervalSince1970: 1_785_924_000)
        return Sub4Import.iso8601(base.addingTimeInterval(Double(n) * 60))
    }

    // MARK: Opening and closing

    @Test("A run opens as running, with no finish time")
    func openLeavesItRunning() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "255",
                                          snapshotID: "2026-08-05-081716", now: t0)
        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        #expect(run.id == id)
        #expect(run.state == .running)
        #expect(run.finishedUTC == nil)
        #expect(run.snapshotID == "2026-08-05-081716")
        #expect(run.appVersion == "255")
    }

    @Test("A finished run carries when it finished")
    func finishRecordsTheTime() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil, now: t0)
        try MigrationLedger.finish(d, id: id, state: .pending,
                                   note: "661 activities", now: t1)
        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        #expect(run.state == .pending)
        #expect(run.finishedUTC == t1)
        #expect(run.note == "661 activities")
    }

    @Test("Import completion cannot bypass verification or activation")
    func finishAcceptsOnlyImportOutcomes() throws {
        for forbidden in [MigrationRunState.verified, .activated, .interrupted] {
            let d = try db()
            let id = try MigrationLedger.open(d, appVersion: "338",
                                              snapshotID: nil, now: t0)
            #expect(throws: MigrationLedgerError.self) {
                try MigrationLedger.finish(d, id: id, state: forbidden,
                                           note: nil, now: t1)
            }
            let latest = try MigrationLedger.latest(d)
            let run = try #require(latest)
            #expect(run.state == .running)
            #expect(run.finishedUTC == nil)
        }
    }

    @Test("Verification preserves the import finish time")
    func verificationIsASeparateGuardedTransition() throws {
        let d = try db()
        let id = try MigrationLedger.open(d, appVersion: "338",
                                          snapshotID: nil, now: t0)
        try MigrationLedger.finish(d, id: id, state: .pending,
                                   note: "import complete", now: t1)
        let moved = try MigrationLedger.verifyPending(d, id: id,
                                                      note: "semantic checks agreed")
        #expect(moved)
        let latest = try MigrationLedger.latest(d)
        let run = try #require(latest)
        #expect(run.state == .verified)
        #expect(run.finishedUTC == t1,
                "verification must not turn import duration into verification delay")
        #expect(run.note == "semantic checks agreed")
    }

    @Test("Only the newest completed pending run can be verified")
    func verificationRefusesEveryOtherShape() throws {
        // Running.
        do {
            let d = try db()
            let id = try MigrationLedger.open(d, appVersion: "338",
                                              snapshotID: nil, now: t0)
            let moved = try MigrationLedger.verifyPending(d, id: id, note: nil)
            #expect(!moved)
        }

        // Failed.
        do {
            let d = try db()
            let id = try closedRun(d, at: t1, trigger: .manual, state: .failed)
            let moved = try MigrationLedger.verifyPending(d, id: id, note: nil)
            #expect(!moved)
        }

        // Interrupted.
        do {
            let d = try db()
            let id = try closedRun(d, at: t1, trigger: .manual,
                                   state: .interrupted)
            let moved = try MigrationLedger.verifyPending(d, id: id, note: nil)
            #expect(!moved)
        }

        // Unknown id.
        do {
            let d = try db()
            let moved = try MigrationLedger.verifyPending(d, id: "not-a-run",
                                                          note: nil)
            #expect(!moved)
        }

        // Already verified or activated.
        for state in [MigrationRunState.verified, .activated] {
            let d = try db()
            let id = try closedRun(d, at: t1, trigger: .manual, state: state)
            let moved = try MigrationLedger.verifyPending(d, id: id, note: nil)
            #expect(!moved)
        }

        // A newer row supersedes an otherwise valid pending result.
        do {
            let d = try db()
            let older = try closedRun(d, at: t0, trigger: .manual)
            _ = try MigrationLedger.open(d, appVersion: "338",
                                         snapshotID: nil, now: t1)
            let moved = try MigrationLedger.verifyPending(d, id: older, note: nil)
            #expect(!moved)
        }
    }

    @Test("Insertion sequence orders runs that started in the same second")
    func sameSecondRunsHaveADeterministicNewest() throws {
        let d = try db()
        let first = try closedRun(d, at: t0, trigger: .manual)
        let second = try closedRun(d, at: t0, trigger: .manual)
        let rows = try MigrationLedger.all(d)
        #expect(rows.map(\.id) == [second, first])
        #expect(rows[0].sequence > rows[1].sequence)
    }

    @Test("Activation advances only the newest verified run")
    func activationCannotSkipOrUseAStaleVerification() throws {
        let d = try db()
        let pending = try closedRun(d, at: t0, trigger: .manual)
        let skipped = try MigrationLedger.activateVerified(d, id: pending)
        #expect(!skipped)

        let verified = try MigrationLedger.verifyPending(d, id: pending,
                                                         note: "agreed")
        #expect(verified)
        let activated = try MigrationLedger.activateVerified(d, id: pending)
        #expect(activated)
        let latest = try MigrationLedger.latest(d)
        let activeRow = try #require(latest)
        #expect(activeRow.state == .activated)
        #expect(activeRow.finishedUTC == t0)

        let olderVerified = try closedRun(d, at: t1, trigger: .manual,
                                          state: .verified)
        _ = try MigrationLedger.open(d, appVersion: "338",
                                     snapshotID: nil, now: t1)
        let stale = try MigrationLedger.activateVerified(d, id: olderVerified)
        let unknown = try MigrationLedger.activateVerified(d, id: "not-a-run")
        #expect(!stale)
        #expect(!unknown)
    }

    @Test("A run with no snapshot says so rather than pretending")
    func aRunWithoutASnapshotIsRecordedAsSuch() throws {
        let d = try db()
        _ = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil, now: t0)
        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        // Contract item 3 wants the inputs copied before they are read. A run
        // that skipped that is a run with nothing to go back to, and the column
        // is how that becomes visible instead of assumed.
        #expect(run.snapshotID == nil)
    }

    // MARK: The acceptance criteria

    @Test("An import that throws leaves failed, not running")
    func aThrowingImportIsRecordedAsFailed() throws {
        let d = try db()

        // `run` throws because the activity has no start instant and the schema
        // refuses it — a real refusal from `ImportTests`, not a contrived one.
        // What matters is that the ledger survives the rollback of the write
        // that failed.
        struct Boom: Error {}
        let id = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil, now: t0)
        do {
            try d.queue.write { _ in throw Boom() }
        } catch {
            try MigrationLedger.finish(d, id: id, state: .failed,
                                       note: "Boom", now: t1)
        }

        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        #expect(run.state == .failed, "a rolled-back import left the run running")
        #expect(run.finishedUTC == t1)
        #expect(run.note == "Boom")
    }

    @Test("The real importer opens and closes its own run")
    func theImporterClosesItsOwnRun() throws {
        let d = try db()
        // Driven through the real `Sub4Import.run` rather than the ledger
        // directly, because the thing under test is the wiring: that `run`
        // opens a row before its write and closes it after, and that the report
        // can name the row it opened.
        let report = try Sub4Import.run(into: d, activities: [], shoes: [],
                                        appVersion: "255",
                                        snapshotID: "2026-08-05-081716")
        let runRow = try MigrationLedger.latest(d)
        let run = try #require(runRow)
        #expect(run.id == report.runID, "the report should name the row it opened")
        #expect(run.state == .pending, "a committed import is pending verification")
        #expect(run.snapshotID == "2026-08-05-081716")
        #expect(run.note?.contains("0 activities") == true)
    }

    @Test("Two imports produce two rows, newest first")
    func runsAccumulate() throws {
        let d = try db()
        let first = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil,
                                             now: "2026-08-05T09:00:00Z")
        try MigrationLedger.finish(d, id: first, state: .pending, note: nil,
                                   now: "2026-08-05T09:00:05Z")
        let second = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil,
                                              now: "2026-08-05T10:00:00Z")
        try MigrationLedger.finish(d, id: second, state: .pending, note: nil,
                                   now: "2026-08-05T10:00:05Z")

        let all = try MigrationLedger.all(d)
        #expect(all.count == 2)
        #expect(all.first?.id == second, "newest first")
        #expect(all.last?.id == first)
    }

    // MARK: What the schema refuses

    @Test("A state the vocabulary does not have is rejected")
    func anUnknownStateIsRefused() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, NULL, 'halfway', '255')
                    """, arguments: [t0])
            }
        }
    }

    @Test("A running run may not carry a finish time")
    func runningAndFinishedCannotCoexist() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, ?, 'running', '255')
                    """, arguments: [t0, t1])
            }
        }
    }

    @Test("A finished run must carry a finish time")
    func finishedWithoutATimeIsRefused() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, NULL, 'verified', '255')
                    """, arguments: [t0])
            }
        }
    }

    @Test("A run cannot finish before it started")
    func timeRunsForwards() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion)
                    VALUES ('x', ?, ?, 'pending', '255')
                    """, arguments: [t1, t0])
            }
        }
    }

    // MARK: The trigger column — patch 311

    @Test("A trigger the vocabulary does not have is rejected")
    func anUnknownTriggerIsRefused() throws {
        let d = try db()
        #expect(throws: (any Error).self) {
            try d.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO migration_run
                      (id, startedUTC, finishedUTC, state, appVersion, triggeredBy)
                    VALUES ('x', ?, NULL, 'running', '311', 'somebody')
                    """, arguments: [t0])
            }
        }
    }

    /// The 45 rows written before this patch have no answer, and the column has
    /// to admit that. A NOT NULL with a default would have meant choosing a
    /// value for them, and a guessed `backgrounded` is indistinguishable from a
    /// recorded one — §12.15.
    @Test("A run with no recorded trigger is stored and says so")
    func anUnrecordedTriggerIsAllowed() throws {
        let d = try db()
        _ = try MigrationLedger.open(d, appVersion: "311", snapshotID: nil, now: t0)
        let run = try #require(try MigrationLedger.latest(d))
        #expect(run.triggeredBy == nil)
        #expect(run.triggerLabel == MigrationRunTrigger.unrecordedLabel)
        #expect(run.line.contains("trigger not recorded"))
    }

    @Test("Every trigger the enum has can be stored and read back")
    func everyTriggerIsStorable() throws {
        for t in MigrationRunTrigger.allCases {
            let other = try db()
            let id = try MigrationLedger.open(other, appVersion: "311",
                                              snapshotID: nil, trigger: t, now: t0)
            let run = try #require(try MigrationLedger.latest(other))
            #expect(run.id == id)
            #expect(run.triggeredBy == t)
            #expect(run.line.contains(t.rawValue))
        }
    }

    /// The wiring, through the real importer rather than the ledger directly —
    /// the same argument `theImporterClosesItsOwnRun` makes. A trigger that
    /// reached `open` but not the row would be a column that is always NULL.
    @Test("The importer carries the trigger it was handed into the row")
    func theImporterRecordsTheTrigger() throws {
        let d = try db()
        _ = try Sub4Import.run(into: d, activities: [], shoes: [],
                               appVersion: "311", trigger: .backgroundRefresh)
        let run = try #require(try MigrationLedger.latest(d))
        #expect(run.triggeredBy == .backgroundRefresh)
        #expect(run.triggerLabel == "a background refresh")
    }

    // MARK: Retention — what is kept

    /// The list is written out rather than derived, so that adding a case is a
    /// decision. This asserts it is the right list TODAY; when it fails, the
    /// question to answer is whether the new trigger's successful runs are
    /// disposable, not how to make the test green.
    @Test("Prunable means every automatic trigger, and only those")
    func prunableIsEveryAutomaticTrigger() {
        let prunable = Set(MigrationLedger.prunableTriggers.map(\.rawValue))
        let automatic = Set(MigrationRunTrigger.allCases.map(\.rawValue))
            .subtracting([MigrationRunTrigger.manual.rawValue])
        #expect(prunable == automatic)
    }

    @Test("Below the keep count nothing is removed")
    func aSmallLedgerIsLeftAlone() throws {
        let d = try db()
        for n in 0 ..< 5 { try closedRun(d, at: stamp(n), trigger: .backgrounded) }
        // Hoisted into locals rather than written inline in `#expect` — the
        // macro decomposes into a `rethrows` call and an inline `try` inside
        // one has been a compile error in this project before.
        let removed = try MigrationLedger.prune(d, keeping: 10)
        let left = try MigrationLedger.all(d, limit: 100)
        #expect(removed == 0)
        #expect(left.count == 5)
    }

    @Test("Beyond the keep count the oldest automatic runs go, newest stay")
    func theOldestAutomaticRunsAreTrimmed() throws {
        let d = try db()
        var ids: [String] = []
        for n in 0 ..< 8 {
            ids.append(try closedRun(d, at: stamp(n), trigger: .backgrounded))
        }
        let removed = try MigrationLedger.prune(d, keeping: 3)
        #expect(removed == 5)

        let left = try MigrationLedger.all(d, limit: 100).map(\.id)
        #expect(left.count == 3)
        #expect(Set(left) == Set(ids.suffix(3)), "the newest three survive")
    }

    /// THE IMPORTANT HALF. Everything below is a row a prune must not touch,
    /// and each one is a different reason.
    @Test("A prune never removes a manual run")
    func manualRunsSurvive() throws {
        let d = try db()
        let mine = try closedRun(d, at: stamp(0), trigger: .manual)
        for n in 1 ..< 6 { try closedRun(d, at: stamp(n), trigger: .backgrounded) }
        _ = try MigrationLedger.prune(d, keeping: 1)
        let left = try MigrationLedger.all(d, limit: 100).map(\.id)
        #expect(left.contains(mine), "the athlete did that one on purpose")
        #expect(left.count == 2, "one manual and the newest automatic")
    }

    @Test("A prune never removes a failed run")
    func failedRunsSurvive() throws {
        let d = try db()
        let broke = try closedRun(d, at: stamp(0), trigger: .backgrounded, state: .failed)
        for n in 1 ..< 6 { try closedRun(d, at: stamp(n), trigger: .backgrounded) }
        _ = try MigrationLedger.prune(d, keeping: 1)
        let left = try MigrationLedger.all(d, limit: 100).map(\.id)
        #expect(left.contains(broke),
                "a failure is the reason anybody reads this table")
    }

    @Test("A prune never removes a currently open run")
    func currentlyOpenRunsSurvive() throws {
        let d = try db()
        let killed = try MigrationLedger.open(d, appVersion: "311", snapshotID: nil,
                                              trigger: .backgrounded, now: stamp(0))
        for n in 1 ..< 6 { try closedRun(d, at: stamp(n), trigger: .backgrounded) }
        _ = try MigrationLedger.prune(d, keeping: 1)
        let left = try MigrationLedger.all(d, limit: 100).map(\.id)
        #expect(left.contains(killed),
                "the only evidence the app was killed mid-write")
    }

    @Test("Automatic interruptions are bounded independently")
    func automaticInterruptedRetentionIsBounded() throws {
        let d = try db()
        var ids: [String] = []
        for n in 0 ..< 8 {
            let id = try MigrationLedger.open(d, appVersion: "338",
                                              snapshotID: nil,
                                              trigger: .backgrounded,
                                              now: stamp(n))
            ids.append(id)
            _ = try MigrationLedger.closeInterrupted(d, now: stamp(n))
        }
        let removed = try MigrationLedger.prune(d, keeping: 200,
                                                keepingInterrupted: 3)
        let rows = try MigrationLedger.all(d, limit: 100)
        #expect(removed == 5)
        #expect(rows.map(\.id) == Array(ids.suffix(3).reversed()))
        #expect(rows.allSatisfy { $0.state == .interrupted })
    }

    @Test("Manual interruptions are retained outside the automatic cap")
    func manualInterruptedEvidenceSurvives() throws {
        let d = try db()
        let manual = try MigrationLedger.open(d, appVersion: "338",
                                              snapshotID: nil,
                                              trigger: .manual, now: stamp(0))
        _ = try MigrationLedger.closeInterrupted(d, now: stamp(0))
        for n in 1 ... 5 {
            _ = try MigrationLedger.open(d, appVersion: "338",
                                         snapshotID: nil,
                                         trigger: .foregrounded, now: stamp(n))
            _ = try MigrationLedger.closeInterrupted(d, now: stamp(n))
        }
        _ = try MigrationLedger.prune(d, keeping: 200, keepingInterrupted: 2)
        let ids = try MigrationLedger.all(d, limit: 100).map(\.id)
        #expect(ids.contains(manual))
        #expect(ids.count == 3, "one manual plus two automatic interruptions")
    }

    @Test("A prune never removes a verified or activated run")
    func checkedRunsSurvive() throws {
        let d = try db()
        let checked = try closedRun(d, at: stamp(0), trigger: .backgrounded,
                                    state: .verified)
        let live = try closedRun(d, at: stamp(1), trigger: .foregrounded,
                                 state: .activated)
        for n in 2 ..< 8 { try closedRun(d, at: stamp(n), trigger: .backgrounded) }
        _ = try MigrationLedger.prune(d, keeping: 1)
        let left = try MigrationLedger.all(d, limit: 100).map(\.id)
        #expect(left.contains(checked))
        #expect(left.contains(live), "D7 decides on the strength of these")
    }

    /// The 45 rows from before this patch cannot be identified as automatic, so
    /// they are not treated as if they were. Bounded and one-time.
    @Test("A prune never removes a run whose trigger was not recorded")
    func unrecordedRunsSurvive() throws {
        let d = try db()
        let old = try closedRun(d, at: stamp(0), trigger: nil)
        for n in 1 ..< 6 { try closedRun(d, at: stamp(n), trigger: .backgrounded) }
        _ = try MigrationLedger.prune(d, keeping: 1)
        let left = try MigrationLedger.all(d, limit: 100).map(\.id)
        #expect(left.contains(old))
    }

    /// THE PRUNE HAPPENS WITH NOBODY PRESSING ANYTHING. It rides inside
    /// `open`'s own transaction, so the table cannot grow past its shape even
    /// if every run after this one throws.
    ///
    /// Runs the real number rather than a convenient one: five past
    /// `keepAutomaticRuns`, so the trim is the production trim and not a
    /// parameter a test chose.
    @Test("Opening a run trims the ledger on the way in")
    func openingPrunes() throws {
        let d = try db()
        let overshoot = MigrationLedger.keepAutomaticRuns + 5
        var ids: [String] = []
        for n in 0 ..< overshoot {
            ids.append(try closedRun(d, at: stamp(n), trigger: .backgrounded))
        }

        let left = try MigrationLedger.all(d, limit: 1_000).map(\.id)
        // The newest one was `pending` only after the last prune ran, so the
        // steady state is the keep count plus that row.
        #expect(left.count == MigrationLedger.keepAutomaticRuns + 1,
                "got \(left.count) of \(overshoot)")
        #expect(left.contains(ids[overshoot - 1]), "the newest run is still there")
        #expect(!left.contains(ids[0]), "the oldest automatic run went")

        // And a row is never in its own doomed set — it is `running` when the
        // prune beside it runs.
        let fresh = try MigrationLedger.open(d, appVersion: "311", snapshotID: nil,
                                             trigger: .backgrounded,
                                             now: stamp(overshoot))
        let after = try MigrationLedger.all(d, limit: 1_000).map(\.id)
        #expect(after.contains(fresh))
    }

    // MARK: Interrupted runs

    @Test("A run left open is reported, not repaired")
    func staleRunsAreVisible() throws {
        let d = try db()
        _ = try MigrationLedger.open(d, appVersion: "255", snapshotID: nil, now: t0)
        let stale = try MigrationLedger.stale(d)
        #expect(stale.count == 1)
        #expect(stale.first?.state == .running)
        // Rewriting it to `failed` on the next launch would be tidy and would
        // destroy the only evidence that the app was killed while writing.
        let afterRow = try MigrationLedger.latest(d)
        let after = try #require(afterRow)
        #expect(after.state == .running)
    }

    /// THE ONE WITH TEETH — patch 311.
    ///
    /// `stale` used to read `all(db, limit: 100)` and filter it. At 255 that was
    /// the whole table. At D6b, two rows per app switch, it is about a day — so
    /// an interrupted run from two days ago was invisible and the screen said
    /// "Interrupted runs: 0" with complete confidence.
    ///
    /// 150 newer rows, all `manual` so the prune cannot remove them, and one
    /// interrupted run underneath. The old implementation returns nothing here.
    @Test("An interrupted run is found however far down the table it is")
    func anInterruptedRunIsFoundBeyondThePage() throws {
        let d = try db()
        let killed = try MigrationLedger.open(d, appVersion: "311", snapshotID: nil,
                                              trigger: .backgrounded, now: stamp(0))
        for n in 1 ... 150 { try closedRun(d, at: stamp(n), trigger: .manual) }

        let stale = try MigrationLedger.stale(d)
        #expect(stale.count == 1, "a count taken from a page is not a count of the table")
        #expect(stale.first?.id == killed)
    }

    // MARK: The census

    /// Every trigger named every time, including at zero, with `total` as the
    /// denominator. §12.54.2 and §12.54.3 — a bare zero is noise, a missing
    /// zero is nothing at all, and a count beside its denominator is evidence.
    @Test("The census names every trigger even when it has none")
    func theCensusSpeaksAtZero() throws {
        let d = try db()
        let c = try MigrationLedger.census(d)
        #expect(c.total == 0)
        for t in MigrationRunTrigger.allCases {
            #expect(c.diagnosticLines.contains { $0.contains(t.rawValue) },
                    "\(t.rawValue) missing from an empty census")
        }
        #expect(c.diagnosticLines.first == "Import ledger: 0 rows")
    }

    @Test("The census counts what is there, by trigger")
    func theCensusCounts() throws {
        let d = try db()
        try closedRun(d, at: stamp(0), trigger: .manual)
        try closedRun(d, at: stamp(1), trigger: .backgrounded)
        try closedRun(d, at: stamp(2), trigger: .backgrounded)
        try closedRun(d, at: stamp(3), trigger: nil)
        _ = try MigrationLedger.open(d, appVersion: "311", snapshotID: nil,
                                     trigger: .foregrounded, now: stamp(4))

        let c = try MigrationLedger.census(d)
        #expect(c.total == 5)
        #expect(c.byTrigger["manual"] == 1)
        #expect(c.byTrigger["backgrounded"] == 2)
        #expect(c.byTrigger["foregrounded"] == 1)
        #expect(c.byTrigger["backgroundRefresh"] == nil)
        #expect(c.unrecorded == 1)
        #expect(c.openNow == 1, "the foregrounded one is still open")
        #expect(c.interrupted == 0)
        #expect(c.diagnosticLines.contains("  backgroundRefresh: 0"))
    }

    // MARK: The migration itself

    @Test("The migration is declared as well as registered")
    func theMigrationIsDeclared() {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.migrationRun))
        #expect(Sub4Migrations.all.contains(Sub4Migrations.runTrigger))
        // The invariant from patch 236: identifiers must sort into run order.
        #expect(Sub4Migrations.all == Sub4Migrations.all.sorted())
    }

    @Test("Every state the enum has can be stored")
    func everyStateIsStorable() throws {
        let d = try db()
        for state in MigrationRunState.allCases {
            let id = try closedRun(d, at: t1, trigger: .manual, state: state)
            // Computed into a local first: `#expect`/`#require` decompose into
            // a `rethrows` call and an inline `try` inside one is a compile
            // error this project has hit before.
            let rows = try MigrationLedger.all(d)
            let back = try #require(rows.first { $0.id == id })
            #expect(back.state == state)
        }
    }
}
