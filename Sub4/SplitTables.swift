//
//  SplitTables.swift
//  Sub4
//
//  The three tables a run is read through: per kilometre, per interval, and against the plan's asked distance.
//
//  SPLIT OUT OF ActivityDetailView.swift IN PATCH 171. That file had reached
//  2,150 lines and held every card on the page. These pieces moved wholesale,
//  unchanged except that members shared with the view lost `private` —
//  Swift's file-scoped privacy cannot cross a file split.
//

import SwiftUI

struct PlanSegment: Identifiable {
    let id: Int
    let label: String
    let metres: Double
    let seconds: Int
    let avgHR: Double?

    var paceSecPerKm: Int {
        guard metres > 100, seconds > 0 else { return 0 }
        return Int((Double(seconds) / (metres / 1000)).rounded())
    }
}

// MARK: - Split table
//
// A deviation table, not a bar chart: each kilometre is drawn as a bar growing
// left or right from the baseline. Bars from a zero origin would all be nearly
// the same length (every km is roughly five and a half minutes) and would say
// nothing. Centred on the target, the shape of the run is immediately readable.

struct SplitTable: View {
    let splits: [ActivityDetail.Split]
    let baseline: Int
    /// The target range, when the session states one that kilometre splits can
    /// be judged against. nil means the baseline is this run's own median and
    /// there is no such thing as "on target" — the two-colour table.
    var band: (low: Int, high: Int)? = nil
    var asSpeed = false
    var tint: Color = .accent4

    /// Seconds per kilometre of slack at each edge. The same figure the verdict
    /// card and the interval table use, so a split the headline calls "on
    /// target" is never drawn as a miss two rows below it.
    private static let tolerance = 2

    /// Half-width of the deviation gutter, in points.
    private let half: CGFloat = 44

    /// Scale: the largest deviation among the COMPLETE kilometres fills the
    /// gutter, with a floor so a metronomic run doesn't get its noise amplified
    /// into drama.
    ///
    /// Partial splits are drawn but do not set the scale. A 300 m finish taken
    /// at a sprint is a real number and belongs on screen, but letting it size
    /// the gutter would shrink every full kilometre to a stub — which is the
    /// same failure the 14 m fragment used to cause, one order of magnitude
    /// down. Their bars clip at the edge instead.
    private var maxDev: Double {
        let complete = splits.filter { !$0.isPartial }
        let pool = complete.isEmpty ? splits : complete
        let d = pool.map { abs(Double($0.paceSecPerKm - baseline)) }.max() ?? 1
        return max(d, 15)
    }

    var body: some View {
        // Hoisted: it was a computed property read once per row, which walked
        // the whole array for every row it drew.
        let scale = maxDev
        return VStack(spacing: 5) {
            ForEach(splits) { s in row(s, scale) }
            legend
        }
    }

    /// Three entries when there is a band to be inside, two when there is not.
    ///
    /// INLINE, NOT SPREAD ACROSS THE GUTTER. The first version pushed the words
    /// apart with Spacers inside the 88-point gutter so each sat over the region
    /// it described. Two words fitted; the third did not, and "on target" broke
    /// as "on tar-/get" between "fast er" and "slow er". Position was carrying
    /// meaning the swatch can carry in a fraction of the width.
    ///
    /// The words are dim, not tinted. A swatch beside a label is the identity;
    /// colouring the label as well says the same thing twice and leaves the row
    /// with no neutral text in it.
    private var legend: some View {
        HStack(spacing: 7) {
            LegendItem(.square(Color.fasterColor), "faster")
            if band != nil {
                legendDash
                LegendItem(.square(Color.onTargetColor), "on target")
            }
            legendDash
            LegendItem(.square(Color.slowerColor), "slower")
            Spacer(minLength: 0)
        }
        // Aligned to the gutter's left edge: 16 for the index column, 6 for the
        // stack's spacing.
        .padding(.leading, 22)
        .padding(.top, 2)
    }

    private var legendDash: some View {
        Text("–").font(.caption2).foregroundStyle(Color.dim)
    }

    // The "never let a label break" rule this legend once carried for itself
    // now lives on LegendItem, for every legend at once.

    /// Half the band's width, in points, for the shaded zone behind the bars.
    ///
    /// The zone is drawn as well as the colour because a colour tells you the
    /// answer and a zone shows you the question: with the band visible, a bar
    /// that stops just inside it and one that runs just past it are obviously
    /// the same distance from the edge.
    private func bandHalfWidth(_ maxDev: Double) -> CGFloat? {
        guard let b = band else { return nil }
        let secs = Double(b.high - b.low) / 2 + Double(Self.tolerance)
        guard secs > 0 else { return nil }
        return min(CGFloat(secs / maxDev) * half, half)
    }

    /// Faster, slower, or inside the band.
    ///
    /// WHY THIS IS NOT THE SIGN OF THE DEVIATION. The bar grows from the band's
    /// MIDPOINT, so on a 6:00–6:15 target a 6:13 kilometre has a positive
    /// deviation of six seconds and used to be painted slower-amber — while the
    /// card above it, reading the same split against the same band, called it on
    /// target. The bar and the verdict disagreed on every kilometre in the right
    /// half of the band.
    private func colour(_ pace: Int) -> Color {
        guard let b = band else {
            return pace < baseline ? Color.fasterColor : Color.slowerColor
        }
        if pace < b.low - Self.tolerance { return Color.fasterColor }
        if pace > b.high + Self.tolerance { return Color.slowerColor }
        return Color.onTargetColor
    }

    private func row(_ s: ActivityDetail.Split, _ maxDev: Double) -> some View {
        let dev = Double(s.paceSecPerKm - baseline)
        let w = min(CGFloat(abs(dev) / maxDev) * half, half)
        let fill = colour(s.paceSecPerKm)
        let bandW = bandHalfWidth(maxDev)

        return HStack(spacing: 6) {
            Text(s.isPartial ? "·" : "\(s.index)")
                .font(.caption2.weight(.bold)).monospacedDigit()
                .foregroundStyle(Color.dim)
                .frame(width: 16, alignment: .trailing)

            ZStack(alignment: .center) {
                // The band itself, behind everything. Faint on purpose: it is
                // the backdrop the bars are read against, not a mark.
                if let bandW {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.onTargetColor.opacity(0.13))
                        .frame(width: bandW * 2, height: 13)
                }
                Rectangle().fill(Color.line).frame(width: 1)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if dev < 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(fill)
                            .frame(width: w, height: 9)
                    }
                }
                .frame(width: half, alignment: .trailing)
                .offset(x: -half / 2)

                HStack(spacing: 0) {
                    if dev > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(fill)
                            .frame(width: w, height: 9)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: half, alignment: .leading)
                .offset(x: half / 2)
            }
            .frame(width: half * 2, height: 13)

            Text(valueLabel(s))
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(s.isPartial ? Color.dim : Color.ink)
                .frame(width: 62, alignment: .trailing)

            if let hr = s.averageHR, hr > 0 {
                Text("\(Int(hr))")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(Color.dim)
                    .frame(width: 30, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .opacity(s.isPartial ? 0.6 : 1)
    }

    private func valueLabel(_ s: ActivityDetail.Split) -> String {
        if asSpeed {
            let kmh = 3600.0 / Double(max(s.paceSecPerKm, 1))
            return String(format: "%.1f km/h", kmh)
        }
        return Fmt.pace(s.paceSecPerKm) + (s.isPartial
            ? String(format: " (%.0fm)", s.distanceM) : "")
    }
}

// MARK: - Interval table
//
// Reps, not kilometres. A plain list rather than the deviation gutter the
// kilometre table uses: there are four or five rows, each is a different
// length, and the question is not "what shape was the run" but "was each rep
// inside the band". So the band is the frame and each pace is coloured against
// it, with the gap spelled out in words beside it.

/// Two rows: what the plan asked for, and what was added to it.
///
/// The same grammar as the kilometre table — name, bar, pace, heart rate — so
/// this reads as another view of the run rather than as a different card that
/// happens to be in the same place. The bar is share of DISTANCE, which is the
/// axis the split is made on; sharing time would draw the slower segment longer
/// and quietly invert the thing being compared.
struct PlanSplitTable: View {

    let segments: [PlanSegment]
    let band: (low: Int, high: Int)?
    var footnote: String = ""

    private var total: Double { segments.reduce(0) { $0 + $1.metres } }

    private func colour(_ pace: Int) -> Color {
        guard let b = band, pace > 0 else { return Color.ink }
        if pace < b.low - 2 { return Color.fasterColor }
        if pace > b.high + 2 { return Color.slowerColor }
        return Color.onTargetColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { seg in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(seg.label).font(.caption).foregroundStyle(Color.dim)
                        Spacer(minLength: 4)
                        Text(Fmt.duration(seg.seconds))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(Color.dim)
                        Text(seg.paceSecPerKm > 0 ? Fmt.pace(seg.paceSecPerKm) : "—")
                            .font(.subheadline.weight(.bold)).monospacedDigit()
                            .foregroundStyle(colour(seg.paceSecPerKm))
                        Text(seg.avgHR.map { "\(Int($0))" } ?? "—")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(Color.dim)
                            .frame(width: 30, alignment: .trailing)
                    }
                    TrackBar(fraction: total > 0 ? seg.metres / total : 0,
                             tint: colour(seg.paceSecPerKm).opacity(0.75))
                }
            }

            if !footnote.isEmpty {
                Text(footnote).font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}

struct IntervalTable: View {
    let splits: IntervalSplits
    var tint: Color = .accent4

    private var band: (low: Int, high: Int)? {
        guard let p = splits.plan else { return nil }
        return (p.work.fast, p.work.slow)
    }

    private func colour(_ pace: Int) -> Color {
        guard let b = band else { return Color.ink }
        if pace < b.low - 2 { return Color.fasterColor }
        if pace > b.high + 2 { return Color.slowerColor }
        return Color.onTargetColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(splits.reps) { r in row(r) }

            if let mean = splits.meanPace {
                Divider().overlay(Color.line)
                HStack(spacing: 8) {
                    Text("mean").font(.caption2.weight(.bold)).fixedSize()
                        .foregroundStyle(Color.dim)
                        .frame(width: 30, alignment: .leading)
                    Text(Fmt.duration(splits.workSeconds))
                        .font(.caption.monospacedDigit()).foregroundStyle(Color.dim)
                        .frame(width: 52, alignment: .leading)
                    Spacer(minLength: 4)
                    Text(Fmt.pace(mean) + " /km")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(colour(mean))
                }
            }

            Text(note).font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
    }

    private func row(_ r: RepSplit) -> some View {
        HStack(spacing: 8) {
            Text("\(r.index)")
                .font(.caption2.weight(.bold)).monospacedDigit()
                .foregroundStyle(Color.dim)
                .frame(width: 30, alignment: .leading)

            Text(Fmt.duration(r.seconds))
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .leading)

            Text(r.distanceLabel)
                .font(.caption2.monospacedDigit()).foregroundStyle(Color.dim)
                .frame(width: 58, alignment: .leading)

            Spacer(minLength: 4)

            if let hr = r.avgHR, hr > 0 {
                Text("\(Int(hr))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(Color.dim)
                    .frame(width: 30, alignment: .trailing)
            }

            Text(r.paceLabel)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(colour(r.paceSecPerKm))
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// Says where the numbers came from, every time. A list of reps the app
    /// worked out for itself must never be indistinguishable from a list the
    /// watch recorded.
    private var note: String {
        switch splits.source {
        case .laps:
            return "The laps the watch recorded, unmodified."
        case .detected:
            let base = "Segmented from the pace trace, in order — not the fastest "
                     + "windows of the run. Anything quicker than "
                     + "\(Fmt.pace(splits.cutSecPerKm)) /km counted as work"
            return base + (splits.floatStated
                ? ", the line the plan draws between its work and float bands."
                : ", taken from this run — midway between the work band and the "
                  + "run's own slow quartile, and never more than a minute off "
                  + "the band. The plan states no float pace for this session.")
        }
    }
}

// The diverging pair for split deviation — cool for quicker, warm for slower,
// always beside the words "faster" and "slower" — moved to Theme.swift in patch
// 99. It has to resolve per colour scheme like everything else, and a second
// `extension Color` in a view file was the only place in the project where a
// palette value lived outside the palette.

