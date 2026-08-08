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
//  Constants, zones, FTP, sRPE and Apple Health's heart rates come from the APP
//  on both sides. Not because that is convenient — because:
//
//    · the database holds constants, FTP, notes and the plan in tables and had
//      no repository for any of them at 315. Those are slices 5 and 6, and the
//      groundwork's slice order put this one before its own inputs (§12.58.3).
//    · Apple Health's heart rate is a cache of somebody else's store. No
//      database this app writes will ever hold it.
//
//  PATCH 317 CHANGED WHAT THAT SENTENCE COSTS, WITHOUT CHANGING THE SHAPE.
//  `AthleteRepository` now reads the profile, the resting series and the zones
//  back out and compares them field by field on the Database screen. Three of
//  the five held inputs — constants, zones and FTP — are therefore VERIFIED to
//  be the same on both sides rather than merely assumed to be.
//
//  They are still taken from the app here, deliberately. Feeding the twin the
//  database's constants would make a difference in the fitness rows mean
//  EITHER the trace OR the constants, and the screen could not say which.
//  Verifying them separately keeps this comparison's single cause and closes
//  the same gap — which is why `verifiedByReadBack` is printed beside
//  `heldFromTheApp` rather than replacing it.
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
//  THE HISTOGRAM, AND A CORRECTION TO WHY — patch 316
//  --------------------------------------------------
//  `WorkoutLoad.hrSeconds` is seconds per heart rate, and it is the whole input
//  to `ZoneTotals` — the Time-in-zone card. 315 did not compare it.
//
//  THE ARGUMENT FOR ADDING IT WAS WRONG THE FIRST TIME, and the wrong version
//  is worth keeping because it is a shape this project keeps meeting. It was:
//  *TRIMP is an integral, the histogram is the distribution under it, and two
//  distributions can integrate to the same number.* That reads like §12.16 and
//  it is false here. Both come from ONE walk over ONE set of bins:
//
//      TRIMP     = Σ (dt/60) × f(bpm)
//      histogram = Σ dt,  keyed by round(bpm)
//
//  The histogram DETERMINES the TRIMP. Move a minute from 140 bpm to 160 and
//  the integral moves 2.3% — hundreds of times the tolerance — because `f` is
//  exponential. 315 would already have caught every case the first argument
//  described.
//
//  **Do not reason by analogy about two numbers without checking whether one
//  determines the other.** §12.43's cousin.
//
//  WHAT IS ACTUALLY LEFT, AND IT IS NARROW
//  ---------------------------------------
//  One gap: the integral uses the EXACT heart rate and the histogram ROUNDS it.
//  A trace differing by two hundredths of a bpm on one bin moves that bin into
//  the next bucket while moving TRIMP by about 0.0015 — under the tolerance. If
//  the bucket sits on a zone boundary, a minute crosses zones and the card
//  moves while every figure in 315 agrees. `aRoundingDifferenceMovesAZone`
//  builds exactly that.
//
//  AND ONE THING THAT IS NOT NARROW: until now the Time-in-zone card was
//  covered by INFERENCE — the TRIMP agrees, so the histogram must. That holds
//  only while both come from one walk. It breaks silently the day the trace
//  rung gains a second path or the two guards drift apart, and an inference
//  that breaks silently is the thing this file exists to replace with a number.
//
//  THE ZONES ARE HELD FROM THE APP, like the constants. `hr_zone` is in the
//  database and has no reader yet, and bucketing both sides with the SAME zones
//  is what makes a difference here mean the trace rather than the boundaries.
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

    /// One hundredth of a second, per heart rate. `hrSeconds` is a sum of
    /// `binWidth / speed` terms, so it carries the same summation residue the
    /// TRIMP does and gets the same treatment.
    static let secondTolerance = 0.01

    /// On screen, so the threshold is a number rather than a hidden `==`.
    static let toleranceLabel = "0.01 TRIMP · 0.01 s"

    /// What both sides take from the app rather than from the database, and
    /// therefore what this comparison cannot see. Printed, not implied.
    static let heldFromTheApp =
        "constants, zones, FTP, sRPE and Apple Health"

    /// Of those five, the three the athlete read-back now checks — patch 317.
    ///
    /// A SEPARATE STRING RATHER THAN AN EDIT TO THE ONE ABOVE. What this
    /// comparison holds constant did not change; what is known about those
    /// constants did. Collapsing the two would lose the distinction between
    /// "not varied here" and "proven identical", and the second is a claim
    /// that has to be earned by something on screen.
    ///
    /// PATCH 322 ADDED sRPE, AND THE QUALIFIER IS NOT DECORATION. The figure
    /// is `note.rpe × DataCorrections.scoringSeconds(a) / 60`, keyed by the
    /// activity the matcher picked, for the session the plan dated. After 322
    /// each of those is settled EXCEPT the plan:
    ///
    ///   · `note.rpe`       read back and compared, patch 322.
    ///   · `scoringSeconds` compile-time constants in the binary, not rows.
    ///                      The two sides cannot differ; nothing to read.
    ///   · the matcher      proven at 321, §12.64.
    ///   · the plan         held identically on both sides, so it cannot
    ///                      differ. VERIFIED SINCE 323 — the plan read-back
    ///                      compares all 260 sessions field by field, so the
    ///                      caveat this line carried from 322 is gone and the
    ///                      sentence stops at "sRPE".
    ///
    /// Apple Health is not in it and never will be: its heart rate is a cache
    /// of somebody else's store that no database this app writes will hold.
    static let verifiedByReadBack = "constants, zones, FTP and sRPE"

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

        // The shape under the number — patch 316.

        /// Heart-rate buckets walked across every session that carried a
        /// histogram on both sides. The DEEPEST denominator this project has:
        /// one entry per distinct bpm per session, so a year of traces is tens
        /// of thousands of comparisons. `samplesWalked` (§12.39.6.1) three
        /// slices later.
        let hrBucketsCompared: Int
        /// Sessions whose distribution differs while the integral may not.
        let workoutsWithDifferentHistogram: [String]

        // Time in zone, summed over the whole history from those histograms.

        /// Seconds per zone, app against database. Compared per zone rather
        /// than as a total, because two zones can move in opposite directions
        /// and leave the total untouched.
        let zonesCompared: Int
        let zonesDiffering: [Int]
        /// Sessions the card counts and sessions it has to leave out. Both are
        /// on the card, so both are compared.
        let zoneTracedApp: Int
        let zoneTracedDatabase: Int
        let zoneUntracedApp: Int
        let zoneUntracedDatabase: Int

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
            + workoutsWithDifferentHistogram.count + zonesDiffering.count
            + (zoneTracedApp == zoneTracedDatabase ? 0 : 1)
            + (zoneUntracedApp == zoneUntracedDatabase ? 0 : 1)
            + (appDays == databaseDays ? 0 : 1)
        }

        /// Zero days compared to zero days agrees perfectly and proves nothing.
        /// `workoutsCompared` is in here too: a series of four hundred rest
        /// days would satisfy the first test and describe no training at all.
        /// `hrBucketsCompared` is deliberately NOT in here. A history with no
        /// traces at all is a legitimate state — a phone with no strap — and
        /// requiring buckets would make this screen call that broken. The
        /// bucket count is printed instead, so a reader can see whether the
        /// distribution half looked at anything.
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
                "  of those, verified: \(verifiedByReadBack)",
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
                "  heart-rate buckets compared: \(hrBucketsCompared)",
                "  sessions with a different distribution: "
                + "\(workoutsWithDifferentHistogram.count)",
                "  zones compared: \(zonesCompared)",
                "  zones that disagree: \(zonesDiffering.count)",
                "  sessions in the zone card: \(zoneTracedApp) vs \(zoneTracedDatabase)",
                "  sessions it left out: \(zoneUntracedApp) vs \(zoneUntracedDatabase)",
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
    /// `zones` and `today` are handed in and used for BOTH sides. Bucketing
    /// with the same boundaries is what makes a difference in the zone rows
    /// mean the trace rather than the zone edit, and passing `today` keeps a
    /// test off the machine's clock (§12.48.5).
    static func compare(app: [DailyLoad], database: [DailyLoad],
                        zones: [AthleteStore.HRZone] = [],
                        today: String = DayKey.key()) -> Report {

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
        var differentHistogram: [String] = []
        var buckets = 0
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

                // THE SHAPE, NOT THE INTEGRAL — patch 316. Compared over the
                // UNION of both sides' heart rates, so a bucket present on one
                // side only is a difference rather than something quietly not
                // walked.
                //
                // Only where both sides carry a distribution: a session that
                // moved rung has already been reported once, and its missing
                // histogram is that same fault seen again.
                if w.hasZoneDistribution, t.hasZoneDistribution {
                    var histogramDiffers = false
                    for bpm in Set(w.hrSeconds.keys).union(t.hrSeconds.keys) {
                        buckets += 1
                        if abs((w.hrSeconds[bpm] ?? 0) - (t.hrSeconds[bpm] ?? 0))
                            > secondTolerance {
                            histogramDiffers = true
                        }
                    }
                    if histogramDiffers { differentHistogram.append(w.activityId) }
                }
            }
        }

        // TIME IN ZONE, over the whole history, from the histograms above.
        //
        // ONE FUNCTION, CALLED TWICE — `ZoneTotals.build` is the call
        // `ProgressTabView` makes, so this compares what is on the card rather
        // than something adjacent to it. `.all` because a 30-day window would
        // leave twelve months unexamined, which is §12.57.2's mistake.
        //
        // 316a: this named the FILE rather than the type. ZoneTime.swift holds
        // `ZoneTotals`. A signature was read and its enclosing type inferred
        // from the filename — §12.60.1's lesson, one line lower down.
        let myZones = ZoneTotals.build(days: app, zones: zones, window: .all, today: today)
        let theirZones = ZoneTotals.build(days: database, zones: zones,
                                        window: .all, today: today)
        let zoneKeys = Set(myZones.seconds.keys).union(theirZones.seconds.keys).sorted()
        let zonesDiffering = zoneKeys.filter {
            abs((myZones.seconds[$0] ?? 0) - (theirZones.seconds[$0] ?? 0)) > secondTolerance
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
            hrBucketsCompared: buckets,
            workoutsWithDifferentHistogram: differentHistogram.sorted(),
            zonesCompared: zoneKeys.count,
            zonesDiffering: zonesDiffering,
            zoneTracedApp: myZones.traced,
            zoneTracedDatabase: theirZones.traced,
            zoneUntracedApp: myZones.untraced,
            zoneUntracedDatabase: theirZones.untraced,
            pointsCompared: min(appPoints.count, dbPoints.count),
            pointsWithDifferentFitness: pointsDiffering,
            appFitness: appPoints.last?.ctl,
            databaseFitness: dbPoints.last?.ctl,
            appFatigue: appPoints.last?.atl,
            databaseFatigue: dbPoints.last?.atl)
    }
}
