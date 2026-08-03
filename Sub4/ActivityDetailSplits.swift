//
//  ActivityDetailSplits.swift
//  Sub4
//
//  The splits card: kilometre, laps, reps, and the plan-derived cut.
//
//  SPLIT OUT OF ActivityDetailView.swift IN PATCH 171. That file had reached
//  2,150 lines and held every card on the page. These pieces moved wholesale,
//  unchanged except that members shared with the view lost `private` —
//  Swift's file-scoped privacy cannot cross a file split.
//

import SwiftUI

extension ActivityDetailView {

    // MARK: Splits
    //
    // NOT ON MOVEMENT — patch 148.
    //
    // Strava produces kilometre splits for anything with GPS, so a lunchtime
    // walk arrived here with a table reading 13:38, 9:34, 13:55 and bars painted
    // "faster" and "slower". Every one of those numbers is a traffic light, a
    // phone call, or a stop to look in a window. Grading them is the app
    // inventing a performance nobody attempted.
    //
    // THE GATE IS `isPlanEligible`, NOT `session != nil`.
    //
    // The request was to drop splits on unplanned sessions, and taken literally
    // that would also drop them from an unmatched RUN — a run you did that the
    // plan did not ask for, or one whose match failed. "Did I drift over eight
    // kilometres" is a real question about a run whether or not a plan wanted
    // it, and the card already answers it honestly without a target: the
    // baseline falls back to the session's own median and says so.
    //
    // `isPlanEligible` is the app's existing line between training and movement
    // — a ride over 10 km, a run over 1.5, a swim over 400 m — so this needs no
    // new rule and no new constant. What it removes is exactly the set that was
    // wrong: walks, hikes, kayaks, and the sub-10 km bike commute, whose
    // "KILOMETRE SPEED" table was the same noise wearing a different label.
    @ViewBuilder
    func splitsCard(_ ctx: SplitContext) -> some View {
        if activity.discipline != .swim, activity.isPlanEligible,
           let d = detail, d.hasSplits, let base = baseline(d) {
            let modes = availableModes(ctx)
            let mode = splitMode.flatMap { modes.contains($0) ? $0 : nil }
                    ?? defaultMode(modes, ctx)
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle(splitsTitle(mode),
                             mode == .km ? baselineLabel
                                         : (mode == .plan ? planSubtitle
                                                          : intervalSubtitle(ctx)))

                // The picker appears only when there is more than one way to
                // read the run. On an easy 8 km there is exactly one, and a
                // segmented control with a single segment is furniture.
                if modes.count > 1 {
                    Picker("", selection: Binding(get: { mode },
                                                  set: { splitMode = $0 })) {
                        ForEach(modes, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .km {
                    SplitTable(splits: d.displaySplits,
                               baseline: base,
                               band: measurableTarget.map { ($0.low, $0.high) },
                               asSpeed: activity.discipline == .bike,
                               tint: tint)
                } else if mode == .plan, let segs = planSegments {
                    PlanSplitTable(segments: segs,
                                   band: measurableTarget.map { ($0.low, $0.high) },
                                   footnote: planFootnote)
                } else if let i = intervals(mode, ctx) {
                    IntervalTable(splits: i, tint: tint)
                }
            }
            .cardStyle()
        }
    }

    // MARK: Which views of the splits exist

    enum SplitMode: String, Hashable {
        case km, laps, reps, plan
        var label: String {
            switch self {
            case .km:   return "Km"
            case .laps: return "Laps"
            case .reps: return "Reps"
            // "Laps", not "Plan" — patch 165.
            //
            // These two modes are mutually exclusive by construction: the
            // derived split is only offered when the watch recorded none. So
            // there is never a picker with both on it, and two names for one
            // slot would be the interface changing vocabulary depending on which
            // watch button got pressed.
            //
            // The provenance does not disappear with the label. It moves to the
            // footer, which is where the recorded view has always stated its own
            // — "the laps the watch recorded, unmodified" against "split at the
            // planned 8 km, the watch recorded none". Same sentence position,
            // opposite claim, and neither pretends to be the other.
            case .plan: return "Laps"
            }
        }
    }

    func intervals(_ mode: SplitMode, _ ctx: SplitContext) -> IntervalSplits? {
        mode == .laps ? ctx.laps : ctx.reps
    }

    func availableModes(_ ctx: SplitContext) -> [SplitMode] {
        var out: [SplitMode] = [.km]
        if ctx.laps != nil { out.append(.laps) }
        if let r = ctx.reps, !r.reps.isEmpty { out.append(.reps) }
        // Only when the watch recorded none. With real laps the derived split
        // is not a second opinion, it is the same boundary guessed at: on the
        // 30 July run the watch's own mark landed at 4.98 km against a planned
        // 5.00, and offering both put two tabs on the card that differed by
        // twenty metres.
        if ctx.laps == nil, planSegments != nil { out.append(.plan) }
        return out
    }

    /// A session prescribed in minutes opens on its reps, because kilometres
    /// are the view that cannot answer its question. Everything else opens on
    /// kilometres.
    func defaultMode(_ modes: [SplitMode], _ ctx: SplitContext) -> SplitMode {
        guard let s = session, let t = PaceTarget.parse(s), !t.isMeasurable
        else { return .km }
        if modes.contains(.laps), ctx.laps?.matchesPlan == true { return .laps }
        if modes.contains(.reps) { return .reps }
        if modes.contains(.laps) { return .laps }
        return .km
    }

    // MARK: The plan view — patch 164
    //
    // WHAT IT ANSWERS THAT NOTHING ELSE DOES. The verdict at the top of the page
    // says "average, whole run", and on a session you overran that average is
    // taken over a distance the plan never asked for. Eight kilometres were
    // asked; 8.42 were run; the figure being graded is the 8.42. The difference
    // is small and it is not nothing — the tail of a run is where the pace goes,
    // and it is the part you added.
    //
    // So: the asked distance as one segment, the rest as another, each with its
    // own pace. It is the only place in the app that states the pace over
    // exactly what was prescribed.
    //
    // CALLED "PLAN" AND NOT "LAPS", DELIBERATELY. A lap is a button press — a
    // thing that happened, recorded at the moment it happened. This boundary is
    // DERIVED, from a distance written down weeks earlier, and a session can
    // carry both at once. Filing a derivation under the name of a measurement is
    // the one habit this project has consistently refused; see the header of
    // DataCorrections for the same argument about a different table.
    //
    // WHOLE KILOMETRES ONLY, AND THAT IS WHY THIS NEEDS NO STREAM. Planned run
    // distances in this plan are whole numbers, and Strava's splits are cut at
    // the kilometre — so the boundary falls exactly on a split edge and the two
    // segments are sums of rows rather than an interpolation. If a plan ever
    // states 7.5 km the guard below drops the view rather than inventing a cut.

    var planSegments: [PlanSegment]? {
        guard activity.discipline == .run,
              let s = session, let d = detail, d.hasSplits else { return nil }
        let planned = PlanStore.plannedRunKm(s)
        // `exact` matters: an estimate converted from minutes is not a boundary,
        // it is a guess, and cutting a run at a guess produces two figures that
        // look measured and are not.
        guard planned.exact, planned.km >= 1 else { return nil }

        let rows = d.displaySplits
        let target = planned.km * 1000

        // THE CUT IS MADE ON MEASURED DISTANCE, NOT ON A ROW COUNT — patch 166.
        //
        // This used to be `rows.prefix(8)` for a planned 8 km, on the assumption
        // that eight displayed rows are eight kilometres. They are not always:
        // `displaySplits` drops fragments under 100 m, so a run paused mid-way
        // hands back a list whose eighth row ends somewhere past the eighth
        // kilometre. Accumulating distance cannot drift that way.
        var cut = 0
        var run = 0.0
        for (i, r) in rows.enumerated() {
            run += r.distanceM
            cut = i + 1
            if run >= target - 1 { break }
        }
        guard cut < rows.count else { return nil }

        func fold(_ part: ArraySlice<ActivityDetail.Split>, _ id: Int,
                  _ name: String) -> PlanSegment {
            let m = part.reduce(0.0) { $0 + $1.distanceM }
            let t = part.reduce(0) { $0 + $1.movingTime }
            // Duration-weighted, because a 200 m tail and a 1 km split are not
            // equal witnesses to an average heart rate.
            let num = part.reduce(0.0) { $0 + ($1.averageHR ?? 0) * Double($1.movingTime) }
            let den = part.filter { ($0.averageHR ?? 0) > 0 }
                          .reduce(0) { $0 + $1.movingTime }
            return PlanSegment(id: id,
                               label: String(format: "%@ · %.2f km", name, m / 1000),
                               metres: m, seconds: t,
                               avgHR: den > 0 ? num / Double(den) : nil)
        }

        let asked = fold(rows.prefix(cut), 0, "Asked")
        let extra = fold(rows.dropFirst(cut), 1, "Extra")
        // A tail shorter than a hundred metres is a rounding artefact of where
        // the watch stopped, not a decision to run further.
        guard extra.metres >= 100 else { return nil }
        return [asked, extra]
    }

    func splitsTitle(_ mode: SplitMode) -> String {
        switch mode {
        case .km:   return activity.discipline == .bike ? "KILOMETRE SPEED"
                                                        : "KILOMETRE SPLITS"
        case .laps: return "LAPS"
        case .reps: return "REPS"
        case .plan: return "LAPS"
        }
    }

    var planSubtitle: String {
        measurableTarget.map { "target \(Fmt.pace($0.low))–\(Fmt.pace($0.high))" } ?? ""
    }

    /// The counterpart to "the laps the watch recorded, unmodified". Said in the
    /// same place and with the same weight, because the reader cannot see which
    /// of the two they are looking at from the tab alone.
    ///
    /// IT ALSO CARRIES A DISCREPANCY THIS VIEW WAS THE FIRST TO EXPOSE.
    /// Strava reports three different distances for a run and does not reconcile
    /// them. On 1 August 2026 the activity says 8 416 m, its single lap says
    /// 8 363, and `splits_metric` sums to about 8 567 — a spread of 200 m on
    /// eight and a half kilometres. Every other card reads one of those numbers
    /// and prints it; this one is the first to add two of them up in public, so
    /// it is the first place the disagreement becomes visible.
    ///
    /// Nothing is corrected. The segments are sums of split rows and are exactly
    /// as true as the rows; the hero figure is the activity's own distance and is
    /// exactly as true as Strava's. When they differ by more than a percent the
    /// card says so, because two numbers on one screen that cannot both be right
    /// need the reader told, not reconciled by a fudge.
    var planFootnote: String {
        guard let s = session else { return "" }
        let p = PlanStore.plannedRunKm(s)
        var line = String(format: "The watch recorded no laps — split at the planned %.0f km.",
                          p.km)
        if let d = detail {
            let summed = d.displaySplits.reduce(0.0) { $0 + $1.distanceM }
            let whole = activity.distance
            if whole > 0, abs(summed - whole) / whole > 0.01 {
                line += String(format: " Strava's splits total %.2f km against the "
                               + "activity's %.2f — both are its own figures, unaltered.",
                               summed / 1000, whole / 1000)
            }
        }
        return line
    }

    func intervalSubtitle(_ ctx: SplitContext) -> String {
        guard let p = ctx.plan else { return "" }
        return "target \(p.work.label) /km"
    }

    /// The line each kilometre is measured against: the plan's target when it
    /// states one, otherwise this session's own median. Never an invented number.
    func baseline(_ d: ActivityDetail) -> Int? {
        if let t = measurableTarget { return t.midpoint }
        return d.medianSplitPace
    }

    /// WITH a target the subtitle is empty: the band is printed once, in the
    /// verdict at the top of the page, and the shaded zone behind the bars is
    /// where it is needed here. WITHOUT one the baseline is this run's own
    /// median, which nothing else on the page states — so it still has to.
    var baselineLabel: String {
        measurableTarget == nil ? "vs this session's median" : ""
    }

    /// The plan's target, but only when kilometre splits can actually be judged
    /// against it. A threshold session's 4×8 min can't, so its splits are shown
    /// against their own median instead of being painted red for being a warm-up.
    var measurableTarget: PaceTarget? {
        guard activity.discipline == .run, let s = session,
              let t = PaceTarget.parse(s), t.isMeasurable else { return nil }
        return t
    }

}
