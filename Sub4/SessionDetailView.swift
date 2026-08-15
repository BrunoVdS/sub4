//
//  SessionDetailView.swift
//  Sub4
//
//  Full swim or strength session. Both share the identical
//  {total, tag, focus, blocks:[{d,t,x,u}]} shape, so one view covers both.
//
//  Completion is shown, never set — it comes from the matched Strava activity.
//  The note is the one thing on this screen you write yourself: two numbers and
//  a paragraph about how the session actually went. See NotesStore.
//

import SwiftUI

struct SessionDetailView: View {
    let session: Session

    /// Parsed ONCE, at init.
    ///
    /// `WorkoutParser.parse` runs half a dozen regexes over the session text,
    /// and the session card reads it from eight different computed properties.
    /// As a computed property that is eight full parses per body pass, on a
    /// view that redraws whenever the matcher or the notes store changes. The
    /// session is a `let`, so the parse can never go stale.
    private let parsed: (workout: PlanWorkout?, reason: String?)

    init(session: Session) {
        self.session = session
        self.parsed = WorkoutParser.parse(session)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var matcher = Matcher.shared
    // One sheet, one enum. This view previously stacked four `.sheet`
    // modifiers, and SwiftUI presents one sheet per view — with several
    // stacked, which ones actually work is not something you can read off the
    // code. It happened to work here because the note sheet was written last
    // and ended up outermost; Today had the same four plus settings and the
    // note was buried in the middle, which is why notes could be written from
    // Week and not from Today.
    private enum Route: Identifiable {
        case picker
        case activity(Activity)
        case workout
        case fuel(ladder: Bool, raceDay: Bool)
        case warmup

        var id: String {
            switch self {
            case .picker:          "picker"
            case .activity(let a): "activity-\(a.id)"
            case .workout:         "workout"
            case .fuel(let l, let r): "fuel-\(l)-\(r)"
            case .warmup:         "warmup"
            }
        }
    }

    @State private var route: Route?

    private var match: Match? {
        guard let d = session.date else { return nil }
        return matcher.day(d).matches.first { $0.session.uid == session.uid }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    intro
                    // Directly under the title. "What am I doing today" is the
                    // question this screen is opened to answer, and it used to
                    // be answered last, below the watch link, in a card that
                    // shrank to the width of its own text.
                    sessionCard
                    prepCard
                    fuelCard
                    completion
                    // The note left this page in patch 104. A note records how a
                    // session WENT, and this view is now only ever shown for a
                    // session that has NOT been matched to an activity — the one
                    // case where there is nothing yet to describe. It lives on
                    // the activity page instead.
                    workoutLink

                    // Swim and strength carry a real structure from the plan;
                    // those are unchanged. Only the raw-text fallback moved
                    // into `sessionCard` above.
                    if let blocks = session.breakdown?.blocks {
                        ForEach(blocks) { BlockRow(block: $0, tint: session.tint) }
                    }

                    if session.discipline == .strength { hevyNote }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(session.kindLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(session.tint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $route) { r in
                switch r {
                case .picker:
                    if let d = session.date {
                        MatchPickerView(session: session, dayKey: d)
                    }
                case .activity(let a): ActivityDetailView(activity: a)
                case .workout:         WorkoutPreviewView(session: session)
                        case .fuel(let l, let r):
                    // Race day is a DESTINATION, not a sheet stacked on the
                    // fuelling reference. Branching here is what stops the
                    // "Fuelling opens, then Race day opens on top" flash.
                    if r { RaceDayView() } else { FuelView(scrollToLadder: l) }
                case .warmup:          WarmupView()
                }
            }
        }
        .tint(.accent4)
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title ?? "—").font(.title3.weight(.bold))

            HStack(spacing: 8) {
                if let t = session.breakdown?.total { Chip(text: t, tint: session.tint) }
                if let day = session.day { Chip(text: day, tint: .dim) }
            }

            if let tag = session.breakdown?.tag, !tag.isEmpty {
                Text(tag).font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.tint)
            }
            if let focus = session.breakdown?.focus, !focus.isEmpty {
                Text(focus).font(.subheadline).foregroundStyle(Color.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: The session
    //
    // WHAT THIS CARD IS ALLOWED TO SAY
    // --------------------------------
    // The plan's own words, the parser's reading of them, and arithmetic on
    // the two. Nothing else. It states a duration because distance ÷ pace is
    // division, and it states the gap to marathon pace because that is a
    // subtraction against a figure the plan itself sets. It does not say how
    // the session should feel or what to do if it goes wrong — that would be
    // training advice this app invented, wearing the same typeface as the
    // plan's instructions.
    //
    // The raw line stays at the bottom of the card. A parser can be wrong, and
    // that one monospaced row is the only way anyone would ever notice.

    /// Moved to `PlanSessionCards.swift` in patch 104 so the activity page can
    /// draw the same card. Two hundred lines of "what the plan asked for" cannot
    /// live as private members of one of the two views that needs them.
    private var sessionCard: some View { PlanSessionCard(session: session) }

    // MARK: Completion — read-only, from Strava

    @ViewBuilder
    private var completion: some View {
        if let a = match?.activity {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Completed").font(.subheadline.weight(.semibold))
                    if match?.auto == false {
                        Text("· manual match").font(.caption)
                    }
                    Spacer()
                    Button("Change") { route = .picker }
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(session.tint)

                Text(a.name).font(.subheadline).foregroundStyle(Color.ink)

                HStack(spacing: 12) {
                    stat(String(format: "%.2f", a.km), "km")
                    stat("\(a.minutes)", "min")
                    if let p = a.paceLabel { stat(p, "") }
                    if let hr = a.averageHeartrate,
                       AthleteStore.shared.zone(forHR: hr) == nil {
                        stat("\(Int(hr))", "bpm")
                    }
                }

                if let hr = a.averageHeartrate,
                   let z = AthleteStore.shared.zone(forHR: hr) {
                    HStack(spacing: 8) {
                        ZoneChip(zone: z, bpm: Int(hr), showName: true)
                        Text("avg · zone \(z.range) bpm")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                }

                if let shoe = AthleteStore.shared.shoe(id: a.gearId) {
                    HStack(spacing: 5) {
                        Image(systemName: "shoe.2").font(.caption2)
                        Text(shoe.name).font(.caption2)
                        Text("· \(Int(shoe.km)) km").font(.caption2)
                    }
                    .foregroundStyle(Color.dim)
                }

                Button { route = .activity(a) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.xaxis")
                        Text("Splits, route and heart rate")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(Color.accent4)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        } else if session.isRest {
            Label("Rest day", systemImage: "moon.zzz.fill")
                .font(.subheadline).foregroundStyle(Color.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
        } else {
            // PATCH 368. "Not recorded yet" was a FALSE STATEMENT about a
            // session you had marked skipped — you recorded it, and this said
            // nobody had. The control and its reason are both unconditional:
            // §12.54.2, the surface the card's context menu leans on.
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    // RED, and through the shared symbol — 368a. See
                    // `SkipStanding.symbol`: this was one of three copies.
                    Label(skip.isSkipped ? "You did not do this" : "Not recorded yet",
                          systemImage: SkipStanding.symbol(isDone: false,
                                                           isSkipped: skip.isSkipped))
                        .font(.subheadline)
                        .foregroundStyle(skip.isSkipped ? Color.red : Color.dim)
                    Spacer()
                    Button("Match…") { route = .picker }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accent4)
                }
                // **THE COLOUR IS CONDITIONAL, AND 368 GOT THIS WRONG.**
                //
                // An explicit `foregroundStyle` OVERRIDES the styling
                // `.disabled` would apply, so this button read in full accent
                // on a session whose day has not passed and did nothing when
                // tapped. "Back to its planned day" in the Fix match sheet
                // greys correctly precisely because it sets no colour.
                //
                // A control that looks live and silently does nothing is worse
                // than one that is absent — §12.54.2 inside out, and the reason
                // the row is rendered in every state at all.
                Button(skip.action) { toggleSkip() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(skip.isOffered ? Color.accent4 : Color.dim)
                    .disabled(!skip.isOffered)
                Text(skip.line).font(.caption2).foregroundStyle(Color.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    /// Whether this session can be marked skipped, and whether it is — 368.
    ///
    /// `session.date` is the EFFECTIVE day, so a session moved onto a past day
    /// becomes skippable and one moved into the future stops being.
    private var skip: SkipStanding {
        SkipStanding.of(isRest: session.isRest,
                        day: session.date,
                        today: DayKey.key(),
                        isDone: matcher.isComplete(session, on: session.date ?? ""),
                        decision: matcher.decisions[session.uid])
    }

    /// See `TodayView.toggleSkip` — neither call can fail, and §12.19 says why
    /// that is a disclosed gap rather than an omission here.
    private func toggleSkip() {
        if skip.isSkipped {
            matcher.clearOverride(sessionUid: session.uid)
        } else {
            matcher.setOverride(sessionUid: session.uid, activityId: nil)
        }
    }

    // MARK: Fuelling
    //
    // Directly under the prescription, because it IS part of the prescription —
    // the plan wrote a fuelling line for 180 of its 260 sessions and it sat
    // unread in the HTML for months. Above completion, because you read it
    // before the session, not after it.

    @ViewBuilder
    private var fuelCard: some View {
        if let f = session.fuel, !f.isEmpty {
            let pointer = session.fuelPointsAtLadder || session.fuelPointsAtRaceDay
            let quiet = session.fuelIsWaterOnly
            Button {
                route = .fuel(ladder: session.fuelPointsAtLadder,
                              raceDay: session.fuelPointsAtRaceDay)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: quiet ? "drop" : "bolt.fill").font(.caption)
                        Text("FUEL").font(.caption2.weight(.bold)).tracking(0.5)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(quiet ? Color.dim : Color.accent4)

                    Text(f).font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(pointer
                         ? "Tap for the ladder and the full fuelling reference."
                         : "Tap for products, per-session targets and the ladder.")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardStyle()
        }
    }

    // MARK: Rehearsal
    //
    // Three sessions in the plan carry this. It is deliberately loud on those
    // three and absent everywhere else — "nothing new on the day" only works if
    // the rehearsal is impossible to miss when it comes round.

    @ViewBuilder
    private var prepCard: some View {
        // Trimmed, matching linksToWarmup — otherwise a whitespace-only
        // prep would render an empty card with a label on it.
        if let p = session.prep?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            let raceDay = session.prepIsRaceDay
            let tint: Color = raceDay
                ? Color.accent4
                : Color.longRunTint
            Button { route = .warmup } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: raceDay
                              ? "figure.run" : "arrow.trianglehead.clockwise")
                            .font(.caption)
                        Text(session.prepLabel)
                            .font(.caption2.weight(.bold)).tracking(0.5)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(tint)

                    Text(p).font(.subheadline).foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Tap for the full countdown, the mobility circuit and "
                         + "what changes by conditions.")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardStyle()
        }
    }

    // MARK: Note — the one thing here you write yourself
    //
    // Sits directly under completion because that is the boundary between what
    // happened and what was asked for, and because a note is written in the
    // minutes after a session, when this screen is already open.
    //
    // Rest days can carry a note too. "Rested because the calf was still sore"
    // is exactly the kind of entry the monthly review needs, and hiding the
    // control on rest days would lose it.

    /// Runs only — the plan states no structure for anything else, and
    /// WorkoutKit can't build custom swim workouts at all.
    @ViewBuilder
    private var workoutLink: some View {
        if session.discipline == .run {
            Button { route = .workout } label: {
                HStack(spacing: 10) {
                    Image(systemName: parsed.workout != nil
                          ? "applewatch.watchface" : "hand.raised")
                    VStack(alignment: .leading, spacing: 2) {
                        // "Send to the watch", not "Structured workout". The
                        // card above now states the session, so this row's only
                        // remaining job is the action — and it is a button.
                        Text(parsed.workout != nil ? "Send to the watch"
                                                   : "No structure — run on feel")
                            .font(.subheadline.weight(.semibold))
                        Text(parsed.workout.map { summary($0) }
                             ?? (parsed.reason ?? ""))
                            .font(.caption).foregroundStyle(Color.dim)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption2)
                        .foregroundStyle(Color.dim)
                }
                .foregroundStyle(parsed.workout != nil ? session.tint : Color.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            }
            .buttonStyle(.plain)
        }
    }

    /// Must agree with the preview sheet. It read `steps.count` while the
    /// preview reads `legCount`, so the same session said "2 steps" here and
    /// "9" one tap away.
    private func summary(_ w: PlanWorkout) -> String {
        var parts = ["\(w.legCount) step\(w.legCount == 1 ? "" : "s")"]
        if let km = w.totalKm {
            parts.append(String(format: "%g km", (km * 10).rounded() / 10))
        }
        if w.shape != .steady { parts.append(w.shape.rawValue.lowercased()) }
        return parts.joined(separator: " · ")
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.callout.weight(.bold)).foregroundStyle(Color.accent4)
            if !unit.isEmpty {
                Text(unit).font(.caption2).foregroundStyle(Color.dim)
            }
        }
    }

    private var hevyNote: some View {
        Text("Strength arrives from Hevy via Strava. Hevy's sync is per-workout — "
             + "toggle it on the save screen, or the session won't appear here.")
            .font(.caption)
            .foregroundStyle(Color.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - Block

struct BlockRow: View {
    let block: Block
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let d = block.d, !d.isEmpty {
                    Text(d)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tint.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(block.t ?? "").font(.body.weight(.semibold))
                Spacer(minLength: 0)
            }

            if let x = block.x, !x.isEmpty {
                Text(x).font(.subheadline).foregroundStyle(Color.dim)
            }

            if let url = block.videoURL {
                Link(destination: url) {
                    Label("Video", systemImage: "play.rectangle.fill")
                        .font(.caption.weight(.semibold))
                }
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Chip

struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
    }
}
