//
//  SessionTallyTests.swift
//  Sub4CoreTests
//
//  "Done of total", once — patch 328, ADR-0003 §12.72.
//
//  WHAT THESE ARE FOR
//  ------------------
//  The rule these pin has been half-applied since patch 98: SEVEN copies, six
//  of them counting the plan's 30 optional Zwift rides and one not. Nothing
//  caught it because each copy was internally consistent and no test had ever
//  asked an optional session what it thought it was.
//
//  328 found five of the seven. The two it missed — `MatchParity` and
//  `Review` — were caught on the device within the hour, by a prediction that
//  named a number. §12.72.7.
//
//  So the tests that matter here are not the arithmetic ones:
//
//    `anOptionalSessionIsNotInTheDenominator`
//        — the assertion that did not exist, and whose absence let two tabs
//          disagree for 230 patches.
//
//    `bothEntryPointsApplyTheSameRule`
//        — there are two shapes (matches, and sessions + a completion test)
//          because `Matcher.adherence` resolves per session and 321 declined
//          to change that. Two shapes is how five copies started. This holds
//          them to one answer.
//
//    `theExclusionsAreCountedNotJustApplied`
//        — §12.54.2. An exclusion nobody can see cannot be told from an
//          exclusion that stopped being applied.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct SessionTallyTests {

    // MARK: Fixtures

    private func session(_ uid: String,
                         discipline: Discipline = .run,
                         title: String = "Easy run",
                         detail: String = "8 km easy") -> Session {
        Session(uid: uid, weekUid: "w1", day: "Mon", date: "2026-07-27",
                discipline: discipline, intensity: .easy,
                title: title, detail: detail, fuel: nil, prep: nil, seq: 0,
                swimDetail: nil, strengthDetail: nil)
    }

    private func rest(_ uid: String) -> Session {
        session(uid, discipline: .rest, title: "Rest", detail: "Nothing today")
    }

    /// How the plan HTML actually marks the 28 Zwift rides — `PlanStore
    /// .isOptional` is a regex for "opt." or "optional" over title + detail.
    private func optional(_ uid: String, word: String = "Optional") -> Session {
        session(uid, discipline: .bike,
                title: "\(word) Zwift ride", detail: "45 min Z2")
    }

    /// `Match.isDone` is `activity != nil`, so a nil activity is a session that
    /// was not done. Every match-shaped test below uses nil, which keeps these
    /// tests free of an `Activity` fixture they would otherwise have to keep in
    /// step with the real one.
    private func match(_ s: Session) -> Match {
        Match(session: s, activity: nil, auto: true)
    }

    // MARK: The rule

    /// THE ASSERTION THAT DID NOT EXIST.
    @Test("An optional session is not in the denominator")
    func anOptionalSessionIsNotInTheDenominator() {
        let r = SessionTally.over([match(session("a")),
                                   match(optional("b")),
                                   match(session("c"))])
        #expect(r.total == 2, "the optional one is excluded")
        #expect(r.optionalExcluded == 1)
    }

    @Test("A rest day is not in the denominator")
    func aRestDayIsNotInTheDenominator() {
        let r = SessionTally.over([match(session("a")), match(rest("b"))])
        #expect(r.total == 1)
        #expect(r.restExcluded == 1)
    }

    /// "opt." as well as "optional", and in the detail as well as the title —
    /// the regex is `\bopt(?:ional|\.)`, case-insensitive, over both fields
    /// joined. Pinned because a plan revision that reworded the marker would
    /// otherwise put 28 sessions back into every denominator silently.
    @Test("Both spellings of the optional marker are recognised, in either field")
    func theOptionalMarkerIsRecognisedWhereverItAppears() {
        let cases = [
            optional("a", word: "Optional"),
            optional("b", word: "OPT."),
            session("c", title: "Zwift ride", detail: "45 min Z2 — opt.")
        ]
        for s in cases {
            let r = SessionTally.over([match(s)])
            #expect(r.optionalExcluded == 1, "\(s.uid) was counted")
            #expect(r.total == 0)
        }
    }

    /// §12.54.2 — an exclusion you cannot see is indistinguishable from an
    /// exclusion that stopped being applied.
    @Test("The exclusions are counted, not just applied")
    func theExclusionsAreCountedNotJustApplied() {
        let r = SessionTally.over([match(session("a")), match(rest("b")),
                                   match(rest("c")), match(optional("d"))])
        #expect(r == SessionTally.Result(done: 0, total: 1,
                                         restExcluded: 2, optionalExcluded: 1))
    }

    // MARK: Both shapes, one rule

    /// TWO ENTRY POINTS IS HOW FIVE COPIES STARTED. `Matcher.adherence` walks
    /// sessions and resolves each day again; 321 declined to change that shape
    /// and 328 declines too. What it must not do is disagree about what counts.
    @Test("Both entry points apply the same rule")
    func bothEntryPointsApplyTheSameRule() {
        let sessions = [session("a"), rest("b"), optional("c"), session("d")]
        // `map { match($0) }` and NOT `map(match)` — patch 234, and CLAUDE.md
        // §2 carries it: handing a MainActor-isolated method to `map` as a
        // function VALUE passes it out of the actor.
        let viaMatches = SessionTally.over(sessions.map { match($0) })
        let viaSessions = SessionTally.over(sessions) { _ in false }
        #expect(viaMatches == viaSessions)
        #expect(viaMatches.total == 2)
    }

    @Test("The completion test drives the numerator, not the denominator")
    func theCompletionTestDrivesOnlyTheNumerator() {
        let sessions = [session("a"), rest("b"), optional("c"), session("d")]
        let none = SessionTally.over(sessions) { _ in false }
        let all = SessionTally.over(sessions) { _ in true }
        #expect(none.total == all.total, "a completion answer cannot move a denominator")
        #expect(none.done == 0)
        #expect(all.done == 2, "and it cannot resurrect an excluded session")
    }

    // MARK: Composition

    @Test("Results add, so a week is the sum of its days")
    func resultsAdd() {
        let monday = SessionTally.over([match(session("a")), match(rest("b"))])
        let tuesday = SessionTally.over([match(optional("c")), match(session("d"))])
        let week = monday + tuesday
        #expect(week == SessionTally.Result(done: 0, total: 2,
                                            restExcluded: 1, optionalExcluded: 1))
    }

    @Test("An empty walk is zero, and says nothing was excluded either")
    func anEmptyWalkIsZero() {
        #expect(SessionTally.over([Match]()) == SessionTally.Result())
    }

    /// A week of nothing but rest and optional sessions has a denominator of
    /// zero, and `PlanRow` draws no progress at all rather than "0 of 0" —
    /// which would read as a week the athlete failed.
    @Test("A week with nothing countable reports no line rather than zero of zero")
    func nothingCountableIsNotAFailedWeek() {
        let r = SessionTally.over([match(rest("a")), match(optional("b"))])
        #expect(r.total == 0)
        #expect(r.lineIfCounted == nil)
        #expect(r.line == "0 of 0", "the string still exists for a caller that wants it")
    }

    // MARK: The delegating callers

    /// PATCH 328a. THE RULE IS STATED IN EXACTLY ONE PLACE, and `counts` is a
    /// view of it rather than a second copy — 328a nearly shipped a `Bool`
    /// predicate beside an `over` that still spelled the filter out
    /// underneath, which would have been a fix carrying the defect it fixed.
    @Test("counts and verdict cannot disagree, because one is the other")
    func countsIsAViewOfVerdict() {
        let cases = [session("a"), rest("b"), optional("c")]
        for s in cases {
            #expect(SessionTally.counts(s) == (SessionTally.verdict(s) == .counts))
        }
        #expect(SessionTally.verdict(session("a")) == .counts)
        #expect(SessionTally.verdict(rest("b")) == .rest)
        #expect(SessionTally.verdict(optional("c")) == .optional)
    }

    /// A REST DAY THAT IS ALSO MARKED OPTIONAL reports as rest, and the order
    /// matters only because the two counters must sum to the excluded total.
    /// Pinned so a reordering cannot double-count.
    @Test("Every session lands in exactly one bucket")
    func everySessionLandsInExactlyOneBucket() {
        let all = [session("a"), rest("b"), optional("c"), session("d")]
        let r = SessionTally.over(all.map { match($0) })
        #expect(r.total + r.restExcluded + r.optionalExcluded == all.count)
    }

    /// `MatchResolver.adherence` is what both sides of `MatchParity` call, so
    /// its figure moves on the device and moves EQUALLY on both sides. Pinned
    /// here so the delegation cannot be quietly unwound.
    @Test("MatchResolver.adherence delegates and therefore excludes optional too")
    func matchResolverAdherenceDelegates() {
        let matches = [match(session("a")), match(optional("b")), match(rest("c"))]
        let a = MatchResolver.adherence(matches)
        let r = SessionTally.over(matches)
        #expect(a.done == r.done)
        #expect(a.total == r.total)
        #expect(a.total == 1, "not 2 — the optional session left the denominator at 328")
    }
}
