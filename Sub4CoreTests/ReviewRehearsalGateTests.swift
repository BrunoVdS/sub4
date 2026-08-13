//
//  ReviewRehearsalGateTests.swift
//  Sub4CoreTests
//
//  A rehearsal is not a review — patch 353, ADR-0003 §12.98.
//
//  WHY THESE TESTS DRIVE PURE FUNCTIONS AND NOT `ReviewDue.state()`
//  ----------------------------------------------------------------
//  `state()` reads two main-actor singletons — `PlanStore.shared` for the
//  finished-week count and `ProposalStore.shared` for the last run. In the test
//  host both are real: the plan store is hydrated from the simulator's database
//  (§12.57, and 346a paid for learning it), and the proposal store is a file in
//  the test host's container. A test that drove `state()` would be asserting
//  about whatever those two happened to hold, and a test that WROTE to
//  `ProposalStore.shared` to fix that would leave a row behind that every other
//  suite's `state()` then counts.
//
//  So 353 puts the rule in `newestReal(in:)` and friends, which take their
//  records as an argument and have no default. That is the testable half, and
//  it is the half that was wrong.
//
//  THE NEGATIVE CONTROL IS THE POINT OF THIS FILE.
//  `theUnfilteredReadIsWhatTheDefectWas` asserts that the OLD expression — the
//  plain newest record — returns the rehearsal on the same array. Without it
//  every test below would pass on a `newestReal` that did no filtering at all,
//  because six of the seven cases would still come out right. §12.69: a check
//  that cannot fail has not been tested, and the fourth negative control in
//  this project written after the absence of one cost a patch.
//

import Testing
import Foundation
@testable import Sub4

@Suite("A rehearsal is not a review")
@MainActor
struct ReviewRehearsalGateTests {

    // MARK: Fixtures

    /// `ReviewRehearsal.proposal(naming:)` is used rather than a hand-built
    /// `ReviewProposal` for the reason its own doc gives: it is internal
    /// precisely so the shaping can be exercised without writing a record.
    private func record(_ id: String,
                        _ ranAt: String,
                        model: String) -> ProposalStore.Record {
        ProposalStore.Record(
            id: id,
            ranAt: ISO8601DateFormatter().date(from: ranAt) ?? Date(),
            windowLabel: "Week 01",
            startDay: "2026-07-28",
            endDay: "2026-08-01",
            evidence: "",
            proposal: ReviewRehearsal.proposal(naming: ["wk-01-tue-easy",
                                                        "wk-01-wed-strength"]),
            appVersion: "353",
            model: model)
    }

    private func rehearsal(_ id: String, _ ranAt: String) -> ProposalStore.Record {
        record(id, ranAt, model: ReviewRehearsal.modelName)
    }

    private func real(_ id: String, _ ranAt: String) -> ProposalStore.Record {
        record(id, ranAt, model: "claude-sonnet-4-5")
    }

    // MARK: The marker

    /// PINNED, NOT CHOSEN. Six records on the device carry this exact string,
    /// written by patch 269 and encoded into `proposals.json`. Changing the
    /// constant would make those six stop being rehearsals — to this gate, to
    /// the banner, and to the paste — while remaining rehearsals in fact.
    @Test("The marker is the value already on disk")
    func theMarkerIsTheStoredValue() {
        #expect(ReviewRehearsal.modelName == "rehearsal")
        #expect(ReviewRehearsal.mustGoBefore == "2026-08-24")
        #expect(!ReviewRehearsal.mustGoBeforeLabel.isEmpty)
    }

    @Test("A record knows what it is, and a real one is not confused for it")
    func aRecordKnowsWhatItIs() {
        #expect(rehearsal("r1", "2026-08-09T12:29:16Z").isRehearsal)
        #expect(!real("v1", "2026-08-24T08:00:00Z").isRehearsal)
        #expect(!record("v2", "2026-08-24T08:00:00Z", model: "Rehearsal").isRehearsal,
                "the comparison is exact — a capitalised model is a model")
    }

    // MARK: The gate

    @Test("With only rehearsals stored, the gate sees no review at all")
    func onlyRehearsalsMeansNoReview() {
        let records = [rehearsal("r6", "2026-08-09T12:29:35Z"),
                       rehearsal("r5", "2026-08-09T12:29:34Z"),
                       rehearsal("r1", "2026-08-09T12:29:16Z")]
        #expect(ReviewDue.newestReal(in: records) == nil)
        #expect(ReviewDue.realReviews(in: records).isEmpty)
        #expect(ReviewDue.rehearsals(in: records).count == 3)
    }

    /// **THE NEGATIVE CONTROL.** The same array, read the way `ReviewDue` read
    /// it before this patch. If this stops returning the rehearsal, the tests
    /// above have stopped being able to fail.
    @Test("The unfiltered read is what the defect was")
    func theUnfilteredReadIsWhatTheDefectWas() {
        let records = [rehearsal("r6", "2026-08-09T12:29:35Z"),
                       real("v1", "2026-08-01T09:00:00Z")]
        #expect(records.first?.isRehearsal == true,
                "the old expression took this one, and it is a rehearsal")
        #expect(ReviewDue.newestReal(in: records)?.id == "v1",
                "the new one takes the real review underneath it")
    }

    /// The ordering case that matters on 24 August: a rehearsal newer than
    /// every real review must not become "the last review".
    @Test("A newer rehearsal does not hide an older real review")
    func aNewerRehearsalDoesNotHideARealOne() {
        let records = [rehearsal("r6", "2026-08-09T12:29:35Z"),
                       real("v2", "2026-08-03T09:00:00Z"),
                       real("v1", "2026-07-06T09:00:00Z")]
        #expect(ReviewDue.newestReal(in: records)?.id == "v2")
        #expect(ReviewDue.realReviews(in: records).count == 2)
    }

    @Test("With no records at all the gate has nothing to skip")
    func nothingStoredIsItsOwnAnswer() {
        #expect(ReviewDue.newestReal(in: []) == nil)
        #expect(ReviewDue.rehearsals(in: []).isEmpty)
        #expect(ReviewDue.rehearsalWarning(in: []) == nil)
    }

    // MARK: What is said about them

    /// The banner is CONDITIONAL and the paste line is not, and the difference
    /// is the whole of §12.54.2's boundary: one is an action item on a screen
    /// opened every morning, the other is evidence in a document read later.
    @Test("The banner is silent at zero and dated otherwise")
    func theBannerIsSilentAtZero() {
        #expect(ReviewDue.rehearsalWarning(in: [real("v1", "2026-08-01T09:00:00Z")])
                == nil)

        let six = (1...6).map { rehearsal("r\($0)", "2026-08-09T12:29:3\($0)Z") }
        let before = ReviewDue.rehearsalWarning(in: six, today: "2026-08-13")
        #expect(before != nil)
        #expect(before?.contains("6 rehearsal records are stored") == true)
        #expect(before?.contains(ReviewRehearsal.mustGoBeforeLabel) == true,
                "a deadline nobody can read is not a deadline")

        let one = ReviewDue.rehearsalWarning(in: [six[0]], today: "2026-08-13")
        #expect(one?.contains("1 rehearsal record is stored") == true,
                "one record does not read as `1 records are`")
    }

    /// After the day passes, the sentence has to change — "delete them before
    /// Monday 24 August" read on 25 August is worse than saying nothing.
    @Test("Past the deadline it stops giving a date it has missed")
    func pastTheDeadlineItChangesWhatItSays() {
        let six = (1...6).map { rehearsal("r\($0)", "2026-08-09T12:29:3\($0)Z") }
        let after = ReviewDue.rehearsalWarning(in: six, today: "2026-08-24")
        #expect(after != nil)
        #expect(after?.contains("already due") == true)
        #expect(after?.contains(ReviewRehearsal.mustGoBeforeLabel) == false,
                "the deadline is behind it and repeating it reads as stale")
    }

    /// §12.54.2. The line the paste carries has an answer at zero, and that
    /// answer is the only thing that will ever prove the six went.
    @Test("The paste line speaks at zero")
    func thePasteLineSpeaksAtZero() {
        let quiet = ReviewDue.rehearsalLine(in: [])
        #expect(quiet.contains("Review rehearsals stored: 0"))
        #expect(quiet.contains("no longer counts them"))

        let loud = ReviewDue.rehearsalLine(
            in: (1...6).map { rehearsal("r\($0)", "2026-08-09T12:29:3\($0)Z") })
        #expect(loud.contains("Review rehearsals stored: 6"))
        #expect(loud.contains(ReviewRehearsal.mustGoBeforeLabel))
    }

    /// A real review is not counted as a rehearsal in the other direction
    /// either — the line has to read zero on a device that has run a review
    /// and never a rehearsal, which is every device after 24 August.
    @Test("A device with only real reviews reports zero rehearsals")
    func realReviewsAreNotCounted() {
        let records = [real("v2", "2026-08-24T09:00:00Z"),
                       real("v1", "2026-07-27T09:00:00Z")]
        #expect(ReviewDue.rehearsals(in: records).isEmpty)
        #expect(ReviewDue.rehearsalWarning(in: records) == nil)
        #expect(ReviewDue.rehearsalLine(in: records).contains("stored: 0"))
        #expect(ReviewDue.newestReal(in: records)?.id == "v2")
    }
}
