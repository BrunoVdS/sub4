//
//  WeekView.swift
//  Sub4
//
//  Seven days at a glance, with completion derived from Strava.
//
//  Weeks are generated from the ingest cutoff (a Monday) through race week, so
//  the post-Ironman block and the plan proper are one continuous sequence
//  rather than two separate things. A week before Wk 1 simply has no planned
//  sessions and shows what was recorded.
//
//  Body is deliberately decomposed — a single large body trips the SwiftUI
//  type checker.
//

import SwiftUI

struct WeekView: View {

    private let store = PlanStore.shared
    @State private var matcher = Matcher.shared
    @State private var activities = ActivityStore.shared
    @State private var load = LoadStore.shared

    @State private var index: Int = 0
    @State private var detail: Session?
    @State private var started = false

    // MARK: Week maths

    /// The Monday of the week the WEEK GRID opens in — `weekGridDayKey`, which
    /// since patch 117 is a different constant from the ingest cutoff.
    ///
    /// Ingest now reaches back to 1 July 2025 so the fitness curve and the
    /// volume stack have real history behind them. This tab does not want it:
    /// it grades recorded work against what the plan asked for, and before the
    /// block there is nothing to grade against. Following the ingest window
    /// would have put fifty rows of pre-plan weeks in front of week 1.
    ///
    /// IT WAS NEVER A MONDAY
    /// ---------------------
    /// This used to be `MatchRules.cutoffDayKey` unchanged, and that key was
    /// **2026-01-01 — a Thursday**. Every week on this tab therefore ran
    /// Thursday to Wednesday, and `planWeek` looks the plan up by
    /// `startDate == weekStart`. Plan weeks start on Mondays, so the lookup
    /// could never match: not once in 34 weeks.
    ///
    /// Everything downstream of `planWeek` was dead as a result — the week
    /// number, the tag, the badge, the planned figure — and the title fell
    /// through to its "Post-Ironman" default forever, including for week 1 of
    /// the marathon block.
    ///
    /// Snapping to the Monday of the containing week puts the grid back on the
    /// plan's own boundaries: 29 December 2025, which is exactly 30 weeks
    /// before plan week 1. Nothing recorded is excluded, because that Monday
    /// is earlier than the grid key rather than later.
    private var firstMonday: Date {
        let d = DayKey.date(MatchRules.weekGridDayKey) ?? Date()
        return Self.iso.dateInterval(of: .weekOfYear, for: d)?.start ?? d
    }

    /// ISO, not `Calendar.current`. The current calendar's first weekday
    /// follows the device locale — Sunday in the United States — and a week
    /// grid that moves when you change region is a week grid that will not line
    /// up with a plan written in ISO weeks.
    private static let iso = Calendar(identifier: .iso8601)

    private var weekStart: Date {
        Self.iso.date(byAdding: .day, value: index * 7, to: firstMonday) ?? firstMonday
    }

    private var dayKeys: [String] {
        (0..<7).compactMap { offset in
            Self.iso.date(byAdding: .day, value: offset, to: weekStart).map(DayKey.key)
        }
    }

    private var planWeek: Week? {
        store.planWeeks.first { $0.startDate == DayKey.key(weekStart) }
    }

    private var lastIndex: Int {
        guard let last = store.planWeeks.last?.startDate,
              let d = DayKey.date(last) else { return 0 }
        let days = Self.iso.dateComponents([.day], from: firstMonday, to: d).day ?? 0
        return max(0, days / 7)
    }

    /// Index of the week containing today, clamped into range.
    private var todayIndex: Int {
        let days = Self.iso.dateComponents(
            [.day], from: firstMonday,
            to: Self.iso.startOfDay(for: Date())).day ?? 0
        return min(max(0, days / 7), lastIndex)
    }

    // MARK: Body

    // WHICH WEEK, AND HOW IT IS GOING, STAY ON SCREEN
    // -----------------------------------------------
    // The header and the summary used to be two cards inside the scroll view,
    // so scrolling to Saturday took both off the top — and Saturday is exactly
    // when you want to know which week you are in and how much of it is done.
    // They are one card now, outside the ScrollView, and only the days move.
    //
    // Merging them costs less height than it saves: two cards carried two sets
    // of padding and a gap between them, and "Sessions 3/4" was printed once in
    // the bar and again as a metric.
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                weekCard
                    .padding(.horizontal, 16)
                    // Sells the pinning: the days pass beneath an edge rather
                    // than stopping at a seam the same colour as the page.
                    .shadow(color: Color.panelShadow.opacity(0.45), radius: 7, y: 4)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(dayKeys, id: \.self) {
                            DayRow(dayKey: $0, onOpen: { detail = $0 })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .padding(.top, 10)
            .background(Color.bg)
            .navigationTitle("Week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if index != todayIndex {
                        Button("This week") { withAnimation { index = todayIndex } }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .sheet(item: $detail) { SessionDetailView(session: $0) }
        }
        .tint(.accent4)
        .onAppear {
            guard !started else { return }
            started = true
            index = todayIndex
        }
    }

    // MARK: Header

    private var navRow: some View {
        HStack {
            stepButton("chevron.left", enabled: index > 0) { index -= 1 }
            Spacer()
            VStack(spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(.headline)
                    headerBadge
                }
                Text(subtitle).font(.caption)
                    .foregroundStyle(Color.dim)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            stepButton("chevron.right", enabled: index < lastIndex) { index += 1 }
        }
    }

    /// The plan's own badge for this week, weighted the same way the Plan tab
    /// weights it. Asking "is this a hard week?" happens here too.
    @ViewBuilder
    private var headerBadge: some View {
        if let w = planWeek, let k = w.weekKind, let text = w.badge, !text.isEmpty {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(k.isFilled ? k.tint : Color.clear)
                .foregroundStyle(k.onTint)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(k.isFilled ? .clear : Color.line, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .fixedSize()
        }
    }

    private var title: String {
        if let w = planWeek, let n = w.weekNo {
            return "Week \(n) of \(store.totalPlanWeeks)"
        }
        // NOT "Post-Ironman". These weeks run from 29 December 2025, and the
        // Ironman was in June — so for five of the seven months this label was
        // describing a race that had not happened yet. What is true of every
        // one of them, and the only thing the app can state without inventing a
        // date it does not hold, is that they precede the block. The date range
        // underneath says when.
        return "Before the plan"
    }

    private var subtitle: String {
        let range = planWeek?.dateRange ?? defaultRange
        guard let tag = planWeek?.tag, !tag.isEmpty else { return range }
        return "\(range) · \(tag)"
    }

    private var defaultRange: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        let end = Self.iso.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return "\(f.string(from: weekStart))–\(f.string(from: end))"
    }

    private func stepButton(_ icon: String,
                            enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { action() } } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(Color.bg)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.dim : Color.dim.opacity(0.25))
        .disabled(!enabled)
    }

    // MARK: The pinned card

    private var weekCard: some View {
        let t = totals
        return VStack(spacing: 11) {
            navRow
            // Always present, so "which week" is separated from "how it is
            // going" even in a week the plan prescribes nothing for.
            Divider().overlay(Color.line)
            if t.total > 0 {
                VStack(spacing: 6) {
                    HStack {
                        Text("Sessions").font(.caption).foregroundStyle(Color.dim)
                        Spacer()
                        Text("\(t.done)/\(t.total)")
                            .font(.caption.weight(.bold)).monospacedDigit()
                            .foregroundStyle(t.done == t.total ? Color.accent4 : Color.dim)
                    }
                    ProgressView(value: Double(t.done), total: Double(t.total))
                        .tint(.accent4)
                }
            }

            // RUN AGAINST RUN, NOT ALL-SPORT AGAINST THE PLAN'S BUDGET
            // ---------------------------------------------------------
            // This row used to read "Recorded 44.2 km" beside "Planned 275 km",
            // and both halves were wrong for the same reason: they were not the
            // same quantity.
            //
            // The recorded figure added every activity's kilometres together —
            // 3 km of swimming plus 20 km of running plus 60 km of riding — a
            // sum with no meaning, since a swum kilometre and a ridden one are
            // not the same thing. The planned figure was `week.stats["km"]`,
            // which is the plan author's ALL-SPORT budget and includes an
            // assumed commute the source document states as
            // "32 km × 5 ≈ 160 km / 10 h a week". Bruno's actual commute is
            // about 21 km a week, so 160 of that 275 was never going to appear.
            //
            // Side by side they invited one subtraction, and the answer was
            // always a catastrophic shortfall that did not exist. Running is
            // what this plan is for and what the plan states per session, so
            // the pair is now running against running. `plannedRunKm` is the
            // same estimator the Plan tab and the review already use.
            let planned = planWeek.map { store.plannedRunKm(week: $0) }
            HStack(spacing: 0) {
                MetricCell(label: "Run", value: String(format: "%.1f", t.runKm),
                           unit: "km", colour: .accent4)
                MetricDivider()
                if let p = planned, p.km > 0 {
                    MetricCell(label: "Planned",
                               value: String(format: "%@%.0f", p.exact ? "" : "≈", p.km),
                               unit: "km", colour: .dim)
                } else {
                    MetricCell(label: "Time", value: "\(t.minutes)",
                               unit: "min", colour: .dim)
                }
                MetricDivider()
                MetricCell(label: "Activities", value: "\(t.recorded)",
                           unit: "", colour: .dim)
            }

            loadStrip
        }
        .cardStyle()
    }

    // MARK: What the week did to the curve
    //
    // THE SAME STRIP AS TODAY, MEASURING A DIFFERENT THING
    // ----------------------------------------------------
    // Today answers "where am I, and what did this morning do to it". A week
    // cannot answer the first question with a single CTL — it has seven — so the
    // figure printed is where the curve ENDED UP, and the change beneath it is
    // how far it travelled to get there.
    //
    // That second number is the RAMP, and until now it existed only as a
    // sentence in the fitness ⓘ calling it "the number a build is actually
    // steered by". It has never been on screen. Guidance is written in roughly
    // +3 to +5 CTL a week, so this is the one place in the app where the change
    // is directly comparable to something somebody else wrote down.
    //
    // The cell, the colours and the level threshold come from LoadMetrics, so
    // this strip and Today's cannot drift apart.
    //
    // TAPPING OPENS THE SAME PANEL TODAY'S STRIP OPENS
    // ------------------------------------------------
    // `PanelGroup.loadFromStrip` with `opensOn: "fitness"` — character for
    // character what TodayView passes, and deliberately so. There is one fitness
    // chart in this app and it should be one tap from anywhere its numbers are
    // printed; a Week-specific variant would be a second thing to keep correct
    // for no gain, since the chart shows the whole curve either way.
    //
    // The tap target is the strip ONLY, not the card. The rows above it — Run,
    // Planned, Activities — are week bookkeeping and have nothing to expand, and
    // making the whole card open the fitness chart would mean tapping "Planned
    // 18 km" lands on a CTL curve. The Divider is left outside the tappable
    // region so the boundary a finger finds is the boundary the eye sees.
    @ViewBuilder
    private var loadStrip: some View {
        if let w = WeekLoadSummary.build(load.pmc, dayKeys: dayKeys) {
            Divider().overlay(Color.line)
            ExpandableCard(panels: PanelGroup.loadFromStrip, opensOn: "fitness") {
                strip(w)
            }
        }
    }

    private func strip(_ w: WeekLoadSummary) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                // INK, NOT accent4 — patch 142. On Today this figure is accent4
                // when the day was measured and dim when it was not, so the
                // colour carries something. A week's total has no such state,
                // which made accent4 here pure decoration sitting two columns
                // from a `slowerColor` delta it is indistinguishable from.
                MetricCell(label: "Load",
                           value: String(format: "%.0f", w.totalLoad),
                           unit: "TRIMP", colour: .ink)
                MetricDivider()
                MetricCell(label: "Fitness",
                           value: w.ctl.map { String(format: "%.0f", $0) } ?? "—",
                           unit: "CTL", colour: .dim,
                           swatch: .line(Color.ctlTint),
                           delta: MetricDelta(w.ctlChange, upIsGood: true))
                MetricDivider()
                MetricCell(label: "Fatigue",
                           value: w.atl.map { String(format: "%.0f", $0) } ?? "—",
                           unit: "ATL", colour: .dim,
                           swatch: .line(Color.atlTint),
                           delta: MetricDelta(w.atlChange, upIsGood: false))
                MetricDivider()
                // A CLOSURE, NOT `map(PMC.freshnessLabel)`.
                //
                // Passing a MainActor-isolated method as a FUNCTION VALUE strips
                // its isolation — `map` has no idea where it will be called from,
                // so the compiler warns that the call is implicitly async. A
                // closure literal inherits the isolation of the context it is
                // written in, which here is the MainActor, and the warning goes.
                //
                // Second time this exact trap has been sprung: patch 129 had
                // `decoded.filter(Self.isKept)` for the same reason. The tell is
                // a bare type-qualified name where an argument list is expected.
                MetricCell(label: w.tsb.map { PMC.freshnessLabel($0) } ?? "Fresh",
                           value: w.tsb.map { String(format: "%+.0f", $0) } ?? "—",
                           unit: "TSB", colour: .dim, swatch: .area,
                           delta: MetricDelta(w.tsbChange, upIsGood: true))
            }
            if let note = loadNote(w) {
                Text(note).font(.system(size: 9)).foregroundStyle(Color.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Said only when it changes how the figures should be read.
    ///
    /// A part-week total is not comparable to a finished one, and an imputed day
    /// is a number the app invented to keep the curve continuous rather than one
    /// it measured. Both are silent everywhere else on this card, so they are
    /// stated here or nowhere.
    private func loadNote(_ w: WeekLoadSummary) -> String? {
        var parts: [String] = []
        if w.isPartial { parts.append("week still running") }
        if w.imputedDays == 1 { parts.append("1 day filled in") }
        else if w.imputedDays > 1 { parts.append("\(w.imputedDays) days filled in") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Week roll-up. `done` counts non-rest planned sessions with a match.
    /// `runKm` is running only. `minutes` and `recorded` still cover everything,
    /// because time and a session count ARE comparable across sports — only
    /// distance is not.
    /// PATCH 328 — the tally comes from `SessionTally`, the distances do not.
    ///
    /// Two different questions and only one of them was duplicated. "How many
    /// planned sessions were completed" is the app's most-copied derivation
    /// and now has one implementation; "how far did you actually move this
    /// week" is asked here and nowhere else, counts EXTRAS as well as matched
    /// activities, and stays local.
    ///
    /// **This changes what the Week tab prints.** The optional Zwift rides
    /// were in `total` and are not any more, so a week containing one shows a
    /// smaller denominator than it did at 327. §12.72.
    private var totals: (done: Int, total: Int, runKm: Double,
                         minutes: Int, recorded: Int) {
        var km = 0.0, mins = 0, count = 0
        var tally = SessionTally.Result()
        for key in dayKeys {
            let r = matcher.day(key)
            tally = tally + SessionTally.over(r.matches)
            for a in r.matches.compactMap(\.activity) {
                if a.discipline == .run { km += a.km }
                mins += a.minutes; count += 1
            }
            for a in r.extras {
                if a.discipline == .run { km += a.km }
                mins += a.minutes; count += 1
            }
        }
        return (tally.done, tally.total, km, mins, count)
    }
}

// MARK: - One day

struct DayRow: View {
    let dayKey: String
    let onOpen: (Session) -> Void

    @State private var matcher = Matcher.shared
    /// For `dayZones` only. Observed rather than read statically so the marker
    /// appears when the history finishes loading rather than one navigation
    /// later.
    @State private var store = ActivityStore.shared

    /// Owned here rather than passed down from WeekView and PlanWeekDetail —
    /// one row is the only thing that can be open at a time anyway, and it keeps
    /// both parents unchanged. This is also what gives Week AND Plan note
    /// editing in one change: DayRow is used by both.
    ///
    /// One enum, one `.sheet`. Two stacked `.sheet` modifiers on a single view
    /// is unreliable in SwiftUI — some of them silently never present — and
    /// that is the bug this change is fixing on Today.
    private enum Route: Identifiable {
        case activity(Activity)
        case merged(MergedExtra)
        case fuel(ladder: Bool, raceDay: Bool)
        case warmup

        var id: String {
            switch self {
            case .activity(let a): "activity-\(a.id)"
            case .merged(let m):   m.id
            case .fuel(let l, let r): "fuel-\(l)-\(r)"
            case .warmup:         "warmup"
            }
        }
    }

    @State private var route: Route?

    private var resolved: (matches: [Match], extras: [Activity]) { matcher.day(dayKey) }
    private var isToday: Bool { dayKey == DayKey.key() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dayHeader
            let r = resolved
            if r.matches.isEmpty && r.extras.isEmpty {
                Text("—").font(.subheadline).foregroundStyle(Color.dim.opacity(0.5))
            } else {
                ForEach(r.matches, id: \.session.uid) { sessionLine($0) }
                // Same-type extras collapse per day since patch 177 — the week
                // grid is the screen that suffered most from four walk rows on
                // one day. See MergedActivity.
                ForEach(MergedExtra.group(r.extras)) { item in
                    switch item {
                    case .single(let a): extraLine(a)
                    case .merged(let m): mergedLine(m)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isToday ? Color.accent4.opacity(0.55) : .clear, lineWidth: 1.5)
        )
        .sheet(item: $route) { r in
            switch r {
            case .activity(let a): ActivityDetailView(activity: a)
            case .merged(let m):   MergedDetailView(merged: m)
            case .fuel(let l, let r):
                // See SessionDetailView — race day is its own destination.
                if r { RaceDayView() } else { FuelView(scrollToLadder: l) }
            case .warmup:          WarmupView()
            }
        }
    }

    private var dayHeader: some View {
        HStack(spacing: 6) {
            Text(weekdayLabel.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.5)
                .foregroundStyle(isToday ? Color.accent4 : Color.dim)
            Text(dayNumber).font(.caption2).foregroundStyle(Color.dim)
            // Which clock this day was lived on, shown only when it was not the
            // reader's — patch 201, ADR-0003 §4.5. Silent on the 640 days at
            // home, which is what makes it worth reading on the twenty-three it
            // is not.
            if let zone = zoneMarker {
                Text(zone)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accent4)
            }
            Spacer()
            if let km = dayKm, km > 0 {
                Text(String(format: "%.1f km", km))
                    .font(.caption2.weight(.semibold)).foregroundStyle(Color.dim)
            }
        }
    }

    /// `"JST"` for a day counted from another midnight, nil for a day at home.
    ///
    /// Read from `ActivityStore` rather than computed here: `DayZones.from`
    /// walks the whole history, and seven `DayRow`s recomputing it on every
    /// body pass would do that seven times a frame during a scroll.
    private var zoneMarker: String? {
        store.dayZones.marker(forDay: dayKey)
    }

    private var dayKm: Double? {
        let r = resolved
        let a = r.matches.compactMap(\.activity).reduce(0) { $0 + $1.km }
        return a + r.extras.reduce(0) { $0 + $1.km }
    }

    private var weekdayLabel: String {
        guard let d = DayKey.date(dayKey) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE"
        return f.string(from: d)
    }

    private var dayNumber: String {
        guard let d = DayKey.date(dayKey) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    /// ONE DESTINATION PER ROW (patch 104). The title and the recorded figure
    /// used to open two different pages; now both call `open`, which sends a
    /// matched session to its activity and an unmatched one to the plan page.
    /// The pencil is gone — a note is written on the activity page only.
    ///
    /// Any note that exists is still PRINTED under the line, so a week can be
    /// read without opening anything. Reading it here and writing it there is
    /// the split the patch is making.
    private func sessionLine(_ m: Match) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button { open(m) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: m.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.footnote)
                            .foregroundStyle(m.isDone ? m.session.tint : Color.dim.opacity(0.4))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(m.session.tint).frame(width: 3, height: 16)
                        Text(m.session.title ?? "—")
                            .font(.subheadline)
                            .foregroundStyle(m.isDone ? Color.dim : Color.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let a = m.activity {
                    Button { route = .activity(a) } label: {
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f", a.km))
                                .font(.caption2.weight(.semibold))
                            Image(systemName: "chart.bar.xaxis").font(.caption2)
                        }
                        .foregroundStyle(Color.accent4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            PrepLine(session: m.session) { route = .warmup }
                .padding(.leading, 21)
            FuelLine(session: m.session) {
                route = .fuel(ladder: m.session.fuelPointsAtLadder,
                              raceDay: m.session.fuelPointsAtRaceDay)
            }
            .padding(.leading, 21)
            NoteSummary(session: m.session)
        }
    }

    private func open(_ m: Match) {
        if let a = m.activity { route = .activity(a) } else { onOpen(m.session) }
    }

    private func extraLine(_ a: Activity) -> some View {
        Button { route = .activity(a) } label: {
            HStack(spacing: 9) {
                Image(systemName: a.extraSymbol)
                    .font(.caption2).foregroundStyle(Color.dim.opacity(0.7))
                    .frame(width: 14)
                Text(a.name).font(.caption).foregroundStyle(Color.dim).lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: "%.1f", a.km))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
            .padding(.leading, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The merged day's one line. "Walks · 3" says the count where a single's
    /// line says its name — the km figure stays in the same column.
    private func mergedLine(_ m: MergedExtra) -> some View {
        Button { route = .merged(m) } label: {
            HStack(spacing: 9) {
                Image(systemName: m.symbol)
                    .font(.caption2).foregroundStyle(Color.dim.opacity(0.7))
                    .frame(width: 14)
                Text("\(m.title) · \(m.parts.count)")
                    .font(.caption).foregroundStyle(Color.dim).lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: "%.1f", m.km))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
            .padding(.leading, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
