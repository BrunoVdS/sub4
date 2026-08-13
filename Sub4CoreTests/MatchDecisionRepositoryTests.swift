//
//  MatchDecisionRepositoryTests.swift
//  Sub4CoreTests
//
//  The table that had no reader — patch 355, D7 slice B2, ADR-0003 §12.100.
//
//  WHY THE LEFT JOIN IS THE POINT OF THIS FILE
//  -------------------------------------------
//  `match_decision.activityID` is nullable, and nil is not an absence: it is
//  the athlete saying *nothing satisfied this session*. The old
//  `[String: String]` in UserDefaults had to spell that `""` and 272 gave it a
//  real nil. An INNER join on `activity_alias` would drop every one of those
//  rows, the comparison would report them as `decisionsOnlyInApp`, and that
//  reads as missing data rather than as a reader that cannot see half its
//  table.
//
//  `theExplicitlyNothingDecisionSurvivesTheRead` is the test that would catch
//  it, and it is the reason the round trip below writes one.
//
//  WHAT IS NOT TESTED HERE. The comparison's plumbing into `Report` is driven
//  directly on values — `compareDecisions` is `inout` on a struct and needs no
//  database — so the two halves are exercised separately: the reader against
//  real rows, the comparison against hand-built ones.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("match_decision has a reader")
@MainActor
struct MatchDecisionRepositoryTests {

    // MARK: Fixtures

    private func decision(_ uid: String,
                          activity: String?,
                          decided: String = "2026-08-01T09:00:00Z") -> MatchDecision {
        MatchDecision(sessionUid: uid,
                      activityId: activity,
                      decided: ISO8601DateFormatter().date(from: decided) ?? Date(),
                      dateIsKnown: true)
    }

    /// The importer is the writer, so the round trip goes through it rather
    /// than through hand-written SQL — the same argument
    /// `AuthoredRepositoryTests` makes about `user_note`. A reader tested
    /// against rows a test invented is a reader tested against a schema nobody
    /// writes.
    private func seeded(_ decisions: [MatchDecision],
                        activities: [Activity] = []) throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db,
                               activities: activities,
                               shoes: [],
                               matchDecisions: decisions)
        return db
    }

    // MARK: The read

    /// **THE ONE THE LEFT JOIN EXISTS FOR.** A decision naming no activity is a
    /// decision. An inner join would return nothing here.
    @Test("An explicitly-nothing decision survives the read")
    func theExplicitlyNothingDecisionSurvivesTheRead() throws {
        let db = try seeded([decision("wk-03-fri-easy", activity: nil)])

        let load = MatchDecisionRepository.load(db)
        #expect(load.isTrustworthy)
        #expect(load.skipped == 0)
        let out = try #require(load.decisions)
        #expect(out.count == 1)
        #expect(out.first?.sessionUid == "wk-03-fri-easy")
        #expect(out.first?.activityId == nil,
                "nil is what the athlete said, not a row the reader lost")
    }

    @Test("A read of an empty table is a clean read of nothing")
    func anEmptyTableReadsCleanly() throws {
        let db = try Sub4Database.inMemory()
        let load = MatchDecisionRepository.load(db)
        #expect(load.isTrustworthy)
        #expect(load.decisions?.isEmpty == true)
        #expect(load.skipped == 0)
        #expect(load.line.contains("0 match decisions"))
    }

    /// §12.15. A failed read must not be reachable through the happy path.
    @Test("A load that did not happen refuses to hand back an empty array")
    func aFailedLoadIsNotAnEmptyOne() {
        for load: MatchDecisionLoad in [.unavailable, .failed("the file is locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.decisions == nil,
                    "nil, so a caller cannot treat a failure as no decisions")
            #expect(load.skipped == 0)
            #expect(!load.line.isEmpty)
        }
    }

    // MARK: The comparison

    @Test("Two sides that agree compare and report nothing")
    func agreementIsQuiet() {
        var r = AuthoredRoundTrip.Report()
        let d = [decision("a", activity: nil), decision("b", activity: "99")]
        AuthoredRoundTrip.compareDecisions(
            store: d, database: .loaded(decisions: d, skipped: 0), into: &r)

        #expect(r.decisionsWereRead)
        #expect(r.decisionsInApp == 2)
        #expect(r.decisionsInDatabase == 2)
        #expect(r.decisionsCompared == 2)
        #expect(r.decisionFieldsCompared == 4, "two fields per decision")
        #expect(r.decisionDifferences.isEmpty)
        #expect(r.unexplained == 0)
        #expect(r.totalCompared == 2, "and they count toward the verdict")
    }

    /// nil and a value are different answers, and this is the field where it
    /// matters most: one says the athlete decided nothing satisfied the
    /// session, the other names what did.
    @Test("A decision that changed its activity is a difference")
    func aChangedActivityIsADifference() {
        var r = AuthoredRoundTrip.Report()
        AuthoredRoundTrip.compareDecisions(
            store: [decision("a", activity: "99")],
            database: .loaded(decisions: [decision("a", activity: nil)],
                              skipped: 0),
            into: &r)

        #expect(r.decisionsCompared == 1)
        #expect(r.decisionDifferences == ["a · activityId"])
        #expect(r.unexplained == 1)
    }

    @Test("A decision on one side only is named, by session uid")
    func aOneSidedDecisionIsNamed() {
        var r = AuthoredRoundTrip.Report()
        AuthoredRoundTrip.compareDecisions(
            store: [decision("a", activity: nil)],
            database: .loaded(decisions: [decision("b", activity: nil)],
                              skipped: 0),
            into: &r)

        #expect(r.decisionsOnlyInApp == ["a"])
        #expect(r.decisionsOnlyInDatabase == ["b"])
        #expect(r.decisionsCompared == 0)
        #expect(r.unexplained == 2)
    }

    /// `dateIsKnown` has no column, and the comparison must not walk it or
    /// every row would differ. `approvedForDecisions` is the record of that.
    @Test("The flag with no column is approved and not compared")
    func theMissingColumnIsApprovedAndNotWalked() {
        var r = AuthoredRoundTrip.Report()
        var stored = decision("a", activity: nil)
        stored.dateIsKnown = false
        AuthoredRoundTrip.compareDecisions(
            store: [stored],
            database: .loaded(decisions: [decision("a", activity: nil)],
                              skipped: 0),
            into: &r)

        #expect(r.decisionsCompared == 1)
        #expect(r.decisionDifferences.isEmpty,
                "the flag is not walked, so a disagreement about it is not one")
        #expect(AuthoredRoundTrip.approvedForDecisions.count == 1)
        #expect(AuthoredRoundTrip.approvedForDecisions.first?.field
                == "match_decision.dateIsKnown")
        #expect(AuthoredRoundTrip.approved.count == 2,
                "and the notes' own list did not grow — two tables, two lists")
    }

    // MARK: Never asked

    /// §12.15, and the reason `decisionsWereRead` exists. A report nobody gave
    /// the decisions to prints exactly the zeros of one where both sides were
    /// empty.
    @Test("Never asked and nothing to compare do not print the same")
    func neverAskedIsItsOwnState() {
        let untouched = AuthoredRoundTrip.Report()
        #expect(!untouched.decisionsWereRead)
        #expect(untouched.diagnosticLines.contains(where: {
            $0.contains("match decisions were read: NO")
        }))

        var asked = AuthoredRoundTrip.Report()
        AuthoredRoundTrip.compareDecisions(
            store: [], database: .loaded(decisions: [], skipped: 0), into: &asked)
        #expect(asked.decisionsWereRead)
        #expect(asked.diagnosticLines.contains(where: {
            $0.contains("match decisions were read: yes")
        }))
        #expect(asked.decisionsCompared == 0,
                "zero compared to zero is a real state and still not a check")
    }

    /// A read that failed leaves the database side at zero and says so through
    /// `isTrustworthy` — the report must not read that as agreement.
    @Test("A failed read is not two empty sides")
    func aFailedReadIsNotAgreement() {
        var r = AuthoredRoundTrip.Report()
        AuthoredRoundTrip.compareDecisions(
            store: [decision("a", activity: nil)],
            database: .failed("the queue was closed"),
            into: &r)

        #expect(r.decisionsWereRead)
        #expect(r.decisionsInApp == 1)
        #expect(r.decisionsInDatabase == 0)
        #expect(r.decisionsCompared == 0)
        #expect(r.decisionsOnlyInApp.isEmpty,
                "the reader failed, so nothing is missing from anything")
    }
}
