//
//  VolumeParity.swift
//  Sub4
//
//  D6c slice 2 — daily and weekly distance. Patch 313,
//  `D6C-SHADOW-PARITY-GROUNDWORK.md` §6.2, ADR-0003 §12.57.
//
//  WHAT SLICE 2 COMPARES, AND WHY THESE THREE
//  ------------------------------------------
//  Slice 1 proved both sides derive the same LIST. This asks the next question:
//  do the numbers computed FROM that list agree?
//
//    1. `DayDistance.of` — one day's distance. Not a sum: patch 249 made it
//       refuse to add kilometres across sports, so it answers `.km(13.3, .bike)`
//       or `.minutes(74)` or `.none`. A day where one side says kilometres and
//       the other says minutes is a difference no field comparison could ever
//       see, because every field on every activity would agree.
//
//    2. `VolumeSeries.recordedByWeek` — training and commute volume per ISO
//       week, per discipline, per unit. Three disciplines times two units times
//       every week in the history, which is where the denominator comes from.
//
//    3. `VolumeSeries.mix` — the whole history split into six bands in both
//       units. The one volume figure in this app with no clock in it, and what
//       four of the ⓘ notes quote their percentages from.
//
//  WHAT IT DOES NOT COMPARE, AND WHY NOT YET
//  -----------------------------------------
//  **The plan's prescription.** `VolumeSeries.weeks` returns a planned figure
//  beside the recorded one, and that half reads `PlanStore` — slice 5. Only the
//  recorded half belongs to this slice, which is why 313 extracted exactly that
//  and left the rest of `weeks()` alone.
//
//  **Anything on a rolling window.** `markers` and `totals` are 30 days back
//  from `Date()`. They are comparable — both sides would be asked at the same
//  instant — but a clean answer would describe one month and say nothing about
//  the other twelve. The whole-history figures above cover them.
//
//  A TOLERANCE, STATED RATHER THAN HIDDEN
//  --------------------------------------
//  Both sides sum the same doubles from lists `settle` put in the same order,
//  so exact equality should hold today. **Should is not a mechanism** — §12.49
//  cost a patch to learn that. One reordering anywhere upstream and `==` starts
//  reporting 1e-15 as a data difference, and the first time a gate cries wolf
//  is the last time anybody reads it.
//
//  So a difference under **one metre** or **one second** is floating-point
//  summation, not data. Both numbers are on screen beside the verdict, because
//  a threshold nobody can see is a threshold nobody can argue with.
//
//  Integers are compared exactly. `DayDistance.minutes` and `.none(minutes:)`
//  are `Int`, and a tolerance on an integer would be an invitation.
//

import Foundation

@MainActor
enum VolumeParity {

    // MARK: The tolerance

    /// One metre. Below this, a difference in kilometres is how two identical
    /// sums of doubles ended up in a different last bit.
    static let kilometreTolerance = 0.001

    /// One second, in hours.
    static let hourTolerance = 1.0 / 3_600

    /// On screen, so the threshold is a number rather than a hidden `==`.
    static let toleranceLabel = "1 m · 1 s"

    private static func close(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
        abs(a - b) <= tolerance
    }

    private static func tolerance(for unit: VolumeUnit) -> Double {
        unit == .km ? kilometreTolerance : hourTolerance
    }

    /// `DayDistance` holds a `Double` in one of its three cases, so its
    /// synthesised `==` is exact. Compared here instead, with the discipline
    /// held exactly and only the distance given room.
    ///
    /// THE CASE ITSELF MUST MATCH. `.km(0, .run)` and `.none(minutes: 0)` are
    /// different answers to "what did this day add up to", and collapsing them
    /// would hide the defect patch 249 exists to prevent.
    static func same(_ a: DayDistance, _ b: DayDistance) -> Bool {
        switch (a, b) {
        case let (.km(x, dx), .km(y, dy)):
            dx == dy && close(x, y, kilometreTolerance)
        case let (.minutes(x), .minutes(y)):
            x == y
        case let (.none(x), .none(y)):
            x == y
        default:
            false
        }
    }

    // MARK: The report

    struct Report: Equatable {

        /// Days both sides hold. Days only one side has are slice 1's answer
        /// and are not repeated here — one question, one place.
        let daysCompared: Int
        let daysDiffering: [String]

        /// Three disciplines × two units × every week in the history.
        let weekValuesCompared: Int
        /// `2026-04-20 · run · km`
        let weeksDiffering: [String]

        /// Six bands × two units.
        let bandsCompared: Int
        /// `bike km`
        let bandsDiffering: [String]

        /// `VolumeMix.firstDayKey` — where the history is said to start. It is
        /// printed in four ⓘ notes as "since July 2025", so a disagreement
        /// changes a sentence rather than a number.
        let historyStartAgrees: Bool

        var unexplained: Int {
            daysDiffering.count + weeksDiffering.count + bandsDiffering.count
            + (historyStartAgrees ? 0 : 1)
        }

        /// The guard against agreeing about nothing — the same argument slice 1
        /// makes, applied to three denominators instead of one.
        var lookedAtSomething: Bool {
            daysCompared > 0 && weekValuesCompared > 0 && bandsCompared > 0
        }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else {
                return "nothing compared — \(daysCompared) days, "
                     + "\(weekValuesCompared) week figures, \(bandsCompared) bands"
            }
            let total = daysCompared + weekValuesCompared + bandsCompared
            return unexplained == 0
                ? "\(total) figures · no differences"
                : "\(total) figures · \(unexplained) differences"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        /// Day keys and week keys are dates of training days, which this paste
        /// already carries in the roster and ledger lines; no names, no ids, no
        /// distances.
        var diagnosticLines: [String] {
            var lines = [
                "Volume parity: \(daysCompared) days, \(weekValuesCompared) "
                + "week figures, \(bandsCompared) bands",
                "  tolerance: \(toleranceLabel)",
                "  days that disagree: \(daysDiffering.count)",
                "  week figures that disagree: \(weeksDiffering.count)",
                "  history bands that disagree: \(bandsDiffering.count)",
                "  the history starts on the same day: \(historyStartAgrees ? "yes" : "no")",
                "  unexplained differences: \(unexplained)"]
            // NAMED, NOT JUST COUNTED — §12.39's rule. "12 differ" sends
            // somebody through twelve; "12 differ, all on bike km" is usually a
            // one-line fix. Capped, and the cap says so rather than truncating
            // silently.
            for d in daysDiffering.prefix(5) { lines.append("    day \(d)") }
            if daysDiffering.count > 5 {
                lines.append("    + \(daysDiffering.count - 5) more days")
            }
            for w in weeksDiffering.prefix(5) { lines.append("    week \(w)") }
            if weeksDiffering.count > 5 {
                lines.append("    + \(weeksDiffering.count - 5) more week figures")
            }
            for b in bandsDiffering { lines.append("    band \(b)") }
            return lines
        }
    }

    // MARK: The comparison

    /// Both sides handed in, already settled by `ActivityRoster`.
    ///
    /// STATIC AND TAKING ITS INPUTS, for the reason slice 1 states: a test can
    /// then build the two sides from genuinely different places, which is the
    /// only answer there is to "both sides are secretly the same object".
    static func compare(store: [Activity], database: [Activity]) -> Report {

        // MARK: One day at a time

        // THE SAME FUNCTION ON BOTH SIDES. `byDay` moved into `ActivityRoster`
        // at 312 for exactly this, and `DayDistance.of` was already shared —
        // it needed no move, which is what a rule looks like when it was
        // written in the right place the first time.
        let myDays = ActivityRoster.byDay(store)
        let theirDays = ActivityRoster.byDay(database)
        let sharedDays = Set(myDays.keys).intersection(theirDays.keys)
        let daysDiffering = sharedDays.filter {
            !same(DayDistance.of(myDays[$0] ?? []),
                  DayDistance.of(theirDays[$0] ?? []))
        }.sorted()

        // MARK: One week, one discipline, one unit at a time

        var weekValues = 0
        var weeksDiffering: [String] = []
        for metric in VolumeMetric.allCases {
            for unit in VolumeUnit.allCases {
                let mine = VolumeSeries.recordedByWeek(store, metric: metric, unit: unit)
                let theirs = VolumeSeries.recordedByWeek(database, metric: metric, unit: unit)
                // The UNION, not the intersection. A week present on one side
                // only is the difference most worth reporting, and comparing
                // only shared weeks would be the version that cannot see it.
                for key in Set(mine.keys).union(theirs.keys).sorted() {
                    weekValues += 1
                    let a = mine[key] ?? RecordedWeek()
                    let b = theirs[key] ?? RecordedWeek()
                    let t = tolerance(for: unit)
                    if !close(a.training, b.training, t) || !close(a.commute, b.commute, t) {
                        weeksDiffering.append("\(key) · \(metric.rawValue) · \(unit.rawValue)")
                    }
                }
            }
        }

        // MARK: The whole history, by band

        let myMix = VolumeSeries.mix(store)
        let theirMix = VolumeSeries.mix(database)
        var bands = 0
        var bandsDiffering: [String] = []
        for band in VolumeSegment.allCases {
            bands += 2
            if !close(myMix.km[band] ?? 0, theirMix.km[band] ?? 0, kilometreTolerance) {
                bandsDiffering.append("\(band.rawValue) km")
            }
            if !close(myMix.hours[band] ?? 0, theirMix.hours[band] ?? 0, hourTolerance) {
                bandsDiffering.append("\(band.rawValue) hours")
            }
        }

        return Report(daysCompared: sharedDays.count,
                      daysDiffering: daysDiffering,
                      weekValuesCompared: weekValues,
                      weeksDiffering: weeksDiffering,
                      bandsCompared: bands,
                      bandsDiffering: bandsDiffering,
                      historyStartAgrees: myMix.firstDayKey == theirMix.firstDayKey)
    }
}
