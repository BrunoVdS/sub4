//
//  WorkQueueTests.swift
//  Sub4CoreTests
//
//  What the app has stopped asking for — patch 276, ADR-0003 §12.23. D5 slice 2.
//
//  TWO OF THESE MATTER MORE THAN THE REST.
//
//  `theFrozenStatesStillMatchTheSchema` is the coupling test §12.1 asks for on
//  every vocabulary inside a migration. `work_queue`'s CHECK hard-codes its
//  four states rather than reading a constant, and the migration is history —
//  so the assertion can only run one way: the enum must still say what the
//  schema was born saying.
//
//  `aForgottenVerdictIsRemoved` is the pruning, which §12.21 deliberately did
//  NOT do for notes. It is safe here because the source is a preference array
//  with no decode step and the whole table is rebuildable by re-syncing —
//  neither of which is true of a note — and a test is the only place that
//  distinction is enforced rather than merely written down.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct WorkQueueTests {

    private func item(_ kind: WorkKind,
                      _ subject: String,
                      _ state: WorkState,
                      lastError: String? = nil) -> WorkItem {
        WorkItem(kind: kind, subjectID: subject, state: state,
                 attempts: 1, lastError: lastError)
    }

    private func rows(_ db: Sub4Database) throws -> [Row] {
        try db.queue.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM work_queue ORDER BY subjectID")
        }
    }

    private func count(_ db: Sub4Database) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM work_queue") ?? 0
        }
    }

    // MARK: The frozen vocabulary

    /// The migration hard-codes `state IN ('pending', 'running', 'failed',
    /// 'done')` and can never be edited. This is the coupling.
    @Test("The frozen states still match the schema")
    func theFrozenStatesStillMatchTheSchema() {
        // ONE INTERPOLATED LITERAL, NOT TWO LITERALS ADDED TOGETHER.
        // `#expect`'s message is a `Comment?`, which is
        // `ExpressibleByStringInterpolation` — so this converts and `"a" + "b"`
        // does not, because a concatenation produces a `String` and a `String`
        // is not a literal. Worth a comment: the two read identically.
        let states = WorkState.allCases.map(\.rawValue)
        #expect(Set(states) == Set(["pending", "running", "failed", "done"]),
                "WorkState drifted from what migration 2 froze: \(states)")
    }

    /// A state the CHECK does not know must be refused by the database rather
    /// than stored — proving the constraint is live, not decorative.
    @Test("A state the schema never froze is refused")
    func anUnknownStateIsRefused() throws {
        let db = try Sub4Database.inMemory()
        var threw = false
        do {
            try db.queue.write { d in
                try d.execute(sql: """
                    INSERT INTO work_queue
                      (id, kind, subjectID, state, attempts, createdUTC, updatedUTC)
                    VALUES ('x', 'detail', '1', 'queued', 0, 'now', 'now')
                    """)
            }
        } catch {
            threw = true
        }
        #expect(threw, "the CHECK on work_queue.state did not fire")
    }

    // MARK: The mapping

    @Test("A refused recording is failed; an empty one is done")
    func theTwoVerdictsAreDistinguishable() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(
            into: db, activities: [], shoes: [],
            workItems: [item(.detail, "111", .failed,
                             lastError: "the source refused this recording"),
                        item(.stream, "222", .done)])

        #expect(report.workItemsSeen == 2)
        #expect(report.workItemsImported == 2)

        let all = try rows(db)
        #expect(all.count == 2)
        #expect(all[0]["kind"] as String? == "detail")
        #expect(all[0]["state"] as String? == "failed")
        #expect(all[1]["kind"] as String? == "stream")
        // NOT `failed`. The fetch succeeded and the answer was "nothing here",
        // which is 23 of this athlete's activities.
        #expect(all[1]["state"] as String? == "done")
        #expect(all[1]["lastError"] as String? == nil)
    }

    @Test("attempts is one, because one is the minimum known to be true")
    func attemptsIsAFloor() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               workItems: [item(.detail, "111", .failed)])
        let all = try rows(db)
        #expect(all[0]["attempts"] as Int? == 1)
        // Nothing is scheduled, because nothing is ever retried.
        #expect(all[0]["notBeforeUTC"] as String? == nil)
    }

    @Test("Both timestamps are set, and a refresh does not remake the row")
    func createdIsNotRewritten() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               workItems: [item(.detail, "111", .failed)])
        let first = try rows(db)
        let created = first[0]["createdUTC"] as String?
        #expect(created != nil)

        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               workItems: [item(.detail, "111", .failed)])
        let second = try rows(db)
        // `createdUTC` says when the ROW was made. A refresh does not make it
        // again.
        #expect(second[0]["createdUTC"] as String? == created)
    }

    // MARK: Idempotency and pruning

    @Test("Importing twice keeps one row per subject")
    func importingTwiceKeepsOneRow() throws {
        let db = try Sub4Database.inMemory()
        let items = [item(.detail, "111", .failed), item(.stream, "222", .done)]
        let first = try Sub4Import.run(into: db, activities: [], shoes: [],
                                       workItems: items)
        let second = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        workItems: items)

        #expect(first.workItemsImported == 2)
        #expect(second.workItemsImported == 0)
        #expect(second.workItemsUpdated == 2)
        let n = try count(db)
        #expect(n == 2)
    }

    /// THE ONE §12.21 REFUSED TO DO FOR NOTES. See the header.
    @Test("A verdict the store has forgotten is removed")
    func aForgottenVerdictIsRemoved() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               workItems: [item(.detail, "111", .failed),
                                           item(.stream, "222", .done)])
        let before = try count(db)
        #expect(before == 2)

        // `resetCache` cleared the detail verdict; the stream one stands.
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        workItems: [item(.stream, "222", .done)])
        #expect(report.workItemsRemoved == 1)
        let after = try rows(db)
        #expect(after.count == 1)
        #expect(after[0]["subjectID"] as String? == "222")
    }

    @Test("An empty store empties this importer's kinds")
    func anEmptyStoreEmptiesTheTable() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               workItems: [item(.detail, "111", .failed)])

        // Deliberate and asserted: unlike notes, this table is rebuildable by
        // re-syncing and its source is a preference array with no decode step,
        // so "empty" cannot mean "unreadable" here.
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        workItems: [])
        #expect(report.workItemsRemoved == 1)
        let n = try count(db)
        #expect(n == 0)
    }

    /// The prune claims only rows it could have written. A row belonging to
    /// nothing — no subject — is somebody else's, and stays.
    @Test("A row with no subject is not claimed by the prune")
    func aSubjectlessRowSurvives() throws {
        let db = try Sub4Database.inMemory()
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO work_queue
                  (id, kind, subjectID, state, attempts, createdUTC, updatedUTC)
                VALUES ('sweep', 'detail', NULL, 'pending', 0, 'now', 'now')
                """)
        }

        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        workItems: [])
        #expect(report.workItemsRemoved == 0)
        let n = try count(db)
        #expect(n == 1)
    }

    // MARK: The verifier

    @Test("A faithful queue verifies")
    func aFaithfulQueueVerifies() throws {
        let db = try Sub4Database.inMemory()
        let items = [item(.detail, "111", .failed), item(.stream, "222", .done)]
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], workItems: items)

        let report = try SemanticVerifier.verify(db, activities: [], workItems: items)
        #expect(report.passed, "a faithful queue failed verification")
        let tables = Set(report.checks.map(\.table))
        #expect(tables.contains("work_queue"))
    }

    @Test("Deleting a verdict is caught, and names its table")
    func deletingAVerdictIsCaught() throws {
        let db = try Sub4Database.inMemory()
        let items = [item(.detail, "111", .failed), item(.stream, "222", .done)]
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], workItems: items)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM work_queue WHERE subjectID = '111'")
        }

        let report = try SemanticVerifier.verify(db, activities: [], workItems: items)
        #expect(!report.passed)
        #expect(report.failures.contains { $0.table == "work_queue" })
    }
}
