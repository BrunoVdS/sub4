//
//  LoadParity.swift
//  Sub4
//
//  D6c slice 3 — fitness and load. Patch 315, ADR-0003 §12.59.
//
//  WHAT IT COMPARES
//  ----------------
//  Two `[DailyLoad]` series and the two fitness curves built from them. Every
//  day's state, every day's total, every scored workout's rung and figure, and
//  the CTL and ATL on top.
//
//  Both series come from ONE function — `LoadSeries.build`, extracted at 314 —
//  so nothing here is a second implementation of a four-hundred-day walk over a
//  four-rung scoring engine. The only things that differ between the two calls
//  are the activities and the traces.
//
//  WHAT IS HELD IDENTICAL, AND WHY THAT IS THE HONEST SHAPE
//  --------------------------------------------------------
//  Constants, FTP, sRPE and Apple Health's heart rates come from the APP on
//  both sides. Not because that is convenient — because:
//
//    · the database holds constants, FTP, notes and the plan in tables and has
//      no repository for any of them. Those are slices 5 and 6, and the
//      groundwork's slice order put this one before its own inputs (§12.58.3).
//    · Apple Health's heart rate is a cache of somebody else's store. No
//      database this app writes will ever hold it.
//
//  So this patch isolates exactly one variable: **what the database's
//  activities and traces produce.** `heldFromTheApp` is on screen and in the
//  paste, because a comparison that does not say what it held constant is a
//  comparison whose result cannot be interpreted.
//
//  THE DIFFERENCE THIS EXISTS TO FIND
//  ----------------------------------
//  D6a accepted a loss in the traces, in as many words on the Database screen:
//  *a stream that was shorter than the distance axis comes back padded with
//  zeros and its original length is gone.*
//
//  `LoadEngine` scores from the trace when it has one and falls back to the
//  session average when it cannot. So a padded trace can change which RUNG a
//  session is scored on, which changes its figure, which changes a day, which
//  changes the curve. **Nothing has ever asked whether that accepted loss costs
//  a number the athlete reads.** `workoutsWithDifferentSource` is the row that
//  asks.
//
//  That is also what makes this a comparison with a real way to fail, which
//  groundwork §2.1 demands of every one of them.
//
//  A TOLERANCE, FOR THE REASON §12.57.3 GIVES
//  ------------------------------------------
//  TRIMP is a sum of doubles. A hundredth of a TRIMP is four decimal places
//  below anything this app displays; a difference that small is arithmetic, not
//  data. Printed on screen beside the verdict, because a threshold nobody can
//  see is a threshold nobody can argue with.
//
//  `DayState` is compared EXACTLY. A rest and a gap both carry a load of zero
//  and the state is the only thing between them (§12.58.4), so a tolerance
//  there would erase the distinction this whole engine is built around.
//

import Foundation

@MainActor
enum LoadParity {

    /// Four decimal places below anything displayed.
    static let trimpTolerance = 0.01

    /// On screen, so the threshold is a number rather than a hidden `==`.
    static let toleranceLabel = "0.01 TRIMP"

    /// What both sides take from the app rather than from the database, and
    /// therefore what this comparison cannot see. Printed, not implied.
    static let heldFromTheApp =
        "constants, FTP, sRPE and Apple Health"

    private static func close(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= trimpTolerance
    }

    // MARK: The report

    struct Report: Equatable {

        // Denominators — groundwork §2.1 case 2.

        /// Days in the app's series and in the twin's. They should match: both
        /// walks run from the same cutoff to the same today.
        let appDays: Int
        let databaseDays: Int
        let daysCompared: Int
        /// Every scored or unscored workout present on both sides. THE deep
        /// denominator, and the equivalent of `samplesWalked` for this slice —
        /// §12.39.6.1. Days can agree while every workout inside them differs.
        let workoutsCompared: Int
        /// Traces each side had to score from. A twin with no traces would
        /// agree on every day that scored from a session average and would be
        /// describing nothing.
        let appTraces: Int
        let databaseTraces: Int

        // Differences

        /// Compared EXACTLY. A rest and a gap both carry zero.
        let daysWithDifferentState: [String]
        let daysWithDifferentLoad: [String]
        /// THE ROW THIS SLICE EXISTS FOR. A workout scored from the trace on
        /// one side and from the session average on the other means the
        /// database's copy of that trace could not carry it.
        let workoutsWithDifferentSource: [String]
        let workoutsWithDifferentFigure: [String]

        // The curve

        let pointsCompared: Int
        let pointsWithDifferentFitness: Int
        let appFitness: Double?
        let databaseFitness: Double?
        let appFatigue: Double?
        let databaseFatigue: Double?

        var unexplained: Int {
            daysWithDifferentState.count + daysWithDifferentLoad.count
            + workoutsWithDifferentSource.count + workoutsWithDifferentFigure.count
            + pointsWithDifferentFitness
            + (appDays == databaseDays ? 0 : 1)
        }

        /// Zero days compared to zero days agrees perfectly and proves nothing.
        /// `workoutsCompared` is in here too: a series of four hundred rest
        /// days would satisfy the first test and describe no training at all.
        var lookedAtSomething: Bool { daysCompared > 0 && workoutsCompared > 0 }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else {
                return "nothing compared — \(daysCompared) days, "
                     + "\(workoutsCompared) sessions"
            }
            return unexplained == 0
                ? "\(daysCompared) days · \(workoutsCompared) sessions · no differences"
                : "\(daysCompared) days · \(unexplained) differences"
        }

        /// Fitness and fatigue, rounded the way the screens round them, so a
        /// reader can hold this against the Progress tab.
        var fitnessLine: String {
            guard let a = appFitness, let d = databaseFitness else { return "no curve" }
            return "\(Int(a.rounded())) vs \(Int(d.rounded()))"
        }

        var fatigueLine: String {
            guard let a = appFatigue, let d = databaseFatigue else { return "no curve" }
            return "\(Int(a.rounded())) vs \(Int(d.rounded()))"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        /// Day keys and counts only; no session names and no activity ids.
        var diagnosticLines: [String] {
            var lines = [
                "Load parity: \(daysCompared) days, \(workoutsCompared) sessions",
                "  held from the app: \(heldFromTheApp)",
                "  tolerance: \(toleranceLabel)",
                "  days in the app's series: \(appDays)",
                "  days in the database's series: \(databaseDays)",
                "  traces the app scored from: \(appTraces)",
                "  traces the database scored from: \(databaseTraces)",
                "  days with a different state: \(daysWithDifferentState.count)",
                "  days with a different total: \(daysWithDifferentLoad.count)",
                "  sessions scored from a different rung: "
                + "\(workoutsWithDifferentSource.count)",
                "  sessions with a different figure: "
                + "\(workoutsWithDifferentFigure.count)",
                "  curve points compared: \(pointsCompared)",
                "  curve points that disagree: \(pointsWithDifferentFitness)",
                "  fitness: \(fitnessLine)",
                "  fatigue: \(fatigueLine)",
                "  unexplained differences: \(unexplained)"]
            // NAMED, NOT JUST COUNTED — §12.39's rule. Capped, and the cap says
            // so rather than truncating silently.
            for d in daysWithDifferentState.prefix(5) { lines.append("    state \(d)") }
            if daysWithDifferentState.count > 5 {
                lines.append("    + \(daysWithDifferentState.count - 5) more days")
            }
            for d in daysWithDifferentLoad.prefix(5) { lines.append("    total \(d)") }
            if daysWithDifferentLoad.count > 5 {
                lines.append("    + \(daysWithDifferentLoad.count - 5) more days")
            }
            return lines
        }
    }

    // MARK: The comparison

    /// Both series handed in, both built by `LoadSeries.build`.
    ///
    /// STATIC AND TAKING ITS INPUTS, like the other two slices, so a test can
    /// build the two sides from genuinely different places.
    static func compare(app: [DailyLoad], database: [DailyLoad]) -> Report {

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`. The walk
        // cannot produce a duplicate day, and a dictionary initialiser that
        // TRAPS on data is not a thing a diagnostic should be able to do.
        let mine = Dictionary(app.map { ($0.dayKey, $0) },
                              uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(database.map { ($0.dayKey, $0) },
                                uniquingKeysWith: { first, _ in first })
        let shared = Set(mine.keys).intersection(theirs.keys).sorted()

        var differentState: [String] = []
        var differentLoad: [String] = []
        var differentSource: [String] = []
        var differentFigure: [String] = []
        var workouts = 0

        for day in shared {
            guard let a = mine[day], let d = theirs[day] else { continue }

            // EXACTLY. A rest and a gap both carry zero, and the state is the
            // only thing between them — §12.58.4.
            if a.state != d.state { differentState.append(day) }
            if !close(a.load, d.load) { differentLoad.append(day) }

            let theirWorkouts = Dictionary(d.workouts.map { ($0.activityId, $0) },
                                           uniquingKeysWith: { first, _ in first })
            for w in a.workouts {
                guard let t = theirWorkouts[w.activityId] else { continue }
                workouts += 1
                // THE ROW THIS SLICE EXISTS FOR. `.stream` on one side and
                // `.average` on the other is the accepted trace loss costing a
                // number, which nothing has ever tested for.
                if w.source != t.source { differentSource.append(w.activityId) }
                else if !close(w.trimp, t.trimp) { differentFigure.append(w.activityId) }
            }
        }

        // THE CURVE, over the whole series rather than only its last point. A
        // difference in March that has decayed away by August would be
        // invisible in the headline and is still a difference.
        let appPoints = PMC.build(app)
        let dbPoints = PMC.build(database)
        var pointsDiffering = 0
        for i in 0 ..< min(appPoints.count, dbPoints.count)
        where !close(appPoints[i].ctl, dbPoints[i].ctl) {
            pointsDiffering += 1
        }

        return Report(
            appDays: app.count,
            databaseDays: database.count,
            daysCompared: shared.count,
            workoutsCompared: workouts,
            appTraces: app.reduce(0) { $0 + $1.workouts.filter { $0.source == .stream }.count },
            databaseTraces: database.reduce(0) { $0 + $1.workouts.filter { $0.source == .stream }.count },
            daysWithDifferentState: differentState,
            daysWithDifferentLoad: differentLoad,
            workoutsWithDifferentSource: differentSource.sorted(),
            workoutsWithDifferentFigure: differentFigure.sorted(),
            pointsCompared: min(appPoints.count, dbPoints.count),
            pointsWithDifferentFitness: pointsDiffering,
            appFitness: appPoints.last?.ctl,
            databaseFitness: dbPoints.last?.ctl,
            appFatigue: appPoints.last?.atl,
            databaseFatigue: dbPoints.last?.atl)
    }
}
