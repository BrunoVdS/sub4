//
//  PMC.swift
//  Sub4
//
//  Fitness, fatigue and the difference between them.
//
//  THE ARITHMETIC
//  --------------
//      CTL[d] = CTL[d−1] + (load[d] − CTL[d−1]) / 42        "fitness"
//      ATL[d] = ATL[d−1] + (load[d] − ATL[d−1]) / 7         "fatigue"
//      TSB[d] = CTL[d−1] − ATL[d−1]                         "freshness"
//
//  Two exponential moving averages over the same daily series, at different
//  time constants, and their difference. That is the whole model. Everything
//  interesting about it is in what the series contains, which is why the load
//  engine and its four day-states came first.
//
//  TSB USES YESTERDAY'S VALUES, and that is not a rounding detail. Today's
//  session has already been added to today's ATL, so a same-day TSB would show
//  you tired because you trained this morning — which you knew. Yesterday's
//  difference is the state you STARTED today in.
//
//  42 IS A TIME CONSTANT, NOT A HALF-LIFE
//  --------------------------------------
//  The half-life is 42 · ln2 ≈ 29 days. The tooltip that says "your fitness
//  halves in six weeks" is wrong and it is everywhere.
//
//  WHAT THE MODEL DOES NOT KNOW
//  ----------------------------
//  The 42 and the 7 are population conventions. Banister's original model
//  fitted individual gain factors per athlete; every commercial implementation
//  dropped that and kept the constants, which is the compromise inherited here.
//  They are stored on every point so that changing them later is visible rather
//  than silent.
//
//  GAPS
//  ----
//  A gap day — something happened and nothing could be scored — is the one case
//  with no honest answer. Zero is wrong: the training happened. Skipping it is
//  wrong: the average needs a value. So it is IMPUTED from the trailing seven
//  usable days and marked as imputed, and the count travels with the curve.
//  Above a fifth of the window imputed, the curve stops claiming to be one.
//
//  A partial day is a floor, not a gap: something scored, something did not.
//  Those are counted separately and never imputed — inventing the missing part
//  of a day we can partly see would be worse than reading it low.
//

import Foundation

struct PMCPoint: Identifiable, Hashable {
    let dayKey: String
    /// What went into the average — the day's load, or the imputed stand-in.
    let load: Double
    let ctl: Double
    let atl: Double
    /// Yesterday's CTL − ATL. nil on the first day, where there is no yesterday.
    let tsb: Double?
    let state: DayState
    let imputed: Bool
    /// Inside the first 42 days, where the average has not filled yet.
    let isWarmup: Bool

    var id: String { dayKey }
}

enum PMC {

    /// Time constants, in days. Population conventions, not fitted to anyone.
    static let ctlTau = 42.0
    static let atlTau = 7.0

    /// Days before the long average means anything.
    static let warmupDays = 42

    /// Above this share of imputed days, the curve is not describing training.
    static let maxImputedShare = 0.20

    /// One day of the recursion, exposed so the self-test can check it against
    /// the published worked example rather than against itself.
    static func step(ctl: Double, atl: Double, load: Double) -> (ctl: Double, atl: Double) {
        (ctl + (load - ctl) / ctlTau, atl + (load - atl) / atlTau)
    }

    // MARK: Building

    static func build(_ days: [DailyLoad]) -> [PMCPoint] {
        guard !days.isEmpty else { return [] }

        var out: [PMCPoint] = []
        var ctl = 0.0
        var atl = 0.0
        // The trailing window used to stand in for a gap. Only usable days go
        // in it, so a run of gaps cannot feed on itself.
        var recent: [Double] = []

        for (i, d) in days.enumerated() {
            let imputed = d.state == .gap
            let load: Double
            if imputed {
                load = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
            } else {
                load = d.load
                recent.append(d.load)
                if recent.count > 7 { recent.removeFirst() }
            }

            // Yesterday's difference, read before today's session moves it.
            let tsb: Double? = i == 0 ? nil : ctl - atl

            let next = step(ctl: ctl, atl: atl, load: load)
            ctl = next.ctl
            atl = next.atl

            out.append(PMCPoint(dayKey: d.dayKey, load: load, ctl: ctl, atl: atl,
                                tsb: tsb, state: d.state, imputed: imputed,
                                isWarmup: i < warmupDays))
        }
        return out
    }

    // MARK: Reading

    /// CTL now minus CTL seven days ago — the number the monthly review acts
    /// on, and the one a build is steered by.
    static func rampRate(_ points: [PMCPoint], on index: Int? = nil) -> Double? {
        let i = index ?? (points.count - 1)
        guard i >= 7, i < points.count else { return nil }
        return points[i].ctl - points[i - 7].ctl
    }

    /// Freshness in words. Deliberately descriptive, never advice: the source
    /// literature is explicit that race-day TSB targets are folklore, so this
    /// says what the number IS and stops.
    static func freshnessLabel(_ tsb: Double) -> String {
        switch tsb {
        case ..<(-25):  return "Deep"
        case ..<(-10):  return "Loaded"
        case ..<10:     return "Steady"
        default:        return "Fresh"
        }
    }
}

// MARK: - The curve as a whole

struct PMCSummary {
    let points: [PMCPoint]

    var latest: PMCPoint? { points.last }
    var ctl: Double? { latest?.ctl }
    var atl: Double? { latest?.atl }
    var tsb: Double? { latest?.tsb }
    var ramp: Double? { PMC.rampRate(points) }

    var imputedCount: Int { points.filter(\.imputed).count }
    var partialCount: Int { points.filter { $0.state == .partial }.count }

    /// Days at the head of the series where the 42-day average had not filled.
    ///
    /// `PMCPoint.isWarmup` has existed for as long as the curve has and nothing
    /// has ever read it. The series-level `isWarmup` below — a different
    /// property that happens to share the name — gates the caveat, and it goes
    /// false the moment there are 42 days of data. That is precisely when the
    /// per-point flag starts to matter: the curve becomes readable at its
    /// right-hand end while its left-hand end is still an average climbing out
    /// of a seed of zero. Seven months in, the caveat cannot fire and January
    /// still reports a fitness of nothing.
    ///
    /// 42 days is ONE TIME CONSTANT, not convergence. An exponential average is
    /// within 1 − e⁻¹ ≈ 63% of steady state after one, so this marks the stretch
    /// that is certainly wrong rather than the point at which the curve is
    /// finally right — that is nearer three time constants. Widening it is a
    /// judgement about how much of the picture to disown, not a bug fix, so the
    /// constant is left where it was.
    var warmupCount: Int { points.filter(\.isWarmup).count }

    /// Days of series since training first appears in it.
    ///
    /// NOT `points.count`. The series runs from the ingest cutoff to today
    /// whether or not anything was recorded, so counting points measures the
    /// calendar. On a fresh install every day is a rest day, every average is
    /// zero, and a curve made entirely of absence would otherwise report itself
    /// as forty-two days of evidence.
    var daysOfData: Int {
        guard let i = points.firstIndex(where: { $0.load > 0 || $0.state == .gap })
        else { return 0 }
        return points.count - i
    }

    var isWarmup: Bool { daysOfData < PMC.warmupDays }

    /// Measured over the window the averages actually reflect, not over the
    /// whole series.
    ///
    /// Three weeks of dead heart-rate strap ending today makes the displayed
    /// fatigue entirely invented — but spread across seven months of history it
    /// is 10% and passes. The averages have 42- and 7-day time constants; the
    /// honesty check has to use the same horizon.
    var imputedShare: Double {
        let window = points.suffix(PMC.warmupDays)
        guard !window.isEmpty else { return 0 }
        return Double(window.filter(\.imputed).count) / Double(window.count)
    }

    /// The one gate on whether any of this should be shown as a conclusion.
    var isTrustworthy: Bool {
        !isWarmup && imputedShare <= PMC.maxImputedShare
    }

    /// Why not, when not. nil when the curve is worth reading.
    var caveat: String? {
        if points.isEmpty { return "No load series yet." }
        if daysOfData == 0 { return "No training in the series yet." }
        if isWarmup {
            return "Only \(daysOfData) of the \(PMC.warmupDays) days the long "
                 + "average needs. Fitness is still filling and reads low."
        }
        if imputedShare > PMC.maxImputedShare {
            return String(format: "%.0f%% of the last %d days had nothing that "
                          + "could be scored and were filled in from the week "
                          + "around them. The curve is describing the fill, not "
                          + "the training.",
                          imputedShare * 100, PMC.warmupDays)
        }
        return nil
    }
}
