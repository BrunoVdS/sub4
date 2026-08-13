//
//  PlanVersionCensusTests.swift
//  Sub4CoreTests
//
//  The census, and the prune it licenses — patch 352, ADR-0003 §12.97.
//
//  WHAT HAD TO BE BUILT TO TEST THIS HONESTLY
//  ------------------------------------------
//  The whole file exists to detect a version that duplicates another under a
//  DIFFERENT `contentHash`, and the importer will not produce one on demand:
//  it hashes its input and skips the write when the hash is already stored, so
//  importing the same plan twice gives one version. §12.93.3's duplicate came
//  from the store being hydrated in a different array order, which is a state
//  that no longer exists after 347.
//
//  So the twin is built in SQL — every content row copied under fresh row ids
//  and a different hash — which is exactly what the device holds and exactly
//  what a fingerprint over row identities would fail to recognise. `copyOfActive`
//  below is the fixture, and it is the reason these tests can fail.
//
//  THE PLAN IS THE REAL ONE. `PlanStore.decodeBundle()` rather than a
//  hand-built fixture: 260 sessions, 81 breakdowns and 634 blocks through the
//  real importer is what the census reads on the phone, and a five-session
//  fixture would not have exercised the week-stat re-keying at all.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("Every stored plan version, counted")
@MainActor
struct PlanVersionCensusTests {

    // MARK: Fixtures

    private func seeded() throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: PlanStore.decodeBundle().plan)
        return db
    }

    /// Every content row of the active version, copied under fresh row ids and
    /// a hash nothing else holds. Not activated: the partial unique index
    /// `plan_version_one_active` permits exactly one active version per plan.
    private func copyOfActive(_ db: Sub4Database,
                              as newID: String = "twin",
                              hash: String = "a-hash-nothing-else-holds") throws {
        try db.queue.write { d in
            guard let source = try String.fetchOne(d, sql: """
                SELECT id FROM plan_version WHERE activatedUTC IS NOT NULL
                """) else {
                throw NSError(domain: "test", code: 1)
            }
            let p = newID + "-"

            try d.execute(sql: """
                INSERT INTO plan_version
                  (id, planID, contentHash, sourceLabel, importedUTC, activatedUTC)
                SELECT ?, planID, ?, sourceLabel, importedUTC, NULL
                  FROM plan_version WHERE id = ?
                """, arguments: [newID, hash, source])

            try d.execute(sql: """
                INSERT INTO plan_week
                  (id, planVersionID, uid, weekNo, label, startDate,
                   dateRange, tag, badge, kind, logged)
                SELECT ? || id, ?, uid, weekNo, label, startDate,
                       dateRange, tag, badge, kind, logged
                  FROM plan_week WHERE planVersionID = ?
                """, arguments: [p, newID, source])

            try d.execute(sql: """
                INSERT INTO plan_week_stat (id, planWeekID, key, value)
                SELECT ? || id, ? || planWeekID, key, value
                  FROM plan_week_stat
                 WHERE planWeekID IN
                       (SELECT id FROM plan_week WHERE planVersionID = ?)
                """, arguments: [p, p, source])

            try d.execute(sql: """
                INSERT INTO plan_session
                  (id, planVersionID, planWeekID, uid, day, date, discipline,
                   intensity, title, detail, fuel, prep, seq)
                SELECT ? || id, ?, ? || planWeekID, uid, day, date, discipline,
                       intensity, title, detail, fuel, prep, seq
                  FROM plan_session WHERE planVersionID = ?
                """, arguments: [p, newID, p, source])

            try d.execute(sql: """
                INSERT INTO plan_session_detail
                  (id, planSessionID, kind, total, tag, focus)
                SELECT ? || d.id, ? || d.planSessionID, d.kind, d.total,
                       d.tag, d.focus
                  FROM plan_session_detail d
                  JOIN plan_session s ON s.id = d.planSessionID
                 WHERE s.planVersionID = ?
                """, arguments: [p, p, source])

            try d.execute(sql: """
                INSERT INTO plan_session_block
                  (id, planSessionDetailID, ordinal, duration, title,
                   cue, videoURL)
                SELECT ? || b.id, ? || b.planSessionDetailID, b.ordinal,
                       b.duration, b.title, b.cue, b.videoURL
                  FROM plan_session_block b
                  JOIN plan_session_detail d ON d.id = b.planSessionDetailID
                  JOIN plan_session s ON s.id = d.planSessionID
                 WHERE s.planVersionID = ?
                """, arguments: [p, p, source])

            try d.execute(sql: """
                INSERT INTO plan_exercise
                  (id, planVersionID, uid, name, videoURL, cue, uses)
                SELECT ? || id, ?, uid, name, videoURL, cue, uses
                  FROM plan_exercise WHERE planVersionID = ?
                """, arguments: [p, newID, source])
        }
    }

    private func count(_ db: Sub4Database, _ table: String) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // MARK: The census agrees with the reader

    /// THE CONTROL FOR EVERY NUMBER BELOW. This file writes its own SELECTs
    /// against tables `PlanRepository` also reads. If the two disagree about
    /// the active version, the census is wrong and its verdict is worthless —
    /// so the disagreement is a test rather than a line nobody reads.
    @Test("The census counts the active version the way the reader does")
    func theCensusAgreesWithTheReader() throws {
        let db = try seeded()
        let load = PlanRepository.load(db)
        guard case .loaded(_, let weeks, let sessions, _, _, _) = load else {
            Issue.record("the seeded database did not load")
            return
        }
        let c = PlanVersionCensus.read(db, readerSessionCount: sessions.count)

        #expect(c.readFailure == nil)
        #expect(c.versions.count == 1)
        #expect(c.activeCount == 1)
        #expect(c.agreesWithReader == true)
        #expect(c.agreementLine == "yes")
        #expect(c.activeVersion?.sessions == sessions.count)
        #expect(c.activeVersion?.weeks == weeks.count)
        #expect(c.activeVersion?.sessionUIDs.count == sessions.count,
                "every session uid is unique within a version")
    }

    /// §12.15. A census that could not read must not print like one that read
    /// cleanly and found nothing.
    @Test("A census with no answer says so rather than printing zeros")
    func aFailedReadIsNotAnEmptyDatabase() {
        var c = PlanVersionCensus()
        c.readFailure = "the queue was closed"
        #expect(c.versions.isEmpty)
        #expect(c.line.contains("could not be read"))
        #expect(c.diagnosticLines.first?.contains("could not be read") == true)
        #expect(c.diagnosticLines.contains(where: { $0.contains("not the same as zero") }))
    }

    /// §12.54.2 — the answer "no twins" has to be printed, or it cannot be
    /// told from a section nobody wired in.
    @Test("The verdict is printed when there is nothing to report")
    func theQuietAnswerIsStillPrinted() throws {
        let db = try seeded()
        let c = PlanVersionCensus.read(db, readerSessionCount: nil)
        #expect(c.twinGroups.isEmpty)
        #expect(c.removableCount == 0)
        #expect(c.diagnosticLines.contains(where: {
            $0.contains("identical training: none")
        }))
        #expect(c.diagnosticLines.contains(where: { $0.contains("fingerprint covers:") }),
                "what the verdict is about is stated, not assumed")
    }

    // MARK: The fingerprint

    /// **THE ONE THE FILE EXISTS FOR.** Same training, fresh row ids, a
    /// different `contentHash` — which is the device's state, and the state
    /// `contentHash` alone calls two different plans.
    @Test("A copy with fresh row ids fingerprints the same and hashes differently")
    func aCopyFingerprintsTheSame() throws {
        let db = try seeded()
        try copyOfActive(db)

        let c = PlanVersionCensus.read(db, readerSessionCount: nil)
        #expect(c.versions.count == 2)
        #expect(c.activeCount == 1, "the copy is not activated")

        let hashes = Set(c.versions.map { $0.contentHash })
        #expect(hashes.count == 2, "the stored hashes disagree")

        let prints = Set(c.versions.map { $0.fingerprint })
        #expect(prints.count == 1, "and the training is identical")

        #expect(c.twinGroups.count == 1)
        #expect(c.twinGroups.first?.count == 2)
        #expect(c.removableCount == 1)
        #expect(c.keeper(of: c.twinGroups[0])?.isActive == true,
                "the active version is the one kept")
        // The uid superset has not grown: a twin adds rows, not sessions.
        #expect(c.allSessionUIDs.count == c.activeVersion?.sessionUIDs.count)
        #expect(c.uidsHeldOnlyBy(c.versions[1]).isEmpty)
    }

    /// The negative control. One `detail` string differs and the two are no
    /// longer twins — which is what stops the prune deleting a revision.
    @Test("One changed detail is enough to stop them being twins")
    func oneChangedDetailBreaksIt() throws {
        let db = try seeded()
        try copyOfActive(db)
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE plan_session SET detail = 'something else entirely'
                 WHERE planVersionID = 'twin'
                   AND id = (SELECT id FROM plan_session
                              WHERE planVersionID = 'twin' ORDER BY uid LIMIT 1)
                """)
        }

        let c = PlanVersionCensus.read(db, readerSessionCount: nil)
        #expect(c.versions.count == 2)
        #expect(Set(c.versions.map { $0.fingerprint }).count == 2)
        #expect(c.twinGroups.isEmpty)
        #expect(c.removableCount == 0)
    }

    /// A block three levels down, and the fingerprint still sees it. This is
    /// the join the census re-keys by session uid rather than by row id, so a
    /// mistake there would show as a twin that is not one.
    @Test("A changed block breaks it too")
    func oneChangedBlockBreaksIt() throws {
        let db = try seeded()
        try copyOfActive(db)
        try db.queue.write { d in
            try d.execute(sql: """
                UPDATE plan_session_block SET cue = 'a different cue'
                 WHERE id = (SELECT b.id FROM plan_session_block b
                               JOIN plan_session_detail x ON x.id = b.planSessionDetailID
                               JOIN plan_session s ON s.id = x.planSessionID
                              WHERE s.planVersionID = 'twin'
                              ORDER BY b.id LIMIT 1)
                """)
        }
        let c = PlanVersionCensus.read(db, readerSessionCount: nil)
        #expect(c.twinGroups.isEmpty)
    }

    // MARK: The prune

    @Test("The prune removes the twin, keeps the active one, and says which")
    func thePruneRemovesTheTwin() throws {
        let db = try seeded()
        try copyOfActive(db)

        let before = try count(db, "plan_session")
        let outcome = PlanVersionPrune.run(db)

        #expect(outcome.didRun)
        #expect(outcome.refusal == nil)
        #expect(outcome.deleted.count == 1)
        #expect(outcome.kept.count == 1)
        #expect(outcome.deleted.first == String("twin".prefix(8)))

        let versionsLeft = try count(db, "plan_version")
        let sessionsLeft = try count(db, "plan_session")
        let blocksLeft = try count(db, "plan_session_block")
        #expect(versionsLeft == 1)
        #expect(sessionsLeft == before / 2,
                "the cascade took the copied sessions with it")
        #expect(blocksLeft > 0, "and left the survivor's")

        // The plan still reads. This is the assertion that would fail if the
        // delete had taken the active version's rows through a shared row id.
        let load = PlanRepository.load(db)
        guard case .loaded(_, let weeks, let sessions, _, _, _) = load else {
            Issue.record("the plan no longer loads after a prune")
            return
        }
        #expect(sessions.count == before / 2)
        #expect(weeks.count > 0)

        // Idempotent: a second press finds nothing and refuses.
        let again = PlanVersionPrune.run(db)
        #expect(again.deleted.isEmpty)
        #expect(again.refusal != nil)
    }

    @Test("With nothing duplicated the prune deletes nothing and says why")
    func thePruneRefusesWhenThereIsNoTwin() throws {
        let db = try seeded()
        let before = try count(db, "plan_session")
        let outcome = PlanVersionPrune.run(db)

        #expect(outcome.didRun)
        #expect(outcome.deleted.isEmpty)
        #expect(outcome.kept.isEmpty)
        #expect(outcome.refusal?.contains("identical") == true)
        let after = try count(db, "plan_session")
        #expect(after == before)
        #expect(outcome.line.contains("nothing removed"))
    }

    /// "Not run" and "ran and refused" are different states, and a screen that
    /// printed the same thing for both would be §12.15 all over again.
    @Test("Never run is not the same as ran and found nothing")
    func neverRunIsItsOwnState() {
        #expect(PlanVersionPrune().line == "not run")
        #expect(PlanVersionPrune().didRun == false)
    }

    /// THE UNREACHABLE GUARD, EXERCISED. The rule the prune follows makes this
    /// impossible from a real database — a twin holds the same sessions by
    /// definition — so it is driven directly, on values that would lose a uid.
    /// §12.69: a guard that cannot fail has not been tested.
    @Test("The lost-uid refusal fires on values that would lose one")
    func theLostUIDRefusalFiresOnValuesThatWouldLoseOne() {
        func v(_ id: String, _ uids: [String]) -> PlanVersionCensus.Version {
            PlanVersionCensus.Version(
                id: id, planID: "p", sourceLabel: "bundled",
                importedUTC: "2026-08-01T00:00:00Z", contentHash: "h-" + id,
                isActive: id == "keep", weeks: 1, weekStats: 1,
                sessions: uids.count, details: 0, blocks: 0, exercises: 0,
                fingerprint: "same", sessionUIDs: Set(uids))
        }
        var census = PlanVersionCensus()
        census.versions = [v("keep", ["a", "b"]), v("gone", ["a", "b", "c"])]

        let refusal = PlanVersionPrune.uidsLostRefusal(
            census: census, doomed: [census.versions[1]])
        #expect(refusal != nil)
        #expect(refusal?.contains("c") == true)

        #expect(PlanVersionPrune.uidsLostRefusal(
            census: census, doomed: [census.versions[0]]) == nil,
            "deleting the subset loses nothing")
    }

    // MARK: What a delete does to what points at it

    /// §12.7 refuses to make `proposal_change.planSessionUID` a foreign key.
    /// The census is what makes that survivable: it reports which uids only
    /// one version holds and which of those are referenced, so a delete is
    /// decided on rather than discovered.
    @Test("References into the removed version are counted before it goes")
    func referencesAreCountedBeforeTheDelete() throws {
        let db = try seeded()
        try copyOfActive(db)
        let c = PlanVersionCensus.read(db, readerSessionCount: nil)

        #expect(c.referencedUIDs.isEmpty, "nothing is stored in this database")
        #expect(c.danglingReferences.isEmpty)
        for version in c.versions {
            #expect(c.uidsHeldOnlyBy(version).isEmpty,
                    "a twin holds nothing uniquely, which is why it can go")
        }
    }
}
