//
//  RouteMapView.swift
//  Sub4
//
//  The GPS trace. Two renderings, chosen by connectivity:
//
//   • online  — MapKit, so the route sits on real streets
//   • offline — the same coordinates drawn as a bare shape on the card
//
//  The offline fallback exists because MapKit with no network is a grey grid
//  with a route floating on it, which reads as broken. A plain trace reads as
//  intentional, costs nothing, and still shows the shape of the run.
//
//  Both renderings take the same `highlight`, so dragging the profile chart
//  moves a dot along the route in either mode.
//

import SwiftUI
import MapKit
import Network
import Observation

// MARK: - Connectivity

@Observable
final class Reachability {
    static let shared = Reachability()

    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.isOnline = up }
        }
        monitor.start(queue: DispatchQueue(label: "sub4.network.monitor"))
    }
}

// MARK: - Where the chart is pointing

struct RouteHighlight: Equatable {
    let coordinate: CLLocationCoordinate2D
    let label: String

    static func == (a: RouteHighlight, b: RouteHighlight) -> Bool {
        a.label == b.label
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
    }
}

// MARK: - Map

struct RouteMapView: View {

    let coordinates: [CLLocationCoordinate2D]
    var tint: Color = .accent4
    var highlight: RouteHighlight?

    /// nil fills whatever space the parent gives, which is what the full-screen
    /// presentation wants. A number is the card.
    var height: CGFloat? = 190

    /// PAN AND ZOOM ARE OFF ON THE CARD, AND THAT IS A FIX, NOT A RESTRICTION.
    ///
    /// The card sits inside a ScrollView. MapKit claims drags before SwiftUI
    /// sees them, so a finger starting on the map panned the map instead of
    /// scrolling the page — on a detail screen where the map is a third of the
    /// width, that is a dead zone you have to learn to swipe around. It also
    /// swallowed the tap, which is why this card could never open the way every
    /// other card on the page does.
    ///
    /// Inline it is now a picture: the page scrolls over it and a tap opens it.
    /// Full screen it is a map, where panning is the point and there is nothing
    /// else the gesture could have meant.
    var interactive: Bool = false

    /// The part already covered, drawn over the dim full route during playback.
    ///
    /// A memberwise initialiser takes its arguments in declaration order and
    /// this project has now lost two builds to forgetting that — see the note
    /// on `StreamChartView.expanded`. New stored properties go after this one.
    ///
    /// Empty means no playback, which is why this is a plain array rather than
    /// an optional: there is no difference between "not playing" and "nothing
    /// covered yet", and two spellings of one state is one too many.
    ///
    /// AN ARRAY OF RUNS since patch 177, for the same reason as `segments`
    /// below: on a merged day the covered path must not bridge the legs. A
    /// single activity passes one run and nothing changes for it.
    var travelled: [[CLLocationCoordinate2D]] = []

    /// The route as separate legs — patch 177, for a merged day.
    ///
    /// Empty means `coordinates` is the whole story, which is every single
    /// activity. Non-empty REPLACES `coordinates` for drawing: each leg gets
    /// its own polyline, so the map never draws the straight line from where
    /// the lunch walk ended to where the evening walk began — a line nobody
    /// moved along. `coordinates` still carries the flat union for the guard
    /// and the fit, so a caller passes both and they agree by construction.
    ///
    /// DECLARED LAST — the memberwise-order rule above.
    var segments: [[CLLocationCoordinate2D]] = []

    @State private var net = Reachability.shared

    /// The scrub marker. Deliberately not one of the series colours and not one
    /// of the route's own endpoint colours — it's a cursor, not data, and it
    /// carries its distance as a label so it never depends on being red.
    private var cursorColour: Color { Color.dangerColor }

    var body: some View {
        Group {
            if coordinates.count > 1 {
                if net.isOnline {
                    liveMap
                } else {
                    offlineTrace
                }
            }
        }
    }

    // MARK: Online

    /// ROTATE IS IN, PITCH IS OUT.
    ///
    /// The card was `[.pan, .zoom]` since it was written and the full screen
    /// inherited it, so a route could be moved and scaled but never turned —
    /// which is the one thing you want when the run went north and the street
    /// names are sideways.
    ///
    /// `.pitch` is deliberately not here. The style is `elevation: .flat`, so
    /// there is no terrain to tilt into: pitching only skews a flat plane into a
    /// trapezoid, which makes distances along the route read differently at the
    /// top of the screen than at the bottom. It also costs a two-finger drag
    /// that would otherwise be free.
    private var modes: MapInteractionModes {
        interactive ? [.pan, .zoom, .rotate] : []
    }

    /// THE CAMERA IS OWNED, NOT SEEDED — patch 155.
    ///
    /// `initialPosition:` is applied ONCE, at first layout, and never again.
    /// That is fine for a card, whose frame never changes, and wrong for the
    /// expanded panel.
    ///
    /// The panel does not keep the same size across a rotation, even though it
    /// is built long-side-to-long-side to try to. `RotatedScreen` measures
    /// `geo.size`, which is the SAFE rectangle — and a phone's portrait safe
    /// area (status bar and home indicator, top and bottom) is not the same
    /// shape as its landscape one (the island inset on one side). So the panel
    /// arrives a few tens of points different after the turn.
    ///
    /// A chart does not care: it re-lays-out to whatever it is given. A map does
    /// — MapKit keeps the camera it already had and simply shows a different
    /// amount of world through a differently shaped window, so the route drifts
    /// off centre and stays there. That is the bug: not that the panel moved,
    /// but that the map never re-framed.
    @State private var camera: MapCameraPosition = .automatic

    /// One run per polyline. A single activity is a one-element array.
    private var routeRuns: [[CLLocationCoordinate2D]] {
        segments.isEmpty ? [coordinates] : segments
    }

    /// Whether any covered path exists — the dim-the-route test.
    private var isCovering: Bool {
        travelled.contains { $0.count > 1 }
    }

    private var liveMap: some View {
        Map(position: $camera, interactionModes: modes) {
            // The whole route, dimmed once there is a covered part to contrast
            // against it. Dimmed rather than hidden: the shape of what is still
            // to come is most of what makes watching it worth anything.
            //
            // Per LEG, not one polyline — see `segments`. `Array.indices` as
            // the ForEach id is safe here: the runs are value-copied inputs
            // that change only with the view's own identity.
            ForEach(routeRuns.indices, id: \.self) { i in
                MapPolyline(coordinates: routeRuns[i])
                    .stroke(isCovering ? tint.opacity(0.28) : tint,
                            style: StrokeStyle(lineWidth: 3,
                                               lineCap: .round,
                                               lineJoin: .round))
            }
            ForEach(travelled.indices, id: \.self) { i in
                if travelled[i].count > 1 {
                    MapPolyline(coordinates: travelled[i])
                        .stroke(tint, style: StrokeStyle(lineWidth: 4,
                                                         lineCap: .round,
                                                         lineJoin: .round))
                }
            }
            // Start of the first leg, finish of the last. The intermediate
            // ends deliberately carry no marks: four flags on a walking day
            // would out-shout the route, and the legs are already separate
            // lines.
            if let first = routeRuns.first?.first {
                Annotation("Start", coordinate: first) { endpoint(.startColor) }
            }
            if let last = routeRuns.last?.last {
                Annotation("Finish", coordinate: last) { FinishMarker() }
            }
            if let h = highlight {
                Annotation(h.label, coordinate: h.coordinate) { cursor }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // A rotated map with no way back to north is a map you can get lost in.
        // The compass is `.automatic`, so it appears only once you have turned
        // the map and one tap puts it back — and the scale bar is worth having
        // for free on a route, where "how big is that loop" is a real question.
        //
        // Hidden rather than omitted on the card: the controls are declared once
        // for both presentations, and visibility follows interactivity, so a
        // non-interactive map cannot show a compass that would do nothing.
        //
        // The compass ALONE, not the scale bar as well. The scale renders in
        // the top-leading area, which is where the close button lives, and a
        // system control appearing over app chrome is worse than not having a
        // scale bar. Four corners, four things, nothing overlapping.
        .mapControls { MapCompass() }
        .mapControlVisibility(interactive ? .automatic : .hidden)
        // RE-FIT WHENEVER THE FRAME CHANGES, WHICH IS WHAT ROTATION IS.
        //
        // Not "whenever the camera changes" — that fires on every pan and would
        // fight the finger. This fires only when the view's own size does, which
        // on this screen means exactly one thing: the phone turned.
        //
        // A pan or zoom made before the turn IS discarded, deliberately. Turning
        // the phone is a request to see the picture properly, and every other
        // panel in the app answers it by re-laying-out. A map that kept a stale
        // camera would be the only thing on screen that did not.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            camera = .rect(fittedRect)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color.line, lineWidth: 1)
        )
    }

    /// Square corners full screen. A rounded rectangle says "this is a card on a
    /// page"; there is no page behind it here.
    private var corner: CGFloat { height == nil ? 0 : 10 }

    private func endpoint(_ colour: Color) -> some View {
        Circle()
            .fill(colour)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.bg, lineWidth: 2))
    }

    private var cursor: some View {
        Circle()
            .fill(cursorColour)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 3)
    }

    /// Fits the whole route by unioning map points rather than padding a
    /// degree-span. A degree of longitude covers far less ground than a degree
    /// of latitude at 51° N, so a span built from raw deltas fits the route to
    /// the wrong axis on a wide, short frame.
    private var fittedRect: MKMapRect {
        var rect = MKMapRect.null
        for c in coordinates {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        guard !rect.isNull else {
            let p = MKMapPoint(coordinates[0])
            return MKMapRect(x: p.x - 500, y: p.y - 500, width: 1000, height: 1000)
        }
        // A margin, with a floor so a 400 m loop isn't zoomed to the pavement.
        let pad = max(rect.width, rect.height) * 0.15
        return rect.insetBy(dx: -max(pad, 150), dy: -max(pad, 150))
    }

    // MARK: Offline

    private var offlineTrace: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geo in
                let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: 12, dy: 12)
                ZStack(alignment: .topLeading) {
                    // Per leg, projected through the FULL route's bounds so
                    // every leg lands in one shared frame — see `segments`.
                    ForEach(routeRuns.indices, id: \.self) { i in
                        RouteShape(coordinates: routeRuns[i], bounds: coordinates)
                            .stroke(isCovering ? tint.opacity(0.28) : tint,
                                    style: StrokeStyle(lineWidth: 2,
                                                       lineCap: .round,
                                                       lineJoin: .round))
                            .padding(12)
                    }

                    // The same shared bounds, for the same reason — a growing
                    // line rescaled to its own extent would crawl backwards
                    // across the frame as it got longer.
                    ForEach(travelled.indices, id: \.self) { i in
                        if travelled[i].count > 1 {
                            RouteShape(coordinates: travelled[i], bounds: coordinates)
                                .stroke(tint, style: StrokeStyle(lineWidth: 2.5,
                                                                 lineCap: .round,
                                                                 lineJoin: .round))
                                .padding(12)
                        }
                    }

                    // The offline trace drew neither endpoint until patch 108,
                    // so the fallback was a different map rather than the same
                    // map without tiles. Both marks now, drawn in the same order
                    // as the live one — finish last, so on a loop it sits on top
                    // of the start rather than under it.
                    if let c = routeRuns.first?.first,
                       let p = RouteShape.project(c, coordinates: coordinates, in: rect) {
                        Circle()
                            .fill(Color.startColor)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.bg, lineWidth: 2))
                            .position(p)
                    }
                    if let c = routeRuns.last?.last,
                       let p = RouteShape.project(c, coordinates: coordinates, in: rect) {
                        FinishMarker(size: 13).position(p)
                    }

                    if let h = highlight,
                       let p = RouteShape.project(h.coordinate,
                                                  coordinates: coordinates,
                                                  in: rect) {
                        Circle()
                            .fill(cursorColour)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .position(p)
                    }
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: height == nil ? .infinity : nil)
            .background(Color.bg)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color.line, lineWidth: 1)
            )

            Label(highlight?.label ?? "Offline · route only",
                  systemImage: highlight == nil ? "wifi.slash" : "mappin")
                .font(.caption2)
                .foregroundStyle(Color.dim)
                .padding(9)
        }
    }
}

// The device-following full screen was deleted in patch 150.
//
// `RouteScreen` presented the map at the phone's own orientation, chosen in
// 144 because a route has no long axis: a towpath run is tall, a park loop is
// square, and a wide frame letterboxes half of them. That reasoning has not
// changed and is not wrong.
//
// What outweighed it is that the route now shares a panel GROUP with the
// profile — switch between them in the header, and the scrub that links them
// keeps working — and a group cannot have two presentation styles. The route
// goes through `RotatedScreen` with everything else, and a tall route pays for
// it in side margins.
//
// If those margins turn out to be the thing that matters, the way back is a
// route-only panel outside the group, not a second presentation inside it.

// MARK: - Bare trace

/// Draws a lat/lon track into a rect, aspect-corrected.
///
/// Longitude degrees shrink with latitude, so a track drawn on raw degrees comes
/// out stretched east–west. At 51° N (Antwerpen) a degree of longitude is ~0.63
/// of a degree of latitude — visible enough to matter.
struct RouteShape: Shape {
    let coordinates: [CLLocationCoordinate2D]
    /// Scale to THESE bounds instead of the drawn line's own. Only playback
    /// needs it: a partial route measured against itself would be redrawn at a
    /// new scale on every frame and appear to shrink as it grew.
    var bounds: [CLLocationCoordinate2D]?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard coordinates.count > 1,
              let b = RouteBounds(bounds ?? coordinates) else { return path }

        path.move(to: b.point(coordinates[0], in: rect))
        for c in coordinates.dropFirst() {
            path.addLine(to: b.point(c, in: rect))
        }
        return path
    }

    /// Shared by the trace and the scrub dot, so the two can never disagree
    /// about where a coordinate lands.
    static func project(_ c: CLLocationCoordinate2D,
                        coordinates: [CLLocationCoordinate2D],
                        in rect: CGRect) -> CGPoint? {
        RouteBounds(coordinates)?.point(c, in: rect)
    }
}

/// Bounds computed ONCE per draw.
///
/// The obvious refactor — one `project(coordinate, coordinates:, in:)` called
/// per point — rescans the whole track for its min and max on every point, so a
/// 2 000-point polyline costs four million comparisons per frame. Hoisting the
/// scan makes it linear.
struct RouteBounds {
    let minLat, maxLat, minLon, maxLon: Double
    /// Longitude compression at this latitude: a degree of longitude is ~0.63
    /// of a degree of latitude at 51° N, and a track drawn on raw degrees comes
    /// out stretched east–west.
    let k: Double

    init?(_ coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return nil }
        var loLat = coords[0].latitude,  hiLat = loLat
        var loLon = coords[0].longitude, hiLon = loLon
        for c in coords.dropFirst() {
            loLat = min(loLat, c.latitude);  hiLat = max(hiLat, c.latitude)
            loLon = min(loLon, c.longitude); hiLon = max(hiLon, c.longitude)
        }
        minLat = loLat; maxLat = hiLat
        minLon = loLon; maxLon = hiLon
        k = cos(((loLat + hiLat) / 2) * .pi / 180)
    }

    func point(_ c: CLLocationCoordinate2D, in rect: CGRect) -> CGPoint {
        let w = max((maxLon - minLon) * k, 1e-6)
        let h = max(maxLat - minLat, 1e-6)
        let scale = min(rect.width / w, rect.height / h)
        let offsetX = (rect.width  - w * scale) / 2
        let offsetY = (rect.height - h * scale) / 2
        return CGPoint(x: rect.minX + offsetX + (c.longitude - minLon) * k * scale,
                       // y is flipped: north is up.
                       y: rect.minY + offsetY + (maxLat - c.latitude) * scale)
    }
}

/// The Start and Finish key, said once.
///
/// Two screens explain the route's endpoint marks — the detail card's legend
/// and the full-screen title bar — and until patch 173 each composed its own
/// pair. A `Group`, so the items inherit whatever spacing the host row uses:
/// the key states WHAT the marks mean, and the row it sits in decides how the
/// explanation is set.
struct RouteKey: View {
    var body: some View {
        Group {
            LegendItem(.dot(Color.startColor), "Start")
            // The finish carries its own mark rather than a swatch: the flag
            // on the map is a pattern, and a coloured dot here would be a key
            // to something that is not on screen.
            LegendItem(.view(AnyView(FinishMarker(size: 9))), "Finish")
        }
    }
}

// MARK: - The finish

/// A round chequered flag.
///
/// WHY NOT A COLOURED DOT
/// ----------------------
/// Start and finish used to be the same shape in two colours, and on a loop they
/// sit within a few metres of each other. Distinguishing them meant reading two
/// small circles against whatever the map happened to be underneath — a green
/// dot on parkland, a tint dot on a road — and then checking the legend to
/// recall which was which.
///
/// A chequered flag is not a colour, it is a convention. It means finish
/// everywhere it appears, and it survives being the same size as the dot beside
/// it because the PATTERN carries it. It is also the one mark on this map that
/// needs no legend entry to be understood.
///
/// DRAWN, NOT AN SF SYMBOL. `flag.checkered` renders as a flag on a pole: at
/// fourteen points the pole is most of the glyph's width and the chequers become
/// four grey pixels. A grid of squares clipped to a circle keeps the pattern at
/// any size, which is what has to survive.
///
/// BLACK AND WHITE ON BOTH SCHEMES, deliberately — this is the only mark in the
/// app exempt from the theme. A chequered flag in theme colours is not a
/// chequered flag, and the tile underneath is a photograph of the world rather
/// than one of our surfaces.
struct FinishMarker: View {

    var size: CGFloat = 15
    /// Four across reads as chequered at fifteen points; three reads as a
    /// pinwheel and six as grey.
    private let squares = 4

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<squares, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<squares, id: \.self) { c in
                        Rectangle()
                            .fill((r + c).isMultiple(of: 2) ? Color.white : Color.black)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // A hairline inside the clip so the white squares have an edge, and a
        // ring outside it so the black ones do. Either alone loses half the
        // marker against a map tile of the same value.
        .overlay(Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 0.5))
        .padding(1.5)
        .background(Circle().fill(Color.white))
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
    }
}
