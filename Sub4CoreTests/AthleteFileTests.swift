//
//  AthleteFileTests.swift
//  Sub4CoreTests
//
//  `athlete.json` as bytes — patch 259, migration contract item 4.
//
//  Patch 246 wrote down that this file could not be decoded from outside its
//  own store, as a test, before anything needed it to be. This is the patch
//  that needed it. What follows is the two obligations that come with a mirror:
//  that it AGREES with the thing it mirrors, and that it is worth having —
//  meaning it decodes where the original could not.
//

import Testing
import Foundation
@testable import Sub4

// MARK: - The drift guard

/// `@MainActor`, because it builds a real `AthleteStore.Cache` — which stays
/// main-actor isolated, and is the reason `AthleteFile` exists rather than
/// `Cache` simply being made internal.
@Suite
@MainActor
struct AthleteFileAgreementTests {

    @Test("The mirror matches what the store writes, field for field")
    func theMirrorMatchesWhatTheStoreWrites() throws {
        // Encoded with a bare `JSONEncoder`, because that is literally what
        // `AthleteStore.save()` does. If the store ever changes its encoder,
        // this test is what notices.
        let cache = AthleteStore.Cache(
            zones: [.init(index: 1, min: 0, max: 120),
                    .init(index: 5, min: 171, max: nil)],
            shoes: [.init(id: "g11111", name: "Novablast 4",
                          distanceM: 412_000, primary: true)],
            bikes: [.init(id: "b6932581", name: "Gravel",
                          distanceM: 5_680_000, primary: true)],
            fetched: Date(timeIntervalSince1970: 776_000_000),
            ftp: 270)

        let data = try JSONEncoder().encode(cache)
        let file = try AthleteFile.read(data)

        #expect(file.ftp == cache.ftp)
        #expect(file.fetched == cache.fetched)

        #expect(file.zones.count == cache.zones.count)
        #expect(file.zones.map(\.index) == cache.zones.map(\.index))
        #expect(file.zones.map(\.min) == cache.zones.map(\.min))
        // The open-ended top zone: nil has to survive as nil, not as 0.
        #expect(file.zones.map(\.max) == cache.zones.map(\.max))

        // Patch 267. The bikes have to survive the mirror too, or 356
        // activities go back to naming gear nothing holds.
        #expect(file.bikes?.count == cache.bikes?.count)
        #expect(file.bikes?.first?.id == "b6932581")
        #expect(file.bikes?.first?.distanceM == 5_680_000)

        #expect(file.shoes.count == cache.shoes.count)
        #expect(file.shoes.map(\.id) == cache.shoes.map(\.id))
        #expect(file.shoes.map(\.name) == cache.shoes.map(\.name))
        #expect(file.shoes.map(\.distanceM) == cache.shoes.map(\.distanceM))
        #expect(file.shoes.map(\.primary) == cache.shoes.map(\.primary))
    }

    @Test("A property added to one shape and not the other is caught")
    func theShapesHaveTheSameKeys() throws {
        // The field-by-field test above compares what BOTH types have. This
        // one compares what each type WRITES, so a property added to `Cache`
        // alone is a failure rather than a silently ignored key.
        // POPULATED, not empty. `JSONEncoder` omits a nil optional entirely,
        // so two shapes that both leave `bikes` nil write the same keys and
        // this test would pass while proving nothing — which is what it did
        // when patch 267 first added the field to one side only.
        let cache = AthleteStore.Cache(
            zones: [], shoes: [],
            bikes: [.init(id: "b1", name: "Bike", distanceM: 1, primary: false)],
            fetched: Date(timeIntervalSince1970: 0), ftp: 200)
        let file = AthleteFile(
            zones: [], shoes: [],
            bikes: [.init(id: "b1", name: "Bike", distanceM: 1, primary: false)],
            fetched: Date(timeIntervalSince1970: 0), ftp: 200)

        let fromCache = try keys(of: JSONEncoder().encode(cache))
        let fromFile = try keys(of: AthleteFile.encoder.encode(file))
        #expect(fromCache == fromFile,
                "the two shapes no longer write the same keys")
    }

    private func keys(of data: Data) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set(try #require(object).keys)
    }
}

// MARK: - The point of it

/// DELIBERATELY NOT `@MainActor` — patch 258's lesson applied on purpose this
/// time rather than after three warnings. The reader that will use `AthleteFile`
/// is `nonisolated` and runs inside a database write; a mirror that could only
/// be decoded on the main actor would have solved nothing.
@Suite
struct AthleteFileTests {

    @Test("The real file decodes without the main actor")
    func theFixtureDecodes() throws {
        let data = try #require(LegacyDamage.valid.bytes(for: .athlete))
        let file = try AthleteFile.read(data)

        #expect(file.ftp == 270)
        #expect(file.zones.count == 2)
        #expect(file.shoes.count == 1)
        #expect(file.shoes.first?.name == "Novablast 4")
        // The top zone has no ceiling, and the fixture omits the key entirely
        // rather than writing null. Both have to arrive as nil.
        #expect(file.zones.last?.max == nil)
        #expect(file.zones.first?.max == 120)
    }

    @Test("A file written before patch 267 still decodes, with no bikes")
    func anOlderFileHasNoBikes() throws {
        // The hazard `Cache.bikes` is optional for. A synthesised decoder does
        // not use Swift default values, so a non-optional `bikes` would make
        // every athlete.json written before today fail ENTIRELY — taking the
        // zones, the FTP and the shoe history with it.
        let data = try #require(LegacyDamage.valid.bytes(for: .athlete))
        let file = try AthleteFile.read(data)
        #expect(file.bikes == nil)
        // And everything else still arrives, which is the part that would
        // have been lost.
        #expect(file.ftp == 270)
        #expect(file.zones.count == 2)
        #expect(file.shoes.count == 1)
    }

    @Test("The top-level shape is still the four keys it has always been")
    func theShapeIsUnchanged() throws {
        // Carried over from `athleteCannotBeDecodedFromOutsideItsStore`, which
        // patch 259 replaces. The old test's assertion was worth keeping even
        // though its premise is gone: this is the shape thirteen months of
        // files on disk are written in, and a change to it is a migration
        // rather than an edit.
        let data = try #require(LegacyDamage.valid.bytes(for: .athlete))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(try #require(object).keys)
        #expect(keys == ["zones", "shoes", "fetched", "ftp"],
                "athlete.json's top-level shape changed: \(keys.sorted())")
    }

    @Test("The wrong date strategy throws rather than inventing a date")
    func theWrongStrategyThrowsRatherThanInventingADate() throws {
        // Contract item 4 in one assertion. `fetched` is a number of seconds
        // from 2001; read as ISO-8601 it does not become 1970 or 2001, it
        // fails — and a decoder that fails is a decoder that can be corrected.
        //
        // The corpus already asserts this across all eleven inputs. It is
        // repeated here because `AthleteFile.decoder` is a specific choice
        // made in a specific file, and this is where somebody would change it.
        let data = try #require(LegacyDamage.valid.bytes(for: .athlete))
        #expect(throws: (any Error).self) {
            try JSONDecoder.sub4.decode(AthleteFile.self, from: data)
        }
    }

    @Test("The declared strategy is the one the corpus recorded")
    func theStrategyAgreesWithTheCorpus() {
        // `LegacyInput.dates` is the app-independent record of which decoder
        // wrote which file. `AthleteFile.decoder` is the implementation. This
        // asserts they are talking about the same thing, so the corpus cannot
        // drift into being documentation.
        #expect(LegacyInput.athlete.dates == .numericReferenceDate)
    }

    @Test("A truncated file fails rather than decoding a partial profile")
    func truncationIsNotSilent() throws {
        // Not the classifier — that is the next patch, and it will make this
        // assertion sharper. For now the only claim is that a half file does
        // not produce a half profile.
        let data = try #require(LegacyDamage.truncated.bytes(for: .athlete))
        #expect(throws: (any Error).self) {
            try AthleteFile.read(data)
        }
    }
}
