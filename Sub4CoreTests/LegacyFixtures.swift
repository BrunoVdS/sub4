//
//  LegacyFixtures.swift
//  Sub4CoreTests
//
//  The legacy input corpus — D0 "capture every legacy schema/fixture",
//  patch 246, ADR-0003 §12.13.
//
//  WHAT THIS IS FOR
//  ----------------
//  D3's exit gate reads: "Every known empty/corrupt/partial/duplicate/
//  interrupted fixture produces the expected result." Until this file there
//  were no fixtures at all. Every test in this project built its data in Swift
//  and handed it to the importer as values, which tests the importer and says
//  nothing about the bytes on disk — and the bytes on disk are the entire
//  subject of a migration.
//
//  The migration contract distinguishes six things that all look like "no data"
//  to `try? JSONDecoder().decode(...)`: absent, empty, corrupt, truncated,
//  key-mismatched, and wrongly-dated. `ActivityStore.load()` is one line —
//  `(try? JSONDecoder().decode([Activity].self, from: data)) ?? []` — and it
//  answers all six with an empty array. A fresh install and a half-written file
//  are indistinguishable to it. That is the defect the corpus exists to make
//  testable.
//
//  WHY LITERALS AND NOT FILES
//  --------------------------
//  The project uses file-system-synchronized groups. A `.json` dropped into
//  `Sub4CoreTests/` would be picked up as a resource by rules nobody here has
//  verified, and a fixture that silently fails to copy reads as a fixture that
//  passes. Swift string literals compile or they do not.
//
//  WHY MINIMAL AND NOT REAL
//  ------------------------
//  Each `valid` fixture carries the REQUIRED fields and nothing else. That is
//  deliberate: a fixture with every optional filled in cannot tell you whether
//  the decoder actually treats the optionals as optional, and this is the shape
//  most likely to break when a property loses its `?`. Real data lives on the
//  phone; what is captured here is the contract.
//
//  THE DATE ENCODING IS THE TRAP
//  -----------------------------
//  Migration contract item 4: "notes/proposals use ISO-8601 dates; several
//  other stores use the default numeric `Date` encoding." Getting it backwards
//  does not throw — `.iso8601` applied to `776000000` throws, but numeric
//  applied to an ISO string throws too, and either way the `try?` swallows it
//  and the store comes up empty. Every entry below states which decoder wrote
//  it, and carries a fixture encoded the WRONG way so a decoder mix-up is a
//  test failure rather than an empty screen.
//

import Foundation
@testable import Sub4

// MARK: - The stores

/// One legacy input, as it exists on disk today.
///
/// `path` is relative to Application Support and must match what the store
/// writes — `LegacyFixtureTests` asserts every declared path in
/// `DataLifecycle` has an entry here, so a new store cannot be added without
/// its fixture.
enum LegacyInput: String, CaseIterable {
    case notes
    case proposals
    case activities
    case athlete
    case weather
    case detail
    case streams
    case constants
    case commutes
    case moves
    case legacyDetails
    case legacyStreams

    /// The path under Application Support. The two per-activity stores write a
    /// directory of files named by Strava id; the fixture stands for one file
    /// inside it.
    var path: String {
        switch self {
        case .notes:      "notes.json"
        case .proposals:  "proposals.json"
        case .activities: "activities.json"
        case .athlete:    "athlete.json"
        case .weather:    "weather.json"
        case .detail:     "details/<id>.json"
        case .streams:    "streams/<id>.json"
        case .constants:  "constants.json"
        case .commutes:   "commutes.json"
        case .moves:      "moves.json"
        // The two monolithic files the per-activity split replaced. Still on
        // disk on every device that upgraded through it, still read by
        // `DetailStore.load()`, and listed in the inventory as `.legacyFile`
        // precisely because nothing has ever removed them. A migration that
        // skipped these would leave the full detail history of four app
        // versions behind — which is the failure `details.json` has already
        // caused once, and the reason `AppSupportItem.legacyFile` exists.
        case .legacyDetails: "details.json"
        case .legacyStreams: "streams.json"
        }
    }

    /// Which `JSONDecoder` the store uses. Contract item 4.
    var dates: DateEncoding {
        switch self {
        // Authored data uses ISO-8601 throughout — notes, proposals, and now
        // the commute decisions. The split in contract item 4 is not arbitrary:
        // what the athlete wrote is stored in a form a human can read.
        case .notes, .proposals, .commutes, .moves:  .iso8601
        case .athlete, .weather, .detail, .streams,
             .legacyDetails, .legacyStreams: .numericReferenceDate
        // Activity stores its instants as strings, not `Date`s — see
        // `Activity.startLocal` and `startUTC`. There is no date strategy to
        // get wrong here, and saying so is worth more than leaving it implied.
        //
        // `AthleteConstants` joins `Activity` here for the same reason: it
        // holds no `Date`. Its figures are months (`"2026-07"`) and day keys,
        // stored as strings because that is what they mean.
        case .activities, .constants: .noneStored
        }
    }

    enum DateEncoding: Equatable {
        case iso8601
        case numericReferenceDate
        case noneStored
    }

    /// The outer JSON container, which decides which damage classes apply.
    var container: Container {
        switch self {
        case .notes, .weather,
             .legacyDetails, .legacyStreams:    .dictionaryKeyedByID
        case .proposals, .activities:           .array
        case .commutes, .moves:                 .dictionaryKeyedByID
        case .athlete, .detail, .streams,
             .constants:                        .object
        }
    }

    enum Container { case dictionaryKeyedByID, array, object }

    /// The smallest file the store's decoder accepts: required fields only.
    var valid: String {
        switch self {

        case .notes:
            // [String: NotesStore.Note] · ISO-8601
            """
            {"w03-tue":{"sessionUid":"w03-tue","text":"Legs fine.",\
            "created":"2026-08-01T06:12:00Z","edited":"2026-08-01T06:12:00Z"}}
            """

        case .proposals:
            // [ProposalStore.Record] · ISO-8601
            """
            [{"id":"2026-07-01_2026-07-31_1","ranAt":"2026-08-01T06:12:00Z",\
            "windowLabel":"July 2026","startDay":"2026-07-01","endDay":"2026-07-31",\
            "evidence":"# Evidence\\n\\nNothing notable.","appVersion":"1.0 (3) · patch 246",\
            "model":"fixture","proposal":{"verdict":"no_change",\
            "summary":"The block is landing.","reasoning":"Nothing moved.",\
            "changes":[],"watchFor":[],"confidence":3}}]
            """

        case .activities:
            // [Activity] · no Date fields at all
            """
            [{"id":"11111111","name":"Morning Run","sportType":"Run",\
            "startLocal":"2026-07-28T09:24:06","distance":10000.0,\
            "movingTime":3000,"elapsedTime":3100}]
            """

        case .athlete:
            // AthleteStore.Cache · numeric · decoded by `AthleteFile` since
            // patch 259. Until then `Cache` was `private` and this fixture
            // could only be asserted structurally — see `AthleteFileTests`.
            """
            {"zones":[{"index":1,"min":0,"max":120},{"index":5,"min":171}],\
            "shoes":[{"id":"g11111","name":"Novablast 4","distanceM":412000.0,\
            "primary":true}],"fetched":776000000.0,"ftp":270}
            """

        case .weather:
            // [String: ActivityWeather] · numeric
            """
            {"11111111":{"activityId":"11111111","tempC":14.2,"feelsLikeC":13.1,\
            "humidity":0.78,"windKmh":11.0,"windFromDegrees":225.0,\
            "precipitationMm":0.0,"symbolName":"cloud","conditionLabel":"Cloudy",\
            "samples":3,"fetched":776000000.0}}
            """

        case .detail:
            // ActivityDetail · numeric
            """
            {"activityId":"11111111","splits":[{"index":1,"distanceM":1000.0,\
            "movingTime":300,"elapsedTime":305}],"laps":[{"index":1,\
            "distanceM":10000.0,"movingTime":3000}],"bestEfforts":[{"name":"5k",\
            "seconds":1450}],"fetched":776000000.0}
            """

        case .streams:
            // ActivityStreams · numeric
            """
            {"activityId":"11111111","distanceM":[0.0,100.0,200.0,300.0,400.0,\
            500.0,600.0,700.0],"fetched":776000000.0}
            """

        case .constants:
            // AthleteConstants · no Date fields
            //
            // `restByMonth`, `sexCoefficient` and `version` are NOT optional
            // and carry Swift default values — which the synthesised
            // `init(from:)` does not use. A `constants.json` written before any
            // one of them existed fails to decode ENTIRELY, taking the typed
            // maximum and the whole resting series with it. That is a real
            // upgrade hazard and this fixture is the thing that will notice
            // when a fourth such property is added.
            """
            {"restByMonth":{"2026-07":48},"sexCoefficient":1.92,"version":1}
            """

        case .commutes:
            // [String: CommuteDecision] · ISO-8601
            //
            // The key is the activity id and so is the embedded `activityId`,
            // which is why this store gets a key-mismatch fixture below: the
            // same trap notes and weather carry.
            """
            {"19608576674":{"activityId":"19608576674","isCommute":true,\
            "decided":"2026-08-05T09:12:00Z"}}
            """

        case .moves:
            // [String: PlanMove] · ISO-8601
            //
            // `movedTo` is a STRING and `decided` is a `Date`, which is the
            // whole shape of this store: the day is the plan's own vocabulary
            // and the instant is when the athlete said so. A fixture that made
            // both dates would not exercise the pairing.
            """
            {"w03-sun-long":{"sessionUid":"w03-sun-long",\
            "movedTo":"2026-08-17","decided":"2026-08-17T18:40:00Z"}}
            """

        case .legacyDetails:
            // [String: ActivityDetail] · numeric · the pre-split monolith
            """
            {"11111111":{"activityId":"11111111","splits":[{"index":1,\
            "distanceM":1000.0,"movingTime":300,"elapsedTime":305}],"laps":[],\
            "bestEfforts":[],"fetched":776000000.0}}
            """

        case .legacyStreams:
            // [String: ActivityStreams] · numeric · the pre-split monolith
            """
            {"11111111":{"activityId":"11111111","distanceM":[0.0,100.0,200.0,\
            300.0,400.0,500.0,600.0,700.0],"fetched":776000000.0}}
            """
        }
    }

    /// The same content written with the OTHER date strategy. Nil where the
    /// store holds no `Date` — see `.activities`.
    ///
    /// This is the fixture that catches contract item 4 being got backwards,
    /// and it is the one that would have been most useful to have: a decoder
    /// mix-up produces an empty store, and an empty store on a fresh install is
    /// correct behaviour. The two are indistinguishable without this.
    var validWithTheOtherDateEncoding: String? {
        switch self {
        case .notes:
            """
            {"w03-tue":{"sessionUid":"w03-tue","text":"Legs fine.",\
            "created":776000000.0,"edited":776000000.0}}
            """
        case .proposals:
            """
            [{"id":"2026-07-01_2026-07-31_1","ranAt":776000000.0,\
            "windowLabel":"July 2026","startDay":"2026-07-01","endDay":"2026-07-31",\
            "evidence":"# Evidence\\n\\nNothing notable.","appVersion":"1.0 (3) · patch 246",\
            "model":"fixture","proposal":{"verdict":"no_change",\
            "summary":"The block is landing.","reasoning":"Nothing moved.",\
            "changes":[],"watchFor":[],"confidence":3}}]
            """
        case .athlete:
            """
            {"zones":[{"index":1,"min":0,"max":120},{"index":5,"min":171}],\
            "shoes":[{"id":"g11111","name":"Novablast 4","distanceM":412000.0,\
            "primary":true}],"fetched":"2026-08-01T06:12:00Z","ftp":270}
            """
        case .weather:
            """
            {"11111111":{"activityId":"11111111","tempC":14.2,"feelsLikeC":13.1,\
            "humidity":0.78,"windKmh":11.0,"windFromDegrees":225.0,\
            "precipitationMm":0.0,"symbolName":"cloud","conditionLabel":"Cloudy",\
            "samples":3,"fetched":"2026-08-01T06:12:00Z"}}
            """
        case .detail:
            """
            {"activityId":"11111111","splits":[{"index":1,"distanceM":1000.0,\
            "movingTime":300,"elapsedTime":305}],"laps":[{"index":1,\
            "distanceM":10000.0,"movingTime":3000}],"bestEfforts":[{"name":"5k",\
            "seconds":1450}],"fetched":"2026-08-01T06:12:00Z"}
            """
        case .streams:
            """
            {"activityId":"11111111","distanceM":[0.0,100.0,200.0,300.0,400.0,\
            500.0,600.0,700.0],"fetched":"2026-08-01T06:12:00Z"}
            """
        case .commutes:
            """
            {"19608576674":{"activityId":"19608576674","isCommute":true,\
            "decided":776000000.0}}
            """
        case .moves:
            // The one that catches contract item 4 being got backwards on this
            // store: `movedTo` still parses, so a decoder mix-up would leave a
            // file that looks right and holds nothing.
            """
            {"w03-sun-long":{"sessionUid":"w03-sun-long",\
            "movedTo":"2026-08-17","decided":776000000.0}}
            """
        case .legacyDetails:
            """
            {"11111111":{"activityId":"11111111","splits":[{"index":1,\
            "distanceM":1000.0,"movingTime":300,"elapsedTime":305}],"laps":[],\
            "bestEfforts":[],"fetched":"2026-08-01T06:12:00Z"}}
            """
        case .legacyStreams:
            """
            {"11111111":{"activityId":"11111111","distanceM":[0.0,100.0,200.0,\
            300.0,400.0,500.0,600.0,700.0],"fetched":"2026-08-01T06:12:00Z"}}
            """
        case .activities, .constants:
            nil
        }
    }

    /// The outer key disagrees with the embedded id. Contract item 5 says
    /// quarantine, not pick one — and picking one is what every store does
    /// today, silently, because the dictionary key is the only thing it reads.
    ///
    /// Nil for the containers where the question does not arise.
    var keyMismatch: String? {
        switch self {
        case .notes:
            """
            {"w99-sun":{"sessionUid":"w03-tue","text":"Legs fine.",\
            "created":"2026-08-01T06:12:00Z","edited":"2026-08-01T06:12:00Z"}}
            """
        case .weather:
            """
            {"99999999":{"activityId":"11111111","tempC":14.2,"feelsLikeC":13.1,\
            "humidity":0.78,"windKmh":11.0,"windFromDegrees":225.0,\
            "precipitationMm":0.0,"symbolName":"cloud","conditionLabel":"Cloudy",\
            "samples":3,"fetched":776000000.0}}
            """
        case .commutes:
            """
            {"99999999":{"activityId":"19608576674","isCommute":true,\
            "decided":"2026-08-05T09:12:00Z"}}
            """
        case .moves:
            """
            {"w99-sat-rest":{"sessionUid":"w03-sun-long",\
            "movedTo":"2026-08-17","decided":"2026-08-17T18:40:00Z"}}
            """
        case .legacyDetails:
            """
            {"99999999":{"activityId":"11111111","splits":[{"index":1,\
            "distanceM":1000.0,"movingTime":300,"elapsedTime":305}],"laps":[],\
            "bestEfforts":[],"fetched":776000000.0}}
            """
        case .legacyStreams:
            """
            {"99999999":{"activityId":"11111111","distanceM":[0.0,100.0,200.0,\
            300.0,400.0,500.0,600.0,700.0],"fetched":776000000.0}}
            """
        default:
            nil
        }
    }

    /// Two entries claiming the same identity. Legal JSON, illegal domain.
    var duplicate: String? {
        switch self {
        case .activities:
            """
            [{"id":"11111111","name":"Morning Run","sportType":"Run",\
            "startLocal":"2026-07-28T09:24:06","distance":10000.0,\
            "movingTime":3000,"elapsedTime":3100},\
            {"id":"11111111","name":"Morning Run (duplicate)","sportType":"Run",\
            "startLocal":"2026-07-28T09:24:06","distance":10000.0,\
            "movingTime":3000,"elapsedTime":3100}]
            """
        case .proposals:
            """
            [{"id":"2026-07-01_2026-07-31_1","ranAt":"2026-08-01T06:12:00Z",\
            "windowLabel":"July 2026","startDay":"2026-07-01","endDay":"2026-07-31",\
            "evidence":"a","appVersion":"p246","model":"fixture",\
            "proposal":{"verdict":"no_change","summary":"s","reasoning":"r",\
            "changes":[],"watchFor":[],"confidence":3}},\
            {"id":"2026-07-01_2026-07-31_1","ranAt":"2026-08-01T06:12:00Z",\
            "windowLabel":"July 2026","startDay":"2026-07-01","endDay":"2026-07-31",\
            "evidence":"b","appVersion":"p246","model":"fixture",\
            "proposal":{"verdict":"no_change","summary":"s","reasoning":"r",\
            "changes":[],"watchFor":[],"confidence":3}}]
            """
        default:
            nil
        }
    }
}

// MARK: - The damage classes

/// The six ways a legacy file arrives wrong, plus the two that are correct.
///
/// Every one of these currently produces the same observable result — an empty
/// store — and telling them apart is what patch 248 is for. Named here so the
/// vocabulary exists before the code that uses it, the same way every frozen
/// vocabulary in this schema does.
enum LegacyDamage: String, CaseIterable {
    /// Correct, and must decode.
    case valid
    /// No file at all. A fresh install. NOT an error — contract item 2.
    case absent
    /// Zero bytes. A write that was interrupted before anything was flushed.
    case empty
    /// Whitespace only. Same cause, one buffer later.
    case whitespace
    /// Cut off mid-object. The classic interrupted write, and the one the
    /// project has actually seen: two reinstalls this week.
    case truncated
    /// Structurally broken JSON that is not merely short.
    case corrupt
    /// Not JSON at all. A captive portal's HTML body written where a response
    /// was expected — the failure that looks like data until you open it.
    case notJSON
    /// Decodes, but with the wrong date strategy. Contract item 4.
    case wrongDateEncoding
    /// Outer key disagrees with the embedded id. Contract item 5.
    case keyMismatch
    /// Two rows, one identity.
    case duplicate

    /// Whether the store's own decoder should succeed on this. `absent` has no
    /// bytes to hand it, so it is excluded from decode tests and belongs to the
    /// classifier instead.
    var shouldDecode: Bool {
        switch self {
        case .valid, .keyMismatch, .duplicate: true
        case .absent, .empty, .whitespace, .truncated,
             .corrupt, .notJSON, .wrongDateEncoding: false
        }
    }

    /// The bytes for a given input, or nil where the class does not apply to
    /// that input's container — an array has no outer key to mismatch.
    func bytes(for input: LegacyInput) -> Data? {
        switch self {
        case .valid:      Data(input.valid.utf8)
        case .absent:     nil
        case .empty:      Data()
        case .whitespace: Data("   \n\t\n".utf8)
        case .truncated:  Self.truncate(input.valid)
        case .corrupt:    Self.corrupt(input.valid)
        case .notJSON:
            Data("""
                 <!DOCTYPE html><html><head><title>Sign in to continue</title>\
                 </head><body>You must accept the terms.</body></html>
                 """.utf8)
        case .wrongDateEncoding:
            input.validWithTheOtherDateEncoding.map { Data($0.utf8) }
        case .keyMismatch: input.keyMismatch.map { Data($0.utf8) }
        case .duplicate:   input.duplicate.map { Data($0.utf8) }
        }
    }

    /// Sixty per cent of the bytes. Enough to be recognisably the right file
    /// and impossible to decode — which is exactly what a partial write is.
    private static func truncate(_ json: String) -> Data {
        let all = Array(json.utf8)
        return Data(all.prefix(max(1, all.count * 6 / 10)))
    }

    /// Break the structure without shortening it. A file this size that fails
    /// to parse is not a partial write, and a classifier that cannot tell those
    /// apart will tell the athlete to restore a backup he does not need.
    private static func corrupt(_ json: String) -> Data {
        Data(json.replacingOccurrences(of: "\":", with: "\"=").utf8)
    }
}
