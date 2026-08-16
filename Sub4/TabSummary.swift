//
//  TabSummary.swift
//  Sub4
//
//  The tab summaries, as functions of their inputs — D6c slice 8, patch 329,
//  ADR-0003 §12.73.
//
//  WHAT THIS IS FOR
//  ----------------
//  Third extraction of the same shape, and the last one D6c needs.
//
//    310  `ActivityRoster`   the five rules that turn rows into the list
//    321  `MatchResolver`    one day's matching, from inputs not singletons
//    328  `SessionTally`     "done of total", once instead of seven times
//    329  `TabSummary`       what the Progress and Week tabs add up
//
//  Every one of them existed because a twin cannot call a derivation that
//  lives inside a `View` and reads `.shared`. §12.43, and the reason it keeps
//  recurring is that a derivation with one caller looks like part of that
//  caller right up until something else has to agree with it.
//
//  THIS PATCH CHANGES NO BEHAVIOUR, AND THE SUITE IS THE PROOF
//  ----------------------------------------------------------
//  The bodies below are the bodies that were in `ProgressTabView` and
//  `WeekView`, moved. Not rewritten, not tidied, not corrected — moved. Every
//  existing test that touches those tabs exercises them, which is the same
//  argument 310 made for `ActivityRoster` and the reason that patch landed
//  clean.
//
//  The one thing that changes is what they READ: weeks, sessions and days
//  arrive as arguments instead of being fetched from `PlanStore.shared` and
//  `Matcher.shared`. That is the whole point — patch 330's twin passes the
//  database's weeks, the database's sessions and the database's days into the
//  identical code.
//
//  THE CUTOFF IS THE MOST LIKELY WAY TO GET SLICE 8 WRONG
//  ------------------------------------------------------
//  `weekPoints` skips weeks that have not begun — `startKey <= todayKey`.
//  Groundwork §7 named this before any code was written, because a twin that
//  applies a different cutoff, or reads a different clock, compares 34 weeks
//  against 2 and reports 32 phantom differences.
//
//  So `todayKey` is a PARAMETER. Neither this file nor its callers may reach
//  for `DayKey.key()`: the comparison must be able to hand both sides the same
//  day, and a function that reads the clock cannot be asked twice with the
//  same answer guaranteed. Same argument `Sub4Import` makes about `now`.
//
//  A CLOSURE FOR THE DAYS, NOT A DICTIONARY
//  ----------------------------------------
//  `day:` is `(String) -> MatchResolver.Day` rather than a prepared
//  `[String: MatchResolver.Day]`. The view resolves lazily, one key at a time,
//  and building a dictionary of every day of every begun week first would do
//  work the view does not do today — which would make this a performance
//  change as well as a move, and this patch is neither.
//
//  330 passes a closure backed by the database's days. It will also want to
//  know which days it was asked for that it did not have; that belongs in the
//  twin, not here.
//
//  `MainActor`, like `MatchResolver` and `SessionTally` — `Match` and
//  `Activity` are main-actor isolated, and this counts what a resolution
//  already produced.
//

import Foundation

@MainActor
enum TabSummary {

    // MARK: The Progress chart's series

    /// One begun week, as the chart draws it.
    ///
    /// `plannedKm` and `actualKm` are both RUNNING only, and that is not an
    /// oversight: they share an axis, and the planned figure is running
    /// kilometres because running is the only sport the plan gives distances
    /// for. Anything else here would be two quantities on one scale.
    struct WeekPoint: Identifiable, Equatable {
        let weekNo: Int
        let start: Date
        /// RUNNING only — see `PlanStore.plannedRunKm`.
        let plannedKm: Double
        let plannedExact: Bool
        /// RUNNING only, so the two are comparable.
        let actualKm: Double
        /// A MAXIMUM, not a sum — and therefore the most sensitive figure in
        /// this file. A missing activity moves it only if that activity was
        /// the longest, which is the one case an agreeing total would hide.
        let longestRunKm: Double
        let done: Int
        let total: Int

        var id: Int { weekNo }
    }

    /// Only weeks that have begun — a future week has nothing to say.
    ///
    /// `todayKey` is a parameter. See the header.
    static func weekPoints(weeks: [Week],
                           sessions: [Session],
                           todayKey: String,
                           day: (String) -> MatchResolver.Day) -> [WeekPoint] {
        weeks.compactMap { w -> WeekPoint? in
            guard let n = w.weekNo,
                  let startKey = w.startDate,
                  startKey <= todayKey,
                  let start = DayKey.date(startKey) else { return nil }

            var actual = 0.0, longest = 0.0
            var tally = SessionTally.Result()
            for offset in 0..<7 {
                guard let d = Calendar(identifier: .iso8601)
                        .date(byAdding: .day, value: offset, to: start) else { continue }
                let r = day(DayKey.key(d))

                // OPTIONAL AND REST EXCLUDED, and since 328 the rule lives in
                // `SessionTally` rather than on this line. §12.72.
                tally = tally + SessionTally.over(r.matches)

                // RUNS only. The planned figure this is charted against is
                // running kilometres, so anything else here would be comparing
                // two different quantities on one axis.
                for a in (r.matches.compactMap(\.activity) + r.extras)
                where a.discipline == .run {
                    actual += a.km
                    longest = max(longest, a.km)
                }
            }

            let planned = PlanStore.plannedRunKm(sessions: sessions, inWeek: w)
            return WeekPoint(weekNo: n, start: start,
                             plannedKm: planned.km,
                             plannedExact: planned.exact,
                             actualKm: actual, longestRunKm: longest,
                             done: tally.done, total: tally.total)
        }
    }

    // MARK: What was actually done, per discipline

    /// The four Progress rows' left-hand figures.
    ///
    /// Each sport in the unit the plan writes it in — km for running and
    /// swimming, hours for the bike, a count for strength — because forcing
    /// them into one unit means inventing a cycling speed. `PlanStore
    /// .PlanVolume`'s own header makes that argument and this is its other
    /// half.
    ///
    /// `runExact` is left at its default `true`: it describes a PLANNED
    /// figure's precision, and a recorded distance is measured. A caller
    /// comparing this against a planned volume must not read it.
    static func actualVolume(_ activities: [Activity]) -> PlanStore.PlanVolume {
        var v = PlanStore.PlanVolume()
        for a in activities where a.dayKey >= MatchRules.planStartDayKey {
            switch a.discipline {
            case .run:      v.runKm += a.km
            case .swim:     v.swimKm += a.km
            case .bike:     if a.isPlanEligible { v.bikeHours += Double(a.movingTime) / 3600 }
            case .strength: if a.isPlanEligible { v.strengthSessions += 1 }
            default:        break
            }
        }
        return v
    }

    // MARK: The Week tab's movement figures

    /// EXTRAS ARE COUNTED, and no other comparison in the project counts them.
    ///
    /// The Week card answers "how far did you actually move this week", which
    /// includes the commute, the walks and everything else the matcher left
    /// unmatched. That is a different question from adherence and from the
    /// chart's `actualKm`, both of which are about the plan.
    ///
    /// `runKm` is running only; `minutes` and `recorded` cover everything,
    /// because time and a count ARE comparable across sports and distance is
    /// not. `WeekView`'s own comment made that distinction and it moved here
    /// with the code.
    struct WeekActuals: Equatable {
        var runKm = 0.0
        /// **SECONDS, NOT MINUTES — patch 375, §12.119.**
        ///
        /// This field held minutes and was fed `a.minutes`, so a week of ten
        /// sessions could be nine minutes short and `WeekView` printed it.
        ///
        /// `minutes` below keeps every reader working unchanged — `WeekView`
        /// at 284 and 426, and `TabSummaryTests`, all still ask for minutes and
        /// still get them. Only the accumulation changed.
        var movingSeconds = 0
        var recorded = 0

        var minutes: Int { movingSeconds / 60 }
    }

    static func weekActuals(_ days: [MatchResolver.Day]) -> WeekActuals {
        var w = WeekActuals()
        for d in days {
            for a in d.matches.compactMap(\.activity) + d.extras {
                if a.discipline == .run { w.runKm += a.km }
                w.movingSeconds += a.movingTime
                w.recorded += 1
            }
        }
        return w
    }
}
