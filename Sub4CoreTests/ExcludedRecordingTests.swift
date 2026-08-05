//
//  ExcludedRecordingTests.swift
//  Sub4CoreTests
//
//  What an excluded recording costs, and what it stops costing — patch 256.
//
//  The August 2025 Romania file was refused by the schema on every import and
//  kept by the app, and ADR §12.12.5 recorded that as a decision. A day of
//  living with it showed the decision had three consequences rather than one: a
//  raw SQLite CHECK failure printed on the health screen every run, and — because
//  a refused activity gets no `activity_alias` — its trace and its detail both
//  reporting "with no activity". One decision, three lines that read as faults.
//
//  Excluding it in both places is what these tests hold in place. The thing most
//  worth protecting is the LAST one: that an exclusion is never silent.
//
//  PATCH 257 — THE FOURTH HEAD
//  ---------------------------
//  256 counted three consequences and fixed three. There were four. The same
//  recording also has a weather reading, and weather resolves through
//  `activity_alias` exactly as the trace and the detail do, so it kept landing
//  in `weatherUnmatched` — one grey line still saying "with no activity" about
//  a recording the app had already ruled on.
//
//  Worth naming, because the miss was not in the reasoning but in the sweep:
//  the two consequences that had just been on screen got fixed and the third
//  sharing the same mechanism did not. The mechanism is "resolves through the
//  alias". The way to find all of them is to grep for that lookup, not to
//  recall which screens complained.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct ExcludedRecordingTests {

    /// The one this patch is about.
    private let romania = "18883849470"
    /// The one that was already there, so these tests fail if the list is
    /// replaced rather than added to.
    private let swim = "16775873379"

    @Test("The Romania recording is excluded, with its reason")
    func theRomaniaRideIsListed() throws {
        #expect(DataCorrections.isIgnored(id: romania))
        let reason = try #require(DataCorrections.ignoredActivities[romania])
        // Every entry names the session and says what was wrong with it — the
        // rule at the top of `DataCorrections`.
        #expect(reason.contains("8.04 days"))
    }

    @Test("The earlier exclusion is still there")
    func theListWasAddedToNotReplaced() {
        #expect(DataCorrections.isIgnored(id: swim))
        #expect(DataCorrections.ignoredActivities.count == 2)
    }

    @Test("An excluded activity never reaches the store")
    func theAppDropsIt() {
        let a = Activity(id: romania, name: "Romania", sportType: "Ride",
                         startLocal: "2025-08-10T09:00:00",
                         distance: 199_200, movingTime: 70_153,
                         elapsedTime: 694_865,
                         elevationGain: 2403, averageHeartrate: nil,
                         isTrainer: nil, maxHeartrate: nil, gearId: nil,
                         maxSpeed: 30.6, deviceWatts: nil, averageWatts: 62.5,
                         startUTC: nil, startLat: nil, startLon: nil)
        #expect(DataCorrections.isIgnored(a))
        // Which is what stops the importer ever offering it, and therefore what
        // stops the CHECK constraint firing. The database never sees the row.
    }

    @Test("Its trace is counted as excluded, not as missing an activity")
    func theTraceIsAttributed() throws {
        let db = try Sub4Database.inMemory(label: "excluded-trace")
        let trace = ActivityStreams(activityId: romania,
                                    distanceM: [0, 100, 200, 300, 400, 500, 600, 700],
                                    fetched: Date(timeIntervalSince1970: 776_000_000))
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        streams: [trace], appVersion: "256")
        #expect(report.recordingsIgnored == 1)
        // The distinction this patch exists for. "Unmatched" means the activity
        // is not there and nobody knows why; "ignored" means it is not there
        // because of a decision with a reason next to it.
        #expect(report.recordingsUnmatched == 0)
        #expect(report.recordingsSeen == 0)
    }

    @Test("Its detail is counted as excluded too")
    func theDetailIsAttributed() throws {
        let db = try Sub4Database.inMemory(label: "excluded-detail")
        let detail = ActivityDetail(activityId: romania,
                                    splits: [], bestEfforts: [], laps: [],
                                    fetched: Date(timeIntervalSince1970: 776_000_000))
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        details: [detail], appVersion: "256")
        #expect(report.detailsIgnored == 1)
        #expect(report.detailsUnmatched == 0)
        #expect(report.detailsSeen == 0)
    }

    // MARK: The one 256 missed — patch 257

    @Test("Its weather is counted as excluded, not as an orphan")
    func theWeatherIsAttributed() throws {
        let db = try Sub4Database.inMemory(label: "excluded-weather")
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        weather: [reading(for: romania)],
                                        appVersion: "257")
        #expect(report.weatherIgnored == 1)
        // The line that stayed at 1 through patch 256 while the other three
        // went to zero.
        #expect(report.weatherUnmatched == 0)
        // Never counted as attempted, either. Counting it seen and then
        // declining it would put it back in a total the screen reads as work.
        #expect(report.weatherSeen == 0)
    }

    @Test("Weather for an activity that is simply absent is still unmatched")
    func aRealWeatherOrphanIsStillAnOrphan() throws {
        // The counterweight, same as `aRealGapIsStillAGap` below. An id nobody
        // has ruled on, with no activity behind it, is an orphan and says so —
        // "anything larger means activities are missing that should not be" is
        // the sentence this counter exists to keep true.
        let db = try Sub4Database.inMemory(label: "real-orphan")
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        weather: [reading(for: "99999999")],
                                        appVersion: "257")
        #expect(report.weatherUnmatched == 1)
        #expect(report.weatherIgnored == 0)
        #expect(report.weatherSeen == 1)
    }

    /// A reading with plausible values. Nothing here is asserted on — the
    /// subject is which counter it lands in, not what it says about the sky.
    private func reading(for activityId: String) -> ActivityWeather {
        ActivityWeather(activityId: activityId, tempC: 24.1, feelsLikeC: 25.0,
                        humidity: 0.55, windKmh: 9.0, windFromDegrees: 180,
                        precipitationMm: 0.0, symbolName: "sun.max",
                        conditionLabel: "Clear", samples: 4,
                        fetched: Date(timeIntervalSince1970: 776_000_000),
                        source: .openMeteo)
    }

    // MARK: Real gaps stay gaps

    @Test("A trace for an activity that is simply absent is still unmatched")
    func aRealGapIsStillAGap() throws {
        // The counter that must NOT swallow everything. An id nobody has ruled
        // on, with no activity behind it, is a gap and says so.
        let db = try Sub4Database.inMemory(label: "real-gap")
        let trace = ActivityStreams(activityId: "99999999",
                                    distanceM: [0, 100, 200, 300, 400, 500, 600, 700],
                                    fetched: Date(timeIntervalSince1970: 776_000_000))
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        streams: [trace], appVersion: "256")
        #expect(report.recordingsUnmatched == 1)
        #expect(report.recordingsIgnored == 0)
    }

    @Test("An import holding only excluded material refuses nothing")
    func nothingIsRefused() throws {
        // The whole point on screen: `Refused` returns to zero, so the next
        // entry that appears there is news.
        let db = try Sub4Database.inMemory(label: "no-refusals")
        let trace = ActivityStreams(activityId: romania,
                                    distanceM: [0, 100, 200, 300, 400, 500, 600, 700],
                                    fetched: Date(timeIntervalSince1970: 776_000_000))
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        streams: [trace], appVersion: "256")
        #expect(report.refusals.isEmpty)
        #expect(report.isClean)
    }

    @Test("Every exclusion is readable, so none of them is silent")
    func exclusionsAreVisible() {
        // `Settings` prints these. A recording the app throws away without
        // saying so is indistinguishable from one it failed to fetch — the rule
        // this file's subject was written under.
        #expect(DataCorrections.ignoredReasons.count == DataCorrections.ignoredActivities.count)
        let joined = DataCorrections.ignoredReasons.joined(separator: " ")
        #expect(joined.contains("Romania"))
        #expect(joined.contains("swim"))
    }
}

/// DELIBERATELY NOT `@MainActor` — patch 258, and that is the entire test.
///
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` put `DataCorrections` on the
/// main actor without anyone deciding it should be there, and the three
/// importers that read it are `nonisolated static func`. That produced three
/// warnings — two shipped in 256, one in 257 — and 472 then 474 tests passed
/// over the top of them, because a warning is not a failure and this build is
/// loud enough that three more lines scroll past.
///
/// Nothing below asserts a value that the suite above does not already assert.
/// What it asserts is that this file still COMPILES: if `isIgnored(id:)` or
/// `ignoredActivities` goes back to being main-actor isolated, these two
/// functions stop building, and a build failure is the only thing that stops
/// for a warning-shaped defect.
@Suite
struct ExcludedRecordingNonisolationTests {

    @Test("The by-id lookup is callable without the main actor")
    func theLookupIsNonisolated() {
        // The exact call the importers make, from the exact isolation they
        // make it in.
        #expect(DataCorrections.isIgnored(id: "18883849470"))
        #expect(!DataCorrections.isIgnored(id: "99999999"))
    }

    @Test("The table itself is readable without the main actor")
    func theTableIsNonisolated() {
        // `isIgnored(id:)` could have been made nonisolated on its own by
        // copying the table behind an accessor. It was not: the table is a
        // compile-time literal that nothing mutates, so there was never a race
        // for an actor to prevent. This holds that reasoning in place.
        #expect(DataCorrections.ignoredActivities.count == 2)
    }
}
