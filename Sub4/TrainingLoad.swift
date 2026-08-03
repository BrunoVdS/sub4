//
//  TrainingLoad.swift
//  Sub4
//
//  One number per session, in one currency, computed the same way for every
//  sport.
//
//  THE CURRENCY
//  ------------
//  Banister exponential TRIMP, from heart rate:
//
//      ΔHR   = (HR − rest) / (max − rest)          clamped to [0, 1]
//      TRIMP = Σ  minutes · ΔHR · 0.64 · exp(w · ΔHR)
//
//  with w = 1.92 male, 1.67 female. One computation, so a run, a ride and a
//  swim can be added together honestly — which is the whole reason for
//  choosing it. TrainingPeaks sums rTSS with sTSS with power TSS and Strava
//  mixes power load with HR load in one curve; both are adding numbers from
//  separately anchored scales, and neither can say what the sum means.
//
//  THE LADDER
//  ----------
//  Every eligible activity resolves to exactly one rung, and the rung is
//  recorded next to the number so no figure is ever mistaken for a better one:
//
//    1. STREAM   — integrated over the cached per-bin heart rate. The real
//                  thing: intervals are scored as intervals.
//    2. AVERAGE  — the session's mean HR against its moving time. Arrives with
//                  the activity itself at no API cost, and is what every day
//                  starts on before the detail queue reaches it. Under-scores
//                  intervals, because the exponential is convex: the average of
//                  the exponent is not the exponent of the average.
//    3. UNSCORED — no usable heart rate. NOT zero. A day holding one of these
//                  is marked, because a silent zero is a lie the fitness curve
//                  would carry for six weeks.
//
//  WHY sRPE IS NOT RUNG 3 YET
//  --------------------------
//  The source spec has RPE × minutes as the fallback. It never addresses the
//  problem with that: RPE 5 for an hour is 300, while an hour at ΔHR 0.7 is
//  108. They are different scales, and substituting one for the other is
//  exactly the unit mismatch the single-currency decision exists to prevent —
//  it would put a step in the fitness curve wherever a note happened to exist.
//
//  So sRPE is computed and carried alongside, never summed. Once enough
//  sessions have BOTH an RPE and a heart-rate score, their ratio is measurable
//  and sRPE can be converted with a number derived from this athlete rather
//  than assumed. Until then an RPE-only session is unscored and says so.
//
//  WHAT IS DELIBERATELY NOT HERE
//  -----------------------------
//  No power, because the bike reports Strava's estimate rather than a meter.
//  No bone load, because ground contact time does not exist in Strava's API at
//  any resolution. No rTSS, no sTSS, no ACWR, no readiness score.
//

import Foundation

// MARK: - Where a number came from

enum LoadSource: String, Codable, Hashable {
    case stream          // integrated per-bin heart rate
    case average         // session mean HR
    case power           // converted from TSS, for rides with no heart rate
    case unscored        // nothing usable

    var label: String {
        switch self {
        case .stream:   return "HR trace"
        case .average:  return "avg HR"
        case .power:    return "power"
        case .unscored: return "unscored"
        }
    }

    /// Everything but `unscored` produces a figure in the same units — the
    /// first two directly, the third through a measured conversion.
    var contributesLoad: Bool { self != .unscored }

    /// True when the figure came through a conversion rather than from heart
    /// rate. Counted separately, because a curve mostly made of conversions is
    /// a different object from one mostly made of measurements.
    var isConverted: Bool { self == .power }
}

enum LoadFlag: String, Codable, Hashable {
    case lowHRCoverage        // HR present for < 80% of the trace
    case partialHRCoverage    // 80–95%: counted, but the gaps score nothing
    case hrMaxBreach          // HR above HR_max — the maximum is stale or wrong
    case durationMismatch     // the trace's own duration disagrees with Strava's
    case noHeartRate          // nothing to compute from
    case constantsMissing     // no usable HR_max / HR_rest for that day
    case noPowerFactor        // power present, but nothing to convert it with
    case noFTP                // power present, but no measured FTP to score it against
    case surgyPower           // average power is hiding a lot of variation
    case correctedDuration    // scored over a hand-corrected duration
    case healthHeartRate      // HR came from Apple Health, not from Strava

    var label: String {
        switch self {
        case .lowHRCoverage:     return "HR < 80%"
        case .partialHRCoverage: return "HR < 95%"
        case .hrMaxBreach:       return "above HR max"
        case .durationMismatch:  return "duration mismatch"
        case .noHeartRate:       return "no HR"
        case .constantsMissing:  return "no constants"
        case .noPowerFactor:     return "no power factor"
        case .noFTP:             return "no FTP"
        case .surgyPower:        return "surgy — floor"
        case .correctedDuration: return "corrected duration"
        case .healthHeartRate:   return "HR from Health"
        }
    }
}

// MARK: - One activity's load

struct WorkoutLoad: Codable, Hashable, Identifiable {
    let activityId: String
    let dayKey: String
    let name: String
    let sport: String
    /// TRIMP. Zero when `source == .unscored`, and that zero must never be
    /// added to a day without also marking the day.
    let trimp: Double
    let source: LoadSource
    let flags: [LoadFlag]
    /// Fraction of the trace carrying heart rate, when there was a trace.
    let hrCoverage: Double?
    /// sRPE — carried, never summed. See the note at the top of this file.
    let srpe: Double?
    /// The constants this figure was computed under. Stored per row rather than
    /// referenced by a version id, so staleness is a direct comparison.
    let hrMaxUsed: Int
    let hrRestUsed: Int
    let engineVersion: Int

    /// The duration the figure was computed over, and what Strava said.
    ///
    /// Identical for every session except the handful in `DataCorrections`.
    /// Carried so a corrected row can be INSPECTED rather than merely flagged —
    /// "corrected duration" beside a number you cannot check is a claim, not
    /// evidence, and the correction was documented as visible.
    var scoredSeconds: Int = 0
    var stravaMovingSeconds: Int = 0

    /// SECONDS PER HEART RATE, AT 1 BPM RESOLUTION. Empty unless this session
    /// was scored from its trace.
    ///
    /// WHY BPM AND NOT ZONES
    /// ---------------------
    /// Zones are edited in Settings and re-fetched from Strava. Bucketing into
    /// zones here would mean a zone change forces a full recompute of the load
    /// series, and would bake that day's boundaries into every stored figure —
    /// including, historically, the overlapping bounds fixed in patch 81. Kept
    /// as raw bpm, the bucketing happens at render time: a zone edit redraws
    /// instantly and this engine stays entirely ignorant of zones.
    ///
    /// Roughly a hundred entries per session, in memory only — `LoadStore`
    /// persists nothing.
    var hrSeconds: [Int: Double] = [:]

    /// Carried from the activity so a card can filter to the plan's own
    /// disciplines without re-reading `ActivityStore`. The engine scores a wider
    /// set than every card wants to show: `isLoadEligible` also admits anything
    /// over 10 km, which is how a long walk earns load and a 5 km commute does
    /// not.
    var isPlanEligible: Bool = false

    /// Carried so a card can group by discipline without a second lookup in
    /// `ActivityStore`. `sport` above is Strava's raw string; this is the app's
    /// own five-way classification.
    var disciplineRaw: String = Discipline.other.rawValue
    var discipline: Discipline { Discipline(rawValue: disciplineRaw) ?? .other }

    /// True when this session can contribute a time-in-zone distribution. A
    /// session scored from its average has a number but no shape.
    ///
    /// Note that some disciplines can NEVER be true here, and it is structural
    /// rather than a recording fault: a distribution is integrated from a
    /// distance-binned trace, and a strength session covers no distance at all.
    var hasZoneDistribution: Bool { !hrSeconds.isEmpty }

    var id: String { activityId }
    var isDurationCorrected: Bool {
        scoredSeconds > 0 && stravaMovingSeconds > 0
            && scoredSeconds != stravaMovingSeconds
    }
    var isScored: Bool { source.contributesLoad }
}

// MARK: - One day

enum DayState: String, Codable, Hashable {
    case measured    // every eligible activity scored
    case partial     // something on this day could not be scored
    case rest        // nothing eligible happened — a real zero
    case gap         // things happened and none of them could be scored

    var label: String {
        switch self {
        case .measured: return "measured"
        case .partial:  return "partial"
        case .rest:     return "rest"
        case .gap:      return "gap"
        }
    }

    /// Rest days are real zeros and belong in the curve. Gaps are not zeros,
    /// and a fitness curve computed across one is wrong for six weeks after it.
    var isUsable: Bool { self == .measured || self == .rest || self == .partial }
}

struct DailyLoad: Codable, Hashable, Identifiable {
    let dayKey: String
    let load: Double
    let state: DayState
    let workouts: [WorkoutLoad]

    var id: String { dayKey }

    var scored: [WorkoutLoad] { workouts.filter(\.isScored) }
    var unscored: [WorkoutLoad] { workouts.filter { !$0.isScored } }
}

// MARK: - The engine

enum LoadEngine {

    /// Bumped when a rule here changes. Every stored figure carries it, so a
    /// recompute can tell which numbers were produced under which rules.
    /// 2: the power rung.
    /// 3 introduces `DataCorrections.scoringSeconds`, so any series built by
    /// version 2 is stale for the corrected sessions and must be rebuilt.
    /// 4 accepts a heart rate from Apple Health where Strava has none.
    static let version = 4

    /// Banister's constant. Not a tuning parameter — it is part of the
    /// published formula.
    static let k = 0.64

    /// Heart rate must be present for this much of a trace before the trace is
    /// used at all. Below it, the session falls to its session average.
    static let minCoverage = 0.80
    /// Above the gate but below this, the figure is counted and flagged: the
    /// uncovered part scores nothing, so the total is slightly low.
    static let goodCoverage = 0.95

    /// How far the trace's own duration may differ from Strava's moving time
    /// before the trace is distrusted. A distance-binned trace through a long
    /// stop integrates to something quite unlike the session.
    static let maxDurationDrift = 0.25

    // MARK: The formula

    /// One sample's contribution, in TRIMP per minute.
    ///
    /// Separated out because it is the only piece of arithmetic in this file
    /// that a paper can be checked against, and `selfTest()` checks it.
    static func trimpPerMinute(hr: Double, rest: Int, max: Int, w: Double) -> Double {
        let span = Double(max - rest)
        guard span > 0 else { return 0 }
        let d = Swift.min(Swift.max((hr - Double(rest)) / span, 0), 1)
        return d * k * exp(w * d)
    }

    // MARK: Per activity

    /// Compute one activity's load, taking the best rung available.
    static func load(for a: Activity,
                     streams: ActivityStreams?,
                     hrMax: Int?,
                     hrRest: Int?,
                     w: Double,
                     srpe: Double?,
                     ftp: Int? = nil,
                     powerFactor: PowerFactor? = nil,
                     healthAverageHR: Double? = nil) -> WorkoutLoad {

        func result(_ trimp: Double, _ source: LoadSource,
                    _ flags: [LoadFlag], _ coverage: Double?) -> WorkoutLoad {
            WorkoutLoad(activityId: a.id, dayKey: a.dayKey, name: a.name,
                        sport: a.sportType, trimp: trimp, source: source,
                        flags: flags, hrCoverage: coverage, srpe: srpe,
                        hrMaxUsed: hrMax ?? 0, hrRestUsed: hrRest ?? 0,
                        engineVersion: version,
                        scoredSeconds: DataCorrections.scoringSeconds(a),
                        stravaMovingSeconds: a.movingTime,
                        isPlanEligible: a.isPlanEligible,
                        disciplineRaw: (a.discipline ?? .other).rawValue)
        }

        // Power is scored from watts, FTP and duration. None of that needs a
        // heart-rate maximum or a resting rate — so a ride that CAN be scored
        // must not be turned into a gap because the constants are missing.
        func powerResult() -> WorkoutLoad? {
            guard a.discipline == .bike, a.hasRealPower,
                  a.movingTime >= PowerLoad.minSeconds else { return nil }
            guard let ftp, let tss = PowerLoad.tss(a, ftp: ftp) else {
                // The FTP is the single thing blocking this, and the list has
                // to say which thing.
                return result(0, .unscored, [.noHeartRate, .noFTP], nil)
            }
            guard let f = powerFactor, f.isUsable else {
                return result(0, .unscored, [.noHeartRate, .noPowerFactor], nil)
            }
            var flags: [LoadFlag] = []
            if let r = PowerLoad.roughness(streams), r > 0.5 {
                flags.append(.surgyPower)
            }
            return result(tss * f.k, .power, flags, nil)
        }

        guard let hrMax, let hrRest, hrMax - hrRest >= ConstantsStore.minSpread else {
            return powerResult() ?? result(0, .unscored, [.constantsMissing], nil)
        }

        // --- Rung 1: the trace.
        //
        // The histogram is filled HERE and nowhere else, so a session trusted
        // for TRIMP is trusted for time in zone and no other. One rule, not two.
        if let s = streams, let stream = streamTrimp(a, s, hrMax, hrRest, w) {
            var out = result(stream.trimp, .stream, stream.flags, stream.coverage)
            out.hrSeconds = streamHistogram(s)
            return out
        }

        // --- Rung 2: the session average.
        //
        // Strava's average where there is one, Apple Health's where there is
        // not. A strength session logged through Hevy reaches Strava with reps,
        // sets and calories and NO heart rate — so the engine could not score
        // it and the whole day became a gap, imputed in the curve and inflating
        // monotony for a week after. The watch was recording throughout; the
        // figure simply never made the trip. Flagged, so a number that came
        // from somewhere other than the activity says so.
        let fromHealth = a.averageHeartrate == nil && (healthAverageHR ?? 0) > 30
        if let avg = a.averageHeartrate ?? healthAverageHR, avg > 30, avg.isFinite {
            var flags: [LoadFlag] = []
            if fromHealth { flags.append(.healthHeartRate) }
            if avg > Double(hrMax) { flags.append(.hrMaxBreach) }
            // Strava's moving time, EXCEPT where that recording is known to be
            // wrong — see DataCorrections. Flagged rather than silent.
            if DataCorrections.isCorrected(a) { flags.append(.correctedDuration) }
            let minutes = Double(DataCorrections.scoringSeconds(a)) / 60
            let t = minutes * trimpPerMinute(hr: avg, rest: hrRest, max: hrMax, w: w)
            return result(t, .average, flags, nil)
        }

        // --- Rung 3: power, converted. Only for a ride with no usable heart
        // rate — heart rate is the currency, and a conversion never outranks a
        // measurement in it.
        if let w = powerResult() { return w }

        // --- Rung 4: nothing. Explicitly not zero-with-a-shrug.
        return result(0, .unscored, [.noHeartRate], nil)
    }

    /// Seconds per heart rate, at 1 bpm resolution, over the same trace and the
    /// same geometry `streamTrimp` integrates.
    ///
    /// The stream is resampled to equal-DISTANCE bins, so a bin's duration is
    /// its width over its speed. Counting samples instead — or weighting them
    /// equally — would describe where the route was slow rather than where the
    /// clock went, and on a hilly run those are not the same distribution.
    ///
    /// Bins under 0.3 m/s are skipped, exactly as in the TRIMP integral: that is
    /// the stop at the lights, and stopped time is not time in any zone. It
    /// follows that these seconds sum to LESS than the session's moving time,
    /// by design and not by loss.
    ///
    /// Only ever called from rung 1, so the coverage floor and the duration
    /// drift check have already been passed before a single second is counted.
    static func streamHistogram(_ s: ActivityStreams) -> [Int: Double] {
        guard let hr = s.heartRate, hr.count == s.count,
              let speed = s.speed, speed.count == s.count,
              s.count >= 8, let total = s.distanceM.last, total > 0 else { return [:] }

        let binWidth = total / (Double(s.count) - 0.5)
        var out: [Int: Double] = [:]
        for i in 0..<s.count {
            let v = speed[i]
            guard v > 0.3 else { continue }
            let bpm = hr[i]
            guard bpm > 30, bpm.isFinite else { continue }
            out[Int(bpm.rounded()), default: 0] += binWidth / v
        }
        return out
    }

    /// Integrated over the cached trace, or nil when the trace cannot carry it.
    ///
    /// The stream is resampled to equal-DISTANCE bins, so a bin's duration is
    /// its width over its speed — the slow bins are the long ones, and summing
    /// per-bin heart rate without that weighting would score a run by its
    /// geography rather than its clock.
    private static func streamTrimp(_ a: Activity,
                                    _ s: ActivityStreams,
                                    _ hrMax: Int,
                                    _ hrRest: Int,
                                    _ w: Double)
    -> (trimp: Double, coverage: Double, flags: [LoadFlag])? {

        guard let hr = s.heartRate, hr.count == s.count,
              let speed = s.speed, speed.count == s.count,
              s.count >= 8, let total = s.distanceM.last, total > 0 else { return nil }

        let binWidth = total / (Double(s.count) - 0.5)

        var seconds = 0.0
        var trimp = 0.0
        var visited = 0        // bins the integral actually walks
        var covered = 0        // …of those, the ones carrying a heart rate
        var breach = false

        for i in 0..<s.count {
            let v = speed[i]
            guard v > 0.3 else { continue }
            visited += 1
            let dt = binWidth / v
            seconds += dt
            let bpm = hr[i]
            guard bpm > 30, bpm.isFinite else { continue }
            covered += 1
            if bpm > Double(hrMax) { breach = true }
            trimp += (dt / 60) * trimpPerMinute(hr: bpm, rest: hrRest, max: hrMax, w: w)
        }

        guard seconds > 0, visited > 0 else { return nil }
        // Denominated on the bins the integral visits, not on every bin in the
        // file. Dividing by the lot would count a stationary stretch as missing
        // heart rate, and a session with a long stop and a perfect trace would
        // be demoted to its session average — which under-scores intervals by
        // about 8%, the exact error the trace exists to avoid.
        let coverage = Double(covered) / Double(visited)
        guard coverage >= minCoverage else { return nil }

        // The trace has to describe the same session Strava does. A large
        // disagreement means a stop, a pause, or a resampling that lost time —
        // any of which makes the integral describe something else.
        // The corrected figure where there is one: otherwise a session whose
        // moving time is known to be wrong would be rejected from the trace
        // rung for disagreeing with the very number being corrected.
        let moving = Double(DataCorrections.scoringSeconds(a))
        if moving > 0, abs(seconds - moving) / moving > maxDurationDrift { return nil }

        var flags: [LoadFlag] = []
        if coverage < goodCoverage { flags.append(.partialHRCoverage) }
        if breach { flags.append(.hrMaxBreach) }
        return (trimp, coverage, flags)
    }

    // MARK: Self-test
    //
    // The published worked example, checked in the app rather than in a test
    // target this project does not have. Visible in Settings, so a formula that
    // drifts is caught by looking rather than by remembering.

    struct Check: Identifiable {
        let name: String
        let expected: String
        let got: String
        let pass: Bool
        var id: String { name }
    }

    static func selfTest() -> [Check] {
        var out: [Check] = []

        func check(_ name: String, _ expected: Double, _ got: Double,
                   tolerance: Double = 0.05, format: String = "%.2f") {
            out.append(Check(name: name,
                             expected: String(format: format, expected),
                             got: String(format: format, got),
                             pass: abs(expected - got) <= tolerance))
        }

        // Banister, the reference vector: 60 min at HR 150, rest 50, max 190,
        // male. ΔHR = 100/140 = 0.7143 → 60 × 0.7143 × 0.64 × e^1.3714 = 108.1
        check("Banister 60 min @150",
              108.1,
              60 * trimpPerMinute(hr: 150, rest: 50, max: 190, w: 1.92),
              tolerance: 0.1, format: "%.1f")

        // At rest there is no load, whatever the duration.
        check("At resting HR", 0,
              60 * trimpPerMinute(hr: 50, rest: 50, max: 190, w: 1.92))

        // Above maximum, ΔHR clamps to 1 — the load stops rising rather than
        // running away with the exponent.
        let atMax = trimpPerMinute(hr: 190, rest: 50, max: 190, w: 1.92)
        let above = trimpPerMinute(hr: 210, rest: 50, max: 190, w: 1.92)
        check("Clamped above max", atMax, above)

        // Female weighting is a different curve, not a scale factor.
        check("Female 60 min @150",
              60 * 0.7143 * 0.64 * exp(1.67 * 0.7143),
              60 * trimpPerMinute(hr: 150, rest: 50, max: 190, w: 1.67),
              tolerance: 0.1, format: "%.1f")

        // TSS, from the published worked example: FTP 250 W, 200 W for an
        // hour → IF 0.80 → 64.0.
        check("TSS · 200 W at FTP 250 for 1 h", 64.0,
              PowerLoad.tss(watts: 200, ftp: 250, seconds: 3600), tolerance: 0.01)

        // The PMC recursion, from the published worked example: yesterday's
        // CTL 50 and ATL 60, today's load 100.
        let stepped = PMC.step(ctl: 50, atl: 60, load: 100)
        check("PMC step · CTL", 51.19, stepped.ctl, tolerance: 0.01)
        check("PMC step · ATL", 65.71, stepped.atl, tolerance: 0.01)

        // And the property that makes it an exponential average at all: from
        // zero, a constant load reaches 1 − (1 − 1/τ)^τ of itself after τ days.
        var ctl = 0.0, atl = 0.0
        for _ in 0..<42 { let s = PMC.step(ctl: ctl, atl: atl, load: 100); ctl = s.ctl; atl = s.atl }
        check("CTL after 42 days at 100", 63.65, ctl, tolerance: 0.05, format: "%.2f")

        // The resting-HR percentile: eleven values 50…60, tenth percentile = 51.
        let p = ConstantsStore.percentile(Array(50...60), 0.10)
        out.append(Check(name: "Tenth percentile of 50…60",
                         expected: "51", got: "\(p)", pass: p == 51))

        // Month arithmetic across both year boundaries.
        let back = ConstantsStore.month("2026-01", offsetBy: -1)
        let fwd  = ConstantsStore.month("2026-12", offsetBy: 1)
        out.append(Check(name: "Month arithmetic",
                         expected: "2025-12 / 2027-01",
                         got: "\(back) / \(fwd)",
                         pass: back == "2025-12" && fwd == "2027-01"))

        return out
    }
}

// MARK: - Which activities count

extension MatchRules {
    /// Bruno's rule: a walk or a commute counts as training load only when it
    /// is a real distance in one go. Below it, a walk to the shop is movement,
    /// not training, and letting it into a fitness curve built for a marathon
    /// would quietly raise the floor under every figure.
    static var loadMinKmForExtras: Double = 10.0
}

extension Activity {
    /// Whether this activity contributes to training load at all.
    ///
    /// Deliberately wider than `isPlanEligible`, which answers a different
    /// question — "may this satisfy a planned session". A 12 km walk satisfies
    /// nothing in the plan and is still an hour and a half on your feet.
    var isLoadEligible: Bool {
        if isPlanEligible { return true }
        return km >= MatchRules.loadMinKmForExtras
    }
}
