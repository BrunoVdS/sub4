//
//  SeriesSwatch.swift
//  Sub4
//
//  The mark that links a number to its line.
//
//  WHY NOT JUST COLOUR THE NUMBER
//  ------------------------------
//  It was the obvious idea and it fails three ways on this particular set of
//  figures.
//
//  Freshness has no line to borrow from. TSB is drawn as the AREA between the
//  two curves, so there is no hue to match — and tinting the numeral to the
//  translucent grey of a fill produces a muddy number rather than a visual aid.
//
//  Load and fatigue would collide. `Color.accent4` is #FB9226 and the ATL line
//  is #FFB02E; at caption size, side by side, those read as one colour on two
//  numbers meaning entirely different things.
//
//  And the load figure's colour is already carrying meaning: accent when the
//  day was measured, dim when it was a gap or a floor. That says "this number
//  is real", which is worth more on a screen read in a hurry than "this number
//  is also on a chart". Putting series identity on the same channel would
//  overwrite it.
//
//  So the identity goes on a mark beside the label and the numeral stays in
//  ink — which is also what every chart legend in the app already does, so this
//  is a convention being extended rather than a new one being invented.
//
//  A FIGURE WITH NO LINE GETS NO SWATCH
//  ------------------------------------
//  Load is not plotted on the fitness chart, so it carries nothing. The absence
//  is the point: it groups the three model outputs visually and leaves today's
//  input outside them, which is the real distinction between the four numbers.
//

import SwiftUI

/// A legend mark sized for a caption line.
enum SeriesSwatch: View, Equatable {
    /// A solid line, matching a `LineMark`.
    case line(Color)
    /// The shaded band between two lines, matching the TSB `AreaMark`.
    case area
    /// A dashed reference, matching a `RuleMark`.
    case rule(Color)

    var body: some View {
        switch self {
        case .line(let c):
            RoundedRectangle(cornerRadius: 1.5)
                .fill(c).frame(width: 9, height: 3)
        case .area:
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.tsbFill).frame(width: 9, height: 7)
        case .rule(let c):
            RoundedRectangle(cornerRadius: 1.5)
                .fill(c).frame(width: 9, height: 2).opacity(0.85)
        }
    }
}
