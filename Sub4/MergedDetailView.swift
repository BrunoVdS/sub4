//
//  MergedDetailView.swift
//  Sub4
//
//  The detail page for a merged day — patch 177.
//
//  FULLY MERGED, NOT A LIST OF LINKS. The choice was between a parts list
//  that taps through to the individual pages, and one page where everything
//  is joined; the second was chosen. So the profile chart is the day's legs
//  laid end to end on one distance axis, the zone bars are one distribution
//  summed across the legs, and the map draws every leg on one canvas. The
//  parts appear once, as a compact list inside the header — information, not
//  navigation.
//
//  WHY THE DISTANCE AXIS MAKES THE JOIN HONEST. Streams are distance-binned
//  (see ActivityStreams), so concatenation produces a genuinely continuous
//  axis: the hours between a lunch walk and an evening walk occupy no metres
//  and leave no hole to paper over. The one thing that must never be drawn is
//  the straight line between the legs on the MAP — `RouteMapView.segments`
//  and the playback boundary split exist for exactly that.
//
//  WHAT THIS PAGE DELIBERATELY LACKS, against ActivityDetailView: a verdict
//  and an asked section (extras have no session), splits (removed from
//  unplanned pages in patch 148), weather (one reading spanning a day whose
//  legs ran morning to evening would claim a precision it does not have),
//  and the note (notes hang off sessions).
//

import SwiftUI
import CoreLocation

struct MergedDetailView: View {

    let merged: MergedExtra

    @Environment(\.dismiss) private var dismiss
    @State private var store = DetailStore.shared
    /// Observed explicitly rather than relied on implicitly — patch 253.
    /// `Activity.isCommuteRide` reads `CommuteStore.shared` from inside a view
    /// body, which observation tracking does pick up on its own; holding it
    /// here says out loud that this screen redraws when a ride is reclassified,
    /// and matches how every other store on the screen is declared.
    @State private var commutes = CommuteStore.shared

    /// What kind of group this was when the page opened — patch 254.
    ///
    /// Captured rather than computed, and that is the whole point: the parts
    /// carry their commute state live, so a group that opened as three commutes
    /// and has had one taken out would otherwise report itself as "two
    /// commutes and something else" with no memory of having been three. This
    /// is what `partsRemoved` counts against.
    @State private var openedAsCommutes = true
    @State private var athlete = AthleteStore.shared
    @State private var load = LoadStore.shared

    /// One scrub for the page: the profile draws its cursor from it and the
    /// map places its dot — same contract as ActivityDetailView.
    @State private var scrubKm: Double?

    /// The concatenated streams, BUILT ONCE and rebuilt only when a part's
    /// trace lands — the same discipline as `RoutePanel.cachedTrack` (patch
    /// 176). Left as a computed property this would re-concatenate a thousand
    /// samples on every frame of a scrub, because `scrubKm` invalidates the
    /// whole body at drag rate.
    @State private var joined: MergedStreams?

    /// Presented from the ScrollView, never from a card — the LazyVStack
    /// lesson of patch 163 applies to any container that can tear a row down,
    /// and costs nothing to respect here even with an eager VStack.
    private enum PanelSheet: String, Identifiable {
        case profile, route
        var id: String { rawValue }
    }
    @State private var panelSheet: PanelSheet?

    private var parts: [Activity] { merged.parts }

    private var tint: Color {
        switch merged.discipline {
        case .bike: Discipline.bike.tint
        case .run:  Discipline.run.tint
        case .swim: Discipline.swim.tint
        default:    .dim
        }
    }

    /// Changes exactly when a part's trace arrives — the rebuild key for
    /// `joined`, same shape as ActivityDetailView.splitCtxKey.
    private var streamsKey: String {
        parts.map { p in
            String(Int(store.streams(for: p.id)?.fetched.timeIntervalSince1970 ?? 0))
        }
        .joined(separator: "-")
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    headerCard
                    hrCard
                    profileCard
                    mapCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color.bg)
            .fullScreenCover(item: $panelSheet) { p in
                switch p {
                case .route:   routePanelScreen
                case .profile: profilePanelScreen
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(merged.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.accent4)
        // Every part jumps the queue, one at a time — `prioritise` is a
        // single-flight call and awaiting it serially is what keeps this from
        // racing the drain.
        .task {
            for p in parts { await store.prioritise(p.id) }
        }
        .task(id: streamsKey) { joined = merged.joinedStreams(from: store) }
    }

    // MARK: Header — what the day's movement added up to

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: merged.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(merged.title).font(.title3.weight(.bold))
                }
                Text(dateLine).font(.caption).foregroundStyle(Color.dim)
            }
            heroRow
            Rectangle().fill(Color.line).frame(height: 1)
            partsList
            commuteHint
                .onAppear { openedAsCommutes = parts.allSatisfy(\.isCommuteRide) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// "3 walks · Saturday 2 August · 09:12 – 19:45"
    private var dateLine: String {
        var out = merged.countLabel
        if let d = DayKey.date(merged.dayKey) { out += " · " + DayKey.pretty(d) }
        let span = merged.timeSpan
        if !span.isEmpty { out += " · " + span }
        return out
    }

    private var heroRow: some View {
        HStack(spacing: 0) {
            heroMetric("Distance", String(format: "%.1f", merged.km), "km")
            MetricDivider(height: 30)
            heroMetric("Moving", Fmt.duration(merged.movingTime), "")
            MetricDivider(height: 30)
            if merged.discipline == .bike {
                heroMetric("Speed", String(format: "%.1f", speedKmh), "km/h")
            } else {
                heroMetric("Pace",
                           merged.paceSecPerKm.map(Fmt.pace) ?? "—", "min/km")
            }
            if merged.elevationGain > 1 {
                MetricDivider(height: 30)
                heroMetric("Climb",
                           String(format: "%.0f", merged.elevationGain), "m")
            }
        }
    }

    private var speedKmh: Double {
        guard merged.movingTime > 0 else { return 0 }
        return merged.km / (Double(merged.movingTime) / 3600)
    }

    /// The same cell ActivityDetailView draws, restated here because that one
    /// is an instance method of a different view. Kept byte-for-byte in look:
    /// the claim both pages make is "these are measured facts about one
    /// thing", and the claim only holds if the cells are indistinguishable.
    private func heroMetric(_ label: String, _ value: String,
                            _ unit: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(Color.dim)
                .lineLimit(1).minimumScaleFactor(0.75)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.weight(.bold))
                    .foregroundStyle(tint)
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

    /// The legs, as facts. Start time first because it is what distinguishes
    /// them; the Strava name stays because "Lunch Walk" is information the
    /// merged title deliberately gave up.
    ///
    /// PATCH 253 — each leg can be taken out of the group. A day's rides are
    /// not all one thing: two hops to the station and a real ride home arrive
    /// as three files, and the distance rule puts any of them under 10 km into
    /// the commutes. The bicycle at the end of each row is how that is undone,
    /// one ride at a time.
    ///
    /// THE PAGE DOES NOT REARRANGE UNDER YOUR FINGER. A ride taken out of the
    /// commutes stops being part of this group immediately — the list behind
    /// this sheet already shows it separately — but the totals at the top of
    /// this page were computed when it opened and still include it. Recomputing
    /// them live would make a page about three rides silently become a page
    /// about two while being read. The footer says so instead.
    private var partsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parts) { p in
                HStack(spacing: 9) {
                    Text(String(p.startLocal.dropFirst(11).prefix(5)))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Color.dim)
                    Text(p.name).font(.subheadline)
                        .foregroundStyle(Color.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(partMetrics(p))
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(Color.dim)
                    if p.discipline == .bike { commuteToggle(p) }
                }
            }
            if partsRemoved > 0 { removedFooter }
        }
    }

    /// One ride's commute state, as a tap target rather than a switch.
    ///
    /// A switch per row would put three of them down the trailing edge of a
    /// card of one-line facts — the same complaint that made the detail page's
    /// own toggle a single row in patch 252. A filled bicycle is in, an outline
    /// is out, and the footer below says which is which.
    private func commuteToggle(_ p: Activity) -> some View {
        Button {
            CommuteStore.shared.set(!p.isCommuteRide, for: p.id)
        } label: {
            Image(systemName: p.isCommuteRide ? "bicycle.circle.fill" : "bicycle.circle")
                .font(.body)
                .foregroundStyle(p.isCommuteRide ? tint : Color.dim.opacity(0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(p.isCommuteRide ? "Commute" : "Not a commute")
    }

    /// How many legs this page still lists but the group no longer holds.
    private var partsRemoved: Int {
        parts.filter { $0.discipline == .bike && $0.isCommuteRide != openedAsCommutes }.count
    }

    private var removedFooter: some View {
        Text(partsRemoved == 1
             ? "One ride has moved out of this group. The figures above still "
             + "include it — close this page to see the group as it is now."
             : "\(partsRemoved) rides have moved out of this group. The figures "
             + "above still include them — close this page to see the group as "
             + "it is now.")
            .font(.caption2).foregroundStyle(Color.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    /// Shown under the legs when any of them can be taken out, so the bicycle
    /// is explained where it is rather than in a manual.
    @ViewBuilder
    private var commuteHint: some View {
        if merged.discipline == .bike {
            // The sentence has to follow the group — patch 254, when training
            // rides started grouping too. A "Rides" page telling you to take a
            // ride "out of the commutes" would describe the opposite of the tap
            // it is explaining.
            Text(openedAsCommutes
                 ? "Tap a bicycle to take that ride out of the commutes. It "
                 + "counts as training from then on, and can satisfy a planned "
                 + "session."
                 : "Tap a bicycle to mark that ride as a commute. It stops "
                 + "counting towards training volume and can no longer satisfy "
                 + "a planned session.")
                .font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func partMetrics(_ p: Activity) -> String {
        var out: [String] = []
        if p.km >= 0.05 { out.append(String(format: "%.1f km", p.km)) }
        out.append("\(p.minutes) min")
        return out.joined(separator: " · ")
    }

    // MARK: Heart rate — one distribution across the legs

    @ViewBuilder
    private var hrCard: some View {
        let totals = mergedTotals
        if merged.averageHeartrate != nil || totals?.isEmpty == false {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text("HEART RATE").font(.caption2.weight(.bold)).tracking(0.5)
                    InfoButton(topic: .zones)
                    Spacer()
                    Text(hrSummary).font(.caption2)
                }
                .foregroundStyle(Color.dim)

                if let hr = merged.averageHeartrate,
                   let z = athlete.zone(forHR: hr) {
                    ZoneChip(zone: z, bpm: Int(hr), showName: true)
                }

                if let t = totals, !t.isEmpty {
                    let zones = athlete.hrZones
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(zones) { z in
                            zoneRow(z, seconds: t.seconds[z.index] ?? 0,
                                    of: t.totalSeconds)
                        }
                        Text(zoneFootnote(t))
                            .font(.system(size: 9)).foregroundStyle(Color.dim)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    /// Each part's histogram bucketed by `ZoneTotals.build(_:zones:)` — the
    /// single-session rule stated once, in ZoneTime — then summed. Summing
    /// AFTER bucketing keeps this page in exact agreement with what the parts
    /// would each show: same lookup, same edge handling, just added up.
    private var mergedTotals: ZoneTotals? {
        let zones = athlete.hrZones
        let ids = Set(parts.map(\.id))
        let loads = load.day(merged.dayKey)?.workouts
            .filter { ids.contains($0.activityId) } ?? []
        guard !zones.isEmpty, !loads.isEmpty else { return nil }

        var seconds: [Int: Double] = [:]
        var traced = 0, untraced = 0
        var untracedSeconds = 0.0
        var byDiscipline: [Discipline: Int] = [:]
        for w in loads {
            let t = ZoneTotals.build(w, zones: zones)
            for (z, s) in t.seconds { seconds[z, default: 0] += s }
            traced += t.traced
            untraced += t.untraced
            untracedSeconds += t.untracedSeconds
            for (d, n) in t.untracedByDiscipline {
                byDiscipline[d, default: 0] += n
            }
        }
        return ZoneTotals(seconds: seconds, traced: traced, untraced: untraced,
                          untracedSeconds: untracedSeconds,
                          untracedByDiscipline: byDiscipline)
    }

    private func zoneRow(_ z: AthleteStore.HRZone,
                         seconds: Double, of total: Double) -> some View {
        let f = total > 0 ? seconds / total : 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(z.titled).font(.caption2).foregroundStyle(Color.dim)
                Spacer(minLength: 4)
                Text(seconds >= 1 ? Fmt.duration(Int(seconds.rounded())) : "—")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(seconds >= 1 ? Color.ink : Color.dim)
            }
            TrackBar(fraction: f, tint: z.color)
        }
    }

    private func zoneFootnote(_ t: ZoneTotals) -> String {
        var out = Fmt.duration(Int(t.totalSeconds.rounded())) + " traced"
        if t.traced < parts.count {
            out += " across \(t.traced) of \(parts.count) parts"
        } else {
            out += " across all \(parts.count) parts"
        }
        out += " — time below the moving threshold is not counted."
        return out
    }

    private var hrSummary: String {
        var p: [String] = []
        if let a = merged.averageHeartrate { p.append("avg \(Int(a))") }
        if let m = parts.compactMap(\.maxHeartrate).max() { p.append("max \(Int(m))") }
        return p.joined(separator: " · ")
    }

    // MARK: Profile — the legs end to end

    @ViewBuilder
    private var profileCard: some View {
        if let j = joined, j.streams.isUsable {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("PROFILE", profileSubtitle(j))
                StreamChartView(streams: j.streams,
                                discipline: merged.discipline,
                                tint: tint,
                                selectedKm: $scrubKm)
            }
            .cardStyle()
            .contentShape(Rectangle())
            .onTapGesture { panelSheet = .profile }
        }
    }

    /// "12.4 km · 3 parts, end to end" — and when a trace is still missing,
    /// the shortfall is SAID rather than left to be noticed: a profile
    /// covering two of three legs looks exactly like one covering all three.
    private func profileSubtitle(_ j: MergedStreams) -> String {
        let km = String(format: "%.1f km", j.streams.totalKm)
        return j.included < parts.count
            ? km + " · \(j.included) of \(parts.count) parts"
            : km + " · \(parts.count) parts, end to end"
    }

    // MARK: Map — every leg on one canvas

    /// Per-part polylines from the cached details. The card draws these
    /// rather than the stream coordinates for the same reason the single
    /// page does — the polyline is the higher-fidelity line.
    private var routeSegments: [[CLLocationCoordinate2D]] {
        parts.compactMap { store.detail(for: $0.id) }
            .filter(\.hasRoute)
            .map(\.coordinates)
    }

    @ViewBuilder
    private var mapCard: some View {
        let segs = routeSegments
        if !segs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("ROUTE", segs.count < parts.count
                             ? "\(segs.count) of \(parts.count) parts"
                             : "all \(parts.count) parts")
                RouteMapView(coordinates: segs.flatMap { $0 },
                             tint: tint,
                             highlight: routeHighlight,
                             segments: segs)
                HStack(spacing: 14) {
                    RouteKey()
                    if let h = routeHighlight {
                        LegendItem(.dot(Color.dangerColor), h.label)
                    }
                    Spacer(minLength: 0)
                }
            }
            .cardStyle()
            .contentShape(Rectangle())
            .onTapGesture { panelSheet = .route }
        }
    }

    private var routeHighlight: RouteHighlight? {
        guard let km = scrubKm,
              let s = joined?.streams,
              let c = s.coordinate(atKm: km) else { return nil }
        return RouteHighlight(coordinate: c,
                              label: String(format: "%.2f km", km))
    }

    // MARK: Panels

    /// Device-following, like every map full screen — see ActivityDetailRoute.
    /// Playback runs across the joined streams: the marker jumps from one
    /// leg's finish to the next leg's start, because no metres separate them
    /// on the distance axis, and the travelled line splits at the same
    /// boundaries so the jump is never painted as a path.
    @ViewBuilder
    private var routePanelScreen: some View {
        let segs = routeSegments
        if !segs.isEmpty {
            RouteFullScreen(coordinates: segs.flatMap { $0 },
                            streams: joined?.streams,
                            movingSeconds: joined?.movingSeconds ?? merged.movingTime,
                            tint: tint,
                            discipline: merged.discipline,
                            restingHighlight: routeHighlight,
                            title: merged.title,
                            segments: segs,
                            segmentBoundaries: joined?.boundaries ?? [])
        }
    }

    @ViewBuilder
    private var profilePanelScreen: some View {
        if let j = joined, j.streams.isUsable {
            RotatedScreen(panels: [
                ExpandedPanel("profile", "Profile") {
                    StreamChartView(streams: j.streams,
                                    discipline: merged.discipline,
                                    tint: tint,
                                    selectedKm: $scrubKm,
                                    expanded: true)
                }
            ])
        }
    }

    // MARK: Furniture

    private func sectionTitle(_ title: String, _ sub: String) -> some View {
        HStack {
            Text(title).font(.caption2.weight(.bold)).tracking(0.5)
            Spacer()
            Text(sub).font(.caption2)
        }
        .foregroundStyle(Color.dim)
    }
}
