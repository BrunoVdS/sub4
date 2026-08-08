//
//  WeatherGearRepositoryTests.swift
//  Sub4CoreTests
//
//  Weather and gear, read back — D6c slice 6, patch 324, ADR-0003 §12.67.
//
//  WHAT THESE ARE FOR
//  ------------------
//  Two prove the round trip. The rest prove the comparison can FAIL, and four
//  guard decisions this reader could have got quietly wrong:
//
//    `theActivityIdComesBackAsStravas`
//        — `weather.activityID` is canonical; `ActivityWeather.activityId` is
//          Strava's. Fifth instance of the trap.
//
//    `aNilSourceNormalisesAndIsNotADifference`
//        — the column is NOT NULL and the importer writes `provider`, so nil
//          cannot round trip. Comparing `source` would report every pre-133
//          reading as differing; comparing `provider` reports what both sides
//          hold. 320a's rule.
//
//    `aReadingForAnActivityTheAppDoesNotHoldIsExplained`
//        — `weather.activityID` is a foreign key, so those rows CANNOT exist.
//          Reporting them as missing data would make the screen red for the
//          database being right.
//
//    `gearKeysDirectlyWithNoAlias`
//        — the one table in this patch where the canonical-id trap does not
//          apply, asserted so that a later reader does not "fix" it by adding
//          a join that would match nothing.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct WeatherGearRepositoryTests {

    // MARK: Fixtures

    private func activity(_ id: String) -> Activity {
        Activity(id: id, name: "Evening Run", sportType: "Run",
                 startLocal: "2026-07-28T18:02:00", distance: 10_000,
                 movingTime: 3_300, elapsedTime: 3_400,
                 elevationGain: 42, averageHeartrate: 148, isTrainer: false,
                 maxHeartrate: 171, gearId: nil, maxSpeed: 4.2,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T16:02:00Z", startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func weather(_ activityId: String,
                         tempC: Double = 18.5,
                         source: WeatherSource? = .openMeteo) -> ActivityWeather {
        ActivityWeather(activityId: activityId, tempC: tempC, feelsLikeC: 17.1,
                        humidity: 0.62, windKmh: 14.0, windFromDegrees: 225,
                        precipitationMm: 0.4, symbolName: "cloud.sun",
                        conditionLabel: "Partly cloudy", samples: 3,
                        fetched: Date(timeIntervalSince1970: 1_780_000_000),
                        source: source)
    }

    private func shoe(_ id: String = "g123",
                      name: String = "Adizero Boston 12",
                      km: Double = 412,
                      primary: Bool = true) -> AthleteStore.Shoe {
        AthleteStore.Shoe(id: id, name: name, distanceM: km * 1000,
                          primary: primary)
    }

    private func compare(_ db: Sub4Database,
                         weather w: [ActivityWeather],
                         gear g: [AthleteStore.Shoe],
                         known: Set<String>) -> WeatherGearRoundTrip.Report {
        WeatherGearRoundTrip.compare(storeWeather: w, storeGear: g,
                                     knownActivityIDs: known,
                                     database: WeatherGearRepository.load(db))
    }

    // MARK: Nothing there is not the same as could not look

    /// §12.15, twelfth instance. A device that has never opened an activity has
    /// no readings, and that is an answer.
    @Test("An empty database reads as empty and says so")
    func emptyIsAnAnswer() throws {
        let db = try Sub4Database.inMemory()
        let load = WeatherGearRepository.load(db)

        #expect(load.isTrustworthy)
        #expect(load.weather?.isEmpty == true)
        #expect(load.gear?.isEmpty == true)
        #expect(load.skipped == 0)
        #expect(load.line == "0 readings, 0 gear.")
    }

    @Test("An untrustworthy read hands back nothing, not empty lists")
    func anUntrustworthyReadIsNotEmpty() {
        for load: WeatherGearLoad in [.unavailable, .failed("the file is locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.weather == nil,
                    "a caller must not reach [] without deciding what this means")
            #expect(load.gear == nil)
        }
    }

    // MARK: The round trip

    @Test("A reading survives the round trip, field by field")
    func theReadingRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = weather("19580875358")
        _ = try Sub4Import.run(into: db, activities: [activity("19580875358")],
                               shoes: [], weather: [original])

        let back = try #require(WeatherGearRepository.load(db).weather?.first)
        #expect(back.activityId == original.activityId)
        #expect(back.tempC == original.tempC)
        #expect(back.feelsLikeC == original.feelsLikeC)
        #expect(back.humidity == original.humidity)
        #expect(back.windKmh == original.windKmh)
        #expect(back.windFromDegrees == original.windFromDegrees)
        #expect(back.precipitationMm == original.precipitationMm)
        #expect(back.symbolName == original.symbolName)
        #expect(back.conditionLabel == original.conditionLabel)
        #expect(back.samples == original.samples)
        #expect(back.provider == original.provider)
        #expect(Sub4Import.iso8601(back.fetched)
                == Sub4Import.iso8601(original.fetched))
    }

    /// EXACT, no tolerance. A `Double` written to a REAL column and read back is
    /// lossless — there is no formatting step in between, unlike the paces at
    /// 320 or the TRIMP at 314. A tolerance would forgive a changed value.
    @Test("An awkward double comes back bit for bit")
    func doublesAreNotForgiven() throws {
        let db = try Sub4Database.inMemory()
        let odd = 1.0 / 3.0
        _ = try Sub4Import.run(into: db, activities: [activity("a1")], shoes: [],
                               weather: [weather("a1", tempC: odd)])
        let back = try #require(WeatherGearRepository.load(db).weather?.first)
        #expect(back.tempC == odd, "no rounding anywhere in the path")
    }

    @Test("Gear survives the round trip")
    func theGearRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [shoe()])

        let back = try #require(WeatherGearRepository.load(db).gear?.first)
        #expect(back.externalID == "g123")
        #expect(back.name == "Adizero Boston 12")
        #expect(back.distanceM == 412_000)
        #expect(back.retiredUTC == nil,
                "the column exists and the importer has never written it — §12.67.4")
    }

    // MARK: The canonical-id trap, fifth instance

    /// `weather.activityID` is the canonical activity id, resolved through
    /// `activity_alias` on the way in. The store is keyed by Strava's. A reader
    /// returning the column would hand back 583 ids matching nothing the app
    /// holds, and every reading would report as missing from both sides at once.
    @Test("The activity id comes back as Strava's, not the canonical one")
    func theActivityIdComesBackAsStravas() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity("19580875358")],
                               shoes: [], weather: [weather("19580875358")])

        let canonical = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT activityID FROM weather")
        }
        #expect(canonical != nil, "the importer resolved and wrote it")
        #expect(canonical != "19580875358", "and it wrote the CANONICAL id")

        let back = try #require(WeatherGearRepository.load(db).weather?.first)
        #expect(back.activityId == "19580875358",
                "the reader must hand back the id the store keys by")
    }

    /// THE EXCEPTION, ASSERTED SO NOBODY "FIXES" IT. `gear.externalID` is
    /// Strava's gear id and so is `Shoe.id`; `activity_alias` maps activities
    /// and would match no gear at all. A join added here out of symmetry with
    /// the weather query would return zero rows.
    @Test("Gear keys directly, with no alias in between")
    func gearKeysDirectlyWithNoAlias() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [shoe()])

        let stored = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT externalID FROM gear")
        }
        #expect(stored == "g123", "the column already holds Strava's id")
    }

    // MARK: The normalisation that is not a difference

    /// `ActivityWeather.source` is optional; `weather.provider` is NOT NULL and
    /// the importer writes `provider`, which is `source ?? .openMeteo`. So a nil
    /// source becomes "openMeteo" in the column and cannot come back as nil.
    ///
    /// Comparing `source` would report every pre-133 reading as differing.
    /// Comparing `provider` reports what both sides hold and every screen draws.
    /// 320a made the same call about a zero heart rate and refused to put it on
    /// the approved list, because an approved entry would have enshrined a wrong
    /// comparison as a data decision.
    @Test("A nil source normalises to Open-Meteo and is not a difference")
    func aNilSourceNormalisesAndIsNotADifference() throws {
        let db = try Sub4Database.inMemory()
        let original = weather("a1", source: nil)
        _ = try Sub4Import.run(into: db, activities: [activity("a1")], shoes: [],
                               weather: [original])

        let back = try #require(WeatherGearRepository.load(db).weather?.first)
        #expect(original.source == nil)
        #expect(back.source == .openMeteo, "the column cannot hold the absence")
        #expect(back.provider == original.provider, "and provider is what agrees")

        let r = compare(db, weather: [original], gear: [], known: ["a1"])
        #expect(r.isHealthy, "the normalisation is not a divergence")
        #expect(r.readingsWithNoStoredSource == 1,
                "but it is counted, so it is visible rather than hidden")
    }

    /// Apple Weather does round trip, which is what makes the test above a
    /// statement about the absence rather than about the provider column.
    @Test("Apple Weather comes back as Apple Weather")
    func theOtherProviderRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity("a1")], shoes: [],
                               weather: [weather("a1", source: .appleWeather)])
        let back = try #require(WeatherGearRepository.load(db).weather?.first)
        #expect(back.provider == .appleWeather)
    }

    // MARK: The explained absence

    /// `weather.activityID` is a foreign key. A reading whose activity the
    /// roster dropped CANNOT be stored — the importer counts those as
    /// `weatherUnmatched` — so reporting them as missing would paint the screen
    /// red for the database doing the only thing it can.
    @Test("A reading for an activity the app does not hold is explained, not missing")
    func aReadingForAnActivityTheAppDoesNotHoldIsExplained() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity("a1")], shoes: [],
                               weather: [weather("a1")])

        // The store holds a second reading whose activity was never imported.
        let r = compare(db, weather: [weather("a1"), weather("ghost")],
                        gear: [], known: ["a1"])
        #expect(r.readingsCompared == 1)
        #expect(r.readingsForUnknownActivities == 1)
        #expect(r.readingsOnlyInApp.isEmpty,
                "counted once, in the column that explains it")
        #expect(r.isHealthy)
    }

    /// The same shape with the activity PRESENT is a real gap and must fail.
    /// Without this pair the test above would be indistinguishable from a
    /// comparison that forgives everything.
    @Test("A reading missing for an activity the app does hold is a difference")
    func aGenuinelyMissingReadingFails() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity("a1"),
                                                     activity("a2")],
                               shoes: [], weather: [weather("a1")])

        let r = compare(db, weather: [weather("a1"), weather("a2")],
                        gear: [], known: ["a1", "a2"])
        #expect(r.readingsOnlyInApp == ["a2"])
        #expect(r.readingsForUnknownActivities == 0)
        #expect(!r.isHealthy)
    }

    // MARK: Rows this reader declines

    /// `weather.provider` is a frozen vocabulary with a CHECK constraint, like
    /// `user_note.feel` and `plan_session.discipline`. Mapping an unknown value
    /// to nil would silently resolve it to Open-Meteo through `provider`, which
    /// is the loudest possible version of a silent data change.
    ///
    /// Forced past the constraint for §12.65.11's reason — third use of that
    /// helper shape.
    @Test("An unknown provider is skipped and counted, not resolved to Open-Meteo")
    func anUnknownProviderIsSkipped() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity("a1")], shoes: [],
                               weather: [weather("a1")])
        try db.queue.writeWithoutTransaction { d in
            try d.execute(sql: "PRAGMA ignore_check_constraints = ON")
            defer { try? d.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
            try d.execute(sql: "UPDATE weather SET provider = 'metoffice'")
        }

        let load = WeatherGearRepository.load(db)
        #expect(load.isTrustworthy, "the read itself worked")
        #expect(load.weather?.isEmpty == true)
        #expect(load.skipped == 1)
    }

    @Test("The schema refuses an unknown provider through an ordinary write")
    func theSchemaRefusesAnUnknownProvider() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity("a1")], shoes: [],
                               weather: [weather("a1")])
        #expect(throws: DatabaseError.self) {
            try db.queue.write { d in
                try d.execute(sql: "UPDATE weather SET provider = 'metoffice'")
            }
        }
    }

    // MARK: The comparison

    @Test("The store and the database agree on every compared field")
    func theRealRoundTripAgrees() throws {
        let db = try Sub4Database.inMemory()
        let w = [weather("a1"), weather("a2", tempC: 4.0)]
        let g = [shoe(), shoe("g456", name: "Vaporfly", km: 88, primary: false)]
        _ = try Sub4Import.run(into: db,
                               activities: [activity("a1"), activity("a2")],
                               shoes: g, weather: w)

        let r = compare(db, weather: w, gear: g, known: ["a1", "a2"])
        #expect(r.isHealthy)
        #expect(r.readingsCompared == 2)
        #expect(r.readingFieldsCompared == 22, "eleven per reading")
        #expect(r.gearCompared == 2)
        #expect(r.gearFieldsCompared == 4, "two per item — the rest are approved")
        #expect(r.totalCompared == 4)
        #expect(r.unexplained == 0)
        #expect(r.gearCarryingRetirement == 0)
    }

    @Test("A changed field is caught and named")
    func aChangedFieldIsNamed() throws {
        let db = try Sub4Database.inMemory()
        let w = [weather("a1")]
        let g = [shoe()]
        _ = try Sub4Import.run(into: db, activities: [activity("a1")],
                               shoes: g, weather: w)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE weather SET windKmh = 99.0")
            try d.execute(sql: "UPDATE gear SET distanceM = 1.0")
        }

        let r = compare(db, weather: w, gear: g, known: ["a1"])
        #expect(!r.isHealthy)
        #expect(r.readingDifferences == ["a1 · windKmh"])
        #expect(r.gearDifferences == ["g123 · distanceM"])
        #expect(r.unexplained == 2)
    }

    /// `primary` is on the approved list, so changing it must NOT be reported —
    /// and this is the test that keeps the list honest. An approved entry that
    /// nothing exercises is a suppression nobody checked.
    @Test("A different primary flag is not a difference")
    func theApprovedDifferenceIsActuallyApproved() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [shoe(primary: true)])

        let r = compare(db, weather: [], gear: [shoe(primary: false)], known: [])
        #expect(r.gearDifferences.isEmpty)
        #expect(r.gearCompared == 1)
        #expect(WeatherGearRoundTrip.approved.count == 2)
        #expect(WeatherGearRoundTrip.approved.map(\.field)
                == ["Shoe.primary", "gear.retiredUTC"])
    }

    /// Gear alone may legitimately be empty — an athlete with no shoes on
    /// Strava is a real state — but weather is not, so zero readings is a
    /// failure rather than a quiet pass.
    @Test("No readings is not a pass, even with gear present")
    func nothingComparedIsNotAPass() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [shoe()])

        let r = compare(db, weather: [], gear: [shoe()], known: [])
        #expect(r.gearCompared == 1)
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy)
        #expect(r.summary == "nothing compared")
    }

    // MARK: The paste

    /// UNCONDITIONAL, every line, including the zeros — §12.54.2.
    @Test("The diagnostic lines are unconditional")
    func theDiagnosticLinesAreUnconditional() {
        let lines = WeatherGearRoundTrip.Report().diagnosticLines
        for needle in ["readings compared", "reading fields compared",
                       "readings for an activity the app does not hold",
                       "readings with no stored source",
                       "readings from Apple Weather",
                       "gear compared", "gear fields compared",
                       "gear carrying a retirement date",
                       "rows the reader could not read",
                       "approved differences", "unexplained differences"] {
            #expect(lines.contains { $0.contains(needle) },
                    "an empty report still prints \(needle)")
        }
    }
}
