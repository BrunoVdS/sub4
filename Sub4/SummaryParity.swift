//
//  SummaryParity.swift
//  Sub4
//
//  The tab summaries, compared — D6c slice 8, patch 330, ADR-0003 §12.75.
//
//  THE LAST SLICE, AND THE FIRST THAT HOLDS ALMOST NOTHING
//  ------------------------------------------------------
//  Slices 1–5 all hold the plan from the app: `ShadowParity.matchReport` calls
//  `PlanStore.shared.sessions(on:)` for BOTH sides, and the screen says so —
//  *"Held from the app: the plan, the match decisions and the commute
//  decisions"*, with *"Of those, verified: the plan … by their read-backs"*
//  underneath. That is a division of labour, not an oversight: `PlanRoundTrip`
//  proves the plan is identical, and `MatchParity` proves the matching is
//  identical GIVEN a plan.
//
//  Slice 8 does not. Its database side reads the plan from
//  `PlanRepository.load`, so the planned figures are a real comparison rather
//  than the same input handed in twice. **It holds only the match decisions**,
//  which makes it the closest thing on that screen to what D7 will actually
//  do — and the reason the screen now carries two different answers to "where
//  does the plan come from". Decided 8 August; the `heldFromTheApp` line says
//  which slice does which so a reader is not left to infer it.
//
//  WHAT IT COMPARES
//  ----------------
//  Three things, and none of them is re-proving a finished slice:
//
//    the WeekPoint series   the Progress chart — planned km, actual km, the
//                           longest run, and done-of-total, per begun week
//    the volume rows        Run / Bike / Swim / Strength, actual and planned
//    the block tally        the "10 / 208" on the Progress card, summed from
//                           the week points rather than counted a third way
//
//  Day distances, week distances, CTL and the matcher are slices 2, 3 and 5 and
//  are NOT touched here. Groundwork §1.1 lists them; comparing them again would
//  triple the run time and produce a second answer to a settled question.
//
//  THE LONGEST RUN IS THE SENSITIVE ONE
//  ------------------------------------
//  It is a MAXIMUM, not a sum. Every other figure in this slice is a total, and
//  a total hides a swap: two activities of 10 + 10 and 4 + 16 agree on 20 km
//  and disagree on the longest run. It is also the figure the long-run
//  progression — the whole point of a marathon block — is read from.
//
//  THE CLOSURE HOLE, NAMED IN THE ADDENDUM BEFORE IT WAS BUILT
//  ----------------------------------------------------------
//  `TabSummary.weekPoints` takes `day: (String) -> MatchResolver.Day`. A
//  closure that returns an EMPTY day for a key the database has nothing for is
//  indistinguishable from a day that genuinely holds nothing — §12.15 inside a
//  lambda, where no `guard` can see it.
//
//  Every other count in this slice is per WEEK, so a handful of missing DAYS
//  would barely move any of them. So the closure counts: `daysAskedFor`, and
//  how many of those each side had anything for. Three figures, printed
//  unconditionally, and the only place a day-shaped hole could show.
//
//  A TOLERANCE, FOR THE SAME REASON AS SLICE 2
//  -------------------------------------------
//  `plannedKm`, `actualKm`, `longestRunKm` and three of the four volume rows
//  are sums of decimals, and two identical sums can end in a different last
//  digit. `done`, `total` and `strengthSessions` are `Int` and are compared
//  exactly — a tolerance on an integer would be an invitation.
//

import Foundation

@MainActor
enum SummaryParity {

    /// SHORTER THAN EVERY OTHER SLICE'S, and that is the finding. Slices 1–5
    /// hold the plan; this one reads it.
    static let heldFromTheApp = "the match decisions"

    /// `match_decision` holds no rows on the device, so there is nothing for a
    /// read-back to have verified. Stated rather than left blank — an empty
    /// string here would read as "everything is verified".
    static let verifiedByReadBack = "none — match_decision holds no rows"

    static let toleranceLabel = "1 m · 0.001 h"
    private static let distanceTolerance = 0.001      // km
    private static let hourTolerance = 0.001

    private static func close(_ a: Double, _ b: Double, _ t: Double) -> Bool {
        abs(a - b) <= t
    }

    // MARK: The report

    struct Report: Equatable {

        // MARK: Denominators

        var weeksInApp = 0
        var weeksInDatabase = 0
        var weeksCompared = 0
        /// Seven per week: start, plannedKm, plannedExact, actualKm,
        /// longestRunKm, done, total.
        var weekFieldsCompared = 0

        /// Four rows — run, bike, swim, strength.
        var volumeRowsCompared = 0
        /// Nine: four actual, four planned, and `runExact` on the planned side.
        var volumeFieldsCompared = 0

        /// The plan each side computed its planned figures from. Not a
        /// difference on its own — slice 6b owns that — but a slice that read
        /// 261 against 260 would produce week differences with no visible
        /// cause, and this is the line that gives it one.
        var planSessionsInApp = 0
        var planSessionsInDatabase = 0

        // MARK: The closure hole — see the header

        var daysAskedFor = 0
        var daysWithContentInApp = 0
        var daysWithContentInDatabase = 0

        // MARK: Differences

        /// "week 2 · actualKm", "week 5 · longestRunKm"
        var weekDifferences: [String] = []
        /// "run · planned", "bike · actual"
        var volumeDifferences: [String] = []
        var weeksOnlyInApp: [Int] = []
        var weeksOnlyInDatabase: [Int] = []

        /// "10 of 208 vs 10 of 208". Summed from the week points rather than
        /// counted a third way — the addendum's own instruction, because
        /// `Sessions 10/208` on the Progress card and `10 of 208` on the
        /// adherence line are already two paths to it.
        var blockLine = "—"
        var blockDiffers = false

        var totalCompared: Int { weeksCompared + volumeRowsCompared }

        var unexplained: Int {
            weekDifferences.count + volumeDifferences.count
            + weeksOnlyInApp.count + weeksOnlyInDatabase.count
            + (blockDiffers ? 1 : 0)
        }

        /// WEEKS, NOT `totalCompared`. The four volume rows are compared
        /// unconditionally — even on a device with nothing in it — so a
        /// `totalCompared > 0` test could never be false, and this slice would
        /// report a green tick having proved nothing. Groundwork §2.1: a check
        /// whose answer is always "healthy" is indistinguishable from a check
        /// that is broken.
        ///
        /// Zero begun weeks is a real state — before 27 July 2026 it was the
        /// only state — and the honest reading of it is "not looked at", not
        /// "agreed".
        var lookedAtSomething: Bool { weeksCompared > 0 }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else { return "nothing compared" }
            return unexplained == 0
                ? "\(weeksCompared) weeks · \(volumeRowsCompared) volume rows · no differences"
                : "\(totalCompared) compared · \(unexplained) differences"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        ///
        /// SAFE TO PASTE: week numbers, field names, counts and distances the
        /// plan itself states. Nothing the athlete wrote.
        var diagnosticLines: [String] {
            var lines: [String] = []
            lines.append("Summary parity: \(summary)")
            lines.append("  weeks in the app: \(weeksInApp)")
            lines.append("  weeks in the database: \(weeksInDatabase)")
            lines.append("  weeks compared: \(weeksCompared)")
            lines.append("  week fields compared: \(weekFieldsCompared)")
            lines.append("  plan sessions each side computed from: "
                         + "\(planSessionsInApp) vs \(planSessionsInDatabase)")
            lines.append("  days asked for: \(daysAskedFor)")
            // ONE LINE, "X vs Y" — patch 330a. It was two lines, and the
            // screen row beside it already said "5 vs 3". A paste that says
            // the same thing differently from the screen it was copied off is
            // a paste somebody has to translate, and the two-sided form is
            // what every other figure in this file uses.
            lines.append("  days with anything in each side: "
                         + "\(daysWithContentInApp) vs \(daysWithContentInDatabase)")
            lines.append("  volume rows compared: \(volumeRowsCompared)")
            lines.append("  volume fields compared: \(volumeFieldsCompared)")
            lines.append("  block sessions: \(blockLine)")
            lines.append("  weeks only in the app: \(weeksOnlyInApp.count)")
            lines.append("  weeks only in the database: \(weeksOnlyInDatabase.count)")
            lines.append("  week fields that differ: \(weekDifferences.count)")
            lines.append("  volume figures that differ: \(volumeDifferences.count)")
            lines.append("  tolerance: \(toleranceLabel)")
            lines.append("  held from the app: \(heldFromTheApp)")
            lines.append("  of those, verified: \(verifiedByReadBack)")
            lines.append("  unexplained differences: \(unexplained)")
            for d in weekDifferences.prefix(8) { lines.append("    \(d)") }
            if weekDifferences.count > 8 {
                lines.append("    + \(weekDifferences.count - 8) more")
            }
            for d in volumeDifferences.prefix(6) { lines.append("    \(d)") }
            return lines
        }
    }

    // MARK: The comparison

    /// EVERY FIGURE, NAMED. No reflection, as everywhere else.
    ///
    /// Takes BUILT summaries rather than the inputs to build them, like
    /// `VolumeParity` and `DetailParity`: the building is `TabSummary`'s, and
    /// a comparison that also built its own sides would be the second
    /// implementation §12.43 keeps costing this project.
    static func compare(app: [TabSummary.WeekPoint],
                        database: [TabSummary.WeekPoint],
                        appActual: PlanStore.PlanVolume,
                        databaseActual: PlanStore.PlanVolume,
                        appPlanned: PlanStore.PlanVolume,
                        databasePlanned: PlanStore.PlanVolume,
                        planSessionsInApp: Int,
                        planSessionsInDatabase: Int,
                        daysAskedFor: Int,
                        daysWithContentInApp: Int,
                        daysWithContentInDatabase: Int) -> Report {
        var r = Report()
        r.weeksInApp = app.count
        r.weeksInDatabase = database.count
        r.planSessionsInApp = planSessionsInApp
        r.planSessionsInDatabase = planSessionsInDatabase
        r.daysAskedFor = daysAskedFor
        r.daysWithContentInApp = daysWithContentInApp
        r.daysWithContentInDatabase = daysWithContentInDatabase

        // MARK: Week points, paired by week number

        let mine = Dictionary(app.map { ($0.weekNo, $0) },
                              uniquingKeysWith: { a, _ in a })
        let theirs = Dictionary(database.map { ($0.weekNo, $0) },
                                uniquingKeysWith: { a, _ in a })
        r.weeksOnlyInApp = Set(mine.keys).subtracting(theirs.keys).sorted()
        r.weeksOnlyInDatabase = Set(theirs.keys).subtracting(mine.keys).sorted()

        for no in Set(mine.keys).intersection(theirs.keys).sorted() {
            guard let a = mine[no], let b = theirs[no] else { continue }
            r.weeksCompared += 1
            r.weekFieldsCompared += 7

            let tag = "week \(no)"
            if a.start != b.start { r.weekDifferences.append("\(tag) · start") }
            if !close(a.plannedKm, b.plannedKm, distanceTolerance) {
                r.weekDifferences.append("\(tag) · plannedKm")
            }
            if a.plannedExact != b.plannedExact {
                r.weekDifferences.append("\(tag) · plannedExact")
            }
            if !close(a.actualKm, b.actualKm, distanceTolerance) {
                r.weekDifferences.append("\(tag) · actualKm")
            }
            // THE MAXIMUM. See the header — the one figure a total cannot hide.
            if !close(a.longestRunKm, b.longestRunKm, distanceTolerance) {
                r.weekDifferences.append("\(tag) · longestRunKm")
            }
            // INTEGERS, COMPARED EXACTLY.
            if a.done != b.done { r.weekDifferences.append("\(tag) · done") }
            if a.total != b.total { r.weekDifferences.append("\(tag) · total") }
        }

        // MARK: The block tally, summed from the week points

        let appDone = app.reduce(0) { $0 + $1.done }
        let appTotal = app.reduce(0) { $0 + $1.total }
        let dbDone = database.reduce(0) { $0 + $1.done }
        let dbTotal = database.reduce(0) { $0 + $1.total }
        r.blockLine = "\(appDone) of \(appTotal) vs \(dbDone) of \(dbTotal)"
        r.blockDiffers = appDone != dbDone || appTotal != dbTotal

        // MARK: The four volume rows

        r.volumeRowsCompared = 4
        r.volumeFieldsCompared = 9

        if !close(appActual.runKm, databaseActual.runKm, distanceTolerance) {
            r.volumeDifferences.append("run · actual")
        }
        if !close(appActual.bikeHours, databaseActual.bikeHours, hourTolerance) {
            r.volumeDifferences.append("bike · actual")
        }
        if !close(appActual.swimKm, databaseActual.swimKm, distanceTolerance) {
            r.volumeDifferences.append("swim · actual")
        }
        if appActual.strengthSessions != databaseActual.strengthSessions {
            r.volumeDifferences.append("strength · actual")
        }

        if !close(appPlanned.runKm, databasePlanned.runKm, distanceTolerance) {
            r.volumeDifferences.append("run · planned")
        }
        if !close(appPlanned.bikeHours, databasePlanned.bikeHours, hourTolerance) {
            r.volumeDifferences.append("bike · planned")
        }
        if !close(appPlanned.swimKm, databasePlanned.swimKm, distanceTolerance) {
            r.volumeDifferences.append("swim · planned")
        }
        if appPlanned.strengthSessions != databasePlanned.strengthSessions {
            r.volumeDifferences.append("strength · planned")
        }
        // `runExact` describes the PLANNED side only — a recorded distance is
        // measured, and `TabSummary.actualVolume` leaves it at its default for
        // that reason. Comparing it on the actual side would be comparing two
        // constants.
        if appPlanned.runExact != databasePlanned.runExact {
            r.volumeDifferences.append("run · plannedExact")
        }

        return r
    }
}
