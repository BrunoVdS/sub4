//
//  WeekKind.swift
//  Sub4
//
//  How much a week weighs, according to the plan.
//
//  The source document already classifies every week — a badge with a CSS class
//  of race, peak, cut or done. That classification was never extracted, so the
//  Plan tab drew all 34 weeks identically and the two hardest weeks of the block
//  looked exactly like the two easiest.
//
//  This reads the plan's own judgement rather than inventing one. Deciding in
//  Swift which weeks are "hard" would mean second-guessing something the plan
//  had already decided — and getting it subtly wrong somewhere around week 24.
//
//  THE VISUAL RULE
//  ---------------
//  Only three states are worth distinguishing, and they have to be tellable
//  apart at a glance while scrolling 34 rows:
//
//    hard      race and peak — a filled badge and a coloured leading bar
//    recovery  cut — a quiet outlined badge, and the row itself dimmed
//    ordinary  no badge, no bar, full weight
//
//  Dimming the recovery weeks rather than only brightening the hard ones is
//  deliberate. Sixteen of the 34 weeks are cutbacks; if they kept full weight
//  the list would still read as uniform, because more than half of it would be
//  competing for attention with everything else.
//

import SwiftUI

enum WeekKind: String {
    case race       // the December test, and race week
    case peak       // the two peak long-run weeks
    case cut        // every cutback, down, recovery, holiday and taper week
    case done       // the logged July prologue

    init?(_ raw: String?) {
        guard let raw, let k = WeekKind(rawValue: raw) else { return nil }
        self = k
    }

    /// race and peak. The weeks the block is built around.
    var isHard: Bool { self == .race || self == .peak }

    var isRecovery: Bool { self == .cut }

    /// Filled for the hard weeks, outlined for everything else — the same
    /// treatment the source document gives them.
    var isFilled: Bool { isHard }

    var tint: Color {
        switch self {
        // The plan's own --long green for race weeks and --amber for peaks.
        // On light that green is 1.3:1 against white — invisible — so the light
        // step is the same hue taken down to where it can be seen.
        case .race: dyn(dark: 0x9CFF6E, light: 0x2F7A1C)
        case .peak: Color.atlTint
        case .cut:  Color.dim
        case .done: Color.dim.opacity(0.7)
        }
    }

    /// Ink for a filled badge. The fill inverts between schemes — a bright green
    /// on dark, a deep one on light — so the ink has to invert with it or the
    /// badge is unreadable in exactly one of the two.
    var onTint: Color {
        isFilled ? dyn(dark: 0x0D1205, light: 0xFFFFFF) : tint
    }

    /// How strongly the row itself is drawn. Recovery weeks recede.
    var rowOpacity: Double {
        switch self {
        case .race, .peak: 1
        case .cut:         0.62
        case .done:        0.55
        }
    }
}

extension Week {
    var weekKind: WeekKind? { WeekKind(kind) }

    /// True for the two race weeks and the two peak weeks.
    var isHardWeek: Bool { weekKind?.isHard ?? false }
    var isRecoveryWeek: Bool { weekKind?.isRecovery ?? false }
}
