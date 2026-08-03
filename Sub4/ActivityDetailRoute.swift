//
//  ActivityDetailRoute.swift
//  Sub4
//
//  The route card, the profile card, and the full-screen panels they open.
//
//  SPLIT OUT OF ActivityDetailView.swift IN PATCH 171. That file had reached
//  2,150 lines and held every card on the page. These pieces moved wholesale,
//  unchanged except that members shared with the view lost `private` —
//  Swift's file-scoped privacy cannot cross a file split.
//

import SwiftUI
import CoreLocation

extension ActivityDetailView {

    // MARK: Map

    // TAPPING OPENS THE ROUTE — 144, and back to 144's shape in patch 162.
    //
    // NOT an ExpandableCard, and the reason is a controlled experiment nobody
    // set up on purpose. Profile and Route were the same component — same card,
    // same RotatedScreen, same cover, same rotation — and only ROUTE lost itself
    // when the phone turned. What differs is the content: the profile is SwiftUI
    // all the way down and the route contains a `Map`.
    //
    // A `Map` is UIKit wearing a SwiftUI hat, and `RotatedScreen` puts a 90°
    // layer transform on its content while UIKit is running its own rotation on
    // the window. Two transforms on one view, applied by two systems that do not
    // know about each other. The history says the same thing: this map was
    // presented WITHOUT rotation in 144 and 145, was validated working, and has
    // misbehaved on every rotation since 150 folded it into the rotated panel.
    //
    // So it goes back to its own full screen, which follows the device. The
    // system turns the map the way it turns every other map on the phone.
    //
    // The card still behaves like every other one — whole card taps, no glyph.
    // Only the destination differs, and 152's reasons for the gesture are
    // untouched by 162's reasons for the presentation.
    @ViewBuilder
    var mapCard: some View {
        if let d = detail, d.hasRoute {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("ROUTE", elevationLabel)
                RouteMapView(coordinates: d.coordinates,
                             tint: tint,
                             highlight: routeHighlight)
                mapLegend
            }
            .cardStyle()
            .contentShape(Rectangle())
            .onTapGesture { panelSheet = .route }
        }
    }

    /// Device-following, not rotated — see the note on `mapCard`.
    @ViewBuilder
    var routePanelScreen: some View {
        if let d = detail, d.hasRoute {
            RouteFullScreen(coordinates: d.coordinates,
                            streams: store.streams(for: activity.id),
                            movingSeconds: duration,
                            tint: tint,
                            discipline: activity.discipline,
                            restingHighlight: routeHighlight,
                            title: activity.name)
        }
    }

    /// The rotated panel, which the profile has always been happy in.
    @ViewBuilder
    var profilePanelScreen: some View {
        if let s = store.streams(for: activity.id), s.isUsable {
            RotatedScreen(panels: [
                ExpandedPanel("profile", "Profile") {
                    StreamChartView(streams: s,
                                    discipline: activity.discipline,
                                    tint: tint,
                                    selectedKm: $scrubKm,
                                    expanded: true)
                }
            ])
        }
    }

    /// Shared by the card and the expanded panel. The panel is just the map, so
    /// the key has to travel with it — otherwise the flag and the two dots go
    /// unexplained on the one view large enough to make them worth reading.
    var mapLegend: some View {
        HStack(spacing: 14) {
            RouteKey()
            if let h = routeHighlight {
                LegendItem(.dot(Color.dangerColor), h.label)
            }
            Spacer(minLength: 0)
        }
    }

    /// Chart position → ground position. Straight lookup in the latlng stream,
    /// which shares an index with the distance axis the chart is drawn on.
    var routeHighlight: RouteHighlight? {
        guard let km = scrubKm,
              let s = store.streams(for: activity.id),
              let c = s.coordinate(atKm: km) else { return nil }
        return RouteHighlight(coordinate: c, label: String(format: "%.2f km", km))
    }

    /// Empty for runs and rides since patch 87 — the climb moved into the hero
    /// row, and printing it again here would put the same number twice on one
    /// screen. Kept for anything else that somehow carries a route and a gain.
    var elevationLabel: String {
        guard activity.discipline != .run, activity.discipline != .bike,
              let g = activity.elevationGain, g > 1 else { return "" }
        return "\(Int(g)) m climbed"
    }

    // MARK: Profile — heart rate, pace, elevation and grade against distance

    // TAP OPENS, DRAG SCRUBS — patch 152.
    //
    // The whole card is the control, the way every expandable card in this app
    // works. Patch 150 put the affordance on the header instead, out of a fear
    // that an outer tap would fight the chart's own gesture; the fear was
    // right and the fix was in the wrong place. `chartGesture` now gives the
    // plot a drag-only recogniser, so a tap has nothing to collide with and the
    // card can behave like all the others. See the note in StreamChartView.
    //
    // A SINGLE PANEL, NOT A GROUP. 150 put Profile and Route in one group with
    // a switcher, on the reasoning that they share the scrub. They do — but the
    // switcher is chrome for a choice nobody was making: you open the profile
    // to read the profile. One card, one panel, no header control.
    @ViewBuilder
    var profileCard: some View {
        if let s = store.streams(for: activity.id), s.isUsable {
            // Not `ExpandableCard`, for the same reason the map is not: that
            // component carries its own `.fullScreenCover`, and on this page the
            // card it would be attached to lives in a LazyVStack. See
            // `PanelSheet`. The gesture is unchanged — whole card taps, and the
            // chart's drag-only recogniser from patch 152 keeps the scrub.
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("PROFILE", String(format: "%.1f km", s.totalKm))
                StreamChartView(streams: s,
                                discipline: activity.discipline,
                                tint: tint,
                                selectedKm: $scrubKm)
            }
            .cardStyle()
            .contentShape(Rectangle())
            .onTapGesture { panelSheet = .profile }
        } else if store.streamsUnavailable(activity.id) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                Text("No recorded profile for this one — entered by hand, or "
                     + "recorded without GPS.")
                Spacer()
            }
            .font(.caption).foregroundStyle(Color.dim)
            .cardStyle()
        }
    }

}
