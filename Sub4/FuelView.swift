//
//  FuelView.swift
//  Sub4
//
//  The fuelling reference, and the race-day plan.
//
//  Two screens rather than one. Fuelling is something you check the night
//  before a long run; the race-day schema is read once in March and rehearsed
//  twice before that. Putting a 10-row race timeline in the middle of the
//  everyday reference buries the ladder you actually came for.
//
//  Everything shown is the plan's own text, unchanged. Nothing here computes.
//

import SwiftUI

struct FuelView: View {

    /// Opened straight at the ladder when a session's fuel line says "see
    /// ladder" — the whole point of that phrase is that it is a pointer, and
    /// making you find the target yourself wastes it.
    var scrollToLadder = false
    /// True when pushed onto an existing NavigationStack (the Plan tab, or the
    /// race-day screen) rather than presented as a sheet — no second stack, no
    /// Done button.
    var embedded = false
    /// False when this view was itself reached FROM the race-day screen.
    /// Otherwise the two link to each other and you can push Race day →
    /// Fuelling → Race day → … forever.
    var showsRaceDayLink = true

    @Environment(\.dismiss) private var dismiss
    @State private var showRaceDay = false

    private var fuel: Fuel? { PlanStore.shared.fuel }

    var body: some View {
        // Embedded means pushed onto the Plan tab's existing NavigationStack;
        // otherwise it is a sheet and brings its own. Nesting a second stack
        // inside a pushed view gives two navigation bars.
        Group {
            if embedded { content } else { NavigationStack { content } }
        }
        .tint(.accent4)
    }

    // NOTE: this view no longer opens the race-day screen for you.
    //
    // It used to, via `onAppear { showRaceDay = true }`, so a session whose
    // fuel line reads "Full race-day schema" would land here and then have
    // Race day slide up on top half a second later — two sheets deep, with
    // Done peeling back to a screen you never asked for. Wanting to *land* on
    // a different screen is a routing decision, so the caller now picks the
    // destination and this view only ever shows itself.

    @ViewBuilder
    private var content: some View {
        Group {
            ScrollView {
                if let f = fuel {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 10) {
                            if let i = f.intro { introCard(i) }
                            if showsRaceDayLink { raceDayLink }
                            productsCard(f.products)
                            targetsCard(f.perSession)
                            ladderCard(f.ladder).id("ladder")
                            if let r = f.timingRule { ruleCard(r) }
                            if let c = f.caution { cautionCard(c) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                        .onAppear {
                            guard scrollToLadder else { return }
                            // Deferred a runloop turn. onAppear fires before the
                            // ScrollView has laid its content out — especially
                            // inside a sheet — so scrolling immediately does
                            // nothing, which would silently kill the whole
                            // point of the "see ladder" pointer.
                            DispatchQueue.main.async {
                                withAnimation { proxy.scrollTo("ladder", anchor: .top) }
                            }
                        }
                    }
                } else {
                    missing
                }
            }
            .background(Color.bg)
            .navigationTitle("Fuelling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showRaceDay) { RaceDayView() }
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Image(systemName: "drop").font(.largeTitle).foregroundStyle(Color.dim)
            Text("No fuelling data").font(.headline)
            Text("plan.json was built before the extractor read sections 09 "
                 + "and 10. Re-run extract_plan.py and rebuild.")
                .font(.subheadline).foregroundStyle(Color.dim)
                .multilineTextAlignment(.center)
        }
        .padding(30).frame(maxWidth: .infinity)
    }

    // MARK: Cards

    private func introCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline).foregroundStyle(Color.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }

    private var raceDayLink: some View {
        Button { showRaceDay = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "flag.checkered")
                    .font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Race day — eat & drink")
                        .font(.subheadline.weight(.semibold))
                    Text("Carb-load, breakfast, the full during-race timeline")
                        .font(.caption).foregroundStyle(Color.dim)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
                    .foregroundStyle(Color.dim)
            }
            .foregroundStyle(Color.accent4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    private func productsCard(_ products: [Fuel.Product]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Your products")
            ForEach(products) { p in
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name ?? "—").font(.subheadline.weight(.semibold))
                    if let c = p.carbs {
                        Text(c).font(.caption).foregroundStyle(Color.accent4)
                    }
                    HStack(spacing: 6) {
                        if let caf = p.caffeine, caf.lowercased() != "none" {
                            Text("caffeine \(caf)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.dangerColor.opacity(0.18))
                                .foregroundStyle(Color.dangerColor)
                                .clipShape(Capsule())
                        }
                        if let u = p.use {
                            Text(u).font(.caption2).foregroundStyle(Color.dim)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func targetsCard(_ rows: [Fuel.SessionTarget]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("What to take per session")
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.session ?? "—")
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if r.hasTarget {
                            Text(r.target ?? "")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.accent4)
                        }
                    }
                    Text(r.take ?? "")
                        .font(.caption).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func ladderCard(_ steps: [Fuel.LadderStep]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("Long-run fuelling ladder")
            ForEach(steps) { s in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.run ?? "—")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(s.carbs ?? "")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accent4)
                    }
                    Text(s.take ?? "")
                        .font(.caption).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func ruleCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "clock").font(.caption).foregroundStyle(Color.accent4)
            Text(text)
                .font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.caption2.weight(.bold)).tracking(0.5)
            .foregroundStyle(Color.dim)
    }

    // MARK: Caution
    //
    // Its own treatment, in the warning colour, never collapsed and never
    // abbreviated. This is the one item in the whole fuelling section where the
    // consequence of not reading it is not an underfuelled long run.

    private func cautionCard(_ c: Fuel.Caution) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill").font(.caption)
                Text(c.tag ?? "Caution").font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Color.dangerColor)

            Text(c.text ?? "")
                .font(.caption)
                .foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.dangerColor)
                .frame(width: 3).padding(.vertical, 10).padding(.leading, 1)
        }
    }
}

// MARK: - Race day

struct RaceDayView: View {

    @Environment(\.dismiss) private var dismiss

    private var race: Fuel.RaceDay? { PlanStore.shared.fuel?.raceDay }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let r = race {
                    VStack(alignment: .leading, spacing: 10) {
                        countdown
                        warmupLink
                        if let i = r.intro { intro(i) }
                        if !r.before.isEmpty { beforeCard(r.before) }
                        if !r.timeline.isEmpty { timelineCard(r.timeline) }
                        if let t = r.totals { totalsCard(t) }
                        // Grouped: this VStack had reached exactly ten
                        // children, and a ViewBuilder block stops at ten with
                        // an error that names nothing useful.
                        Group {
                            if let h = r.hydration { plainCard("Hydration & salts", h, "drop.fill") }
                            if let p = r.pacing { plainCard("Pacing", p, "speedometer") }
                            if let c = r.caution { caution(c) }
                            fuellingLink
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                } else {
                    Text("No race-day plan in plan.json.")
                        .font(.subheadline).foregroundStyle(Color.dim)
                        .padding(30)
                }
            }
            .background(Color.bg)
            .navigationTitle("Race day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.accent4)
    }

    // The warm-up is the first thing that happens on race morning, so it is
    // the first link on the race-day screen — ahead of the food, which the
    // timeline itself then interleaves with.
    private var warmupLink: some View {
        NavigationLink { WarmupView(embedded: true) } label: {
            HStack(spacing: 11) {
                Image(systemName: "figure.run").font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The warm-up")
                        .font(.subheadline.weight(.semibold))
                    Text("Countdown to the gun, the mobility circuit, "
                         + "and what to do by conditions")
                        .font(.caption).foregroundStyle(Color.dim)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
                    .foregroundStyle(Color.dim)
            }
            .foregroundStyle(Color.accent4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    /// Reaching race day directly from the marathon session used to be a dead
    /// end — no way through to the products or the ladder from here.
    private var fuellingLink: some View {
        NavigationLink {
            FuelView(embedded: true, showsRaceDayLink: false)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "bolt.fill").font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fuelling reference")
                        .font(.subheadline.weight(.semibold))
                    Text("Products, per-session targets and the long-run ladder")
                        .font(.caption).foregroundStyle(Color.dim)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
                    .foregroundStyle(Color.dim)
            }
            .foregroundStyle(Color.accent4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    private var countdown: some View {
        VStack(spacing: 4) {
            if let d = PlanStore.shared.daysToRace(), d > 0 {
                Text("\(d) days out")
                    .font(.title3.weight(.bold)).foregroundStyle(Color.accent4)
            }
            Text(PlanStore.shared.plan.meta.targetTime
                 + " · " + PlanStore.shared.targetPace)
                .font(.caption).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .cardStyle()
    }

    private func intro(_ t: String) -> some View {
        Text(t).font(.subheadline).foregroundStyle(Color.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }

    private func beforeCard(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("BEFORE THE RACE").font(.caption2.weight(.bold))
                .tracking(0.5).foregroundStyle(Color.dim)
            ForEach(items, id: \.self) { s in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(Color.accent4).frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(s).font(.caption).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// The timeline is the one thing here you read while moving, so it is laid
    /// out as a timeline — time on the left, running total on the right — not
    /// as prose you have to scan.
    private func timelineCard(_ steps: [Fuel.RaceDay.Step]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("DURING THE RACE").font(.caption2.weight(.bold))
                .tracking(0.5).foregroundStyle(Color.dim)
            ForEach(steps) { s in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.time ?? "")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Color.accent4)
                        if let d = s.dist, d != "—", !d.isEmpty {
                            Text(d).font(.caption2).foregroundStyle(Color.dim)
                        }
                    }
                    .frame(width: 74, alignment: .leading)

                    Text(s.take ?? "")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(s.total ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func totalsCard(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(Color.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }

    private func plainCard(_ title: String, _ body: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.accent4)
            Text(body).font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func caution(_ c: Fuel.Caution) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill").font(.caption)
                Text(c.tag ?? "On the day").font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Color.dangerColor)
            Text(c.text ?? "").font(.caption).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.dangerColor)
                .frame(width: 3).padding(.vertical, 10).padding(.leading, 1)
        }
    }
}
