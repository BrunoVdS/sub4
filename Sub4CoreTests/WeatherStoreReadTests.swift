//
//  WeatherStoreReadTests.swift
//  Sub4CoreTests
//
//  The file that would not decode — patch 371, ADR-0003 §12.115.
//
//  THE ONE THAT IS THE INCIDENT
//  ----------------------------
//  `theFileSurvivesAnUncleanRead`. On 15 August `weather.json` went from 602
//  readings to one: the file became undecodable, `load()`'s `?? [:]` emptied the
//  store in memory without saying so, one activity's weather arrived, and
//  `save()` wrote a one-entry dictionary over six hundred. That test corrupts a
//  file, drives the exact path — `store(_:)` -> `save()` — and asserts the bytes
//  on disk are unchanged. It is the only test here that must never be skipped.
//
//  AND THE ONE THAT STOPS THE FIX BEING WORSE
//  ------------------------------------------
//  `theRoundTripUsesTheSameEncoding`. `save()` writes with a BARE `JSONEncoder`
//  — deliberately, the numeric date encoding on disk is thirteen months old.
//  `StoreRead.decode` DEFAULTS to `JSONDecoder.sub4`, which reads ISO-8601. Take
//  that default and every existing weather file stops decoding, which — with the
//  new guard in `save()` — stops every device persisting weather at once. The
//  test asserts the store's own output round trips, and that `.sub4` cannot read
//  it, so anybody who "tidies up" the explicit decoder is told immediately.
//
//  NOTHING HERE TOUCHES `WeatherStore.shared`. Every test runs through the
//  `init(directory:)` seam into a fresh temporary folder, because the singleton
//  points at the real Application Support directory and these tests write.
//

import Testing
import Foundation
@testable import Sub4

@Suite("A weather file that will not decode")
@MainActor
struct WeatherStoreReadTests {

    // MARK: Fixtures

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("weather-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func file(in dir: URL) -> URL {
        dir.appendingPathComponent("weather.json")
    }

    private func reading(_ id: String, tempC: Double = 14) -> ActivityWeather {
        ActivityWeather(activityId: id,
                        tempC: tempC,
                        feelsLikeC: tempC - 1,
                        humidity: 0.71,
                        windKmh: 12,
                        windFromDegrees: 225,
                        precipitationMm: 0,
                        symbolName: "cloud",
                        conditionLabel: "Mostly Cloudy",
                        samples: 2,
                        fetched: Date(timeIntervalSinceReferenceDate: 776_000_000),
                        source: .openMeteo)
    }

    /// A file that is valid JSON, is not small, and is not a
    /// `[String: ActivityWeather]`. The 15 August file decoded as nothing for
    /// some reason nobody recorded; what matters to the store is only that the
    /// decode threw over bytes worth keeping.
    private func writeSomethingUndecodable(into dir: URL) throws -> Data {
        var object: [String: Int] = [:]
        for i in 0..<602 { object["activity-\(i)"] = i }
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        try data.write(to: file(in: dir))
        return data
    }

    /// A file the store itself would have written — bare encoder, numeric dates.
    @discardableResult
    private func writeAGoodFile(into dir: URL,
                                _ readings: [ActivityWeather]) throws -> Data {
        var byActivity: [String: ActivityWeather] = [:]
        for r in readings { byActivity[r.activityId] = r }
        let data = try JSONEncoder().encode(byActivity)
        try data.write(to: file(in: dir))
        return data
    }

    // MARK: What the read now says

    /// **§12.115.1, AND IT IS THE WHOLE DEFECT.** An empty store the app could
    /// read and an empty store it could not are opposite facts. `?? [:]`
    /// returned the same value for both, so nothing downstream — not the
    /// screen, not the journal, not `save()` — could tell them apart.
    @Test("An undecodable file is not an empty store")
    func anUndecodableFileIsNotAnEmptyStore() throws {
        let dir = try directory()
        _ = try writeSomethingUndecodable(into: dir)

        let store = WeatherStore(directory: dir)
        #expect(store.storedCount == 0)
        #expect(!store.lastLoad.isTrustworthy,
                "an unreadable file reads as a legitimately empty store")
        #expect(store.lastLoad != .absent,
                "a file that is there reads as no file at all")

        // The comparison that names the defect: same count, opposite verdicts.
        let emptyDir = try directory()
        let fresh = WeatherStore(directory: emptyDir)
        #expect(fresh.storedCount == store.storedCount)
        #expect(fresh.lastLoad != store.lastLoad,
                "two stores holding nothing for opposite reasons agree")
    }

    /// A fresh install has no `weather.json` and that is not a fault. §12.20's
    /// own rule: absent is a legitimate empty, and a guard that refused here
    /// would stop the first reading ever being saved.
    @Test("An absent file is trustworthy")
    func anAbsentFileIsTrustworthy() throws {
        let dir = try directory()
        let store = WeatherStore(directory: dir)
        #expect(store.lastLoad == .absent)
        #expect(store.lastLoad.isTrustworthy)

        store.store(reading("692"))
        #expect(FileManager.default.fileExists(atPath: file(in: dir).path),
                "a fresh install never writes its first reading")
        #expect(WeatherStore(directory: dir).storedCount == 1)
    }

    // MARK: What the write refuses

    /// **THE REGRESSION — 15 AUGUST, EXACTLY.** Corrupt the file, let a fetch
    /// land, and assert the bytes on disk did not move. This is the test that
    /// exists because 601 readings did.
    @Test("The file survives an unclean read")
    func theFileSurvivesAnUncleanRead() throws {
        let dir = try directory()
        let before = try writeSomethingUndecodable(into: dir)

        let store = WeatherStore(directory: dir)
        // The exact path: a fetch landed, `store(_:)` ran, `save()` was called.
        store.store(reading("692"))

        let after = try Data(contentsOf: file(in: dir))
        #expect(after == before,
                "the file was overwritten after a read that failed — this is 15 August again")
    }

    /// The refusal, stated as a verdict rather than inferred from the bytes.
    /// The cost is disclosed and deliberate: the reading is live in memory and
    /// on screen, and it is re-fetched next launch.
    @Test("An unclean read refuses to save")
    func anUncleanReadRefusesToSave() throws {
        let dir = try directory()
        _ = try writeSomethingUndecodable(into: dir)

        let store = WeatherStore(directory: dir)
        store.store(reading("692"))

        #expect(store.storedCount == 1,
                "the reading is not held in memory, so the screen loses it too")

        let text = try String(contentsOf: file(in: dir), encoding: .utf8)
        #expect(!text.contains("Mostly Cloudy"),
                "the reading reached the file the store could not read")
    }

    /// **§12.69 — A GUARD THAT BLOCKS EVERYTHING HAS NOT BEEN TESTED EITHER.**
    /// The refusal has to be about the unclean read and nothing else.
    @Test("A clean read still saves")
    func aCleanReadStillSaves() throws {
        let dir = try directory()
        try writeAGoodFile(into: dir, [reading("601", tempC: 9)])

        let store = WeatherStore(directory: dir)
        #expect(store.lastLoad == .loaded)
        #expect(store.storedCount == 1)

        store.store(reading("692", tempC: 21))

        let reopened = WeatherStore(directory: dir)
        #expect(reopened.storedCount == 2,
                "a store that read cleanly did not persist the new reading")
        #expect(reopened.byActivity["601"]?.tempC == 9,
                "the reading that was already on disk did not survive the save")
    }

    /// Deleting the file is the repair, so it has to lift the refusal. Without
    /// this the guard outlives its cause: the bad file is gone and the store
    /// still will not write until the next launch.
    @Test("Resetting the cache makes the store writable again")
    func resetCacheMakesTheStoreWritableAgain() throws {
        let dir = try directory()
        _ = try writeSomethingUndecodable(into: dir)

        let store = WeatherStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy)

        store.resetCache()
        #expect(store.lastLoad == .absent,
                "the verdict outlived the file it was about")

        store.store(reading("692"))
        #expect(WeatherStore(directory: dir).storedCount == 1,
                "the store still refuses to write after the bad file was removed")
    }

    // MARK: The encoding, which is the dangerous part

    /// **§12.115.2 — THE LINE THAT COULD EMPTY EVERY DEVICE.** `save()` writes
    /// with a bare encoder; `StoreRead.decode` defaults to `.sub4`. Taking the
    /// default would make every existing weather file undecodable, and with the
    /// guard above that means every device silently stops persisting weather.
    @Test("The round trip uses the same encoding")
    func theRoundTripUsesTheSameEncoding() throws {
        let dir = try directory()
        let store = WeatherStore(directory: dir)
        let written = reading("692", tempC: 17.5)
        store.store(written)

        let reopened = WeatherStore(directory: dir)
        #expect(reopened.lastLoad == .loaded,
                "the store cannot read a file it wrote itself")
        #expect(reopened.byActivity["692"]?.tempC == 17.5)
        #expect(reopened.byActivity["692"]?.fetched == written.fetched,
                "the date did not survive the round trip")

        // AND THE DEFAULT MUST NOT WORK. If this ever passes, the two coders
        // have converged and `load()` may take the default — until then,
        // dropping the explicit decoder breaks every existing install.
        let data = try Data(contentsOf: file(in: dir))
        #expect(throws: (any Error).self) {
            try JSONDecoder.sub4.decode([String: ActivityWeather].self, from: data)
        }
    }

    // MARK: The journal

    /// The seam must stay out of the shared journal — that journal's own rule,
    /// and not a style point: `canReconcile` reads it to decide whether rows
    /// may be DELETED, so a test store recorded there votes on real data.
    @Test("The seam does not record to the journal")
    func theSeamDoesNotRecordToTheJournal() throws {
        let journal = StoreReadJournal.shared
        journal.forgetEverythingForTesting()
        defer { journal.forgetEverythingForTesting() }

        let dir = try directory()
        _ = try writeSomethingUndecodable(into: dir)
        let store = WeatherStore(directory: dir)

        #expect(!store.lastLoad.isTrustworthy,
                "the store read the corrupt file cleanly, so this proves nothing")
        #expect(journal.outcomes["weather.json"] == nil,
                "a temporary test store reported into the journal that permits deletion")
        #expect(!journal.hasUnreadable)
    }
}
