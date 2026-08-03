//
//  TodayView.swift
//  Sub4
//
//  Primary screen. Completion is DERIVED from Strava — nothing here creates a
//  log entry. If a session shows as not done, the activity hasn't arrived.
//

import SwiftUI

struct TodayView: View {

    private let store = PlanStore.shared
    @State private var activities = ActivityStore.shared
    @State private var matcher = Matcher.shared
    @State private var health = HealthStore.shared
    @State private var load = LoadStore.shared
    @State private var proposals = ProposalStore.shared

    @State private var day: Date = Date()
    // ONE sheet, not five.
    //
    // This view used to carry five separate `.sheet` modifiers stacked on the
    // same view — session detail, match picker, activity data, note, settings.
    // SwiftUI presents one sheet per view at a time, and stacking modifiers
    // that way is unreliable: some of them silently never present, and which
    // ones is not something you can reason about from the code. That is the
    // most likely reason the session sheet would not open from Today while the
    // identical sheet opened fine from Week, which has one.
    //
    // A single modifier driven by an enum removes the whole class of problem
    // and makes the set of things this screen can present explicit.
    private enum Route: Identifiable {
        case session(Session)
        case fix(Session)
        case activity(Activity)
        case merged(MergedExtra)
        case fuel(ladder: Bool, raceDay: Bool)
        case warmup
        case review

        var id: String {
            switch self {
            case .session(let s):  "session-\(s.uid)"
            case .fix(let s):      "fix-\(s.uid)"
            case .activity(let a): "activity-\(a.id)"
            case .merged(let m):   m.id
            case .fuel(let l, let r): "fuel-\(l)-\(r)"
            case .warmup:         "warmup"
            case .review:          "review"
            }
        }
    }

    @State private var route: Route?

    private var key: String { DayKey.key(day) }
    private var isToday: Bool { key == DayKey.key() }

    /// HISTORY · TODAY · FUTURE — patch 158.
    ///
    /// The title used to read `isToday ? "Today" : "Plan"`, which called
    /// yesterday a plan. Yesterday is not a plan: it is a record of what was
    /// done, and on this screen it shows recorded activities, matched sessions
    /// and a note you already wrote. Calling that "Plan" was the screen telling
    /// you the wrong thing about what you were looking at.
    ///
    /// Three words, because there are three states and the middle one is the
    /// only one where both halves of the page are live at once: what was asked
    /// for, and what happened.
    private enum DayRelation { case history, today, future }

    private var relation: DayRelation {
        let k = key, t = DayKey.key()
        if k == t { return .today }
        return k < t ? .history : .future
    }

    private var title: String {
        switch relation {
        case .history: "History"
        case .today:   "Today"
        case .future:  "Future"
        }
    }
    private var week: Week? { store.week(containing: key) }

    /// Days before Wk 1 — the post-Ironman block. Recorded training here isn't
    /// "extra", it's simply what was done, so it gets shown on its own terms.
    private var isPrePlan: Bool { MatchRules.isPrePlan(key) }

    private var resolved: (matches: [Match], extras: [Activity]) { matcher.day(key) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if let err = store.loadError {
                        banner("Plan not loaded", err, .red)
                    } else {
                        // Above the race card on purpose. It appears at most
                        // once every 28 days, it is the only thing on this
                        // screen that wants doing rather than reading, and it
                        // is dismissed by doing it.
                        if isToday { reviewBanner }
                        raceCard
                        header

                        let r = resolved
                        if r.matches.isEmpty && r.extras.isEmpty { emptyDay }
                        // The done/total bar that used to sit here is gone. The
                        // session cards above already show completion one by
                        // one, with a tick or an empty circle each — the bar
                        // restated that in a form carrying strictly less
                        // information.
                        if !r.matches.isEmpty { cards(r.matches) }
                        if !r.extras.isEmpty { extrasSection(r.extras) }

                        movementCard(r)
                        loadStrip
                        // Under the strip, not instead of it. The strip has the
                        // figures; these have the fortnight behind them.
                        TodayTiles(summary: load.pmc, dayKey: key)
                        // WAS: a Strava error banner here, an orange "Connect
                        // Strava" card above the cards, and a cloud icon in the
                        // toolbar — three statements of one fact on one screen,
                        // with Settings making a fourth. All three are gone; the
                        // alarm is a badge on the Settings tab. See ContentView.
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.bg)
            // SWIPE BETWEEN DAYS — patch 158.
            //
            // `simultaneousGesture`, and only `onEnded`. The page is a vertical
            // ScrollView, so the drag has to be shared rather than taken: a
            // plain `.gesture` wins the contest and the screen stops scrolling.
            // Nothing is consumed while the finger is down, so scrolling is
            // untouched; the decision is made once, at lift.
            //
            // TWO TESTS, BOTH REQUIRED. Horizontal travel has to beat vertical
            // by half again — a diagonal flick during a scroll is a scroll —
            // and it has to clear 60 pt, so a tap that wobbles is not a day.
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { g in
                        let dx = g.translation.width, dy = g.translation.height
                        guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                        // Dragging LEFT moves forward, the direction a page
                        // turns. The content follows the finger.
                        shift(dx < 0 ? 1 : -1)
                    }
            )
            .refreshable { await activities.sync() }
            // Fingerprint-guarded, so this is free once the series is current.
            .task { load.recomputeIfNeeded() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // THE CLOUD BUTTON WENT TOO, AND IT WAS DOING TWO JOBS BADLY.
            // As an ACTION it duplicated `.refreshable` below, which is the
            // gesture anyone reaches for on a scrolling screen anyway. As an
            // INDICATOR it was one of the three Strava statements this screen
            // was making; that job belongs to the Settings badge now. The gear
            // went with it — Settings is a tab.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !isToday {
                        Button("Today") { withAnimation { day = Date() } }
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .sheet(item: $route) { r in
                switch r {
                case .session(let s):  SessionDetailView(session: s)
                case .fix(let s):      MatchPickerView(session: s, dayKey: key)
                case .activity(let a): ActivityDetailView(activity: a)
                case .merged(let m):   MergedDetailView(merged: m)
                        case .fuel(let l, let r):
                    // See SessionDetailView — race day is its own destination.
                    if r { RaceDayView() } else { FuelView(scrollToLadder: l) }
                case .warmup:          WarmupView()
                case .review:          ReviewView()
                }
            }
        }
        .tint(.accent4)
        .task {
            // Independent and non-blocking: neither can stall the other, and a
            // misbehaving HealthKit query can't hold up the Strava sync.
            async let strava: Void = activities.syncIfNeeded()
            async let steps: Void = health.refreshIfPossible()
            _ = await (strava, steps)
            // The load engine now reads a heart rate from Health where Strava
            // has none, so the workout cache has to exist by the time the
            // series is built rather than only once a chart has asked for it.
            // Throttled to an hour inside, and a no-op without authorisation.
            await health.loadWorkoutCacheIfStale(since: MatchRules.cutoffDayKey)
            // Zones and gear barely move — at most once a day, after the sync
            // so a fresh token is already in hand.
            await AthleteStore.shared.refreshIfStale()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            step("chevron.left", enabled: canShift(-1)) { shift(-1) }
            Spacer()
            VStack(spacing: 2) {
                Text(DayKey.pretty(day)).font(.headline)
                if let w = week {
                    Text(subtitle(w)).font(.caption)
                        .foregroundStyle(Color.dim)
                        .multilineTextAlignment(.center)
                } else if isPrePlan {
                    Text("Before the plan")
                        .font(.caption).foregroundStyle(Color.dim)
                }
            }
            Spacer()
            step("chevron.right", enabled: canShift(1)) { shift(1) }
        }
        .cardStyle()
    }

    private func subtitle(_ w: Week) -> String {
        var p: [String] = []
        if let n = w.weekNo { p.append("Week \(n) of \(store.totalPlanWeeks)") }
        else { p.append(w.display) }
        if let t = w.tag, !t.isEmpty { p.append(t) }
        return p.joined(separator: " · ")
    }

    private func step(_ icon: String, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(Color.bg).clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.dim : Color.dim.opacity(0.25))
        .disabled(!enabled)
    }

    /// The first and last day worth walking to.
    ///
    /// BOUNDED, because an unbounded stepper is a control that does nothing for
    /// as long as you hold it. Backwards stops at the ingest cutoff — before it
    /// there are no activities and never will be. Forwards stops at the end of
    /// race week, which is the last day the plan has an opinion about.
    private var earliestKey: String { MatchRules.cutoffDayKey }

    private var latestKey: String {
        guard let last = store.planWeeks.last?.startDate,
              let d = DayKey.date(last),
              let end = Calendar(identifier: .iso8601)
                  .date(byAdding: .day, value: 6, to: d) else { return DayKey.key() }
        return DayKey.key(end)
    }

    private func canShift(_ d: Int) -> Bool {
        guard let next = Calendar.current.date(byAdding: .day, value: d, to: day)
        else { return false }
        let k = DayKey.key(next)
        return k >= earliestKey && k <= latestKey
    }

    private func shift(_ d: Int) {
        guard canShift(d),
              let next = Calendar.current.date(byAdding: .day, value: d, to: day)
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) { day = next }
    }

    // MARK: Cards

    private func cards(_ matches: [Match]) -> some View {
        ForEach(matches, id: \.session.uid) { m in
            MatchRow(match: m,
                     // ONE DESTINATION PER CARD (patch 104). Tapping the row and
                     // tapping the little chart icon used to land on two
                     // different pages showing overlapping content, and which
                     // one you got depended on where your thumb fell. A matched
                     // session now always opens the activity — which is where
                     // everything about it lives — and an unmatched one opens
                     // the plan page, because there is no activity to open.
                     onOpen: { open(m) },
                     onFix: { route = .fix(m.session) },
                     onData: { open(m) },
                     onFuel: { route = .fuel(ladder: m.session.fuelPointsAtLadder,
                                             raceDay: m.session.fuelPointsAtRaceDay) },
                     onPrep: { route = .warmup })
        }
    }

    private func open(_ m: Match) {
        if let a = m.activity { route = .activity(a) } else { route = .session(m.session) }
    }

    /// Everything outside the plan — commutes, walks, kayaking, and any session
    /// activity that found no match. Kept, not discarded: this is the rest of
    /// the movement picture.
    private func extrasSection(_ acts: [Activity]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(isPrePlan ? "RECORDED" : "EXTRA MOVEMENT")
                    .font(.caption2.weight(.bold)).tracking(0.5)
                Spacer()
                Text(String(format: "%.1f km · %d min",
                            acts.reduce(0) { $0 + $1.km },
                            acts.reduce(0) { $0 + $1.minutes }))
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isPrePlan ? Color.accent4.opacity(0.9) : Color.dim)

            // Extras are tappable too — a commute or a walk has a route and a
            // heart rate like anything else.
            //
            // GROUPED SINCE PATCH 177: same-type extras on one day collapse
            // into a single row — four walks are one fact, not four. The
            // totals line above already summed everything, so nothing up
            // there changes; only the row count does. See MergedActivity.
            ForEach(MergedExtra.group(acts)) { item in
                switch item {
                case .single(let a):
                    extraRow(symbol: a.extraSymbol,
                             title: a.name,
                             caption: a.extraLabel,
                             km: a.km,
                             minutes: a.minutes) { route = .activity(a) }
                case .merged(let m):
                    extraRow(symbol: m.symbol,
                             title: m.title,
                             caption: "\(m.countLabel) · \(m.timeSpan)",
                             km: m.km,
                             minutes: m.minutes) { route = .merged(m) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// One row shape for both cases, so a merged day and a lone kayak are
    /// visually the same species and the only difference is what the words say.
    private func extraRow(symbol: String, title: String, caption: String,
                          km: Double, minutes: Int,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.caption).foregroundStyle(Color.dim)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline).foregroundStyle(Color.ink)
                    Text(caption).font(.caption2).foregroundStyle(Color.dim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if km >= 0.05 {
                        Text(String(format: "%.1f km", km))
                            .font(.caption.weight(.semibold))
                    }
                    Text("\(minutes) min").font(.caption2)
                }
                .foregroundStyle(Color.dim)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(Color.dim.opacity(0.5))
            }
            // Same fix as the planned row: the Spacer in the middle is
            // empty space, and empty space in a stack is not a hit
            // target unless it is told to be one.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Day total. Inside the plan: plan volume vs extra. Before the plan:
    /// a single total, because nothing was "planned" to compare against.
    private func movementCard(_ r: (matches: [Match], extras: [Activity])) -> some View {
        let planKm  = r.matches.compactMap(\.activity).reduce(0) { $0 + $1.km }
        let extraKm = r.extras.reduce(0) { $0 + $1.km }
        let mins    = r.matches.compactMap(\.activity).reduce(0) { $0 + $1.minutes }
                    + r.extras.reduce(0) { $0 + $1.minutes }
        let steps   = health.steps(on: key)

        return HStack(spacing: 0) {
            if isPrePlan {
                MetricCell(label: "Total",
                           value: String(format: "%.1f", planKm + extraKm),
                           unit: "km", colour: .accent4)
                MetricDivider()
                MetricCell(label: "Time", value: "\(mins)", unit: "min", colour: .dim)
            } else {
                MetricCell(label: "Plan", value: String(format: "%.1f", planKm),
                           unit: "km", colour: .accent4)
                MetricDivider()
                MetricCell(label: "Extra", value: String(format: "%.1f", extraKm),
                           unit: "km", colour: .dim)
            }
            MetricDivider()
            if let s = steps {
                MetricCell(label: "Steps",
                           value: s.formatted(.number.grouping(.automatic)),
                           unit: "", colour: .dim)
            } else {
                Button { Task { await health.requestAuthorization() } } label: {
                    VStack(spacing: 2) {
                        Text("Steps").font(.caption2).foregroundStyle(Color.dim)
                        Image(systemName: "heart.text.square")
                            .font(.subheadline).foregroundStyle(Color.accent4)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    // MARK: Load
    //
    // Two figures, and no more. Today is "what am I meant to do, and did I do
    // it" — a fitness chart belongs on Progress, not here.
    //
    // The freshness half is GATED. Inside the 42-day warm-up, or with too much
    // of the recent window filled in, it is absent rather than caveated: a TSB
    // computed from three weeks of history looks exactly like a real one, and
    // this is the screen read in a hurry.

    // FOUR NUMBERS, AND IT NO LONGER HIDES ITSELF.
    //
    // The old strip appeared only when the day had scored something, and showed
    // EITHER fitness OR freshness depending on a gate. Both were wrong for the
    // same reason: a rest day, a commute-only day, or a morning before you have
    // trained are precisely the days you open this screen to decide whether to
    // train — and they were the days it vanished.
    //
    // It now always shows, and carries the whole state: what today contributed,
    // and the three figures that describe where that leaves you. Load is the
    // input; fitness, fatigue and freshness are one model read at three time
    // constants, and freshness is literally the difference between the other
    // two, so splitting them across a gate never made sense.
    //
    // Tapping opens the same rotated panel the Fitness card on Progress opens.
    // One gesture, one meaning, no second code path.
    @ViewBuilder
    private var loadStrip: some View {
        // `load.pmc` is stored rather than computed since patch 60, so this no
        // longer has to be built inside a branch to avoid paying for the curve
        // on every body pass. That constraint is what shaped the old gate.
        let s = load.pmc
        // Freshness for the day BEING VIEWED, not for today. `s.tsb` is always
        // the end of the series, so stepping back three weeks would have paired
        // that Tuesday's load with this morning's freshness and presented the
        // pair as one day.
        let p = s.points.first { $0.dayKey == key }
        if p != nil || load.day(key) != nil {
            // The strip's own gate is looser than the Progress card's — it shows
            // whenever the day has numbers, caveat or not — so it uses the
            // variant that guarantees Fitness is in the group. Without that, a
            // tap during the warm-up would open Load pattern, or nothing.
            ExpandableCard(panels: PanelGroup.loadFromStrip, opensOn: "fitness") {
                stripBody(s, p)
            }
        }
    }

    // MARK: The day-on-day change
    //
    // The cell, the divider and the colour convention moved to LoadMetrics.swift
    // in patch 139, when the Week tab asked for the same strip. What stays here
    // is the only part that is about TODAY: which two points to subtract.
    //
    // CTL is an exponential average with a 42-day time constant, so the figure
    // itself barely moves and the movement is the whole point. "31" tells you
    // where you are; "−0.7" tells you what this morning did to it.

    /// nil when there is no yesterday in the series, or when the curve is not
    /// trusted — a delta between two numbers the app has just said it does not
    /// believe is two mistakes presented as progress.
    private func delta(_ s: PMCSummary, _ p: PMCPoint?,
                       _ value: (PMCPoint) -> Double?,
                       upIsGood: Bool) -> MetricDelta? {
        guard s.isTrustworthy, let p, let now = value(p),
              let d = DayKey.date(p.dayKey),
              let prevKey = Calendar(identifier: .iso8601)
                  .date(byAdding: .day, value: -1, to: d).map(DayKey.key),
              // Looked up by DAY rather than by index. The series is contiguous
              // today, and `points[i - 1]` would keep compiling and quietly stop
              // meaning "yesterday" the first time it is not.
              let prev = s.points.first(where: { $0.dayKey == prevKey }),
              let before = value(prev)
        else { return nil }
        return MetricDelta(now - before, upIsGood: upIsGood)
    }

    private func stripBody(_ s: PMCSummary, _ p: PMCPoint?) -> some View {
        let day = load.day(key)
        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                // A gap is not a zero. Showing "0 TRIMP" in the accent colour
                // for a day that held an hour of training nothing could score
                // is the exact conflation the whole engine is built to avoid.
                MetricCell(label: "Load",
                           value: day == nil ? "—"
                               : (day!.state == .gap ? "—" : String(format: "%.0f", day!.load)),
                           unit: day?.state == .gap ? "not scored"
                               : (day?.state == .partial ? "floor" : "TRIMP"),
                           colour: day?.state == .measured ? Color.accent4 : Color.dim)
                MetricDivider()
                // The three PMC figures stand or fall together. Showing fitness
                // while withholding freshness, as the old version did, presents
                // one number from a curve the app has just decided it does not
                // trust — and a CTL from three weeks of history looks exactly
                // like a real one.
                MetricCell(label: "Fitness",
                           value: s.isTrustworthy
                               ? (p.map { String(format: "%.0f", $0.ctl) } ?? "—") : "—",
                           unit: "CTL", colour: Color.dim,
                           swatch: .line(Color.ctlTint),
                           delta: delta(s, p, { $0.ctl }, upIsGood: true))
                MetricDivider()
                // Fatigue is the one metric whose wanted direction is DOWN, so
                // it is the one place this colour convention reads backwards if
                // it is applied by raw sign. Rising fatigue in amber is the
                // deliberate choice: a build week earns amber here and that is
                // correct, because the strip is reporting the state, not
                // grading the plan.
                MetricCell(label: "Fatigue",
                           value: s.isTrustworthy
                               ? (p.map { String(format: "%.0f", $0.atl) } ?? "—") : "—",
                           unit: "ATL", colour: Color.dim,
                           swatch: .line(Color.atlTint),
                           delta: delta(s, p, { $0.atl }, upIsGood: false))
                MetricDivider()
                if s.isTrustworthy, let t = p?.tsb {
                    // The WORD is the label and the acronym is the unit, the
                    // same way round as the other three. The first version had
                    // both — "Fresh · +22 · fresh" — which says it twice and
                    // spends the one line of caption on nothing.
                    MetricCell(label: PMC.freshnessLabel(t),
                               value: String(format: "%+.0f", t),
                               unit: "TSB", colour: Color.dim, swatch: .area,
                               delta: delta(s, p, { $0.tsb }, upIsGood: true))
                } else {
                    MetricCell(label: "Fresh", value: "—", unit: "TSB",
                               colour: Color.dim, swatch: .area)
                }
            }
            if !s.isTrustworthy, let why = s.caveat {
                Text(why).font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle()
    }

    /// `swatch` links the figure to its line on the fitness chart. See
    /// SeriesSwatch for why the mark carries the identity rather than the
    /// numeral. A figure with no line on that chart — Load — passes nil, and
    /// keeps using `colour` to say whether the day was measured.
    /// LOAD HAS NO DELTA, AND THAT IS NOT AN OVERSIGHT.
    /// The other three are averages, so a day-on-day change means something. A
    /// day's TRIMP is one session against another session: Monday rest against
    /// Tuesday intervals is a difference of 90, and it describes the plan rather
    /// than the athlete. A number that large and that meaningless sitting beside
    /// three that matter would be read as though it mattered.

    private var emptyDay: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar").font(.title2).foregroundStyle(Color.dim)
            Text("Nothing planned").font(.headline)
            if let next = store.nextSessionDay(onOrAfter: key), let d = DayKey.date(next) {
                Button("Jump to \(DayKey.pretty(d))") { withAnimation { day = d } }
                    .font(.subheadline.weight(.semibold)).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18).cardStyle()
    }

    // MARK: Race day — the first thing on the screen
    //
    // Top of the tab, above the date stepper, because it is the only number
    // here that is true regardless of which day you are looking at. Stepping
    // back to last Tuesday should not change how far away March is, and when it
    // sat at the bottom it read as a footnote to today rather than the thing
    // every session on this screen is for.
    //
    // Counts down to plan.meta.raceDate, so it stays correct if the race moves.

    private var raceCard: some View {
        VStack(spacing: 6) {
            Text(raceLine)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accent4)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text("Target: Marathon sub 4hr")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)

            Text(store.plan.meta.targetTime + " · " + store.targetPace)
                .font(.caption).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .cardStyle()
    }

    /// Counts DOWN to plan.meta.race_date. The three edge cases are real: the
    /// countdown reaches zero, and then goes negative, and "Race day — −4 days"
    /// on the Thursday after a marathon would be a poor way to be greeted.
    private var raceLine: String {
        guard let d = store.daysToRace() else { return "Race day" }
        if d > 1  { return "Race day — \(d) days" }
        if d == 1 { return "Race day — tomorrow" }
        if d == 0 { return "Race day — today" }
        return "Race day — done"
    }

    // MARK: Monthly review
    //
    // It used to be a permanent card on Progress that said "Available once the
    // first plan week has ended" for the first six weeks of the block. A row
    // that is always present and usually inert teaches you to scroll past the
    // place the real thing will appear. Here it is absent until it is due, and
    // then it is the first thing on the screen.

    @ViewBuilder
    private var reviewBanner: some View {
        // `proposals.records.count` is read so the banner re-evaluates the
        // moment a review is stored — without it the state is computed once and
        // the banner survives the thing that was meant to clear it.
        let _ = proposals.records.count
        let state = ReviewDue.state()
        if state.isDue {
            Button { route = .review } label: {
                HStack(spacing: 11) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.title3).foregroundStyle(Color.accent4).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monthly review is due")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ink)
                        Text(ReviewDue.subtitle(state))
                            .font(.caption).foregroundStyle(Color.dim)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                        .foregroundStyle(Color.dim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardStyle()
            // Through `route`, NOT a second `.sheet` on this screen. The note
            // at the top of this file is not decorative: stacked sheet
            // modifiers here silently fail to present, and which one loses is
            // not something the code tells you.
        }
    }

    private func banner(_ title: String, _ msg: String, _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(colour)
            Text(msg).font(.caption).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
}

// MARK: - Row

struct MatchRow: View {
    let match: Match
    let onOpen: () -> Void
    let onFix: () -> Void
    let onData: () -> Void
    let onFuel: () -> Void
    let onPrep: () -> Void

    private var s: Session { match.session }
    private var done: Bool { match.isDone }

    var body: some View {
        VStack(spacing: 9) {
            plannedPart
            // The plan's own fuelling line, between what was asked and what was
            // recorded — it belongs with the prescription, because it is read
            // before the session, not after it.
            PrepLine(session: s, onOpen: onPrep)
            FuelLine(session: s, onOpen: onFuel)
            if let a = match.activity { recordedPart(a) }
            // The note left this card in patch 104. It is written and read on
            // the activity page now — one place, and only once there is an
            // activity to describe.
        }
        .fixedSize(horizontal: false, vertical: true)
        .cardStyle()
        // THE WHOLE CARD OPENS THE DETAIL PAGE.
        //
        // Fixing the label's content shape above fixes the gap it caused, and
        // leaves every other one: the coloured bar, the tick, the 9pt gaps
        // between rows, the margin below the last line. Enumerating them is a
        // list that gets one entry longer every time a row is added.
        //
        // A tap gesture on the container rather than wrapping the card in a
        // Button: the children ARE buttons, and a Button inside a Button
        // swallows the inner tap. A gesture does not — the child buttons still
        // take their own taps first, and this catches whatever is left, which
        // is precisely the definition of "anywhere else on the card".
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .contextMenu {
            Button("Fix match…", systemImage: "arrow.left.arrow.right") { onFix() }
            if match.activity != nil {
                Button("Activity data…", systemImage: "chart.bar.xaxis") { onData() }
            }
        }
    }

    // MARK: What was planned — tapping opens the session

    private var plannedPart: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(s.tint).frame(width: 5).frame(maxHeight: .infinity)
                .opacity(done ? 0.45 : 1)

            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? s.tint : Color.dim.opacity(0.4))
                .frame(width: 30)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: s.discipline.symbol).font(.caption2)
                        Text(s.kindLabel.uppercased())
                            .font(.caption2.weight(.bold)).tracking(0.5)
                        if !match.auto {
                            Image(systemName: "hand.point.up.left.fill").font(.caption2)
                        }
                    }
                    .foregroundStyle(s.tint.opacity(done ? 0.6 : 1))

                    Text(s.title ?? "—")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(done ? Color.dim : Color.ink)
                        .multilineTextAlignment(.leading)

                    if let d = s.detail, !d.isEmpty {
                        Text(d).font(.subheadline)
                            .foregroundStyle(Color.dim.opacity(done ? 0.7 : 1))
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // WITHOUT THIS, ONLY THE GLYPHS ARE TAPPABLE. The label is
                // stretched to the full width, but a stack's hit area is the
                // union of its children — so the empty space to the right of
                // "Easy" was dead, which is exactly where a thumb lands.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: What was recorded — its own button, opening the activity sheet
    //
    // Deliberately a separate control rather than a nested one: a Button inside
    // a Button swallows the inner tap in SwiftUI, and the two destinations are
    // genuinely different — the plan above, the data below.

    private func recordedPart(_ a: Activity) -> some View {
        Button(action: onData) {
            VStack(alignment: .leading, spacing: 5) {
                Divider().overlay(Color.line)
                HStack(spacing: 8) {
                    Text(String(format: "%.2f km", a.km))
                        .font(.caption.weight(.bold))
                    Text("\(a.minutes) min").font(.caption)
                    if let p = a.paceLabel { Text(p).font(.caption) }
                    if let hr = a.averageHeartrate,
                       AthleteStore.shared.zone(forHR: hr) == nil {
                        Text("\(Int(hr)) bpm").font(.caption)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chart.bar.xaxis").font(.caption2)
                }
                .foregroundStyle(Color.accent4)

                if let hr = a.averageHeartrate,
                   let z = AthleteStore.shared.zone(forHR: hr) {
                    // Named here too since patch 78. It was the last surface
                    // showing a bare "Z2", which is a coordinate you have to
                    // have memorised rather than a thing you can read.
                    ZoneChip(zone: z, bpm: Int(hr), showName: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
