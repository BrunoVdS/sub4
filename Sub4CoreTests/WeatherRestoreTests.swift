//
//  WeatherRestoreTests.swift
//  Sub4CoreTests
//
//  Putting the readings back — patch 374, ADR-0003 §12.118.
//
//  THE ONE THAT IS THE RECOVERY
//  ----------------------------
//  `readingsMissingFromTheFileAreAdded`. On 15 August `weather.json` went from
//  602 readings to one. 371 stopped it happening again and put nothing back;
//  the 601 have been in the database since, comparing `fields that differ: 0`.
//  This is the test that says they can come home.
//
//  THE ONE THAT DECIDED THE DESIGN
//  -------------------------------
//  `aReadingFetchedSinceTheImportSurvives`. A restore that replaced the file
//  wholesale would look simpler and would delete every reading fetched since
//  the last import — 15 August again, at smaller scale, with the repair as the
//  cause. Additive is not a preference here; it is the difference between a
//  fix and a second occurrence.
//
//  THE ONE THAT MAKES THE GUARD WORK
//  ---------------------------------
//  `anUnreadableFileIsMovedNotOverwritten` and its two neighbours. 371's
//  `save()` refuses while the file will not decode, which is exactly the state
//  a restore is most needed in. The restore does not step around that: it
//  moves the bytes somewhere they survive, which leaves nothing to destroy,
//  and then takes the ordinary path.
//
//  NOTHING HERE TOUCHES THE SINGLETON. Every store is built through
//  `init(directory:)` into a fresh temporary folder — `WeatherStore.shared`
//  points at the athlete's real weather.json.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Restoring weather from the database")
@MainActor
struct WeatherRestoreTests {

    // MARK: Fixtures

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func reading(_ id: String, tempC: Double = 14.0) -> ActivityWeather {
        ActivityWeather(activityId: id, tempC: tempC, feelsLikeC: tempC - 1,
                        humidity: 72, windKmh: 11, windFromDegrees: 225,
                        precipitationMm: 0, symbolName: "cloud.sun",
                        conditionLabel: "Partly cloudy", samples: 3,
                        fetched: Date(timeIntervalSince1970: 1_755_000_000),
                        source: .openMeteo)
    }

    /// The shape `save()` writes: a bare encoder, because the date encoding on
    /// disk is thirteen months old. A fixture written with `JSONEncoder.sub4`
    /// would be a file this store cannot read, which is a different test.
    private func writeStore(_ readings: [ActivityWeather], to dir: URL) throws {
        let byActivity = Dictionary(readings.map { ($0.activityId, $0) },
                                    uniquingKeysWith: { a, _ in a })
        try JSONEncoder().encode(byActivity)
            .write(to: dir.appendingPathComponent("weather.json"))
    }

    @discardableResult
    private func writeCorrupt(to dir: URL) throws -> Data {
        var object: [String: Int] = [:]
        for i in 0..<200 { object["entry-\(i)"] = i }
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        try data.write(to: dir.appendingPathComponent("weather.json"))
        return data
    }

    private func fromDatabase(_ readings: [ActivityWeather]) -> WeatherGearLoad {
        .loaded(weather: readings, gear: [], skipped: 0)
    }

    private func asideFiles(in dir: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("unreadable-") }
    }

    // MARK: The recovery

    /// **THE ONE THAT IS THE RECOVERY.** One reading in the file, six hundred
    /// and two in the database.
    @Test("Readings missing from the file are added")
    func readingsMissingFromTheFileAreAdded() throws {
        let dir = try directory()
        try writeStore([reading("survivor")], to: dir)

        let store = WeatherStore(directory: dir)
        #expect(store.storedCount == 1)

        let stored = (0..<601).map { reading("db-\($0)") } + [reading("survivor")]
        let result = try store.restore(from: fromDatabase(stored))

        #expect(result.added == 601)
        #expect(result.alreadyHeld == 1)
        #expect(result.setAside == nil)
        #expect(store.storedCount == 602)
    }

    /// §12.118.2. The database's copy does not win — the store's does.
    @Test("A reading already held is not changed")
    func aReadingAlreadyHeldIsNotChanged() throws {
        let dir = try directory()
        try writeStore([reading("a", tempC: 14.0)], to: dir)

        let store = WeatherStore(directory: dir)
        let result = try store.restore(from: fromDatabase([reading("a", tempC: 99.0)]))

        #expect(result.added == 0)
        #expect(result.alreadyHeld == 1)
        #expect(store.byActivity["a"]?.tempC == 14.0,
                "the restore overwrote a reading the store already held")
    }

    /// **THE ONE THAT DECIDED THE DESIGN.** A reading fetched since the last
    /// import is in the file and not in the database. Wholesale replacement
    /// deletes exactly these.
    @Test("A reading fetched since the import survives")
    func aReadingFetchedSinceTheImportSurvives() throws {
        let dir = try directory()
        try writeStore([reading("imported"), reading("fetched-yesterday")], to: dir)

        let store = WeatherStore(directory: dir)
        try store.restore(from: fromDatabase([reading("imported")]))

        #expect(store.byActivity["fetched-yesterday"] != nil,
                "a reading the database has never seen was deleted by the repair")
        #expect(store.storedCount == 2)
    }

    @Test("Restoring twice adds nothing the second time")
    func restoringTwiceAddsNothingTheSecondTime() throws {
        let dir = try directory()
        let stored = (0..<10).map { reading("db-\($0)") }

        let store = WeatherStore(directory: dir)
        #expect(try store.restore(from: fromDatabase(stored)).added == 10)

        let second = try store.restore(from: fromDatabase(stored))
        #expect(second.added == 0)
        #expect(second.alreadyHeld == 10)
    }

    // MARK: The unreadable file

    /// §12.118.3. The state a restore is most needed in, and the one 371's
    /// guard refuses to write in.
    @Test("An unreadable file is moved, not overwritten")
    func anUnreadableFileIsMovedNotOverwritten() throws {
        let dir = try directory()
        try writeCorrupt(to: dir)

        let store = WeatherStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy)

        let result = try store.restore(from: fromDatabase([reading("a"), reading("b")]))

        #expect(result.added == 2)
        let aside = try #require(result.setAside, "the unreadable file was not kept")
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(try asideFiles(in: dir).count == 1)
    }

    @Test("The moved file keeps the original bytes")
    func theMovedFileKeepsTheOriginalBytes() throws {
        let dir = try directory()
        let before = try writeCorrupt(to: dir)

        let store = WeatherStore(directory: dir)
        let result = try store.restore(from: fromDatabase([reading("a")]))

        let aside = try #require(result.setAside)
        #expect(try Data(contentsOf: aside) == before,
                "the preserved copy is not the file that could not be read")
    }

    /// The repair has to persist, or it is a repair that lasts until the app
    /// is closed — which is the failure 371 disclosed, not a fix for it.
    @Test("A restore after moving reaches the disk")
    func aRestoreAfterMovingReachesTheDisk() throws {
        let dir = try directory()
        try writeCorrupt(to: dir)

        let store = WeatherStore(directory: dir)
        try store.restore(from: fromDatabase([reading("a"), reading("b")]))

        let reopened = WeatherStore(directory: dir)
        #expect(reopened.lastLoad.isTrustworthy)
        #expect(reopened.storedCount == 2)
    }

    /// §12.20. `try`, not `try?` — a move that silently did not happen leaves
    /// the bytes exactly where the write is about to land.
    @Test("A restore that cannot move the file writes nothing")
    func aRestoreThatCannotMoveTheFileWritesNothing() throws {
        let dir = try directory()
        let before = try writeCorrupt(to: dir)

        let store = WeatherStore(directory: dir)
        #expect(!store.lastLoad.isTrustworthy)

        // Read and execute, no write: the file can still be opened, and
        // nothing can be created, renamed or replaced beside it.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: dir.path)
        }

        #expect(throws: (any Error).self) {
            try store.restore(from: fromDatabase([reading("a")]))
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent("weather.json")) == before,
                "the unreadable file was written over after the move failed")
        #expect(store.storedCount == 0, "memory kept readings that never reached the disk")
    }

    // MARK: Nothing to restore

    @Test("A failed database read restores nothing")
    func aFailedDatabaseReadRestoresNothing() throws {
        let dir = try directory()
        let before = try writeCorrupt(to: dir)

        let store = WeatherStore(directory: dir)
        #expect(throws: WeatherRestoreFault.self) {
            try store.restore(from: .failed("no such table: weather"))
        }
        // The move is downstream of the read, so a failed read must not have
        // touched the file either.
        #expect(try Data(contentsOf: dir.appendingPathComponent("weather.json")) == before)
        #expect(try asideFiles(in: dir).isEmpty)
    }

    /// Nothing to restore is not a repair. An empty database must not move a
    /// readable file aside, and must not write.
    @Test("An empty database touches nothing")
    func anEmptyDatabaseTouchesNothing() throws {
        let dir = try directory()
        try writeCorrupt(to: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("weather.json"))

        let store = WeatherStore(directory: dir)
        let result = try store.restore(from: fromDatabase([]))

        #expect(result.added == 0)
        #expect(result.alreadyHeld == 0)
        #expect(result.setAside == nil)
        #expect(try Data(contentsOf: dir.appendingPathComponent("weather.json")) == before)
        #expect(try asideFiles(in: dir).isEmpty)
    }

    // MARK: The aside name

    /// Two taps in the same second are two restores. `ProposalStore.add`
    /// already records what a running count costs when the second one lands on
    /// the first.
    @Test("A second aside in the same second does not collide")
    func asideNamesDoNotCollide() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("weather.json")
        let now = Date(timeIntervalSince1970: 1_755_000_000)

        let first = WeatherStore.asideURL(for: file, now: now)
        try Data("x".utf8).write(to: first)
        let second = WeatherStore.asideURL(for: file, now: now)

        #expect(first != second)
        #expect(second.lastPathComponent.contains("unreadable-"))
    }
}
