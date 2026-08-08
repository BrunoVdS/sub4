//
//  SessionTally.swift
//  Sub4
//
//  "Done of total", once — patch 328, ADR-0003 §12.72.
//
//  SEVEN IMPLEMENTATIONS, AND THEY DISAGREED
//  -----------------------------------------
//  Counting how many of a week's planned sessions were completed is the most
//  reproduced derivation in this app. Before this file there were SEVEN copies:
//
//    Matcher.adherence(for:)          walks sessions, calls isComplete
//    MatchResolver.adherence(_:)      walks matches — extracted at 321
//    WeekView.totals                  the Week tab's card
//    PlanView.PlanRow.progress        each week row on the Plan tab
//    ProgressTabView.points           the Progress chart's WeekPoint
//    MatchParity (line 272)           the adherence line on the Database screen
//    Review.swift `countable`         what the MODEL is told, each week row
//
//  All seven excluded rest days. **One excluded optional sessions.**
//
//  328 SAID FIVE AND SHIPPED FIVE. It was wrong, and the way it was wrong is
//  worth more than the fix. The copies were counted by grepping `isDone`;
//  `MatchParity:274` appeared in those results and was ASSUMED to be a call to
//  `MatchResolver.adherence` rather than read. It is a sixth copy. `Review`'s
//  is a seventh, reached only by grepping `isRest` afterwards.
//
//  The device caught it inside an hour, and only because 328 predicted a
//  NUMBER: adherence should fall from 236 to about 206. It read 236. A
//  prediction of "it should drop a bit" would have been satisfied by the
//  screen and the two survivors would still be there. §12.72.7.
//
//  `ProgressTabView.points` carries the comment, and it names the patch:
//
//      OPTIONAL SESSIONS EXCLUDED, as they are everywhere else. This filter
//      was missing until patch 98: the tally counted the plan's 28 optional
//      Zwift rides while every distance figure on the same card excluded
//      them, and the info sheet said they were not counted.
//
//  *"as they are everywhere else"* was true of the file it was written in and
//  false of the app. Patch 98 fixed the site it was looking at and left four.
//  So the Week tab and the Progress tab printed different denominators for the
//  same week, and each was internally consistent, which is why nothing caught
//  it: **a rule copied seven times is not seven checks, it is seven chances
//  to drift.** §12.43, and this is the eleventh application.
//
//  None of the seven completed D6c slices would have found this. Every one of
//  them compares the app against the database; this is the app disagreeing
//  with itself, on two screens, about a number the athlete reads as progress.
//  It was found by reading the code before writing slice 8's twin — which is
//  §12.44's point restated: read the code that produces the number.
//
//  WHAT THE RULE IS, STATED ONCE
//  -----------------------------
//  A planned session counts toward the denominator unless it is a **rest** day
//  or an **optional** one. Optional is `PlanStore.isOptional` — a regex for
//  "opt." or "optional" in the title or detail, which is how the plan HTML
//  marks the 28 Zwift rides.
//
//  The numerator is `Match.isDone`, which is `activity != nil`: a session is
//  done when something the athlete recorded satisfied it.
//
//  THE EXCLUSIONS ARE COUNTED, NOT JUST APPLIED — §12.54.2
//  ------------------------------------------------------
//  `restExcluded` and `optionalExcluded` ride on the result and are printed
//  wherever there is room. An exclusion nobody can see is indistinguishable
//  from an exclusion that stopped being applied, and this rule has already
//  been half-applied for 230 patches without anybody noticing.
//
//  `MainActor`, like `MatchResolver` — `Match` is main-actor isolated because
//  it holds a `Session` and an `Activity`, and this counts what a resolution
//  already produced rather than resolving anything itself.
//

import Foundation

@MainActor
enum SessionTally {

    /// What a walk over one or more days produced.
    ///
    /// `Equatable` so a test can state a whole expectation in one line, and so
    /// slice 8's twin can compare two of these rather than four loose Ints.
    struct Result: Equatable {
        var done = 0
        var total = 0
        /// Excluded and counted. See the header.
        var restExcluded = 0
        var optionalExcluded = 0

        /// "3 of 4". The form every one of the seven call sites was building
        /// by hand.
        var line: String { "\(done) of \(total)" }

        /// Nil rather than "0 of 0" for a week that has not begun — the shape
        /// `PlanRow.progress` needs, kept here so the caller does not restate
        /// the condition.
        var lineIfCounted: String? { total > 0 ? line : nil }

        static func + (a: Result, b: Result) -> Result {
            Result(done: a.done + b.done,
                   total: a.total + b.total,
                   restExcluded: a.restExcluded + b.restExcluded,
                   optionalExcluded: a.optionalExcluded + b.optionalExcluded)
        }
    }

    /// WHY A SESSION IS OR IS NOT IN A DENOMINATOR — one statement, and the
    /// only one in the project.
    ///
    /// A predicate would have been enough for the callers and not enough for
    /// this file: `over(_:)` has to say WHICH exclusion applied, so a
    /// `Bool` would have left the two reasons written out a second time right
    /// underneath. 328a nearly shipped exactly that, which would have been a
    /// fix carrying the defect it was fixing.
    enum Verdict: Equatable {
        case counts
        case rest
        case optional
    }

    static func verdict(_ s: Session) -> Verdict {
        if s.isRest { return .rest }
        if PlanStore.isOptional(s) { return .optional }
        return .counts
    }

    /// THE RULE AS A PREDICATE — patch 328a, for the caller that cannot use
    /// `over(_:)`.
    ///
    /// `MatchParity` walks TWO lists at once, counting the app's done and the
    /// database's done for the same session in one pass. Splitting that into
    /// two walks would be two chances to pair them differently, so it takes
    /// the rule and keeps its own loop.
    ///
    /// Deliberately takes a `Session`, not a `Match`: whether a session belongs
    /// in a denominator is a property of the session and says nothing about
    /// whether it was done.
    static func counts(_ s: Session) -> Bool { verdict(s) == .counts }

    /// THE ONE IMPLEMENTATION. Everything else in this file routes here.
    static func over(_ matches: [Match]) -> Result {
        var r = Result()
        for m in matches {
            switch verdict(m.session) {
            case .rest: r.restExcluded += 1
            case .optional: r.optionalExcluded += 1
            case .counts:
                r.total += 1
                if m.isDone { r.done += 1 }
            }
        }
        return r
    }

    static func over(_ days: [MatchResolver.Day]) -> Result {
        days.reduce(Result()) { $0 + over($1.matches) }
    }

    /// The session-shaped entry point, for `Matcher.adherence(for:)`.
    ///
    /// It cannot use the match-shaped one: it walks SESSIONS and asks
    /// `isComplete` per session, which resolves each day again. That shape is
    /// left alone — 321 deliberately declined to change it — but the RULE it
    /// applies comes from here, so the two cannot drift apart again.
    ///
    /// `isComplete` is passed in rather than reached for, so this stays a pure
    /// function of its arguments and a test can drive it without a matcher.
    static func over(_ sessions: [Session],
                     isComplete: (Session) -> Bool) -> Result {
        var r = Result()
        for s in sessions {
            switch verdict(s) {
            case .rest: r.restExcluded += 1
            case .optional: r.optionalExcluded += 1
            case .counts:
                r.total += 1
                if isComplete(s) { r.done += 1 }
            }
        }
        return r
    }
}
