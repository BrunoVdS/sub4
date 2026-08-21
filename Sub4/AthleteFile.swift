//
//  AthleteFile.swift
//  Sub4
//
//  `athlete.json`, readable as bytes — step 3.4, patch 259, migration contract
//  items 3 and 4.
//
//  WHY THIS FILE EXISTS AT ALL
//  --------------------------
//  `LegacyFixtureTests.athleteCannotBeDecodedFromOutsideItsStore` recorded the
//  obstacle in patch 246, before anything depended on it: `AthleteStore.Cache`
//  was `private`, so nothing — not the file-level decoders, not the semantic
//  verifier, not `@testable import` — could decode `athlete.json`. Every other
//  legacy input has a type that can be handed a `Data`. This one had a store
//  and nothing else.
//
//  That test has been paying for itself since: the constraint was discovered
//  when it cost one line to write down rather than halfway through the patch
//  that needed it.
//
//  A MIRROR, NOT A PROMOTION — AND THE REASON IS ISOLATION
//  ------------------------------------------------------
//  The obvious fix is to drop `private` from `Cache` and decode that. `Cache`
//  is nested in `AthleteStore`, which is `@Observable final class` under
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — so `Cache` and its
//  `Codable` conformance are main-actor isolated, and the reader that will use
//  this runs `nonisolated`, inside a database write. Patch 258 is the whole
//  story of what that costs: three warnings that no test stopped for.
//
//  So `Cache` becomes internal (it had no reason to be private beyond habit)
//  and this type mirrors it with its own `nonisolated` shapes. The mirror is
//  what the reader decodes; `Cache` stays what the store writes.
//
//  THE DRIFT IS THE OBVIOUS OBJECTION, AND IT IS ANSWERED BY A TEST
//  ---------------------------------------------------------------
//  Two declarations of one shape is two things to keep in step, and nothing in
//  Swift makes them agree. `AthleteFileTests.theMirrorMatchesWhatTheStoreWrites`
//  encodes a real `AthleteStore.Cache` and decodes it as an `AthleteFile`,
//  field by field. Add a property to one and that test fails, which is the only
//  form of "keep these in step" worth writing down.
//
//  THE DATE STRATEGY IS PART OF THE SHAPE — CONTRACT ITEM 4
//  -------------------------------------------------------
//  `AthleteStore.save()` uses a bare `JSONEncoder()`, so `fetched` is a
//  `Double` counting seconds from 2001 — `.deferredToDate`, not ISO-8601.
//  Reading it with the app's own `JSONDecoder.sub4` does not produce a wrong
//  date; it throws, which is the good outcome and the one
//  `theWrongStrategyThrowsRatherThanInventingADate` holds in place.
//
//  Item 4 exists because the alternative is a decoder that succeeds and is
//  wrong. `decoder` below is the only one that may read this file.
//

import Foundation

/// The on-disk shape of `athlete.json`, decodable without the main actor.
nonisolated struct AthleteFile: Codable, Hashable {

    /// Mirrors `AthleteStore.HRZone` — the stored properties only. `label`,
    /// `range` and `contains` are presentation and belong to the store's type;
    /// a mirror that copied them would be a second implementation of the same
    /// rules, which is a worse problem than the duplication it saved.
    nonisolated struct Zone: Codable, Hashable {
        let index: Int
        let min: Int
        /// nil = the open-ended top zone.
        let max: Int?
    }

    /// Mirrors `AthleteStore.Shoe`, stored properties only.
    nonisolated struct Shoe: Codable, Hashable {
        let id: String
        let name: String
        let distanceM: Double
        let primary: Bool
        /// PATCH 425, D7 slice B5. Optional for the reason every other optional
        /// in this file is optional: a synthesised `init(from:)` ignores Swift
        /// defaults, so a non-optional here would fail to decode every
        /// `athlete.json` written before today.
        ///
        /// **THE MIRROR CARRIES IT EVEN THOUGH THE MIRROR CANNOT USE IT.**
        /// `AthleteFileAgreementTests` holds this declaration field by field
        /// against `AthleteStore.Cache`; a mirror missing a field is a mirror
        /// that silently drops it on the way through a nonisolated decode.
        let kind: GearKind?
    }

    var zones: [Zone]
    var shoes: [Shoe]
    /// Patch 267. Optional for the same reason as `AthleteStore.Cache.bikes`:
    /// every file written before today is missing the key, and a synthesised
    /// decoder does not use default values.
    var bikes: [Shoe]?
    /// Patch 268. Same optionality, same reason.
    var retired: [Shoe]?
    /// When the athlete profile was last fetched from Strava. Seconds from
    /// 2001 on disk — see `decoder`.
    var fetched: Date?
    var ftp: Int?

    /// THE ONLY DECODER THAT MAY READ `athlete.json`.
    ///
    /// `.deferredToDate` because `AthleteStore.save()` uses a bare
    /// `JSONEncoder()` and always has. This is not a preference; it is a fact
    /// about thirteen months of files already on disk, and contract item 4 is
    /// the requirement to state it per store rather than guess once globally.
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }

    /// Matches `AthleteStore.save()` exactly, for round-tripping in tests. Not
    /// used to write the real file — the store owns that, and two writers of
    /// one file is the defect this type is careful not to become.
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate
        return e
    }

    static func read(_ data: Data) throws -> AthleteFile {
        try decoder.decode(AthleteFile.self, from: data)
    }
}
