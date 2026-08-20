//
//  AthleteGuardTests.swift
//  Sub4CoreTests
//
//  The last two stores come under §12.116 — patch 418, ADR-0003 §12.163,
//  plan topic 2.
//
//  WHAT THE CEILING WAS
//  --------------------
//  `UNPROTECTED_STORE_CEILING` sat at 2 from patch 378. The two were these:
//  file-backed stores that decode into memory and write that memory back, with
//  no record of whether the read succeeded. Both read with
//  `try? Data(contentsOf:)` and `try? JSONDecoder().decode(…)` and `else {
//  return }` — so **an undecodable file left memory at its defaults, silently,
//  and the next save wrote those defaults over it.**
//
//  For `constants.json` the defaults are an athlete's HR max, resting heart
//  rate and FTP: the inputs every zone and every TRIMP is derived from.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The athlete stores refuse after an unclean read")
@MainActor
struct AthleteGuardTests {

    private func directory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("athlete-418-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func corrupt(_ dir: URL, _ name: String) throws {
        try Data("{ this is not json".utf8)
            .write(to: dir.appendingPathComponent(name))
    }

    private func bytes(_ dir: URL, _ name: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    // MARK: 1 — the defect, as a test

    /// **THE PRECONDITION, AND THE HONEST LIMIT OF WHAT A TEST CAN REACH.**
    ///
    /// `AthleteStore.save()` has exactly one caller — `refresh()`, which fetches
    /// from Strava — and every mutable property is `private(set)`. So nothing
    /// synchronous drives this store to write, and the refusal branch cannot be
    /// exercised from the suite.
    ///
    /// What IS testable is the thing the guard reads: after an unreadable file
    /// the store knows its read failed. The refusal itself is three identical
    /// lines to `ConstantsStore`'s, which `unreadableConstantsSurvive` drives
    /// end to end. **Stated rather than left for a green suite to imply** —
    /// §12.69, and the same admission `ProtectionReadBackTests` makes one patch
    /// earlier.
    @Test("An unreadable athlete cache is known to be unreadable")
    func anUnreadableAthleteCacheIsKnown() throws {
        let dir = try directory()
        try corrupt(dir, "athlete.json")

        let store = AthleteStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy, "the read failed and the store knows")
        // Before 418 there was nothing to ask. The store returned early and
        // memory kept its defaults, which the next save wrote over the file.
        #expect(store.ftp == nil)
        #expect(store.shoes.isEmpty)
    }

    @Test("Unreadable constants are not overwritten")
    func unreadableConstantsSurvive() throws {
        let dir = try directory()
        try corrupt(dir, "constants.json")
        let before = try #require(bytes(dir, "constants.json"))

        let store = ConstantsStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy)

        store.setHRMaxOverride(185)

        #expect(bytes(dir, "constants.json") == before,
                "an HR max is what every zone and every TRIMP is derived from")
    }

    // MARK: 2 — and it still writes when the read was clean

    @Test("A fresh install writes normally")
    func anAbsentFileIsNotAnUncleanRead() throws {
        let dir = try directory()
        let store = ConstantsStore(directory: dir)

        // `.absent` is trustworthy. A guard that refused here would make a new
        // install a store that can never write — a protection that breaks the
        // thing it protects.
        #expect(store.lastLoad == .absent)
        #expect(store.lastLoad.isTrustworthy)

        store.setHRMaxOverride(185)
        #expect(bytes(dir, "constants.json") != nil, "it must still write")
    }

    @Test("A clean read writes, and what it wrote reads back")
    func aCleanReadRoundTrips() throws {
        let dir = try directory()
        let first = ConstantsStore(directory: dir)
        first.setHRMaxOverride(185)

        // The store must be able to read what it just wrote. `constants.json`
        // carries no Date, so its decoder strategy is not load-bearing — the
        // bare decoder matches the bare encoder for symmetry rather than
        // necessity. **`athlete.json` is where that matters**, and
        // `theAthleteCacheFormatRoundTrips` is the test that says so.
        let second = ConstantsStore(directory: dir)
        #expect(second.lastLoad == .loaded,
                "the store must be able to read what it just wrote")
        #expect(second.lastLoad.isTrustworthy)
        #expect(second.c.hrMaxOverride == 185)
    }

    /// The same round trip for `athlete.json`, written by hand because the
    /// store's own writer is behind a network refresh. It is the FORMAT that
    /// matters here: a bare `JSONEncoder`, which `AthleteFile` decodes with
    /// `.deferredToDate`, and which `StoreRead.decode`'s default would not read.
    @Test("An athlete cache written in the file's own format reads back")
    func theAthleteCacheFormatRoundTrips() throws {
        let dir = try directory()
        let url = dir.appendingPathComponent("athlete.json")
        // **`fetched` IS NOT NIL, AND THAT IS THE WHOLE TEST.** A bare
        // `JSONEncoder` writes a Date as a number; `JSONDecoder.sub4` — the
        // default `StoreRead.decode` would have used — reads `.iso8601`. With
        // `fetched: nil` the strategies never meet and this passes against the
        // wrong decoder, which is exactly what the first draft did.
        try StoreWrite.encode(AthleteStore.Cache(zones: [], shoes: [],
                                                 bikes: nil, retired: nil,
                                                 fetched: Date(timeIntervalSince1970: 1_755_000_000),
                                                 ftp: 270),
                              to: url, store: "athlete.json",
                              encoder: JSONEncoder())

        let store = AthleteStore(directory: dir)
        #expect(store.lastLoad == .loaded,
                "the store must read what its own encoder writes")
        #expect(store.ftp == 270)
    }

    // MARK: 3 — the refusal is recorded, not swallowed

    @Test("A refused write reaches the unsaved-stores journal")
    func aRefusalIsRecorded() throws {
        let dir = try directory()
        try corrupt(dir, "constants.json")
        let store = ConstantsStore(directory: dir)
        store.setHRMaxOverride(185)

        // §12.54.2. A store that quietly stopped writing looks exactly like one
        // with nothing to write; the journal is where the Database screen reads
        // "Unsaved stores" from, and the reason has to be in it.
        let entry = StoreWriteJournal.shared.unsaved["constants.json"]
        #expect(entry != nil, "a refusal nobody can see is the defect with a guard on top")
    }
}
