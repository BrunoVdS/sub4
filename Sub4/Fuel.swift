//
//  Fuel.swift
//  Sub4
//
//  Sections 09 (Fueling) and 10 (Race day · eat & drink) of the plan.
//
//  These existed in the source document from the beginning and reached nothing.
//  180 of the 260 sessions carry their own fuelling line, and the two reference
//  sections carry the product table, a g/hr figure for every session type, the
//  long-run ladder, the full race-day timeline and the hydration and pacing
//  plan. None of it was extracted, so none of it was in the app.
//
//  MODELLED AS TEXT, NOT AS NUMBERS
//  --------------------------------
//  Every field here is the plan's own string, carried through unchanged. It
//  would be easy to parse "~65 g/hr" into an Int and "750 ml Leppin + 1 gel"
//  into a structure — and it would be wrong. The app has no use for a fuelling
//  number it can compute with, and a parser is a place for the plan's meaning
//  to be quietly altered. "Never guess" applies here exactly as it does to the
//  session prescriptions: what the plan says is what gets shown.
//
//  The one thing that is interpreted is `Session.fuel`, and only to decide
//  whether to show a link to the ladder — a substring check, not a parse.
//

import Foundation

nonisolated struct Fuel: Codable, Hashable {

    struct Product: Codable, Hashable, Identifiable {
        let name: String?
        let carbs: String?
        let caffeine: String?
        let use: String?
        // Deterministic. `UUID()` here would mint a new id on every access,
        // so ForEach identity would change each render and rows would be
        // rebuilt from scratch.
        var id: String { name ?? "—" }
    }

    /// "Long run (easy / steady)" → "~65 g/hr" → "Leppin bottle + gels".
    struct SessionTarget: Codable, Hashable, Identifiable {
        let session: String?
        let target: String?
        let take: String?
        var id: String { session ?? "—" }

        /// The plan writes "—" for sessions that need nothing.
        var hasTarget: Bool {
            guard let t = target?.trimmingCharacters(in: .whitespaces) else { return false }
            return !t.isEmpty && t != "—" && t != "-"
        }
    }

    struct LadderStep: Codable, Hashable, Identifiable {
        let run: String?
        let carbs: String?
        let take: String?
        var id: String { run ?? "—" }
    }

    struct Caution: Codable, Hashable {
        let tag: String?
        let text: String?
    }

    struct RaceDay: Codable, Hashable {

        struct Step: Codable, Hashable, Identifiable {
            let time: String?
            let dist: String?
            let take: String?
            let total: String?
            var id: String { (time ?? "") + (total ?? "") }
        }

        let intro: String?
        /// Carb-load, the day before, breakfast, and the gel at −15 min.
        let before: [String]
        let timeline: [Step]
        let totals: String?
        let hydration: String?
        let pacing: String?
        let caution: Caution?
    }

    let intro: String?
    let timingRule: String?
    let products: [Product]
    let perSession: [SessionTarget]
    let ladder: [LadderStep]
    let caution: Caution?
    let raceDay: RaceDay?
}

// MARK: - Reading a session's fuel line

extension Session {

    /// True when the plan's fuel line points at the long-run ladder rather than
    /// stating what to take. A substring check, deliberately — see the header.
    var fuelPointsAtLadder: Bool {
        (fuel ?? "").localizedCaseInsensitiveContains("ladder")
    }

    /// True when the line points at the race-day schema.
    var fuelPointsAtRaceDay: Bool {
        let f = (fuel ?? "").lowercased()
        return f.contains("race-day schema") || f.contains("race schema")
    }

    /// "Water only" sessions get a quieter treatment than a 65 g/hr long run —
    /// the information is "there is nothing to carry", which should not look
    /// like an instruction.
    var fuelIsWaterOnly: Bool {
        (fuel ?? "").localizedCaseInsensitiveContains("water only")
    }
}

extension PlanStore {
    var fuel: Fuel? { plan.fuel }
}
