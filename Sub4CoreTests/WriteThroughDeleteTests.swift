//
//  WriteThroughDeleteTests.swift
//  Sub4CoreTests
//
//  The run the athlete caused may delete — patch 360, ADR-0003 §12.104.
//
//  WHAT WAS MEASURED, ON THE DEVICE, ON 15 AUGUST
//  ----------------------------------------------
//  Three steps, each validated before the next:
//
//    1. baseline          blob 3, database 3, unexplained differences 0
//    2. Back to automatic blob 2, database 3, only in the database 1
//       (a write-through fired: authored, patch 359, 09:28:15Z)
//    3. Import button     match decisions 2 seen, 1 removed, database 2
//
//  Reconciliation works. The automatic write-through was refusing to run it —
//  `DatabaseWriteThrough.writeThrough` overwrote the gate's answer with
//  `.skipped("an automatic write-through does not delete")` for every trigger.
//
//  WHY THAT WAS RIGHT UNTIL 358
//  ----------------------------
//  The blob was what the app read and the database was a shadow. A row the
//  athlete had deleted sat there until somebody ran a reconciled import, and
//  the blanket refusal protected against a store that transiently failed to
//  decode taking thirteen months of notes with it — 274's argument, and it has
//  not stopped being true.
//
//  B2 INVERTED THE CONSEQUENCE. `Matcher`, `NotesStore` and `CommuteStore` are
//  hydrated FROM the database at launch, so a row the write-through refuses to
//  delete is not stale: it comes back, the store serves it, and the next save
//  persists it over the file. The deletion survives only in a blob nothing
//  reads again — and on 15 August an unrelated edit resolved the disagreement
//  in the database's favour, silently, which is why the read-back went quiet
//  on its own.
//
//  THE SPLIT THIS FILE PINS
//  ------------------------
//  `.authored` is fired by `NotesStore.save`, `Matcher.persist` and
//  `CommuteStore` — the athlete wrote something and the stores are exactly as
//  they left them. `backgrounded`, `foregrounded` and `backgroundRefresh` are
//  fired by the system at a moment nobody chose. So the run you caused may
//  delete; the runs the system causes may not.
//
//  AND `theGateStillRefuses` IS THE ONE THAT MATTERS, for the same reason
//  `ReconcileTests.theGateRefuses` is: this patch widens WHICH RUNS MAY ASK,
//  not what the answer is. A store that did not read cleanly still deletes
//  nothing, on any trigger.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("The run the athlete caused may delete")
@MainActor
struct WriteThroughDeleteTests {

    // MARK: Fixtures

    /// `activityId: nil` throughout — "explicitly nothing satisfied this
    /// session". It needs no `activity` row to resolve against, and it is the
    /// shape the device was carrying when this was found.
    private func decision(_ uid: String) -> MatchDecision {
        MatchDecision(sessionUid: uid, activityId: nil,
                      decided: Date(timeIntervalSince1970: 1_785_000_000),
                      dateIsKnown: true)
    }

    private func count(_ db: Sub4Database, _ table: String) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    /// Two decisions in the database, put there the way the Import button does
    /// it, so the starting state is one this app really produces.
    private func seeded() throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               matchDecisions: [decision("wk3-tue"),
                                                decision("wk3-thu")],
                               reconcile: .run(Set(ReconcileFamily.allCases)))
        return db
    }

    /// The stores as they are a moment after the athlete cleared one — one
    /// decision left, and the gate saying the files read cleanly.
    private func afterADelete() -> AppStores {
        var s = AppStores()
        s.matchDecisions = [decision("wk3-tue")]
        s.reconcile = .run(Set(ReconcileFamily.allCases))
        return s
    }

    private func report(_ o: DatabaseWriteThrough.Outcome)
        -> Sub4Import.Report? {
        if case .wrote(let r, _) = o { return r }
        return nil
    }

    // MARK: The defect, and the fix

    /// **THE TEST THIS PATCH EXISTS FOR.** Before 360 this left two rows and
    /// the next launch handed the deleted one back.
    @Test("An authored run deletes what the athlete deleted")
    func anAuthoredRunDeletes() throws {
        let db = try seeded()
        let before = try count(db, "match_decision")
        #expect(before == 2)

        let out = DatabaseWriteThrough.writeThrough(
            db, stores: afterADelete(), appVersion: "test", trigger: .authored, family: .matchDecisions, cause: "a test")

        let r = try #require(report(out))
        #expect(r.reconciled.permits(.matchDecisions),
                "the athlete's own save may delete its OWN family")
        #expect(r.matchDecisionsRemoved == 1)
        let after = try count(db, "match_decision")
        #expect(after == 1)
    }

    /// The other half of the split, and it is not a leftover: a backgrounding
    /// fires at a moment nobody chose, with the stores in whatever state they
    /// happen to be in. 274's guard was earned there and stays there.
    @Test("A system-triggered run still refuses to delete")
    func aSystemRunRefuses() throws {
        for trigger: MigrationRunTrigger in [.backgrounded, .foregrounded,
                                             .backgroundRefresh] {
            let db = try seeded()
            let out = DatabaseWriteThrough.writeThrough(
                db, stores: afterADelete(), appVersion: "test", trigger: trigger,
                family: nil, cause: "a test")

            let r = try #require(report(out))
            #expect(ReconcileFamily.allCases.allSatisfy { !r.reconciled.permits($0) },
                    "a run nobody asked for may not delete from ANY family")
            #expect(r.reconciled.line.contains("does not delete"))
            #expect(r.matchDecisionsRemoved == 0)
            let kept = try count(db, "match_decision")
            #expect(kept == 2, "a system run removed a row")
        }
    }

    /// **THE ONE THAT MATTERS — `ReconcileTests.theGateRefuses`, re-aimed.**
    ///
    /// 360 widens which runs may ASK. It must not widen the ANSWER: a store
    /// that did not read cleanly deletes nothing, and an authored trigger buys
    /// no exception. This is what stands between an unreadable `notes.json` and
    /// a database that removes the only intact copy.
    @Test("An authored run whose stores did not read cleanly still deletes nothing")
    func theGateStillRefuses() throws {
        let db = try seeded()
        var s = afterADelete()
        s.reconcile = .skipped("a store could not be read")

        let out = DatabaseWriteThrough.writeThrough(
            db, stores: s, appVersion: "test", trigger: .authored, family: .matchDecisions, cause: "a test")

        let r = try #require(report(out))
        #expect(!r.reconciled.permits(.matchDecisions))
        #expect(r.reconciled.line.contains("could not be read"),
                "the gate's reason survives, not the trigger's")
        #expect(r.matchDecisionsRemoved == 0)
        let keptByTheGate = try count(db, "match_decision")
        #expect(keptByTheGate == 2)
    }

    /// The two refusals are different sentences, for `ReconcileTests`' reason:
    /// "the caller may not" and "a store could not be read" send a reader to
    /// opposite places, and a single Bool would have made them one word.
    @Test("The two refusals do not share a sentence")
    func theTwoRefusalsDiffer() throws {
        let db = try seeded()
        var unread = afterADelete()
        unread.reconcile = .skipped("a store could not be read")

        let byTrigger = DatabaseWriteThrough.writeThrough(
            db, stores: afterADelete(), appVersion: "test",
            trigger: .backgrounded, family: nil, cause: "a test")
        let byGate = DatabaseWriteThrough.writeThrough(
            db, stores: unread, appVersion: "test", trigger: .authored, family: .matchDecisions, cause: "a test")

        let a = try #require(report(byTrigger))
        let b = try #require(report(byGate))
        #expect(a.reconciled != b.reconciled)
        #expect(a.reconciled.line != b.reconciled.line)
    }

    // MARK: Steady state

    /// WITH NOTHING DELETED IT IS A NO-OP, which is what makes the widening
    /// safe to leave on. Under B2 the store is seeded from the database at
    /// launch, so the keep-set equals the table until the athlete edits — every
    /// authored run between edits removes nothing at all.
    @Test("An authored run that matches the database removes nothing")
    func anUnchangedStoreRemovesNothing() throws {
        let db = try seeded()
        var s = AppStores()
        s.matchDecisions = [decision("wk3-tue"), decision("wk3-thu")]
        s.reconcile = .run(Set(ReconcileFamily.allCases))

        let out = DatabaseWriteThrough.writeThrough(
            db, stores: s, appVersion: "test", trigger: .authored, family: .matchDecisions, cause: "a test")

        let r = try #require(report(out))
        #expect(r.reconciled.permits(.matchDecisions))
        #expect(r.matchDecisionsRemoved == 0)
        let unchanged = try count(db, "match_decision")
        #expect(unchanged == 2)
    }

    /// The same widening reaches notes, and it has to: `NotesStore.remove` fires
    /// the identical trigger, and a deleted note that came back would be worse
    /// than a resurrected match decision — it is the one thing in this app that
    /// cannot be fetched again.
    @Test("A deleted note is deleted on the athlete's own save too")
    func aDeletedNoteIsRemovedToo() throws {
        let db = try Sub4Database.inMemory()
        let a = NotesStore.Note(sessionUid: "wk3-tue", rpe: 6, feel: nil,
                                text: "Legs heavy.",
                                created: Date(timeIntervalSince1970: 1_780_000_000),
                                edited: Date(timeIntervalSince1970: 1_780_000_000))
        let b = NotesStore.Note(sessionUid: "wk3-thu", rpe: 4, feel: nil,
                                text: "Fine.",
                                created: Date(timeIntervalSince1970: 1_780_000_000),
                                edited: Date(timeIntervalSince1970: 1_780_000_000))
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [a, b],
                               reconcile: .run(Set(ReconcileFamily.allCases)))
        let notesBefore = try count(db, "user_note")
        #expect(notesBefore == 2)

        var s = AppStores()
        s.notes = [a]
        s.reconcile = .run(Set(ReconcileFamily.allCases))
        let out = DatabaseWriteThrough.writeThrough(
            db, stores: s, appVersion: "test", trigger: .authored,
            family: .notes, cause: "a test")

        let r = try #require(report(out))
        #expect(r.notesRemoved == 1)
        let notesAfter = try count(db, "user_note")
        #expect(notesAfter == 1)
    }

    // MARK: The cross-family path — patch 414, §12.159

    private func proposal(_ ranAt: String) -> ProposalStore.Record {
        ProposalStore.Record(
            id: "w01-\(ranAt)",
            ranAt: ISO8601DateFormatter().date(from: ranAt) ?? Date(),
            windowLabel: "Week 01",
            startDay: "2026-07-28",
            endDay: "2026-08-01",
            evidence: "",
            proposal: ReviewRehearsal.proposal(naming: ["wk-01-tue-easy"]),
            appVersion: "414-test",
            model: "test")
    }

    /// **THE TEST TOPIC 1C ASKS FOR, IN ITS OWN WORDS.**
    ///
    /// *"Prove the current cross-family path with a failing test: a note-
    /// authored trigger must not be able to remove a review row."*
    ///
    /// It failed before 414 and the mechanism is worth stating, because it is
    /// worse than a shared permission. **Nothing in this app announces a
    /// proposal change** — there is no `noteAuthoredChange` for reviews — so
    /// `review` could ONLY ever be pruned by a trigger belonging to some other
    /// family. Its own saves never asked; everybody else's did.
    @Test("A note-authored run may not remove a review row")
    func aNoteTriggerCannotDeleteAReview() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               proposals: [proposal("2026-08-01T09:00:00Z")],
                               reconcile: .run(Set(ReconcileFamily.allCases)))
        #expect(try count(db, "review") == 1)

        // The athlete saves a note. `AppStores` has no proposals in it —
        // which is the ordinary state, since the stores are read fresh and
        // `proposals.json` is B7's and usually empty.
        var s = AppStores()
        s.notes = []
        s.reconcile = .run(Set(ReconcileFamily.allCases))

        let out = DatabaseWriteThrough.writeThrough(
            db, stores: s, appVersion: "test", trigger: .authored,
            family: .notes, cause: "a session note was saved")
        let r = try #require(report(out))

        #expect(r.reviewsRemoved == 0,
                "a note save has no business deleting a review")
        #expect(try count(db, "review") == 1,
                "the review is the athlete's, and no note trigger may reach it")
        #expect(r.reconciled.permits(.notes))
        #expect(!r.reconciled.permits(.reviews))
    }

    /// The other half, and it is the one that shows the permission is real
    /// rather than merely narrower: the family whose mutation completed still
    /// reconciles, in the same run that refused the others.
    @Test("The family that did change is still reconciled")
    func theOwnFamilyStillReconciles() throws {
        let db = try seeded()
        let out = DatabaseWriteThrough.writeThrough(
            db, stores: afterADelete(), appVersion: "test", trigger: .authored,
            family: .matchDecisions, cause: "a match decision was saved")
        let r = try #require(report(out))

        #expect(r.matchDecisionsRemoved == 1, "its own family is not spared")
        #expect(r.reconciled.permits(.matchDecisions))
        #expect(!r.reconciled.permits(.notes))
        #expect(!r.reconciled.permits(.reviews))
    }

    /// **THE TWO STORES THAT OWN NO FAMILY.** `AthleteStore` and
    /// `AthleteConstants` announce `.authored` so the write-through carries
    /// their rows across, and they prune nothing. Before 414 they were handed
    /// permission to delete from all five families.
    @Test("A change belonging to no family reconciles nothing")
    func noFamilyDeletesNothing() throws {
        let db = try seeded()
        let out = DatabaseWriteThrough.writeThrough(
            db, stores: afterADelete(), appVersion: "test", trigger: .authored,
            family: nil, cause: "an athlete constant was saved")
        let r = try #require(report(out))

        #expect(r.matchDecisionsRemoved == 0)
        #expect(try count(db, "match_decision") == 2, "nothing was theirs to remove")
        #expect(ReconcileFamily.allCases.allSatisfy { !r.reconciled.permits($0) })
        #expect(r.reconciled.line.contains("no reconcilable family"))
    }
}

