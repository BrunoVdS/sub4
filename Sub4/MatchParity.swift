//
//  MatchParity.swift
//  Sub4
//
//  D6c slice 5 — plan matching. Patch 321, ADR-0003 §12.64.
//
//  THE NUMBER UNDERNEATH THIS ONE IS ON THE WEEK SCREEN
//  ----------------------------------------------------
//  Slices 1 to 4 compared lists, distances, loads and paces. This compares
//  **which activity satisfied which planned session** — and the figure that
//  falls out of it is *Sessions 4/4*, the one line on the Week screen that says
//  whether the block is being done.
//
//  It is also the slice with the most ways to be quietly wrong. A session with
//  no stated distance takes `candidates.first!`, so the ORDER of the activity
//  array decides what it claims. A session with a stated distance takes the
//  nearest by kilometres, so a distance differing by a metre could swing it.
//  And an override names an activity by id, so an id the twin does not hold
//  turns a manual match into an unmatched session.
//
//  None of that is hypothetical arithmetic — every one is a branch in
//  `MatchResolver.resolve`, and this is the first thing that has ever run that
//  function twice.
//
//  BOTH SIDES CALL ONE COPY
//  ------------------------
//  `MatchResolver.day` is the app's own derivation, extracted at 321 and
//  unchanged. Neither side reimplements the eligibility filter, the three
//  resolution steps, the ordering or the extras sort. §12.43, seventh
//  application, and the one where a second implementation would have been
//  least detectable: two plausible match lists differing on one session, and no
//  test able to say which is right.
//
//  WHAT IS HELD FROM THE APP, AND WHY EACH ONE
//  -------------------------------------------
//    · **the plan** — `plan_session` and its children are in the database and
//      have no reader. That is slice 6b. Holding it means a difference here
//      cannot be a plan difference.
//    · **the match decisions** — `match_decision` is in the database, holds
//      **zero rows on this device**, and has no reader either. Holding them
//      keeps the override branch exercised on both sides by the same data.
//    · **the commute decisions** — `isPlanEligible` reads `CommuteStore`
//      through `isCommuteRide`, and patch 251 decided not to thread that
//      through fourteen call sites. It is the same store answering the same
//      activity ids on both sides, so it cannot make them disagree; it is
//      still held rather than compared, and the screen says so.
//
//  So exactly one variable moves: **the activities**. That is slice 3's shape
//  and it is deliberate — a difference in the match rows has one cause.
//
//  THE DENOMINATOR THAT IS NOT `sessionsCompared`
//  ----------------------------------------------
//  Most planned sessions are rest days or sessions with no activity to find,
//  and those resolve to `nil` on both sides in agreement. A run over 37 weeks
//  would report hundreds of matched-nothings and look thorough.
//
//  `matchesResolved` counts the sessions that claimed an ACTIVITY on both
//  sides. That is what `lookedAtSomething` tests, for §12.54.2's reason one
//  level up from the row it was written for: **a session that matched nothing
//  on both sides agrees perfectly and describes nothing.**
//
//  THE OVERRIDE THAT CANNOT WIN — NAMED, NOT FIXED
//  -----------------------------------------------
//  `resolve` step 1 honours an override only when the named activity is in the
//  pool, and the pool has already been filtered by `isPlanEligible` — under
//  which a walk is never eligible. So an override naming a walk produces an
//  unmatched session, and the Week screen says *Not done* with nothing on
//  screen saying why.
//
//  That is the defect open since 2026-08-05, and 321 does not fix it: the fix
//  is a behaviour change and the choice between the two candidates is the
//  athlete's. `MatchResolverTests.anOverrideNamingAnIneligibleActivityIsLost`
//  asserts today's behaviour with the defect named, so the day it is fixed the
//  test inverts rather than the change going unnoticed.
//

import Foundation

@MainActor
enum MatchParity {

    /// What this comparison cannot see. Printed, not implied.
    static let heldFromTheApp =
        "the plan, the match decisions and the commute decisions"

    /// Of those three, the one the authored read-back now checks — patch 322.
    ///
    /// A SEPARATE STRING RATHER THAN AN EDIT TO THE ONE ABOVE, for §12.61.1's
    /// reason: what this comparison holds constant did not change, what is
    /// known about it did, and collapsing the two would lose the distinction
    /// between "not varied here" and "proven identical".
    ///
    /// The match decisions are not in it and cannot be until something reads
    /// `match_decision` — which holds zero rows, so there would be nothing to
    /// check. **The plan joined the list at 323**, which leaves the match
    /// decisions as the only held input this screen cannot yet corroborate,
    /// and an empty table as the reason.
    static let verifiedByReadBack =
        "the plan and the commute decisions, by their read-backs"

    // MARK: The report

    struct Report: Equatable {

        // Denominators — groundwork §2.1 case 2.

        /// Days walked: every day carrying a planned session or an activity on
        /// either side.
        let daysCompared: Int
        /// Planned sessions resolved on both sides.
        let sessionsCompared: Int
        /// Sessions that claimed an ACTIVITY on both sides. THE denominator —
        /// see the header.
        let matchesResolved: Int
        /// Activities that fell out of the plan on either side, compared by
        /// day. The other half of the movement picture.
        let extrasCompared: Int

        // Membership

        let daysOnlyInApp: [String]
        let daysOnlyInDatabase: [String]
        /// A session one side resolved and the other did not see at all.
        let sessionsOnOneSideOnly: [String]

        // Differences

        /// THE ROW THIS SLICE EXISTS FOR. Both sides matched the session and
        /// they named a different activity.
        let sessionsWithADifferentActivity: [String]
        /// Matched on one side, unmatched on the other. *Sessions 4/4* becomes
        /// 3/4 on exactly this.
        let sessionsDoneOnOneSideOnly: [String]
        /// One side called it a manual override and the other an automatic
        /// match. The activity may be the same; how it was chosen is not.
        let sessionsWithADifferentSource: [String]
        /// The extras list held different activities.
        let daysWithDifferentExtras: [String]
        /// Same activities, different order — the list is sorted by
        /// `startLocal` and the screen draws it in that order.
        let daysWithDifferentExtraOrder: [String]

        // Context, printed on both sides rather than asserted

        /// The Week screen's numerator and denominator, both sides.
        let appSessionsDone: Int
        let databaseSessionsDone: Int
        let sessionsCounted: Int
        /// How many resolutions went down the override branch at all. **Zero on
        /// a device with no overrides**, which is the state today — printed so
        /// that "no differences" can be read as "and the override branch was
        /// never exercised" rather than as coverage it does not have.
        let overridesApplied: Int

        var unexplained: Int {
            daysOnlyInApp.count + daysOnlyInDatabase.count
            + sessionsOnOneSideOnly.count
            + sessionsWithADifferentActivity.count
            + sessionsDoneOnOneSideOnly.count
            + sessionsWithADifferentSource.count
            + daysWithDifferentExtras.count + daysWithDifferentExtraOrder.count
            + (appSessionsDone == databaseSessionsDone ? 0 : 1)
        }

        /// Zero days compared to zero days agrees perfectly, and so does a
        /// plan whose every session matched nothing on both sides.
        var lookedAtSomething: Bool { daysCompared > 0 && matchesResolved > 0 }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else {
                return "nothing compared — \(daysCompared) days, "
                     + "\(matchesResolved) matches"
            }
            return unexplained == 0
                ? "\(daysCompared) days · \(matchesResolved) matches · no differences"
                : "\(daysCompared) days · \(unexplained) differences"
        }

        /// "218 of 251 vs 218 of 251" — the Week screen's figure, both sides.
        var adherenceLine: String {
            "\(appSessionsDone) of \(sessionsCounted) vs "
            + "\(databaseSessionsDone) of \(sessionsCounted)"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        ///
        /// SAFE TO PASTE. Day keys, session uids and counts. A session uid is
        /// the plan's own identifier and describes the plan, not the athlete;
        /// no activity ids and no session names.
        var diagnosticLines: [String] {
            var lines = [
                "Match parity: \(daysCompared) days, \(matchesResolved) matches",
                "  held from the app: \(heldFromTheApp)",
                "  of those, verified: \(verifiedByReadBack)",
                "  planned sessions compared: \(sessionsCompared)",
                "  sessions that claimed an activity on both sides: \(matchesResolved)",
                "  extras compared: \(extrasCompared)",
                "  days only in the app: \(daysOnlyInApp.count)",
                "  days only in the database: \(daysOnlyInDatabase.count)",
                "  sessions on one side only: \(sessionsOnOneSideOnly.count)",
                "  sessions that claimed a different activity: "
                + "\(sessionsWithADifferentActivity.count)",
                "  sessions done on one side only: \(sessionsDoneOnOneSideOnly.count)",
                "  sessions chosen a different way: "
                + "\(sessionsWithADifferentSource.count)",
                "  days with different extras: \(daysWithDifferentExtras.count)",
                "  days with a different extras order: "
                + "\(daysWithDifferentExtraOrder.count)",
                "  overrides applied: \(overridesApplied)",
                "  adherence: \(adherenceLine)",
                "  unexplained differences: \(unexplained)"]
            // NAMED, NOT JUST COUNTED — §12.39's rule.
            for u in sessionsWithADifferentActivity.prefix(6) {
                lines.append("    different activity \(u)")
            }
            for u in sessionsDoneOnOneSideOnly.prefix(6) {
                lines.append("    done on one side \(u)")
            }
            for d in daysWithDifferentExtras.prefix(5) {
                lines.append("    extras \(d)")
            }
            return lines
        }
    }

    // MARK: The comparison

    /// Two days-worth of resolutions, keyed by day. Neither side is read from
    /// anywhere here.
    ///
    /// STATIC AND TAKING ITS INPUTS, like the other four slices, so a test can
    /// build the two sides from genuinely different places — which for this
    /// slice means two different activity lists through one resolver.
    static func compare(app: [String: MatchResolver.Day],
                        database: [String: MatchResolver.Day]) -> Report {

        let onlyInApp = app.keys.filter { database[$0] == nil }
        let onlyInDatabase = database.keys.filter { app[$0] == nil }
        let shared = Set(app.keys).intersection(database.keys).sorted()

        var sessionsCompared = 0
        var matchesResolved = 0
        var extrasCompared = 0
        var onOneSideOnly: [String] = []
        var differentActivity: [String] = []
        var doneOnOneSideOnly: [String] = []
        var differentSource: [String] = []
        var differentExtras: [String] = []
        var differentExtraOrder: [String] = []
        var appDone = 0, databaseDone = 0, counted = 0
        var overrides = 0

        for day in shared {
            guard let a = app[day], let d = database[day] else { continue }

            let theirs = Dictionary(d.matches.map { ($0.session.uid, $0) },
                                    uniquingKeysWith: { first, _ in first })
            var seen: Set<String> = []

            for m in a.matches {
                seen.insert(m.session.uid)
                guard let t = theirs[m.session.uid] else {
                    onOneSideOnly.append(m.session.uid); continue
                }
                sessionsCompared += 1

                // THE WEEK SCREEN'S FIGURE, counted from the matches both
                // sides produced rather than re-resolved.
                //
                // PATCH 328a — AND THE COMMENT ABOVE USED TO BE FALSE. It said
                // "rest days are excluded exactly as `Matcher.adherence`
                // excludes them", which read like a delegation and was a
                // hand-written copy. 328 extracted five copies of this rule and
                // missed this one, so for one patch the Database screen's
                // adherence counted optional sessions while all three tabs had
                // stopped. `SessionTally.counts` is the rule; there is nothing
                // left on this line to drift. §12.72.7.
                //
                // A PAIRED WALK, which is why it is the predicate rather than
                // `SessionTally.over`: one pass counts the app's done and the
                // database's done for the SAME session, and splitting it into
                // two walks would be two chances to pair them differently.
                if SessionTally.counts(m.session) {
                    counted += 1
                    if m.isDone { appDone += 1 }
                    if t.isDone { databaseDone += 1 }
                }
                if !m.auto { overrides += 1 }

                switch (m.activity?.id, t.activity?.id) {
                case let (x?, y?):
                    matchesResolved += 1
                    if x != y { differentActivity.append(m.session.uid) }
                case (nil, nil):
                    break
                default:
                    // MATCHED ON ONE SIDE AND NOT THE OTHER. This is the row
                    // that turns 4/4 into 3/4, and it is the shape the match
                    // picker defect produces.
                    doneOnOneSideOnly.append(m.session.uid)
                }

                // HOW it was chosen, not only what was chosen. An automatic
                // match that happens to land on the activity an override named
                // is the same row and a different fact.
                if m.auto != t.auto { differentSource.append(m.session.uid) }
            }
            for u in theirs.keys where !seen.contains(u) {
                onOneSideOnly.append(u)
            }

            // THE EXTRAS, by identity and then by order. The list is sorted by
            // `startLocal` and the screen draws it in that order, so two lists
            // holding the same activities in a different sequence are not the
            // same screen.
            let mine = a.extras.map(\.id)
            let others = d.extras.map(\.id)
            extrasCompared += mine.count
            if Set(mine) != Set(others) { differentExtras.append(day) }
            else if mine != others { differentExtraOrder.append(day) }
        }

        return Report(
            daysCompared: shared.count,
            sessionsCompared: sessionsCompared,
            matchesResolved: matchesResolved,
            extrasCompared: extrasCompared,
            daysOnlyInApp: onlyInApp.sorted(),
            daysOnlyInDatabase: onlyInDatabase.sorted(),
            sessionsOnOneSideOnly: onOneSideOnly.sorted(),
            sessionsWithADifferentActivity: differentActivity.sorted(),
            sessionsDoneOnOneSideOnly: doneOnOneSideOnly.sorted(),
            sessionsWithADifferentSource: differentSource.sorted(),
            daysWithDifferentExtras: differentExtras.sorted(),
            daysWithDifferentExtraOrder: differentExtraOrder.sorted(),
            appSessionsDone: appDone,
            databaseSessionsDone: databaseDone,
            sessionsCounted: counted,
            overridesApplied: overrides)
    }
}
