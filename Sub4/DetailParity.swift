//
//  DetailParity.swift
//  Sub4
//
//  D6c slice 4 — details, splits and laps. Patch 320, ADR-0003 §12.63.
//
//  THE DIFFERENCE BETWEEN THIS AND THE READ-BACK ABOVE IT
//  ------------------------------------------------------
//  291 and 295 compared every FIELD of every detail: calories, the polyline,
//  each split's distance and moving time, each lap, each best effort. That
//  question is answered.
//
//  This asks the other one. `ActivityDetail` carries a family of DERIVED
//  figures — `overallPace`, `medianSplitPace`, `fastestSplit`,
//  `closingPace(km:)`, `openingPace(km:)`, `bestWindowPace(km:)` — and
//  `PaceTarget.measured` switches over four of them to produce the sentence on
//  the activity screen: *"5:57 — faster than asked"*. **Nothing has ever asked
//  whether the database's copy produces the same sentence.**
//
//  Equal fields should imply equal derivations. They do, by construction, if
//  and only if every field that feeds a derivation is one of the fields that
//  was compared — and that is a claim about coverage, not a theorem. §12.16's
//  warning is that equal counts can hide changed values; this is the same
//  warning one level up, where equal values are assumed to imply equal answers.
//
//  NOTHING HERE IS A SECOND IMPLEMENTATION
//  ---------------------------------------
//  Every figure below is read off `ActivityDetail`'s own properties, and the
//  lap reading is `IntervalDetector.fromLaps` — the app's own function, called
//  twice. §12.43, sixth application. A parity file that re-derived a closing
//  pace would eventually disagree with the screen, and no test could say which
//  was right.
//
//  THE PLAN IS NOT CONSULTED, AND THAT IS A CHOICE
//  -----------------------------------------------
//  `IntervalDetector.fromLaps` takes an optional `IntervalPlan`, which narrows
//  the work laps by the plan's cut pace. It is passed **nil** here.
//
//  Getting a real plan means `Matcher.day()` → `Session` → `IntervalPlan.from`,
//  and `Matcher` is slice 5 — groundwork §8 names that dependency as the one
//  it had not investigated. Passing nil keeps slice 4's answer about the LAPS
//  and nothing else, at the cost of leaving the cut-pace filter unexercised.
//  That limit is on screen rather than in this comment only, because a
//  comparison that does not say what it left out is a comparison whose result
//  cannot be read.
//
//  WHAT THE WINDOW SIZES ARE, AND WHY THOSE
//  ----------------------------------------
//  `PaceTarget.Kind` carries its own `n` from the plan — "last 4 km at MP",
//  "2×4 km @5:38–5:43". The windows here are the ones the plan actually writes,
//  plus 1 km, which every detail with a single complete split can answer.
//
//  Without the 1 km entries the denominator would be dominated by nils on short
//  sessions, and **a figure that is nil on both sides agrees perfectly while
//  proving nothing** — which is why `paceFiguresAnswered` is counted separately
//  from `paceFiguresCompared` and is what `lookedAtSomething` actually tests.
//  §12.54.2, one level deeper than the row it was written for.
//
//  THE ACCEPTED LOSS THIS IS POSITIONED TO FIND — AND IT FOUND IT
//  --------------------------------------------------------------
//  D6a accepted one: the importer's `positiveOrNil` turns a zero average heart
//  rate into nothing, on twelve details, for BOTH `split.averageHR` and
//  `lap.averageHR` (`Sub4Import+Recording` lines 218 and 229). The read-back
//  reports it as a field difference and always will.
//
//  The first version of this file argued that `hasHRSplits` was the only
//  derived property reading `averageHR`, so the loss could cost nothing. **That
//  was true of `ActivityDetail`'s own properties and false of the derivation
//  chain**, and the device said so on the first run: 16 of 1,141 reps differed.
//  `IntervalDetector.fromLaps` copies `lap.averageHR` straight into
//  `RepSplit.avgHR`, which the lap table draws — §12.63.8.
//
//  SO THE RULE IS THE READER'S, NOT THE CARRIER'S. Every consumer of a heart
//  rate in this app guards it: `SplitTables` asks `hr > 0` at the kilometre
//  table (line 194) and at the lap table (line 336), and `hasHRSplits` asks
//  `($0.averageHR ?? 0) > 0`. A stored zero and a missing value are the same
//  pixel everywhere.
//
//  `shownHR` compares what is drawn. What is CARRIED differently and drawn the
//  same is counted separately and printed dim — because a difference that
//  vanishes from the screen when it stops being a fault is §12.54.2's defect,
//  and because the day one of those 16 becomes a real 148-versus-nothing is the
//  day the two counters part company.
//

import Foundation

/// The detail and trace files, read WITHOUT asking the store that serves them —
/// patch 390, D7 slice B4. `ActivitySource` at 381 is the direct precedent and
/// §12.126.3 made its rule general: **a read-back gets its own read in the slice
/// that hydrates its own store.**
///
/// **THE ORDER IS THE POINT, AND IT IS 381's ARGUMENT VERBATIM.** 392 hydrates
/// `DetailStore` from the database. Three comparisons take their app side from
/// that store — Compare's slice 4, the Details read-back and the Recordings
/// read-back — and all three would become the database agreeing with itself:
/// 694 details, 668 traces and 199,848 samples, guaranteed to agree, printing
/// *no differences*. Nothing in the suite could see it, because both sides
/// agreeing is what a pass looks like.
///
/// **IT IS NOT A SECOND DECODER**, which is 364's rule.
/// `DetailStore(directory:)` is the seam 390 added: it reads the same per-file
/// JSON with the same `JSONDecoder`, through `loadFromDirectories()`, which is
/// the function the singleton also calls. What it does NOT inherit is every
/// write in that class — see `DetailStore.mayWrite`, and the schema purge it
/// refuses.
///
/// **IT ANSWERS IN THREE STATES.** A container the app cannot reach, a device
/// that has never synced, and a directory whose files will not decode all
/// produce a small number, and §12.15 is that those are different facts.
///
/// LIVES IN THIS FILE rather than its own, deliberately — a new Swift file is
/// invisible to the app target until Xcode is quit and reopened (CLAUDE.md §3),
/// and `ActivitySource` sits in `ActivityParity.swift` for the same reason.
@MainActor
enum DetailSource {

    struct Read {
        /// Keyed by activity id, exactly as the store holds them.
        let details: [String: ActivityDetail]
        let streams: [String: ActivityStreams]
        /// What the directories held and what would not decode.
        let tally: DetailStore.FileTally
        /// Nil container. Distinct from an empty directory: one says the app
        /// cannot look, the other says there is nothing there. §12.15.
        let directoryFound: Bool

        /// **AN UNDECODABLE FILE COSTS THE READ ITS INDEPENDENCE, NOT ITS
        /// HONESTY.** The store skips such a file and re-queues it, which is
        /// right. A comparison cannot: a detail the app could not read shows up
        /// as `detailsOnlyInDatabase`, which reads as *the importer wrote a row
        /// the app never had* — the opposite of what happened.
        var isTrustworthy: Bool { directoryFound && tally.isClean }

        /// Printed unconditionally, and it is the sentence every count under it
        /// means. A comparison that does not say where its own side came from
        /// cannot be checked by anybody who was not holding the phone.
        var line: String {
            guard directoryFound else {
                return "Application Support is unreachable, so the app side "
                     + "was not read at all"
            }
            guard tally.isClean else {
                return "the detail and trace files were read and \(tally.line) "
                     + "— the app's own store was compared instead"
            }
            return "details/ and streams/, read directly — \(tally.line)"
        }
    }

    /// `AppSupportItem.container` and not a tenth copy of the
    /// `applicationSupportDirectory` incantation — 356a's correction, and its
    /// own doc's reason: *nil is a real answer*.
    static func read() -> Read {
        guard let dir = AppSupportItem.container else {
            return Read(details: [:], streams: [:],
                        tally: DetailStore.FileTally(), directoryFound: false)
        }
        let store = DetailStore(directory: dir)
        return Read(details: store.details, streams: store.streams,
                    tally: store.tally, directoryFound: true)
    }
}

@MainActor
enum DetailParity {

    // MARK: What is compared, and with what precision

    /// Every pace here is `Int` seconds per kilometre — already rounded by the
    /// property that produced it — so paces are compared EXACTLY. There is no
    /// summation residue to forgive at one-second resolution.
    ///
    /// Metres are not: `totalElevationFromSplits` and a rep's `metres` are sums
    /// of doubles and carry the same arithmetic residue §12.57.3 describes.
    static let metreTolerance = 0.01

    /// On screen, so the threshold is a number rather than a hidden `==`.
    static let toleranceLabel = "paces exact · 0.01 m"

    /// What this comparison does not see. Printed, not implied.
    static let heldFromTheApp =
        "the plan — laps are read with no cut pace"

    /// "last 4 km at MP" and "2×4 km" are what the plan writes; 1 km is the
    /// window a short session can still answer.
    static let closingKilometres = [1, 2, 4]
    static let openingKilometres = [1, 2]
    static let windowKilometres = [1, 2, 4, 5]

    /// EVERY DERIVED PACE ON THE TYPE, NAMED. Adding one to `ActivityDetail`
    /// and not to this list makes the comparison quietly weaker, which is why
    /// they are spelled out rather than reflected over — the same argument
    /// `ActivityRoundTrip.differingFields` makes one level down.
    static func paceFigures(_ d: ActivityDetail) -> [(name: String, value: Int?)] {
        var out: [(name: String, value: Int?)] = [
            (name: "overall", value: d.overallPace),
            (name: "median split", value: d.medianSplitPace),
            (name: "fastest split", value: d.fastestSplit?.paceSecPerKm)]
        for n in closingKilometres {
            out.append((name: "closing \(n) km", value: d.closingPace(km: n)))
        }
        for n in openingKilometres {
            out.append((name: "opening \(n) km", value: d.openingPace(km: n)))
        }
        for n in windowKilometres {
            out.append((name: "best \(n) km", value: d.bestWindowPace(km: n)))
        }
        return out
    }

    private static func close(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= metreTolerance
    }

    /// THE HEART RATE AS EVERY READER DRAWS IT — patch 320a.
    ///
    /// `SplitTables` guards `hr > 0` at the kilometre table and at the lap
    /// table; `hasHRSplits` asks the same question one level up. Nothing in
    /// this app displays a zero heart rate, so nothing here should report one
    /// as a difference from a missing one.
    ///
    /// Comparing the drawn value rather than the stored one loses NOTHING: 148
    /// against nothing still differs, and so does 148 against 150. It only
    /// stops the importer's own normalisation being reported as a divergence
    /// the athlete could see, which is a sentence that was not true.
    static func shownHR(_ v: Double?) -> Int? {
        guard let v, v > 0 else { return nil }
        return Int(v)
    }

    // MARK: The report

    struct Report: Equatable {

        // MARK: Where the app side came from — patch 390

        /// **A `var` WITH A DEFAULT, SET BY THE CALLER — 381's shape exactly.**
        /// `compare` is handed two lists and cannot know where either came from;
        /// `ShadowParity` reads the files and then says so on the report.
        var appSideCameFrom = "DetailStore.shared"

        /// False when the files could not be read and the store was compared
        /// instead. It is not a difference — it is the comparison losing its
        /// independence, which `isHealthy` refuses to call a pass.
        ///
        /// **DEFAULT `true`, FOLLOWING `ActivityParity` RATHER THAN
        /// `liveStoreIsSettled`.** §12.125.8 argued three states for that one
        /// because it asks a question a test genuinely cannot answer. This asks
        /// whether the list the caller handed over was read cleanly, and a
        /// caller that built its own list read it as cleanly as it likes — so
        /// `true` is the honest default and every existing `DetailParityTests`
        /// fixture keeps meaning what it meant.
        var appSideWasReadCleanly = true

        // Denominators — groundwork §2.1 case 2.

        let appDetails: Int
        let databaseDetails: Int
        let detailsCompared: Int

        /// Every (detail × window) pair evaluated. The wide denominator.
        let paceFiguresCompared: Int
        /// Pairs where BOTH sides produced a number. The one that matters:
        /// twelve hundred nils agreeing with twelve hundred nils is a perfect
        /// result describing nothing.
        let paceFiguresAnswered: Int
        /// Splits matched by index inside the compared details. The deep
        /// denominator, and `samplesWalked`'s fifth appearance — §12.39.6.1.
        let splitsCompared: Int
        /// Laps offered to the detector, both sides together.
        let lapsCompared: Int
        /// Reps matched by index where both sides read an interval structure.
        let repsCompared: Int

        // Membership

        /// In the app and not in the database, and nobody meant that.
        let detailsOnlyInApp: [String]
        /// In the app and not in the database ON PURPOSE — `DataCorrections`
        /// refuses two sessions and the importer declines their details at the
        /// door, while `DetailStore` keeps them because it keys by Strava id
        /// and never sees an `Activity`. §12.42.2. **Not counted as a
        /// difference.** A permanent, correct red row is a row that stops
        /// being read.
        let detailsExcluded: [String]
        let detailsOnlyInDatabase: [String]

        // Differences

        /// "19580875358 · closing 4 km". Named, because "9 figures differ"
        /// sends somebody through nine screens and "9, all on best 5 km" is one
        /// fix.
        let paceFiguresDiffering: [String]
        /// The set `displaySplits` produced — its size or its indices.
        let detailsWithDifferentSplitSet: [String]
        /// A split whose derived `paceSecPerKm` differs. Counted deep, because
        /// one detail with forty bad splits and forty details with one each are
        /// the same first number and nothing alike — §12.39.2.
        let splitsWithDifferentPace: Int
        /// A split whose heart rate is DRAWN differently — patch 320a. The
        /// kilometre table's HR column was uncompared until the rep finding
        /// showed the gap.
        let splitsWithDifferentHR: Int
        /// Carried differently, drawn the same: the importer's `positiveOrNil`
        /// on a stored zero. Printed dim, never counted as a difference.
        let splitsWithNormalisedHR: Int
        /// `hasSplits`, `hasHRSplits` or `hasRoute` disagreeing.
        let detailsWithDifferentFlags: [String]
        let detailsWithDifferentElevation: [String]
        /// The decoded polyline's length. Shallow on purpose — the polyline
        /// STRING is compared field-for-field by the read-back at 291, and this
        /// only asks whether the same string decodes to the same track.
        let detailsWithDifferentTrack: [String]
        /// One side read an interval structure out of the laps and the other
        /// did not, or they disagree on how many reps.
        let detailsWithDifferentLapReading: [String]
        let repsDiffering: Int
        /// THE 16. A rep whose heart rate is carried differently and drawn the
        /// same — `lap.averageHR` zero in the store, nothing in the database.
        /// Dim, and printed, because a row that vanishes once it is understood
        /// is a row nobody can watch. §12.54.2.
        let repsWithNormalisedHR: Int

        // Context, printed on both sides rather than asserted

        /// THE TWELVE ZERO-HEART-RATE DETAILS' ROW. `hasHRSplits` is the only
        /// derived property that reads `averageHR` and it treats a stored zero
        /// and a missing value alike, so these two should match — and printing
        /// both is what makes that evidence rather than a claim.
        let appDetailsWithHRSplits: Int
        let databaseDetailsWithHRSplits: Int
        let appDetailsWithRoute: Int
        let databaseDetailsWithRoute: Int
        let appDetailsReadAsIntervals: Int
        let databaseDetailsReadAsIntervals: Int

        var unexplained: Int {
            detailsOnlyInApp.count + detailsOnlyInDatabase.count
            + paceFiguresDiffering.count + detailsWithDifferentSplitSet.count
            + splitsWithDifferentPace + splitsWithDifferentHR
            + detailsWithDifferentFlags.count
            + detailsWithDifferentElevation.count + detailsWithDifferentTrack.count
            + detailsWithDifferentLapReading.count + repsDiffering
        }

        /// Zero details compared to zero details agrees perfectly. So does a
        /// history of strength sessions with no splits in it, which is why
        /// `paceFiguresAnswered` and not `paceFiguresCompared` is the test.
        var lookedAtSomething: Bool {
            detailsCompared > 0 && paceFiguresAnswered > 0
        }

        /// **AND IT ASKS WHERE ITS OWN SIDE CAME FROM — patch 390.** Zero
        /// differences over an app side that could not be read is not a pass:
        /// the fallback compares the database against whatever was to hand, and
        /// after 392 that is the database. 381 gave `ActivityParity` this same
        /// clause and §12.125.3 called it the one with teeth. §12.69 — a check
        /// that cannot fail has not been tested.
        var isHealthy: Bool {
            lookedAtSomething && unexplained == 0 && appSideWasReadCleanly
        }

        var summary: String {
            guard lookedAtSomething else {
                return "nothing compared — \(detailsCompared) details, "
                     + "\(paceFiguresAnswered) figures answered"
            }
            return unexplained == 0
                ? "\(detailsCompared) details · \(paceFiguresAnswered) figures · "
                  + "no differences"
                : "\(detailsCompared) details · \(unexplained) differences"
        }

        var hrSplitsLine: String {
            "\(appDetailsWithHRSplits) vs \(databaseDetailsWithHRSplits)"
        }

        var routeLine: String {
            "\(appDetailsWithRoute) vs \(databaseDetailsWithRoute)"
        }

        var intervalLine: String {
            "\(appDetailsReadAsIntervals) vs \(databaseDetailsReadAsIntervals)"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        /// Activity ids appear only in the named differences, which are capped;
        /// no session names and no dates.
        var diagnosticLines: [String] {
            var lines = [
                "Detail parity: \(detailsCompared) details, "
                + "\(paceFiguresAnswered) figures answered",
                // PATCH 390 — AT THE TOP, and it is the sentence every number
                // below it means. 381's two lines, one comparison over.
                "  the app side came from: \(appSideCameFrom)",
                "  the app side was read cleanly: "
                + "\(appSideWasReadCleanly ? "yes" : "NO")",
                "  held from the app: \(heldFromTheApp)",
                "  tolerance: \(toleranceLabel)",
                "  details in the app: \(appDetails)",
                "  details in the database: \(databaseDetails)",
                "  in the app only: \(detailsOnlyInApp.count)",
                "  excluded on purpose: \(detailsExcluded.count)",
                "  in the database only: \(detailsOnlyInDatabase.count)",
                "  pace figures compared: \(paceFiguresCompared)",
                "  pace figures both sides answered: \(paceFiguresAnswered)",
                "  pace figures that differ: \(paceFiguresDiffering.count)",
                "  splits compared: \(splitsCompared)",
                "  splits with a different pace: \(splitsWithDifferentPace)",
                "  splits with a different heart rate: \(splitsWithDifferentHR)",
                "  splits whose zero heart rate was normalised: "
                + "\(splitsWithNormalisedHR)",
                "  details with a different split set: "
                + "\(detailsWithDifferentSplitSet.count)",
                "  details with different flags: \(detailsWithDifferentFlags.count)",
                "  details with different elevation: "
                + "\(detailsWithDifferentElevation.count)",
                "  details with a different track: \(detailsWithDifferentTrack.count)",
                "  laps offered to the detector: \(lapsCompared)",
                "  details read as intervals: \(intervalLine)",
                "  details with a different lap reading: "
                + "\(detailsWithDifferentLapReading.count)",
                "  reps compared: \(repsCompared)",
                "  reps that differ: \(repsDiffering)",
                "  reps whose zero heart rate was normalised: "
                + "\(repsWithNormalisedHR)",
                "  details with heart-rate splits: \(hrSplitsLine)",
                "  details with a route: \(routeLine)",
                "  unexplained differences: \(unexplained)"]
            // NAMED, NOT JUST COUNTED — §12.39's rule. Capped, and the cap says
            // so rather than truncating silently.
            for f in paceFiguresDiffering.prefix(8) { lines.append("    \(f)") }
            if paceFiguresDiffering.count > 8 {
                lines.append("    + \(paceFiguresDiffering.count - 8) more figures")
            }
            for d in detailsWithDifferentSplitSet.prefix(5) {
                lines.append("    split set \(d)")
            }
            for d in detailsWithDifferentLapReading.prefix(5) {
                lines.append("    lap reading \(d)")
            }
            return lines
        }
    }

    // MARK: The comparison

    /// Both sides handed in, neither read from anywhere.
    ///
    /// STATIC AND TAKING ITS INPUTS, like the other three slices, so a test can
    /// build the two sides from genuinely different places.
    static func compare(app: [ActivityDetail],
                        database: [ActivityDetail]) -> Report {

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`. Neither store
        // can hold two details for one activity, and a dictionary initialiser
        // that TRAPS on data is not a thing a diagnostic should be able to do.
        let mine = Dictionary(app.map { ($0.activityId, $0) },
                              uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(database.map { ($0.activityId, $0) },
                                uniquingKeysWith: { first, _ in first })

        var onlyInApp: [String] = []
        var excluded: [String] = []
        for id in mine.keys where theirs[id] == nil {
            // Absent on purpose is not absent — §12.42.2, and this calls
            // `DataCorrections` rather than modelling it.
            if DataCorrections.isIgnored(id: id) { excluded.append(id) }
            else { onlyInApp.append(id) }
        }
        let onlyInDatabase = theirs.keys.filter { mine[$0] == nil }

        let shared = Set(mine.keys).intersection(theirs.keys).sorted()

        var figuresCompared = 0
        var figuresAnswered = 0
        var figuresDiffering: [String] = []
        var splitsCompared = 0
        var splitsDifferingPace = 0
        var splitsDifferingHR = 0
        var splitsNormalisedHR = 0
        var differentSplitSet: [String] = []
        var differentFlags: [String] = []
        var differentElevation: [String] = []
        var differentTrack: [String] = []
        var differentLapReading: [String] = []
        var lapsCompared = 0
        var repsCompared = 0
        var repsDiffering = 0
        var repsNormalisedHR = 0
        var appHR = 0, dbHR = 0
        var appRoute = 0, dbRoute = 0
        var appIntervals = 0, dbIntervals = 0

        for id in shared {
            guard let a = mine[id], let d = theirs[id] else { continue }

            // THE PACE FAMILY. Every window on both sides, in one pass, with
            // the answered pairs counted apart from the evaluated ones.
            let ap = paceFigures(a)
            let dp = paceFigures(d)
            for (i, figure) in ap.enumerated() where i < dp.count {
                figuresCompared += 1
                let theirValue = dp[i].value
                if figure.value != nil && theirValue != nil { figuresAnswered += 1 }
                if figure.value != theirValue {
                    figuresDiffering.append("\(id) · \(figure.name)")
                }
            }

            // THE SPLIT SET the screen would draw, and the pace inside each
            // row. `displaySplits` is a filter — a fragment under 100 m that
            // survived on one side and not the other changes the table.
            let aSplits = a.displaySplits
            let dSplits = d.displaySplits
            if aSplits.count != dSplits.count
                || aSplits.map(\.index) != dSplits.map(\.index) {
                differentSplitSet.append(id)
            }
            var theirSplits: [Int: ActivityDetail.Split] = [:]
            for s in dSplits { theirSplits[s.index] = s }
            for s in aSplits {
                guard let t = theirSplits[s.index] else { continue }
                splitsCompared += 1
                if s.paceSecPerKm != t.paceSecPerKm
                    || s.isPartial != t.isPartial
                    || s.isFragment != t.isFragment {
                    splitsDifferingPace += 1
                }
                // THE COLUMN THE KILOMETRE TABLE DRAWS — patch 320a, and it was
                // uncompared until the rep finding showed the gap.
                if shownHR(s.averageHR) != shownHR(t.averageHR) {
                    splitsDifferingHR += 1
                } else if s.averageHR != t.averageHR {
                    splitsNormalisedHR += 1
                }
            }

            // THE THREE FLAGS the views branch on. `hasHRSplits` is the one
            // positioned against D6a's accepted loss.
            if a.hasHRSplits { appHR += 1 }
            if d.hasHRSplits { dbHR += 1 }
            if a.hasRoute { appRoute += 1 }
            if d.hasRoute { dbRoute += 1 }
            if a.hasSplits != d.hasSplits
                || a.hasHRSplits != d.hasHRSplits
                || a.hasRoute != d.hasRoute {
                differentFlags.append(id)
            }

            if !close(a.totalElevationFromSplits, d.totalElevationFromSplits) {
                differentElevation.append(id)
            }
            if a.coordinates.count != d.coordinates.count {
                differentTrack.append(id)
            }

            // THE LAPS, through the app's own detector with no plan. Both
            // sides' lap counts go into the denominator, because a detail whose
            // laps vanished on one side would otherwise contribute nothing to
            // it and still be reported as a difference.
            lapsCompared += a.laps.count + d.laps.count
            let aReps = IntervalDetector.fromLaps(a.laps, plan: nil)
            let dReps = IntervalDetector.fromLaps(d.laps, plan: nil)
            if aReps != nil { appIntervals += 1 }
            if dReps != nil { dbIntervals += 1 }

            switch (aReps, dReps) {
            case (nil, nil):
                break
            case let (x?, y?):
                if x.source != y.source || x.reps.count != y.reps.count {
                    differentLapReading.append(id)
                }
                var theirReps: [Int: RepSplit] = [:]
                for r in y.reps { theirReps[r.index] = r }
                for r in x.reps {
                    guard let t = theirReps[r.index] else { continue }
                    repsCompared += 1
                    // THE HEART RATE AS THE LAP TABLE DRAWS IT — 320a. The
                    // first version compared `avgHR` raw and reported the
                    // importer's own normalisation as a divergence.
                    if r.isWork != t.isWork || r.seconds != t.seconds
                        || !close(r.metres, t.metres)
                        || r.paceSecPerKm != t.paceSecPerKm
                        || shownHR(r.avgHR) != shownHR(t.avgHR) {
                        repsDiffering += 1
                    } else if r.avgHR != t.avgHR {
                        repsNormalisedHR += 1
                    }
                }
            default:
                // ONE SIDE READ AN INTERVAL SESSION AND THE OTHER DID NOT.
                // The loudest thing this slice can find: the same laps through
                // the same detector reaching different verdicts.
                differentLapReading.append(id)
            }
        }

        return Report(
            appDetails: app.count,
            databaseDetails: database.count,
            detailsCompared: shared.count,
            paceFiguresCompared: figuresCompared,
            paceFiguresAnswered: figuresAnswered,
            splitsCompared: splitsCompared,
            lapsCompared: lapsCompared,
            repsCompared: repsCompared,
            detailsOnlyInApp: onlyInApp.sorted(),
            detailsExcluded: excluded.sorted(),
            detailsOnlyInDatabase: onlyInDatabase.sorted(),
            paceFiguresDiffering: figuresDiffering.sorted(),
            detailsWithDifferentSplitSet: differentSplitSet.sorted(),
            splitsWithDifferentPace: splitsDifferingPace,
            splitsWithDifferentHR: splitsDifferingHR,
            splitsWithNormalisedHR: splitsNormalisedHR,
            detailsWithDifferentFlags: differentFlags.sorted(),
            detailsWithDifferentElevation: differentElevation.sorted(),
            detailsWithDifferentTrack: differentTrack.sorted(),
            detailsWithDifferentLapReading: differentLapReading.sorted(),
            repsDiffering: repsDiffering,
            repsWithNormalisedHR: repsNormalisedHR,
            appDetailsWithHRSplits: appHR,
            databaseDetailsWithHRSplits: dbHR,
            appDetailsWithRoute: appRoute,
            databaseDetailsWithRoute: dbRoute,
            appDetailsReadAsIntervals: appIntervals,
            databaseDetailsReadAsIntervals: dbIntervals)
    }
}
