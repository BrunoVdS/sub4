//
//  WeatherImportTests.swift
//  Sub4CoreTests
//
//  Weather, and the re-keying — patch 226, ADR-0003 §12.9.
//
//  THE ONE THAT MATTERS IS `theStravaKeyIsResolvedThroughTheAlias`. Weather is
//  stored against a Strava activity id and the schema holds it against the
//  canonical one; if that resolution ever silently failed, every reading would
//  land in `weatherUnmatched` and the screen would report a tidy zero-refusal
//  import that stored nothing.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct WeatherImportTests {

    private func activity(_ id: String) -> Activity {
        Activity(id: id, name: "Session", sportType: "Run",
                 startLocal: "2026-07-28T07:24:06", distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T05:24:06Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func weather(_ activityId: String,
                         tempC: Double = 18.5,
                         humidity: Double = 0.62,
                         samples: Int = 3,
                         source: WeatherSource? = .openMeteo) -> ActivityWeather {
        ActivityWeather(activityId: activityId, tempC: tempC, feelsLikeC: 17.1,
                        humidity: humidity, windKmh: 14.0, windFromDegrees: 225,
                        precipitationMm: 0.4, symbolName: "cloud.sun",
                        conditionLabel: "Partly cloudy", samples: samples,
                        fetched: Date(timeIntervalSince1970: 1_780_000_000),
                        source: source)
    }

    /// THE ONE THAT MATTERS. `weather.json` is keyed by Strava activity id;
    /// `weather.activityID` references the canonical activity. §8 records the
    /// Strava-keyed dictionary as a known gap to be re-keyed at 4A M4 — this
    /// import is what closes it, so the resolution has to be asserted rather
    /// than assumed.
    @Test("The Strava key is resolved through the alias to the canonical activity")
    func theStravaKeyIsResolvedThroughTheAlias() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [activity("19580875358")],
                                        shoes: [], weather: [weather("19580875358")])

        #expect(report.weatherImported == 1)
        #expect(report.weatherUnmatched == 0)

        let (stored, canonical) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT activityID FROM weather"),
             try String.fetchOne(d, sql: "SELECT id FROM activity"))
        }
        #expect(stored == canonical)
        #expect(stored != "19580875358", "the Strava id was carried into the weather row")
    }

    /// A reading about an activity that is not here cannot be stored, and that
    /// is the schema being right rather than the import being wrong. Counted,
    /// not refused — the two mean different things and conflating them would
    /// make a correct decline look like a defect.
    @Test("Weather for a missing activity is counted, not refused")
    func orphanWeatherIsCountedNotRefused() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        weather: [weather("not-imported")])
        #expect(report.weatherSeen == 1)
        #expect(report.weatherImported == 0)
        #expect(report.weatherUnmatched == 1)
        #expect(report.refusals.isEmpty, "a correct decline was reported as a refusal")
    }

    @Test("Every field of a reading arrives")
    func aReadingArrivesWhole() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [activity("1")], shoes: [],
                               weather: [weather("1")])
        let row = try db.queue.read { d in
            try Row.fetchOne(d, sql: "SELECT * FROM weather")
        }
        let r = try #require(row)
        #expect(r["provider"] as String? == "openMeteo")
        #expect(r["tempC"] as Double? == 18.5)
        #expect(r["feelsLikeC"] as Double? == 17.1)
        #expect(r["humidity"] as Double? == 0.62)
        #expect(r["windKmh"] as Double? == 14.0)
        #expect(r["windFromDegrees"] as Double? == 225)
        #expect(r["precipitationMm"] as Double? == 0.4)
        #expect(r["symbolName"] as String? == "cloud.sun")
        #expect(r["conditionLabel"] as String? == "Partly cloudy")
        #expect(r["samples"] as Int? == 3)
        #expect(r["fetchedUTC"] as String? != nil)
    }

    /// `ActivityWeather.source` is optional and `provider` falls back to
    /// `.openMeteo`. The column is NOT NULL with a CHECK, so the fallback has
    /// to produce a value the constraint accepts — a nil that reached the
    /// column would refuse the row.
    @Test("A reading with no recorded source still names a provider")
    func theProviderFallbackSatisfiesTheConstraint() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [activity("1")],
                                        shoes: [], weather: [weather("1", source: nil)])
        #expect(report.weatherImported == 1)
        let provider = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT provider FROM weather")
        }
        #expect(provider == "openMeteo")
    }

    @Test("Re-importing a reading refreshes it rather than adding a second")
    func weatherConverges() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("1")]
        let first = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                       weather: [weather("1", tempC: 18.5)])
        let second = try Sub4Import.run(into: db, activities: acts, shoes: [],
                                        weather: [weather("1", tempC: 21.0)])
        #expect(first.weatherImported == 1)
        #expect(second.weatherImported == 0)
        #expect(second.weatherUpdated == 1)

        let (count, temp) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM weather") ?? -1,
             try Double.fetchOne(d, sql: "SELECT tempC FROM weather"))
        }
        #expect(count == 1, "the unique constraint on activityID did not hold")
        #expect(temp == 21.0)
    }

    /// The CHECK bounds are the store's own rules restated in SQL. A reading
    /// that somehow got past `WeatherStore` must not take the others with it.
    @Test("A reading the schema refuses does not cost the others")
    func aRefusedReadingIsIsolated() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(
            into: db,
            activities: [activity("good"), activity("bad")],
            shoes: [],
            weather: [weather("good"), weather("bad", humidity: 4.0)])   // 0…1
        #expect(report.weatherImported == 1)
        #expect(report.refusals.count == 1)
        #expect(report.refusals.first?.externalID.contains("bad") == true)
    }

    /// `WeatherSource` and the frozen vocabulary inside the migration must
    /// agree, or a perfectly good reading is refused by a CHECK on a value the
    /// app produces. Same shape as `SchemaAgreementTests` for disciplines.
    @Test("Every weather source the app has can be stored")
    func everySourceIsAccepted() throws {
        for source in WeatherSource.allCases {
            let db = try Sub4Database.inMemory()
            let report = try Sub4Import.run(into: db, activities: [activity("1")],
                                            shoes: [], weather: [weather("1", source: source)])
            #expect(report.weatherImported == 1,
                    "\(source.rawValue) is not in the migration's provider list")
        }
    }
}
