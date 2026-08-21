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
        // **430 CHANGED THIS SENTENCE AND THE CHANGE IS THE POINT.** Before the
        // flip the half-hydrated state had one cause and the line named the
        // slice. Now it has another — B5 shipped and the gear table is empty —
        // and naming the slice would send a reader to the ladder instead of to
        // the import. §12.15, §12.127.5.
        #expect(!s.servedFrom.line.contains("until slice B5"),
                "the line names a slice that has landed")
        #expect(s.servedFrom.line.contains("nothing stored to hydrate from"))

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

    /// **430 IS THE FLIP.**
    @Test("Both families are fed")
    func bothAreFed() {
        #expect(PersistenceAuthority.hydrates(.weather))
        #expect(PersistenceAuthority.hydrates(.gear))
    }
}

/// **PATCH 431 — WHAT 430 MADE VACUOUS, AND WHAT ASKS THE FUNCTION.**
///
/// §12.125: the patch before a flip is the one that asks what the flip is about
/// to make vacuous. B5 did not get that patch, so these are the tests that go
/// with the correction.
@Suite
@MainActor
struct WeatherGearIndependenceTests {

    /// **THE ARM THAT WAS A CONSTANT.** `case .weather: false` survived the
    /// flip, so every comparison reading `WeatherStore` counted as evidence
    /// while the store was serving rows.
    @Test("Whether weather is fed is asked, not stated")
    func weatherIsAQuestion() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let w = WeatherStore(directory: dir)
        #expect(w.servedFrom == .files)
        w.hydrate(from: [])
        #expect(w.servedFrom == .database,
                "the store must be able to answer, or the arm has nothing to ask")
    }

    /// The gear arm never had the defect, and its own comment says why.
    @Test("Gear's two halves move with the store")
    func gearFollowsTheStore() {
        let s = AthleteStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        s.hydrate(zones: [], ftp: nil)
        #expect(s.zonesServedFrom == .database)
        #expect(s.gearServedFrom == .files, "half hydrated is half on files")
        s.hydrate(gear: [])
        #expect(s.gearServedFrom == .database)
    }

    /// **ASK THE FUNCTION, NOT ITS INGREDIENTS — §12.164.** Reverting
    /// `weatherGear` to the singletons leaves every test above green.
    @Test("The read-back reports its own read")
    func theReadBackReportsItsOwnRead() async throws {
        let db = try Sub4Database.inMemory()
        let (_, _, source) = await ReadBacks.weatherGear(db)

        guard case .ownRead(let where_) = source else {
            Issue.record("the row is self-referential — got \(source)")
            return
        }
        #expect(where_.contains("read directly") || where_.contains("unreachable"))
        // Fed or not, a row that went and read the files can disagree.
        #expect(!source.isSelfReferential(
                    given: ExpectationSources(fedByTheDatabase: [.weather, .gear])))
    }
}

/// **PATCH 432 — THE LOOP THE DEVICE FOUND.**
///
/// After 430 the launch hydrated gear from the database, `AppStores` handed the
/// importer `AthleteStore.shared.allGear` — which was now the rows — and
/// `importGear` found nothing changed. The kinds sat in `athlete.json`, were
/// read at every launch and thrown away at every launch, and the database could
/// never learn them.
///
/// The first device run at 431 reported `gear fields that differ: 11`, all
/// `kind`, with `gear by kind: 0 shoes, 0 bikes, 11 of unknown kind`. **It was
/// visible only because 431 gave the read-back its own read** — before that,
/// both sides were the rows and it looked perfect.
@Suite
@MainActor
struct GearHydrationMergeTests {

    private func row(_ id: String, kind: GearKind, retired: Bool)
    -> WeatherGearLoad.StoredGear {
        WeatherGearLoad.StoredGear(externalID: id, name: id, distanceM: 1000,
                                   retiredUTC: nil, kind: kind, isRetired: retired)
    }

    /// A store whose file knew the kinds — which is every device on the first
    /// launch after B5.
    private func storeFromFile() throws -> AthleteStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let shoe = AthleteStore.Shoe(id: "g1", name: "Novablast",
                                     distanceM: 1000, primary: false)
        let bike = AthleteStore.Shoe(id: "b1", name: "Gravel",
                                     distanceM: 1000, primary: false)
        let old = AthleteStore.Shoe(id: "r1", name: "Old pair",
                                    distanceM: 1000, primary: false)
        // No `kind` and no `retired` key — a file written before 425.
        let cache = AthleteStore.Cache(zones: [], shoes: [shoe], bikes: [bike],
                                       retired: [old], fetched: nil, ftp: nil)
        try JSONEncoder().encode(cache)
            .write(to: dir.appendingPathComponent("athlete.json"))
        return AthleteStore(directory: dir)
    }

    /// **THE ONE THAT IS THE PATCH.** Rows written before 426 say `unknown`
    /// for everything, and the file knows better.
    @Test("A kind the database does not know is taken from the file")
    func theKindIsRecovered() throws {
        let s = try storeFromFile()
        s.hydrate(gear: [row("g1", kind: .unknown, retired: false),
                         row("b1", kind: .unknown, retired: false)])

        #expect(s.bikes.map(\.id) == ["b1"],
                "the bike went back to being unclassified, and the database can never learn it")
        #expect(s.shoes.map(\.id) == ["g1"])
        #expect(s.gearRecoveredFromTheFile == 2)
    }

    /// Retirement is the same shape: `false` on a row written before 426 is an
    /// absence, not a denial.
    @Test("A retirement the database does not know is taken from the file")
    func retirementIsRecovered() throws {
        let s = try storeFromFile()
        s.hydrate(gear: [row("r1", kind: .unknown, retired: false)])
        #expect(s.retired.map(\.id) == ["r1"])
        // Two facts recovered for one item: its kind is unknown on both sides,
        // so only the retirement counts — and `.unknown` from the file is not
        // an improvement on `.unknown` from the row.
        #expect(s.gearRecoveredFromTheFile == 1)
    }

    /// **THE DATABASE STILL WINS WHERE IT KNOWS SOMETHING.** The merge fills
    /// gaps; it does not prefer the file.
    @Test("A kind the database knows is not overridden by the file")
    func theDatabaseWinsWhenItKnows() throws {
        let s = try storeFromFile()
        // The file calls g1 a shoe; the database says bike. The database wins.
        s.hydrate(gear: [row("g1", kind: .bike, retired: false)])
        #expect(s.bikes.map(\.id) == ["g1"])
        #expect(s.gearRecoveredFromTheFile == 0)
    }

    @Test("Name and distance always come from the row")
    func theRowOwnsNameAndDistance() throws {
        let s = try storeFromFile()
        s.hydrate(gear: [WeatherGearLoad.StoredGear(
            externalID: "g1", name: "Renamed", distanceM: 9_999,
            retiredUTC: nil, kind: .shoe, isRetired: false)])
        #expect(s.shoes.first?.name == "Renamed")
        #expect(s.shoes.first?.distanceM == 9_999)
    }

    /// **THE COUNTER IS THE TRIPWIRE.** Zero on the second launch is what says
    /// the write-through carried the facts back; a number that stays non-zero
    /// is the loop still running.
    @Test("Nothing is recovered once the database knows")
    func theCounterFallsToZero() throws {
        let s = try storeFromFile()
        s.hydrate(gear: [row("g1", kind: .shoe, retired: false),
                         row("b1", kind: .bike, retired: false),
                         row("r1", kind: .unknown, retired: true)])
        #expect(s.gearRecoveredFromTheFile == 0)
    }
}
