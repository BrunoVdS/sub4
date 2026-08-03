//
//  RoutePlayback.swift
//  Sub4
//
//  Watching a run happen, on the expanded route panel.
//
//  THE PROBLEM THIS FILE EXISTS TO SOLVE
//  -------------------------------------
//  There is no time stream. `ActivityStreams` resamples every series to about
//  three hundred bins aligned to CUMULATIVE DISTANCE, which is what makes the
//  profile chart honest — every sample is an instantaneous reading at a known
//  distance, so a stop shows as a dip rather than contaminating its neighbours.
//
//  It is also exactly the wrong axis for playback. Step through those bins at a
//  constant rate and the marker crosses a 4:30 kilometre and a 7:00 kilometre in
//  the same wall-clock time, which is the one thing anybody presses play to see.
//
//  THE FIX IS ALREADY IN THE DATA. The speed stream is metres per second, so the
//  time between two samples is Δdistance ÷ speed. Integrating that reconstructs a
//  time axis from the two axes we have, and the marker slows on the climb because
//  the athlete slowed on the climb.
//
//  WHAT THAT COSTS, STATED RATHER THAN HIDDEN
//  ------------------------------------------
//  · Distance-binned samples contain NO STOPPED TIME — a red light occupies no
//    metres — so this is moving-time playback. A 52-minute walk with four
//    minutes of standing still plays as 48.
//  · The integrated total does not land exactly on the recorded moving time, so
//    it is scaled to match. The SHAPE is measured; the TOTAL is anchored.
//  · Zero speed has to be floored or Δd ÷ v is infinite and the marker parks on
//    one sample forever.
//
//  Both are ⓘ material rather than footnotes, and neither makes the picture less
//  true than the profile chart it is derived from.
//

import SwiftUI
import CoreLocation
// `Timer.publish` is Foundation, but `.autoconnect()` is a Combine extension on
// Publisher and `onReceive` needs the conformance visible. Without this line the
// error names `autoconnect` and not the import, which is the least useful place
// it could have pointed.
import Combine

// MARK: - The reconstructed clock

/// Cumulative seconds for each stream sample, index-aligned with `distanceM`.
struct PlaybackTrack {

    let seconds: [Double]
    /// The last entry, kept out so callers never index into an empty array.
    let total: Double

    /// Metres per second below which a sample is treated as this value.
    ///
    /// Not zero, and not a "reasonable walking pace" either. This exists purely
    /// to stop a division blowing up, so it is set low enough that a genuinely
    /// slow sample still reads as slow: 0.5 m/s is 33 min/km, which no recording
    /// in this history sustains and which therefore never distorts a real one.
    static let minSpeed = 0.5

    /// nil when the activity cannot be played: no speed stream, too few samples,
    /// or an integrated duration too short to be a session. The control is
    /// absent in that case — see the note on `RoutePanel`.
    init?(_ s: ActivityStreams, movingSeconds: Int) {
        guard s.isUsable, movingSeconds > 30,
              let speed = s.speed, speed.count == s.count else { return nil }

        var t: [Double] = [0]
        t.reserveCapacity(s.count)
        for i in 1..<s.count {
            // `max(0, …)` because a resampled distance axis is monotonic in
            // principle and this file should not be the thing that discovers it
            // was not.
            let dd = max(0, s.distanceM[i] - s.distanceM[i - 1])
            t.append(t[i - 1] + dd / max(speed[i], Self.minSpeed))
        }
        guard let raw = t.last, raw > 1 else { return nil }

        let k = Double(movingSeconds) / raw
        seconds = t.map { $0 * k }
        total = Double(movingSeconds)
    }

    /// The sample the clock has reached. Binary search, because this runs on
    /// every animation frame and a linear scan over three hundred samples at
    /// sixty hertz is work nobody needs to do.
    func index(at elapsed: Double) -> Int {
        var lo = 0, hi = seconds.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if seconds[mid] < elapsed { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - Speeds

/// The multiplier is REBASED, and the labels are the reason.
///
/// Real time is unwatchable — nobody presses play to spend forty-nine minutes
/// watching a forty-nine minute run — so every figure here is a large multiple
/// of it and printing "120×" invites arithmetic nobody wants to do. `1×` means
/// the speed this is normally watched at; the multiples are relative to that.
enum PlaybackRate: Double, CaseIterable, Identifiable {
    case half = 60, one = 120, two = 240, four = 480

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .half: "0.5×"
        case .one:  "1×"
        case .two:  "2×"
        case .four: "4×"
        }
    }
}

// MARK: - The panel

/// The expanded route, with a transport bar and a live readout.
///
/// PLAYBACK POSITION IS LOCAL, AND THAT IS DELIBERATE.
/// The obvious wiring is to drive the detail page's `scrubKm` — the map cursor
/// and the profile cursor both already follow it, so playback would come almost
/// free. It is not done: that binding lives on `ActivityDetailView`, so writing
/// it sixty times a second would re-evaluate the whole detail page, every card,
/// for every frame of an animation happening inside a cover on top of it.
///
/// The cost of keeping it local is one extra highlight computation in this file.
/// The cost of not keeping it local is a page that stutters while it plays.
struct RoutePanel: View {

    let coordinates: [CLLocationCoordinate2D]
    let streams: ActivityStreams?
    let movingSeconds: Int
    var tint: Color = .accent4
    var discipline: Discipline?
    /// Where the profile chart was left. Shown before playback starts and after
    /// nothing else, so opening the panel does not silently move a cursor the
    /// reader put somewhere on purpose.
    var restingHighlight: RouteHighlight?

    /// Let the map run under the safe area while the chrome stays inside it.
    /// Only the full-screen presentation wants this; declared after the fields
    /// above, per the memberwise-order rule that has now cost this project
    /// three builds. New fields go below.
    var fullBleed: Bool = false

    /// The route as separate legs, for a merged day — patch 177. Passed through
    /// to the map so the joins between legs are never drawn. Empty for a
    /// single activity.
    var segments: [[CLLocationCoordinate2D]] = []

    /// Sample indices in `streams` where a new leg begins, from
    /// `MergedStreams.boundaries`. The travelled line splits here for the same
    /// reason the route does: the marker JUMPS from one leg's finish to the
    /// next leg's start — no metres separate them on the distance axis — and
    /// the covered path must not paint a line across that jump.
    ///
    /// DECLARED LAST — the memberwise-order rule above.
    var segmentBoundaries: [Int] = []

    @State private var elapsed: Double = 0
    @State private var playing = false
    @State private var rate: PlaybackRate = .one
    /// Stamp of the previous tick. Cleared on pause and on scrub, which is what
    /// stops a paused interval from being paid back all at once on resume.
    @State private var lastTick: Date?

    /// BUILT ONCE, NOT PER ACCESS — patch 176, the review's P3.
    ///
    /// This was a computed property, which read tidily and meant the 300-sample
    /// integration re-ran on every access — and during playback it is accessed
    /// in the timer tick, in `sampleIndex`, in `travelled` and in `highlight`:
    /// roughly ninety rebuilds a second of a value that changes only when the
    /// streams do.
    ///
    /// Keyed on `fetched` rather than built in `onAppear`, because the streams
    /// CAN change under an open panel — `prioritise` may land the trace while
    /// you are looking at the route — and a cache built once at appear would
    /// hold the pre-trace nil forever.
    @State private var cachedTrack: PlaybackTrack?

    private var track: PlaybackTrack? { cachedTrack }

    private func rebuildTrack() {
        guard let s = streams, s.hasCoordinates else { cachedTrack = nil; return }
        cachedTrack = PlaybackTrack(s, movingSeconds: movingSeconds)
    }

    /// True once play has been pressed and before it has been reset.
    ///
    /// The readout is hidden at rest rather than printing the first sample: a
    /// panel that opens with "5:08 min/km · 126 bpm" over the route is making a
    /// claim about a moment nobody chose. It appears when the run starts and
    /// stays through a pause, because pausing to read the figures is most of
    /// what pausing is for.
    private var running: Bool { elapsed > 0 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            mapLayer

            if running, let i = sampleIndex { readout(i) }

            if let t = track { transport(t) }
        }
        // A PLAIN TIMER, NOT TimelineView(.animation).
        //
        // The TimelineView form is tidier and is the wrong tool: its schedule
        // re-evaluates a subtree, and the state this needs to mutate lives
        // outside that subtree — which lands you writing `onChange(of:
        // context.date)` on a `Color.clear`, a workaround dressed as a design.
        // Thirty hertz is smooth on a marker moving a few points a frame, and a
        // guarded no-op thirty times a second while paused costs nothing.
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
                        .autoconnect()) { now in
            guard playing, let t = track else { lastTick = nil; return }
            defer { lastTick = now }
            guard let last = lastTick else { return }
            elapsed = min(t.total, elapsed + now.timeIntervalSince(last) * rate.rawValue)
            if elapsed >= t.total { playing = false }
        }
        .onChange(of: streams?.fetched, initial: true) { _, _ in rebuildTrack() }
    }

    /// The picture goes to the edges; the controls do not. A transport bar under
    /// the home indicator is a transport bar you cannot press.
    @ViewBuilder
    private var mapLayer: some View {
        let map = RouteMapView(coordinates: coordinates,
                               tint: tint,
                               highlight: highlight,
                               height: nil,
                               interactive: true,
                               travelled: travelled,
                               segments: segments)
        if fullBleed { map.ignoresSafeArea() } else { map }
    }

    // MARK: What the clock is pointing at

    private var sampleIndex: Int? {
        guard let t = track, let s = streams, s.hasCoordinates else { return nil }
        return min(t.index(at: elapsed), s.count - 1)
    }

    /// The route so far, taken from the STREAM coordinates rather than the
    /// decoded polyline. The clock is indexed against the streams, and the two
    /// are different lines of different lengths — slicing the polyline by the
    /// same integer would draw a fraction of the wrong one. See the note on
    /// `ActivityStreams.coordinate(atKm:)` for why they differ at all.
    ///
    /// SPLIT AT THE LEG BOUNDARIES — patch 177. On a merged day the covered
    /// path is one run per completed leg plus the leg in progress, so no line
    /// bridges the jump between legs. `segmentBoundaries` is empty for a
    /// single activity and the loop degenerates to the old single run.
    private var travelled: [[CLLocationCoordinate2D]] {
        guard running, let i = sampleIndex, let s = streams,
              let lat = s.latitude, let lon = s.longitude,
              lat.count > i, lon.count > i else { return [] }
        var runs: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        var next = 0
        for j in 0...i {
            if next < segmentBoundaries.count, j == segmentBoundaries[next] {
                runs.append(current)
                current = []
                next += 1
            }
            let c = CLLocationCoordinate2D(latitude: lat[j], longitude: lon[j])
            if CLLocationCoordinate2DIsValid(c) { current.append(c) }
        }
        runs.append(current)
        return runs
    }

    private var highlight: RouteHighlight? {
        guard running, let i = sampleIndex, let s = streams,
              let lat = s.latitude?[safe: i], let lon = s.longitude?[safe: i]
        else { return restingHighlight }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(c) else { return restingHighlight }
        return RouteHighlight(coordinate: c,
                              label: String(format: "%.2f km",
                                            (s.distanceM[safe: i] ?? 0) / 1000))
    }

    // MARK: Readout

    private struct Readout: Identifiable {
        let id: Int
        let label: String
        let value: String
        let unit: String
        /// nil prints the figure in ink and draws no swatch — for the two
        /// figures that are not a series on the profile chart.
        let series: StreamSeries?
    }

    private var usesPace: Bool { discipline == .run || discipline == .swim }

    private func lines(_ i: Int) -> [Readout] {
        var out: [Readout] = []
        if let v = streams?.speed?[safe: i], v > 0.2 {
            out.append(Readout(id: out.count,
                               label: usesPace ? "Pace" : "Speed",
                               value: usesPace ? Fmt.pace(Int((1000 / v).rounded()))
                                               : String(format: "%.1f", v * 3.6),
                               unit: usesPace ? "min/km" : "km/h",
                               series: .speed))
        }
        if let hr = streams?.heartRate?[safe: i], hr > 0 {
            out.append(Readout(id: out.count, label: "HR",
                               value: "\(Int(hr))", unit: "bpm", series: .heartRate))
        }
        if let e = streams?.altitude?[safe: i] {
            out.append(Readout(id: out.count, label: "Elev",
                               value: "\(Int(e))", unit: "m", series: .elevation))
        }
        out.append(Readout(id: out.count, label: "Distance",
                           value: String(format: "%.2f",
                                         (streams?.distanceM[safe: i] ?? 0) / 1000),
                           unit: "km", series: nil))
        out.append(Readout(id: out.count, label: "Elapsed",
                           value: Fmt.duration(Int(elapsed)), unit: "", series: nil))
        return out
    }

    /// TOP-RIGHT AND INSET FROM THE TOP, which is not a taste decision: MapKit
    /// places its compass trailing-top and will not move it, so a column
    /// starting at the top edge would sit underneath it.
    ///
    /// Non-interactive, so a finger landing on it still pans the map. It is a
    /// caption over a picture, not a control.
    private func readout(_ i: Int) -> some View {
        let rows = lines(i)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                if r.id > 0 { Divider().overlay(Color.line.opacity(0.55)) }
                cell(r)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 108, alignment: .leading)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.trailing, 8)
        .padding(.top, 40)
        .allowsHitTesting(false)
    }

    private func cell(_ r: Readout) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let s = r.series {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(s.colour).frame(width: 8, height: 2.5)
                }
                Text(r.label.uppercased())
                    .font(.system(size: 8.5, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(Color.dim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(r.value).font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(r.series?.colour ?? Color.ink)
                if !r.unit.isEmpty {
                    Text(r.unit).font(.system(size: 8.5)).foregroundStyle(Color.dim)
                }
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Transport

    private func transport(_ t: PlaybackTrack) -> some View {
        HStack(spacing: 10) {
            Button {
                if elapsed >= t.total { elapsed = 0 }
                lastTick = nil
                playing.toggle()
            } label: {
                Image(systemName: elapsed >= t.total
                      ? "arrow.counterclockwise"
                      : (playing ? "pause.fill" : "play.fill"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.bg)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accent4))
            }
            .buttonStyle(.plain)

            scrubTrack(t)

            HStack(spacing: 0) {
                ForEach(PlaybackRate.allCases) { r in
                    Button { rate = r } label: {
                        Text(r.label)
                            .font(.system(size: 9, weight: r == rate ? .bold : .regular))
                            .foregroundStyle(r == rate ? Color.ink : Color.dim)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule()
                                .fill(Color.ink.opacity(r == rate ? 0.15 : 0)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 6).padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Draggable, so the transport is also how you reach a moment without
    /// waiting for it.
    ///
    /// `minimumDistance: 0` is correct HERE and wrong on the profile chart. The
    /// difference is what sits behind the gesture: this bar has nothing a tap
    /// could otherwise have meant, and the chart has a card that opens.
    private func scrubTrack(_ t: PlaybackTrack) -> some View {
        GeometryReader { geo in
            let f = t.total > 0 ? elapsed / t.total : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dim.opacity(0.28)).frame(height: 3)
                Capsule().fill(Color.ctlTint)
                    .frame(width: max(0, geo.size.width * f), height: 3)
                Circle().fill(Color.dangerColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: max(0, geo.size.width * f - 4.5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        playing = false
                        lastTick = nil
                        elapsed = min(t.total,
                                      max(0, g.location.x
                                             / max(geo.size.width, 1) * t.total))
                    }
            )
        }
        .frame(height: 18)
    }
}

// MARK: - Full screen

/// The route at the phone's own orientation.
///
/// WHY THIS EXISTS AGAIN, AFTER PATCH 150 DELETED IT
/// -------------------------------------------------
/// The evidence is a controlled experiment nobody set up on purpose. The profile
/// panel and the route panel are the same component — same `ExpandableCard`,
/// same `RotatedScreen`, same cover, same rotation — and only the ROUTE loses
/// itself when the phone turns. The one thing that differs is what is inside:
/// the profile is SwiftUI all the way down, and the route contains a `Map`.
///
/// `Map` is UIKit wearing a SwiftUI hat. Putting one inside a `.rotationEffect`
/// asks MKMapView to live under a 90° layer transform while UIKit is running its
/// own rotation on the window — two transforms on one view, applied by two
/// systems that do not know about each other. It also explains the history: this
/// map was presented WITHOUT rotation in patches 144 and 145, was validated
/// working, and has misbehaved on every rotation since 150 folded it into the
/// rotated panel.
///
/// So the map stops being rotated. The system turns it, the way it turns every
/// other map on the phone, and nothing applies a second transform on top.
///
/// This is also the presentation the route wanted anyway — see 144: a route has
/// no long axis, and a towpath run laid into a forced landscape frame is
/// letterboxed by two thick margins. The panel group that made consistency worth
/// paying for was removed in 152; there is nothing left to be consistent WITH.
struct RouteFullScreen: View {

    let coordinates: [CLLocationCoordinate2D]
    let streams: ActivityStreams?
    let movingSeconds: Int
    var tint: Color = .accent4
    var discipline: Discipline?
    var restingHighlight: RouteHighlight?
    var title: String = ""

    /// Pass-throughs to RoutePanel for a merged day — patch 177. Declared
    /// LAST, per the memberwise-order rule.
    var segments: [[CLLocationCoordinate2D]] = []
    var segmentBoundaries: [Int] = []

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Opaque, for the reason in patch 161: a transparent cover presented
            // from inside the detail sheet does not survive a rotation.
            Color.bg.ignoresSafeArea()

            RoutePanel(coordinates: coordinates,
                       streams: streams,
                       movingSeconds: movingSeconds,
                       tint: tint,
                       discipline: discipline,
                       restingHighlight: restingHighlight,
                       fullBleed: true,
                       segments: segments,
                       segmentBoundaries: segmentBoundaries)

            titleBar
        }
    }

    /// Close, name and the key, in one plate. The readout sits top-right inset
    /// from the top and the compass above it, so the leading corner is the only
    /// one free — and the legend has to travel with the map or the flag and the
    /// two dots go unexplained on the one view large enough to read them.
    private var titleBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3).foregroundStyle(Color.dangerColor)
            }
            .buttonStyle(.plain)

            if !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink).lineLimit(1)
            }

            Divider().frame(height: 14).overlay(Color.line)

            RouteKey()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 12).padding(.top, 6)
    }
}
