//
//  ReconcileTests.swift
//  Sub4CoreTests
//
//  What the athlete deleted — patch 274, ADR-0003 §12.21.
//
//  THE TEST THAT HAD TO EXIST BEFORE THE CODE DID IS `theGateRefuses`.
//  Everything else here proves the pass removes what it should; that one
//  proves it does nothing when it has not been given permission, which is the
//  only property standing between a corrupt `notes.json` and thirteen months
//  of deleted notes.
//
//  AND `aDeletedReviewTakesItsWholeRecord`, because the cascade is the part
//  that is asserted rather than read: deleting one `review` row is supposed to
//  remove five, and a foreign key that was declared without `ON DELETE
//  CASCADE` would leave four orphans with nothing complaining.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct ReconcileTests {

    // MARK: Fixtures

    private func note(_ uid: String) -> NotesStore.Note {
        NotesStore.Note(sessionUid: uid, rpe: 6, feel: .expected,
                        text: "Legs heavy for the first 3 km.",
                        created: Date(timeIntervalSince1970: 1_780_000_000),
                        edited: Date(timeIntervalSince1970: 1_780_000_500))
    }

    private func decision(_ uid: String, _ activityId: String?) -> MatchDecision {
        MatchDecision(sessionUid: uid, activityId: activityId,
                      decided: Date(timeIntervalSince1970: 1_785_000_000),
                      dateIsKnown: true)
    }

    private func activity(_ id: String) -> Activity {
        Activity(id: id, name: "Morning Run", sportType: "Run",
                 startLocal: "2026-07-28T09:24:06", distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: 40, averageHeartrate: 142, isTrainer: nil,
                 maxHeartrate: 160, gearId: nil, maxSpeed: 4.2,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T07:24:06Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func record(_ ranAt: Double = 1_780_100_000) -> ProposalStore.Record {
        .init(id: "2026-06-01→2026-06-28-1",
              ranAt: Date(timeIntervalSince1970: ranAt),
              windowLabel: "1–28 June",
              startDay: "2026-06-01", endDay: "2026-06-28",
              evidence: "## Load\nCTL 41, ATL 63, TSB −22.",
              proposal: .init(verdict: .easier,
                              summary: "Ease the next week.",
                              reasoning: "Freshness has been deep for five days.",
                              changes: [.init(sessionUid: "wk3-tue",
                                              newDetail: "8 km easy", skip: false,
                                              evidence: "TSB −22 for 5 days",
                                              reason: "Freshness is deep")],
                              // PATCH 334 — 1–5 is the contract now. §12.82.
                              watchFor: ["Sleep"], confidence: 4),
              appVersion: "1.0 (1) · patch 274",
              model: "rehearsal")
    }

    private func count(_ db: Sub4Database, _ table: String) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // MARK: The gate

    /// THE ONE THAT MATTERS. Without `.run` the pass must not touch a row —
    /// this is what stands between an unreadable `notes.json` and a database
    /// that deletes the only intact copy of thirteen months of notes.
    @Test("Without permission the pass removes nothing")
    func theGateRefuses() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [note("wk3-tue")], reconcile: .run(Set(ReconcileFamily.allCases)))
        let userNoteRows1 = try count(db, "user_note")
        #expect(userNoteRows1 == 1)

        // The store is now empty and the caller did not ask. This is exactly
        // the shape of a failed read, and it must change nothing.
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        notes: [])
        let userNoteRows2 = try count(db, "user_note")
        #expect(userNoteRows2 == 1)
        #expect(report.notesRemoved == 0)
        #expect(!report.reconciled.permits(.notes))
    }

    @Test("The skip carries its reason, and the two reasons differ")
    func theSkipSaysWhy() throws {
        let db = try Sub4Database.inMemory()
        let notAsked = try Sub4Import.run(into: db, activities: [], shoes: [])
        let gated = try Sub4Import.run(into: db, activities: [], shoes: [],
                                       reconcile: .skipped("a store could not be read"))

        #expect(notAsked.reconciled != gated.reconciled)
        #expect(gated.reconciled.line.contains("could not be read"))
        // A single Bool would have made these two the same word.
        #expect(notAsked.reconciled.line != gated.reconciled.line)
    }

    // MARK: Notes

    @Test("A note deleted from the store is deleted from the table")
    func aDeletedNoteIsRemoved() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [note("wk3-tue"), note("wk3-thu")],
                               reconcile: .run(Set(ReconcileFamily.allCases)))
        let userNoteRows3 = try count(db, "user_note")
        #expect(userNoteRows3 == 2)

        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        notes: [note("wk3-tue")], reconcile: .run(Set(ReconcileFamily.allCases)))
        #expect(report.notesRemoved == 1)
        let userNoteRows4 = try count(db, "user_note")
        #expect(userNoteRows4 == 1)

        let left = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT planSessionUID FROM user_note")
        }
        #expect(left == "wk3-tue")
    }

    @Test("An empty notes store empties the table, and only when permitted")
    func anEmptyStoreEmptiesTheTable() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [note("wk3-tue")], reconcile: .run(Set(ReconcileFamily.allCases)))

        // The dangerous case, asserted deliberately rather than left to be
        // discovered: with permission, zero notes means zero rows. Everything
        // in patch 273 exists so that "zero notes" is only ever said by a
        // store that was actually read.
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        notes: [], reconcile: .run(Set(ReconcileFamily.allCases)))
        #expect(report.notesRemoved == 1)
        let userNoteRows5 = try count(db, "user_note")
        #expect(userNoteRows5 == 0)
    }

    // MARK: Match decisions

    @Test("Back to automatic removes the decision")
    func aClearedOverrideIsRemoved() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               matchDecisions: [decision("wk3-tue", "19580875358")],
                               reconcile: .run(Set(ReconcileFamily.allCases)))
        let matchDecisionRows1 = try count(db, "match_decision")
        #expect(matchDecisionRows1 == 1)

        let report = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        matchDecisions: [], reconcile: .run(Set(ReconcileFamily.allCases)))
        #expect(report.matchDecisionsRemoved == 1)
        let matchDecisionRows2 = try count(db, "match_decision")
        #expect(matchDecisionRows2 == 0)
    }

    /// A decision the importer HELD BACK is still a decision. Its uid is in
    /// the store, so the pass must leave it alone rather than reading "no row
    /// was written" as "he deleted it".
    @Test("A held-back decision is not treated as a deletion")
    func aHeldBackDecisionSurvives() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               matchDecisions: [decision("wk3-tue", "19580875358")],
                               reconcile: .run(Set(ReconcileFamily.allCases)))

        // Same session, now naming an activity the database does not have.
        let report = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        matchDecisions: [decision("wk3-tue", "99999999999")],
                                        reconcile: .run(Set(ReconcileFamily.allCases)))
        #expect(report.matchDecisionsUnresolved == 1)
        #expect(report.matchDecisionsRemoved == 0)
        let matchDecisionRows3 = try count(db, "match_decision")
        #expect(matchDecisionRows3 == 1)
    }

    // MARK: Reviews, and the cascade

    @Test("A deleted review takes its whole record with it")
    func aDeletedReviewTakesItsWholeRecord() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               proposals: [record()], reconcile: .run(Set(ReconcileFamily.allCases)))
        let reviewRows1 = try count(db, "review")
        #expect(reviewRows1 == 1)
        let reviewEvidenceRows1 = try count(db, "review_evidence")
        #expect(reviewEvidenceRows1 == 1)
        let proposalRows1 = try count(db, "proposal")
        #expect(proposalRows1 == 1)
        let proposalChangeRows1 = try count(db, "proposal_change")
        #expect(proposalChangeRows1 == 1)
        let proposalWatchRows1 = try count(db, "proposal_watch")
        #expect(proposalWatchRows1 == 1)

        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        proposals: [], reconcile: .run(Set(ReconcileFamily.allCases)))

        #expect(report.reviewsRemoved == 1)
        // THE CASCADE, ASSERTED. Deleting one row is supposed to remove five;
        // a foreign key declared without ON DELETE CASCADE would leave four
        // orphans and nothing would complain.
        let reviewRows2 = try count(db, "review")
        #expect(reviewRows2 == 0)
        let reviewEvidenceRows2 = try count(db, "review_evidence")
        #expect(reviewEvidenceRows2 == 0)
        let proposalRows2 = try count(db, "proposal")
        #expect(proposalRows2 == 0)
        let proposalChangeRows2 = try count(db, "proposal_change")
        #expect(proposalChangeRows2 == 0)
        let proposalWatchRows2 = try count(db, "proposal_watch")
        #expect(proposalWatchRows2 == 0)
    }

    @Test("A review still in the store survives a reconciled import")
    func aKeptReviewSurvives() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               proposals: [record()], reconcile: .run(Set(ReconcileFamily.allCases)))
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        proposals: [record()], reconcile: .run(Set(ReconcileFamily.allCases)))
        #expect(report.reviewsRemoved == 0)
        let reviewRows3 = try count(db, "review")
        #expect(reviewRows3 == 1)
        let proposalChangeRows3 = try count(db, "proposal_change")
        #expect(proposalChangeRows3 == 1)
    }

    // MARK: The verifier learns to check reviews

    @Test("An orphaned review is caught by the verifier")
    func anOrphanedReviewIsCaught() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               proposals: [record()], reconcile: .run(Set(ReconcileFamily.allCases)))

        // The store no longer has it and the pass was not allowed to run —
        // which is precisely the state the device was in on 5 August, and
        // which nothing could see because the verifier did not check reviews.
        let report = try SemanticVerifier.verify(db, activities: [], proposals: [])
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "review" })
    }

    @Test("A reconciled import verifies")
    func aReconciledImportVerifies() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [note("wk3-tue")], proposals: [record()],
                               reconcile: .run(Set(ReconcileFamily.allCases)))
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [], proposals: [], reconcile: .run(Set(ReconcileFamily.allCases)))

        let report = try SemanticVerifier.verify(db, activities: [])
        #expect(report.passed, "a reconciled migration failed verification")
    }
}
