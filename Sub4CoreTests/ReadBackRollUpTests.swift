//
//  ReadBackRollUpTests.swift
//  Sub4CoreTests
//
//  Patch 333, corrected at 333a. The verdict logic, and the FOUR states it
//  must keep apart.
//
//  WHAT THESE ARE FOR
//  ------------------
//  The roll-up's whole value is that one line can be quoted as the reason it
//  was safe to move on. So the tests that matter are not "green means green" —
//  they are the ones that refuse to call a blind read a pass, and refuse to
//  call an empty comparison agreement.
//
//  333 shipped three states and collapsed two of them in the adapter. These
//  tests did not catch it, because they tested the type and the defect was in
//  the caller: every test below passed while the device reported "could not
//  look" over a database it had read perfectly. `aReadThatSucceededAndFound
//  NothingIsNotBlind` is the one that now states the distinction directly.
//
//  Nothing here touches a database. `ReadBacks` runs the nine and is exercised
//  on the device; this is the arithmetic that turns nine reports into one
//  sentence, and it is the part that can be wrong quietly.
//

import Testing
@testable import Sub4

@MainActor
@Suite("Read-back roll-up")
struct ReadBackRollUpTests {

    private func line(_ name: String = "A",
                      compared: Int = 10,
                      unexplained: Int = 0,
                      couldNotLook: String? = nil) -> ReadBackRollUp.Line {
        .init(name: name, compared: compared, unexplained: unexplained,
              couldNotLook: couldNotLook)
    }

    // MARK: The four verdicts

    @Test func comparedSomethingAndAgreed() {
        let l = line()
        #expect(l.verdict == .agreed)
        #expect(l.isHealthy)
        #expect(!l.isFault)
        #expect(l.value == "10 compared, no differences")
    }

    @Test func comparedSomethingAndDisagreed() {
        let l = line(unexplained: 3)
        #expect(l.verdict == .differed)
        #expect(!l.isHealthy)
        #expect(l.isFault)
        #expect(l.value == "10 compared, 3 differ")
    }

    /// Zero differences over a read that never happened is not agreement, and
    /// the value must say why rather than printing a number.
    @Test func aReadThatDidNotHappenIsNotAgreement() {
        let l = line(compared: 0, couldNotLook: "the details could not be read")
        #expect(l.verdict == .couldNotLook)
        #expect(!l.isHealthy)
        #expect(l.isFault)
        #expect(l.value == "the details could not be read")
    }

    /// THE ONE 333 GOT WRONG. A read that succeeded and found both sides empty
    /// is not blind. It proves nothing, which is a different sentence, a
    /// different colour and a different column.
    @Test func aReadThatSucceededAndFoundNothingIsNotBlind() {
        let l = line(compared: 0)
        #expect(l.verdict == .nothingToCompare)
        #expect(!l.isHealthy)
        #expect(!l.isFault)
        #expect(l.value == "nothing on either side")
    }

    /// A failed read outranks everything. Even numbers that arrived alongside
    /// it describe a comparison that did not happen.
    @Test func aFailedReadOutranksItsOwnNumbers() {
        let l = line(compared: 40, unexplained: 2, couldNotLook: "closed")
        #expect(l.verdict == .couldNotLook)
    }

    // MARK: The outcome

    @Test func neverIsHealthyAndSaysSo() {
        let o = ReadBackRollUp.Outcome.never
        #expect(o.isHealthy)
        #expect(!o.provesSomething)
        #expect(o.line == "Not rolled up since this launch.")
        #expect(o.lines.isEmpty)
    }

    @Test func anEmptyRunIsNotHealthy() {
        let o = ReadBackRollUp.Outcome.ran([])
        #expect(!o.isHealthy)
        #expect(o.line == "Nothing ran.")
    }

    @Test func aFailedOrClosedDatabaseIsNotHealthy() {
        #expect(!ReadBackRollUp.Outcome.noDatabase.isHealthy)
        #expect(!ReadBackRollUp.Outcome.readFailed("locked").isHealthy)
        #expect(ReadBackRollUp.Outcome.readFailed("locked").line
                == "The roll-up could not run — locked")
    }

    /// ALL FOUR TERMS, ALWAYS. A term that disappears at zero cannot be told
    /// from a term nobody wired in — and the sentence exists at all because
    /// "8 of 9 agree" hid two different facts on the first device run.
    @Test func allNineAgreeingStillPrintsEveryTerm() {
        let o = ReadBackRollUp.Outcome.ran((1...9).map { line("R\($0)") })
        #expect(o.isHealthy)
        #expect(o.provesSomething)
        #expect(o.line == "9 of 9 agree · 0 differ · 0 could not look · 0 nothing to compare")
    }

    /// The real 9 August reading, and what it should have said.
    @Test func theFourCountsAreNamedApart() {
        let o = ReadBackRollUp.Outcome.ran([
            line("A"),
            line("B", unexplained: 2),
            line("C", compared: 0, couldNotLook: "the plan could not be read"),
            line("D", compared: 0)
        ])
        #expect(o.healthyCount == 1)
        #expect(o.differingCount == 1)
        #expect(o.blindCount == 1)
        #expect(o.emptyCount == 1)
        #expect(o.line == "1 of 4 agree · 1 differ · 1 could not look · 1 nothing to compare")
    }

    @Test func oneBlindLineIsEnoughToFailTheWhole() {
        let o = ReadBackRollUp.Outcome.ran(
            (1...8).map { line("R\($0)") }
            + [line("R9", compared: 0, couldNotLook: "could not be read")])
        #expect(!o.isHealthy)
        #expect(o.healthyCount == 8)
    }

    /// AN EMPTY COMPARISON DOES NOT TURN IT RED — it is an absence of
    /// evidence, not evidence of a fault — but it also does not let the
    /// roll-up claim it proved anything. Two properties, deliberately.
    @Test func anEmptyComparisonIsNotAFaultAndIsNotProof() {
        let o = ReadBackRollUp.Outcome.ran([line("A"), line("B", compared: 0)])
        #expect(o.isHealthy)
        #expect(!o.provesSomething)
        #expect(o.emptyCount == 1)
    }

    // MARK: The paste

    @Test func everyLineReachesThePaste() {
        let o = ReadBackRollUp.Outcome.ran([line("A"), line("B", unexplained: 1)])
        let l = o.diagnosticLines
        #expect(l.count == 3)
        #expect(l[0].hasPrefix("Read-back roll-up: "))
        #expect(l[1] == "  A: 10 compared, no differences")
        #expect(l[2] == "  B: 10 compared, 1 differ")
    }

    @Test func thePasteSpeaksBeforeAnythingHasRun() {
        let l = ReadBackRollUp.Outcome.never.diagnosticLines
        #expect(l == ["Read-back roll-up: Not rolled up since this launch."])
    }

    // MARK: The runner

    @Test func recordingAResultAdvancesTheRunCounter() {
        let r = ReadBackRollUp()
        #expect(r.runs == 0)
        #expect(r.last == .never)
        r.record([line("A")])
        #expect(r.runs == 1)
        #expect(r.last == .ran([line("A")]))
        r.recordFailure("closed")
        #expect(r.last == .readFailed("closed"))
        // A FAILURE IS NOT A RUN. `runs` answers "did a roll-up complete",
        // and a read that could not happen did not complete one.
        #expect(r.runs == 1)
    }
}
