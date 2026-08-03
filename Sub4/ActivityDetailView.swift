//
//  ActivityDetailView.swift
//  Sub4
//
//  The per-activity sheet. Opens from Today, Week and Plan wherever a session
//  shows as done, and from any row in the extra-movement lists.
//
//  Three layouts, because three disciplines ask different questions:
//
//   • RUN   — did I hit the pace the plan asked for? Splits, target verdict,
//             best efforts, shoe.
//   • RIDE  — how hard and how far? Speed, elevation, power. No pace verdict:
//             the plan gives rides no numeric target, so inventing one would be
//             dishonest.
//   • SWIM  — distance and pace per 100 m, laps as intervals. Again no target.
//
//  Everything here reads from the cache DetailStore filled during sync. If a
//  sheet is opened before the backfill reached that activity, it jumps the
//  queue — one request — rather than showing an empty screen.
//

import SwiftUI
import Foundation
import Charts

/// Small identifiable carriers, so every ForEach here has a real element type.
/// ForEach over raw tuples compiles, but it's the first thing to break when a
/// row gains a field.
struct HeroMetric: Identifiable {
    let id: Int
    let label: String
    let value: String
    let unit: String
}

struct FactRow: Identifiable {
    let id: String
    let value: String
}

struct HRPoint: Identifiable {
    let id: Int
    let bpm: Double
}

struct ActivityDetailView: View {

    let activity: Activity

    @Environment(\.dismiss) var dismiss
    @State var store = DetailStore.shared
    // The matcher and the notes store are observed rather than read once: the
    // note card and the match row both have to redraw when they change, and
    // this view is now where both are edited.
    @State var matcher = Matcher.shared
    @State var notes = NotesStore.shared

    /// ONE sheet, one enum. The trap SessionDetailView documents at length —
    /// stacked `.sheet` modifiers present one of them and you cannot read which
    /// off the code — applies here the moment this view gained a second.
    enum Route: Identifiable {
        case note(Session)
        case picker(Session, String)

        var id: String {
            switch self {
            case .note(let s):      "note-\(s.uid)"
            case .picker(let s, _): "picker-\(s.uid)"
            }
        }
    }
    @State var route: Route?
    @State var athlete = AthleteStore.shared

    /// Observed for the zone bars: the histogram lives on the load series, and a
    /// rebuild finishing while this page is open should fill the bars in rather
    /// than leave them absent until the next visit.
    @State var load = LoadStore.shared

    /// Where the finger is on the profile chart, in km. Lives here because two
    /// cards read it: the chart draws its cursor line, the map drops its dot.
    @State var scrubKm: Double?

    /// Which view of the splits is on screen. nil means "whatever this session
    /// should open on" — reps for a session prescribed in minutes, kilometres
    /// for everything else. Once tapped it stays where it was put.
    @State var splitMode: SplitMode?

    /// Everything the interval views need, built once.
    ///
    /// `scrubKm` is @State on this view, so dragging the profile chart
    /// invalidates `body` at frame rate. Each of the interval helpers used to
    /// re-run WorkoutParser over the session text and re-segment 300 bins of
    /// speed — six to eight regex sweeps and up to four segmentations per
    /// frame. Built once per activity instead, and rebuilt only when the detail
    /// or the stream behind it changes.
    struct SplitContext {
        let plan: IntervalPlan?
        let laps: IntervalSplits?
        let reps: IntervalSplits?
    }

    @State var splitCtx: SplitContext?

    /// Which expanded panel is open.
    ///
    /// PRESENTED FROM THE SCROLL VIEW, NOT FROM THE CARD — patch 163, and this
    /// is the actual fix for "the panel vanishes when I turn the phone".
    ///
    /// The tell was "scrolling brings it back". The cards live in a LazyVStack,
    /// which realises rows near the viewport and TEARS DOWN the ones that leave
    /// it. A `.fullScreenCover` attached to a row is attached to something that
    /// can stop existing — and rotating reshapes the viewport, so on a landscape
    /// screen the eighth card is far more likely to fall outside the realised
    /// range. The cover's host goes with it, the content stops rendering, and
    /// scrolling the row back into range brings it straight home.
    ///
    /// It also explains the profile-versus-route split exactly: profile is the
    /// seventh card and route the eighth, so the one nearer the bottom loses
    /// first. Patches 155, 160, 161 and 162 were all tuning variables that were
    /// not the cause — the map's transform, the presentation background, the
    /// orientation source. Every one of them was downstream of a host that had
    /// been deallocated.
    ///
    /// The ScrollView is never torn down, so a cover attached to it cannot be.
    enum PanelSheet: String, Identifiable {
        case profile, route
        var id: String { rawValue }
    }

    @State var panelSheet: PanelSheet?

    /// Observed, not just read once — the conditions row appears mid-screen when
    /// the fetch lands, and without the observation it would stay empty until
    /// something else redrew the page.
    @State var weather = WeatherStore.shared

    var buildSplitContext: SplitContext {
        let p = activity.discipline == .run
            ? session.flatMap { IntervalPlan.from($0) } : nil
        let l = activity.discipline == .run
            ? detail.flatMap { IntervalDetector.fromLaps($0.laps, plan: p) } : nil
        let r = p.flatMap { pp in
            store.streams(for: activity.id)
                .flatMap { IntervalDetector.detect($0, plan: pp) }
        }
        return SplitContext(plan: p, laps: l, reps: r)
    }

    /// Changes exactly when the inputs change, and never during a scrub.
    var splitCtxKey: String {
        let d = detail?.fetched.timeIntervalSince1970 ?? 0
        let s = store.streams(for: activity.id)?.fetched.timeIntervalSince1970 ?? 0
        return "\(activity.id)-\(Int(d))-\(Int(s))"
    }

    var detail: ActivityDetail? { store.detail(for: activity.id) }

    var session: Session? { match?.session }

    var match: Match? {
        matcher.day(activity.dayKey).matches
            .first { $0.activity?.id == activity.id }
    }

    var tint: Color { session?.tint ?? disciplineTint }

    var disciplineTint: Color {
        switch activity.discipline {
        case .bike:     return Discipline.bike.tint
        case .swim:     return Discipline.swim.tint
        case .strength: return .accent4
        case .run:      return Discipline.run.tint
        default:        return .dim
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                let ctx = splitCtx ?? buildSplitContext
                // ORDER, TOP TO BOTTOM (patch 107):
                //
                //   ANSWER      what happened, against what was asked. One card.
                //   YOUR READING the note.
                //   WHERE       splits, then heart rate.
                //   EXPLORE     profile, route, best efforts.
                //   REFERENCE   the fact list.
                //
                // Splits used to sit fifth, below a map and a four-series chart.
                // After a verdict the reader has exactly one question — where did
                // those three seconds go — and the table that answers it was
                // three scrolls down. Route and Profile are exploration: worth
                // having, not worth scrolling past.
                //
                // LAZY, NOT EAGER — and the reorder above is why it now matters.
                //
                // A plain VStack builds every child the moment the page appears.
                // That was tolerable when ROUTE sat third; with it eighth, every
                // activity you open pays for MapKit — a Metal layer, a tile
                // session, a telemetry registration — for a card most opens never
                // scroll to. The four MapKit lines in the Xcode console on
                // opening a detail page are exactly that happening.
                //
                // Deferring also covers the profile chart, which resamples a
                // stream, and the splits table, which segments the run.
                //
                // The console noise is a symptom and not the reason: three of
                // those four lines are MapKit registering with a daemon that is
                // unreachable in the simulator, and no change here or anywhere
                // else in this project can silence them. What this fixes is the
                // work, not the logging of it.
                LazyVStack(spacing: 10) {
                    // Name, figures, conditions and verdict are one card since
                    // patch 146 — see the note on `runCard`.
                    runCard(ctx)
                    breakdownCards
                    noteCard
                    splitsCard(ctx)
                    hrCard
                    profileCard
                    mapCard
                    lapsCard
                    effortsCard
                    footerCard
                    pendingNote
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color.bg)
            // On the ScrollView, deliberately — see `PanelSheet`. It is also a
            // different node from the `.sheet` below, so nothing stacks.
            .fullScreenCover(item: $panelSheet) { p in
                switch p {
                case .route:   routePanelScreen
                case .profile: profilePanelScreen
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(activity.discipline?.label ?? activity.sportType)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $route) { r in
                switch r {
                case .note(let s):        NoteEditorView(session: s)
                case .picker(let s, let d): MatchPickerView(session: s, dayKey: d)
                }
            }
        }
        .tint(.accent4)
        .task { await store.prioritise(activity.id) }
        // The weather fetch lives HERE and not next to the row that shows it.
        // `weatherRow` renders nothing until the data exists, so a `.task`
        // attached to it never ran — SwiftUI does not reliably run work hung on
        // a view that produces no node, and the fetch sat waiting for the data
        // it was supposed to get. That was patch 130's bug and the reason this
        // stays on `body`, which is guaranteed to appear.
        .task(id: activity.id) { await WeatherStore.shared.fetchIfNeeded(activity) }
        // Rebuilt when the detail or the stream arrives, and at no other time.
        // Without this the fallback in `body` would re-segment the run on every
        // frame of a scrub.
        .task(id: splitCtxKey) { splitCtx = buildSplitContext }
    }

    var startTime: String {
        String(activity.startLocal.dropFirst(11).prefix(5))    // "09:24"
    }

    // MARK: The run — four cards merged into one
    //
    // WHAT THIS REPLACED, AND WHY
    // ---------------------------
    // Until patch 107 the top of this page was four separate cards: the hero
    // metrics, the verdict, a one-line "Matched to a planned session" row whose
    // only content was a Change button, and THE SESSION. All four answer the
    // same question — what was asked, and did you do it — with three seams
    // between them, and between them they printed the target band four times,
    // the recorded distance three times and the planned distance twice.
    //
    // WHAT SURVIVED UNCHANGED
    // -----------------------
    // The verdict block. A first draft compressed it to a right-aligned
    // "+3 s/km over the bound", which removed a repetition and also removed the
    // only piece of typography on the page doing real work: the pace set large,
    // in the state's own colour, with the target beside it. The SIZE is the
    // verdict. It is inlined here exactly as it was.
    //
    // WHAT THAT FORCES
    // ----------------
    // With the band printed inside the verdict, the plan row must not repeat
    // it. So the plan row carries only what the verdict does not — the distance
    // asked, the intensity, the derived duration, the gap to marathon pace, and
    // the plan's own raw line. See `PlanSessionCard(compact:)`.

    // THREE CARDS BECAME ONE — patch 146.
    //
    // The header, "THE RUN" and "CONDITIONS" were three cards describing one
    // thing: what this session was, and what the weather was while it happened.
    // Nothing separated them except chrome, and the chrome was expensive — two
    // extra headers, four extra sets of card padding and two gaps, about ninety
    // points, which on a 6.9" phone is whether the verdict lands on the first
    // screen.
    //
    // It also said "run" three times in four lines: the title, the discipline
    // chip under it, and the section header. The chip is now the discipline
    // GLYPH, which still marks a session called "Lunch Break" and costs no
    // words; "THE RUN" is gone, because a section header names a section and
    // there is one section.
    //
    // WHAT DID NOT MERGE, DELIBERATELY: the note. It is the only thing on this
    // screen you wrote rather than measured, and it is editable — folding it in
    // would put a tap target inside a block of read-only facts.
    func runCard(_ ctx: SplitContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            heroRow
            weatherRow
            verdictSection(ctx)
            askedSection
            weatherFooter
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Name, when, and the only way to correct the match.
    ///
    /// `.firstTextBaseline` on the glyph and the title, not `.center` — a long
    /// name wraps to two lines and a centred icon would drift to the middle of
    /// them. The button is absent on an extra: a commute has no session to be
    /// matched to.
    var titleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // `extraSymbol`, NOT `discipline.symbol` — patch 147.
                    //
                    // 146 replaced the chip with the discipline glyph and broke
                    // the unplanned case doing it. A kayak is `Discipline.other`
                    // whose symbol is a QUESTION MARK, so dropping the chip that
                    // read "Kayaking" left the session marked by a glyph meaning
                    // "no idea". `extraSymbol` falls through to the discipline
                    // for everything it does not name itself, so a run is still
                    // figure.run and nothing that worked stopped working.
                    Image(systemName: activity.extraSymbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(activity.name).font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(dateLine).font(.caption).foregroundStyle(Color.dim)
            }
            Spacer(minLength: 8)
            if let s = session {
                Button("Change match") { route = .picker(s, activity.dayKey) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accent4)
                    .fixedSize()
            }
        }
    }

    /// "Ride · commute · Saturday 1 August · 09:53", or just the date when the
    /// kind adds nothing.
    ///
    /// THE OTHER HALF OF WHAT THE CHIP WAS CARRYING.
    /// `extraLabel` is the one thing a glyph cannot say: a commute and a
    /// training ride are both `bicycle`, and "Zwift" is not visible in either
    /// the icon or, usually, the name. It is prefixed here rather than restored
    /// as a chip because for a matched session it would print the discipline a
    /// third time, which is what patch 146 set out to stop.
    ///
    /// THE TEST IS WHETHER THE NAME ALREADY SAYS IT, which is the same test
    /// that removed the chip in the first place — just applied per activity
    /// rather than assumed. "Morning Run" contains "Run", "Lunch Walk" contains
    /// "Walk", "Morning Ride" contains "Ride": all suppressed. "Morning Ride"
    /// does NOT contain "Ride · commute", and no name contains "Zwift", so the
    /// two cases where the kind is genuinely news both survive it.
    var dateLine: String {
        let kind = activity.extraLabel
        let out = activity.name.localizedCaseInsensitiveContains(kind) ? "" : "\(kind) · "
        guard let d = DayKey.date(activity.dayKey) else { return out + startTime }
        return out + "\(DayKey.pretty(d)) · \(startTime)"
    }

    var heroRow: some View {
        HStack(spacing: 0) {
            ForEach(heroMetrics) { m in
                if m.id > 0 { MetricDivider(height: 30) }
                heroMetric(m.label, m.value, m.unit)
            }
        }
    }

    // MARK: Conditions
    //
    // A SECOND ROW OF THE SAME FOUR CELLS, not a strip with its own styling.
    // The claim being made is that these are all measured facts about one
    // session, and using the same component with the same dividers and the same
    // spacing makes that claim without a word of chrome.
    //
    // The figures are INK, not the session tint. Colour on this page means "this
    // is what you did"; nobody ran 87% humidity, and the weather happened to you
    // rather than being produced by you.
    //
    // Renders nothing at all until the measurement exists — a row of dashes
    // would be four claims that the app does not know it cannot make yet. The
    // fetch is triggered from `body`, not from here, for the reason documented
    // on that `.task`.
    @ViewBuilder
    var weatherRow: some View {
        if let w = weather.weather(for: activity) {
            HStack(spacing: 0) {
                heroMetric(w.conditionLabel, String(format: "%.0f", w.tempC), "°C",
                           symbol: w.symbolName, colour: Color.ink)
                MetricDivider(height: 30)
                heroMetric("Felt", String(format: "%.0f", w.feelsLikeC), "°C",
                           colour: Color.ink)
                MetricDivider(height: 30)
                heroMetric("Wind", String(format: "%.0f", w.windKmh),
                           "km/h \(w.windFromLabel)", colour: Color.ink)
                MetricDivider(height: 30)
                // THE FOURTH CELL IS WHICHEVER OF THE TWO IS WORTH READING.
                //
                // The old card dropped Rain below 0.1 mm and always printed
                // humidity, which meant a dry run spent a column on "0.0 mm" or
                // lost one entirely. Four columns is the grid; on a wet day rain
                // is the fact, on a dry one it is humidity, and neither day
                // shows a measurement of nothing.
                if w.precipitationMm >= 0.1 {
                    heroMetric("Rain", String(format: "%.1f", w.precipitationMm), "mm",
                               colour: Color.ink)
                } else {
                    heroMetric("Humidity", String(format: "%.0f", w.humidity * 100), "%",
                               colour: Color.ink)
                }
            }
        }
    }

    /// Provenance, at the foot of the card it belongs to.
    ///
    /// The Open-Meteo credit is a licence condition and the Apple Weather mark
    /// is a term of use, so this cannot be dropped for tidiness — but it never
    /// needed a row of its own either. The sample count stays with it because
    /// "the temperature during your run" and "the temperature at the hour your
    /// run started" are different claims, and only one of them is this.
    @ViewBuilder
    var weatherFooter: some View {
        if let w = weather.weather(for: activity) {
            VStack(alignment: .leading, spacing: 3) {
                if let note = w.note {
                    Text(note).font(.system(size: 9)).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    WeatherAttributionView(source: w.provider)
                    Text(w.samples == 1
                         ? "· one hourly reading, the session fitted inside it."
                         : "· mean of \(w.samples) hourly readings across the session.")
                        .font(.system(size: 9)).foregroundStyle(Color.dim)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// A rule, then the verdict. Drawn only when there is one to draw — on an
    /// extra, or a session the plan states no pace for, the card is the hero row
    /// and nothing else.
    @ViewBuilder
    func verdictSection(_ ctx: SplitContext) -> some View {
        if hasVerdict {
            Rectangle().fill(Color.line).frame(height: 1)
            verdictBody(ctx)
        }
    }

    var hasVerdict: Bool {
        guard activity.discipline == .run, let s = session,
              PaceTarget.parse(s) != nil else { return false }
        return true
    }

    /// What the plan asked, minus everything the verdict has already said.
    @ViewBuilder
    var askedSection: some View {
        if let s = session {
            Rectangle().fill(Color.line).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("asked").font(.caption2).foregroundStyle(Color.dim)
                    .frame(width: 42, alignment: .leading)
                PlanSessionCard(session: s, compact: true)
            }
        }
    }

    /// The duration every figure on this page is built from.
    ///
    /// `DataCorrections.scoringSeconds`, not `activity.movingTime`. The fitness
    /// curve and the volume card have scored the 14 June swim over its official
    /// 1:14:46 since patch 122; this page was still printing the watch's 44:00
    /// beside a pace derived from it, so the same session read two different
    /// ways depending on which screen you were on.
    var duration: Int { DataCorrections.scoringSeconds(activity) }

    var heroMetrics: [HeroMetric] {
        var raw: [(String, String, String)]
        switch activity.discipline {
        case .swim:
            raw = [("Distance", String(format: "%.0f", activity.distance), "m"),
                   (durationLabel, Fmt.duration(duration), ""),
                   ("Pace", per100m, "min/100m")]
        case .bike:
            raw = [("Distance", String(format: "%.1f", activity.km), "km"),
                   (durationLabel, Fmt.duration(duration), ""),
                   ("Speed", String(format: "%.1f", speedKmh), "km/h")]
        case .strength, .rest, .other, .none:
            raw = [("Duration", Fmt.duration(duration), ""),
                   (Self.avgHRLabel, activity.averageHeartrate.map { "\(Int($0))" } ?? "—", "bpm"),
                   ("Energy", detail?.calories.map { "\(Int($0))" } ?? "—", "kcal")]
        case .run:
            raw = [("Distance", String(format: "%.2f", activity.km), "km"),
                   (durationLabel, Fmt.duration(duration), ""),
                   ("Pace", paceSecPerKm.map(Fmt.pace) ?? "—", "min/km")]
        }
        // ELEVATION ONLY WHERE IT MEANS SOMETHING
        // ---------------------------------------
        // Added for the three moving sports, and only when the figure exists.
        // A pool swim reports zero climb by definition, and a Hevy circuit has
        // no route at all — printing "0 m" there is a measurement of nothing
        // dressed as one of something.
        if let gain = activity.elevationGain,
           activity.discipline == .run || activity.discipline == .bike {
            raw.append(("Climb", String(format: "%.0f", gain), "m"))
        }
        return raw.enumerated().map {
            HeroMetric(id: $0.offset, label: $0.element.0,
                       value: $0.element.1, unit: $0.element.2)
        }
    }

    /// "Moving" is the watch's word for it. When the figure came from a timing
    /// mat it is not moving time and calling it that would be the one place the
    /// correction lies about itself.
    var durationLabel: String {
        DataCorrections.official(activity) != nil ? "Official" : "Moving"
    }

    var speedKmh: Double {
        guard duration > 0 else { return 0 }
        return activity.km / (Double(duration) / 3600)
    }

    var paceSecPerKm: Int? {
        guard activity.km > 0.05, duration > 0 else { return nil }
        return Int((Double(duration) / activity.km).rounded())
    }

    var per100m: String {
        guard activity.distance > 50 else { return "—" }
        let s = Int((Double(duration) / (activity.distance / 100)).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `symbol` and `colour` exist for the weather row, which uses this same
    /// cell rather than a lookalike — that identity is the whole argument for
    /// putting weather here at all. `colour` defaults to the session tint via
    /// nil rather than a default expression, because a default cannot reference
    /// an instance property.
    func heroMetric(_ label: String, _ value: String, _ unit: String,
                            symbol: String? = nil,
                            colour: Color? = nil) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9))
                        .foregroundStyle(Color.dim)
                }
                Text(label).font(.caption2).foregroundStyle(Color.dim)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                // A fourth metric takes each column to a quarter of the width,
                // and "30:22" at title3 does not fit that on a small phone.
                // Shrinking beats truncating: a slightly smaller figure is
                // still the figure.
                Text(value).font(.title3.weight(.bold))
                    .foregroundStyle(colour ?? tint)
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(Color.dim)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Furniture

    /// Laps first — they are marks, not inference. Detection only if the watch
    /// recorded none, or recorded a count the plan does not recognise.
    func bestIntervals(_ ctx: SplitContext) -> IntervalSplits? {
        if let l = ctx.laps, l.matchesPlan { return l }
        if let r = ctx.reps, r.matchesPlan { return r }
        return ctx.laps ?? ctx.reps
    }

    func timedVerdict(_ target: PaceTarget, _ iv: IntervalSplits,
                              _ mean: Int) -> some View {
        let state = target.state(for: mean)
        let inside = iv.reps.filter {
            $0.paceSecPerKm > 0
                && $0.paceSecPerKm >= target.low - 2
                && $0.paceSecPerKm <= target.high + 2
        }.count
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: state.symbol)
                Text(state.headline).font(.subheadline.weight(.bold))
                Spacer()
                Text(Fmt.pace(mean)).font(.subheadline.weight(.bold))
                    .monospacedDigit()
            }
            .foregroundStyle(state.colour)

            Text("\(iv.count) reps · \(Fmt.duration(iv.workSeconds)) of work at "
                 + "\(Fmt.pace(mean)) /km · target \(target.rangeLabel) · "
                 + "\(inside) of \(iv.count) inside the band")
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)

            Text(iv.source == .laps
                 ? "Measured over the laps the watch recorded — the warm-up, the "
                   + "floats and the cool-down are excluded."
                 : "Measured over the reps found in the pace trace — the warm-up, "
                   + "the floats and the cool-down are excluded.")
                .font(.caption2).foregroundStyle(Color.dim.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func sectionTitle(_ title: String, _ sub: String) -> some View {
        HStack {
            Text(title).font(.caption2.weight(.bold)).tracking(0.5)
            Spacer()
            Text(sub).font(.caption2)
        }
        .foregroundStyle(Color.dim)
    }
}
