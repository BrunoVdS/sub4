//
//  SummaryParityTests.swift
//  Sub4CoreTests
//
//  The tab summaries, compared — D6c slice 8, patch 330, ADR-0003 §12.75.
//
//  WHAT THESE ARE FOR
//  ------------------
//  Groundwork §2.1: a check whose answer is always "0 differences" is
//  indistinguishable from a check that is broken. On the device this slice is
//  expected to report zero — slices 1, 5 and 6b already prove its inputs — so
//  these tests are the only thing that can say it would notice.
//
//  Four earn their place:
//
//    `aLongerRunHidingBehindTheSameTotalIsCaught`
//        — `longestRunKm` is the one MAXIMUM in a slice of sums. 10 + 10 and
//          4 + 16 agree on every other figure. If this test did not exist,
//          nothing would notice the long-run progression being wrong, which is
//          the number a marathon block is actually steered by.
//
//    `zeroWeeksIsNotHealthy`
//        — the four volume rows are compared unconditionally, so a
//          `totalCompared > 0` test could never be false. Without this, a
//          device that compared no weeks at all would show a green tick.
//
//    `aDayTheDatabaseHasNothingForIsVisible`
//        — every other figure is per WEEK. The day closure returns an empty
//          day for a missing key, which is §12.15 inside a lambda.
//
//    `theToleranceForgivesArithmeticAndNothingElse`
//        — sums of decimals end in different last digits; a tolerance that
//          swallowed a real difference would be worse than none.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct SummaryParityTests {

    // MARK: Fixtures

    private func point(_ no: Int,
                       plannedKm: Double = 30, plannedExact: Bool = true,
                       actualKm: Double = 28, longestRunKm: Double = 14,
                       done: Int = 3, total: Int = 4,
                       start: Double = 1_776_600_000) -> TabSummary.WeekPoint {
        TabSummary.WeekPoint(weekNo: no, start: Date(timeIntervalSince1970: start),
                             plannedKm: plannedKm, plannedExact: plannedExact,
                             actualKm: actualKm, longestRunKm: longestRunKm,
                             done: done, total: total)
    }

    private func volume(runKm: Double = 28, bikeHours: Double = 2,
                        swimKm: Double = 1.5, strengthSessions: Int = 2,
                        runExact: Bool = true) -> PlanStore.PlanVolume {
        PlanStore.PlanVolume(runKm: runKm, bikeHours: bikeHours, swimKm: swimKm,
                             strengthSessions: strengthSessions, runExact: runExact)
    }

    /// Everything agreeing, which is what the device is expected to show.
    private func compare(app: [TabSummary.WeekPoint],
                         database: [TabSummary.WeekPoint],
                         appActual: PlanStore.PlanVolume? = nil,
                         databaseActual: PlanStore.PlanVolume? = nil,
                         appPlanned: PlanStore.PlanVolume? = nil,
                         databasePlanned: PlanStore.PlanVolume? = nil,
                         daysAskedFor: Int = 7,
                         daysWithContentInApp: Int = 4,
                         daysWithContentInDatabase: Int = 4,
                         planSessionsInApp: Int = 261,
                         planSessionsInDatabase: Int = 261)
    -> SummaryParity.Report {
        SummaryParity.compare(app: app, database: database,
                              appActual: appActual ?? volume(),
                              databaseActual: databaseActual ?? volume(),
                              appPlanned: appPlanned ?? volume(),
                              databasePlanned: databasePlanned ?? volume(),
                              planSessionsInApp: planSessionsInApp,
                              planSessionsInDatabase: planSessionsInDatabase,
                              daysAskedFor: daysAskedFor,
                              daysWithContentInApp: daysWithContentInApp,
                              daysWithContentInDatabase: daysWithContentInDatabase)
    }

    // MARK: Agreement, and its denominators

    @Test("Identical sides agree, and every denominator is an exact product")
    func identicalSidesAgree() {
        let weeks = [point(1), point(2), point(3)]
        let r = compare(app: weeks, database: weeks)

        #expect(r.isHealthy)
        #expect(r.unexplained == 0)
        #expect(r.weeksCompared == 3)
        #expect(r.weekFieldsCompared == 21, "7 per week × 3")
        #expect(r.volumeRowsCompared == 4)
        #expect(r.volumeFieldsCompared == 9, "4 actual + 4 planned + runExact")
        #expect(r.totalCompared == 7)
        #expect(r.blockLine == "9 of 12 vs 9 of 12")
        #expect(!r.blockDiffers)
    }

    /// THE GREEN TICK THAT WOULD HAVE MEANT NOTHING. Four volume rows are
    /// compared whatever happens, so healthiness must not rest on them.
    @Test("Zero weeks compared is not healthy, however many volume rows ran")
    func zeroWeeksIsNotHealthy() {
        let r = compare(app: [], database: [])
        #expect(r.volumeRowsCompared == 4, "the rows still ran")
        #expect(r.totalCompared == 4)
        #expect(!r.lookedAtSomething, "and that is not a reason to call it looked at")
        #expect(!r.isHealthy)
        #expect(r.summary == "nothing compared")
    }

    // MARK: The sensitive figure

    /// A MAXIMUM HIDING BEHIND A SUM. Every other figure agrees.
    @Test("A different longest run behind the same total is caught")
    func aLongerRunHidingBehindTheSameTotalIsCaught() {
        let mine = [point(1, actualKm: 20, longestRunKm: 10)]
        let theirs = [point(1, actualKm: 20, longestRunKm: 16)]
        let r = compare(app: mine, database: theirs)

        #expect(r.weekDifferences == ["week 1 · longestRunKm"])
        #expect(r.unexplained == 1)
        #expect(!r.isHealthy)
    }

    @Test("Each week field is reported by its own name")
    func eachFieldIsNamed() {
        let base = point(1)
        let cases: [(String, TabSummary.WeekPoint)] = [
            ("week 1 · plannedKm", point(1, plannedKm: 31)),
            ("week 1 · plannedExact", point(1, plannedExact: false)),
            ("week 1 · actualKm", point(1, actualKm: 29)),
            ("week 1 · longestRunKm", point(1, longestRunKm: 15)),
            ("week 1 · done", point(1, done: 2)),
            ("week 1 · total", point(1, total: 5)),
            ("week 1 · start", point(1, start: 1_776_700_000))
        ]
        for (name, changed) in cases {
            let r = compare(app: [base], database: [changed])
            #expect(r.weekDifferences == [name], "\(name)")
        }
    }

    /// TWO DIFFERENCES, NOT ONE — and the first draft of this test expected
    /// one, which is what the run corrected. A week the database is missing
    /// changes the week set AND the block tally, because the block is summed
    /// from the week points. They are two claims about two numbers the athlete
    /// reads, and collapsing them would hide the second.
    @Test("A week on one side only is reported, not compared")
    func aWeekOnOneSideOnly() {
        let r = compare(app: [point(1), point(2)], database: [point(1)])
        #expect(r.weeksCompared == 1)
        #expect(r.weeksOnlyInApp == [2])
        #expect(r.weeksOnlyInDatabase.isEmpty)
        #expect(r.blockLine == "6 of 8 vs 3 of 4")
        #expect(r.blockDiffers, "a missing week is missing from the block too")
        #expect(r.unexplained == 2)
    }

    // MARK: The tolerance

    /// SUMS OF DECIMALS END IN DIFFERENT LAST DIGITS. A tolerance that
    /// swallowed a real difference would be worse than having none.
    @Test("The tolerance forgives arithmetic and nothing else")
    func theToleranceForgivesArithmeticAndNothingElse() {
        let arithmetic = compare(app: [point(1, actualKm: 28.0)],
                                 database: [point(1, actualKm: 28.0005)])
        #expect(arithmetic.weekDifferences.isEmpty, "half a metre is not data")

        let data = compare(app: [point(1, actualKm: 28.0)],
                           database: [point(1, actualKm: 28.02)])
        #expect(data.weekDifferences == ["week 1 · actualKm"], "twenty metres is")
    }

    /// INTEGERS ARE COMPARED EXACTLY. A tolerance on a session count would be
    /// an invitation.
    @Test("A one-session difference is a difference")
    func integersAreExact() {
        let r = compare(app: [point(1, done: 3)], database: [point(1, done: 4)])
        #expect(r.weekDifferences == ["week 1 · done"])
    }

    // MARK: The block tally

    @Test("The block tally is summed from the week points and differs when they do")
    func theBlockTallyIsSummed() {
        let mine = [point(1, done: 3, total: 4), point(2, done: 4, total: 4)]
        let theirs = [point(1, done: 3, total: 4), point(2, done: 3, total: 4)]
        let r = compare(app: mine, database: theirs)
        #expect(r.blockLine == "7 of 8 vs 6 of 8")
        #expect(r.blockDiffers)
        // The week difference AND the block difference — the block is a
        // separate claim about a separate number the athlete reads.
        #expect(r.unexplained == 2)
    }

    // MARK: The volume rows

    @Test("Every volume figure is reported by row and by side")
    func everyVolumeFigureIsNamed() {
        let cases: [(String, PlanStore.PlanVolume)] = [
            ("run · actual", volume(runKm: 29)),
            ("bike · actual", volume(bikeHours: 2.5)),
            ("swim · actual", volume(swimKm: 1.6)),
            ("strength · actual", volume(strengthSessions: 3))
        ]
        for (name, changed) in cases {
            let r = compare(app: [point(1)], database: [point(1)],
                            databaseActual: changed)
            #expect(r.volumeDifferences == [name], "\(name)")
        }

        let plannedCases: [(String, PlanStore.PlanVolume)] = [
            ("run · planned", volume(runKm: 29)),
            ("bike · planned", volume(bikeHours: 2.5)),
            ("swim · planned", volume(swimKm: 1.6)),
            ("strength · planned", volume(strengthSessions: 3)),
            ("run · plannedExact", volume(runExact: false))
        ]
        for (name, changed) in plannedCases {
            let r = compare(app: [point(1)], database: [point(1)],
                            databasePlanned: changed)
            #expect(r.volumeDifferences == [name], "\(name)")
        }
    }

    /// `runExact` describes a PLANNED figure's precision. `TabSummary
    /// .actualVolume` leaves it at its default because a recorded distance is
    /// measured, so comparing it on the actual side would compare two
    /// constants and could never fail.
    @Test("runExact is compared on the planned side only")
    func runExactIsPlannedSideOnly() {
        let r = compare(app: [point(1)], database: [point(1)],
                        databaseActual: volume(runExact: false))
        #expect(r.volumeDifferences.isEmpty,
                "an actual volume's runExact says nothing about anything")
    }

    // MARK: The day-shaped hole

    /// EVERY OTHER FIGURE IS PER WEEK. A closure returning an empty day for a
    /// key the database has nothing for is indistinguishable from a day that
    /// holds nothing — unless it is counted.
    @Test("A day the database has nothing for is visible")
    func aDayTheDatabaseHasNothingForIsVisible() {
        let r = compare(app: [point(1)], database: [point(1)],
                        daysAskedFor: 7,
                        daysWithContentInApp: 5,
                        daysWithContentInDatabase: 3)
        #expect(r.daysAskedFor == 7)
        #expect(r.daysWithContentInApp == 5)
        #expect(r.daysWithContentInDatabase == 3)
        #expect(r.diagnosticLines.contains { $0.contains("days asked for: 7") })
        #expect(r.diagnosticLines.contains { $0.contains("5 vs 3") })
    }

    // MARK: Context that is not a difference

    /// Slice 6b owns the plan. But a slice reading 261 sessions against 260
    /// would produce week differences with no visible cause, and this line is
    /// what gives them one.
    @Test("A plan size mismatch is printed but is not itself a difference")
    func aPlanSizeMismatchIsContext() {
        let r = compare(app: [point(1)], database: [point(1)],
                        planSessionsInApp: 261, planSessionsInDatabase: 260)
        #expect(r.unexplained == 0, "the numbers agreed; only their source did not")
        #expect(r.diagnosticLines.contains { $0.contains("261 vs 260") })
    }

    // MARK: The paste

    @Test("Every diagnostic line is present whether or not it is zero")
    func everyLineIsUnconditional() {
        let lines = compare(app: [point(1)], database: [point(1)]).diagnosticLines
        for needle in ["weeks in the app:", "weeks compared:", "week fields compared:",
                       "days asked for:", "volume rows compared:",
                       "volume fields compared:", "block sessions:",
                       "week fields that differ:", "volume figures that differ:",
                       "tolerance:", "held from the app:",
                       "unexplained differences:"] {
            #expect(lines.contains { $0.contains(needle) }, "\(needle)")
        }
    }

    /// SHORTER THAN EVERY OTHER SLICE'S, and the test says so rather than
    /// leaving it to be noticed: this is the only slice that reads the plan
    /// from the database instead of holding it from the app.
    @Test("This slice holds only the match decisions")
    func thisSliceHoldsOnlyTheDecisions() {
        #expect(SummaryParity.heldFromTheApp == "the match decisions")
        #expect(!SummaryParity.verifiedByReadBack.isEmpty,
                "an empty string would read as everything being verified")
        #expect(MatchParity.heldFromTheApp.contains("plan"),
                "slice 5 holds the plan; slice 8 does not, and that is the finding")
    }
}
