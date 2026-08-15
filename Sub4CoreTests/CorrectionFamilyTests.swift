//
//  CorrectionFamilyTests.swift
//  Sub4CoreTests
//
//  The `correction` table has more than one claimant — patch 361,
//  ADR-0003 §12.105.
//
//  WHAT WAS WRONG, AND IT HAS BEEN WRONG SINCE 280
//  -----------------------------------------------
//  The verifier compared the commute decisions against `SELECT COUNT(*) FROM
//  correction`. Those two agreed for exactly one reason: the commute decisions
//  were the only rows the table had ever held. The schema says otherwise —
//  `subjectKind IN ('activity', 'planSession')` was written into the CREATE
//  TABLE, so a second claimant was designed in from the start.
//
//  The first row from that second claimant would have failed a comparison
//  named `corrections` with `expected 1, found 2`, sending the reader to look
//  at the commute decisions, which would have been fine.
//
//  AND WHY QUALIFYING IT IS ONLY HALF
//  ----------------------------------
//  A `WHERE subjectKind = ? AND field = ?` on the commute comparison stops the
//  false failure and buys a silence in its place: every row from every future
//  family, counted by nothing. §12.54.2 — a row that vanishes at zero cannot
//  be told from a row nobody wired in. `unclaimed corrections` is the other
//  half, and `theStrayRowIsCountedBySomething` is the test that says the
//  silence is not there.
//
//  THE ONE THAT MATTERS IS `theCommuteComparisonStillFails`
//  --------------------------------------------------------
//  Narrowing a comparison is one keystroke away from disabling it. A `WHERE`
//  clause that matched nothing would make this check pass on every database in
//  the world, which is §12.69's failure with a SQL flavour. So a row is deleted
//  by hand and the check is required to notice.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("Every correction row belongs to some comparison")
@MainActor
struct CorrectionFamilyTests {

    private let decidedAt = Date(timeIntervalSince1970: 1_785_000_000)

    private func ride(_ id: String) -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 4_000,
                 movingTime: 900, elapsedTime: 960,
                 elevationGain: 12, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 8.0,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T16:02:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func decision(_ id: String) -> CommuteDecision {
        CommuteDecision(activityId: id, isCommute: true, decided: decidedAt)
    }

    /// One activity, one commute decision, imported. The state every test here
    /// starts from, and the state the device is actually in.
    private func seeded() throws -> (Sub4Database, [Activity], [CommuteDecision]) {
        let db = try Sub4Database.inMemory()
        let acts = [ride("19580875358")]
        let commutes = [decision("19580875358")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               commutes: commutes)
        return (db, acts, commutes)
    }

    /// A `planSession` correction, written straight in.
    ///
    /// DELIBERATELY NOT THROUGH A STORE. `PlanMoveStore` is patch 362 and this
    /// suite must not wait for it — the point of fixing the verifier first is
    /// that it can survive a row nothing in this build knows how to make. The
    /// row is shaped exactly as §6.2 of the groundwork specifies it.
    private func stray(_ db: Sub4Database) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO correction
                  (id, accountID, subjectKind, subjectID, field, value,
                   reason, authoredUTC)
                VALUES (?, ?, 'planSession', 's-w03-tue-1', 'date',
                        '2026-07-29', ?, '2026-07-28T16:30:00Z')
                """, arguments: [UUID().uuidString, Sub4Import.accountID,
                                 "moved from the planned day"])
        }
    }

    private func check(_ r: VerificationReport, _ name: String) throws -> VerificationCheck {
        try #require(r.checks.first { $0.name == name })
    }

    // MARK: The patch

    /// **THE DEFECT, AND IT FAILS WITHOUT THE FIX.** One commute decision, one
    /// plan-session correction, and the commute comparison must still read
    /// `expected 1, found 1`. Before 361 it read `expected 1, found 2` and the
    /// migration was refused `verified` for a row that was perfectly correct.
    @Test("A row from another family does not disturb the commute comparison")
    func theCommuteComparisonIgnoresAnotherFamily() throws {
        let (db, acts, commutes) = try seeded()
        try stray(db)

        let r = try SemanticVerifier.verify(db, activities: acts,
                                            commutes: commutes)
        let c = try check(r, ComparedCorrections.commute.check)
        #expect(c.expected == "1")
        #expect(c.found == "1", "the whole table was counted before 361")
        #expect(c.passed)
    }

    /// The other half. A row belonging to no declared family is not tolerated
    /// quietly — it is the report's own failure, naming the kind and field.
    @Test("A row nobody claims is counted by the check that claims nothing")
    func theStrayRowIsCountedBySomething() throws {
        let (db, acts, commutes) = try seeded()
        try stray(db)

        let r = try SemanticVerifier.verify(db, activities: acts,
                                            commutes: commutes)
        let c = try check(r, "unclaimed corrections")
        #expect(c.expected == "0")
        #expect(c.found == "1")
        #expect(!c.passed, "a family arrived without a verifier")
        #expect(r.passed == false, "and the report says so")
        // THE POINTER, ON SCREEN AND NOT IN THE PASTE. `subjectKind` and
        // `field` are column vocabulary; `subjectID` is the athlete's own
        // identifier and appears in neither.
        let detail = try #require(c.detail)
        #expect(detail.contains("planSession"))
        #expect(detail.contains("date"))
        #expect(!detail.contains("s-w03-tue-1"), "no subject id, ever")
    }

    @Test("With only the family it knows, the report agrees")
    func aDatabaseOfOnlyCommutesIsClean() throws {
        let (db, acts, commutes) = try seeded()

        let r = try SemanticVerifier.verify(db, activities: acts,
                                            commutes: commutes)
        let c = try check(r, "unclaimed corrections")
        #expect(c.found == "0")
        #expect(c.passed)
    }

    /// **§12.69, AND THE REASON THIS TEST EXISTS AT ALL.** A `WHERE` clause
    /// that matched nothing would make the commute comparison pass on every
    /// database ever built, and every other test in this file would still be
    /// green. So the row goes, by hand, and the check must notice.
    @Test("The commute comparison can still fail")
    func theCommuteComparisonStillFails() throws {
        let (db, acts, commutes) = try seeded()
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM correction")
        }

        let r = try SemanticVerifier.verify(db, activities: acts,
                                            commutes: commutes)
        let c = try check(r, ComparedCorrections.commute.check)
        #expect(c.expected == "1")
        #expect(c.found == "0")
        #expect(!c.passed)
    }

    // MARK: The list, and what joins to it

    /// **THE KEY COMES FROM THE WRITER, CHECKED AGAINST WHAT THE WRITER
    /// WROTE.** Comparing `ComparedCorrections.commute.field` to
    /// `Sub4Import.commuteField` would compare a constant to itself. This reads
    /// the row the importer actually produced, so a family that named a pair
    /// nothing writes would fail here rather than by counting zero forever.
    @Test("The family names the pair the importer really writes")
    func theFamilyMatchesTheRowTheImporterWrote() throws {
        let (db, _, _) = try seeded()
        let fetched = try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT subjectKind, field FROM correction")
        }
        let row = try #require(fetched)
        #expect(row["subjectKind"] as String? == ComparedCorrections.commute.subjectKind)
        #expect(row["field"] as String? == ComparedCorrections.commute.field)
        // And the constants are the importer's own, not a second copy. §12.43.
        #expect(ComparedCorrections.commute.subjectKind == Sub4Import.commuteSubject)
        #expect(ComparedCorrections.commute.field == Sub4Import.commuteField)
    }

    /// The tripwire, in the shape `unmatchedHydratedEntries` established. The
    /// list joins to the checks BY NAME, so a rename finished on one side only
    /// leaves a family whose comparison does not exist — and `unclaimed
    /// corrections` would then count rows the report claims to compare.
    @Test("Every declared family names a comparison the verifier makes")
    func everyFamilyNamesARealComparison() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])
        let names = Set(r.checks.map(\.name))

        #expect(!ComparedCorrections.all.isEmpty,
                "an empty list would make the unclaimed check count everything")
        for f in ComparedCorrections.all {
            #expect(names.contains(f.check),
                    "a declared family names no comparison — a rename nobody finished")
        }
        #expect(names.contains("unclaimed corrections"))
    }

    /// `unclaimed corrections` expects zero because this file says so, not
    /// because a store said so — nothing the database feeds is consulted. So
    /// it is evidence, and it must land on the evidence side of §12.99's split.
    @Test("The unclaimed comparison counts as evidence")
    func theUnclaimedComparisonIsIndependent() throws {
        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])

        #expect(HydratedStores.entry(for: "unclaimed corrections") == nil)
        #expect(r.independentChecks.contains { $0.name == "unclaimed corrections" })
    }

    /// **THE RENAME, FINISHED ON BOTH SIDES.** 358 left a comment on
    /// `HydratedStores` saying `corrections` is the commute decisions and the
    /// name does not say so — and warning that a helpful rename on one side is
    /// exactly what `unmatchedHydratedEntries` exists to catch. This is the
    /// patch that renames it, so this is the test that both lists moved.
    @Test("The rename moved the declared list too")
    func theRenameMovedBothLists() throws {
        #expect(HydratedStores.entry(for: "commute corrections")?.store
                == "CommuteStore.decisions")
        #expect(HydratedStores.entry(for: "commute corrections")?.slice == "B2")
        #expect(HydratedStores.entry(for: "corrections") == nil,
                "the old name is gone from the declared list")

        let db = try Sub4Database.inMemory()
        let r = try SemanticVerifier.verify(db, activities: [])
        #expect(r.unmatchedHydratedEntries.isEmpty)
        #expect(r.selfReferentialChecks.count == HydratedStores.all.count)
    }
}
