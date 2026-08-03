//
//  ReviewView.swift
//  Sub4
//
//  The monthly review, on screen.
//
//  Everything here is read from `Review`, which computes it. This file decides
//  nothing — if a number looks wrong, it is wrong in Review.swift.
//
//  ORDER IS THE ARGUMENT
//  ---------------------
//  Coverage first, flags second, detail third. That order is deliberate and it
//  is the opposite of what a dashboard usually does. A review that opens with
//  "adherence 92%" invites you to act on it; opening with "31% of sessions have
//  a note" tells you the 92% is describing a third of the block. The honest
//  reading order is: can I trust this, then what does it say, then why.
//
//  The share button emits the Markdown evidence pack — the same string that
//  would be sent to a model if that step is ever built. Reading it yourself
//  first is the cheapest way to find out whether the analysis is worth
//  automating at all.
//

import SwiftUI

struct ReviewView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var weeksBack = 4
    @State private var share: ShareItem?
    @State private var shareFailed = false

    // Computed once per window, NOT in a computed property read from the body.
    //
    // ReviewBuilder.build runs the matcher over every day in the window. As a
    // computed property that whole pass re-ran on every re-render — including
    // every tap of the segmented picker, and every time the share sheet
    // appeared. At the 12-week setting that is a few hundred day-matches for a
    // result that cannot have changed.
    @State private var review: Review?
    @State private var built = false

    @State private var proposals = ProposalStore.shared
    @State private var running = false
    @State private var runError: String?
    @State private var opened: ProposalStore.Record?

    /// The review and payload waiting on the preflight screen.
    ///
    /// A value rather than a Bool, so the screen cannot be shown without the
    /// exact payload that would be sent — the two are the same object.
    struct Preflight: Identifiable {
        let id = UUID()
        let review: Review
        let payload: ReviewPayload
    }
    @State private var preflight: Preflight?

    var body: some View {
        NavigationStack {
            ScrollView {
                if !built {
                    ProgressView().padding(40).frame(maxWidth: .infinity)
                } else if let r = review {
                    VStack(alignment: .leading, spacing: 10) {
                        windowPicker
                        coverageCard(r)
                        ForEach(r.flags) { flagCard($0) }
                        adherenceCard(r)
                        volumeCard(r)
                        effortCard(r)
                        if !r.paces.isEmpty { paceCard(r) }
                        // Grouped: a ViewBuilder block tops out at ten children
                        // and this VStack had reached exactly ten. The eleventh
                        // card would fail with an opaque "extra argument in
                        // call" rather than anything that names the real limit.
                        Group {
                            askCard(r)
                            if !proposals.records.isEmpty { historyCard }
                        }
                        shareCard(r)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                } else {
                    empty
                }
            }
            .background(Color.bg)
            .task(id: weeksBack) {
                review = ReviewBuilder.build(weeksBack: weeksBack)
                built = true
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .sheet(item: $opened) { ProposalView(record: $0) }
            // A THIRD sheet on this view. Patch 185's lesson was about a
            // `.confirmationDialog` competing with sheets on a Section, not
            // about sheets on a container — and the two above have worked here
            // for many patches. If this one misbehaves, the fix is to collapse
            // all three into one enum-driven `.sheet(item:)`, as
            // DataControlsView did, rather than to reorder them.
            .sheet(item: $preflight) { p in
                ReviewPreflightView(payload: p.payload) { configured in
                    Task { await send(review: p.review, payload: configured) }
                }
            }
            .alert("Could not write the file", isPresented: $shareFailed) {
                Button("OK", role: .cancel) {}
            }
            // A real two-way binding, not `.constant(runError != nil)`. With a
            // constant binding SwiftUI's own write of `false` is discarded, so
            // the alert has no way to dismiss itself — it only worked because
            // the OK action happened to clear the error, and any other
            // dismissal route would re-present it immediately.
            .alert("Review failed",
                   isPresented: Binding(get: { runError != nil },
                                        set: { if !$0 { runError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(runError ?? "")
            }
        }
        .tint(.accent4)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.largeTitle).foregroundStyle(Color.dim)
            Text("No finished weeks yet").font(.headline)
            Text("The review covers plan weeks that have ended. Come back "
                 + "after the first one closes.")
                .font(.subheadline).foregroundStyle(Color.dim)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }

    // MARK: Window

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WINDOW").font(.caption2.weight(.bold))
                .tracking(0.5).foregroundStyle(Color.dim)
            Picker("Window", selection: $weeksBack) {
                Text("4 weeks").tag(4)
                Text("8 weeks").tag(8)
                Text("12 weeks").tag(12)
            }
            .pickerStyle(.segmented)
            Text("Only weeks that have finished. A week still running would "
                 + "count its unstarted sessions as missed.")
                .font(.caption2).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Coverage — first, on purpose

    private func coverageCard(_ r: Review) -> some View {
        let c = r.coverage
        let thin = c.noteShare < Review.Thresholds.noteCoverageFloor
        // Hoisted: a ternary of concatenated strings inside Text() is the exact
        // shape that stalls the type checker — Text has a dozen overloads and
        // `+` is among the most overloaded operators in the stdlib.
        let verdict: String = thin
            ? "Thin. The effort figures below describe the sessions you chose "
              + "to write about, not the block."
            : "Enough notes for the effort figures to mean something."
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(r.window.label).font(.headline)
                Spacer()
                Text("\(r.window.startDay) → \(r.window.endDay)")
                    .font(.caption2).foregroundStyle(Color.dim)
            }

            HStack(spacing: 0) {
                coverageStat("\(c.sessions)", "sessions", .dim)
                coverageStat(pct(c.matchShare), "recorded",
                             c.matchShare < 0.8 ? .orange : .accent4)
                coverageStat(pct(c.noteShare), "noted",
                             thin ? .orange : .accent4)
            }

            Text(verdict).font(.caption).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func coverageStat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Flags

    private func flagCard(_ f: Review.Flag) -> some View {
        let tint = colour(f.level)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: symbol(f.level)).font(.caption)
                Text(f.title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(tint)
            Text(f.detail).font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tint)
                .frame(width: 3).padding(.vertical, 10).padding(.leading, 1)
        }
    }

    private func colour(_ l: Review.Flag.Level) -> Color {
        switch l {
        case .blocking: Color.dangerColor
        case .warning:  Color.accent4
        case .note:     Discipline.run.tint
        }
    }

    private func symbol(_ l: Review.Flag.Level) -> String {
        switch l {
        case .blocking: "exclamationmark.octagon.fill"
        case .warning:  "exclamationmark.triangle.fill"
        case .note:     "info.circle.fill"
        }
    }

    // MARK: Adherence

    private func adherenceCard(_ r: Review) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Adherence").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(r.sessionsDone)/\(r.sessionsTotal) · \(pct(r.adherence))")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(r.adherence < Review.Thresholds.adherenceFloor
                                     ? .orange : Color.accent4)
            }
            ForEach(r.disciplines) { d in
                HStack(spacing: 9) {
                    Image(systemName: d.discipline.symbol)
                        .font(.caption2).foregroundStyle(d.discipline.tint)
                        .frame(width: 16)
                    Text(d.discipline.label).font(.caption)
                    Spacer()
                    Text("\(d.done)/\(d.planned)")
                        .font(.caption.monospacedDigit()).foregroundStyle(Color.dim)
                    bar(d.share, d.discipline.tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func bar(_ share: Double, _ tint: Color) -> some View {
        // slug 0: this row prints its figure beside the bar, so a hairline of
        // colour for a near-zero share would restate what the number already
        // says better.
        TrackBar(fraction: share, tint: tint, slug: 0)
            .frame(width: 64)
    }

    // MARK: Volume

    private func volumeCard(_ r: Review) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Running volume").font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f / %.0f km", r.doneKm, r.plannedKm))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.accent4)
            }
            ForEach(r.weeks) { w in
                HStack(spacing: 9) {
                    Text(w.label).font(.caption.monospacedDigit())
                        .foregroundStyle(Color.dim).frame(width: 24, alignment: .leading)
                    Text(String(format: "%.1f km", w.doneKm))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Text(String(format: "%@%.0f planned",
                                w.plannedExact ? "" : "≈", w.plannedKm))
                        .font(.caption2).foregroundStyle(Color.dim)
                    bar(w.plannedKm > 0 ? w.doneKm / w.plannedKm : 0,
                        Discipline.run.tint)
                }
            }
            Text("Planned is derived from the sessions, not the plan's weekly "
                 + "headline — that headline includes the bike commute.")
                .font(.caption2).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Effort

    private func effortCard(_ r: Review) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Effort by session type").font(.subheadline.weight(.semibold))
            ForEach(r.efforts) { e in
                effortRow(e)
            }
            Text("RPE is Borg CR10. Feel is relative to the plan's target, "
                 + "not absolute difficulty.")
                .font(.caption2).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func effortRow(_ e: Review.EffortRow) -> some View {
        let hot = (e.meanRPE ?? 0) > Review.Thresholds.easyRunRPECeiling
            && e.key.hasPrefix("Run · easy")
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(e.key).font(.caption.weight(.semibold))
                Spacer()
                if let m = e.meanRPE {
                    Text(String(format: "RPE %.1f", m))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(hot ? .orange : Color.accent4)
                } else {
                    Text("no notes").font(.caption2).foregroundStyle(Color.dim)
                }
            }
            HStack(spacing: 6) {
                Text("\(e.noted)/\(e.sessions) noted")
                    .font(.caption2).foregroundStyle(Color.dim)
                Spacer()
                if e.noted > 0 {
                    feelPip(e.easier, "arrow.down.right", Color.dim)
                    feelPip(e.expected, "equal", Color.dim)
                    feelPip(e.harder, "arrow.up.right",
                            e.harderShare > Review.Thresholds.harderShare
                                ? .orange : Color.dim)
                }
            }
        }
    }

    private func feelPip(_ n: Int, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 9))
            Text("\(n)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(n == 0 ? Color.dim.opacity(0.35) : tint)
    }

    // MARK: Pace

    private func paceCard(_ r: Review) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Pace against the plan's bands").font(.subheadline.weight(.semibold))
            ForEach(r.paces) { paceRow($0) }
            Text("Seconds per km from the nearest edge of the stated band. "
                 + "Sessions the plan leaves open are not listed.")
                .font(.caption2).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Factored out for the same reason as `effortRow` and `flagCard`: the
    /// deviation label is a ternary containing an interpolation containing
    /// another ternary, and the colour is a third. Inline, that was the
    /// heaviest single expression in the file.
    private func paceRow(_ p: Review.PaceRow) -> some View {
        let label: String = p.deviation == 0
            ? "on"
            : (p.deviation > 0 ? "+\(p.deviation)" : "\(p.deviation)")
        let tint: Color = p.deviation == 0
            ? Color.accent4
            : (abs(p.deviation) > 10 ? Color.orange : Color.dim)
        return HStack(spacing: 8) {
            Text(String(p.date.suffix(5)))
                .font(.caption2.monospacedDigit()).foregroundStyle(Color.dim)
            Text(p.title).font(.caption).lineLimit(1)
            Spacer()
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    // MARK: Ask Claude
    //
    // Guarded on the blocking flags rather than left available whenever there
    // is a key. Spending a call on a window the app has already decided cannot
    // support a conclusion produces a confident-sounding answer about nothing,
    // and that answer then sits in the history looking like evidence.

    private func askCard(_ r: Review) -> some View {
        let blocked = r.flags.contains { $0.level == .blocking }
        let already = proposals.existing(startDay: r.window.startDay,
                                         endDay: r.window.endDay)
        // Read ONCE. `isConfigured` is a Keychain lookup plus a JSON decode,
        // and this card re-renders on every picker tap and every store change —
        // three calls per render for a value that cannot change mid-render.
        let configured = ClaudeConfig.isConfigured
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.caption)
                Text("Ask for a verdict").font(.subheadline.weight(.semibold))
                Spacer()
                if running { ProgressView() }
            }
            .foregroundStyle(Color.accent4)

            Text(askSubtitle(configured: configured, blocked: blocked,
                             already: already.count))
                .font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                ask()
            } label: {
                Text(already.isEmpty ? "Run the review" : "Run again")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accent4.opacity(0.18))
                    .foregroundStyle(Color.accent4)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(running || blocked || !configured)
            .opacity(running || blocked || !configured ? 0.45 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func askSubtitle(configured: Bool, blocked: Bool,
                             already: Int) -> String {
        if !configured {
            return "Needs a Claude API key — Settings → Claude API key. "
                 + "Billed separately from a Claude subscription; a review "
                 + "costs a few cents."
        }
        if blocked {
            return "Held back: the flags above say this window cannot support "
                 + "a conclusion. Asking anyway would produce a confident "
                 + "answer about nothing."
        }
        if already > 0 {
            return "This window has already been reviewed \(already) "
                 + (already == 1 ? "time" : "times") + ". Running again asks "
                 + "the same question of the same data — useful for seeing how "
                 + "stable the answer is, and for nothing else."
        }
        return "Sends the figures above — not the raw data — and asks whether "
             + "the block is landing correctly. Nothing is applied: the "
             + "verdict is something you read."
    }

    /// Builds the payload and opens the preflight. Sends nothing, and is no
    /// longer `async` — patch 192. Nothing here suspends, and an async function
    /// that never awaits invites a spinner that flashes for one frame.
    private func ask() {
        do {
            let (review, payload) = try ReviewRunner.prepare(weeksBack: weeksBack)
            preflight = Preflight(review: review, payload: payload)
        } catch {
            runError = error.localizedDescription
        }
    }

    /// The only path that transmits. Reached from the preflight screen's Send
    /// button and from nowhere else, with the payload the athlete just read.
    private func send(review: Review, payload: ReviewPayload) async {
        running = true
        defer { running = false }
        do {
            opened = try await ReviewRunner.run(review: review, payload: payload)
        } catch {
            guard !error.isCancellation else { return }
            runError = error.localizedDescription
        }
    }

    // MARK: History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Previous reviews").font(.subheadline.weight(.semibold))
            ForEach(proposals.newestFirst) { rec in
                Button { opened = rec } label: {
                    HStack(spacing: 9) {
                        Text(rec.windowLabel)
                            .font(.caption.weight(.semibold))
                            .frame(width: 74, alignment: .leading)
                        Text(rec.proposal.verdictLabel)
                            .font(.caption).foregroundStyle(Color.dim)
                            .lineLimit(1)
                        Spacer()
                        Text("\(rec.proposal.confidence)/5")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.dim)
                        Image(systemName: "chevron.right").font(.caption2)
                            .foregroundStyle(Color.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Kept so the sequence can be read. One verdict is an opinion; "
                 + "six that disagree with each other is a finding about the "
                 + "reviewer, not the plan.")
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Share

    private func shareCard(_ r: Review) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = r.writeMarkdown() {
                    share = ShareItem(url: url)
                } else {
                    shareFailed = true
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.up").font(.caption)
                    Text("Export this review").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(Color.accent4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Markdown: every figure above, the raw notes, and the "
                 + "thresholds the flags fired on. This is the evidence pack — "
                 + "readable on its own, and the exact input a model would get "
                 + "if that step is ever added.")
                .font(.caption2).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}
