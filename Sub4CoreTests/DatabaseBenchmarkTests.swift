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

    /// THE ONE THAT WAS MISSING, AND THE DEFECT IT WOULD HAVE CAUGHT.
    ///
    /// Patch 209 read both shapes with `"R\(activities / 2)"`, but the chunked
    /// table keys its rows `"C\(i)"` — so the chunked read matched no row,
    /// unpacked an empty blob, and the phone reported a read cost of ×0.28
    /// with a straight face. Every other test above passed.
    ///
    /// A read that returns nothing is the fastest read there is. Timing one
    /// without checking what came back is not a benchmark, it is a stopwatch.
    @Test("Both shapes hand back the same values when read")
    func bothShapesReturnWhatTheyStored() throws {
        let result = try DatabaseBenchmark.run(activities: activities,
                                               samplesPerActivity: samples)
        let s = result.storage
        #expect(s.readsSampled > 0, "no recording was read at all")
        #expect(s.normalisedValuesRead == s.readsSampled * samples,
                "normalised returned \(s.normalisedValuesRead)")
        #expect(s.chunkedValuesRead == s.readsSampled * samples,
                "chunked returned \(s.chunkedValuesRead) — a key that matches nothing reads very fast")
        #expect(s.readsAgree)
    }

    /// And the verdict refuses to speak when the reads disagree, because a
    /// number computed from a measurement known to be broken is the one that
    /// ends up quoted in the ADR.
    @Test("A failed read check withholds the verdict")
    func abrokenReadWithholdsTheVerdict() {
        let broken = DatabaseBenchmark.StorageComparison(
            activities: 10, samplesPerActivity: 300,
            normalisedBytes: 1000, chunkedBytes: 1000,
            normalisedImportSeconds: 1, chunkedImportSeconds: 1,
            normalisedReadSeconds: 1, chunkedReadSeconds: 1,
            readsSampled: 10, normalisedValuesRead: 3000, chunkedValuesRead: 0)
        let withheld = broken.diagnosticLines.filter { $0.contains("WITHHELD") }
        #expect(!broken.readsAgree)
        #expect(broken.readCheckLabel.contains("MISMATCH"))
        #expect(!withheld.isEmpty)
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

    // MARK: The verdict — patch 212

    /// A comparison over 1,000 activities with everything comfortably inside
    /// budget, which each test below then pushes out of budget one dimension
    /// at a time.
    private func comparison(readSeconds: Double = 0.02,       // 1 ms per recording
                            importSeconds: Double = 2,        // 2 ms per activity
                            normalisedBytes: Int64 = 20_000_000,  // 200 MB at 10,000
                            chunkedBytes: Int64 = 10_000_000)
    -> DatabaseBenchmark.StorageComparison {
        .init(activities: 1_000, samplesPerActivity: 300,
              normalisedBytes: normalisedBytes, chunkedBytes: chunkedBytes,
              normalisedImportSeconds: importSeconds, chunkedImportSeconds: 1,
              normalisedReadSeconds: readSeconds, chunkedReadSeconds: 0.01,
              readsSampled: 20, normalisedValuesRead: 6000, chunkedValuesRead: 6000)
    }

    /// Every collection operation below is computed into a local BEFORE the
    /// macro sees it. `#expect` decomposes a call it can parse into
    /// `Testing.__checkFunctionCall`, which is `rethrows` — so `allSatisfy`,
    /// `filter` and `first(where:)` written inline demand a `try` for an error
    /// a key path cannot throw. This bit me twice; precomputing is the habit
    /// that stops it.
    @Test("A shape inside every budget is affordable")
    func insideBudgetIsAffordable() {
        let c = comparison()
        let checks = c.budgetChecks
        let failed = checks.filter { !$0.passes }
        #expect(c.normalisedIsAffordable)
        #expect(checks.count == 3)
        #expect(failed.isEmpty)
    }

    /// One dimension at a time, so a failure names which budget broke rather
    /// than only that the verdict changed.
    @Test("Each budget can fail on its own")
    func eachBudgetBites() {
        func failedNames(_ c: DatabaseBenchmark.StorageComparison) -> [String] {
            c.budgetChecks.filter { !$0.passes }.map(\.name)
        }

        // 6 ms per recording, over the 5 ms budget.
        let slowRead = comparison(readSeconds: 0.12)
        let slowReadFailures = failedNames(slowRead)
        #expect(!slowRead.normalisedIsAffordable)
        #expect(slowReadFailures == ["Read a trace"])

        // 60 ms per activity, over the 50 ms budget.
        let slowImport = comparison(importSeconds: 60)
        let slowImportFailures = failedNames(slowImport)
        #expect(!slowImport.normalisedIsAffordable)
        #expect(slowImportFailures == ["Import an activity"])

        // 600 MB projected to 10,000, over the 500 MB budget.
        let fat = comparison(normalisedBytes: 60_000_000)
        let fatFailures = failedNames(fat)
        let namesStorage = fatFailures.first?.hasPrefix("Storage") ?? false
        #expect(!fat.normalisedIsAffordable)
        #expect(fatFailures.count == 1)
        #expect(namesStorage)
    }

    /// THE POINT OF PATCH 212, PINNED.
    ///
    /// The old rule compared the shapes to each other, so three runs on one
    /// phone gave read ratios of ×5.04, ×4.73 and ×2.73 and the verdict
    /// flipped between identical runs. These two comparisons have IDENTICAL
    /// absolute costs and wildly different ratios — chunked fast in one, slow
    /// in the other — and must reach the same verdict.
    @Test("The verdict ignores how the other shape performed")
    func theRatioNoLongerDecides() {
        let chunkedFast = comparison(chunkedBytes: 1_000_000)     // storage ×20
        let chunkedSlow = comparison(chunkedBytes: 19_000_000)    // storage ×1.05
        #expect(chunkedFast.storageRatio > 10)
        #expect(chunkedSlow.storageRatio < 1.1)
        #expect(chunkedFast.normalisedIsAffordable == chunkedSlow.normalisedIsAffordable,
                "the verdict moved when only the OTHER shape changed")
        #expect(chunkedFast.normalisedIsAffordable)
    }

    /// Scaling, so a 500-activity run and a 10,000-activity run are judged
    /// against the same number rather than against their own size.
    @Test("Storage is projected to the design target before it is judged")
    func storageIsProjected() {
        let small = comparison(normalisedBytes: 20_000_000)                 // 1,000 activities
        #expect(small.normalisedBytesAtDesignTarget == 200_000_000)
    }

    // MARK: Patch 209 — batching, cancellation, and the pasted numbers

    /// THE ONE THAT EARNS ITS PLACE.
    ///
    /// Patch 209 split every insert loop into `batchSize` chunks so a phone run
    /// does not hold three million rows in one transaction. An off-by-one in
    /// that walk — `start += batchSize` before the body, a `min` the wrong way
    /// round, a half-open range read as closed — drops or duplicates activities
    /// silently, and every timing above would still look plausible.
    ///
    /// So the fixture is deliberately sized to cross a boundary, and the
    /// expected counts are recomputed here from the fixture's own rules. That
    /// duplication is the point: it is a second, independent statement of what
    /// the fixture contains.
    @Test("Batching neither drops nor duplicates activities")
    func batchingCoversEveryActivityExactlyOnce() throws {
        let n = DatabaseBenchmark.batchSize + 1      // crosses exactly one boundary
        let s = 4
        let result = try DatabaseBenchmark.run(activities: n, samplesPerActivity: s)

        #expect(result.activities == n)
        #expect(result.storage.sampleRows == n * s)

        // The fixture corrects one activity in three, so the anti-join returns
        // the rest. Stated independently of the code that builds it.
        let corrected = (0..<n).filter { $0 % 3 == 0 }.count
        let unmatched = try #require(result.queries.first { $0.name == "unmatched" })
        #expect(unmatched.rows == n - corrected,
                "expected \(n - corrected) unmatched, got \(unmatched.rows)")

        #expect(result.storage.normalisedBytes > 0)
        #expect(result.storage.chunkedBytes > 0)
    }

    /// A run one row short of a boundary and one row past it must agree about
    /// what a single activity costs. If they disagree, the walk is skipping or
    /// repeating work at the seam.
    @Test("A size either side of a batch boundary behaves the same per activity")
    func theBoundaryIsNotSpecial() throws {
        let b = DatabaseBenchmark.batchSize
        let under = try DatabaseBenchmark.run(activities: b - 1, samplesPerActivity: 4)
        let over = try DatabaseBenchmark.run(activities: b + 1, samplesPerActivity: 4)
        #expect(under.storage.sampleRows == (b - 1) * 4)
        #expect(over.storage.sampleRows == (b + 1) * 4)
    }

    /// "Stop" has to stop. A button that hid the spinner while three million
    /// inserts carried on would be worse than no button, because the athlete
    /// would put the phone in a pocket.
    ///
    /// Deterministic rather than racy: `eachBatch` checks BEFORE each batch, so
    /// a task cancelled before its first batch throws without doing the work.
    @Test("A cancelled run throws instead of finishing")
    func cancellationStopsTheRun() async throws {
        let task = Task.detached {
            try DatabaseBenchmark.run(activities: 5_000, samplesPerActivity: 50)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        // And it still cleans up after itself, which is the half of the
        // contract a thrown error is most likely to break.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: NSTemporaryDirectory())) ?? []
        #expect(!leftovers.contains { $0.hasPrefix("sub4-benchmark") },
                "a cancelled run left its database behind")
    }

    /// The copy button is how these numbers reach ADR-0003 §9. If the pasted
    /// text omits a query shape or the verdict, the decision gets made from a
    /// partial reading and nobody notices, because the screen looked complete.
    @Test("The pasted diagnostic carries every shape and the verdict")
    func theDiagnosticIsComplete() throws {
        let result = try DatabaseBenchmark.run(activities: 40, samplesPerActivity: 10)
        let text = result.diagnosticLines.joined(separator: "\n")
        for shape in ["day", "week", "source", "sport", "unmatched", "detail"] {
            #expect(text.contains(shape), "\(shape) is missing from the diagnostic")
        }
        #expect(text.contains("Verdict:"))
        #expect(text.contains("Ratios"))
        #expect(text.contains("Normalised:"))
        #expect(text.contains("Chunked:"))
        // Patch 212: the budgets decide, so a diagnostic without them cannot
        // be checked by whoever it is pasted to.
        #expect(text.contains("Read a trace"))
        #expect(text.contains("Import an activity"))
        #expect(text.contains("Storage at"))
    }

    /// The screen shows one line and nothing else while a ten-thousand run
    /// grinds away for minutes. If that line never moves, or arrives in the
    /// wrong order, the only signal the athlete has is wrong — and patch 210
    /// rebuilt the delivery path (an `AsyncStream` in place of one Task per
    /// line) precisely because the old one could not promise the order.
    ///
    /// This checks the source of that stream, which is the half that can be
    /// checked without a screen.
    @Test("A run reports progress in stage order, with no blank lines")
    func progressIsReportedInOrder() throws {
        var lines: [String] = []
        _ = try DatabaseBenchmark.run(activities: DatabaseBenchmark.batchSize + 1,
                                      samplesPerActivity: 4) { lines.append($0) }

        #expect(!lines.isEmpty, "a multi-batch run reported nothing")
        // Computed OUTSIDE the macro. `#expect` decomposes a call it can see
        // into `__checkFunctionCall` and treats the predicate as `rethrows`,
        // so `contains(where:)` written inline demands a `try` for an error
        // that a key path cannot throw. Filtering first sidesteps the
        // decomposition and reads better anyway.
        let blank = lines.filter(\.isEmpty)
        #expect(blank.isEmpty, "a blank progress line would blank the screen")

        let build = try #require(lines.firstIndex { $0.hasPrefix("Building activities") })
        let normalised = try #require(lines.firstIndex { $0.hasPrefix("Importing normalised") })
        let chunked = try #require(lines.firstIndex { $0.hasPrefix("Importing chunked") })
        #expect(build < normalised)
        #expect(normalised < chunked)
    }
}
