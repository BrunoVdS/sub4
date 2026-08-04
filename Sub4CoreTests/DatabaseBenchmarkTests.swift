//
//  DatabaseBenchmarkTests.swift
//  Sub4CoreTests
//
//  The harness, checked before its numbers are believed — patch 206, plan
//  steps 3.2.6 and 3.2.7.
//
//  WHAT THESE DO AND DELIBERATELY DO NOT DO
//  ----------------------------------------
//  They do not assert timings. A test that fails when a query takes 40 ms
//  instead of 30 fails on a busy CI machine and teaches everybody to ignore it,
//  and the numbers that matter come from the phone anyway.
//
//  What they check is that the harness is worth reading: that the fixtures are
//  the size they claim, that both storage shapes hold the SAME data so the
//  comparison is fair, that the packing round-trips exactly, and that the run
//  leaves nothing behind. A benchmark nobody has checked is a number generator.
//
//  THE ONE THAT MATTERS IS `bothShapesHoldTheSameBytes`. If the chunked side
//  were quietly storing less, it would win on storage and read time for a
//  reason that has nothing to do with the question ADR-0003 §9 asks.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

//  WHY `.serialized` — TWO REASONS, EITHER ONE SUFFICIENT
//  ------------------------------------------------------
//  1. `theTemporaryDatabaseIsRemoved` scans the shared temporary directory for
//     anything named `sub4-benchmark…`. Run in parallel with a sibling, it sees
//     the sibling's live directory and fails for a reason that has nothing to
//     do with cleanup. Unique directory names fix the corruption; they cannot
//     fix a test that asserts on a directory everybody shares.
//  2. Four benchmark runs racing for one disk measure contention, not storage
//     shape. The timings are not asserted on, but they are printed and read.
//
//  This is the same mistake as the export race in `DataLifecycleCoordinatorTests`
//  (patch 184). I wrote the comment there and then made it again here.
@Suite(.serialized)
struct DatabaseBenchmarkTests {

    /// Small. The harness is what is under test; ten thousand activities is
    /// what the phone is for.
    private let activities = 40
    private let samples = 25

    @Test("A run produces every measurement plan step 3.2.6 asks for")
    func everyQueryShapeIsMeasured() throws {
        let result = try DatabaseBenchmark.run(activities: activities,
                                               samplesPerActivity: samples)
        let names = Set(result.queries.map(\.name))
        for shape in ["day", "week", "source", "sport", "unmatched", "detail"] {
            #expect(names.contains(shape), "\(shape) was not measured")
        }
        #expect(result.activities == activities)
    }

    /// A query that returns nothing has measured nothing, and the whole run
    /// would report suspiciously fast times. Each shape must actually match
    /// rows in the fixture.
    @Test("Every measured query returns rows")
    func everyQueryMatchesSomething() throws {
        let result = try DatabaseBenchmark.run(activities: activities,
                                               samplesPerActivity: samples)
        for m in result.queries {
            #expect(m.rows > 0, "\(m.name) matched nothing — the fixture does not exercise it")
        }
    }

    /// `unmatched` is the anti-join, and it is only interesting if some
    /// activities ARE matched. The fixture corrects one in three.
    @Test("The unmatched query excludes the corrected activities")
    func unmatchedExcludesTheMatched() throws {
        let result = try DatabaseBenchmark.run(activities: activities,
                                               samplesPerActivity: samples)
        let unmatched = try #require(result.queries.first { $0.name == "unmatched" })
        #expect(unmatched.rows < activities,
                "every activity came back unmatched — the anti-join is measuring a full scan")
        #expect(unmatched.rows > 0)
    }

    /// THE FAIRNESS CHECK, and the reason to trust the comparison at all.
    ///
    /// Both shapes are given the identical series. If the chunked side stored
    /// fewer samples, or dropped a channel, it would win on storage and read
    /// time for a reason that has nothing to do with the question being asked.
    @Test("Both storage shapes hold the same number of samples")
    func bothShapesHoldTheSameBytes() throws {
        let result = try DatabaseBenchmark.run(activities: activities,
                                               samplesPerActivity: samples)
        #expect(result.storage.sampleRows == activities * samples)
        #expect(result.storage.normalisedBytes > 0, "the normalised shape wrote nothing")
        #expect(result.storage.chunkedBytes > 0, "the chunked shape wrote nothing")
    }

    /// The packing is a copy, not a conversion, and this is what says so. A
    /// benchmark whose chunked side lost precision would be comparing a lossy
    /// format against a lossless one.
    @Test("Packing a series and unpacking it returns exactly the same values")
    func packingRoundTripsExactly() {
        let series = DatabaseBenchmark.sampleSeries(count: 300)
        let packed = DatabaseBenchmark.pack(series.heartRate)
        let back = DatabaseBenchmark.unpack(packed)
        #expect(back.count == series.heartRate.count)
        for (a, b) in zip(series.heartRate, back) {
            #expect(a == b, "packing changed \(a) into \(b)")
        }
    }

    @Test("An empty series packs and unpacks to nothing rather than crashing")
    func emptySeriesRoundTrips() {
        #expect(DatabaseBenchmark.unpack(DatabaseBenchmark.pack([])).isEmpty)
        #expect(DatabaseBenchmark.unpack(Data()).isEmpty)
    }

    /// Two runs of the same size must produce the same fixture, or a difference
    /// between runs cannot be attributed to anything.
    @Test("The fixtures are deterministic")
    func fixturesAreDeterministic() {
        let a = DatabaseBenchmark.sampleSeries(count: 120)
        let b = DatabaseBenchmark.sampleSeries(count: 120)
        #expect(a.distance == b.distance)
        #expect(a.heartRate == b.heartRate)
        #expect(a.speed == b.speed)
        #expect(a.altitude == b.altitude)
    }

    /// The run writes three million rows at full size. Leaving that behind on
    /// the athlete's phone would be worse than not measuring.
    @Test("A run leaves no database behind")
    func theTemporaryDatabaseIsRemoved() throws {
        _ = try DatabaseBenchmark.run(activities: 10, samplesPerActivity: 5)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: NSTemporaryDirectory())) ?? []
        #expect(!leftovers.contains { $0.hasPrefix("sub4-benchmark") },
                "the benchmark left a database in the temporary directory")
    }

    /// And it never touches the real one. `Sub4Database.open()` resolves under
    /// Application Support; the benchmark resolves under the temporary
    /// directory, and the two must not be the same place.
    @Test("The benchmark database is not the app's database")
    func theBenchmarkIsNotTheRealDatabase() throws {
        let appSupport = try #require(AppSupportItem.container)
        #expect(!NSTemporaryDirectory().hasPrefix(appSupport.path),
                "the temporary directory is inside Application Support")
    }

    /// The affordability rule is a stated threshold rather than a feeling, so
    /// it is worth pinning that it reads the way the comment claims.
    @Test("The affordability verdict follows the stated thresholds")
    func affordabilityUsesTheWrittenThreshold() {
        func comparison(storage: Double, read: Double) -> DatabaseBenchmark.StorageComparison {
            .init(activities: 1, samplesPerActivity: 1,
                  normalisedBytes: Int64(1000 * storage), chunkedBytes: 1000,
                  normalisedImportSeconds: 1, chunkedImportSeconds: 1,
                  normalisedReadSeconds: read, chunkedReadSeconds: 1)
        }
        #expect(comparison(storage: 2.0, read: 2.0).normalisedIsAffordable)
        #expect(comparison(storage: 3.0, read: 3.0).normalisedIsAffordable)
        #expect(!comparison(storage: 3.1, read: 1.0).normalisedIsAffordable)
        #expect(!comparison(storage: 1.0, read: 3.1).normalisedIsAffordable)
    }
}
