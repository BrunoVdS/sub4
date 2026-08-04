//
//  Warmup.swift
//  Sub4
//
//  Section 10b — the race-day warm-up.
//
//  This is the first content in the app that did not exist in the plan when the
//  block started. It was written into the source HTML as §10b and extracted the
//  same way as everything else, deliberately: the app's whole claim is that it
//  shows you the plan, and content that arrives by a different route quietly
//  weakens that. One source of truth, one extractor, one validator.
//
//  WHY THE PROTOCOL IS SO SHORT
//  ----------------------------
//  Because the race already contains its own warm-up. The opening pace of
//  5:43–5:45 sits inside the easy band (5:45–6:00), and the plan's "first 5 km
//  controlled" is 35 minutes of progressive effort. Anything more spends
//  glycogen that is needed at 32 km, which the plan names as where the race is
//  decided. What is left to solve is logistics — staying warm through a corral
//  wait, loosening ankles and hips, two planned toilet stops, and not going out
//  fast — and that is what the timeline below actually is.
//
//  Every string is the plan's own, unchanged. Nothing here computes.
//

import Foundation

nonisolated struct Warmup: Codable, Hashable {

    struct Step: Codable, Hashable, Identifiable {
        let time: String?
        let action: String?
        let detail: String?
        var id: String { (time ?? "") + (action ?? "") }
    }

    struct Movement: Codable, Hashable, Identifiable {
        let movement: String?
        let dose: String?
        var id: String { movement ?? "—" }
    }

    struct Condition: Codable, Hashable, Identifiable {
        let condition: String?
        let what: String?
        var id: String { condition ?? "—" }
    }

    let intro: String?
    let timeline: [Step]
    let circuit: [Movement]
    let circuitNote: String?
    let conditions: [Condition]
    let caution: Fuel.Caution?

    /// The step that happens at the gun, so the view can tint it differently —
    /// it is the only line that is not preparation.
    func isGun(_ s: Step) -> Bool {
        (s.time ?? "").hasPrefix("0:00")
    }

    /// Steps the plan marks conditional. Flagged rather than hidden: the
    /// decision is the content.
    func isConditional(_ s: Step) -> Bool {
        let a = (s.action ?? "").lowercased()
        return a.contains("only if") || a.contains("if space")
    }
}

extension PlanStore {
    var warmup: Warmup? { plan.warmup }
}

extension Session {

    /// Any session that links to the warm-up protocol — the three rehearsal
    /// long runs plus race day itself.
    var linksToWarmup: Bool {
        !(prep ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The three long runs where the protocol is practised. Race day is
    /// excluded: on the day you are not rehearsing, you are doing it.
    var rehearsesWarmup: Bool {
        (prep ?? "").localizedCaseInsensitiveContains("rehearse")
    }

    /// The label the prep marker carries. "REHEARSE" on the three practice
    /// runs, "WARM-UP" on race morning — calling race day a rehearsal would be
    /// exactly the wrong word on the one morning it matters.
    var prepLabel: String { rehearsesWarmup ? "REHEARSE" : "WARM-UP" }

    /// Race day gets the accent colour rather than the rehearsal blue. It is
    /// not a practice run and should not look like one.
    var prepIsRaceDay: Bool { linksToWarmup && !rehearsesWarmup }
}
