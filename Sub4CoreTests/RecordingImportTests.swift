//
//  RecordingImportTests.swift
//  Sub4CoreTests
//
//  The traces and the details — patch 243, ADR-0003 §12.12.
//
//  THE ONE THAT MATTERS IS `aBackwardsTraceIsRefusedWhole`. Every other rule in
//  `recording_sample` is a column CHECK the database enforces on its own. That
//  one is not expressible as a CHECK — the migration says so in as many words —
//  which means it holds only for as long as this test does.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct RecordingImportTests {

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

    private func streams(_ activityId: String,
                         distance: [Double] = [0, 100, 200, 300, 400, 500, 600, 700],
                         heartRate: [Double]? = nil,
                         power: [Double]? = nil,
                         fetched: Date = Date(timeIntervalSince1970: 1_780_000_000))
    -> ActivityStreams {
        ActivityStreams(activityId: activityId, distanceM: distance,
                        heartRate: heartRate, speed: nil, altitude: nil,
                        grade: nil, power: power, latitude: nil, longitude: nil,
                        fetched: fetched)
    }

    private func detail(_ activityId: String,
                        splits: [ActivityDetail.Split] = [],
                        laps: [ActivityDetail.Lap] = [],
                        efforts: [ActivityDetail.BestEffort] = [],
                        fetched: Date = Date(timeIntervalSince1970: 1_780_000_000))
    -> ActivityDetail {
        ActivityDetail(activityId: activityId, calories: 640,
                       descriptionText: "Felt good", averageCadence: 84,
                       averageWatts: nil, maxWatts: nil,
                       deviceName: "Garmin Forerunner", polyline: "abc123",
                       splits: splits, bestEfforts: efforts, laps: laps,
                       fetched: fetched)
    }

    private func split(_ index: Int, hr: Double? = 148,
                       distance: Double = 1000) -> ActivityDetail.Split {
        .init(index: index, distanceM: distance, movingTime: 341,
              elapsedTime: 345, elevationDiff: 4, averageHR: hr)
    }

    // MARK: The rule the schema cannot state

    /// THE ONE THAT MATTERS. `distanceM >= 0` is a column CHECK; "never
    /// decreasing" is not expressible as one and lives in the importer. A trace
    /// whose x axis doubles back draws a chart that lies, and every pace read
    /// between those two points is nonsense.
    @Test("A trace whose distance goes backwards is refused whole")
    func aBackwardsTraceIsRefusedWhole() throws {
        let db = try Sub4Database.inMemory()
        let bad = streams("1", distance: [0, 100, 200, 150, 300, 400, 500, 600])
        let report = try Sub4Import.run(into: db, activities: [activity("1")],
                                        shoes: [], streams: [bad])

        #expect(report.recordingsImported == 0)
        #expect(report.refusals.count == 1)
        let reason = report.refusals.first?.reason ?? ""
        #expect(reason.contains("decreases at sample 3"))

        let (recordings, samples) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM recording") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM recording_sample") ?? -1)
        }
        #expect(recordings == 0)
        #expect(samples == 0, "a refused trace left samples behind")
    }

    /// Refused BEFORE anything is written, so one bad trace costs the others
    /// nothing.
    @Test("A refused trace does not cost the good ones")
    func aRefusedTraceIsIsolated() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(
            into: db, activities: [activity("good"), activity("bad")], shoes: [],
            streams: [streams("good"),
                      streams("bad", distance: [0, 100, 90, 200, 300, 400, 500, 600])])
        #expect(report.recordingsImported == 1)
        #expect(report.refusals.count == 1)
    }

    @Test("A flat section is not a decrease")
    func aFlatSectionIsAllowed() {
        #expect(Sub4Import.firstDecrease(in: [0, 100, 100, 100, 200]) == nil)
        #expect(Sub4Import.firstDecrease(in: [0]) == nil)
        #expect(Sub4Import.firstDecrease(in: []) == nil)
        #expect(Sub4Import.firstDecrease(in: [0, 100, 99]) == 2)
    }

    // MARK: Traces

    @Test("A trace and its samples arrive in order")
    func aTraceArrivesInOrder() throws {
        let db = try Sub4Database.inMemory()
        let s = streams("19580875358",
                        distance: [0, 100, 200, 300, 400, 500, 600, 700],
                        heartRate: [120, 130, 140, 145, 150, 152, 155, 158])
        let report = try Sub4Import.run(into: db, activities: [activity("19580875358")],
                                        shoes: [], streams: [s])

        #expect(report.recordingsImported == 1)
        #expect(report.samplesImported == 8)

        let (count, distances, stored, canonical) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT sampleCount FROM recording"),
             try Double.fetchAll(d, sql: "SELECT distanceM FROM recording_sample ORDER BY ordinal"),
             try String.fetchOne(d, sql: "SELECT activityID FROM recording"),
             try String.fetchOne(d, sql: "SELECT id FROM activity"))
        }
        #expect(count == 8)
        #expect(distances == [0, 100, 200, 300, 400, 500, 600, 700])
        #expect(stored == canonical)
        #expect(stored != "19580875358", "the Strava id was carried into the recording")
    }

    /// A series Strava returns shorter than the x axis must not crash the
    /// import or shift readings onto the wrong samples. The tail is NULL, which
    /// is what NULL means in this table.
    @Test("A short series runs out into nulls rather than crashing")
    func aShortSeriesBecomesNulls() throws {
        let db = try Sub4Database.inMemory()
        let s = streams("1", heartRate: [120, 130, 140])
        _ = try Sub4Import.run(into: db, activities: [activity("1")], shoes: [],
                               streams: [s])
        let hrs = try db.queue.read { d in
            try Optional<Double>.fetchAll(d, sql: """
                SELECT heartRate FROM recording_sample ORDER BY ordinal
                """)
        }
        #expect(hrs.count == 8)
        #expect(hrs[0] == 120)
        #expect(hrs[2] == 140)
        #expect(hrs[3] == nil, "a short series was padded rather than left absent")
    }

    /// A trace under eight samples is below what the app charts and is still a
    /// fact about a recording that stopped.
    @Test("A short trace is imported and counted")
    func aShortTraceIsImportedAndCounted() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [activity("1")],
                                        shoes: [], streams: [streams("1", distance: [0, 50, 100])])
        #expect(report.recordingsImported == 1)
        #expect(report.recordingsShort == 1)
    }

    @Test("A trace for an activity that is not here is counted, not refused")
    func anOrphanTraceIsCounted() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        streams: [streams("missing")])
        #expect(report.recordingsSeen == 1)
        #expect(report.recordingsUnmatched == 1)
        #expect(report.refusals.isEmpty)
    }

    @Test("An unchanged trace is left alone")
    func anUnchangedTraceIsSkipped() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("1")]
        let s = streams("1")
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [], streams: [s])
        let second = try Sub4Import.run(into: db, activities: acts, shoes: [], streams: [s])
        #expect(second.recordingsUnchanged == 1)
        #expect(second.samplesImported == 0, "the samples were rewritten for nothing")
    }

    /// A re-fetched trace replaces the old one whole — and its samples go with
    /// it, or the recording would carry the union of two traces.
    @Test("A re-fetched trace replaces the samples rather than adding to them")
    func aRefetchedTraceReplacesItsSamples() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("1")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               streams: [streams("1")])
        let second = try Sub4Import.run(
            into: db, activities: acts, shoes: [],
            streams: [streams("1", distance: [0, 10, 20],
                              fetched: Date(timeIntervalSince1970: 1_790_000_000))])

        #expect(second.recordingsUpdated == 1)
        let (recordings, samples) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM recording") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM recording_sample") ?? -1)
        }
        #expect(recordings == 1)
        #expect(samples == 3, "the old trace's samples survived the replacement")
    }

    // MARK: Details

    /// The splits are why this migration exists — `closingPace(km:)` reads them
    /// to answer "last 4 km at marathon pace", and they had nowhere to go.
    @Test("A detail arrives with its splits, laps and best efforts")
    func aDetailArrivesWhole() throws {
        let db = try Sub4Database.inMemory()
        let dt = detail("1",
                        splits: [split(1), split(2), split(3)],
                        laps: [.init(index: 1, distanceM: 5000, movingTime: 1705,
                                     averageHR: 151)],
                        efforts: [.init(name: "1k", seconds: 320),
                                  .init(name: "5k", seconds: 1705)])
        let report = try Sub4Import.run(into: db, activities: [activity("1")],
                                        shoes: [], details: [dt])

        #expect(report.detailsImported == 1)
        #expect(report.splitsImported == 3)
        #expect(report.lapsImported == 1)
        #expect(report.effortsImported == 2)

        let (device, ordinals, effortNames) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT deviceName FROM activity_detail"),
             try Int.fetchAll(d, sql: "SELECT ordinal FROM activity_split ORDER BY ordinal"),
             try String.fetchAll(d, sql: """
                SELECT name FROM activity_best_effort ORDER BY ordinal
                """))
        }
        #expect(device == "Garmin Forerunner")
        #expect(ordinals == [1, 2, 3], "the 1-based split index was renumbered")
        #expect(effortNames == ["1k", "5k"])
    }

    @Test("A re-fetched detail replaces its splits rather than stacking them")
    func aRefetchedDetailReplacesItsParts() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("1")]
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [],
                               details: [detail("1", splits: [split(1), split(2)])])
        let second = try Sub4Import.run(
            into: db, activities: acts, shoes: [],
            details: [detail("1", splits: [split(1)],
                             fetched: Date(timeIntervalSince1970: 1_790_000_000))])
        #expect(second.detailsUpdated == 1)
        let splits = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM activity_split") ?? -1
        }
        #expect(splits == 1)
    }

    @Test("An unchanged detail is left alone")
    func anUnchangedDetailIsSkipped() throws {
        let db = try Sub4Database.inMemory()
        let acts = [activity("1")]
        let dt = detail("1", splits: [split(1)])
        _ = try Sub4Import.run(into: db, activities: acts, shoes: [], details: [dt])
        let second = try Sub4Import.run(into: db, activities: acts, shoes: [], details: [dt])
        #expect(second.detailsUnchanged == 1)
        #expect(second.splitsImported == 0)
    }

    @Test("A detail for an activity that is not here is counted, not refused")
    func anOrphanDetailIsCounted() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        details: [detail("missing")])
        #expect(report.detailsUnmatched == 1)
        #expect(report.refusals.isEmpty)
    }

    /// One unstorable split must not cost the whole detail's neighbours.
    ///
    /// THIS TEST USED A ZERO HEART RATE UNTIL PATCH 244, which was the right
    /// example right up until the moment the importer started converting zero
    /// to NULL — after which it asserted the defect rather than the rule, and
    /// failed the moment the fix landed. A NEGATIVE DISTANCE is refusable in a
    /// way nothing coerces: `distanceM >= 0` is a column CHECK and no boundary
    /// rewrites it, so the isolation is still exercised on something the
    /// database genuinely will not take.
    @Test("A split the schema refuses does not cost the others")
    func aRefusedSplitIsIsolated() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(
            into: db, activities: [activity("ok"), activity("bad")], shoes: [],
            details: [detail("ok", splits: [split(1)]),
                      detail("bad", splits: [split(1, distance: -1)])])
        #expect(report.detailsImported == 1)
        #expect(report.refusals.count == 1)
        let named = report.refusals.first?.externalID ?? ""
        #expect(named.contains("bad"))
    }

    /// PATCH 244, AND THE REASON IT EXISTS. Strava sends
    /// `average_heartrate: 0` for a lap it has no reading for. Left
    /// unconverted it violates `averageHeartrate IS NULL OR > 0`, the savepoint
    /// rolls back, and the whole detail is lost over one lap — twelve of them
    /// on the real device, splits and all.
    @Test("A lap with a zero heart rate becomes null rather than losing the detail")
    func aZeroHeartRateLapDoesNotCostTheDetail() throws {
        let db = try Sub4Database.inMemory()
        let dt = detail("1",
                        splits: [split(1), split(2, hr: 0)],
                        laps: [.init(index: 1, distanceM: 5000, movingTime: 1705,
                                     averageHR: 0),
                               .init(index: 2, distanceM: 5000, movingTime: 1700,
                                     averageHR: 151)])
        let report = try Sub4Import.run(into: db, activities: [activity("1")],
                                        shoes: [], details: [dt])

        #expect(report.detailsImported == 1)
        #expect(report.refusals.isEmpty, "a zero heart rate cost the whole detail")
        #expect(report.lapsImported == 2)
        #expect(report.splitsImported == 2)

        let (lapHRs, splitHRs) = try db.queue.read { d in
            (try Optional<Double>.fetchAll(d, sql: """
                SELECT averageHeartrate FROM activity_lap ORDER BY ordinal
                """),
             try Optional<Double>.fetchAll(d, sql: """
                SELECT averageHeartrate FROM activity_split ORDER BY ordinal
                """))
        }
        #expect(lapHRs == [nil, 151], "zero was stored as a heart rate")
        #expect(splitHRs == [148, nil])
    }

    /// The same rule at the OTHER boundary — where a freshly fetched detail is
    /// built from Strava's JSON. Both exist on purpose: this one stops new
    /// zeros arriving, the importer's copy stops the 378 already cached on disk
    /// from failing.
    @Test("Zero is converted to absent at the decoding boundary")
    func zeroIsConvertedWhenDecoding() {
        #expect(StravaDetailDTO.positiveOrNil(0) == nil)
        #expect(StravaDetailDTO.positiveOrNil(-1) == nil)
        #expect(StravaDetailDTO.positiveOrNil(nil) == nil)
        #expect(StravaDetailDTO.positiveOrNil(151) == 151)
    }

    @Test("The new migration is declared and applied")
    func theMigrationIsDeclared() throws {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.activityDetail))
        let db = try Sub4Database.inMemory()
        let applied = try db.integrityReport().appliedMigrations
        #expect(applied.contains(Sub4Migrations.activityDetail))
    }
}
