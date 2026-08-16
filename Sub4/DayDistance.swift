//
//  DayDistance.swift
//  Sub4
//
//  A day's distance, stated only when it is one quantity — patch 249,
//  ADR-0003 §12.11.6's rule applied a level down.
//
//  THE SAME MISTAKE, ONE SCREEN LOWER
//  ----------------------------------
//  Patch 239 removed "125 km all sports" from the week header, because adding
//  running kilometres to cycling kilometres to swimming kilometres produces a
//  number that is not a quantity. `PlanFocus` replaced it by asking the plan
//  what it is about.
//
//  Today's panel had the identical defect and nobody looked, because the data
//  that would have exposed it was missing: the sync could not fetch an activity
//  uploaded out of order, so 4 August 2026 showed a 1.2 km swim and three rides
//  that were not there. Recovering the rides — patch 249's other half — would
//  have made the panel read `Plan 1,2 km · Extra 13,3 km`, a swim beside three
//  bike rides, and on the pre-plan branch a `Total` of 14,5 km that is nothing
//  at all.
//
//  Worth recording as a pattern rather than an incident: **fixing the sync
//  exposed a display defect that had been latent for months.** Missing data
//  hides defects in the code that would have shown it.
//
//  THE RULE
//  --------
//  One discipline carrying distance → say the distance and NAME the sport.
//  More than one → say the time instead, because minutes do add across sports
//  and kilometres do not.
//
//  Activities carrying no distance do not make a day mixed. A ride and a
//  strength session is a bike day with 13,3 km in it; calling that "mixed" and
//  falling back to minutes would hide the one real number on the screen to
//  avoid a collision that never happened.
//

import Foundation

/// What a set of activities can honestly be said to add up to.
///
/// NOT `nonisolated`, and that is the deliberate half of this decision.
/// `Activity.km` and `Activity.minutes` are COMPUTED properties, so they
/// inherit the type's MainActor isolation — unlike `dayKey` and `discipline`,
/// which are marked `nonisolated` individually. This runs on one day's worth of
/// activities inside a view body, which is main-actor work by definition, so
/// there is nothing to gain by claiming otherwise. The inverse of the mistake
/// this project has made six times: `nonisolated` is a claim about where code
/// can run, and asserting it here would be false.
enum DayDistance: Equatable {
    /// Every activity that covered ground did so in one discipline.
    case km(Double, Discipline)
    /// More than one discipline covered ground. Their kilometres do not add,
    /// so this is the time they took, which does.
    case minutes(Int)
    /// Nothing covered any ground — a strength day, a rest day, an empty one.
    case none(minutes: Int)

    static func of(_ activities: [Activity]) -> DayDistance {
        // `km > 0` and not `discipline != .strength`: the question is whether a
        // thing contributes a distance, and the activity's own distance is a
        // better answer to that than its label. A gym session logged with a
        // stray 40 m of GPS drift is a real edge, and it is caught by the
        // threshold below rather than by guessing from the sport.
        let moved = activities.filter { $0.km >= 0.05 }
        // SECONDS FIRST — patch 375, §12.119. This summed truncated
        // minutes, so a day of four activities could report three
        // minutes short, and `VolumeParity` compared that figure.
        let minutes = activities.totalMinutes

        guard let first = moved.first else { return .none(minutes: minutes) }
        let disciplines = Set(moved.map { $0.discipline ?? .other })
        guard disciplines.count == 1 else { return .minutes(minutes) }

        return .km(moved.reduce(0) { $0 + $1.km }, first.discipline ?? .other)
    }

    /// The number for a metric cell.
    var value: String {
        switch self {
        case .km(let km, _):     String(format: "%.1f", km)
        case .minutes(let m):    "\(m)"
        case .none:              "0,0"
        }
    }

    /// The unit, carrying the discipline where there is one. "km bike" rather
    /// than "km", because a bare "km" beside a swim is what this file exists
    /// to prevent.
    var unit: String {
        switch self {
        case .km(_, let d):  "km \(d.label.lowercased())"
        case .minutes:       "min"
        case .none:          "km"
        }
    }

    /// True when the figure is a distance in one sport. The pre-plan `Total`
    /// cell uses this to decide whether it may combine two sets at all.
    var isSingleDiscipline: Bool {
        if case .km = self { return true }
        return false
    }
}
