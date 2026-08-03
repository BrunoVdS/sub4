//
//  PowerLoad.swift
//  Sub4
//
//  Scoring the rides that have no heart rate.
//
//  THE PROBLEM THIS SOLVES
//  -----------------------
//  A 120 km ride on 29 May, four hours and four minutes, 188 watts. It carries
//  a power meter and no heart rate at all — so under a heart-rate currency it
//  scored nothing, and the fitness curve replaced the biggest single session of
//  the year with the average of the week around it. About half the long rides
//  in this history are like that.
//
//  AVERAGE POWER, NOT NORMALISED POWER
//  -----------------------------------
//  The textbook figure is NP: a 30-second rolling mean raised to the fourth
//  power, averaged, fourth-rooted. It cannot be computed here, and the reason
//  is worth writing down rather than discovering later.
//
//  Traces are stored resampled to 300 equal-DISTANCE bins. On a four-hour ride
//  that is 400 m and roughly 48 seconds per bin — the bin is longer than the
//  window NP averages over. Any "NP" computed from it would be an average of
//  averages wearing a technical name.
//
//  So this uses average power, which Strava reports on the activity itself. The
//  cost is stated: NP ≥ AP always, and the gap grows with variability, so a
//  ragged criterium is under-scored while a steady endurance ride is barely
//  affected. These are steady endurance rides — which is exactly the case where
//  AP is a good proxy, and the trace is used to CHECK that rather than to
//  assume it.
//
//  The benefit is not small: needing no trace means this works on the whole
//  history immediately, rather than waiting for a backfill.
//
//  THE CONVERSION IS MEASURED, NOT ASSUMED
//  ---------------------------------------
//  TSS and TRIMP are separately anchored scales. Adding them would be the exact
//  unit mismatch the single-currency decision exists to prevent — the defect
//  this app refuses to inherit from TrainingPeaks and Strava.
//
//  So they are not added. Instead: for every ride that carries BOTH a heart
//  rate and a meter, both numbers are computed and their ratio recorded. The
//  median of those ratios is a conversion factor derived from this athlete on
//  this bike, and power-only rides are scored through it. Below five paired
//  rides there is no factor and those rides stay unscored, saying so.
//
//  It is still a conversion, and it is shown as one: the factor, the number of
//  rides behind it, and how much they disagree are all on screen.
//

import Foundation

struct PowerFactor {

    /// TRIMP per unit of TSS, measured from rides carrying both.
    let k: Double
    /// How many rides the median was taken over.
    let sampleCount: Int
    /// Interquartile spread as a share of the median. Small means the rides
    /// agree; large means the factor is being asked to cover two different
    /// kinds of riding.
    let spread: Double

    /// Below this the median is one or two rides wearing a decimal point.
    static let minSamples = 5

    var isUsable: Bool { sampleCount >= Self.minSamples }

    /// Wide spread does not stop it being used — it changes what it is worth,
    /// and that has to be visible rather than hidden behind a threshold.
    var isTight: Bool { spread <= 0.35 }

    var label: String {
        String(format: "%.2f TRIMP per TSS · %d rides · ±%.0f%%",
               k, sampleCount, spread * 100)
    }
}

/// Why there is no factor, in enough detail to act on.
///
/// "not measurable" was the whole of the old diagnostic, and it covered four
/// completely different situations with four different fixes: no FTP on the
/// Strava profile, no max heart rate, no ride carrying a meter at all, or
/// meters and heart rates that never appear on the same ride. Only the first
/// two are things the athlete can do anything about, and the row did not say
/// which one it was.
struct PowerDiagnosis {
    let ftp: Int?
    let hrMax: Int?
    /// Outdoor rides long enough for TSS to mean anything.
    let rides: Int
    /// Of those, how many carry a real power meter.
    let withPower: Int
    /// Of those, how many also carry a heart rate.
    let withBoth: Int
    /// Of those, how many also had a resting rate for the day — the pairs the
    /// median is actually taken over.
    let usable: Int

    var reason: String? {
        if ftp == nil {
            // Both paths, because they are different screens and the one
            // this used to name is the web one. And "Refresh athlete", not
            // "Check now": Check now calls activities.sync() and has never
            // touched AthleteStore, so the old instruction pointed at a button
            // that could not have helped even once the endpoint was right.
            return "No FTP on the Strava profile. Set one in the Strava app "
                 + "under Settings → Training Zones → Power, or on strava.com "
                 + "under Settings → My Performance. Then: Sub4 → Settings → "
                 + "Strava → Refresh athlete. A ride's intensity cannot be "
                 + "computed without it."
        }
        if hrMax == nil {
            return "No max heart rate, so the heart-rate side of the conversion "
                 + "cannot be computed."
        }
        if withPower == 0 {
            return "\(rides) outdoor rides, none carrying a power meter."
        }
        if withBoth == 0 {
            return "\(withPower) rides carry a meter and none of them also "
                 + "carries a heart rate. The conversion is measured from rides "
                 + "with both, so there is nothing to measure it from."
        }
        if usable < PowerFactor.minSamples {
            return "\(usable) of \(PowerFactor.minSamples) rides carry a meter, "
                 + "a heart rate, and a resting rate for the day."
        }
        return nil
    }
}

enum PowerLoad {

    /// TSS is meaningless on a short effort — the whole construct assumes a
    /// steady state the ride has to be long enough to reach.
    static let minSeconds = 600

    /// Training Stress Score from average power.
    ///
    /// TSS = (AP/FTP)² × hours × 100. The intensity factor is squared, so a
    /// 10% error in FTP is a 20% error here — which is why the FTP has to be
    /// the measured one from Strava and never an estimate.
    /// OUTDOOR RIDES ONLY, and the discipline gate is the important line.
    ///
    /// His runs carry device watts too — running power, from the watch. Divided
    /// by a CYCLING FTP of 270 that is an intensity factor near 1.0 for an easy
    /// run, and then multiplied by a factor measured on a bike. The number that
    /// falls out is several times the truth and would drag the fitness curve up
    /// for six weeks. Nothing about the guard is defensive: without it the
    /// scored population and the calibrated population are different sets.
    ///
    /// Trainer rides are out for the same reason `calibrate` leaves them out —
    /// a turbo is a different power source, and converting one through a factor
    /// measured on the other averages two calibrations.
    static func tss(_ a: Activity, ftp: Int) -> Double? {
        guard a.discipline == .bike, a.isTrainer != true,
              a.hasRealPower, let ap = a.averageWatts, ap > 0,
              ftp > 50, a.movingTime >= minSeconds else { return nil }
        return tss(watts: ap, ftp: ftp, seconds: a.movingTime)
    }

    /// The formula on its own, so the self-test can check it against the
    /// published worked example instead of against itself.
    static func tss(watts: Double, ftp: Int, seconds: Int) -> Double {
        let intensity = watts / Double(ftp)
        return intensity * intensity * (Double(seconds) / 3600) * 100
    }

    /// How ragged the ride was, from the trace when there is one.
    ///
    /// Coefficient of variation of binned power. A steady ride sits near 0.2;
    /// above 0.5 the average is hiding a lot of surging and NP would have been
    /// materially higher, so the figure is a floor. Not used to reject — used
    /// to say so.
    static func roughness(_ s: ActivityStreams?) -> Double? {
        guard let p = s?.power, p.count >= 8 else { return nil }
        let live = p.filter { $0 > 0 }
        guard live.count >= 8 else { return nil }
        let mean = live.reduce(0, +) / Double(live.count)
        guard mean > 0 else { return nil }
        let variance = live.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(live.count)
        return variance.squareRoot() / mean
    }

    // MARK: Calibration

    /// Measure the conversion from rides that carry both a heart rate and a
    /// meter.
    ///
    /// Both sides use SESSION AVERAGES — average power against average heart
    /// rate — because mixing an integrated trace on one side with an average on
    /// the other would put the trace's 8% interval premium into the factor and
    /// then apply it to rides that never had intervals in them.
    ///
    /// Trainer rides are excluded. A smart trainer is a different power source
    /// from a pedal meter, and the spec is blunt that cross-source comparison
    /// is invalid; letting both into one median would average two calibrations.
    static func calibrate(activities: [Activity],
                          ftp: Int?,
                          hrMax: Int?,
                          hrRest: (String) -> Int?,
                          w: Double) -> PowerFactor? {
        guard let ftp, let hrMax else { return nil }

        var ratios: [Double] = []
        for a in activities {
            guard a.discipline == .bike, a.isTrainer != true,
                  let tss = tss(a, ftp: ftp), tss > 0,
                  let avgHR = a.averageHeartrate, avgHR > 30,
                  let rest = hrRest(a.dayKey),
                  hrMax - rest >= ConstantsStore.minSpread else { continue }
            let minutes = Double(a.movingTime) / 60
            let trimp = minutes * LoadEngine.trimpPerMinute(hr: avgHR, rest: rest,
                                                            max: hrMax, w: w)
            guard trimp > 0 else { continue }
            ratios.append(trimp / tss)
        }
        guard !ratios.isEmpty else { return nil }

        let sorted = ratios.sorted()
        let median = percentile(sorted, 0.5)
        let spread = median > 0
            ? (percentile(sorted, 0.75) - percentile(sorted, 0.25)) / median
            : 0
        return PowerFactor(k: median, sampleCount: sorted.count, spread: spread)
    }

    /// The same walk as `calibrate`, counting where each ride falls out.
    ///
    /// Deliberately a second pass rather than extra return values on
    /// `calibrate`: the calibration is used on every rebuild and must stay
    /// cheap and single-purpose, while this runs once for a diagnostics screen.
    static func diagnose(activities: [Activity],
                         ftp: Int?,
                         hrMax: Int?,
                         hrRest: (String) -> Int?) -> PowerDiagnosis {
        var rides = 0, withPower = 0, withBoth = 0, usable = 0
        for a in activities {
            guard a.discipline == .bike, a.isTrainer != true,
                  a.movingTime >= minSeconds else { continue }
            rides += 1
            guard a.hasRealPower, let ap = a.averageWatts, ap > 0 else { continue }
            withPower += 1
            guard let hr = a.averageHeartrate, hr > 30 else { continue }
            withBoth += 1
            guard let rest = hrRest(a.dayKey), let max = hrMax,
                  max - rest >= ConstantsStore.minSpread else { continue }
            usable += 1
        }
        return PowerDiagnosis(ftp: ftp, hrMax: hrMax, rides: rides,
                              withPower: withPower, withBoth: withBoth,
                              usable: usable)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let pos = p * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Swift.min(lo + 1, sorted.count - 1)
        return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
    }
}
