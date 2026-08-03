//
//  StreamChartView.swift
//  Sub4
//
//  Small multiples: one panel per active series, stacked, sharing a single
//  distance axis drawn once at the bottom. Tap a chip to add or remove a panel.
//
//  WHY THIS BEAT THE OVERLAY
//  -------------------------
//  Overlaying forced a compromise. Heart rate runs 100–180 bpm and grade runs
//  −3 to +3 %; on one frame they can only share an axis if each is normalised
//  to its own range, which means the y-axis has to be hidden because there is
//  no honest label to put on it. You got shapes and had to scrub for numbers.
//
//  Stacked, every panel carries its own real axis in its own real units. The
//  x-axis is shared, so a vertical read across the stack answers "what was my
//  heart rate where the ground tilted" exactly — same question the overlay
//  answered by eye, now answered by number.
//
//  It also lifts the three-series ceiling. Colour was doing the identification
//  work in an overlay, and four lines could not be told apart: the best
//  four-colour set scored a normal-vision ΔE of 10.6 against a floor of 15.
//  Here each panel is titled, so colour only reinforces a label that is already
//  there — elevation and grade can both be on screen, and all four validate on
//  the adjacent pairlist (worst 9.4 CVD, 20.9 normal vision).
//

import SwiftUI
import Charts

struct StreamChartView: View {

    let streams: ActivityStreams
    let discipline: Discipline?
    let tint: Color

    /// Owned by the detail sheet, not by this view — the map reads the same
    /// value to place its cursor, so there is exactly one scrub position.
    @Binding var selectedKm: Double?

    /// True inside the rotated panel — patch 150, corrected in 156.
    ///
    /// This originally read "the panel is the whole phone turned sideways and
    /// has roughly two and a half times the vertical room". That is the reverse
    /// of the truth and it produced a real bug: expanding gives you more WIDTH
    /// and LESS height. The card is a column in a scroll view and can grow
    /// forever; the panel's chart area is about 285 pt, full stop.
    ///
    /// So this flag no longer scales anything. It switches the LAYOUT — rows on
    /// the card, columns in the panel. See the note on `stack`.
    ///
    /// DECLARED LAST, AND THAT IS THE RULE RATHER THAN AN ACCIDENT. A memberwise
    /// initialiser takes its arguments in DECLARATION order, so inserting this
    /// between `tint` and `selectedKm` broke the one call site that passes it —
    /// "argument 'expanded' must precede argument 'selectedKm'". The same trap
    /// cost patch 123 a build, where a fourteen-argument literal reported it as
    /// "unable to type-check this expression in reasonable time" instead. New
    /// stored properties go at the end.
    var expanded: Bool = false

    @State private var active: Set<StreamSeries> = [.heartRate]
    @State private var athlete = AthleteStore.shared

    private var available: [StreamSeries] { streams.availableSeries }

    private var activeOrdered: [StreamSeries] {
        available.filter { active.contains($0) }
    }

    /// Pace, not speed, for anything measured in minutes per kilometre.
    private var usesPace: Bool { discipline == .run || discipline == .swim }

    private var totalKm: Double { max(streams.totalKm, 0.1) }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // TWO ROWS ON THE CARD, ONE IN THE PANEL.
            //
            // The card has vertical space to spend and the panel does not: the
            // chips and the scrub readout each cost a row plus a gap, about 27
            // pt, which is a tenth of everything the panel has. Merged, that
            // comes back as plot — worth roughly 7 pt to each of four series,
            // which is the difference between a 32 pt plot and a 25 pt one.
            if expanded {
                chipsAndScrub
            } else {
                chips
                scrubBar
            }
            stack
            caveats
        }
        .onAppear(perform: seedSelection)
    }

    private var chipsAndScrub: some View {
        HStack(spacing: 6) {
            ForEach(available) { s in chip(s) }
            Spacer(minLength: 10)
            Text(selectedKm == nil ? "WHOLE ACTIVITY"
                                   : String(format: "AT %.2f KM", selectedKm ?? 0))
                .font(.caption2.weight(.bold)).tracking(0.5)
                .foregroundStyle(Color.dim)
                .lineLimit(1)
            if selectedKm != nil {
                Button("Clear") { selectedKm = nil }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accent4)
            }
        }
    }

    private func seedSelection() {
        let live = active.intersection(Set(available))
        active = live.isEmpty ? Set(available.prefix(1)) : live
    }

    // MARK: Chips

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(available) { s in chip(s) }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ s: StreamSeries) -> some View {
        let on = active.contains(s)
        return Button { toggle(s) } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(on ? s.colour : Color.dim.opacity(0.45))
                    .frame(width: 10, height: 3)
                Text(s.shortLabel)
                    .font(.caption2.weight(on ? .bold : .regular))
            }
            .foregroundStyle(on ? Color.ink : Color.dim)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(on ? s.colour.opacity(0.18) : Color.bg)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(on ? s.colour.opacity(0.55) : Color.line,
                                 lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ s: StreamSeries) {
        if active.contains(s) {
            // Never empty — an empty chart is a worse answer than the last one.
            if active.count > 1 { active.remove(s) }
        } else {
            active.insert(s)
        }
    }

    // MARK: Scrub bar

    private var scrubBar: some View {
        HStack {
            Text(selectedKm == nil ? "WHOLE ACTIVITY"
                                   : String(format: "AT %.2f KM", selectedKm ?? 0))
                .font(.caption2.weight(.bold)).tracking(0.5)
            Spacer()
            if selectedKm != nil {
                Button("Clear") { selectedKm = nil }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accent4)
            } else {
                Text("drag any panel").font(.caption2)
            }
        }
        .foregroundStyle(Color.dim)
    }

    // MARK: The axis gutter
    //
    // WHAT WENT WRONG, AND WHY IT LOOKED LIKE AN OVERLAY BUG
    // ------------------------------------------------------
    // The header is a row ABOVE the chart, not a label drawn on top of it. What
    // overlapped it was the PREVIOUS panel's bottom axis label: an axis label is
    // centred on its tick, so the lowest one hangs half below the plot rect,
    // through the 4 pt panel gap and the 1 pt header gap, and lands on the next
    // header's baseline. Both being left-aligned at x = 0, they shared a column
    // as well as a line. "50" on PACE, "20" on ELEVATION, "25.0" on GRADE — one
    // bug, three times.
    //
    // TWO INDEPENDENT FIXES, BECAUSE EITHER ALONE IS A NEAR MISS
    // -----------------------------------------------------------
    //   HORIZONTAL  The labels get a reserved column of their own and the header
    //               starts where the PLOT starts. Even when a label and a header
    //               end up on the same line they no longer occupy the same x.
    //   VERTICAL    Panel gap 4 → 12 and header gap 1 → 3, which clears the
    //               descender of a label hanging below its plot.
    //
    // Spacing alone was the tempting fix and it is the fragile one: it holds
    // until someone changes a font size or adds a fifth series. The column is
    // what makes the collision structurally impossible.
    //
    // The width is RESERVED, not measured. Swift Charts sizes a leading axis to
    // its widest label, so four panels showing "150", "16:40", "0" and "-25.0"
    // would each start their plot somewhere different — four ragged left edges
    // in one card, and no single number the header could be indented by. A fixed
    // frame on the label makes the gutter one constant that both sides use.
    private static let axisLabelWidth: CGFloat = 28
    private static let axisLabelSpacing: CGFloat = 4
    private static var axisGutter: CGFloat { axisLabelWidth + axisLabelSpacing }

    // MARK: The stack

    // STACKED IN BOTH PLACES, IN CHIP ORDER — patch 157.
    //
    // 156 turned the panel's stack on its side, reading "follow the position of
    // the toggle buttons" as "lay the plots out the way the buttons are laid
    // out". Wrong: what has to follow the buttons is the ORDER, not the axis.
    // Heart rate is the first chip, so heart rate is the top plot.
    //
    // Order already came from `available`, which is the array the chips are
    // built from, so first-chip-first-plot has always held and holds here by
    // construction rather than by coincidence.
    //
    // WHAT 150 ACTUALLY BROKE, since two patches have now been spent near it.
    // It scaled the plots UP in the panel, on a comment claiming the panel "has
    // roughly two and a half times the vertical room". The reverse is true: the
    // card is a column in a scroll view and can grow forever, the panel's chart
    // area is about 285 pt and cannot. One series fitted by luck; two overflowed
    // by 167 pt and four by 477, which is the clipping in the screenshots.
    //
    // The fix is not another constant. In the panel the plots are FLEXIBLE and
    // divide whatever height there is, so the stack cannot overflow whatever
    // anybody selects — and the one thing stacking is for, dropping your eye
    // from a spike in one series onto the same kilometre in the next, is intact.
    private var stack: some View {
        // 12 on the card, not 4: an axis label is centred on its tick, so the
        // lowest one hangs below its plot and lands on the next panel's header.
        // 10 in the panel, where every point taken back is a point of plot.
        VStack(spacing: expanded ? 10 : 12) {
            ForEach(activeOrdered) { s in
                panel(s, showsXAxis: s == activeOrdered.last)
            }
        }
        .frame(maxHeight: expanded ? .infinity : nil)
    }

    /// Panels shrink as they multiply, so four still fit without the card
    /// turning into its own scroll view.
    ///
    /// CARD ONLY. In the panel the columns fill the height they are given, so
    /// there is no constant to pick — see the note on `stack` for why the
    /// constants that used to be applied there were wrong in principle and not
    /// just in value.
    private var panelHeight: CGFloat {
        switch activeOrdered.count {
        case 1:  return 150
        case 2:  return 110
        case 3:  return 88
        default: return 76
        }
    }

    private func panel(_ s: StreamSeries, showsXAxis: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            panelHeader(s)
            panelChart(s, showsXAxis: showsXAxis)
        }
        // Both maxima, and both are load-bearing in the panel: without the
        // width an HStack of columns sizes each to its widest label, and
        // without the height the column collapses onto its header.
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil)
    }

    private func panelHeader(_ s: StreamSeries) -> some View {
        let value = selectedKm.flatMap { streams.value(s, atKm: $0) } ?? average(s)
        return HStack(spacing: 6) {
            Text(s.label.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.4)
                .foregroundStyle(s.colour)
            Spacer()
            Text(value.map { display($0, for: s) } ?? "—")
                .font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(Color.ink)
            Text(unit(s)).font(.caption2).foregroundStyle(Color.dim)
        }
        // Starts where the plot starts, so the series name sits over its own
        // trace rather than over the column of numbers belonging to the panel
        // above it.
        .padding(.leading, Self.axisGutter)
    }

    private func panelChart(_ s: StreamSeries, showsXAxis: Bool) -> some View {
        let base = Chart {
            ForEach(points(for: s)) { p in
                LineMark(x: .value("Distance", p.km),
                         y: .value(s.label, p.y))
                    .foregroundStyle(s.colour)
                    // 0.4pt. At a few hundred samples the stroke width IS the
                    // noise floor — a fat line turns ordinary variation into a
                    // solid block.
                    .lineStyle(StrokeStyle(lineWidth: 0.4,
                                           lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }

            if s == .grade {
                RuleMark(y: .value("Flat", 0))
                    .foregroundStyle(Color.dim.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            if let km = selectedKm {
                RuleMark(x: .value("Selected", km))
                    .foregroundStyle(Color.dim)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        // Pinned, not automatic — every panel must share one x scale or a
        // vertical read across the stack lines up the wrong kilometres.
        .chartXScale(domain: 0...totalKm)
        .chartYScale(domain: .automatic(includesZero: s == .grade,
                                        reversed: s == .speed && usesPace))
        .chartYAxis { yAxis(s) }
        .chartXSelection(value: $selectedKm)
        // DRAG SCRUBS, A TAP DOES NOT — patch 152.
        //
        // `chartXSelection(value:)` binds the selection AND installs its own
        // gesture, which on iOS answers a plain tap as well as a drag. That made
        // the plot the one part of the card a tap could not pass through, so the
        // card could not be "tap to expand" while the chart stayed scrubbable:
        // both gestures wanted the same event.
        //
        // `chartGesture` REPLACES the default recogniser rather than adding to
        // it. At a minimum distance of 8 points a tap never starts a scrub and
        // falls through to the card, while a hold-and-drag behaves exactly as
        // before. The binding is untouched — `selectXValue(at:)` writes to the
        // same `$selectedKm`, so the map cursor still follows the finger.
        .chartGesture { proxy in
            DragGesture(minimumDistance: 8)
                .onChanged { proxy.selectXValue(at: $0.location.x) }
        }
        .frame(maxWidth: .infinity,
               maxHeight: expanded ? .infinity : nil)
        .frame(height: expanded ? nil : panelHeight)

        return Group {
            if showsXAxis {
                base.chartXAxis { xAxis() }
            } else {
                base.chartXAxis(.hidden)
            }
        }
    }

    private func yAxis(_ s: StreamSeries) -> some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
            // Fixed width, trailing-aligned: the digits line up against the
            // plot edge on every panel, and the gutter is the same on all four
            // whether the label reads "0" or "-25.0". `minimumScaleFactor`
            // rather than a wider frame — the two longest labels in the app,
            // "16:40" and "-25.0", are within a hair of 28 pt at caption2, and
            // widening the column for them would cost every panel the width.
            AxisValueLabel(horizontalSpacing: Self.axisLabelSpacing) {
                if let v = value.as(Double.self) {
                    Text(display(rawFor(v, s), for: s))
                        .font(.caption2).foregroundStyle(Color.dim)
                        .lineLimit(1).minimumScaleFactor(0.72)
                        .frame(width: Self.axisLabelWidth, alignment: .trailing)
                }
            }
        }
    }

    private func xAxis() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisGridLine().foregroundStyle(Color.line.opacity(0.35))
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    Text(v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v))
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            }
        }
    }

    // MARK: Plot data

    private struct PlotPoint: Identifiable {
        let id: Int
        let km: Double
        let y: Double
    }

    private func points(for s: StreamSeries) -> [PlotPoint] {
        guard let raw = streams.values(s) else { return [] }
        let n = min(raw.count, streams.distanceM.count)
        guard n > 1 else { return [] }
        return (0..<n).compactMap {
            guard let y = plotValue(raw[$0], s) else { return nil }
            return PlotPoint(id: $0, km: streams.distanceM[$0] / 1000, y: y)
        }
    }

    /// Converts a raw stream value into plotted units.
    private func plotValue(_ raw: Double, _ s: StreamSeries) -> Double? {
        guard s == .speed else { return raw }
        guard usesPace else { return raw * 3.6 }              // km/h
        // Standing still has no pace. Clamp rather than let it run to infinity
        // and flatten the rest of the panel into a straight line.
        let sec = raw > 0.4 ? 1000 / raw : 900
        return min(max(sec, 150), 900)
    }

    /// The inverse, for axis labels — the axis works in plotted units.
    private func rawFor(_ plotted: Double, _ s: StreamSeries) -> Double {
        guard s == .speed else { return plotted }
        if usesPace { return plotted > 0 ? 1000 / plotted : 0 }
        return plotted / 3.6
    }

    private func average(_ s: StreamSeries) -> Double? {
        guard let v = streams.values(s), !v.isEmpty else { return nil }
        if s == .speed {
            // Average the speed, then convert — averaging pace directly
            // overweights the slow samples.
            let moving = v.filter { $0 > 0.5 }
            guard !moving.isEmpty else { return nil }
            return moving.reduce(0, +) / Double(moving.count)
        }
        return v.reduce(0, +) / Double(v.count)
    }

    /// Formats a RAW stream value.
    private func display(_ raw: Double, for s: StreamSeries) -> String {
        switch s {
        case .heartRate:
            return "\(Int(raw.rounded()))"
        case .elevation:
            return String(format: "%.0f", raw)
        case .grade:
            return String(format: "%.1f", raw)
        case .speed:
            if usesPace {
                guard raw > 0.4 else { return "—" }
                let sec = Int((1000 / raw).rounded())
                return String(format: "%d:%02d", sec / 60, sec % 60)
            }
            return String(format: "%.1f", raw * 3.6)
        }
    }

    private func unit(_ s: StreamSeries) -> String {
        switch s {
        case .heartRate: return "bpm"
        case .elevation: return "m"
        case .grade:     return "%"
        case .speed:     return usesPace ? "/km" : "km/h"
        }
    }

    // MARK: Caveats
    //
    // Saying "this is noise" is worth more than drawing the noise and letting
    // it be read as terrain.

    @ViewBuilder
    private var caveats: some View {
        let lines = caveatLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption2).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var caveatLines: [String] {
        var out: [String] = []
        for s in activeOrdered {
            switch s {
            case .elevation where !streams.hasRealRelief:
                out.append(String(format: "Elevation spans just %.0f m over %.1f km "
                                  + "— GPS jitter, not terrain.",
                                  streams.elevationRange, streams.totalKm))
            case .grade where !streams.hasRealGrade:
                out.append("Grade stays inside a couple of percent throughout — "
                           + "flat ground, so the wiggle is sensor noise.")
            case .speed where usesPace:
                out.append("Pace floors at 15:00 — a drop to the bottom is a stop, "
                           + "not a slow kilometre.")
            case .heartRate:
                // The peak-zone sentence moved to the HEART RATE card in patch
                // 107 — it was a second heart-rate statement about the same run,
                // two hundred points from the first one. Nothing replaces it
                // here: the panel is titled and carries its own value.
                break
            default:
                break
            }
        }
        return out
    }

}

// MARK: - Series colours
//
// Fixed per series, never reassigned by how many panels are showing. Switching
// heart rate off must not repaint pace.
//
// In a stack, colour is NOT carrying identity — every panel is titled — so it
// reinforces rather than discriminates. These are the documented dark-mode
// categorical slots, validated as a set against this app's card surface
// (#181b22) on the adjacent pairlist, which is the right one for panels that
// only ever sit next to their neighbours.

extension StreamSeries {
    var colour: Color {
        switch self {
        // Light steps re-validated on #FFFFFF rather than inverted: adjacent
        // ΔE 25.3 normal / 10.0 protan, every mark ≥ 3:1. The dark values are
        // the ones already signed off against the panel surface #181b22.
        case .heartRate: return dyn(dark: 0xD95926, light: 0xC2410C)
        case .speed:     return dyn(dark: 0x199E70, light: 0x0F7B5A)
        case .elevation: return dyn(dark: 0x3987E5, light: 0x1D4ED8)
        case .grade:     return dyn(dark: 0xC98500, light: 0x7A5A00)
        }
    }
}
