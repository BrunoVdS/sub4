//
//  GearKind.swift
//  Sub4
//
//  Bike, shoe, or nobody knows — patch 425, ADR-0003 §12.175, D7 slice B5.
//
//  ITS OWN FILE, BECAUSE THREE LAYERS NAME IT.
//  `AthleteStore.Shoe` carries it, `AthleteFile` mirrors it, and `gear.kind`
//  stores it. Nesting it inside any one of those would make the other two
//  reach through a type they do not otherwise depend on.
//
//  THE RAW VALUES ARE FROZEN. `2026-08-21-gear-kind` names them in a `DEFAULT`
//  and a migration is history — `theFrozenGearKindsMatchTheSchema` is the
//  coupling, and it can only run one way: this enum must still say what the
//  schema was born saying. CLAUDE.md's rule, and `work_queue.state`'s
//  precedent.
//

import Foundation

/// What a piece of gear is.
///
/// **`unknown` IS A MEASUREMENT, NOT A PLACEHOLDER.** Retirement is inferred
/// rather than reported — `AthleteStore.resolveRetiredGear` finds gear ids that
/// activities name and the profile no longer holds, and `fetchGear` returns no
/// type. So a retired bike genuinely arrives without a kind, and saying so is
/// the only honest answer available. §12.15, and §12.132's third bucket.
nonisolated enum GearKind: String, Codable, Hashable, CaseIterable, Sendable {
    case shoe
    case bike
    case unknown

    /// For a screen. `unknown` says what it is rather than going blank —
    /// §12.54.2: a row that vanishes cannot be told from one nobody wired in.
    var label: String {
        switch self {
        case .shoe:    "Shoe"
        case .bike:    "Bike"
        case .unknown: "Kind not known"
        }
    }
}
