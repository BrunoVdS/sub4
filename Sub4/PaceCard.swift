//
//  PaceCard.swift
//  Sub4
//
//  How fast, per discipline, against something worth comparing to.
//
//  NATIVE UNITS, AND THE DIRECTION SAYS SO
//  ---------------------------------------
//  Run is min/km, swim is min/100 m, bike is km/h. The good direction therefore
//  FLIPS between tabs: a rising bike line is improvement, a rising run line is
//  decline. The alternative — inverting the y-axis on run and swim so up is
//  always faster — buys one consistent rule at the cost of a run chart with
//  5:00 /km at the top, which is not how anyone reads a pace chart. So the
//  units stay native and the subtitle states the direction, every time.
//
//  THE SCALE IS SET BY ORDINARY SESSIONS
//  -------------------------------------
//  Each discipline has one kind of session that is real, is worth keeping, and
//  is not evidence about form:
//
//   · RUN — off the bike. On 14 June the marathon leg of Ironman Tours went
//     into Strava as two runs, 7.43 km at 7:27 and 5.01 km at 10:51, after a
//     179 km ride. Between them they dragged the domain to 15:00 and squeezed
//     every genuine run into the middle fifth of the card.
//
//   · BIKE — the mountains. Three rides in early May carry 14–18 m of climbing
//     per kilometre; everything since is 2.2–5.0. Without separating them the
//     chart shows a 5 km/h gain in mid-May, when what happened is he came home
//     from the Ardennes.
//
//   · SWIM — none yet, but the same mechanism carries the unverified flag.
//
//  Those sessions are drawn HOLLOW, are excluded from the domain, and are
//  clamped to the edge of it when they fall outside — with the caption naming
//  each clamped one and its true figure. Nothing is hidden; the scale simply
//  stops being decided by the day that is not about this.
//
//  COMMUTES ARE NOT PLOTTED AT ALL
//  -------------------------------
//  Same 10 km threshold as the volume card. A ride to the station is not a slow
//  ride, it is not a ride — and unlike the hilly rides there is nothing to
//  learn from seeing it, so it is filtered rather than flagged.
//
//  THE PLAN STATES NO TARGET FOR BIKE OR SWIM
//  ------------------------------------------
//  Checked, not assumed: all 53 bike sessions and all 26 swim sessions, and not
//  one m:ss token between them. Bike says "2 h outdoor Z2", swim says
//  "1500 m · 6×150 swim + 6×50 kick". So the cool-hue target rule is run-only,
//  and the other two get a grey 90-day median of their own unflagged sessions —
//  labelled as a baseline and never dressed up as a goal.
//
//  THE SWIM TIME IS WRONG AND THE CHART SAYS SO
//  --------------------------------------------
//  Strava's `moving_time` is derived, and on swims it fails in both directions:
//  pool swims count rest as swimming, open water loses the athlete under the
//  surface and calls it stopped. 14 June reads 1:10 /100 m, which is faster
//  than the 1500 m world record.
//
//  Where Apple Health has the session, the active time comes from the summed
//  `distanceSwimming` sample intervals instead — resting at the wall produces
//  no sample, so it can neither count rest nor drop swimming that happened.
//  Where it does not, the dot is drawn hollow and the caption says the timing
//  is unverified. A hollow dot with a caveat beats a solid dot that is a world
//  record.
//
//  EXPANDED MEANS MORE, NOT BIGGER
//  -------------------------------
//  The card carries six months at a uniform dot weight — "am I near target".
//  The expanded panel carries the whole history, sizes each dot by distance,
//  and adds a rolling median — "is it moving". A magnified copy of the card
//  would have answered neither better.
//

import SwiftUI
import Charts

// MARK: - What is being measured

enum PaceMetric: String, CaseIterable, Identifiable {
    case run, bike, swim

    var id: String { rawValue }

    var discipline: Discipline {
        switch self {
        case .run:  .run
        case .bike: .bike
        case .swim: .swim
        }
    }

    var label: String { discipline.label }
    var symbol: String { discipline.symbol }
    var tint: Color { discipline.tint }

    /// Shown beside the value on the tile.
    var unit: String {
        switch self {
        // "min/" spelled out on the two duration metrics. "6:00 /km" leaves the
        // reader to infer that the m:ss is minutes and seconds rather than, say,
        // seconds and hundredths — which is a real reading on a swim figure.
        case .run:  "min/km"
        case .bike: "km/h"
        case .swim: "min/100m"
        }
    }

    /// A pace is a duration and reads as m:ss; a speed is a number.
    var isDuration: Bool { self != .bike }

    var lowerIsFaster: Bool { self != .bike }

    var directionNote: String {
        lowerIsFaster ? "lower is faster" : "higher is faster"
    }

    /// What one session is worth on this axis, given the seconds to use.
    ///
    /// The seconds are passed in rather than read off the activity because the
    /// swim takes them from Apple Health when it can — see `PaceSeries.sessions`.
    func value(_ a: Activity, seconds: Int) -> Double? {
        guard a.discipline == discipline, seconds > 0 else { return nil }
        switch self {
        case .run:
            guard a.km >= 3 else { return nil }
            return Double(seconds) / a.km / 60                 // minutes per km
        case .bike:
            guard a.isPlanEligible else { return nil }         // commutes out
            return a.km / (Double(seconds) / 3600)             // km/h
        case .swim:
            guard a.distance >= 200 else { return nil }
            return Double(seconds) / (a.distance / 100)        // seconds/100 m
        }
    }

    /// Real, kept, and not evidence about form.
    func isFlagged(_ a: Activity, brickDays: Set<String>) -> Bool {
        switch self {
        case .run:  return brickDays.contains(a.dayKey)
        case .bike: return PaceSeries.climbPerKm(a).map { $0 > PaceSeries.hillyMetresPerKm } ?? false
        case .swim: return false
        }
    }

    var flagLabel: String {
        switch self {
        case .run:  "Off the bike"
        case .bike: "Hilly"
        case .swim: "Unverified"
        }
    }

    /// Format one axis value or tile figure.
    func format(_ v: Double) -> String {
        switch self {
        case .run:
            let total = Int((v * 60).rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        case .swim:
            let total = Int(v.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        case .bike:
            return String(format: "%.1f", v)
        }
    }

    /// Axis labels want no decimal on the bike — 22, 24, 26 rather than 22.0.
    func axisFormat(_ v: Double) -> String {
        self == .bike ? String(format: "%.0f", v) : format(v)
    }

    /// Half a minute for run, five seconds for swim, one km/h for bike — the
    /// step the domain is snapped to so the axis reads in round numbers.
    var snap: Double {
        switch self {
        case .run:  0.5      // minutes
        case .swim: 5        // seconds
        case .bike: 1        // km/h
        }
    }

    /// Padding beyond the data, in the same units as `snap`.
    var pad: Double {
        switch self {
        case .run:  0.4
        case .swim: 6
        case .bike: 1
        }
    }
}

// MARK: - The series

struct PaceSession: Identifiable {
    let id: String
    let date: Date
    let value: Double
    let km: Double
    let flagged: Bool
    /// False only for a swim whose timing came from Strava.
    let verified: Bool
}

enum PaceSeries {

    /// Above this a ride is a climb, not a comparison. The history splits
    /// cleanly: three rides at 14–18 m/km, everything else at 2.2–5.0.
    static let hillyMetresPerKm = 10.0

    /// Beyond this, a ride on the same day changes what a RUN means.
    static let brickRideKm = 50.0

    /// What the card shows. The expanded panel shows everything.
    static let cardDays = 180

    /// The window the tile medians are taken over. Longer than the volume
    /// card's 30 days because a pace median needs sessions, and thirty days
    /// currently holds three runs and no swims at all.
    static let markerDays = 90

    static func climbPerKm(_ a: Activity) -> Double? {
        guard let gain = a.elevationGain, a.km > 1 else { return nil }
        return gain / a.km
    }

    static func brickDays(_ activities: [Activity]) -> Set<String> {
        var out: Set<String> = []
        for a in activities where a.discipline == .bike && a.km >= brickRideKm {
            out.insert(a.dayKey)
        }
        return out
    }

    /// Every session on one metric's axis, oldest first.
    ///
    /// `health` is consulted only for swims, and only to replace the seconds.
    /// Distance stays Strava's throughout — it comes off the watch and survives
    /// the trip intact; it is the TIMING that Strava derives and gets wrong.
    static func sessions(_ metric: PaceMetric,
                         activities: [Activity],
                         health: HealthStore?) -> [PaceSession] {
        let bricks = brickDays(activities)
        return activities
            .filter { $0.discipline == metric.discipline }
            .compactMap { a -> PaceSession? in
                guard let date = DayKey.date(a.dayKey) else { return nil }

                // ORDER OF AUTHORITY: chip, then Health, then Strava.
                //
                // The official split goes first and does not consult Health at
                // all. On 14 June the watch stopped mid-swim, so Health's length
                // samples are a subset of the same broken recording — asking it
                // would be asking the same instrument a second time. A chip time
                // is also more verified than anything else in this app, so the
                // dot is solid: the hollow ring means "we could not time this",
                // and here somebody else did.
                var seconds = a.movingTime
                var verified = true
                if let o = DataCorrections.official(a) {
                    seconds = o.seconds
                } else if metric == .swim {
                    if let w = health?.healthMatch(for: a), let active = w.activeSeconds {
                        seconds = active
                    } else {
                        verified = false
                    }
                }

                guard let v = metric.value(a, seconds: seconds) else { return nil }
                return PaceSession(id: a.id, date: date, value: v, km: a.km,
                                   flagged: metric.isFlagged(a, brickDays: bricks)
                                            || !verified,
                                   verified: verified)
            }
            .sorted { $0.date < $1.date }
    }

    /// Set by unflagged sessions and the reference only, snapped to round
    /// numbers so the axis reads 5:00, 5:30, 6:00 rather than 5:17.
    static func domain(_ metric: PaceMetric,
                       _ sessions: [PaceSession],
                       reference: Double?) -> ClosedRange<Double> {
        // When EVERY session is flagged the flags have to set the scale — there
        // is nothing else. That is the swim's situation until Health has been
        // granted: every dot is unverified, and a domain derived from a
        // fallback constant would put the whole series off the top of a chart
        // that looked perfectly normal.
        var v = sessions.filter { !$0.flagged }.map(\.value)
        if v.isEmpty { v = sessions.map(\.value) }
        if let reference { v.append(reference) }

        guard let dataLo = v.min(), let dataHi = v.max() else {
            switch metric {
            case .run:  return 4...8          // minutes per km
            case .bike: return 20...35        // km/h
            case .swim: return 60...180       // seconds per 100 m
            }
        }
        let s = metric.snap
        let low = Swift.max(0, ((dataLo - metric.pad) / s).rounded(.down) * s)
        let high = Swift.max(low + s, ((dataHi + metric.pad) / s).rounded(.up) * s)
        return low...high
    }

    /// Median of the unflagged sessions in the window, falling back to all of
    /// them when none are unflagged. The baseline shown for bike and swim,
    /// because the plan states no target for either.
    static func median(_ sessions: [PaceSession]) -> Double? {
        var v = sessions.filter { !$0.flagged }.map(\.value)
        if v.isEmpty { v = sessions.map(\.value) }
        v.sort()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1
            ? v[v.count / 2]
            : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    static func within(_ sessions: [PaceSession], days: Int) -> [PaceSession] {
        guard let cutoff = Calendar(identifier: .iso8601)
                .date(byAdding: .day, value: -days, to: Date()) else { return sessions }
        return sessions.filter { $0.date >= cutoff }
    }

    /// Rolling median over `window` sessions, plotted at the middle one's date.
    ///
    /// Median rather than mean, and flagged sessions left out of the pool: a
    /// single 10:51 leg drags a five-session mean by more than a minute and
    /// invents a slump that never happened. A median moves by one rank.
    static func trend(_ sessions: [PaceSession],
                      window: Int = 5) -> [(date: Date, value: Double)] {
        let pool = sessions.filter { !$0.flagged }
        guard pool.count >= window else { return [] }
        return (0...(pool.count - window)).map { i in
            let slice = pool[i..<(i + window)].map(\.value).sorted()
            return (pool[i + window / 2].date, slice[window / 2])
        }
    }
}

/// The rolling-90-day headline for one discipline.
struct PaceMarker: Identifiable {
    let metric: PaceMetric
    let median: Double?
    let sessions: Int
    let flagged: Int
    /// Swims whose timing Health has not confirmed.
    let unverified: Int
    /// Across the whole history, not the marker window — used to decide
    /// whether the discipline has enough to draw at all.
    let total: Int

    var id: String { metric.rawValue }
}

/// All three series, built once. Both the card and the expanded panel need
/// every discipline — the tiles show all of them whichever one is selected —
/// so building them per-metric on demand meant three passes over the activity
/// list per redraw, three more for the markers, and a fourth for the gate.
struct PaceBundle {
    let byMetric: [String: [PaceSession]]
    let markers: [PaceMarker]

    func sessions(_ m: PaceMetric) -> [PaceSession] { byMetric[m.rawValue] ?? [] }

    /// Any discipline with enough to plot. The card hides only when none has.
    var hasAnything: Bool { markers.contains { $0.total >= 3 } }

    static func build(activities: [Activity], health: HealthStore?) -> PaceBundle {
        var series: [String: [PaceSession]] = [:]
        var markers: [PaceMarker] = []
        for m in PaceMetric.allCases {
            let all = PaceSeries.sessions(m, activities: activities, health: health)
            series[m.rawValue] = all
            let window = PaceSeries.within(all, days: PaceSeries.markerDays)
            markers.append(PaceMarker(
                metric: m,
                median: PaceSeries.median(window),
                sessions: window.count,
                flagged: window.filter { $0.flagged && $0.verified }.count,
                unverified: window.filter { !$0.verified }.count,
                total: all.count))
        }
        return PaceBundle(byMetric: series, markers: markers)
    }
}

// MARK: - The card

struct PaceCard: View {

    private let store = PlanStore.shared
    @State private var activities = ActivityStore.shared
    @State private var health = HealthStore.shared

    /// Shared with the volume card since patch 70 — see `DisciplineKey`.
    @AppStorage(DisciplineKey.selected) private var metricRaw = PaceMetric.run.rawValue

    private var metric: PaceMetric { PaceMetric(rawValue: metricRaw) ?? .run }

    var body: some View {
        let bundle = PaceBundle.build(activities: activities.activities, health: health)
        // The gate is on ANY discipline having something, never on the selected
        // one. Hiding the card because the selected tab is thin would take the
        // selector down with it and leave no way back to the tab that has data.
        if bundle.hasAnything {
            // Opens on Pace, switches to Weekly volume in place.
            ExpandableCard(panels: PanelGroup.volumePace, opensOn: "pace") {
                PaceChartCard(metric: metric,
                              markers: bundle.markers,
                              sessions: windowed(bundle.sessions(metric)),
                              target: target,
                              height: 140,
                              sizeByDistance: false,
                              showTrend: false,
                              onSelect: { metricRaw = $0.rawValue })
            }
            // Only the swim needs it, but asking on every appearance keeps the
            // cache warm for the moment the tab is switched. Throttled to an
            // hour inside, and a no-op without authorisation.
            .task { await health.loadWorkoutCacheIfStale(since: MatchRules.cutoffDayKey) }
        }
    }

    /// If the window is thin — a fresh install, or a long lay-off — showing
    /// three dots is worse than showing the history that exists.
    private func windowed(_ all: [PaceSession]) -> [PaceSession] {
        let recent = PaceSeries.within(all, days: PaceSeries.cardDays)
        return recent.count >= 8 ? recent : all
    }

    private var target: Double? {
        metric == .run ? Double(store.plan.meta.targetPaceSecKm) / 60.0 : nil
    }
}

struct PaceExpanded: View {

    private let store = PlanStore.shared
    @State private var activities = ActivityStore.shared
    @State private var health = HealthStore.shared

    /// Shared with the volume card since patch 70 — see `DisciplineKey`.
    @AppStorage(DisciplineKey.selected) private var metricRaw = PaceMetric.run.rawValue

    private var metric: PaceMetric { PaceMetric(rawValue: metricRaw) ?? .run }

    var body: some View {
        let bundle = PaceBundle.build(activities: activities.activities, health: health)
        PaceChartCard(metric: metric,
                      markers: bundle.markers,
                      sessions: bundle.sessions(metric),
                      target: metric == .run
                          ? Double(store.plan.meta.targetPaceSecKm) / 60.0 : nil,
                      height: nil,
                      sizeByDistance: true,
                      showTrend: true,
                      onSelect: { metricRaw = $0.rawValue },
                      chrome: false)
    }
}

// MARK: - The chart itself

struct PaceChartCard: View {

    let metric: PaceMetric
    let markers: [PaceMarker]
    let sessions: [PaceSession]
    /// The plan's figure. nil for bike and swim, where the plan states none and
    /// the reference falls back to the athlete's own median.
    let target: Double?
    let height: CGFloat?
    let sizeByDistance: Bool
    let showTrend: Bool
    let onSelect: (PaceMetric) -> Void
    var chrome = true

    /// The cursor, panel only — same reasoning as the volume card: on the card
    /// this plot lives inside an `ExpandableCard` whose job is to open the
    /// panel when tapped, and a selection gesture would eat that tap.
    @State private var cursor: Date?

    /// The plan's target where there is one, the 90-day median otherwise.
    private var reference: Double? {
        target ?? PaceSeries.median(PaceSeries.within(sessions,
                                                      days: PaceSeries.markerDays))
    }

    private var referenceIsTarget: Bool { target != nil }

    private var domain: ClosedRange<Double> {
        PaceSeries.domain(metric, sessions, reference: reference)
    }

    private var flagged: [PaceSession] { sessions.filter(\.flagged) }

    /// Flagged sessions that fall outside the domain and are drawn at its edge.
    /// The direction of "outside" depends on which way faster is.
    private var offScale: [PaceSession] {
        flagged.filter {
            metric.lowerIsFaster ? $0.value > domain.upperBound
                                 : $0.value < domain.lowerBound
        }
    }

    private func clamped(_ v: Double) -> Double {
        Swift.min(Swift.max(v, domain.lowerBound), domain.upperBound)
    }

    /// 26 pt flat on the card. In the expanded panel a 5 km recovery run and a
    /// 25 km long run are meaningfully different sessions and the area says so
    /// — floored so a short one is still a dot rather than a speck.
    private func size(_ s: PaceSession) -> CGFloat {
        sizeByDistance ? CGFloat(Swift.min(20 + s.km * 5, 150)) : CGFloat(26)
    }

    var body: some View {
        Group {
            if chrome { cardBody } else { panelBody }
        }
        .modifier(PaceChrome(on: chrome))
    }

    /// Portrait — unchanged.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("PACE").font(.caption2.weight(.bold)).tracking(0.5)
                InfoButton(topic: .pace)
                Spacer()
                Text(subtitle).font(.caption2).multilineTextAlignment(.trailing)
            }
            .foregroundStyle(Color.dim)

            tiles

            if sessions.count >= 3 {
                chart
                legend
                if let note = caption {
                    Text(note).font(.caption2).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                empty
            }
        }
    }

    // MARK: - Landscape
    //
    // The same rebuild the volume panel got in patch 110, for the same reason:
    // rotated, the screen has width and no height, and the card layout spends
    // height on furniture stacked above and below the plot. Selectors go on one
    // line, the legend becomes a column on the right, and everything left over
    // goes to the chart.
    //
    // ONE THING THE PANEL WAS SILENTLY DROPPING
    // ------------------------------------------
    // The reference figure. `subtitle` — "target 5:41 min/km", or the 90-day
    // median — lives in the header, and the panel has no header, so rotating the
    // phone lost the number the target line is drawn from. It now sits at the
    // end of the selector band, where the volume panel puts its unit toggle.
    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelBand

            if sessions.count >= 3 {
                HStack(alignment: .top, spacing: 22) {
                    chart
                        .chartXSelection(value: $cursor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    panelLegend
                        .frame(width: 120, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                panelFooter
            } else {
                empty
                Spacer(minLength: 0)
            }
        }
    }

    /// Run · Bike · Swim · the reference figure, on one line.
    private var panelBand: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(markers) { m in
                Button { onSelect(m.metric) } label: { panelTile(m) }
                    .buttonStyle(.plain)
            }
            Text(subtitle)
                .font(.system(size: 10)).foregroundStyle(Color.dim)
                .multilineTextAlignment(.leading)
                .frame(width: 120, alignment: .leading)
                .padding(.top, 10)
        }
    }

    private func panelTile(_ m: PaceMarker) -> some View {
        let on = m.metric == metric
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: m.metric.symbol).font(.system(size: 8.5))
                Text(m.metric.label.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.3)
            }
            .foregroundStyle(on ? m.metric.tint : Color.dim)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(m.median.map { m.metric.format($0) } ?? "—")
                    .font(.system(size: 17, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Color.ink)
                Text(m.metric.unit).font(.system(size: 9)).foregroundStyle(Color.dim)
            }
            .lineLimit(1).minimumScaleFactor(0.7)

            // The session count and the flag share a line here, the way the
            // volume tiles' count and delta do. Four rows of nine-point text is
            // the furniture the panel is trying not to pay for.
            HStack(spacing: 4) {
                Text(panelCount(m))
                    .font(.system(size: 9)).foregroundStyle(Color.dim)
                if !flagNote(m).isEmpty {
                    Text("·").font(.system(size: 9)).foregroundStyle(Color.dim)
                    Text(flagNote(m))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.slowerColor)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? m.metric.tint.opacity(0.10) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(on ? m.metric.tint : Color.line, lineWidth: 1)))
        .contentShape(Rectangle())
    }

    private func panelCount(_ m: PaceMarker) -> String {
        if m.sessions == 0 { return "nothing recorded" }
        return "\(m.sessions) session" + (m.sessions == 1 ? "" : "s")
    }

    /// A column, no fill behind it — see the note on the volume panel's legend.
    /// The rows are the same four the card's row draws, in the same order and
    /// under the same conditions; only the axis changed.
    private var panelLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            legendRow(sizeByDistance ? "\(metric.label) · size is distance"
                                     : metric.label) {
                Circle().fill(metric.tint.opacity(0.55)).frame(width: 8, height: 8)
            }
            if !flagged.isEmpty {
                legendRow(metric.flagLabel) {
                    Circle().stroke(metric.tint.opacity(0.8), lineWidth: 1.2)
                        .frame(width: 9, height: 9)
                }
            }
            if showTrend {
                legendRow("5-session median") {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(metric.tint).frame(width: 12, height: 2.5)
                }
            }
            if reference != nil {
                legendRow(referenceIsTarget ? "Target" : "Median") {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(referenceIsTarget ? Color.fasterColor : Color.dim)
                        .frame(width: 12, height: 2.5)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func legendRow<M: View>(_ name: String,
                                    @ViewBuilder mark: () -> M) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            mark().frame(width: 12, alignment: .center)
            Text(name)
                .font(.system(size: 10)).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The window, and whatever the caption has to say — until the cursor is
    /// down, at which point it becomes the session under it.
    ///
    /// Same placement argument as the volume panel: the three figures above are
    /// a selector and must not repaint while you scrub, or you cannot tell a
    /// 90-day median from one session's pace.
    @ViewBuilder
    private var panelFooter: some View {
        if cursor != nil, let s = cursorSession {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DayKey.short(s.date))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ink)
                HStack(spacing: 4) {
                    Circle().fill(metric.tint.opacity(0.55))
                        .frame(width: 7, height: 7)
                    Text(metric.format(s.value) + " " + metric.unit)
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color.ink)
                }
                Text(cursorDistance(s))
                    .font(.system(size: 10)).foregroundStyle(Color.dim)
                // The flag is why a dot is hollow and why it may be sitting on
                // the edge of the scale rather than at its own value. Pointing
                // at one and being told only the clamped number would be the
                // chart lying at the exact moment you asked it a question.
                if s.flagged {
                    Text("· " + metric.flagLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.slowerColor)
                }
                if metric == .swim && !s.verified {
                    Text("· timed by Strava")
                        .font(.system(size: 10)).foregroundStyle(Color.dim)
                }
                Spacer(minLength: 0)
                Button("Clear") { cursor = nil }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .foregroundStyle(Color.dim)
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let note = caption {
                    // Two lines. The off-scale list names a date and a figure
                    // per clamped session, and at one line a third of it went
                    // under the ellipsis on exactly the charts that had most to
                    // explain.
                    Text(note).font(.system(size: 9.5)).foregroundStyle(Color.dim)
                        .lineLimit(2).minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("figures: median over \(PaceSeries.markerDays) days")
                    .font(.system(size: 9)).foregroundStyle(Color.dim)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    /// Nearest session by date.
    ///
    /// WHY A RULE IS NOT ENOUGH HERE, AND THE VOLUME PANEL GETS AWAY WITH ONE
    /// ----------------------------------------------------------------------
    /// Volume is one column per week: a vertical line lands on exactly one bar
    /// and there is nothing to disambiguate. This is a scatter, and two sessions
    /// three days apart are a few points apart on a 52-week axis — a rule alone
    /// would name a date and leave you guessing which dot it meant. So the
    /// nearest session is also ringed.
    private var cursorSession: PaceSession? {
        guard let cursor else { return nil }
        return sessions.min {
            abs($0.date.timeIntervalSince(cursor))
                < abs($1.date.timeIntervalSince(cursor))
        }
    }

    private func cursorDistance(_ s: PaceSession) -> String {
        if metric == .swim {
            return String(format: "%.0f m", s.km * 1000)
        }
        return String(format: "%.1f km", s.km)
    }

    /// Shown in place of the chart when the SELECTED discipline is thin. The
    /// tiles stay above it, so the way back to a discipline with data is one
    /// tap rather than a puzzle.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sessions.isEmpty
                 ? "No \(metric.label.lowercased()) sessions recorded."
                 : "Only \(sessions.count) \(metric.label.lowercased()) session"
                   + (sessions.count == 1 ? "" : "s") + " — not enough to plot.")
                .font(.caption).foregroundStyle(Color.dim)
            if metric == .bike {
                Text("Rides under \(Int(MatchRules.minRideKm)) km are commutes and "
                     + "are not counted here.")
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 26)
    }

    /// The reference figure, and nothing else.
    ///
    /// "lower is faster" used to trail every one of these. It is the opening
    /// line of ⓘ *Each session*, it is the same six words on every render, and
    /// it is a thing you need once. The figure is what changes.
    ///
    /// The direction note survives as the FALLBACK: with neither a target nor a
    /// median there is no figure to state, and an empty subtitle would leave the
    /// header lopsided.
    ///
    /// Corrected here too: the run target read "5:41 /km" while every other pace
    /// on this tab has read "min/km" since patch 79.
    private var subtitle: String {
        if let target, metric == .run {
            return "target \(metric.format(target)) min/km"
        }
        if let r = reference {
            return "90-day median \(metric.format(r)) \(metric.unit)"
        }
        return metric.directionNote
    }

    // MARK: The three markers, which are also the selector

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ForEach(markers) { m in
                    Button { onSelect(m.metric) } label: { tile(m) }
                        .buttonStyle(.plain)
                }
            }
            // Affordance hint dropped — see the same change on VolumeCard.
            Text("median over \(PaceSeries.markerDays) days")
                .font(.system(size: 9)).foregroundStyle(Color.dim)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func tile(_ m: PaceMarker) -> some View {
        let on = m.metric == metric
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: m.metric.symbol).font(.system(size: 8.5))
                Text(m.metric.label.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.3)
            }
            .foregroundStyle(on ? m.metric.tint : Color.dim)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(m.median.map { m.metric.format($0) } ?? "—")
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Color.ink)
                Text(m.metric.unit).font(.system(size: 9)).foregroundStyle(Color.dim)
            }

            Text(m.sessions == 0
                 ? "nothing recorded"
                 : "\(m.sessions) session" + (m.sessions == 1 ? "" : "s"))
                .font(.system(size: 9)).foregroundStyle(Color.dim)
                .lineLimit(1).minimumScaleFactor(0.8)

            Text(flagNote(m))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(flagNote(m).isEmpty ? Color.clear : Color.slowerColor)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? m.metric.tint.opacity(0.10) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(on ? m.metric.tint : Color.line, lineWidth: 1)))
        .contentShape(Rectangle())
    }

    /// Never blank when there is something to say, and never a lie when there
    /// is not — an empty string keeps the tile's height stable.
    private func flagNote(_ m: PaceMarker) -> String {
        if m.unverified > 0 { return "\(m.unverified) unverified" }
        if m.flagged > 0 {
            switch m.metric {
            case .run:  return "\(m.flagged) off the bike"
            case .bike: return "\(m.flagged) hilly"
            case .swim: return "\(m.flagged) flagged"
            }
        }
        return ""
    }

    // MARK: The plot

    private var chart: some View {
        Chart {
            ForEach(sessions.filter { !$0.flagged }) { s in
                PointMark(x: .value("Date", s.date),
                          y: .value("Pace", s.value))
                    .foregroundStyle(metric.tint.opacity(0.55))
                    .symbolSize(size(s))
            }
            // Clamped to the edge of the scale rather than clipped away, so a
            // race day is still visibly a race day. Hollow, because the y
            // position is the scale's and not the session's — the caption
            // carries the real figure.
            ForEach(flagged) { s in
                PointMark(x: .value("Date", s.date),
                          y: .value("Pace", clamped(s.value)))
                    .symbol {
                        Circle()
                            .stroke(metric.tint.opacity(0.8), lineWidth: 1.4)
                            .frame(width: 7, height: 7)
                    }
            }
            if showTrend {
                ForEach(PaceSeries.trend(sessions), id: \.date) { t in
                    LineMark(x: .value("Date", t.date),
                             y: .value("Trend", t.value),
                             series: .value("Series", "trend"))
                        .foregroundStyle(metric.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
            }
            // Last, so it is never under a dot. Forward in the cool hue when it
            // is the plan's target; recessive grey when it is only the
            // athlete's own median, because a baseline is not a goal.
            if let r = reference {
                RuleMark(y: .value("Reference", r))
                    .foregroundStyle(referenceIsTarget ? Color.fasterColor : Color.dim)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            // The cursor, last of all. The rule gives the date, the ring says
            // WHICH dot — see the note on `cursorSession`. Plotted at the
            // clamped value so the ring lands on the drawn position of a
            // flagged session rather than off the top of the chart.
            if let c = cursorSession {
                RuleMark(x: .value("Date", c.date))
                    .foregroundStyle(Color.ink.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Date", c.date),
                          y: .value("Pace", clamped(c.value)))
                    .symbol {
                        Circle()
                            .stroke(Color.ink.opacity(0.85), lineWidth: 1.6)
                            .frame(width: 13, height: 13)
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(metric.axisFormat(v)).font(.caption2)
                            .foregroundStyle(Color.dim)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: chrome ? 4 : 7)) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.35))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? CGFloat.infinity : nil)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(metric.tint.opacity(0.55)).frame(width: 6, height: 6)
                Text(sizeByDistance ? "\(metric.label) · size is distance" : metric.label)
                    .font(.caption2).foregroundStyle(Color.dim)
            }
            if !flagged.isEmpty {
                HStack(spacing: 5) {
                    Circle().stroke(metric.tint.opacity(0.8), lineWidth: 1.2)
                        .frame(width: 7, height: 7)
                    Text(metric.flagLabel).font(.caption2).foregroundStyle(Color.dim)
                }
            }
            if showTrend {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(metric.tint).frame(width: 10, height: 2)
                    Text("5-session median").font(.caption2).foregroundStyle(Color.dim)
                }
            }
            if reference != nil {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(referenceIsTarget ? Color.fasterColor : Color.dim)
                        .frame(width: 10, height: 2)
                    Text(referenceIsTarget ? "Target" : "Median")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// COUNTS AND VALUES, NOT RULES
    /// -----------------------------
    /// This was five sentences of rules — what makes a dot hollow, what a
    /// commute is, how a swim is timed — every one of which is already an ⓘ
    /// entry for the discipline on screen (*Flagged sessions*, *Which sessions
    /// count*, *The clock*). Printing them under the chart as well meant the
    /// card explained itself twice and the one thing you could not get anywhere
    /// else — the off-scale values — came last.
    ///
    /// Two things survive, and they are the two the chart genuinely cannot show:
    ///
    ///   THE UNVERIFIED SWIM COUNT  the dots are hollow, but how many is a
    ///                              figure, and the reason is in ⓘ.
    ///   BEYOND THE SCALE           these sessions are NOT DRAWN AT ALL. Delete
    ///                              this and the data is gone from the app, not
    ///                              merely unexplained.
    ///
    /// The bike's "rides under 10 km are commutes" line keeps its OTHER home —
    /// the empty state, where it explains an empty box rather than decorating a
    /// full one.
    private var caption: String? {
        var parts: [String] = []

        if metric == .swim {
            let unverified = sessions.filter { !$0.verified }.count
            if unverified > 0 {
                parts.append("\(unverified) swim" + (unverified == 1 ? "" : "s")
                             + " timed by Strava.")
            }
        }

        if !offScale.isEmpty {
            let list = offScale
                .map { "\(DayKey.short($0.date)) \(metric.format($0.value))" }
                .joined(separator: ", ")
            parts.append("Beyond the scale: \(list).")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// `.cardStyle()` applied conditionally without branching the view type at the
/// call site — a plain `if` there gives the two branches different identities
/// and SwiftUI rebuilds the chart from scratch rather than updating it.
private struct PaceChrome: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        Group {
            if on { content.cardStyle() } else { content }
        }
    }
}
