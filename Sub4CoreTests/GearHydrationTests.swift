//
//  GearHydrationTests.swift
//  Sub4CoreTests
//
//  Patch 429, ADR-0003 §12.179, D7 slice B5 — the machinery, not the flip.
//
//  `AthleteStore.hydrate(gear:)` REBUILDS THE THREE ARRAYS FROM ROWS, and it
//  could not have been written before 425–427: until `kind` and `isRetired`
//  existed a `gear` row could not say which array it belonged in. That is the
//  whole of what those three patches bought, and this is the first thing to
//  spend it.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct GearHydrationTests {

    private func stored(_ id: String, kind: GearKind, retired: Bool)
    -> WeatherGearLoad.StoredGear {
        WeatherGearLoad.StoredGear(externalID: id, name: id, distanceM: 700_000,
                                   retiredUTC: retired ? "2025-09-14T07:00:00Z" : nil,
                                   kind: kind, isRetired: retired)
    }

    private func store() -> AthleteStore {
        AthleteStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
    }

    @Test("Rows are split back into shoes, bikes and retired")
    func theThreeArraysAreRebuilt() {
        let s = store()
        s.hydrate(gear: [stored("s1", kind: .shoe, retired: false),
                         stored("s2", kind: .shoe, retired: false),
                         stored("b1", kind: .bike, retired: false),
                         stored("r1", kind: .unknown, retired: true)])

        #expect(s.shoes.map(\.id) == ["s1", "s2"])
        #expect(s.bikes.map(\.id) == ["b1"])
        #expect(s.retired.map(\.id) == ["r1"])
        #expect(s.allGear.count == 4)
    }

    /// **RETIREMENT OUTRANKS KIND.** A retired bike is retired first, or it
    /// would sit in `bikes` and read as gear the athlete still owns.
    @Test("A retired bike is retired, not a bike")
    func retirementOutranksKind() {
        let s = store()
        s.hydrate(gear: [stored("b1", kind: .bike, retired: true)])
        #expect(s.bikes.isEmpty)
        #expect(s.retired.map(\.id) == ["b1"])
        #expect(s.retired.first?.kind == .bike, "the kind survives the sorting")
    }

    /// `.unknown` goes to `shoes` because that is where `allGear` has always
    /// put unclassified gear — and `wearIsMeaningful` is what stops the wear
    /// bar, rather than the array doing it.
    @Test("Unclassified gear lands in shoes and draws no wear")
    func unknownGearIsNotGivenAVerdict() {
        let s = store()
        s.hydrate(gear: [stored("x1", kind: .unknown, retired: false)])
        #expect(s.shoes.map(\.id) == ["x1"])
        #expect(s.shoes.first?.wearIsMeaningful == false,
                "700 km of running-shoe thresholds on something nobody identified")
        #expect(s.shoes.first?.kindLabel == "Kind not known")
    }

    @Test("A retired item says so in its label")
    func theLabelNamesRetirement() {
        let s = store()
        s.hydrate(gear: [stored("b1", kind: .bike, retired: true)])
        #expect(s.retired.first?.kindLabel == "Bike · retired")
    }

    /// **THE SENTENCE THAT HAD `until slice B5` IN IT FOR EIGHTY-THREE
    /// PATCHES.** B1 took the zones and the FTP and said so; this is the other
    /// half, and the line is the one-line proof on the device.
    @Test("The store stops saying it is half on files")
    func servedFromBecomesWhole() {
        let s = store()
        s.hydrate(zones: [], ftp: 270)
        #expect(s.servedFrom.line.contains("until slice B5"))
        s.hydrate(gear: [stored("s1", kind: .shoe, retired: false)])
        #expect(s.servedFrom.line == "the database")
    }

    /// RULE 8's subject, asserted rather than assumed: hydration reads.
    @Test("Hydrating gear writes nothing")
    func hydrationDoesNotWrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = AthleteStore(directory: dir)
        s.hydrate(gear: [stored("s1", kind: .shoe, retired: false)])
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("athlete.json").path),
                "hydration wrote a file, and the slice is no longer reversible")
    }
}


@Suite
@MainActor
struct WeatherHydrationTests {

    private func reading(_ id: String, temp: Double) -> ActivityWeather {
        ActivityWeather(activityId: id, tempC: temp, feelsLikeC: temp,
                        humidity: 60, windKmh: 10, windFromDegrees: 180,
                        precipitationMm: 0, symbolName: "cloud",
                        conditionLabel: "Overcast", samples: 2,
                        fetched: Date(timeIntervalSince1970: 0),
                        source: .openMeteo)
    }

    @Test("Readings are keyed by activity and the store says where they came from")
    func hydrationReplacesAndReports() {
        let w = WeatherStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        #expect(w.servedFrom.line == "the app's own files")
        w.hydrate(from: [reading("a1", temp: 21), reading("a2", temp: 14)])
        #expect(w.byActivity.count == 2)
        #expect(w.byActivity["a1"]?.tempC == 21)
        #expect(w.servedFrom.line == "the database")
    }

    /// **429 IS THE MACHINERY AND NOT THE FLIP.** 430 inverts these.
    @Test("Neither family is fed yet")
    func neitherIsFedYet() {
        #expect(!PersistenceAuthority.hydrates(.weather))
        #expect(!PersistenceAuthority.hydrates(.gear))
        #expect(WeatherStore.shared.servedFrom.line == "the app's own files",
                "the singleton is on its files until 430")
    }
}
