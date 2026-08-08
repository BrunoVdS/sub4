//
//  DetailParityTests.swift
//  Sub4CoreTests
//
//  D6c slice 4 — details, splits and laps. Patch 320, ADR-0003 §12.63.
//
//  WHAT THESE ARE FOR
//  ------------------
//  Two of them prove the comparison works. The rest prove it can FAIL, which is
//  what groundwork §2.1 demands of every D6c slice: a check whose answer is
//  always "0 differences" cannot be told from a check that is broken, and D7
//  would be flipped on the strength of it.
//
//  The four that matter most:
//
//    `nilsOnBothSidesAreNotEvidence`   — 12 missing paces agreeing with 12
//                                        missing paces is a perfect result
//                                        describing nothing
//    `onlyTheClosingPaceMoves`         — the windows are genuinely distinct;
//                                        one changed split does not smear
//    `aZeroHeartRateReadsLikeAMissingOne`
//                                      — D6a's accepted loss, and whether it
//                                        costs a derived figure
//    `everyPaceWindowIsNamed`          — a window added to `ActivityDetail` and
//                                        not to `paceFigures` makes every other
//                                        test here quietly weaker
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct DetailParityTests {

    // MARK: Fixtures

    private func split(_ index: Int,
                       metres: Double = 1_000,
                       moving: Int = 330,
                       hr: Double? = 150) -> ActivityDetail.Split {
        ActivityDetail.Split(index: index, distanceM: metres, movingTime: moving,
                             elapsedTime: moving + 5, elevationDiff: 4,
                             averageHR: hr)
    }

    /// Five even kilometres. Every pace window this file compares can answer,
    /// which is what makes the denominators real rather than decorative.
    private func detail(_ id: String = "19580875358",
                        splits: [ActivityDetail.Split]? = nil,
                        laps: [ActivityDetail.Lap] = [],
                        polyline: String? = nil) -> ActivityDetail {
        ActivityDetail(activityId: id, calories: 512, descriptionText: nil,
                       averageCadence: 84, averageWatts: nil, maxWatts: nil,
                       deviceName: "Watch", polyline: polyline,
                       splits: splits ?? (1...5).map { split($0, moving: 330 + $0) },
                       bestEfforts: [], laps: laps,
                       fetched: Date(timeIntervalSince1970: 1_000_000))
    }

    private func lap(_ index: Int, metres: Double, seconds: Int,
                     hr: Double? = 165) -> ActivityDetail.Lap {
        ActivityDetail.Lap(index: index, distanceM: metres,
                           movingTime: seconds, averageHR: hr)
    }

    /// Four 800 m reps — not uniform enough to read as auto-lap, long enough to
    /// count as work.
    private var intervalLaps: [ActivityDetail.Lap] {
        [lap(1, metres: 800, seconds: 240), lap(2, metres: 800, seconds: 242),
         lap(3, metres: 800, seconds: 245), lap(4, metres: 800, seconds: 241)]
    }

    // MARK: It agrees when it should

    @Test("Identical sides agree on every derived figure")
    func identicalSidesAgree() {
        let d = detail(laps: intervalLaps)
        let r = DetailParity.compare(app: [d], database: [d])

        #expect(r.detailsCompared == 1)
        #expect(r.paceFiguresCompared == 12, "got \(r.paceFiguresCompared)")
        #expect(r.paceFiguresAnswered == 12, "five even kilometres answer them all")
        #expect(r.splitsCompared == 5)
        #expect(r.lapsCompared == 8, "four laps on each side")
        #expect(r.repsCompared == 4)
        #expect(r.unexplained == 0, "differed on \(r.paceFiguresDiffering)")
        #expect(r.lookedAtSomething)
        #expect(r.isHealthy)
    }

    /// Groundwork §2.1 case 2. Zero compared to zero agrees perfectly.
    @Test("Nothing compared is not a pass")
    func nothingComparedIsNotAPass() {
        let r = DetailParity.compare(app: [], database: [])
        #expect(r.unexplained == 0, "there is genuinely nothing to disagree about")
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy, "zero of zero must not read as healthy")
        #expect(r.summary.contains("nothing compared"))
    }

    /// THE ONE THAT KEEPS THE DENOMINATOR HONEST. A strength session has no
    /// splits, so every pace window returns nil on both sides — twelve
    /// agreements that describe nothing. `paceFiguresCompared` would say 12;
    /// only `paceFiguresAnswered` tells the truth.
    @Test("Twelve missing paces agreeing with twelve missing paces is not a pass")
    func nilsOnBothSidesAreNotEvidence() {
        let empty = detail(splits: [])
        let r = DetailParity.compare(app: [empty], database: [empty])

        #expect(r.detailsCompared == 1)
        #expect(r.paceFiguresCompared == 12)
        #expect(r.paceFiguresAnswered == 0, "nothing was actually answered")
        #expect(r.unexplained == 0)
        #expect(!r.lookedAtSomething,
                "a detail with no splits agrees about nothing at all")
        #expect(!r.isHealthy)
    }

    // MARK: The pace family — the negative controls

    @Test("A changed split time moves the paces, and they are named")
    func aChangedSplitTimeIsCaught() {
        let mine = detail()
        var theirSplits = (1...5).map { split($0, moving: 330 + $0) }
        theirSplits[2] = split(3, moving: 400)
        let theirs = detail(splits: theirSplits)

        let r = DetailParity.compare(app: [mine], database: [theirs])
        #expect(!r.isHealthy)
        #expect(!r.paceFiguresDiffering.isEmpty)
        #expect(r.paceFiguresDiffering.allSatisfy { $0.hasPrefix("19580875358 · ") },
                "a difference names the detail and the window")
        #expect(r.splitsWithDifferentPace == 1,
                "one split's derived pace moved, not five")
    }

    /// THE WINDOWS ARE DISTINCT, and this is how anybody knows. Changing the
    /// LAST kilometre must move `closing 1 km` and leave `opening 1 km` alone —
    /// a comparison that reported every window on every change would be
    /// indistinguishable from one that compared the whole detail once.
    @Test("Changing the last kilometre moves the closing pace, not the opening")
    func onlyTheClosingPaceMoves() {
        let mine = detail()
        var theirSplits = (1...5).map { split($0, moving: 330 + $0) }
        theirSplits[4] = split(5, moving: 300)
        let r = DetailParity.compare(app: [mine], database: [detail(splits: theirSplits)])

        let names = Set(r.paceFiguresDiffering.map {
            String($0.split(separator: "·").last ?? "").trimmingCharacters(in: .whitespaces)
        })
        #expect(names.contains("closing 1 km"))
        #expect(!names.contains("opening 1 km"), "the first kilometre did not move")
        #expect(!names.contains("opening 2 km"))
    }

    @Test("Changing the first kilometre moves the opening pace, not the closing")
    func onlyTheOpeningPaceMoves() {
        let mine = detail()
        var theirSplits = (1...5).map { split($0, moving: 330 + $0) }
        theirSplits[0] = split(1, moving: 300)
        let r = DetailParity.compare(app: [mine], database: [detail(splits: theirSplits)])

        let names = Set(r.paceFiguresDiffering.map {
            String($0.split(separator: "·").last ?? "").trimmingCharacters(in: .whitespaces)
        })
        #expect(names.contains("opening 1 km"))
        #expect(!names.contains("closing 1 km"), "the last kilometre did not move")
    }

    /// `displaySplits` drops a trailing fragment under 100 m. A fragment that
    /// survived on one side and not the other changes the table on screen, and
    /// every aggregate that walks the set.
    @Test("A fragment on one side only changes the split set")
    func aFragmentChangesTheSplitSet() {
        let mine = detail(splits: (1...5).map { split($0, moving: 330 + $0) })
        let withFragment = (1...5).map { split($0, moving: 330 + $0) }
            + [split(6, metres: 90, moving: 60)]
        let r = DetailParity.compare(app: [mine],
                                     database: [detail(splits: withFragment)])

        #expect(r.detailsWithDifferentSplitSet.isEmpty,
                "under 100 m, so displaySplits drops it on both sides")
        #expect(r.splitsCompared == 5, "five rows in the table either way")

        // AND YET ONE FIGURE MOVES. `overallPace` walks EVERY split, partial
        // and fragment alike, because it is the same arithmetic as the header —
        // while every windowed pace filters on `isPartial` and never sees it.
        // A comparison that only checked the table would have missed this.
        #expect(r.paceFiguresDiffering == ["19580875358 · overall"],
                "differed on \(r.paceFiguresDiffering)")
        #expect(!r.isHealthy)
    }

    @Test("A split the database does not have changes the set")
    func aMissingSplitChangesTheSet() {
        let mine = detail()
        let r = DetailParity.compare(
            app: [mine],
            database: [detail(splits: (1...4).map { split($0, moving: 330 + $0) })])
        #expect(r.detailsWithDifferentSplitSet == ["19580875358"])
        #expect(r.splitsCompared == 4, "only the four present on both sides")
        #expect(!r.isHealthy)
    }

    // MARK: D6a's accepted loss

    /// THE QUESTION THIS SLICE WAS BUILT TO ANSWER. The importer's
    /// `positiveOrNil` turns a zero average heart rate into nothing on twelve
    /// details. `hasHRSplits` is the only derived property that reads
    /// `averageHR`, and it asks `($0.averageHR ?? 0) > 0` — under which a stored
    /// zero and a missing value are the same answer.
    @Test("A zero heart rate and a missing one produce the same derived answer")
    func aZeroHeartRateReadsLikeAMissingOne() {
        let stored = detail(splits: (1...5).map { split($0, moving: 330 + $0, hr: 0) })
        let normalised = detail(splits: (1...5).map { split($0, moving: 330 + $0, hr: nil) })

        let r = DetailParity.compare(app: [stored], database: [normalised])
        #expect(r.appDetailsWithHRSplits == 0)
        #expect(r.databaseDetailsWithHRSplits == 0)
        #expect(r.hrSplitsLine == "0 vs 0")
        #expect(r.detailsWithDifferentFlags.isEmpty)
        #expect(r.splitsWithDifferentHR == 0, "the kilometre table draws neither")
        #expect(r.splitsWithNormalisedHR == 5, "and the carrier difference is counted")
        #expect(r.isHealthy, "the accepted loss must not cost a derived figure")
    }

    /// THE ONE THE DEVICE FOUND — patch 320a, §12.63.8. `IntervalDetector`
    /// copies `lap.averageHR` straight into `RepSplit.avgHR`, and the importer
    /// normalises a stored zero to nothing on laps as well as on splits. 320
    /// compared the carrier and reported 16 of 1,141 reps as divergent; the lap
    /// table guards `hr > 0` and drew both the same.
    @Test("A lap's zero heart rate is normalised, not a rep difference")
    func aZeroLapHeartRateIsNormalisedNotADifference() {
        let stored = intervalLaps.map {
            lap($0.index, metres: $0.distanceM, seconds: $0.movingTime, hr: 0)
        }
        let normalised = intervalLaps.map {
            lap($0.index, metres: $0.distanceM, seconds: $0.movingTime, hr: nil)
        }
        let r = DetailParity.compare(app: [detail(laps: stored)],
                                     database: [detail(laps: normalised)])
        #expect(r.repsCompared == 4)
        #expect(r.repsDiffering == 0, "the lap table guards hr > 0 and draws neither")
        #expect(r.repsWithNormalisedHR == 4, "and the carrier difference is counted")
        #expect(r.isHealthy)
    }

    /// AND IT IS NOT SIMPLY BLIND. A real heart rate against nothing still
    /// differs, and so does a real one against a different real one — without
    /// this pair the test above would pass on a comparison that stopped
    /// looking.
    @Test("A real lap heart rate against nothing is still a rep difference")
    func aRealLapHeartRateIsStillCompared() {
        let real = intervalLaps
        let gone = intervalLaps.map {
            lap($0.index, metres: $0.distanceM, seconds: $0.movingTime, hr: nil)
        }
        let missing = DetailParity.compare(app: [detail(laps: real)],
                                           database: [detail(laps: gone)])
        #expect(missing.repsDiffering == 4, "165 against nothing is a real loss")
        #expect(missing.repsWithNormalisedHR == 0)
        #expect(!missing.isHealthy)

        let moved = intervalLaps.map {
            lap($0.index, metres: $0.distanceM, seconds: $0.movingTime, hr: 171)
        }
        let changed = DetailParity.compare(app: [detail(laps: real)],
                                           database: [detail(laps: moved)])
        #expect(changed.repsDiffering == 4, "165 against 171 is a real difference")
        #expect(!changed.isHealthy)
    }

    /// The same pair for the kilometre table's heart-rate column, which 320
    /// did not compare at all.
    @Test("A split's heart rate is compared as the table draws it")
    func splitHeartRateIsComparedAsDrawn() {
        let real = detail()
        let gone = detail(splits: (1...5).map { split($0, moving: 330 + $0, hr: nil) })
        let r = DetailParity.compare(app: [real], database: [gone])
        #expect(r.splitsWithDifferentHR == 5, "150 against nothing is a real loss")
        #expect(r.splitsWithNormalisedHR == 0)
        #expect(!r.isHealthy)

        let rounded = detail(splits: (1...5).map { split($0, moving: 330 + $0, hr: 150.4) })
        let same = DetailParity.compare(app: [real], database: [rounded])
        #expect(same.splitsWithDifferentHR == 0, "the table draws Int(hr) — both 150")
        #expect(same.splitsWithNormalisedHR == 5, "and the carrier difference is counted")
        #expect(same.isHealthy)
    }

    /// `shownHR` is the rule every reader uses, stated once and asserted here
    /// so a change to `SplitTables` that stops guarding `hr > 0` shows up as a
    /// failing test rather than as a screen full of zeros.
    @Test("shownHR is what the tables draw")
    func shownHRMatchesTheTables() {
        #expect(DetailParity.shownHR(nil) == nil)
        #expect(DetailParity.shownHR(0) == nil, "nothing in this app draws a zero")
        #expect(DetailParity.shownHR(-1) == nil)
        #expect(DetailParity.shownHR(150) == 150)
        #expect(DetailParity.shownHR(150.9) == 150, "Int(hr), not rounded")
    }

    /// And the comparison is not simply blind to heart rate: a real one is
    /// seen on both sides. Without this, the test above would pass on a
    /// comparison that never looked.
    @Test("A real heart rate is still counted on both sides")
    func aRealHeartRateIsSeen() {
        let d = detail()
        let r = DetailParity.compare(app: [d], database: [d])
        #expect(r.appDetailsWithHRSplits == 1)
        #expect(r.databaseDetailsWithHRSplits == 1)
        #expect(r.hrSplitsLine == "1 vs 1")
    }

    /// A heart rate present on one side and genuinely absent on the other is a
    /// difference, not a normalisation.
    @Test("Heart-rate splits on one side only is a flag difference")
    func aOneSidedHeartRateIsADifference() {
        let withHR = detail()
        let without = detail(splits: (1...5).map { split($0, moving: 330 + $0, hr: nil) })
        let r = DetailParity.compare(app: [withHR], database: [without])
        #expect(r.detailsWithDifferentFlags == ["19580875358"])
        #expect(r.hrSplitsLine == "1 vs 0")
        #expect(!r.isHealthy)
    }

    // MARK: Membership

    @Test("A detail the database does not have is counted")
    func aMissingDetailIsCounted() {
        let r = DetailParity.compare(app: [detail("1"), detail("2")],
                                     database: [detail("1")])
        #expect(r.detailsOnlyInApp == ["2"])
        #expect(r.detailsCompared == 1)
        #expect(!r.isHealthy)
    }

    /// ABSENT ON PURPOSE IS NOT ABSENT — §12.42.2. `DataCorrections` refuses two
    /// sessions and the importer declines their details at the door, while
    /// `DetailStore` keeps them because it keys by Strava id. This calls
    /// `DataCorrections` rather than modelling it, so the two cannot drift.
    @Test("A detail refused on purpose is excluded, not missing")
    func aRefusedDetailIsExcludedNotMissing() throws {
        let refused = DataCorrections.ignoredActivities.keys.sorted().first
        let id = try #require(refused)

        let r = DetailParity.compare(app: [detail("1"), detail(id)],
                                     database: [detail("1")])
        #expect(r.detailsExcluded == [id])
        #expect(r.detailsOnlyInApp.isEmpty,
                "a refusal must not be reported as a loss")
        #expect(r.isHealthy, "and it must not fail the slice")
    }

    @Test("A detail only in the database is counted")
    func aSurplusDetailIsCounted() {
        let r = DetailParity.compare(app: [detail("1")],
                                     database: [detail("1"), detail("2")])
        #expect(r.detailsOnlyInDatabase == ["2"])
        #expect(!r.isHealthy)
    }

    // MARK: Laps, through the app's own detector

    @Test("The same laps read as the same reps")
    func lapsReadTheSameWay() {
        let d = detail(laps: intervalLaps)
        let r = DetailParity.compare(app: [d], database: [d])
        #expect(r.appDetailsReadAsIntervals == 1)
        #expect(r.databaseDetailsReadAsIntervals == 1)
        #expect(r.intervalLine == "1 vs 1")
        #expect(r.repsCompared == 4)
        #expect(r.repsDiffering == 0)
        #expect(r.detailsWithDifferentLapReading.isEmpty)
    }

    /// THE LOUDEST THING THIS SLICE CAN FIND: the same detector reaching
    /// different verdicts about whether a session was intervals at all.
    @Test("One side reading intervals and the other not is a difference")
    func aOneSidedIntervalReadingIsADifference() {
        let r = DetailParity.compare(app: [detail(laps: intervalLaps)],
                                     database: [detail(laps: [])])
        #expect(r.detailsWithDifferentLapReading == ["19580875358"])
        #expect(r.intervalLine == "1 vs 0")
        #expect(!r.isHealthy)
    }

    @Test("A changed lap duration changes a rep")
    func aChangedLapChangesARep() {
        var theirs = intervalLaps
        theirs[2] = lap(3, metres: 800, seconds: 300)
        let r = DetailParity.compare(app: [detail(laps: intervalLaps)],
                                     database: [detail(laps: theirs)])
        #expect(r.repsCompared == 4, "the denominator survives a difference")
        #expect(r.repsDiffering == 1)
        #expect(r.detailsWithDifferentLapReading.isEmpty,
                "the same number of reps, one of them different")
        #expect(!r.isHealthy)
    }

    /// Ten 1 km laps on an easy run are auto-lap, not reps, and the detector
    /// refuses them. Both sides must refuse them the same way, or every run in
    /// the app grows a LAPS tab on one side only.
    @Test("Auto-lap is refused on both sides")
    func autoLapIsRefusedOnBothSides() {
        let auto = (1...6).map { lap($0, metres: 1_000, seconds: 330 + $0) }
        let d = detail(laps: auto)
        let r = DetailParity.compare(app: [d], database: [d])
        #expect(r.appDetailsReadAsIntervals == 0)
        #expect(r.databaseDetailsReadAsIntervals == 0)
        #expect(r.lapsCompared == 12, "the laps were still offered and counted")
        #expect(r.isHealthy)
    }

    // MARK: Tolerance and the route

    @Test("Elevation carries a tolerance, and it is small")
    func elevationCarriesATolerance() {
        let mine = detail()
        var nudged = (1...5).map { split($0, moving: 330 + $0) }
        nudged[0] = ActivityDetail.Split(index: 1, distanceM: 1_000, movingTime: 331,
                                         elapsedTime: 336, elevationDiff: 4.005,
                                         averageHR: 150)
        let inside = DetailParity.compare(app: [mine],
                                          database: [detail(splits: nudged)])
        #expect(inside.detailsWithDifferentElevation.isEmpty,
                "five thousandths of a metre is arithmetic, not data")

        nudged[0] = ActivityDetail.Split(index: 1, distanceM: 1_000, movingTime: 331,
                                         elapsedTime: 336, elevationDiff: 9,
                                         averageHR: 150)
        let outside = DetailParity.compare(app: [mine],
                                           database: [detail(splits: nudged)])
        #expect(outside.detailsWithDifferentElevation == ["19580875358"])
    }

    @Test("A route on one side only is a flag difference")
    func aOneSidedRouteIsADifference() {
        let line = "_p~iF~ps|U_ulLnnqC_mqNvxq`@_ulLnnqC_mqNvxq`@"
        let r = DetailParity.compare(app: [detail(polyline: line)],
                                     database: [detail(polyline: nil)])
        #expect(r.routeLine == "1 vs 0")
        #expect(r.detailsWithDifferentFlags == ["19580875358"])
        #expect(!r.isHealthy)
    }

    // MARK: The list that keeps the rest honest

    /// A window added to `ActivityDetail` and not to `paceFigures` makes every
    /// other test in this file quietly weaker without failing any of them.
    /// This is the one that fails.
    @Test("Every derived pace on ActivityDetail is in the compared list")
    func everyPaceWindowIsNamed() {
        let names = DetailParity.paceFigures(detail()).map(\.name)
        #expect(names == ["overall", "median split", "fastest split",
                          "closing 1 km", "closing 2 km", "closing 4 km",
                          "opening 1 km", "opening 2 km",
                          "best 1 km", "best 2 km", "best 4 km", "best 5 km"],
                "the window list changed: \(names)")
        #expect(DetailParity.closingKilometres == [1, 2, 4])
        #expect(DetailParity.openingKilometres == [1, 2])
        #expect(DetailParity.windowKilometres == [1, 2, 4, 5])
    }

    /// The figures come off the type's own properties, not off a second
    /// implementation — §12.43. If they ever diverge, this is what says so.
    @Test("The compared figures are the type's own properties")
    func theFiguresAreTheTypesOwn() {
        let d = detail()
        let byName = Dictionary(DetailParity.paceFigures(d).map { ($0.name, $0.value) },
                                uniquingKeysWith: { first, _ in first })
        #expect(byName["overall"] == d.overallPace)
        #expect(byName["median split"] == d.medianSplitPace)
        #expect(byName["fastest split"] == d.fastestSplit?.paceSecPerKm)
        #expect(byName["closing 4 km"] == d.closingPace(km: 4))
        #expect(byName["opening 2 km"] == d.openingPace(km: 2))
        #expect(byName["best 5 km"] == d.bestWindowPace(km: 5))
    }

    // MARK: The paste

    /// UNCONDITIONAL, every line, including the zeros — 266c's rule, and
    /// §12.54.2's: a row that vanishes at zero cannot be told from a row nobody
    /// wired in.
    @Test("Every diagnostic line is present when nothing differs")
    func theDiagnosticLinesAreUnconditional() {
        let d = detail(laps: intervalLaps)
        let text = DetailParity.compare(app: [d], database: [d])
            .diagnosticLines.joined(separator: "\n")

        for expected in ["Detail parity: 1 details, 12 figures answered",
                         "held from the app: \(DetailParity.heldFromTheApp)",
                         "tolerance: \(DetailParity.toleranceLabel)",
                         "in the app only: 0",
                         "excluded on purpose: 0",
                         "in the database only: 0",
                         "pace figures compared: 12",
                         "pace figures both sides answered: 12",
                         "pace figures that differ: 0",
                         "splits compared: 5",
                         "splits with a different pace: 0",
                         "splits with a different heart rate: 0",
                         "splits whose zero heart rate was normalised: 0",
                         "laps offered to the detector: 8",
                         "details read as intervals: 1 vs 1",
                         "reps compared: 4",
                         "reps that differ: 0",
                         "reps whose zero heart rate was normalised: 0",
                         "details with heart-rate splits: 1 vs 1",
                         "details with a route: 0 vs 0",
                         "unexplained differences: 0"] {
            #expect(text.contains(expected), "the paste is missing: \(expected)")
        }
    }
}
