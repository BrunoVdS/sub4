//
//  VerifiedRunVisibilityTests.swift
//  Sub4CoreTests
//
//  Patch 340. Whether a verified run can be READ, which is a different
//  question from whether one can be written.
//
//  WHAT THESE ARE FOR
//  ------------------
//  `verifyPending` has worked since patch 263 and `SemanticVerifierTests`
//  proves it. Nothing proved that a person — or a paste — could find out
//  afterwards that it had happened, and on 10 August 2026 the answer was that
//  they could not: `LedgerCensus` did not count the state, and the verifier's
//  report lived in a `@State` property that died with the sheet.
//
//  D7's entry gate is the sentence *"a verified run exists over the current
//  data"*. These are the tests for that sentence.
//
//  TWO HALVES, AND THEY FAIL DIFFERENTLY
//  -------------------------------------
//  The census is the DURABLE half: it survives every launch and answers "has
//  this database ever been verified". `VerificationResult` is the CURRENT half:
//  it answers "what did the last press find", survives the sheet, and dies with
//  the launch. Neither can replace the other.
//
//  THE THREE WITH TEETH
//  --------------------
//  · `aVerifiedRunWithNoNoteIsStillAVerifiedRun` — the §12.15 assertion. An
//    implementation reading the note column with `String.fetchOne` would return
//    nil for a verified run that recorded no note, and nil is what "there is no
//    verified run" also looks like. Two opposite facts wearing one appearance,
//    which is §12.87's shape and this project's most expensive one.
//  · `anActivatedRunStillCountsAsVerified` — the §12.54.2 assertion, and it is
//    about NEXT WEEK. D7 moves a verified run to `activated`. A census counting
//    only `verified` would print "never" over a database that had just passed
//    the gate, which is the exact defect this patch exists to close.
//  · `aPassingReportWhoseLedgerRefusedIsNotHealthy` — a comparison that agreed
//    and a ledger row that moved are separate facts. Until 338 the second sat
//    behind a `try?`; this states that they are still separate.
//
//  NO `Sub4Migrations.all.last ==` ASSERTION — CLAUDE.md's rule. This patch
//  adds no migration at all: `verified` has been in the CHECK since 255.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A verified run somebody can find afterwards")
struct VerifiedRunVisibilityTests {

    private func db() throws -> Sub4Database {
        try Sub4Database.inMemory(label: "verified-visibility")
    }

    /// "2026-08-10T09:00:00Z" for n = 0, a minute apart after that — the same
    /// shape `MigrationLedgerTests.stamp` uses, because text order and
    /// chronological order have to be the same thing.
    private func stamp(_ n: Int) -> String {
        let base = Date(timeIntervalSince1970: 1_786_698_000)
        return Sub4Import.iso8601(base.addingTimeInterval(Double(n) * 60))
    }

    /// A run taken all the way to `verified`, with whatever note was given.
    ///
    /// `note` DEFAULTS TO NIL on purpose: that is the case the third test below
    /// is about, and a fixture that always supplied a note would make it
    /// impossible to write.
    @discardableResult
    private func verifiedRun(_ d: Sub4Database, at: String,
                             note: String? = nil) throws -> String {
        let id = try MigrationLedger.open(d, appVersion: "340-test",
                                          snapshotID: nil, trigger: .manual, now: at)
        try MigrationLedger.finish(d, id: id, state: .pending, note: nil, now: at)
        let moved = try MigrationLedger.verifyPending(d, id: id, note: note)
        #expect(moved, "the fixture could not reach verified")
        return id
    }

    // MARK: The census — the durable half

    @Test("An unverified database says so, in all three lines")
    func nothingVerifiedSaysNever() throws {
        let d = try db()
        let c = try MigrationLedger.census(d)
        #expect(c.everVerified == 0)
        #expect(c.newestVerified == nil)

        let text = c.diagnosticLines.joined(separator: "\n")
        #expect(text.contains("runs ever verified: 0"))
        #expect(text.contains("newest verified run: never"))
        // §12.54.2 — the third line prints too, saying why it has no number.
        #expect(text.contains("runs opened since it: not applicable"))
        #expect(c.runsSinceVerified == nil)
    }

    @Test("A verified run is counted and named")
    func aVerifiedRunIsCounted() throws {
        let d = try db()
        try verifiedRun(d, at: stamp(0), note: "20 comparisons, all agreed")

        let c = try MigrationLedger.census(d)
        #expect(c.everVerified == 1)
        let newest = try #require(c.newestVerified)
        #expect(newest.startedUTC == stamp(0))
        #expect(newest.appVersion == "340-test")
        #expect(newest.note == "20 comparisons, all agreed")
        #expect(newest.line.contains("20 comparisons, all agreed"))

        let text = c.diagnosticLines.joined(separator: "\n")
        #expect(text.contains("runs ever verified: 1"))
        #expect(!text.contains("newest verified run: never"))
        #expect(c.runsSinceVerified == 0, "nothing has been opened since")
        #expect(text.contains("runs opened since it: 0"))
    }

    /// THE CURRENTNESS LINE, AND IT MUST SURVIVE THE PRUNE. `runsSinceVerified`
    /// is `MAX(sequence) - sequence`, not a count of rows, because the ledger
    /// deletes all but the newest 200 successful automatic runs. Counting rows
    /// would report 200 where 220 runs had happened — and the whole job of this
    /// line is to say whether the verification still describes the newest thing
    /// the ledger knows about.
    @Test("Runs opened since a verified one are counted through the prune")
    func runsSinceSurvivesThePrune() throws {
        let d = try db()
        try verifiedRun(d, at: stamp(0), note: "all agreed")

        for n in 1 ... 220 {
            let id = try MigrationLedger.open(d, appVersion: "340-test",
                                              snapshotID: nil,
                                              trigger: .backgrounded,
                                              now: stamp(n))
            try MigrationLedger.finish(d, id: id, state: .pending,
                                       note: nil, now: stamp(n))
        }

        let c = try MigrationLedger.census(d)
        #expect(c.total < 220, "the prune ran, so rows are gone")
        #expect(c.everVerified == 1, "a verified run is never pruned")
        #expect(c.runsSinceVerified == 220,
                "counted from the sequence, not from the surviving rows")
    }

    /// THE §12.15 ASSERTION. A verified run that recorded no note and no
    /// verified run at all are opposite facts, and an implementation that read
    /// the note column instead of the row would give them the same appearance.
    @Test("A verified run with no note is still a verified run")
    func aVerifiedRunWithNoNoteIsStillAVerifiedRun() throws {
        let d = try db()
        try verifiedRun(d, at: stamp(0), note: nil)

        let c = try MigrationLedger.census(d)
        #expect(c.everVerified == 1)
        let newest = try #require(c.newestVerified,
                                  "a NULL note is not an absent run")
        #expect(newest.note == nil)
        #expect(newest.line.contains("no note recorded"))

        let text = c.diagnosticLines.joined(separator: "\n")
        #expect(!text.contains("newest verified run: never"))
    }

    /// THE §12.54.2 ASSERTION, AND IT IS ABOUT D7. `activateVerified` refuses
    /// any source state but `verified`, so an activated run is a verified run
    /// that went one rung further. Counting only `verified` would make this
    /// line read "never" the moment the gate is passed.
    @Test("An activated run still counts as verified")
    func anActivatedRunStillCountsAsVerified() throws {
        let d = try db()
        let id = try verifiedRun(d, at: stamp(0), note: "all agreed")
        let activated = try MigrationLedger.activateVerified(d, id: id,
                                                             note: "D7")
        #expect(activated)

        let c = try MigrationLedger.census(d)
        #expect(c.everVerified == 1, "activated is downstream of verified")
        let newest = try #require(c.newestVerified)
        #expect(newest.state == .activated, "the line names which rung it is on")
        #expect(newest.line.contains("activated"))
    }

    /// Newest by SEQUENCE, not by text. Two verifications a minute apart, and
    /// the second one is the answer.
    @Test("The newest verified run is the newest one")
    func theNewestVerifiedRunWins() throws {
        let d = try db()
        try verifiedRun(d, at: stamp(0), note: "the older one")
        try verifiedRun(d, at: stamp(1), note: "the newer one")

        let c = try MigrationLedger.census(d)
        #expect(c.everVerified == 2)
        let newest = try #require(c.newestVerified)
        #expect(newest.note == "the newer one")
    }

    /// A NEGATIVE CONTROL. Pending, failed and interrupted rows are not
    /// verified rows, and a census that counted `total` by mistake would pass
    /// every test above.
    @Test("Rows that are not verified are not counted as verified")
    func unverifiedStatesAreNotCounted() throws {
        let d = try db()
        let pending = try MigrationLedger.open(d, appVersion: "340-test",
                                               snapshotID: nil,
                                               trigger: .backgrounded,
                                               now: stamp(0))
        try MigrationLedger.finish(d, id: pending, state: .pending,
                                   note: nil, now: stamp(0))
        let broken = try MigrationLedger.open(d, appVersion: "340-test",
                                              snapshotID: nil,
                                              trigger: .manual, now: stamp(1))
        try MigrationLedger.finish(d, id: broken, state: .failed,
                                   note: "it threw", now: stamp(1))
        _ = try MigrationLedger.open(d, appVersion: "340-test", snapshotID: nil,
                                     trigger: .foregrounded, now: stamp(2))
        _ = try MigrationLedger.closeInterrupted(d, now: stamp(3))

        let c = try MigrationLedger.census(d)
        #expect(c.total == 3)
        #expect(c.everVerified == 0)
        #expect(c.newestVerified == nil)
    }

    // MARK: The last press — the current half

    private func passing() -> VerificationReport {
        VerificationReport(checks: [
            .compare("activities", table: "activity", expected: 680, found: 680),
            .compare("notes", table: "user_note", expected: 1, found: 1)
        ], seconds: 0.05)
    }

    private func failing() -> VerificationReport {
        VerificationReport(checks: [
            .compare("activities", table: "activity", expected: 680, found: 680),
            .compare("notes", table: "user_note", expected: 1, found: 0)
        ], seconds: 0.05)
    }

    @Test("Not having pressed it says so, and is not a fault")
    func neverSaysSo() {
        let o = VerificationResult.Outcome.never
        #expect(o.isHealthy, "not having looked is not a failure")
        #expect(o.report == nil)
        #expect(o.diagnosticLines == ["Verification: not run since this launch."])
    }

    @Test("A passing report over a marked ledger is the pass")
    func aMarkedLedgerIsThePass() {
        let o = VerificationResult.Outcome.ran(passing(), ledger: .marked)
        #expect(o.isHealthy)
        #expect(o.ledgerAgreed)
        #expect(o.ledgerLine == "the run is marked verified")
        #expect(o.line.contains("2 comparisons agreed"))
    }

    /// THE ONE 338 MADE VISIBLE ON SCREEN AND 340 MAKES VISIBLE IN THE PASTE.
    /// Every comparison agreed and the ledger did not move. Before 338 that
    /// looked identical to a clean pass; it must not look like one here.
    @Test("A passing report whose ledger refused is not healthy")
    func aPassingReportWhoseLedgerRefusedIsNotHealthy() {
        let o = VerificationResult.Outcome.ran(passing(), ledger: .notTheNewestRun)
        #expect(!o.isHealthy, "a passing report is not a verified run")
        #expect(!o.ledgerAgreed)
        #expect(o.ledgerLine.contains("import again"))
    }

    @Test("A failing report is not healthy and says why the ledger held")
    func aFailingReportIsNotHealthy() {
        let o = VerificationResult.Outcome.ran(failing(), ledger: .reportDidNotPass)
        #expect(!o.isHealthy)
        #expect(!o.ledgerAgreed)
        #expect(o.line.contains("1 of 2 disagreed"))
    }

    /// Five outcomes, five sentences, none of them empty and none of them the
    /// same. A case added later with no wording would read as another case's.
    @Test("Every ledger outcome has its own sentence")
    func everyLedgerOutcomeIsNamed() {
        let all: [VerificationResult.Ledger] = [
            .marked, .reportDidNotPass, .notTheNewestRun,
            .failed("SQLite error 5"), .noRun
        ]
        let lines = all.map(\.line)
        #expect(Set(lines).count == all.count, "two outcomes read the same")
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(all.filter(\.agreed) == [.marked], "only one of them is a pass")
    }

    /// The paste carries the ledger sentence under the comparisons. Without it
    /// somebody reading the file later sees "agreed" and cannot tell whether
    /// anything was recorded.
    @Test("The paste carries the ledger sentence")
    func thePasteCarriesTheLedger() {
        let o = VerificationResult.Outcome.ran(passing(), ledger: .marked)
        let lines = o.diagnosticLines
        #expect(lines.first?.contains("agreed") == true)
        #expect(lines.last == "  ledger: the run is marked verified")
    }

    @MainActor
    @Test("Recording a press replaces the outcome")
    func recordingReplacesTheOutcome() {
        let v = VerificationResult.shared
        v.record(passing(), ledger: .marked)
        let after = v.last
        #expect(after.report?.checks.count == 2)
        #expect(after.ledger == .marked)
    }
}
