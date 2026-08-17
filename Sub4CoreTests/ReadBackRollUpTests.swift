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

    /// **`reads:` DEFAULTS TO `.ownRead` HERE, AND THAT IS SAFE FOR THE ONE
    /// REASON `.databaseAlone`'S DEFAULT WAS NOT** — patch 389, against
    /// §12.132.7.
    ///
    /// 388 removed a fixture default of `.databaseAlone` because it was
    /// "independent under every `fed:` set" **by complement** — it happened not
    /// to be self-referential, and the day that stopped implying evidence, every
    /// test leaning on it was quietly testing something else.
    ///
    /// `.ownRead` is independent **by construction**: it means this read-back
    /// went and read the files itself, so no `ExpectationSources` can classify
    /// it otherwise, and `aRowThatReadTheFilesIsNeverSelfReferential` asserts
    /// exactly that against a build feeding everything. The tests below are
    /// about verdicts, and a verdict does not depend on provenance.
    ///
    /// Anything about the fifth count says `reads:` out loud.
    private func line(_ name: String = "A",
                      compared: Int = 10,
                      unexplained: Int = 0,
                      couldNotLook: String? = nil,
                      reads: ReadBackSource = .ownRead("a fixture")) -> ReadBackRollUp.Line {
        .init(name: name, compared: compared, unexplained: unexplained,
              couldNotLook: couldNotLook, reads: reads)
    }

    /// `.allFromFiles` is what a test process really is — nothing is hydrated.
    private func ran(_ lines: [ReadBackRollUp.Line],
                     fed: Set<ExpectationField> = []) -> ReadBackRollUp.Outcome {
        .ran(lines, ExpectationSources(fedByTheDatabase: fed))
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
        let o = ran([])
        #expect(!o.isHealthy)
        #expect(o.line == "Nothing ran.")
    }

    @Test func aFailedOrClosedDatabaseIsNotHealthy() {
        #expect(!ReadBackRollUp.Outcome.noDatabase.isHealthy)
        #expect(!ReadBackRollUp.Outcome.readFailed("locked").isHealthy)
        #expect(ReadBackRollUp.Outcome.readFailed("locked").line
                == "The roll-up could not run — locked")
    }

    /// ALL FIVE TERMS, ALWAYS. A term that disappears at zero cannot be told
    /// from a term nobody wired in — and the sentence exists at all because
    /// "8 of 9 agree" hid two different facts on the first device run. The
    /// fifth is 389's and it hid two more.
    @Test func allNineAgreeingStillPrintsEveryTerm() {
        let o = ran((1...9).map { line("R\($0)") })
        #expect(o.isHealthy)
        #expect(o.provesSomething)
        #expect(o.line == "9 of 9 agree · 0 differ · 0 could not look · "
                        + "0 nothing to compare · 0 read a store the database feeds")
    }

    /// The real 9 August reading, and what it should have said.
    @Test func theFourCountsAreNamedApart() {
        let o = ran([
            line("A"),
            line("B", unexplained: 2),
            line("C", compared: 0, couldNotLook: "the plan could not be read"),
            line("D", compared: 0)
        ])
        #expect(o.healthyCount == 1)
        #expect(o.differingCount == 1)
        #expect(o.blindCount == 1)
        #expect(o.emptyCount == 1)
        #expect(o.line == "1 of 4 agree · 1 differ · 1 could not look · "
                        + "1 nothing to compare · 0 read a store the database feeds")
    }

    @Test func oneBlindLineIsEnoughToFailTheWhole() {
        let o = ran((1...8).map { line("R\($0)") }
                    + [line("R9", compared: 0, couldNotLook: "could not be read")])
        #expect(!o.isHealthy)
        #expect(o.healthyCount == 8)
    }

    /// AN EMPTY COMPARISON DOES NOT TURN IT RED — it is an absence of
    /// evidence, not evidence of a fault — but it also does not let the
    /// roll-up claim it proved anything. Two properties, deliberately.
    @Test func anEmptyComparisonIsNotAFaultAndIsNotProof() {
        let o = ran([line("A"), line("B", compared: 0)])
        #expect(o.isHealthy)
        #expect(!o.provesSomething)
        #expect(o.emptyCount == 1)
    }

    // MARK: The fifth count — patch 389, §12.133

    /// **THE COUNT IS DERIVED FROM EACH ROW'S OWN `reads`, NOT LOOKED UP.**
    /// §12.129 is what the alternative costs: a list beside this type could not
    /// notice a row nobody added to it, which is how `Activities` and `Athlete`
    /// sat in the agreeing column for six and forty-two patches.
    @Test func theFifthCountFollowsTheFieldsTheBuildFeeds() {
        let rows = [
            line("Activities", reads: .liveStores([.from(.activities)])),
            line("Details", reads: .liveStores([.from(.details)])),
            line("Plan", reads: .ownRead("the bundle"))
        ]
        let atB3 = ran(rows, fed: [.activities])
        #expect(atB3.selfReferentialCount == 1)
        #expect(atB3.independentCount == 2)

        // THE SAME ROWS, ONE SLICE LATER. Nothing about the rows changed; the
        // build did, and the count moved on its own. That is the whole design.
        let afterB4 = ran(rows, fed: [.activities, .details, .traces])
        #expect(afterB4.selfReferentialCount == 2)
        #expect(afterB4.independentCount == 1)
    }

    /// **THE ROW A FIELD-ONLY DERIVATION WOULD GET WRONG.** `Notes and
    /// commutes` reads four fields the database feeds and is real evidence
    /// anyway, because 356 gave it its own read of the files. A build feeding
    /// EVERYTHING must not move it.
    @Test func aRowThatReadTheFilesIsNeverSelfReferential() {
        let o = ran([line("Notes and commutes",
                          reads: .ownRead("notes.json, commutes.json, read directly"))],
                    fed: Set(ExpectationField.allCases))
        #expect(o.selfReferentialCount == 0)
        #expect(o.independentCount == 1)
    }

    /// **THREE MARKS, AND THE THIRD IS THE TRIPWIRE** — §12.15. A row that is
    /// independent because it read the files survives its slice; one that is
    /// independent because nothing feeds its store yet becomes self-referential
    /// the day that slice flips. `Review trail` is the second kind.
    @Test func theMarkSaysWhichOfTheThreeStatesARowIsIn() {
        let fed = ExpectationSources(fedByTheDatabase: [.activities])

        #expect(ReadBackSource.ownRead("activities.json, read directly")
                    .mark(given: fed)
                == " · own read: activities.json, read directly")

        #expect(ReadBackSource.liveStores([.from(.activities, "nineteen fields each")])
                    .mark(given: fed)
                == " · self-referential: ActivityStore.activities, "
                 + "nineteen fields each, hydrated at B3")

        #expect(ReadBackSource.liveStores([.from(.reviews)]).mark(given: fed)
                == " · from the stores: ProposalStore.records — not fed yet")
    }

    /// The screen gets the short form, because its budget is width and the
    /// paste is where the store and the slice belong.
    @Test func theScreenMarkIsShortAndOnlyMarksTheSelfReferential() {
        let fed = ExpectationSources(fedByTheDatabase: [.activities])
        #expect(ReadBackSource.liveStores([.from(.activities)]).screenMark(given: fed)
                == " · self-referential")
        #expect(ReadBackSource.liveStores([.from(.reviews)]).screenMark(given: fed) == "")
        #expect(ReadBackSource.ownRead("x").screenMark(given: fed) == "")
    }

    /// One fed field out of several is enough. A row is the database agreeing
    /// with itself if ANY side of its app-side comes from rows.
    @Test func oneFedFieldIsEnoughToMarkTheRow() {
        let o = ran([line("Weather and gear",
                          reads: .liveStores([.from(.weather), .from(.gear)]))],
                    fed: [.gear])
        #expect(o.selfReferentialCount == 1)
    }

    // MARK: The fallback — patch 390, §12.134

    /// **A ROW THAT COULD NOT READ ITS OWN SIDE DID NOT LOOK, WHATEVER NUMBERS
    /// CAME BACK.** `trustworthy` has always been about the DATABASE read; from
    /// 390 three rows read the files themselves, and comparing the store instead
    /// is §12.125.3's fallback — zero differences over it is not agreement.
    ///
    /// Asked inside `line(_:)` rather than at nine call sites, so no future
    /// read-back can forget.
    @Test("A row that fell back to the stores could not look")
    func aFallbackIsNotAgreement() {
        let l = ReadBackRollUp.line(
            "Details", 694, 0,
            trustworthy: true,
            reads: .fellBackToStores(why: "the files could not be decoded",
                                     [.from(.details)]),
            "unused")

        #expect(l.verdict == .couldNotLook,
                "the database read succeeded and the app side did not")
        #expect(l.isFault)
        #expect(l.compared == 0, "a number over a fallback is not a number")
        #expect(l.value == "the files could not be decoded",
                "the source's own sentence, not the database load's")
    }

    /// It is still classified, because it really did compare the store — so the
    /// fifth count sees it and a build that feeds the field marks it.
    @Test("A fallback is classified by what it actually compared")
    func aFallbackIsStillClassified() {
        let src = ReadBackSource.fellBackToStores(why: "unreadable",
                                                 [.from(.details)])
        #expect(!src.appSideWasReadCleanly)
        #expect(src.readFailure == "unreadable")
        #expect(src.isSelfReferential(
            given: ExpectationSources(fedByTheDatabase: [.details])),
                "after B4 a fallback is the database against itself")
        #expect(!src.isSelfReferential(given: .allFromFiles),
                "and before it, it is the store — real, if not independent")
    }

    /// The mark leads with the failure rather than with the classification,
    /// because losing independence and never having had it are different facts
    /// and only one of them is a fault.
    @Test("The fallback mark leads with the failure")
    func theFallbackMarkLeadsWithTheFailure() {
        let m = ReadBackSource.fellBackToStores(why: "unreadable",
                                                [.from(.details)])
            .mark(given: ExpectationSources(fedByTheDatabase: [.details]))
        #expect(m == " · COULD NOT READ ITS OWN SIDE: unreadable")
    }

    /// The two clean cases are unaffected — `liveStores` is a deliberate choice
    /// of side, not a failure. `Weather and gear` and `Review trail` read the
    /// stores on purpose and read them perfectly well.
    @Test("Choosing the stores on purpose is not a failed read")
    func choosingTheStoresIsNotAFailure() {
        #expect(ReadBackSource.liveStores([.from(.reviews)]).appSideWasReadCleanly)
        #expect(ReadBackSource.liveStores([.from(.reviews)]).readFailure == nil)
        #expect(ReadBackSource.ownRead("x").appSideWasReadCleanly)
        #expect(ReadBackSource.ownRead("x").readFailure == nil)
    }

    // MARK: The paste

    @Test func everyLineReachesThePaste() {
        let o = ran([line("A"), line("B", unexplained: 1)])
        let l = o.diagnosticLines
        #expect(l.count == 3)
        #expect(l[0].hasPrefix("Read-back roll-up: "))
        #expect(l[1] == "  A: 10 compared, no differences · own read: a fixture")
        #expect(l[2] == "  B: 10 compared, 1 differ · own read: a fixture")
    }

    /// **THE PASTE CARRIES THE PROVENANCE OF THE ROW THAT COULD NOT LOOK TOO.**
    /// A read that failed still came from somewhere, and dropping the mark on
    /// failure would make the classification depend on whether the read worked.
    @Test func evenABlindRowSaysWhereItWouldHaveLooked() {
        let o = ran([line("Activities", compared: 0, couldNotLook: "closed",
                          reads: .liveStores([.from(.activities)]))],
                    fed: [.activities])
        #expect(o.diagnosticLines[1]
                == "  Activities: closed · self-referential: "
                 + "ActivityStore.activities, hydrated at B3")
        #expect(o.selfReferentialCount == 1, "and it is still counted")
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
        r.record([line("A")], sources: .allFromFiles)
        #expect(r.runs == 1)
        #expect(r.last == .ran([line("A")], .allFromFiles))
        r.recordFailure("closed")
        #expect(r.last == .readFailed("closed"))
        // A FAILURE IS NOT A RUN. `runs` answers "did a roll-up complete",
        // and a read that could not happen did not complete one.
        #expect(r.runs == 1)
    }

    /// The sources travel with the result, so a roll-up recorded before a slice
    /// flipped keeps describing the run that happened. `Sub4Launch.bootstrap`'s
    /// decision, one screen over — §12.128's "read at launch" note.
    @Test func theRecordedResultKeepsTheSourcesItRanUnder() {
        let r = ReadBackRollUp()
        let atB3 = ExpectationSources(fedByTheDatabase: [.activities])
        r.record([line("Activities", reads: .liveStores([.from(.activities)]))],
                 sources: atB3)
        #expect(r.last.sources == atB3)
        #expect(r.last.selfReferentialCount == 1)
        // AND EVERY OTHER CASE ANSWERS `.allFromFiles`, which is the honest
        // answer for a run that did not happen: nothing was compared, so
        // nothing was self-referential.
        #expect(ReadBackRollUp.Outcome.never.sources == .allFromFiles)
        #expect(ReadBackRollUp.Outcome.noDatabase.selfReferentialCount == 0)
    }
}
