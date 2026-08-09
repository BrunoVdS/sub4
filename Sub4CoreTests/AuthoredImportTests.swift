//
//  AuthoredImportTests.swift
//  Sub4CoreTests
//
//  Notes and proposals — patch 225, ADR-0003 §12.7.
//
//  THESE ARE THE STORES THAT CANNOT BE RE-FETCHED. An activity lost in the
//  cutover comes back from Strava; thirteen months of what the athlete thought
//  after each session does not. So the tests here are less about the mechanics
//  and more about loss: does every field arrive, does a second run duplicate
//  anything, and does a change keep the session it applies to.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct AuthoredImportTests {

    private func note(_ uid: String, rpe: Int? = 6,
                      feel: NotesStore.Note.Feel? = .expected,
                      text: String = "Legs heavy for the first 3 km.") -> NotesStore.Note {
        NotesStore.Note(sessionUid: uid, rpe: rpe, feel: feel, text: text,
                        created: Date(timeIntervalSince1970: 1_780_000_000),
                        edited: Date(timeIntervalSince1970: 1_780_000_500))
    }

    private func change(_ uid: String, skip: Bool = false) -> ReviewProposal.Change {
        .init(sessionUid: uid, newDetail: "8 km easy", skip: skip,
              evidence: "TSB −22 for 5 days", reason: "Freshness is deep")
    }

    private func record(_ ranAt: Double = 1_780_100_000,
                        changes: [ReviewProposal.Change] = [],
                        watchFor: [String] = []) -> ProposalStore.Record {
        .init(id: "2026-06-01→2026-06-28-1",
              ranAt: Date(timeIntervalSince1970: ranAt),
              windowLabel: "1–28 June",
              startDay: "2026-06-01", endDay: "2026-06-28",
              evidence: "## Load\nCTL 41, ATL 63, TSB −22.",
              proposal: .init(verdict: .easier,
                              summary: "Ease the next week.",
                              reasoning: "Freshness has been deep for five days.",
                              // PATCH 334. Was 70 since patch 225 — a value the
                              // column admitted and the screen could not draw.
                              // §12.82.
                              changes: changes, watchFor: watchFor, confidence: 4),
              appVersion: "1.0 (1) · patch 225",
              model: "claude-opus-5")
    }

    // MARK: Notes

    @Test("Every field of a note arrives")
    func aNoteArrivesWhole() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [note("wk3-tue")])
        let row = try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM user_note")
        }
        let r = try #require(row)
        #expect(r["planSessionUID"] as String? == "wk3-tue")
        #expect(r["rpe"] as Int? == 6)
        #expect(r["feel"] as String? == "expected")
        #expect((r["text"] as String? ?? "").contains("Legs heavy"))
        #expect(r["createdUTC"] as String? != nil)
        #expect(r["editedUTC"] as String? != nil)
    }

    /// §12.7.1. Both stay NULL until the plan is imported and the matcher runs.
    /// Asserted rather than assumed, because a future importer that helpfully
    /// filled `activityID` would be making a matching decision nobody reviewed.
    @Test("A note is not resolved to a plan version or an activity")
    func aNoteIsNotMatchedByTheImporter() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [note("wk3-tue")])
        let (version, activity) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT planVersionID FROM user_note"),
             try String.fetchOne(d, sql: "SELECT activityID FROM user_note"))
        }
        #expect(version == nil)
        #expect(activity == nil)
    }

    @Test("Re-importing a note updates it rather than adding a second")
    func notesConverge() throws {
        let db = try Sub4Database.inMemory()
        let first = try Sub4Import.run(into: db, activities: [], shoes: [],
                                       notes: [note("wk3-tue", text: "First")])
        let second = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        notes: [note("wk3-tue", text: "Edited")])
        #expect(first.notesImported == 1)
        #expect(second.notesImported == 0)
        #expect(second.notesUpdated == 1)

        let (count, text) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM user_note") ?? -1,
             try String.fetchOne(d, sql: "SELECT text FROM user_note"))
        }
        #expect(count == 1)
        #expect(text == "Edited", "the edit did not reach the database")
    }

    /// `rpe` carries a CHECK of 1…10. A refused note must not take the others
    /// with it — the same savepoint rule as activities, and it matters more
    /// here because nothing can re-fetch what is lost.
    @Test("A note the schema refuses does not cost the others")
    func aRefusedNoteIsIsolated() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [], notes: [
            note("good-1"),
            note("bad", rpe: 0),          // outside 1…10
            note("good-2")
        ])
        #expect(report.notesImported == 2)
        #expect(report.refusals.count == 1)
        #expect(report.refusals.first?.externalID.contains("bad") == true)
    }

    // MARK: Reviews and proposals

    @Test("A review, its evidence, its proposal and its parts all arrive")
    func aReviewArrivesWhole() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], proposals: [
            record(changes: [change("wk3-tue"), change("wk3-thu", skip: true)],
                   watchFor: ["Resting rate", "Sleep"])
        ])
        let counts = try db.queue.read { d in
            (review: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM review") ?? -1,
             evidence: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM review_evidence") ?? -1,
             proposal: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM proposal") ?? -1,
             changes: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM proposal_change") ?? -1,
             watch: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM proposal_watch") ?? -1)
        }
        #expect(counts.review == 1)
        #expect(counts.evidence == 1)
        #expect(counts.proposal == 1)
        #expect(counts.changes == 2)
        #expect(counts.watch == 2)
    }

    /// THE FIVE FIELDS §12.7 FOUND HOMELESS. If any of these is null the
    /// migration was pointless — and the failure would be silent, because a
    /// proposal with no session uid still looks like a proposal.
    @Test("The fields the schema was missing all arrive")
    func theMissingFieldsArrive() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], proposals: [
            record(changes: [change("wk3-thu", skip: true)], watchFor: ["Sleep"])
        ])
        let row = try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM proposal_change")
        }
        let c = try #require(row)
        #expect(c["planSessionUID"] as String? == "wk3-thu")
        #expect(c["isSkip"] as Bool? == true)
        #expect(c["evidence"] as String? == "TSB −22 for 5 days")
        #expect(c["newDetail"] as String? == "8 km easy")
        #expect(c["why"] as String? == "Freshness is deep")

        let appVersion = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT appVersion FROM review")
        }
        #expect(appVersion?.contains("patch 225") == true)
    }

    /// `what` is for reading and `newDetail` is for applying. A skip has no
    /// replacement text, so rendering `newDetail` into a NOT NULL column would
    /// write an empty string into the field that is supposed to say what
    /// changed.
    @Test("A skip says it is a skip rather than saying nothing")
    func aSkipRendersAsSomething() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], proposals: [
            record(changes: [.init(sessionUid: "wk3-thu", newDetail: "", skip: true,
                                   evidence: "TSB −22", reason: "Too deep")])
        ])
        let what = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT what FROM proposal_change")
        }
        #expect(what?.isEmpty == false, "a skip imported with an empty `what`")
    }

    /// §12.7.2 said `windowLabel` would not be carried. It is — `review_evidence`
    /// has a NOT NULL title and the label says what the pack covers better than
    /// a string derived from two day keys would. The ADR is wrong on that point
    /// and this is the test that records it.
    @Test("The window label survives as the evidence title")
    func theWindowLabelIsNotLost() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], proposals: [record()])
        let title = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT title FROM review_evidence")
        }
        #expect(title == "1–28 June")
    }

    @Test("Re-importing a review replaces its parts rather than stacking them")
    func reviewsConverge() throws {
        let db = try Sub4Database.inMemory()
        let rows = [record(changes: [change("wk3-tue")], watchFor: ["Sleep"])]
        let first = try Sub4Import.run(into: db, activities: [], shoes: [], proposals: rows)
        let second = try Sub4Import.run(into: db, activities: [], shoes: [], proposals: rows)

        #expect(first.reviewsImported == 1)
        #expect(second.reviewsImported == 0)
        #expect(second.reviewsUpdated == 1)

        let counts = try db.queue.read { d in
            (review: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM review") ?? -1,
             evidence: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM review_evidence") ?? -1,
             proposal: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM proposal") ?? -1,
             changes: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM proposal_change") ?? -1,
             watch: try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM proposal_watch") ?? -1)
        }
        #expect(counts.review == 1)
        #expect(counts.evidence == 1, "the evidence stacked")
        #expect(counts.proposal == 1, "the proposal stacked")
        #expect(counts.changes == 1, "the changes stacked")
        #expect(counts.watch == 1, "the watch items stacked")
    }

    /// Deleting the proposal must take its changes and watch items with it, or
    /// a refresh leaves orphans that the integrity check will find and nobody
    /// will be able to explain.
    @Test("Deleting a proposal clears its changes and watch items")
    func cascadeReachesTheChildren() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], proposals: [
            record(changes: [change("a"), change("b")], watchFor: ["x", "y"])
        ])
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM proposal")
        }
        let (changes, watch) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM proposal_change") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM proposal_watch") ?? -1)
        }
        #expect(changes == 0)
        #expect(watch == 0)
    }

    /// Declared and applied. NOT "and last" — that assertion was written in
    /// patch 222 and broke in 225 by the next migration merely existing. The
    /// ordering invariant lives in `ActivityInputTests` now, expressed as a
    /// property that survives every future migration.
    @Test("The new migration is declared and applied")
    func theMigrationIsDeclared() throws {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.proposalInputs))
        let db = try Sub4Database.inMemory()
        let applied = try db.integrityReport().appliedMigrations
        #expect(applied.contains(Sub4Migrations.proposalInputs))
    }
}
