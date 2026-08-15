//
//  MatchStandingTests.swift
//  Sub4CoreTests
//
//  What the picker can say, and what the resolver cannot — patch 359.
//
//  WHY THIS TYPE EXISTS AT ALL
//  ---------------------------
//  `MatchResolver.resolve` already knows whether an override is in effect —
//  `Match.auto == false` says so — and the picker could have read that. It
//  would have been wrong, and the resolver's own comment says why:
//
//      THREE OUTCOMES, TWO OF THEM THE SAME MATCH. "Explicitly nothing" and
//      "the activity named is not here" both produce an unmatched session …
//      The importer treats the two differently, because the database can tell
//      them apart and this screen cannot.
//
//  That collapse is correct for the resolver: the athlete overrode the matcher,
//  so the matcher does not get another guess, and a day view has nothing useful
//  to do with the difference. It is NOT correct for the picker, which is the one
//  screen whose whole job is to show what was recorded. §12.15 — a diagnostic
//  that cannot say why it has no answer will be read as having one.
//
//  So `MatchStanding` reads the DECISION, not the resolution. It is the only
//  place in the app that does, and the four cases are the four things a
//  decision can mean.
//
//  NOT A SECOND OPINION ABOUT MATCHING. §12.43 applies and is respected: this
//  answers "what did the athlete record", which the resolver deliberately
//  discards. It never decides what satisfied a session — `MatchResolver` does
//  that and nothing here duplicates it.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The picker can say what was recorded")
struct MatchStandingTests {

    private func decision(_ id: String?) -> MatchDecision {
        MatchDecision(sessionUid: "wk-01-tue-easy", activityId: id,
                      decided: Date(timeIntervalSince1970: 1_000),
                      dateIsKnown: true)
    }

    // MARK: The four cases

    @Test("No decision is automatic, and the sentence says so")
    func noDecisionIsAutomatic() {
        let s = MatchStanding.of(decision: nil, offered: ["a", "b"])
        #expect(s == .automatic)
        #expect(!s.isRecorded)
        #expect(s.chosen == nil)
        #expect(s.line.contains("Nothing recorded"))
    }

    @Test("A chosen activity the day still offers is named")
    func aChosenActivityIsNamed() {
        let s = MatchStanding.of(decision: decision("b"), offered: ["a", "b"])
        #expect(s == .chose("b"))
        #expect(s.isRecorded)
        #expect(s.chosen == "b")
    }

    @Test("Explicitly nothing is its own state")
    func explicitlyNothingIsItsOwn() {
        let s = MatchStanding.of(decision: decision(nil), offered: ["a"])
        #expect(s == .choseNothing)
        #expect(s.isRecorded)
        #expect(s.chosen == nil, "nothing is chosen, and that is the choice")
    }

    /// **THE ONE THE RESOLVER COLLAPSES.** A decision naming an activity this
    /// day no longer offers produces an unmatched session, exactly like
    /// "Not done" — so on every screen but this one they look identical. Here
    /// they must not, because the athlete's next action differs: one is a
    /// decision to keep, the other is a decision to redo.
    @Test("A choice the day no longer offers is not the same as not done")
    func aGoneChoiceIsNotNotDone() {
        let gone = MatchStanding.of(decision: decision("zz"), offered: ["a", "b"])
        let nothing = MatchStanding.of(decision: decision(nil), offered: ["a", "b"])

        #expect(gone == .choseSomethingGone("zz"))
        #expect(gone != nothing, "the two the resolver cannot separate")
        #expect(gone.line != nothing.line, "and the reader must not have to")
        #expect(gone.isRecorded)
        #expect(gone.chosen == nil,
                "nothing on this day is chosen — the row it named is not here")
    }

    /// An empty day cannot offer anything, so every recorded activity is gone.
    /// Worth pinning because it is the state a deleted activity produces and it
    /// must not read as automatic.
    @Test("An empty day does not turn a recorded choice into no choice")
    func anEmptyDayIsNotNoDecision() {
        let s = MatchStanding.of(decision: decision("a"), offered: [])
        #expect(s == .choseSomethingGone("a"))
        #expect(s.isRecorded, "a decision that was made was still made")
    }

    // MARK: The sentence

    /// §12.54.2 — it prints on every state, including the boring one. A footer
    /// that appeared only when something was recorded could not be told from
    /// one nobody wired in, and this is the line that tells a reader whether
    /// the tick above it came from them or from the matcher.
    @Test("Every standing carries a sentence, and no two share one")
    func everyStandingCarriesADistinctSentence() {
        let all: [MatchStanding] = [.automatic, .chose("a"), .choseNothing,
                                    .choseSomethingGone("a")]
        for s in all {
            #expect(!s.line.isEmpty, "a state with no sentence is a blank footer")
        }
        #expect(Set(all.map(\.line)).count == all.count,
                "two states sharing a sentence is two states nobody can tell apart")
    }

    /// The three recorded states all offer the same way out, and the automatic
    /// one has nothing to undo. The picker disables the control on that, so the
    /// flag has to be right or a button that does nothing looks broken.
    @Test("Only the automatic standing has nothing to undo")
    func onlyAutomaticHasNothingToUndo() {
        #expect(!MatchStanding.automatic.isRecorded)
        #expect(MatchStanding.chose("a").isRecorded)
        #expect(MatchStanding.choseNothing.isRecorded)
        #expect(MatchStanding.choseSomethingGone("a").isRecorded)
    }

    // MARK: It reads the decision, not the resolution

    /// THE PROPERTY THAT KEEPS THIS HONEST. What the day resolves to plays no
    /// part: the same decision produces the same standing whatever else is on
    /// the day, because the standing is about what was RECORDED.
    @Test("The standing does not depend on what else the day holds")
    func theStandingIsAboutTheDecisionAlone() {
        let d = decision("b")
        #expect(MatchStanding.of(decision: d, offered: ["b"])
                == MatchStanding.of(decision: d, offered: ["a", "b", "c"]))
        #expect(MatchStanding.of(decision: nil, offered: [])
                == MatchStanding.of(decision: nil, offered: ["a"]))
    }
}
