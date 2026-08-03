//
//  SeriesToggle.swift
//  Sub4
//
//  Turning series on and off — in the expanded panels only.
//
//  WHY NOT ON THE CARDS
//  --------------------
//  The card is a glance. It has 140 points of height, three or four marks, and
//  a caption that already has to earn its place; a row of controls on top of
//  that is chrome competing with the thing it controls. The panel is where you
//  go to investigate, and there a control is worth its space.
//
//  This is the same split the whole tab already runs on — the card shows less,
//  the panel shows more — applied to interaction rather than to data.
//
//  WHY THE STATE RESETS WHEN THE PANEL CLOSES
//  ------------------------------------------
//  It is `@State`, deliberately not `@AppStorage`. A persisted toggle means a
//  chart that is missing a line for a reason you set weeks ago and have
//  forgotten — you open the fitness panel, fatigue is absent, and nothing on
//  screen says you hid it. That failure is quiet and it looks like a bug.
//
//  A panel is a transient investigation. Opening it fresh every time, with
//  everything shown, is the behaviour that cannot mislead.
//
//  WHY SOME SERIES CANNOT BE HIDDEN ALONE
//  --------------------------------------
//  Freshness is drawn as the AREA between fitness and fatigue. Hide either line
//  and the band is still on screen, now bounded by something invisible — which
//  is worse than clutter, because it is a shape that means nothing while
//  looking as though it means something. So hiding a line hides the band with
//  it, and the freshness toggle only controls whether the band is drawn when
//  both its edges are.
//

import SwiftUI

/// One switchable series in a panel's toggle bar.
struct SeriesOption: Identifiable, Equatable {
    let id: String
    let label: String
    let swatch: SeriesSwatch

    init(_ id: String, _ label: String, _ swatch: SeriesSwatch) {
        self.id = id
        self.label = label
        self.swatch = swatch
    }
}

/// A row of small pills, one per series. Tapping dims the pill and removes the
/// series; the pill stays on screen, so a hidden series is never invisible in
/// both places at once.
struct SeriesToggleBar: View {

    let options: [SeriesOption]
    @Binding var hidden: Set<String>

    var body: some View {
        HStack(spacing: 7) {
            ForEach(options) { o in
                let on = !hidden.contains(o.id)
                Button {
                    if on { hidden.insert(o.id) } else { hidden.remove(o.id) }
                } label: {
                    HStack(spacing: 5) {
                        o.swatch.opacity(on ? 1 : 0.3)
                        Text(o.label)
                            .font(.caption2.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.ink : Color.dim)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.ink.opacity(on ? 0.08 : 0.02))
                            .overlay(Capsule().stroke(Color.line, lineWidth: 1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
