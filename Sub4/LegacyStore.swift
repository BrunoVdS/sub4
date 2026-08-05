//
//  LegacyStore.swift
//  Sub4
//
//  The eleven legacy inputs, as the APP sees them — step 3.4, patch 260,
//  migration contract item 4.
//
//  WHY THIS ENUM IS IN THE APP AND NOT IN THE TESTS
//  ------------------------------------------------
//  `LegacyInput` in `Sub4CoreTests` has held this knowledge since patch 246:
//  which file, which decoder, which container. That was the right place for it
//  while nothing in the app read these files as bytes. It is the wrong place
//  now, because the reader is app code and a test enum cannot be its source of
//  truth.
//
//  So the declaration moves here and `LegacyInput` becomes what it always
//  should have been — the fixture corpus for it.
//  `LegacyStoreCoverageTests.theTwoEnumerationsAgree` asserts the two are in
//  bijection, so a store added to one and not the other is a build-time
//  failure rather than an input nobody tests.
//
//  THE DECODER IS PART OF THE DECLARATION — CONTRACT ITEM 4
//  -------------------------------------------------------
//  Item 4 exists because one global decoder is wrong for this app: what the
//  athlete WROTE is stored in ISO-8601 so a human can read it, and what Strava
//  handed over is stored as a `Double` counting seconds from 2001 because a
//  bare `JSONEncoder` was what the store used at the time. Neither is a
//  mistake. Reading one with the other's decoder does not produce a wrong
//  date — it throws, and that is the whole reason to state the pairing per
//  store rather than guess once.
//
//  Two inputs store no `Date` at all. `activities.json` keeps its instants as
//  strings (`Activity.startLocal`, `startUTC`) and `constants.json` keeps
//  months (`"2026-07"`) and day keys. They are declared `.noneStored` rather
//  than defaulted, because "there is no date here" is a fact worth stating and
//  a decoder chosen by accident is one nobody will question.
//

import Foundation

nonisolated enum LegacyStore: String, CaseIterable, Hashable {
    case notes
    case proposals
    case activities
    case athlete
    case weather
    case detail
    case streams
    case constants
    case commutes
    /// The pre-split monolith. Still on disk on every device that upgraded
    /// through the per-activity split, and the reason `AppSupportItem` has a
    /// `.legacyFile` case at all.
    case legacyDetails
    case legacyStreams

    // MARK: Where it lives

    /// Where the file sits under Application Support, in the vocabulary
    /// `DataLifecycle` already uses. Two of these are directories holding one
    /// file per activity; the reader takes bytes, so it does not care, but the
    /// quarantine that follows will.
    var item: AppSupportItem {
        switch self {
        case .notes:         .file("notes.json")
        case .proposals:     .file("proposals.json")
        case .activities:    .file("activities.json")
        case .athlete:       .file("athlete.json")
        case .weather:       .file("weather.json")
        case .constants:     .file("constants.json")
        case .commutes:      .file("commutes.json")
        case .detail:        .directory("details")
        case .streams:       .directory("streams")
        case .legacyDetails: .legacyFile("details.json")
        case .legacyStreams: .legacyFile("streams.json")
        }
    }

    // MARK: How it is written

    nonisolated enum DateStrategy: Equatable {
        /// What the athlete authored. Readable by anything, including whatever
        /// ends up doing the monthly review.
        case iso8601
        /// A `Double` counting seconds from 2001 — what a bare `JSONEncoder`
        /// produces, and what every Strava-derived store has always used.
        case numericReferenceDate
        /// The file holds no `Date`. Stated rather than implied.
        case noneStored
    }

    var dates: DateStrategy {
        switch self {
        case .notes, .proposals, .commutes: .iso8601
        case .athlete, .weather, .detail, .streams,
             .legacyDetails, .legacyStreams: .numericReferenceDate
        case .activities, .constants: .noneStored
        }
    }

    /// The outer JSON container. Not decoration: a file that parses but is an
    /// array where an object was expected is a different fault from one that
    /// does not parse, and telling the athlete to restore a backup for the
    /// wrong reason is worse than saying nothing.
    nonisolated enum Container: String, Equatable {
        case object
        case array
    }

    var container: Container {
        switch self {
        case .proposals, .activities: .array
        case .notes, .weather, .commutes, .athlete, .detail,
             .streams, .constants, .legacyDetails, .legacyStreams: .object
        }
    }

    /// THE ONLY DECODER THAT MAY READ THIS STORE.
    ///
    /// `.noneStored` gets a bare decoder because there is nothing for a date
    /// strategy to affect — not because none was chosen.
    var decoder: JSONDecoder {
        let d = JSONDecoder()
        switch dates {
        case .iso8601:              d.dateDecodingStrategy = .iso8601
        case .numericReferenceDate: d.dateDecodingStrategy = .deferredToDate
        case .noneStored:           break
        }
        return d
    }

    /// For the screen, and for a diagnostic line. The file name rather than
    /// the type, because that is what somebody looking at this would recognise.
    var displayName: String { item.displayName }
}
