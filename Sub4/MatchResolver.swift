//
//  MatchResolver.swift
//  Sub4
//
//  What satisfies a planned session — extracted at patch 321, ADR-0003 §12.64.
//
//  WHY THIS FILE EXISTS, AND IT IS THE SEVENTH TIME
//  -----------------------------------------------
//  D6c slice 5 asks whether the database's activities would match the plan the
//  same way the app's do. Answering that needs the resolution run twice, on two
//  different activity lists — and §12.43 has cost this project three patches
//  worth of the alternative:
//
//    > Do not reimplement the rule. Extract it, and have both sides call the
//    > one copy.
//
//  `isKept`/`dedup` (310), `byDay` (312), `recordedByWeek` (313),
//  `LoadSeries.build` (314), the athlete round trip (317), the detail
//  derivations (320), and now this.
//
//  Here the alternative would have been the worst of the seven. Two plausible
//  match lists differing on which activity one session claimed, with **no test
//  able to say which is right**, and the number underneath it is *Sessions 4/4*
//  on the Week screen.
//
//  THE CODE BELOW IS THE APP'S, MOVED
//  ----------------------------------
//  `resolve` and `plannedKm` are `Matcher`'s own bodies, unchanged except that
//  `decisions` arrives as a parameter instead of being read off the instance,
//  and both are `static`. **No behaviour changed in this patch**, which is what
//  makes the existing suite the proof that the move was faithful — the same
//  argument 310 and 314 made, and the reason 321 fixes nothing while it moves.
//
//  MATCHING IS ORDER-DEPENDENT, AND THAT IS NOT A DEFECT
//  ----------------------------------------------------
//  Step 3 takes `candidates.first!` when a session states no distance, so the
//  ORDER of the activity array decides which activity a vague session claims.
//  That is deliberate — the pool is newest-first and the first candidate is the
//  most recent — and it means slice 5's answer rests on slice 1's.
//
//  Slice 1 reports `0 order disagreements of 674`. If it ever did not, this
//  slice would go red too, and it would be right to. Stated here rather than
//  discovered later, because a comparison whose correctness depends on another
//  comparison should say so.
//
//  WHAT IT STILL READS FROM A SINGLETON
//  ------------------------------------
//  `day` filters on `Activity.isPlanEligible`, which reads `isCommuteRide`,
//  which reads `CommuteStore.shared`. That is not pure and is not made pure
//  here: patch 251 decided that threading a decision dictionary through
//  `isPlanEligible` and fourteen call sites would put the store in the
//  signature of half the app.
//
//  It cannot make the two sides disagree — it is the same store answering the
//  same activity ids — but it IS held constant rather than compared, and the
//  Database screen says so beside the result.
//

import Foundation

@MainActor
enum MatchResolver {

    /// One day's derivation, whole.
    ///
    /// `extras` deliberately includes commutes, walks, kayaking and any
    /// plan-eligible activity that found no session — it is the full movement
    /// picture, not a discard pile. `Matcher.day` said that before this file
    /// existed and the sentence moved with the code.
    struct Day: Equatable {
        let matches: [Match]
        let extras: [Activity]
    }

    /// THE WHOLE OF WHAT `Matcher.day` DERIVES, from inputs rather than from
    /// three singletons. `Matcher.day` is one caller; the shadow twin is the
    /// other, and there will never be a third implementation to keep in step.
    static func day(sessions: [Session],
                    activities: [Activity],
                    decisions: [String: MatchDecision],
                    dayKey: String) -> Day {
        let eligible = activities.filter(\.isPlanEligible)
        let ineligible = activities.filter { !$0.isPlanEligible }

        let (matches, leftover) = resolve(sessions: sessions,
                                          activities: eligible,
                                          decisions: decisions,
                                          dayKey: dayKey)

        let extras = (leftover + ineligible).sorted { $0.startLocal < $1.startLocal }
        return Day(matches: matches, extras: extras)
    }

    /// Completion over a set of matches — rest days excluded, exactly as
    /// `Matcher.adherence` counts them.
    ///
    /// TAKES THE MATCHES RATHER THAN RE-RESOLVING THEM. `Matcher.adherence`
    /// walks sessions and calls `isComplete` per session, which resolves the
    /// whole day again each time; that is left alone. This counts what a
    /// resolution already produced, so it is a tally of the comparison's own
    /// inputs and not a second opinion about them.
    static func adherence(_ matches: [Match]) -> (done: Int, total: Int) {
        var done = 0, total = 0
        for m in matches where !m.session.isRest {
            total += 1
            if m.isDone { done += 1 }
        }
        return (done, total)
    }

    // MARK: The resolution, moved from `Matcher` at 321

    static func resolve(sessions: [Session],
                        activities: [Activity],
                        decisions: [String: MatchDecision],
                        dayKey: String) -> ([Match], [Activity]) {

        var pool = activities
        var matches: [Match] = []

        // 1. Manual overrides win outright.
        //
        //    THREE OUTCOMES, TWO OF THEM THE SAME MATCH. "Explicitly nothing"
        //    and "the activity named is not here" both produce an unmatched
        //    session, which is the behaviour the `""` shape had and is kept
        //    deliberately: the athlete overrode the matcher, so the matcher
        //    does not get another guess. The importer treats the two
        //    differently, because the database can tell them apart and this
        //    screen cannot.
        var remaining: [Session] = []
        for s in sessions {
            if let decision = decisions[s.uid] {
                if let forced = decision.activityId,
                   let i = pool.firstIndex(where: { $0.id == forced }) {
                    matches.append(Match(session: s, activity: pool.remove(at: i), auto: false))
                } else {
                    matches.append(Match(session: s, activity: nil, auto: false))
                }
            } else {
                remaining.append(s)
            }
        }

        // 2. Rest days in the past complete themselves — a rest day is done by
        //    doing nothing, so there is never an activity to find.
        var needsActivity: [Session] = []
        for s in remaining {
            if s.isRest {
                let past = dayKey < DayKey.key()
                matches.append(Match(session: s,
                                     activity: nil,
                                     auto: true))
                _ = past
            } else {
                needsActivity.append(s)
            }
        }

        // 3. Automatic matching, best-fit first. Sessions with a stated distance
        //    are resolved before vague ones so they claim the right activity.
        for s in needsActivity.sorted(by: { plannedKm($0) ?? 0 > plannedKm($1) ?? 0 }) {
            let candidates = pool.enumerated().filter { $0.element.discipline == s.discipline }

            guard !candidates.isEmpty else {
                matches.append(Match(session: s, activity: nil, auto: true))
                continue
            }

            let pick: Int
            if let target = plannedKm(s), candidates.count > 1 {
                pick = candidates.min {
                    abs($0.element.km - target) < abs($1.element.km - target)
                }!.offset
            } else {
                pick = candidates.first!.offset
            }
            matches.append(Match(session: s, activity: pool.remove(at: pick), auto: true))
        }

        let order = sessions.map(\.uid)
        matches.sort {
            (order.firstIndex(of: $0.session.uid) ?? 0)
                < (order.firstIndex(of: $1.session.uid) ?? 0)
        }
        return (matches, pool)
    }

    /// Best guess at the planned distance, pulled from the session text
    /// ("26 km", "1200 m", "6×100").
    static func plannedKm(_ s: Session) -> Double? {
        let text = [s.title, s.detail, s.breakdown?.total]
            .compactMap { $0 }.joined(separator: " ")

        if let m = text.range(of: #"(\d+(?:[.,]\d+)?)\s*km"#, options: .regularExpression) {
            let n = text[m].replacingOccurrences(of: "km", with: "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            return Double(n)
        }
        if let m = text.range(of: #"(\d{3,5})\s*m\b"#, options: .regularExpression) {
            let n = text[m].replacingOccurrences(of: "m", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(n).map { $0 / 1000.0 }
        }
        return nil
    }
}
