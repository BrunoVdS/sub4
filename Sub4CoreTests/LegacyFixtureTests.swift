//
//  LegacyFixtureTests.swift
//  Sub4CoreTests
//
//  What the corpus proves today — D0, patch 246, ADR-0003 §12.13.
//
//  There are two kinds of assertion here and they answer different questions.
//
//  1. THE SCHEMA IS CAPTURED. Every `valid` fixture decodes through the store's
//     own decoder. If a property loses its `?`, or a key is renamed, or a
//     store's date strategy is changed, the fixture stops decoding and this
//     fails — which is precisely the event that would otherwise be discovered
//     as an empty screen after an upgrade.
//
//  2. THE DAMAGE CLASSES ARE INDISTINGUISHABLE TODAY. Empty, truncated,
//     corrupt and wrongly-dated all fail the same way, through the same
//     `try?`, into the same empty store. These tests assert that as the CURRENT
//     behaviour rather than pretending otherwise. Patch 248 replaces them with
//     assertions about the classifier, and the diff between the two is the
//     honest measure of what 248 bought.
//
//  A test that asserts today's defect is a liability if nobody remembers why it
//  is there — §12.12.4 cost this project one repointed test on exactly that.
//  So: these are named `todayEverythingBrokenLooksTheSame` on purpose. When
//  they fail, 248 has landed and they should be rewritten, not restored.
//

import Testing
import Foundation
@testable import Sub4

/// `@MainActor` on the suite, and it is not decoration.
///
/// The app targets build with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the
/// test target does not. So every type this file decodes — `Activity`,
/// `NotesStore.Note`, `ProposalStore.Record`, `ActivityWeather`,
/// `ActivityDetail` — is MainActor-isolated over there while this file is
/// nonisolated over here. Isolating the suite is the cheap correct answer.
/// Marking five app types `nonisolated` to suit a test would be the expensive
/// wrong one, and this project has already paid for `nonisolated` applied as
/// tidiness rather than as a claim — six times.
@Suite
@MainActor
struct LegacyFixtureTests {

    // MARK: Coverage — no store without a fixture

    /// What `DataLifecycle` says each input is called on disk.
    private var declaredComponent: [LegacyInput: String] {
        [.notes: "notes.json", .proposals: "proposals.json",
         .activities: "activities.json", .athlete: "athlete.json",
         .weather: "weather.json", .detail: "details", .streams: "streams",
         .constants: "constants.json",
         .legacyDetails: "details.json", .legacyStreams: "streams.json"]
    }

    @Test("Every legacy path DataLifecycle declares has a fixture")
    func theCorpusCoversTheInventory() {
        var declared = Set<String>()
        for entry in DataLifecycle.entries {
            for location in entry.storage {
                guard case .applicationSupport(let item) = location else { continue }
                switch item {
                case .file(let f):          declared.insert(f)
                case .legacyFile(let f):    declared.insert(f)
                case .directory(let d):     declared.insert(d)
                // The database is this migration's destination, not its input.
                case .databaseDirectory:    break
                }
            }
        }
        let covered = Set(declaredComponent.values)
        let missing = declared.subtracting(covered).sorted()
        #expect(missing.isEmpty,
                """
                    these legacy inputs have no fixture: \(missing.joined(separator: ", ")). \
                    Add a case to LegacyInput before the importer learns to read them.
                    """)
    }

    @Test("Every fixture points at something the inventory declares")
    func theCorpusInventsNothing() {
        var declared = Set<String>()
        for entry in DataLifecycle.entries {
            for location in entry.storage {
                guard case .applicationSupport(let item) = location else { continue }
                declared.insert(item.pathComponent)
            }
        }
        for (input, component) in declaredComponent {
            #expect(declared.contains(component),
                    """
                        \(input.rawValue) claims \(component), which DataLifecycle \
                        does not declare — one of the two is stale
                        """)
        }
    }

    // MARK: The decoders

    private var iso: JSONDecoder { JSONDecoder.sub4 }
    private var numeric: JSONDecoder { JSONDecoder() }

    /// Decode a fixture through the decoder its store actually uses. Throws
    /// exactly what the store's `try?` would have swallowed.
    private func decode(_ input: LegacyInput, _ data: Data) throws {
        switch input {
        case .notes:      _ = try iso.decode([String: NotesStore.Note].self, from: data)
        case .proposals:  _ = try iso.decode([ProposalStore.Record].self, from: data)
        case .activities: _ = try numeric.decode([Activity].self, from: data)
        case .weather:    _ = try numeric.decode([String: ActivityWeather].self, from: data)
        case .detail:     _ = try numeric.decode(ActivityDetail.self, from: data)
        case .streams:    _ = try numeric.decode(ActivityStreams.self, from: data)
        case .constants:  _ = try numeric.decode(AthleteConstants.self, from: data)
        case .legacyDetails:
            _ = try numeric.decode([String: ActivityDetail].self, from: data)
        case .legacyStreams:
            _ = try numeric.decode([String: ActivityStreams].self, from: data)
        case .athlete:
            // `AthleteStore.Cache` is `private`. See the dedicated test below —
            // this is a finding, not an omission.
            _ = try JSONSerialization.jsonObject(with: data)
        }
    }

    @Test("Every valid fixture decodes through its own store's decoder",
          arguments: LegacyInput.allCases)
    func theValidFixtureDecodes(_ input: LegacyInput) throws {
        let data = try #require(LegacyDamage.valid.bytes(for: input))
        try decode(input, data)
    }

    @Test("The wrong date strategy fails — it does not quietly produce 1970",
          arguments: LegacyInput.allCases)
    func theWrongDateEncodingIsRejected(_ input: LegacyInput) throws {
        guard let data = LegacyDamage.wrongDateEncoding.bytes(for: input) else {
            // `.activities` and `.constants` store no Date at all. Nothing to
            // get backwards, and nothing to write a wrong-encoding fixture of.
            #expect(input == .activities || input == .constants,
                    """
                        \(input.rawValue) has a Date somewhere and no \
                        wrong-encoding fixture — contract item 4 is untested for it
                        """)
            return
        }
        guard input != .athlete else {
            // Decoded as untyped JSON here, so the strategy never applies.
            return
        }
        #expect(throws: (any Error).self) { try decode(input, data) }
    }

    @Test("A key mismatch decodes cleanly — which is the problem",
          arguments: [LegacyInput.notes, .weather, .legacyDetails, .legacyStreams])
    func aKeyMismatchIsInvisibleToTheDecoder(_ input: LegacyInput) throws {
        let data = try #require(LegacyDamage.keyMismatch.bytes(for: input))
        // Contract item 5 wants this quarantined. Today it decodes, the outer
        // key wins, and the embedded id is never consulted. Patch 248 makes
        // this a quarantine; until then the behaviour is recorded, not hidden.
        try decode(input, data)
    }

    @Test("Two rows with one identity decode as two rows",
          arguments: [LegacyInput.activities, .proposals])
    func aDuplicateIsInvisibleToTheDecoder(_ input: LegacyInput) throws {
        let data = try #require(LegacyDamage.duplicate.bytes(for: input))
        try decode(input, data)
        if input == .activities {
            let rows = try numeric.decode([Activity].self, from: data)
            #expect(rows.count == 2)
            #expect(Set(rows.map(\.id)).count == 1,
                    "the duplicate fixture stopped being a duplicate")
        }
    }

    // MARK: Today's behaviour, asserted so tomorrow's change is visible

    @Test("Today every broken file fails the same way — nothing is classified",
          arguments: LegacyInput.allCases)
    func todayEverythingBrokenLooksTheSame(_ input: LegacyInput) throws {
        // Read this file's header before touching this test.
        for damage in [LegacyDamage.empty, .whitespace, .truncated, .corrupt, .notJSON] {
            let data = try #require(damage.bytes(for: input),
                                    "\(damage.rawValue) has no bytes for \(input.rawValue)")
            #expect(throws: (any Error).self, "\(damage.rawValue) decoded, which it should not") {
                try decode(input, data)
            }
        }
    }

    @Test("An absent file has no bytes — it is not an empty one")
    func absentIsNotEmpty() {
        for input in LegacyInput.allCases {
            #expect(LegacyDamage.absent.bytes(for: input) == nil)
            #expect(LegacyDamage.empty.bytes(for: input)?.isEmpty == true)
        }
        // Contract item 2: absent can mean a fresh install and must not block
        // activation; present-but-undecodable must. The two are different bytes
        // and, from patch 248, different outcomes.
    }

    @Test("Truncated is recognisably the right file, and still undecodable")
    func truncationIsPartialNotEmpty() throws {
        for input in LegacyInput.allCases {
            let full = try #require(LegacyDamage.valid.bytes(for: input))
            let cut = try #require(LegacyDamage.truncated.bytes(for: input))
            #expect(cut.count > 0)
            #expect(cut.count < full.count)
            #expect(full.starts(with: cut),
                    """
                        \(input.rawValue): truncation must be a prefix of the whole \
                        file — that is what makes it recognisable
                        """)
        }
    }

    @Test("Corruption is not truncation — same length, broken structure")
    func corruptionKeepsItsLength() throws {
        for input in LegacyInput.allCases {
            let full = try #require(LegacyDamage.valid.bytes(for: input))
            let broken = try #require(LegacyDamage.corrupt.bytes(for: input))
            #expect(broken.count == full.count,
                    """
                        \(input.rawValue): the corrupt fixture changed length, so a \
                        classifier could tell it from truncation by size alone — \
                        which would make the test easier than the problem
                        """)
        }
    }

    // MARK: The findings this corpus produced

    @Test("athlete.json has no decodable type outside its own store")
    func athleteCannotBeDecodedFromOutsideItsStore() throws {
        // `AthleteStore.Cache` is `private`, so `@testable import` does not
        // reach it and neither will a file-level decoder. This is why
        // `Sub4Import+Athlete` reads the live store rather than the file, and
        // it is a real obstacle to migration contract item 3: patch 248 needs
        // a non-private mirror of this shape before it can read athlete.json
        // as bytes.
        //
        // Recorded as a test so the constraint is discovered here rather than
        // halfway through writing 248.
        let data = try #require(LegacyDamage.valid.bytes(for: .athlete))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(try #require(object).keys)
        #expect(keys == ["zones", "shoes", "fetched", "ftp"],
                "athlete.json's top-level shape changed: \(keys.sorted())")
    }

    @Test("The corpus states which decoder wrote each file")
    func everyInputDeclaresItsDateStrategy() {
        // Migration contract item 4, made explicit. The grouping below is the
        // claim; the decode tests above are the proof.
        #expect(LegacyInput.notes.dates == .iso8601)
        #expect(LegacyInput.proposals.dates == .iso8601)
        #expect(LegacyInput.athlete.dates == .numericReferenceDate)
        #expect(LegacyInput.weather.dates == .numericReferenceDate)
        #expect(LegacyInput.detail.dates == .numericReferenceDate)
        #expect(LegacyInput.streams.dates == .numericReferenceDate)
        #expect(LegacyInput.legacyDetails.dates == .numericReferenceDate)
        #expect(LegacyInput.legacyStreams.dates == .numericReferenceDate)
        #expect(LegacyInput.activities.dates == .noneStored)
        #expect(LegacyInput.constants.dates == .noneStored)
    }
}
