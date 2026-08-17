//
//  ReviewRehearsal.swift
//  Sub4
//
//  A dress rehearsal for 24 August 2026 — patch 269, ADR-0003 §12.8.3.
//
//  THE PROBLEM THIS SOLVES IS A DATE
//  --------------------------------
//  `ReviewDue.state()` needs four finished plan weeks. The block began Monday
//  27 July, so week 4 ends Sunday 23 August and the first review comes due
//  Monday 24 August. Until then `proposals.json` does not exist — the survey in
//  §12.9e confirmed it on the device — and `review`, `review_evidence`,
//  `proposal`, `proposal_change` and `proposal_watch` hold zero rows however
//  many times the import runs.
//
//  So on 24 August the review writer, the file and the importer will meet for
//  the first time, in one shot, on the day the athlete actually wants the
//  answer. §12.8.2 wrote the checklist for that day and called the whole path
//  "written, tested and unproven".
//
//  This makes the 24th a repeat rather than a premiere.
//
//  WHAT IT DOES NOT DO: CALL THE MODEL
//  -----------------------------------
//  Deliberately. The part that has never run is writer → `proposals.json` →
//  importer → five tables. The Claude call is exercised every time the review
//  button is pressed and has its own error handling, its own tests and its own
//  screen; adding it here would spend a real API call to test the one link in
//  the chain that is not in question.
//
//  It also makes the rehearsal deterministic. A real model answer might come
//  back with zero changes — the expected answer most months — and a rehearsal
//  that exercised `proposal_change` only sometimes would be worth very little.
//
//  THE PROPOSAL IS BUILT TO EXERCISE THE CHECKLIST, NOT TO BE PLAUSIBLE
//  --------------------------------------------------------------------
//  §12.8.2 names five things to verify on the day. The synthetic proposal is
//  shaped so that every one of them has something to be true of:
//
//  - one row in `review`, `review_evidence` and `proposal` — any proposal does
//  - `proposal_change` with a NON-NULL `planSessionUID` — two changes, both
//    naming a real session uid from the athlete's own plan
//  - a skipped session whose `what` is not the empty string — the second change
//    is a skip, which is the case where `newDetail` is empty and `what` has to
//    come from somewhere else
//  - `proposal_watch` in order — two items, deliberately distinguishable
//  - `review.appVersion` — set by `add`, from the build that ran it
//
//  MARKED, SO IT CANNOT BE MISTAKEN FOR A REVIEW
//  ---------------------------------------------
//  `model` is `"rehearsal"` rather than `ClaudeConfig.model`, and that field is
//  a column on `review`. So the row says what it is in the database as well as
//  on screen, and the 24 August record will be distinguishable from this one by
//  something more reliable than its date.
//
//  It is also removable: `ProposalStore.remove(_:)` already exists, and the
//  rehearsal record should be removed before the real review runs — a
//  `ReviewDue` calculation that counted it would push the first real review out
//  by 28 days.
//

import Foundation

@MainActor
enum ReviewRehearsal {

    enum Failure: LocalizedError {
        case notInternalBuild
        case noFinishedWeeks
        case noSessions

        var errorDescription: String? {
            switch self {
            case .notInternalBuild:
                "The rehearsal is only available in internal builds."
            case .noFinishedWeeks:
                "No plan week has finished yet, so there is nothing to build a "
                + "review window from."
            case .noSessions:
                "The plan holds no dated sessions to name in a change."
            }
        }
    }

    /// Internal builds only, and checked twice on purpose.
    ///
    /// **AND THE SECOND CHECK STOPPED BEING BELT-AND-BRACES AT 396.** This
    /// comment used to say `ReleaseGates.isInternalBuild` is `#if DEBUG`, so
    /// this code is not in a release binary at all. It is now — the predicate
    /// asks how the build was SIGNED rather than how it was optimised
    /// (§12.140), so the rehearsal compiles into every configuration and the
    /// throw below is the only thing standing between a distributed build and
    /// running it. A gate enforced solely by its caller moves the first time
    /// somebody adds a second caller, and this one no longer has a compiler
    /// standing behind it.
    /// THE MARKER, DECLARED ONCE — patch 353, ADR-0003 §12.98.
    ///
    /// `model` has carried the literal `"rehearsal"` since 269 and NOTHING
    /// READ IT. From this patch `ReviewDue` does, which turns a string into a
    /// contract: two spellings would be a rehearsal the gate counts as a
    /// review, silently, on the one morning the banner has to appear.
    ///
    /// It is the value already on disk in the six records written on 9 August,
    /// so it is pinned by test rather than chosen. `apply-353.py` refuses a
    /// second literal anywhere in the Swift sources.
    static let modelName = "rehearsal"

    /// The day the first real review comes due: four finished plan weeks after
    /// the block began on Monday 27 July.
    ///
    /// THE RECORDS MUST BE GONE BEFORE IT, NOT ON IT. `ReviewDue` no longer
    /// counts them, so the banner is now right either way — but everything
    /// that counts REVIEWS is still wrong while they are stored: `review: 6`
    /// in the table census, six rows through the read-back, and six windows
    /// that a person reading the history would take for months of work.
    static let mustGoBefore = "2026-08-24"

    /// The same day, for a sentence. Two constants rather than a formatter
    /// because one of them is compared and the other is read aloud, and a
    /// locale-formatted string is not a thing to compare `DayKey` against.
    static let mustGoBeforeLabel = "Monday 24 August 2026"

    static var isAvailable: Bool { ReleaseGates.isInternalBuild }

    @discardableResult
    static func run() throws -> ProposalStore.Record {
        guard isAvailable else { throw Failure.notInternalBuild }

        // The four-week gate, walked down rather than bypassed. Asking for
        // fewer weeks is not the same as pretending there are four: the review
        // that comes out is a REAL review of however many weeks have actually
        // finished, and every figure in it is the athlete's own.
        var review: Review?
        for weeks in stride(from: ReviewDue.minWeeks, through: 1, by: -1) {
            if let r = ReviewBuilder.build(weeksBack: weeks) { review = r; break }
        }
        guard let review else { throw Failure.noFinishedWeeks }

        let uids = sessionUids()
        guard !uids.isEmpty else { throw Failure.noSessions }

        return ProposalStore.shared.add(review: review,
                                        proposal: proposal(naming: uids),
                                        evidence: evidence(for: review),
                                        model: modelName)
    }

    // MARK: What it writes

    /// Two real session uids from the athlete's own plan, so
    /// `proposal_change.planSessionUID` has something to be non-null with —
    /// and so the row would survive the FOREIGN KEY it will one day carry.
    static func sessionUids() -> [String] {
        let plan = PlanStore.shared
        let dated = plan.planWeeks
            .flatMap { plan.sessions(inWeek: $0) }
            .filter { $0.date != nil && !$0.isRest }
            .map(\.uid)
        return Array(dated.prefix(2))
    }

    /// Internal rather than private so the shaping can be tested without
    /// writing a record — `run()` itself writes to the real `ProposalStore`,
    /// and a test that called it would leave a row that `ReviewDue` counts.
    static func proposal(naming uids: [String]) -> ReviewProposal {
        var changes: [ReviewProposal.Change] = [
            .init(sessionUid: uids[0],
                  newDetail: "Rehearsal — an edited session detail.",
                  skip: false,
                  evidence: "Rehearsal: this change exists to fill a row.",
                  reason: "So proposal_change has a non-skip row to be true of.")
        ]
        if uids.count > 1 {
            // THE SKIP, and it is the interesting one. `newDetail` is empty by
            // definition here, so `what` has to be produced from something
            // else — which is the assertion §12.8.2 names, and the case a
            // proposal with only edits would never reach.
            changes.append(.init(sessionUid: uids[1],
                                 newDetail: "",
                                 skip: true,
                                 evidence: "Rehearsal: this change exists to "
                                         + "exercise the skip path.",
                                 reason: "So a skipped session's summary is "
                                       + "not the empty string."))
        }

        return ReviewProposal(
            verdict: .mixed,
            summary: "REHEARSAL — not a real review. Written by "
                   + "ReviewRehearsal to prove the path from the writer to the "
                   + "five review tables before 24 August 2026.",
            reasoning: "Every figure in the window above is the athlete's own; "
                     + "the verdict, the changes and the watch items are not. "
                     + "Delete this record before the first real review runs — "
                     + "a ReviewDue calculation that counted it would push the "
                     + "real one out by 28 days.",
            changes: changes,
            // Two, and distinguishable, so `proposal_watch`'s ordinal can be
            // checked rather than assumed.
            watchFor: ["Rehearsal watch item one.",
                       "Rehearsal watch item two."],
            confidence: 3)
    }

    /// The evidence text. Real, and marked.
    ///
    /// `ReviewRequest.prompt` is NOT used, because it can refuse — a payload
    /// carrying Strava-derived figures is blocked from going to an AI provider
    /// under ADR-0002, and a rehearsal that inherited that refusal would fail
    /// for a reason that has nothing to do with what it is testing. Nothing is
    /// sent anywhere here, so the block does not apply.
    private static func evidence(for review: Review) -> String {
        """
        # REHEARSAL — not sent to any provider

        Written by `ReviewRehearsal` (patch 269) to exercise the path from the
        review writer through proposals.json to the review tables, before the
        first real review on 24 August 2026.

        Window: \(review.window.label) · \(review.window.startDay) to \
        \(review.window.endDay)
        """
    }
}
