//
//  PlanVolumeChart.swift
//  Sub4
//
//  The shape of the whole block, on the Plan tab.
//
//  COMPUTED, NOT DRAWN
//  -------------------
//  Every bar comes from `PlanStore.plannedDistance(week:)` — the same estimator
//  the Plan rows, the Progress totals and the monthly review already use.
//  Nothing here is a figure typed in by hand, so extending the plan, rewriting a
//  session or re-running `extract_plan.py` changes this chart with everything
//  else. A picture of the plan that could disagree with the plan would be worse
//  than no picture.
//
//  EVERY SPORT THE PLAN GIVES A DISTANCE FOR
//  -----------------------------------------
//  Not running only. This block happens to be 97% running by distance — 1,223 km
//  of running against 38 km of swimming — but the next one need not be, and a
//  chart that could only see running would silently under-draw a plan with a
//  60 km Saturday ride in it. Whatever the plan states as a distance is in the
//  bar, in the unit the plan wrote it: kilometres for running and cycling,
//  metres for swimming.
//
//  WHAT IS NEVER IN IT: TIME
//  -------------------------
//  "2 h outdoor Z2" contributes nothing. Turning an hour into a distance needs a
//  pace the plan does not state for that sport, and the guess would arrive
//  wearing the same units as the measurements beside it — which is exactly how a
//  chart starts lying. The bike is 61.5 required hours in this block and none of
//  it is here; Progress counts bikes in hours, where they belong.
//
//  Running is the one exception, because the plan does state a pace for the runs
//  it writes in minutes. Those weeks are faded and marked ≈.
//
//  EMPHASIS, NOT CATEGORY
//  ----------------------
//  The bar's colour is not a sport, it is the week's weight: hard weeks forward,
//  recovery weeks back, everything else neutral. The plan's own badge decides
//  it. Sport is encoded by stacking instead — running from the baseline, every
//  other sport as one segment above it — so the two encodings cannot be
//  confused for each other, and adding a third sport later needs no new colour.
//  The week numbers, the legend and the tap detail all repeat what the colours
//  say.
//
//  Approximate weeks are drawn faded rather than solid. Several of the 34 hold a
//  run written only in minutes, or a bare warm-up with no distance attached, so
//  their total is a conversion, not a measurement — and a bar that looked
//  identical to a measured one would be quietly overstating what the plan
//  actually says.
//
//  COMPUTED ONCE
//  -------------
//  `points` is not cheap: 34 weeks × two passes over 260 sessions × a dozen
//  regexes per run session. `chartXSelection` writes on every frame of a drag,
//  so recomputing it inside `body` would re-run the whole estimator per frame.
//  It is computed once, cached, and recomputed only if the plan itself changes.
//

import SwiftUI
import Charts

struct PlanVolumeChart: View {

    private let store = PlanStore.shared

    struct Point: Identifiable {
        let weekNo: Int
        let label: String
        /// Every sport the plan gives this week a distance for.
        let km: Double
        let runKm: Double
        let otherKm: Double
        /// "run 44 · swim 1.5" — built by PlanStore from the same parts.
        let composition: String
        let longest: Double
        let exact: Bool
        let kind: WeekKind?
        let tag: String?
        var id: Int { weekNo }

        var isHard: Bool { kind?.isHard ?? false }
    }

    @State private var selected: Int?

    /// Everything derived from the plan, in one value.
    ///
    /// Both the points and the sport list walk all 260 sessions through the
    /// parser, and `chartXSelection` writes on every frame of a drag — computing
    /// either inside `body` would re-run the whole estimator per frame. Built
    /// once, and only rebuilt if the plan itself changes.
    struct Model {
        let points: [Point]
        let otherSports: [Discipline]
    }

    @State private var cache: Model?

    /// Falls back to building directly on the very first pass, before
    /// `onAppear` has run, so nothing flashes blank.
    private var model: Model { cache ?? build() }

    private func build() -> Model {
        Model(points: points, otherSports: otherSports)
    }

    private var points: [Point] {
        store.planWeeks.compactMap { w in
            guard let n = w.weekNo else { return nil }
            let d = store.plannedDistance(week: w)
            // The line is the longest RUN specifically — the number the long-run
            // build is aiming at. A 1.5 km swim is not a candidate for it.
            let longest = store.sessions(inWeek: w)
                .filter { $0.discipline == .run }
                .map { PlanStore.plannedRunKm($0).km }
                .max() ?? 0
            return Point(weekNo: n, label: w.label, km: d.km,
                         runKm: d.runKm, otherKm: d.otherKm,
                         composition: d.composition, longest: longest,
                         exact: d.exact, kind: w.weekKind, tag: w.tag)
        }
    }

    private var currentWeekNo: Int? {
        store.week(containing: DayKey.key())?.weekNo
    }

    /// The sports other than running that appear anywhere in the block. Names
    /// the stacked segment, so a plan that adds cycling distance renames itself.
    private var otherSports: [Discipline] {
        let d = store.planWeeks
            .flatMap { store.sessions(inWeek: $0) }
            .filter { $0.discipline != .run
                      && PlanStore.plannedDistanceKm($0).km > 0 }
            .map(\.discipline)
        return PlanStore.distanceDisciplines
            .filter { $0 != .run && d.contains($0) }
    }

    private func otherLabel(_ s: [Discipline]) -> String {
        s.count == 1 ? s[0].label : "Other sports"
    }

    // Emphasis palette. Validated against #0f1115 with the dataviz validator,
    // all pairs: worst CVD separation ΔE 10.8 (green↔amber, protanopia) and
    // worst normal-vision separation ΔE 17.7 (blue↔grey), both clear of the
    // floors. It fails that validator's chroma check on purpose — the grey is a
    // de-emphasis grey and is meant to read as grey.
    private let hardTint = Color.atlTint
    private let restTint = Discipline.rest.tint
    private let baseTint = Discipline.run.tint
    private let otherTint = Discipline.swim.tint

    private func tint(_ p: Point) -> Color {
        if p.isHard { return hardTint }
        if p.kind?.isRecovery == true { return restTint }
        return baseTint
    }

    var body: some View {
        let m = model
        return VStack(alignment: .leading, spacing: 9) {
            header(m.points)
            chart(m.points)
            legend(m.otherSports)
            footnote
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        // `m` is already built above — calling build() again here would sweep
        // all 260 sessions a second time on first appearance.
        //
        // There is no invalidation, and that is not an oversight: PlanStore is
        // deliberately not @Observable and `plan` is a `let`, so the plan cannot
        // change while the app runs. When the monthly review starts rewriting
        // sessions that stops being true, and this cache has to be revisited
        // with it. A key on `plan.sessions.count` would look like a guard and
        // be inert — worse than none.
        .onAppear { if cache == nil { cache = m } }
    }

    // MARK: Header — the selected week, or the block summary

    private func header(_ pts: [Point]) -> some View {
        let sel = selected.flatMap { n in pts.first { $0.weekNo == n } }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sel == nil ? "Planned distance" : "Week \(sel!.label)")
                    .font(.subheadline.weight(.semibold))
                Text(sel.map { subtitle($0) } ?? blockSubtitle(pts))
                    .font(.caption).foregroundStyle(Color.dim)
                    .lineLimit(1)
            }
            Spacer()
            if let s = sel {
                Text(String(format: "%@%.0f km", s.exact ? "" : "≈", s.km))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint(s))
                // Charts keeps the selection after the finger lifts, and
                // nothing else clears it — without this the block summary is
                // gone for good after the first tap.
                Button {
                    selected = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(Color.dim)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func subtitle(_ p: Point) -> String {
        var bits: [String] = []
        if let t = p.tag, !t.isEmpty { bits.append(t) }
        if p.otherKm > 0.05 { bits.append(p.composition) }
        if p.longest > 0 { bits.append(String(format: "long %.0f km", p.longest)) }
        return bits.joined(separator: " · ")
    }

    private func blockSubtitle(_ pts: [Point]) -> String {
        let total = pts.reduce(0) { $0 + $1.km }
        let run = pts.reduce(0) { $0 + $1.runKm }
        // Race week is excluded from "peak": its 57 km is 42.2 km of marathon
        // and would name the race as the biggest training week of the block.
        let peak = pts.filter { $0.kind != .race }.max { $0.km < $1.km }
        let approx = pts.contains { !$0.exact }
        let head = String(format: "%@%.0f km", approx ? "≈" : "", total)
        let split = total - run > 0.5
            ? String(format: " · %.0f run", run) : ""
        return head + split
            + String(format: " · peak wk %@ at %.0f",
                     peak?.label ?? "—", peak?.km ?? 0)
    }

    // MARK: The chart

    private func chart(_ pts: [Point]) -> some View {
        Chart {
            // Running, from the baseline. Coloured by the week's weight.
            ForEach(pts) { p in
                BarMark(
                    x: .value("Week", p.weekNo),
                    y: .value("km", p.runKm),
                    width: .fixed(6)
                )
                .foregroundStyle(tint(p))
                // Estimated weeks are faded. A measured 46 km and a converted
                // 23 km should not look like the same kind of number.
                .opacity(p.exact ? 1 : 0.45)
                .cornerRadius(2)
            }

            // Everything else the plan states a distance for, stacked above it.
            // One segment whatever the sport: this encodes "not running", and a
            // second sport arriving later must not need a second colour.
            ForEach(pts) { p in
                BarMark(
                    x: .value("Week", p.weekNo),
                    y: .value("km", p.otherKm),
                    width: .fixed(6)
                )
                .foregroundStyle(otherTint)
                .opacity(p.exact ? 1 : 0.45)
                .cornerRadius(2)
            }

            // The week's longest run, same unit and therefore the same axis —
            // never a second scale.
            ForEach(pts) { p in
                LineMark(
                    x: .value("Week", p.weekNo),
                    y: .value("km", p.longest),
                    series: .value("s", "long")
                )
                .foregroundStyle(Color.ink.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1.4))
                .interpolationMethod(.monotone)
            }

            if let now = currentWeekNo {
                RuleMark(x: .value("Week", now))
                    .foregroundStyle(Color.accent4.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .chartXAxis {
            // Ticks come from the data, not from "34" — a plan that grows or
            // shrinks must not lose its labels.
            AxisMarks(values: Array(stride(from: 5,
                                           through: pts.last?.weekNo ?? 34,
                                           by: 5))) { v in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.3))
                AxisValueLabel {
                    if let n = v.as(Int.self) {
                        Text("\(n)").font(.caption2).foregroundStyle(Color.dim)
                    }
                }
            }
        }
        .frame(height: 150)
    }

    // MARK: Legend
    //
    // Present because the colours carry meaning. The marker shapes repeat what
    // the colour says, so a reader who cannot separate amber from green loses
    // nothing. The fourth item appears only in a plan that actually contains a
    // second sport with a distance.

    private func legend(_ others: [Discipline]) -> some View {
        HStack(spacing: 11) {
            LegendItem(.symbol("star.fill", hardTint), "Hard")
            LegendItem(.symbol("arrowtriangle.down.fill", restTint), "Recovery")
            LegendItem(.square(baseTint), "Build")
            if !others.isEmpty {
                LegendItem(.symbol("chevron.up", otherTint), otherLabel(others))
            }
            Spacer()
        }
    }

    // Hoisted, per this project's history with the SwiftUI type checker.
    //
    // Says "estimate", not "written in minutes". A bar fades whenever the total
    // is inexact, and there are two reasons for that: a session given only as a
    // duration, and a bare "+ CD" with no distance attached. Naming only the
    // first would be wrong on week 32.
    private let footnoteText =
        "Every distance the plan states, by week — not its weekly headline, "
        + "which is total multisport including the commute. Sessions written "
        + "only in time are not converted, so the bike's hours are not here. "
        + "The line is the week's longest run. Faded bars are estimates: a run "
        + "written in minutes, or a bare WU/CD with no distance stated."

    private var footnote: some View {
        Text(footnoteText)
            .font(.caption2).foregroundStyle(Color.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}
