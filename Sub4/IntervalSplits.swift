//
//  IntervalSplits.swift
//  Sub4
//
//  Reps, for the sessions kilometres cannot describe.
//
//  THE PROBLEM
//  -----------
//  Seven sessions in this block are prescribed in minutes: "2k WU + 4×8min
//  @4:55–5:10 (2min float) + CD". A kilometre split cannot isolate an eight
//  minute rep from the float and warm-up wrapped around it, so those sessions
//  got a target, an explanation, and no verdict — on the sessions where the
//  number matters most.
//
//  TWO SOURCES, IN THIS ORDER
//  --------------------------
//  1. LAPS. If the watch recorded them — because the workout was sent to it, or
//     because the lap button was pressed — they are the athlete's own marks and
//     nothing here has to infer anything. Exact, and preferred whenever present.
//
//  2. THE SPEED STREAM. Segment the run by pace and read the reps out of it.
//     Available on every GPS run, retroactively, with no button to remember.
//
//  WHY SEGMENTATION AND NOT SEARCH
//  -------------------------------
//  The obvious approach — find the four fastest eight-minute windows — is the
//  wrong one, and flatteringly so: it returns the best four windows of ANY run,
//  including one where the reps were missed entirely. This walks the run in
//  order and cuts it where the pace changes. A rep that was run slowly stays in
//  the result, slow.
//
//  The threshold is not invented either. The plan states both numbers:
//  "3×6min @4:55–5:10 (2min float @6:00–6:15)" gives the work band AND the
//  float band, and the cut goes between them. Where the float pace is not
//  stated, the cut sits a fixed distance slower than the work band and the
//  result is marked as such.
//
//  WHAT IT REFUSES TO DO
//  ---------------------
//  Claim a verdict when the rep count it found does not match the rep count the
//  plan asked for. Three reps where the plan said four means either the session
//  changed or the detection is wrong, and there is no way to tell which from
//  here. The segmentation is shown; the judgement is withheld and the reason is
//  printed. A wrong verdict on an interval session is worse than none, because
//  it is the session you would act on.
//
//  It also refuses when the trace is too coarse to hold a rep. Streams are
//  stored resampled to 300 distance-aligned bins — about twelve seconds each on
//  a threshold run. That is thirty-odd points across an eight-minute rep and
//  four across a one-minute one. Below six points per rep this returns nothing
//  rather than a shape built from noise, which is why the two "3×1min" primers
//  in weeks 20 and 34 get laps or nothing at all.
//

import Foundation

// MARK: - What the plan asked for

/// The interval structure of a session, read from the plan's own text through
/// the same parser that builds the Watch workout — never re-parsed here.
struct IntervalPlan: Hashable {
    let reps: Int
    /// Seconds per rep. nil when the reps are prescribed by distance, in which
    /// case kilometre splits already work and this whole file is unnecessary.
    let repSeconds: Int?
    let work: PlanStep.Pace
    let float: PlanStep.Pace?

    static func from(_ session: Session) -> IntervalPlan? {
        guard let w = WorkoutParser.parse(session).workout else { return nil }
        guard let block = w.steps.first(where: { $0.kind == .block
                                                 && $0.iterations > 1 }),
              let pace = block.pace else { return nil }
        var secs: Int?
        if case .time(let t) = block.goal { secs = t }
        return IntervalPlan(reps: block.iterations, repSeconds: secs,
                            work: pace, float: block.recoveryPace)
    }

    /// The pace at which a sample stops counting as work, knowing only the plan.
    ///
    /// Halfway between the slow end of the work band and the fast end of the
    /// float band when the plan states both. Where it does not, a fixed gap —
    /// used for filtering laps, where there is no pace trace to look at. The
    /// detector has one and derives a better cut from it.
    var cutSecPerKm: Int {
        if let f = float, f.fast > work.slow { return (work.slow + f.fast) / 2 }
        return work.slow + Self.assumedGap
    }

    /// The fallback gap when the plan states no float pace and there is no
    /// trace to measure one from.
    static let assumedGap = 40

    var floatStated: Bool { float != nil }
}

// MARK: - One rep

struct RepSplit: Identifiable, Hashable {
    let index: Int
    let isWork: Bool
    let seconds: Int
    let metres: Double
    let avgHR: Double?

    var id: Int { index }

    var paceSecPerKm: Int {
        guard metres > 20, seconds > 0 else { return 0 }
        return Int((Double(seconds) / (metres / 1000)).rounded())
    }

    /// "—" rather than "0:00" when there is no distance to divide by. The
    /// kilometre table learned this the hard way: a pace of zero is not a fast
    /// one, and colouring it as such put a cyan "0:00" at the top of a list.
    var paceLabel: String { paceSecPerKm > 0 ? Fmt.pace(paceSecPerKm) : "—" }

    var distanceLabel: String {
        metres >= 1000 ? String(format: "%.2f km", metres / 1000)
                       : String(format: "%.0f m", metres)
    }
}

// MARK: - The result

struct IntervalSplits {

    enum Source {
        case laps           // the watch's own marks
        case detected       // segmented from the speed stream

        var label: String { self == .laps ? "Laps" : "Reps" }
    }

    let source: Source
    /// Work segments only. Floats are not shown as rows: they are the gaps.
    let reps: [RepSplit]
    /// nil when the session is not an interval session, or was not parseable.
    let plan: IntervalPlan?
    /// True when the float threshold came from the plan rather than from the
    /// run. Printed, because it changes how much the cut can be trusted.
    let floatStated: Bool
    /// The threshold actually used, in seconds per km. Carried rather than
    /// re-derived so the sentence under the table can print the real number
    /// instead of describing a rule that may have been clamped.
    let cutSecPerKm: Int

    var count: Int { reps.count }

    /// The whole point: total work time and the pace across all of it.
    var workSeconds: Int { reps.reduce(0) { $0 + $1.seconds } }
    var workMetres: Double { reps.reduce(0) { $0 + $1.metres } }

    var meanPace: Int? {
        guard workMetres > 100, workSeconds > 0 else { return nil }
        return Int((Double(workSeconds) / (workMetres / 1000)).rounded())
    }

    /// A verdict is only claimed when the count matches what was asked for.
    var matchesPlan: Bool {
        guard let p = plan else { return false }
        return p.reps == reps.count
    }

    /// Why no verdict, in the app's own voice. nil when there IS one.
    var refusal: String? {
        guard let p = plan else { return "No interval structure in the plan for this session." }
        if reps.isEmpty {
            return "Nothing in this run separates into reps at the pace the plan asked for."
        }
        if !matchesPlan {
            return "Found \(reps.count) rep\(reps.count == 1 ? "" : "s") where the "
                 + "plan asked for \(p.reps). Either the session changed or the "
                 + "split is wrong, and there is no way to tell which from here — "
                 + "so no verdict is claimed."
        }
        return nil
    }
}

// MARK: - Detection

enum IntervalDetector {

    /// Minimum samples inside a rep before a shape can be read from it. Below
    /// this the "rep" is three points of a smoothed curve.
    static let minSamplesPerRep = 6

    /// Hysteresis, in seconds per km, either side of the cut. Without it a
    /// pace hovering at the threshold produces a dozen one-sample reps.
    static let hysteresis = 6

    /// Laps as reps.
    ///
    /// A lap is only counted as work when it is at least a third of a minute
    /// long — Apple's own Workout app emits a zero-length lap at the start of
    /// some workouts, and a 2-second lap in a list of 8-minute ones reads as a
    /// failed rep rather than as the artefact it is.
    static func fromLaps(_ laps: [ActivityDetail.Lap],
                         plan: IntervalPlan?) -> IntervalSplits? {
        guard laps.count >= 2 else { return nil }

        // Laps that are plausibly work. When the plan states a threshold, a lap
        // slower than it is the float or the warm-up and is a gap, not a row.
        let cut = plan?.cutSecPerKm
        let work = laps.filter { l in
            guard l.movingTime >= 20, l.distanceM >= 50 else { return false }
            guard let cut else { return true }
            return Int(Double(l.movingTime) / (l.distanceM / 1000)) < cut
        }

        // Auto-lap, not intervals. Every watch marks a lap each kilometre by
        // default, and ten 1 km laps on an easy run are not ten reps — offering
        // them as such would put a "LAPS" tab on almost every run in the app and
        // make "found 10 reps where the plan asked for 4" the usual sentence.
        let uniform = work.count >= 3
            && work.allSatisfy { abs($0.distanceM - 1000) < 25 }
        guard !uniform, work.count >= 2 else { return nil }

        // Numbered after filtering: a dropped zero-length opening lap must not
        // leave the list starting at 2.
        let reps = work.enumerated().map { i, l in
            RepSplit(index: i + 1, isWork: true, seconds: l.movingTime,
                     metres: l.distanceM, avgHR: l.averageHR)
        }
        return IntervalSplits(source: .laps, reps: reps, plan: plan,
                              floatStated: plan?.floatStated ?? false,
                              cutSecPerKm: cut ?? 0)
    }

    /// Reps segmented out of the speed stream.
    ///
    /// Every bin is the same DISTANCE (the stream is resampled that way), so a
    /// bin's duration is its width over its speed, and its pace is the speed
    /// inverted. No time stream is needed, and none is fetched.
    static func detect(_ s: ActivityStreams, plan: IntervalPlan) -> IntervalSplits? {
        // Reps written as a distance need none of this — kilometre splits
        // already answer that session, and the file exists for the ones they
        // cannot answer.
        guard let want = plan.repSeconds else { return nil }
        guard let speed = s.speed, speed.count == s.count, s.count >= 20,
              let total = s.distanceM.last, total > 0 else { return nil }

        // distanceM holds bin CENTRES — the last one sits half a bin short of
        // the total — so dividing by the count would shrink every rep by half a
        // bin. Small, but it lands on durations printed against a plan written
        // in whole minutes.
        let binWidth = total / (Double(s.count) - 0.5)
        // Seconds in each bin. A stationary bin would be infinite; the stream
        // is distance-resampled so those do not exist, but the clamp is cheap.
        let secs = speed.map { $0 > 0.3 ? binWidth / $0 : 0 }
        let pace = speed.map { $0 > 0.3 ? Int((1000 / $0).rounded()) : 9999 }

        // WHERE THE CUT GOES
        //
        // With a stated float pace, between the two bands — the plan has
        // already said where the line is.
        //
        // Without one, from the run itself: halfway between the work band and
        // the run's own slow quartile, which in an interval session is the
        // warm-up, the floats and the cool-down. A fixed 40 s/km gap was tried
        // first and is wrong for week 4, whose work band is 5:10–5:20 and whose
        // warm-up is 6:00 — the cut landed exactly on the warm-up and swallowed
        // it into the first rep. Clamped either side so it can never fall inside
        // the work band, nor drift more than a minute off it.
        let cut: Int
        if plan.floatStated {
            cut = plan.cutSecPerKm
        } else {
            let sorted = pace.sorted()
            let slowQuartile = sorted[min(Int(Double(sorted.count) * 0.75),
                                          sorted.count - 1)]
            cut = max(plan.work.slow + 10,
                      min(plan.work.slow + 60, (plan.work.slow + slowQuartile) / 2))
        }

        // SEPARATION GUARD — does the cut cut anything?
        //
        // Week 20's primer is "5 km easy @5:45–6:00 + 3×1min @5:38–5:43": one
        // minute of surge, fifteen seconds per kilometre quicker than the easy
        // running around it. No threshold separates those, and without this
        // guard the detector returns the whole 30-minute easy run as one
        // enormous "rep" — a number that looks exactly like a measurement.
        //
        // Real interval sessions put 35–58% of their bins on the work side of
        // the cut. A run where more than 70% qualifies is not a run this can
        // read, so it says nothing at all.
        let workBins = pace.filter { $0 < cut }.count
        guard Double(workBins) / Double(pace.count) <= 0.70 else { return nil }

        // Seconds per bin, measured on the WORK side of the cut only. The
        // whole-run median is dragged long by the warm-up, the floats and the
        // cool-down — every one of them slower, so every one of them more
        // seconds per bin — and a rep floor derived from it comes out ~17% too
        // small, letting a stray burst through as an extra rep.
        let workSecs = zip(pace, secs).filter { $0.0 < cut }.map(\.1).sorted()
        let median = workSecs.isEmpty ? secs.sorted()[secs.count / 2]
                                      : workSecs[workSecs.count / 2]

        // Resolution gate — is a rep even representable in this trace?
        guard median > 0, Double(want) / median >= Double(minSamplesPerRep)
        else { return nil }
        var inWork = false
        var runs: [(from: Int, to: Int)] = []
        var start = 0
        for i in pace.indices {
            if inWork {
                if pace[i] > cut + hysteresis {
                    runs.append((start, i - 1)); inWork = false
                }
            } else if pace[i] < cut - hysteresis {
                start = i; inWork = true
            }
        }
        if inWork { runs.append((start, pace.count - 1)) }

        // Drop anything too short to be the rep that was asked for — half the
        // stated rep length, in bins.
        let floor = max(minSamplesPerRep,
                        Int(Double(want) * 0.5 / max(median, 0.1)))
        // And a ceiling. A continuous tempo twice as long as the rep asked for
        // is not that rep, and reporting it as one would turn a session run
        // differently into a session run to plan.
        let ceiling = Int(Double(want) * 2.0 / max(median, 0.1))
        let kept = runs.filter {
            let n = $0.to - $0.from + 1
            return n >= floor && n <= ceiling
        }
        guard !kept.isEmpty else {
            return IntervalSplits(source: .detected, reps: [], plan: plan,
                                  floatStated: plan.floatStated,
                                  cutSecPerKm: cut)
        }

        let hr = s.heartRate
        let reps = kept.enumerated().map { i, r -> RepSplit in
            let range = r.from...r.to
            let t = range.reduce(0.0) { $0 + secs[$1] }
            let m = Double(range.count) * binWidth
            var bpm: Double?
            if let hr, hr.count == s.count {
                let v = range.map { hr[$0] }.filter { $0 > 0 }
                if !v.isEmpty { bpm = v.reduce(0, +) / Double(v.count) }
            }
            return RepSplit(index: i + 1, isWork: true, seconds: Int(t.rounded()),
                            metres: m, avgHR: bpm)
        }
        // TOO MANY TO BE REPS
        //
        // Week 20's primer again, from the other side: with the cut landing in
        // the middle of the easy running, the noise either side of it segments
        // into ten "reps" of a minute each. Twice what was asked is already a
        // trace that is not separating reps, and ten rows of invented structure
        // are worse than no tab at all.
        guard reps.count <= plan.reps * 2 else { return nil }

        return IntervalSplits(source: .detected, reps: reps, plan: plan,
                              floatStated: plan.floatStated,
                              cutSecPerKm: cut)
    }
}
