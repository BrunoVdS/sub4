//
//  SkipStandingTests.swift
//  Sub4CoreTests
//
//  Saying you did not do it — patch 368, ADR-0003 §12.112.
//
//  THE THIRD OF THE FAMILY, TESTED LIKE THE OTHER TWO
//  --------------------------------------------------
//  `MatchStandingTests` (359) and `MoveStandingTests` (367) ask the same three
//  questions of their types: does every state say something, does the flag the
//  control is enabled on distinguish them, and does the decision read the value
//  that is actually honest. This asks them of the skip.
//
//  WHAT THE GATE IS FOR
//  --------------------
//  Three separate things stop the control being offered, and the whole reason
//  `NotOffered` carries a reason is that a compound condition would answer "no"
//  to all three and name none. So each is driven separately, and `theOrderIsRest
//  FirstThenTheDay` pins the precedence — a rest day is never skippable however
//  else the day reads.
//
//  THE BOUNDARY THAT MATTERS
//  -------------------------
//  `todayIsNotYetPast`. The rule is STRICTLY before today, so a session on the
//  current day is not skippable. Off by one in the permissive direction and the
//  app offers, at 07:00, to record that you did not do a session you have all
//  day to do.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("Whether a session was skipped")
struct SkipStandingTests {

    private let today = "2026-08-15"

    private func decision(_ activityId: String?) -> MatchDecision {
        MatchDecision(sessionUid: "wk-03-x", activityId: activityId,
                      decided: Date(timeIntervalSince1970: 1_786_000_000),
                      dateIsKnown: true)
    }

    private func standing(rest: Bool = false,
                          day: String? = "2026-08-14",
                          done: Bool = false,
                          decision d: MatchDecision? = nil) -> SkipStanding {
        SkipStanding.of(isRest: rest, day: day, today: today,
                        isDone: done, decision: d)
    }

    // MARK: The three reasons it is not offered

    /// **THE PRECEDENCE, AND IT IS NOT ARBITRARY.** A rest day is never
    /// skippable whatever else is true of it — including being in the past with
    /// nothing matched, which is every other case's "yes".
    @Test("A rest day is never skippable")
    func aRestDayIsNeverSkippable() {
        #expect(standing(rest: true) == .notOffered(.restDay))
        #expect(standing(rest: true, day: "2026-01-01")
                == .notOffered(.restDay))
        #expect(standing(rest: true, done: true) == .notOffered(.restDay))
    }

    /// **STRICTLY BEFORE TODAY.** Permissive by one day and the app offers, at
    /// breakfast, to record that you did not do a session you have all day for.
    @Test("Today is not yet past")
    func todayIsNotYetPast() {
        #expect(standing(day: today) == .notOffered(.notPast))
        #expect(standing(day: "2026-08-16") == .notOffered(.notPast))
        #expect(standing(day: "2026-08-14") == .notSkipped,
                "the day before today is past and this proves the boundary")
    }

    /// A session the plan gives no day at all has no day to be past.
    @Test("A session with no day is not past")
    func aDatelessSessionIsNotPast() {
        #expect(standing(day: nil) == .notOffered(.notPast))
    }

    @Test("A matched session was not skipped")
    func aMatchedSessionIsNotSkipped() {
        #expect(standing(done: true) == .notOffered(.somethingIsMatched))
    }

    /// Rest wins over the day, and the day wins over the match. Driven rather
    /// than assumed, because the order is the only thing separating three
    /// answers that are each individually true.
    @Test("The order is rest first, then the day, then the match")
    func theOrderIsRestFirstThenTheDay() {
        #expect(standing(rest: true, day: today, done: true)
                == .notOffered(.restDay))
        #expect(standing(day: today, done: true) == .notOffered(.notPast))
    }

    // MARK: What the skip actually is

    /// **A DECISION NAMING NOTHING.** `match_decision.activityID` is nullable
    /// for exactly this, and the skip is not a second store — it is the same
    /// fact `MatchStanding.choseNothing` already describes, said from the card.
    @Test("A decision naming nothing is the skip")
    func aDecisionNamingNothingIsTheSkip() {
        #expect(standing(decision: decision(nil)) == .skipped)
    }

    /// **AND A STALE CHOICE IS NOT ONE.** A decision naming an activity the day
    /// no longer offers reads as not done everywhere — but the athlete said
    /// they DID it, and the app lost the recording. Marking that skipped is a
    /// gesture they can make; reporting it as already skipped is a claim they
    /// did not.
    @Test("A choice naming a gone activity is not a skip")
    func aStaleChoiceIsNotASkip() {
        #expect(standing(decision: decision("gone-42")) == .notSkipped)
    }

    @Test("No decision at all is not a skip")
    func noDecisionIsNotASkip() {
        #expect(standing(decision: nil) == .notSkipped)
    }

    // MARK: What the sheet and the card print

    @Test("Only an offered state can be acted on")
    func onlyAnOfferedStateIsOffered() {
        #expect(!SkipStanding.notOffered(.restDay).isOffered)
        #expect(!SkipStanding.notOffered(.notPast).isOffered)
        #expect(!SkipStanding.notOffered(.somethingIsMatched).isOffered)
        #expect(SkipStanding.notSkipped.isOffered)
        #expect(SkipStanding.skipped.isOffered)
    }

    @Test("Only the skipped state reads as skipped")
    func onlyTheSkippedStateIsSkipped() {
        #expect(SkipStanding.skipped.isSkipped)
        #expect(!SkipStanding.notSkipped.isSkipped)
        #expect(!SkipStanding.notOffered(.notPast).isSkipped)
    }

    /// **§12.54.2, TURNED ON THE TYPE.** Five states sharing sentences would
    /// defeat the rule from the inside: the line would print on every state and
    /// distinguish none of them.
    @Test("Every state says something, and something different")
    func everyStateSaysSomethingDifferent() {
        let all: [SkipStanding] = [.notOffered(.restDay), .notOffered(.notPast),
                                   .notOffered(.somethingIsMatched),
                                   .notSkipped, .skipped]
        let lines = all.map(\.line)
        #expect(Set(lines).count == all.count, "two states share a sentence")
        for l in lines { #expect(!l.isEmpty) }
    }

    // MARK: The glyph — patch 368a

    /// **THE RULE THREE RENDERERS SHARE, AND ONE OF THEM MISSED.** 359 fixed
    /// the picker, 368 fixed the card and the session page by writing the
    /// ternary out twice, and `WeekView` held a third copy that nobody
    /// remembered — so a skipped session looked untouched on the one screen
    /// you read a whole week from. It lives in one place now; this drives it.
    @Test("The symbol answers all three states")
    func theSymbolAnswersAllThreeStates() {
        #expect(SkipStanding.symbol(isDone: true, isSkipped: false)
                == "checkmark.circle.fill")
        #expect(SkipStanding.symbol(isDone: false, isSkipped: true)
                == "xmark.circle.fill")
        #expect(SkipStanding.symbol(isDone: false, isSkipped: false) == "circle")
    }

    /// **DONE WINS.** The two flags can both be true in one frame — a skip
    /// recorded, then a matching activity arriving on the next import, before
    /// the standing is recomputed. Drawn as skipped it would say "you did not
    /// do this" over a session with a recording against it.
    @Test("Done wins over skipped")
    func doneWinsOverSkipped() {
        #expect(SkipStanding.symbol(isDone: true, isSkipped: true)
                == "checkmark.circle.fill")
    }

    /// Three states, three symbols. Two sharing one would put the Week page
    /// back where it started.
    @Test("No two states share a symbol")
    func noTwoStatesShareASymbol() {
        let all = [SkipStanding.symbol(isDone: true, isSkipped: false),
                   SkipStanding.symbol(isDone: false, isSkipped: true),
                   SkipStanding.symbol(isDone: false, isSkipped: false)]
        #expect(Set(all).count == 3, "two states draw the same circle")
    }

    /// The two actions have to differ, or the control says the same thing
    /// whether it is about to record something or take it back.
    @Test("Undoing does not say the same as doing")
    func theActionsDiffer() {
        #expect(SkipStanding.skipped.action != SkipStanding.notSkipped.action)
        #expect(!SkipStanding.skipped.action.isEmpty)
        #expect(!SkipStanding.notSkipped.action.isEmpty)
        // Present in every state — the caller renders it disabled rather than
        // absent, so an empty label would be a blank control.
        for s in [SkipStanding.notOffered(.restDay),
                  .notOffered(.notPast), .notOffered(.somethingIsMatched)] {
            #expect(!s.action.isEmpty)
        }
    }
}

// MARK: - Through the matcher

/// **THE HALF LITERALS CANNOT PROVE.** The gate is correct on values above;
/// what the card and the page do with it goes through `Matcher`, and the skip
/// has to survive a round trip as the same fact `MatchStanding` already knows.
@Suite("The skip is a decision naming nothing")
@MainActor
struct SkipWriteTests {

    /// The two standings describe one row from two sides. If they ever
    /// disagreed, the card and the picker would say different things about the
    /// same session — which is the defect a second store for this would have
    /// guaranteed.
    @Test("The skip and the match standing agree about one decision")
    func theTwoStandingsAgree() {
        let none = MatchDecision(sessionUid: "wk-03-x", activityId: nil,
                                 decided: Date(timeIntervalSince1970: 1_786_000_000),
                                 dateIsKnown: true)

        #expect(MatchStanding.of(decision: none, offered: ["a"]) == .choseNothing)
        #expect(SkipStanding.of(isRest: false, day: "2026-08-14",
                                today: "2026-08-15", isDone: false,
                                decision: none) == .skipped)
    }

    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "skip-440-\(UUID().uuidString)"))
    }

    /// `setOverride(sessionUid:activityId:)` records the skip and
    /// `clearOverride(sessionUid:)` takes it back — the primitives 272 built,
    /// which is why 368 needs no store of its own.
    ///
    /// **THIS TEST USED `Matcher.shared` UNTIL 440, AND IT PASSED ONLY ON A
    /// SIMULATOR AN EARLIER RUN HAD ALREADY DIRTIED.** The singleton commits to
    /// `Sub4Launch.shared.database` — the app's REAL database, which is open in
    /// the test process — and `match_decision.accountID` references `account`.
    /// On a freshly erased container there is no account row, the insert fails
    /// the foreign key, and `setOverride` correctly refuses to publish. Run it
    /// again and it passes, because the first run left the row behind.
    ///
    /// So it is the seam now, like every other test of this store. §12.195.
    @Test("Recording and clearing a skip round-trips")
    func recordingASkipRoundTrips() throws {
        let m = Matcher(defaults: try freshDefaults())
        let uid = "wk-99-skip-test"

        #expect(m.decisions[uid] == nil)

        m.setOverride(sessionUid: uid, activityId: nil)
        let recorded = m.decisions[uid]
        #expect(recorded != nil, "the skip was not recorded")
        #expect(recorded?.activityId == nil,
                "the skip named an activity, so it is not a skip")

        m.clearOverride(sessionUid: uid)
        #expect(m.decisions[uid] == nil, "the skip could not be taken back")
    }

    // MARK: What the dirty simulator was hiding — patch 440

    /// **THE STATE THAT BROKE IT, DRIVEN ON PURPOSE.**
    ///
    /// 412's controls reach a refusal by DROPPING the table, which is a
    /// database somebody broke. This is a database that is perfectly healthy
    /// and simply has no account row yet — the state every phone is in before
    /// its first import, and the state a freshly erased simulator is in for the
    /// whole of the first test run.
    ///
    /// The refusal is CORRECT: a decision the database would not take must not
    /// show a tick (§12.157). What was wrong was a test relying on the row
    /// being there.
    @Test("Before the account row exists, a skip does not stick")
    func aSkipIsRefusedUntilTheAccountRowExists() throws {
        let db = try Sub4Database.inMemory()
        let m = Matcher(defaults: try freshDefaults(), database: db)

        m.setOverride(sessionUid: "wk-03-x", activityId: nil)

        #expect(m.decisions["wk-03-x"] == nil,
                "a decision the foreign key refused was published anyway")
        #expect(m.lastCommit != .reached)
    }

    /// The positive control, and without it the one above passes for a database
    /// that refuses everything — zero compared to zero.
    @Test("Once the account exists the skip reaches the rows and can be taken back")
    func aSkipReachesTheRows() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])
        let m = Matcher(defaults: try freshDefaults(), database: db)

        m.setOverride(sessionUid: "wk-03-x", activityId: nil)
        #expect(m.decisions["wk-03-x"] != nil, "the skip did not stick")
        #expect(m.lastCommit == .reached)
        #expect(try rows(db) == 1)

        // READ WITH SQL, not through the reader that shares the writer's
        // filter — 411 shipped exactly that bug for a day.
        let stored = try db.queue.read { d in
            try String.fetchOne(d, sql: """
                SELECT COALESCE(activityID, 'null') FROM match_decision
                WHERE accountID = ? AND planSessionUID = ?
                """, arguments: [Sub4Import.accountID, "wk-03-x"])
        }
        #expect(stored == "null", "the skip named an activity in the row")

        m.clearOverride(sessionUid: "wk-03-x")
        #expect(m.decisions["wk-03-x"] == nil)
        #expect(try rows(db) == 0, "the row outlived the decision")
    }

    private func rows(_ db: Sub4Database) throws -> Int {
        try db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM match_decision WHERE accountID = ?
                """, arguments: [Sub4Import.accountID]) ?? 0
        }
    }
}
