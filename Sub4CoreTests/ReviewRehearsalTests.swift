//
//  ReviewRehearsalTests.swift
//  Sub4CoreTests
//
//  The rehearsal for 24 August — patch 269.
//
//  WHAT IS TESTED HERE IS THE SHAPING, NOT THE PATH. `run()` writes to the real
//  `ProposalStore`, and `ReviewDue` reads the newest record's date and adds 28
//  days — so a test that called it would leave a row that pushes the first real
//  review into September. The path itself is verified on the device, which is
//  the entire point of the patch: the rehearsal IS the test.
//
//  So these assert the one thing a unit test can: that the proposal it writes
//  has something for every line of §12.8.2's checklist to be true of.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct ReviewRehearsalTests {

    @Test("The rehearsal exists in an internal build and not otherwise")
    func availabilityFollowsTheBuild() {
        // Tests run in Debug, so this is true here — and the assertion that
        // matters is that it is the SAME value the button is gated on, not a
        // second opinion about what an internal build is.
        #expect(ReviewRehearsal.isAvailable == ReleaseGates.isInternalBuild)
    }

    @Test("Both changes name a real session from the plan")
    func changesNameRealSessions() {
        // §12.8.2: proposal_change holds one row per change with a NON-NULL
        // planSessionUID. A made-up uid would satisfy the column and fail the
        // foreign key this table will one day carry.
        let uids = ReviewRehearsal.sessionUids()
        #expect(uids.count == 2, "the bundled plan should offer two dated sessions")

        let p = ReviewRehearsal.proposal(naming: uids)
        #expect(p.changes.count == 2)
        #expect(p.changes.map(\.sessionUid) == uids)

        let plan = PlanStore()
        let known = Set(plan.plan.sessions.map(\.uid))
        let allKnown = p.changes.allSatisfy { known.contains($0.sessionUid) }
        #expect(allKnown, "a change names a session the plan does not have")
    }

    @Test("Exactly one change is a skip, and it carries no new detail")
    func oneChangeIsASkip() {
        // The case a proposal of only edits never reaches, and the one
        // §12.8.2 singles out: `newDetail` is empty by definition here, so
        // `what` has to be produced from something else.
        let p = ReviewRehearsal.proposal(naming: ReviewRehearsal.sessionUids())
        let skips = p.changes.filter(\.skip)
        #expect(skips.count == 1)
        #expect(skips.first?.newDetail.isEmpty == true)

        let edits = p.changes.filter { !$0.skip }
        #expect(edits.count == 1)
        #expect(edits.first?.newDetail.isEmpty == false)
    }

    @Test("Every change carries its evidence and its reason")
    func everyChangeIsJustified() {
        // Both columns are NOT NULL and both are what make a change auditable
        // a month later. A rehearsal that left them empty would prove the
        // insert works and nothing about whether it is worth doing.
        let p = ReviewRehearsal.proposal(naming: ReviewRehearsal.sessionUids())
        let justified = p.changes.allSatisfy {
            !$0.evidence.isEmpty && !$0.reason.isEmpty
        }
        #expect(justified)
    }

    @Test("Two watch items, distinguishable")
    func watchItemsCanBeToldApart() {
        // So proposal_watch's ordinal can be CHECKED rather than assumed. Two
        // identical strings would round-trip in any order and prove nothing.
        let p = ReviewRehearsal.proposal(naming: ReviewRehearsal.sessionUids())
        #expect(p.watchFor.count == 2)
        #expect(p.watchFor[0] != p.watchFor[1])
    }

    @Test("The proposal says what it is, in the text a person reads")
    func itAnnouncesItself() {
        // Marked in the database by `model: "rehearsal"`, and marked here too.
        // Somebody reading this on Progress in three weeks must not have to
        // check a column to know it is not a real review.
        let p = ReviewRehearsal.proposal(naming: ReviewRehearsal.sessionUids())
        #expect(p.summary.contains("REHEARSAL"))
        // And it says what to do about it, because the consequence of leaving
        // it in place is a real one: ReviewDue would push the first review out
        // by 28 days.
        #expect(p.reasoning.contains("Delete"))
        #expect(p.reasoning.contains("28"))
    }

    @Test("A verdict that is not the boring one")
    func theVerdictExercisesTheScreen() {
        // `no_change` is the expected answer most months and the one path
        // that renders nothing. A rehearsal should exercise the other.
        let p = ReviewRehearsal.proposal(naming: ReviewRehearsal.sessionUids())
        #expect(p.verdict != .noChange)
        #expect(p.confidence >= 1 && p.confidence <= 5)
    }
}
