//
//  ReviewRepositoryTests.swift
//  Sub4CoreTests
//
//  The review trail, read back — D6c slice 7, patch 327, ADR-0003 §12.71.
//
//  WHAT THESE ARE FOR
//  ------------------
//  Groundwork §2.1 asks for a test that hands the comparison two deliberately
//  different things and demands it reports them, because a check whose answer
//  is always "0 differences" is indistinguishable from a check that is broken.
//  This slice needs that more than any other: until 24 August 2026 the device
//  has nothing to compare, so the ONLY evidence that this reader works is here.
//
//  Four of these guard decisions the reader could have got quietly wrong:
//
//    `noDiagnosticLineCarriesReviewText`
//        — the rule that makes this section safe to paste. The evidence pack
//          and the model's prose are compared in full and reported by length.
//          A future edit that printed a value would pass every other test.
//
//    `aChangeMovedToAnotherSessionIsADifference`
//        — changes carry an ordinal and are compared by position. Compared as
//          a set, an importer that wrote one session's change under another's
//          uid compares EQUAL, and the athlete gets the wrong session altered.
//
//    `aReviewOnlyInTheDatabaseIsNotCountedAgainstIt`
//        — §12.8.1: a reinstall once took every past review. If that happens
//          again the database is the only copy, and the row showing it must
//          not be styled as the fault.
//
//    `aChangeNamingNoStoredSessionIsUnexplained`
//        — `proposal_change.planSessionUID` is deliberately not a foreign key,
//          so nothing but this resolves it. `rejections(plan:)` already has a
//          name for the failure: "no session with that id — invented".
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct ReviewRepositoryTests {

    // MARK: Fixtures

    /// A sentinel that could not occur by accident, planted in every field
    /// that carries prose. `noDiagnosticLineCarriesReviewText` greps for it.
    private static let secret = "ZZQX-PRIVATE-TRAINING-PROSE"

    private func change(_ uid: String,
                        skip: Bool = false,
                        newDetail: String = "8 km easy",
                        reason: String = "Freshness is deep") -> ReviewProposal.Change {
        .init(sessionUid: uid, newDetail: skip ? "" : newDetail, skip: skip,
              evidence: "TSB −22 for 5 days", reason: reason)
    }

    /// `id` GAINED AN OVERRIDE AT PATCH 337, and the reason is the patch.
    ///
    /// The default still derives from the window, which is what
    /// `ProposalStore.add` does. But the record id is now the key both sides
    /// pair on, so a test that changes the window to provoke a FIELD
    /// difference was, from 337 onward, changing the key instead — two
    /// unpaired reviews rather than one compared review with a differing
    /// field. `aChangedWindowIsADifference` passes an explicit id so its
    /// subject stays the comparator rather than the pairing.
    private func record(id: String? = nil,
                        ranAt: Double = 1_780_100_000,
                        startDay: String = "2026-06-01",
                        endDay: String = "2026-06-28",
                        windowLabel: String = "1–28 June",
                        evidence: String = "## Load\nCTL 41, ATL 63, TSB −22.",
                        verdict: ReviewProposal.Verdict = .easier,
                        summary: String = "Ease the next week.",
                        reasoning: String = "Freshness has been deep for five days.",
                        confidence: Int = 4,
                        changes: [ReviewProposal.Change] = [],
                        watchFor: [String] = [],
                        appVersion: String = "1.0 (1) · patch 327",
                        model: String = "claude-opus-5") -> ProposalStore.Record {
        .init(id: id ?? "\(startDay)→\(endDay)-1",
              ranAt: Date(timeIntervalSince1970: ranAt),
              windowLabel: windowLabel,
              startDay: startDay, endDay: endDay,
              evidence: evidence,
              proposal: .init(verdict: verdict, summary: summary,
                              reasoning: reasoning, changes: changes,
                              watchFor: watchFor, confidence: confidence),
              appVersion: appVersion, model: model)
    }

    @discardableResult
    private func imported(_ db: Sub4Database,
                          _ records: [ProposalStore.Record],
                          plan p: Plan? = nil) throws -> Sub4Import.Report {
        try Sub4Import.run(into: db, activities: [], shoes: [],
                           proposals: records, plan: p)
    }

    private func compare(_ db: Sub4Database,
                         _ records: [ProposalStore.Record]) -> ReviewRoundTrip.Report {
        ReviewRoundTrip.compare(storeRecords: records,
                                database: ReviewRepository.load(db))
    }

    /// A one-session plan, so `planSessionUID` has something to resolve
    /// against. Sessions are what this slice needs; the rest is scaffolding.
    private func plan(sessionUids: [String]) -> Plan {
        Plan(meta: Meta(plan: "Operation Sub-4", week1Monday: "2026-07-27",
                        raceDate: "2027-03-21", targetTime: "4:00:00",
                        targetPaceSecKm: 341),
             weeks: [Week(uid: "w1", weekNo: 1, label: "1",
                          dateRange: "27 Jul – 2 Aug", startDate: "2026-07-27",
                          tag: "Base", badge: nil, kind: nil,
                          logged: false, stats: ["km": 42])],
             sessions: sessionUids.enumerated().map { i, uid in
                 Session(uid: uid, weekUid: "w1", day: "Mon",
                         date: "2026-07-27", discipline: .run,
                         intensity: .easy, title: "Easy run",
                         detail: "8 km easy", fuel: "Water only",
                         prep: nil, seq: i,
                         swimDetail: nil, strengthDetail: nil)
             },
             exercises: [], fuel: nil, warmup: nil)
    }

    // MARK: Nothing there is not the same as could not look

    /// THE STATE THIS SLICE LIVES IN UNTIL 24 AUGUST 2026, and the reason the
    /// empty case is `.loaded` rather than an unhappy path: the read worked and
    /// there is nothing to read, which is not a failure of anything.
    @Test("An empty database is a loaded answer, and says why it is empty")
    func anEmptyDatabaseIsALoadedAnswer() throws {
        let db = try Sub4Database.inMemory()
        let load = ReviewRepository.load(db)
        #expect(load.isTrustworthy)
        #expect(load.reviews?.isEmpty == true)
        #expect(load.line.contains("24 August 2026"),
                "a bare 'nothing' cannot say whether the path is broken or early")
    }

    @Test("An untrustworthy read hands back nothing, not an empty list")
    func anUntrustworthyReadIsNotEmpty() {
        for load: ReviewTrailLoad in [.unavailable, .failed("locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.reviews == nil, "the caller must decide, not the reader")
        }
    }

    /// GREEN WHILE COMPARING NOTHING, exactly once: when BOTH sides are empty.
    /// Any other zero is still a zero worth looking at.
    @Test("Both sides empty is healthy; one side empty is not")
    func bothSidesEmptyIsTheOnlyGreenZero() throws {
        let db = try Sub4Database.inMemory()
        let empty = compare(db, [])
        #expect(empty.bothSidesAreEmpty)
        #expect(empty.isHealthy)
        #expect(empty.summary.contains("24 Aug 2026"))

        let lost = compare(db, [record()])          // app has one, database none
        #expect(!lost.bothSidesAreEmpty)
        #expect(!lost.isHealthy)
        #expect(lost.reviewsOnlyInApp.count == 1)
    }

    // MARK: The round trip

    /// IMPORTS A PLAN, because the change names a session and 327b stopped
    /// pretending a database with no plan could vouch for it. Without one the
    /// report is still correct — it says the uid could not be checked — but
    /// this test is about the round trip and wants every question answered.
    @Test("A review, its evidence and its proposal survive field by field")
    func aReviewRoundTripsWhole() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("wk3-tue")], watchFor: ["Resting rate"])
        try imported(db, [r0], plan: plan(sessionUids: ["wk3-tue"]))

        let r = compare(db, [r0])
        #expect(r.reviewsInApp == 1)
        #expect(r.reviewsInDatabase == 1)
        #expect(r.reviewsCompared == 1)
        #expect(r.evidenceCompared == 1)
        #expect(r.proposalsCompared == 1)
        #expect(r.changesCompared == 1)
        #expect(r.watchCompared == 1)
        // ONE interpolated literal. `"a" + "\(b)"` is a String expression and
        // does not convert to `Comment?` — the rule CLAUDE.md §2 records.
        let seen = r.reviewDifferences + r.evidenceDifferences
                 + r.proposalDifferences + r.changeDifferences
        #expect(r.unexplained == 0, "\(seen)")
        #expect(r.isHealthy)
    }

    /// THE DENOMINATORS ARE EXACT PRODUCTS, which is what makes them evidence
    /// rather than decoration. Five review fields, four evidence fields, five
    /// proposal fields, six per change.
    @Test("Every denominator is an exact product of its shape")
    func theDenominatorsAreExact() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("a"), change("b"), change("c")],
                        watchFor: ["one", "two"])
        try imported(db, [r0])

        let r = compare(db, [r0])
        #expect(r.reviewFieldsCompared == 5)
        #expect(r.evidenceFieldsCompared == 4)
        #expect(r.proposalFieldsCompared == 5)
        #expect(r.changesCompared == 3)
        #expect(r.changeFieldsCompared == 18, "6 per change × 3")
        #expect(r.watchCompared == 2)
        // PATCH 335 adds the three lineage rows. A denominator that does not
        // move when a comparison is added is a denominator nobody can read.
        #expect(r.totalCompared == 1 + 1 + 1 + 3 + 2 + 3)
    }

    @Test("Changes and watch items keep their order")
    func orderedListsKeepTheirOrder() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("first"), change("second")],
                        watchFor: ["alpha", "beta", "gamma"])
        try imported(db, [r0])

        let load = ReviewRepository.load(db)
        let stored = try #require(load.reviews?.first)
        let p = try #require(stored.proposals.first)
        #expect(p.changes.map(\.planSessionUID) == ["first", "second"])
        #expect(p.changes.map(\.ordinal) == [0, 1])
        #expect(p.watch == ["alpha", "beta", "gamma"])
    }

    // MARK: The comparison can fail — groundwork §2.1's test button

    @Test("A changed window is reported")
    func aChangedWindowIsADifference() throws {
        let db = try Sub4Database.inMemory()
        // ONE ID ON BOTH SIDES — see the fixture's header. Without it, 337's
        // key would read this as two different reviews and the comparator
        // under test would never run.
        try imported(db, [record(id: "one-window-1")])

        let r = compare(db, [record(id: "one-window-1", endDay: "2026-06-30")])
        #expect(r.reviewDifferences.contains { $0.hasSuffix("window end") })
        #expect(r.unexplained == 1)
    }

    @Test("A changed verdict is reported")
    func aChangedVerdictIsADifference() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, [record(verdict: .easier)])

        let r = compare(db, [record(verdict: .harder)])
        #expect(r.proposalDifferences.contains { $0.hasSuffix("verdict") })
        #expect(r.unexplained == 1)
    }

    /// A TRUNCATED PACK IS THE FAILURE THIS FIELD ACTUALLY HAS. It is the
    /// largest text in the database and the one a column-width or encoding
    /// mistake would clip.
    @Test("A truncated evidence pack is reported, with both lengths")
    func aTruncatedEvidencePackIsADifference() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, [record(evidence: String(repeating: "x", count: 400))])

        let r = compare(db, [record(evidence: String(repeating: "x", count: 200))])
        let line = try #require(r.evidenceDifferences.first)
        #expect(line.contains("evidence body"))
        #expect(line.contains("200"))
        #expect(line.contains("400"))
    }

    /// SUBSTITUTION AT THE SAME LENGTH is the case a length check alone would
    /// miss, so the values are compared and only the LENGTHS are printed.
    @Test("A substituted pack of the same length is still a difference")
    func aSubstitutedPackOfTheSameLengthIsStillADifference() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, [record(evidence: String(repeating: "x", count: 300))])

        let r = compare(db, [record(evidence: String(repeating: "y", count: 300))])
        let line = try #require(r.evidenceDifferences.first)
        #expect(line.contains("same length"))
        #expect(r.unexplained == 1)
    }

    /// COMPARED BY POSITION, NOT AS A SET. Two changes with their session uids
    /// exchanged hold the same set of uids and the same set of details; only a
    /// positional walk sees it. The consequence is the athlete's Thursday
    /// getting Tuesday's alteration.
    @Test("A change moved to another session is reported")
    func aChangeMovedToAnotherSessionIsADifference() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, [record(changes: [change("wk3-tue", newDetail: "8 km easy"),
                                           change("wk3-thu", newDetail: "12 km steady")])])

        let swapped = record(changes: [change("wk3-tue", newDetail: "12 km steady"),
                                       change("wk3-thu", newDetail: "8 km easy")])
        let r = compare(db, [swapped])
        // FOUR, NOT TWO — and the four is itself evidence. `what` is derived
        // from `newDetail` by `Sub4Import.changeSummary` for a non-skip, so the
        // two fields cannot differ independently: each swapped position reports
        // both. Expecting two was §12.60.1's mistake in miniature — reasoning
        // about two numbers without checking whether one determines the other.
        #expect(r.changeDifferences.count == 4,
                "newDetail and its derived `what`, at both positions")
        #expect(r.changesCompared == 2, "and both were still compared")
    }

    @Test("Shuffled watch items are reported")
    func shuffledWatchItemsAreADifference() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, [record(watchFor: ["Resting rate", "Sleep"])])

        let r = compare(db, [record(watchFor: ["Sleep", "Resting rate"])])
        #expect(r.watchDifferences.count == 2)
    }

    @Test("A change count that does not match is reported rather than walked")
    func aDifferentChangeCountIsReported() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, [record(changes: [change("a"), change("b")])])

        let r = compare(db, [record(changes: [change("a")])])
        #expect(r.changesCompared == 0, "a positional walk over unequal lists is nonsense")
        #expect(r.changeDifferences.count == 1)
        #expect(r.unexplained == 1)
    }

    // MARK: The rule that makes the paste safe

    /// THE ONE THAT WOULD OTHERWISE BE CAUGHT BY NOBODY. Every prose field
    /// carries a sentinel and every one of them is made to differ, so every
    /// difference line and every diagnostic line has an opportunity to leak.
    @Test("No diagnostic line carries a character of review text")
    func noDiagnosticLineCarriesReviewText() throws {
        let secret = Self.secret
        let db = try Sub4Database.inMemory()
        try imported(db, [record(evidence: "pack \(secret) one",
                                 summary: "summary \(secret)",
                                 reasoning: "reasoning \(secret)",
                                 changes: [change("wk3-tue",
                                                  newDetail: "detail \(secret)",
                                                  reason: "reason \(secret)")],
                                 watchFor: ["watch \(secret)"])])

        // Different in every prose field, so every comparator fires.
        let r = compare(db, [record(evidence: "pack \(secret) two",
                                    summary: "summary \(secret)!",
                                    reasoning: "reasoning \(secret)!",
                                    changes: [change("wk3-tue",
                                                     newDetail: "detail \(secret)!",
                                                     reason: "reason \(secret)!")],
                                    watchFor: ["watch \(secret)!"])])

        #expect(r.unexplained > 0, "the test is worthless if nothing differed")
        for line in r.diagnosticLines {
            #expect(!line.contains(secret), "leaked review text: \(line)")
        }
        for line in r.evidenceDifferences + r.proposalDifferences
                  + r.changeDifferences + r.watchDifferences {
            #expect(!line.contains(secret), "leaked review text: \(line)")
        }
    }

    // MARK: The resolve — the number nobody else computes

    @Test("A change naming a stored session resolves")
    func aChangeNamingAStoredSessionResolves() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("wk1-mon")])
        try imported(db, [r0], plan: plan(sessionUids: ["wk1-mon", "wk1-tue"]))

        let r = compare(db, [r0])
        #expect(r.planSessionUIDsKnown == 2)
        #expect(r.changesCompared == 1)
        #expect(r.changesNamingAKnownSession == 1)
        #expect(r.unexplained == 0)
    }

    /// `rejections(plan:)` already calls this case "no session with that id —
    /// invented". Nothing but this reader checks it against the database,
    /// because the column is deliberately not a foreign key.
    @Test("A change naming no stored session is unexplained")
    func aChangeNamingNoStoredSessionIsUnexplained() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("wk9-invented")])
        try imported(db, [r0], plan: plan(sessionUids: ["wk1-mon"]))

        let r = compare(db, [r0])
        #expect(r.changesNamingAKnownSession == 0)
        #expect(r.changesCompared == 1)
        #expect(r.changesResolvable == 1, "the plan is there, so the question is real")
        #expect(r.unexplained == 1, "the resolve feeds unexplained exactly once")
        #expect(r.changeDifferences.isEmpty, "and not twice — the fields all matched")
    }

    /// 327 ASSERTED THE OPPOSITE OF THIS, and was wrong.
    ///
    /// It counted every unresolved uid against the database, so a device that
    /// had imported reviews but not the plan reported the model as inventing
    /// sessions. "Could not be checked" and "failed the check" are different
    /// answers, and only one of them is somebody's fault. Two other tests in
    /// this file went red on it, which is what a comparison that can fail is
    /// for.
    @Test("With no plan imported, the uid is unanswerable rather than wrong")
    func noPlanMeansTheQuestionCannotBeAsked() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("wk1-mon")])
        try imported(db, [r0])

        let r = compare(db, [r0])
        #expect(r.planSessionUIDsKnown == 0)
        #expect(r.changesNamingAKnownSession == 0)
        #expect(r.changesUnresolvable == 1)
        #expect(r.changesResolvable == 0)
        #expect(r.unexplained == 0, "an unanswerable question is not a failure")
        #expect(r.diagnosticLines.contains { $0.contains("could not be checked") })
    }

    /// The other half, so the two cases are pinned against each other: with a
    /// plan present, an unknown uid IS a fault.
    @Test("With a plan imported, an unknown uid is a fault rather than unanswerable")
    func aPlanMakesTheQuestionAnswerable() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("wk9-invented")])
        try imported(db, [r0], plan: plan(sessionUids: ["wk1-mon"]))

        let r = compare(db, [r0])
        #expect(r.changesUnresolvable == 0)
        #expect(r.changesResolvable == 1)
        #expect(r.unexplained == 1)
    }

    // MARK: Columns and shapes nothing occupies — §12.54.2

    /// THE FINDING, ASSERTED SO IT CANNOT BE QUIETLY FIXED OR QUIETLY FORGOTTEN.
    /// ADR-0002's purge has to find every piece of evidence with Strava lineage
    /// and remove it while leaving the verdict standing. There is nothing to
    /// find, because nothing writes the table.
    /// PATCH 335 — THIS TEST INVERTED, AND THAT IS THE THIRD TIME TODAY.
    ///
    /// It used to assert that NOTHING wrote `review_evidence_source`: zero
    /// rows, and a diagnostic line worded as a fact about the writer so that a
    /// bare 0 could not be mistaken for agreement. 327 recorded the unmet
    /// obligation rather than fixing it, precisely so the day somebody wrote
    /// the lineage, a test would change and say so.
    ///
    /// It is written now — one row per source in `ReviewLineage`, per pack.
    @Test("The evidence lineage is written, one row per source")
    func theEvidenceLineageIsWritten() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("a")], watchFor: ["x"])
        try imported(db, [r0], plan: plan(sessionUids: ["a"]))

        let rows = try db.queue.read { d in
            try String.fetchAll(d, sql: """
                SELECT sourceID FROM review_evidence_source ORDER BY sourceID
                """)
        }
        #expect(rows == ReviewLineage.sourceIDs)
        #expect(rows == ["authored", "bundled", "strava"])

        let r = compare(db, [r0])
        #expect(r.evidenceSourceRows == 3)
        #expect(r.evidenceSourcesCompared == 3)
        // THE EXACT SHIPPED WORDING, still — "a printed string's content" is
        // one of the three shapes CLAUDE.md names as carrying assertions
        // elsewhere, and 327a broke this assertion by rewording the line while
        // rebuilding the function around it. §12.61.9.
        #expect(r.diagnosticLines.contains {
            $0.contains("one per source in ReviewLineage: authored, bundled, strava")
        }, "a bare 3 cannot say which three")
        #expect(r.unexplained == 0)
    }

    /// A LINEAGE THAT CANNOT DISAGREE IS NOT A COMPARISON. The rows are
    /// deleted behind the reader's back; the report must notice.
    @Test("A missing lineage row is a difference")
    func aMissingLineageRowIsADifference() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("a")], watchFor: ["x"])
        try imported(db, [r0], plan: plan(sessionUids: ["a"]))

        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM review_evidence_source WHERE sourceID = 'strava'")
        }

        let r = compare(db, [r0])
        #expect(r.evidenceSourceRows == 2)
        #expect(r.unexplained > 0)
        #expect(r.evidenceDifferences.contains { $0.contains("evidence lineage") })
    }

    @Test("No proposal carries a decision, because no screen offers the choice")
    func noProposalCarriesADecision() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record()
        try imported(db, [r0])

        let r = compare(db, [r0])
        #expect(r.proposalsCarryingADecision == 0)
        let stored = try #require(ReviewRepository.load(db).reviews?.first)
        #expect(stored.proposals.first?.decision == nil)
        #expect(stored.proposals.first?.decidedUTC == nil)
    }

    /// The schema anticipated a decomposed pack with sections that could be
    /// withheld. The importer writes one row, keyed 'pack', always sent.
    @Test("The only section key is pack, and nothing is ever withheld")
    func theEvidenceDecompositionIsNotExercised() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record()
        try imported(db, [r0])

        let r = compare(db, [r0])
        #expect(r.sectionKeysSeen == ["pack"])
        #expect(r.evidenceWithheld == 0)
    }

    /// PATCH 334 — THIS TEST INVERTED, AND THAT IS THE POINT OF HAVING HAD IT.
    ///
    /// It used to assert the contradiction: `ReviewProposal.confidence`
    /// documents itself as 1–5, the column's CHECK permitted 0–100, and 70 had
    /// been written since patch 225 and round-tripped happily. 327 printed
    /// that rather than deciding it — §12.71.4 — precisely so the day somebody
    /// decided, a test would change rather than the change going unnoticed.
    ///
    /// `2026-08-13-confidence-scale` narrowed the column to 1–5. The same 70
    /// now refuses at the door, which is what a contract that means something
    /// looks like.
    @Test("The observed confidence range is reported")
    func theConfidenceRangeIsReported() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(confidence: 3)
        try imported(db, [r0])

        let r = compare(db, [r0])
        #expect(r.confidenceRange == "3")
        #expect(r.proposalDifferences.isEmpty)
    }

    // MARK: Which side is missing, and which of those is a fault

    /// §12.8.1. A reinstall once took every past review and there was nowhere
    /// to get them back from. If the database is the only copy, the row showing
    /// that must not be red.
    @Test("A review only in the database is not counted against it")
    func aReviewOnlyInTheDatabaseIsNotCountedAgainstIt() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, [record()])

        let r = compare(db, [])
        #expect(r.reviewsOnlyInDatabase.count == 1)
        #expect(r.reviewsOnlyInApp.isEmpty)
        #expect(r.unexplained == 0, "the database holding the only copy is the point")
    }

    @Test("A review only in the app is a fault")
    func aReviewOnlyInTheAppIsAFault() throws {
        let db = try Sub4Database.inMemory()
        let r = compare(db, [record()])
        #expect(r.reviewsOnlyInApp.count == 1)
        #expect(r.unexplained == 1)
    }

    // MARK: The run time stopped being the key — patch 337

    /// INVERTED AT 337, AND THE INVERSION IS THE POINT.
    ///
    /// This test was written at 327 to assert that a run-time collision is
    /// REPORTED rather than silently merged, and it passed for ten patches
    /// because nothing ever collided. On 9 August 2026 the rehearsal wrote two
    /// records in one second, the importer's `WHERE ranUTC = ?` found the wrong
    /// row, and one review's evidence and proposal were overwritten by
    /// another's. The old assertion — `unexplained >= 1` — described a fault
    /// this patch removes rather than reports.
    ///
    /// So the subject is now: BOTH RECORDS SURVIVE THE ROUND TRIP. The
    /// collision is still counted, and it is no longer a difference.
    @Test("Two app records sharing a run time both import and both compare")
    func twoAppRecordsAtTheSameRunTimeBothSurvive() throws {
        let db = try Sub4Database.inMemory()
        let a = record(ranAt: 1_780_100_000, startDay: "2026-06-01")
        let b = record(ranAt: 1_780_100_000, startDay: "2026-05-01")
        try imported(db, [a, b])

        let r = compare(db, [a, b])
        #expect(r.reviewsInApp == 2)
        #expect(r.reviewsInDatabase == 2, "one row per record, not one per second")
        #expect(r.reviewsCompared == 2)
        #expect(r.duplicateRunTimes.count == 1, "still counted, still visible")
        #expect(r.reviewsOnlyInApp.isEmpty)
        #expect(r.unexplained == 0, "a shared run time is not a difference")
    }

    /// THE 9 AUGUST FAILURE, REPRODUCED AGAINST THE OLD BEHAVIOUR'S SHAPE.
    ///
    /// Two records, one second, DIFFERENT CONTENT. Before 337 the second
    /// record's window and proposal landed on the first's row and the first's
    /// were gone. Reading the window days back proves both are stored, which a
    /// count of rows alone would not: five rows holding the wrong five packs
    /// is what actually happened, and `review: 5` looked fine.
    @Test("Neither record's contents overwrite the other's")
    func neitherRecordOverwritesTheOther() throws {
        let db = try Sub4Database.inMemory()
        let a = record(ranAt: 1_780_100_000, startDay: "2026-06-01",
                       endDay: "2026-06-28", summary: "Ease the next week.")
        let b = record(ranAt: 1_780_100_000, startDay: "2026-05-01",
                       endDay: "2026-05-28", summary: "Hold the volume.")
        try imported(db, [a, b])

        let windows = try db.queue.read {
            try String.fetchSet($0, sql: "SELECT windowStartDayKey FROM review")
        }
        #expect(windows == ["2026-06-01", "2026-05-01"])

        let summaries = try db.queue.read {
            try String.fetchSet($0, sql: "SELECT summary FROM proposal")
        }
        #expect(summaries == ["Ease the next week.", "Hold the volume."])
    }

    /// Importing the same record twice must not produce a second row — the
    /// property `ranUTC` used to provide, now provided by the key that
    /// replaced it. Without this, 337 would have traded a merge for a
    /// duplicate.
    @Test("The same record imported twice stays one row")
    func reimportingTheSameRecordStaysOneRow() throws {
        let db = try Sub4Database.inMemory()
        let a = record()
        try imported(db, [a])
        try imported(db, [a])

        let r = compare(db, [a])
        #expect(r.reviewsInDatabase == 1)
        #expect(r.pairedByRecordKey == 1)
        #expect(r.pairedByRunTime == 0)
        #expect(r.unexplained == 0)
    }

    /// A fresh database has no pre-337 rows, so the fallback must never fire.
    /// `pairedByRunTime` reading anything but zero on a device that has
    /// imported since 337 is the signal that adoption did not happen.
    @Test("A fresh import pairs by key and never by run time")
    func aFreshImportNeverPairsByRunTime() throws {
        let db = try Sub4Database.inMemory()
        let rs = [record(startDay: "2026-06-01"), record(startDay: "2026-05-01")]
        try imported(db, rs)

        let r = compare(db, rs)
        #expect(r.pairedByRecordKey == 2)
        #expect(r.pairedByRunTime == 0)
        #expect(r.reviewsAwaitingAKey == 0)
    }

    // MARK: The approved list is a decision record

    /// Groundwork §5: an entry nobody can justify is a bug that has been given
    /// a hiding place. Same guard as the other read-backs.
    @Test("Every approved difference carries a reason")
    func everyApprovedDifferenceHasAReason() {
        // THREE UNTIL PATCH 337, WHICH DELETED `Record.id`. An approved
        // difference is a claim that a gap is deliberate and harmless; that
        // one turned out to be neither, so it became a column rather than a
        // better-worded excuse. The number is pinned so the list cannot shrink
        // by accident — the entries left have to be argued out, not dropped.
        #expect(ReviewRoundTrip.approved.count == 2)
        #expect(!ReviewRoundTrip.approved.contains { $0.field == "Record.id" },
                "337 built review.recordKey — the difference is not approved, it is gone")
        for a in ReviewRoundTrip.approved {
            #expect(!a.field.isEmpty)
            #expect(a.why.count > 40, "\(a.field) has no real reason attached")
        }
    }

    /// `provider` has no field on the record, so it is compared against the
    /// constant the importer writes. If that constant ever changes without the
    /// column being migrated, this is what says so.
    @Test("Provider is compared against the constant the importer writes")
    func providerIsComparedAgainstTheImportersConstant() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record()
        try imported(db, [r0])

        let stored = try #require(ReviewRepository.load(db).reviews?.first)
        #expect(stored.provider == Sub4Import.reviewProvider)
        #expect(compare(db, [r0]).reviewDifferences.isEmpty)
    }

    /// §12.43, tenth application: `what` has no app-side field, so the
    /// comparison calls the importer's own `changeSummary` rather than
    /// restating its two lines.
    @Test("A skip's rendered summary comes from the importer's own function")
    func theRenderedSummaryIsNotReimplemented() throws {
        let db = try Sub4Database.inMemory()
        let r0 = record(changes: [change("wk3-thu", skip: true)])
        try imported(db, [r0])

        let stored = try #require(ReviewRepository.load(db).reviews?.first)
        let c = try #require(stored.proposals.first?.changes.first)
        #expect(c.what == Sub4Import.changeSummary(change("wk3-thu", skip: true)))
        #expect(!c.what.isEmpty, "a skip must not import with an empty summary")
        #expect(compare(db, [r0]).changeDifferences.isEmpty)
    }
}
