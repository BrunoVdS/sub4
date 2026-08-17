//
//  DiagnosticCoverageTests.swift
//  Sub4CoreTests
//
//  Every section on the Database screen says its numbers — patch 391,
//  ADR-0003 §12.135.
//
//  WHAT THIS FILE EXISTS FOR
//  -------------------------
//  Twenty-three sections draw on that screen. Nineteen of them put their
//  breakdown into the diagnostics paste through a `diagnosticLines` of their
//  own; four did not, and those four are the three most expensive comparisons
//  the app makes plus the write-through:
//
//    ActivityRoundTrip.Report    694 activities × nineteen named fields
//    DetailRoundTrip.Report      694 details, every split, lap and best effort
//    RecordingRoundTrip.Report   668 recordings over 199,848 samples
//    DatabaseWriteThrough        never in the paste at all
//
//  The roll-up (patch 333) fixed the VERDICT for the first three — `Activities:
//  694 compared, no differences` survives the sheet and reaches the paste — and
//  left the BREAKDOWN inside a `@State` that dies with it. So the only way to
//  read WHICH field differed was a screenshot, which is §12.57's evaporation one
//  level down from the defect the roll-up was written to close.
//
//  TWO PROPERTIES ARE WORTH TESTING AND THE SECOND IS THE ONE WITH TEETH
//  ---------------------------------------------------------------------
//  · every line prints at zero — §12.54.2, a block that appears only when
//    something is wrong cannot be told from a block nobody wired in
//  · **NO ATHLETE IDENTIFIER REACHES THE PASTE.** All three reports carry the
//    ids in `missing`, `excluded`, `unreadable` and `differences`, because the
//    SCREEN prints a handful of them. §12.7 promises the paste does not, and
//    that promise is made in the footer of the section the athlete taps.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Every section says its numbers")
@MainActor
struct DiagnosticCoverageTests {

    /// A Strava id no honest line would ever contain, so a leak is unambiguous.
    private let leak = "9988776655"

    // MARK: Activities

    @Test("The activity read-back prints every line at zero")
    func activityLinesAtZero() {
        let l = ActivityRoundTrip.Report(compared: 0).diagnosticLines
        #expect(l.count == 5)
        #expect(l[0] == "Activity read-back: 0 compared")
        #expect(l.contains("  agreed: 0"))
        #expect(l.contains("  in the app and not in the database: 0"))
        #expect(l.contains("  activities with a differing field: 0"))
        #expect(l.contains("  fields that differ: none"),
                "none, not an empty list — a bare blank reads as a missing line")
    }

    @Test("The activity tally names the field and never the activity")
    func activityTallyNamesTheField() {
        var r = ActivityRoundTrip.Report(compared: 694)
        r.missing = [leak]
        r.differences = [.init(id: leak, fields: ["distance", "movingTime"]),
                         .init(id: "111", fields: ["distance"])]
        let text = r.diagnosticLines.joined(separator: "\n")

        #expect(text.contains("  agreed: 692"))
        #expect(text.contains("  in the app and not in the database: 1"))
        #expect(text.contains("distance 2"), "the tally is the line worth reading")
        #expect(text.contains("movingTime 1"))
        #expect(!text.contains(leak), "§12.7 — the ids stay on the screen")
    }

    // MARK: Details

    @Test("The detail read-back prints every line at zero")
    func detailLinesAtZero() {
        let l = DetailRoundTrip.Report(compared: 0).diagnosticLines
        #expect(l.count == 6)
        #expect(l[0] == "Detail read-back: 0 compared")
        #expect(l.contains("  excluded on purpose: 0"),
                "counted apart from missing — §12.42.2")
        #expect(l.contains("  fields that differ: none"))
    }

    /// **BOTH TALLY NUMBERS, because patch 295 bought the distinction.**
    /// Thirteen details with one bad lap each and thirteen details with forty
    /// bad laps between them share the first number and are nothing alike in
    /// the second.
    @Test("The detail tally carries details and elements separately")
    func detailTallyCarriesBothNumbers() {
        var r = DetailRoundTrip.Report(compared: 694)
        r.excluded = [leak]
        r.differences = [
            .init(id: leak, fields: ["laps[index: 1].averageHR",
                                     "laps[index: 2].averageHR"]),
            .init(id: "111", fields: ["laps[index: 9].averageHR"])
        ]
        let text = r.diagnosticLines.joined(separator: "\n")

        #expect(text.contains("  excluded on purpose: 1"))
        #expect(text.contains("2 details / 3 elements"),
                "two details carry it, three laps inside them do")
        #expect(!text.contains(leak), "§12.7 — the ids stay on the screen")
    }

    // MARK: Recordings

    @Test("The recording read-back prints every line at zero")
    func recordingLinesAtZero() {
        let l = RecordingRoundTrip.Report(databaseCount: 0, compared: 0)
            .diagnosticLines
        #expect(l.count == 10)
        #expect(l[0] == "Recording read-back: 0 compared")
        #expect(l.contains("  samples walked: 0"))
        #expect(l.contains("  fields that differ: none"))
        #expect(l.contains("  samples that differ: none"))
    }

    /// **`databaseCount` IS AN OPTIONAL AND NIL IS NOT ZERO.** Its own doc says
    /// so: nil means the id read failed, and "0 recordings in the database" over
    /// a read that never happened is the sentence §12.15 exists to stop.
    @Test("An unknown database count does not print as zero")
    func unknownIsNotZero() {
        let l = RecordingRoundTrip.Report(databaseCount: nil, compared: 0)
            .diagnosticLines
        #expect(l.contains("  recordings in the database: unknown"))
        #expect(!l.contains("  recordings in the database: 0"))
    }

    /// A failed id read means everything under it is unknown rather than zero,
    /// so the block says that and stops rather than printing nine zeros.
    @Test("A failed read says so and prints no counts under it")
    func aFailedReadPrintsNoCounts() {
        var r = RecordingRoundTrip.Report(databaseCount: nil, compared: 0)
        r.readFailure = "the database is locked"
        let l = r.diagnosticLines

        #expect(l[0] == "Recording read-back: the database could not be read")
        #expect(l.contains("  why: the database is locked"))
        #expect(l.contains("  nothing below this line was compared"))
        #expect(!l.contains(where: { $0.contains("samples walked") }),
                "a zero under a read that did not happen is not a zero")
    }

    /// The band is the finding — "91 of 186,204" — and a per-recording count
    /// cannot give it. §12.39.
    @Test("The sample tally carries the band, and no ids")
    func theSampleTallyCarriesTheBand() {
        var r = RecordingRoundTrip.Report(databaseCount: 668, compared: 668)
        r.unreadable = [.init(id: leak, why: "unreadable")]
        r.differences = [.init(id: leak, fields: ["heartRate"], detail: "x")]
        r.walked = ["heartRate": 186_204, "distanceM": 186_204]
        r.differing = ["heartRate": 91]
        let text = r.diagnosticLines.joined(separator: "\n")

        #expect(text.contains("  recordings the reader could not read: 1"))
        #expect(text.contains("  samples walked: 372408"))
        #expect(text.contains("heartRate 91 of 186204"))
        #expect(!text.contains(leak), "§12.7 — the ids stay on the screen")
    }

    // MARK: The write-through

    /// **THE ONLY SECTION ON THAT SCREEN THAT HAD NEVER REACHED THE PASTE.**
    /// A launch where nothing changed must still produce the block — "not run"
    /// and "runs: 0" are the answer, and a block that appeared only after a
    /// write could not be told from one nobody wired in. §12.54.2.
    @Test("The write-through speaks on a launch where it never ran")
    func writeThroughSpeaksBeforeItRuns() {
        let l = DatabaseWriteThrough.diagnosticLines(.never, runs: 0,
                                                     isRunning: false)
        #expect(l.count == 4)
        #expect(l[0] == "Write-through: Not run since this launch.")
        #expect(l.contains("  runs this launch: 0"))
        #expect(l.contains("  running right now: no"))
        #expect(l.contains("  healthy: yes"),
                "never having run is not a fault")
    }

    /// **THE TWO STATES A DEVICE CANNOT BE MADE TO PRODUCE.** 391 made the
    /// sentence pure for exactly this: as an instance property on a singleton
    /// with a `private init`, two of its four arms had nothing that could
    /// exercise them. `PersistenceMode.derive`'s argument.
    @Test("The two states only a broken phone could produce")
    func theUnreachableStates() {
        let noDatabase = DatabaseWriteThrough.diagnosticLines(
            .noDatabase, runs: 3, isRunning: false)
        #expect(noDatabase[0].contains("The database is not open"))
        #expect(noDatabase.contains("  healthy: no"))
        #expect(noDatabase.contains("  runs this launch: 3"),
                "runs counts completed writes, not healthy ones")

        let failed = DatabaseWriteThrough.diagnosticLines(
            .failed("disk full", atUTC: "2026-08-17T09:00:00Z"),
            runs: 1, isRunning: true)
        #expect(failed[0].contains("the write failed"))
        #expect(failed.contains("  running right now: yes"))
        #expect(failed.contains(where: { $0.contains("healthy: no — disk full") }),
                "the reason travels with the verdict")
    }

    /// Every state produces a distinct sentence — the shape `SkipStandingTests`
    /// and `MoveStandingTests` assert for their own vocabularies. Two states
    /// that paste identically are two states nobody can tell apart later.
    @Test("No two write-through states read the same")
    func everyStateReadsDifferently() {
        let all: [DatabaseWriteThrough.Outcome] = [
            .never,
            .noDatabase,
            .failed("disk full", atUTC: "2026-08-17T09:00:00Z")
        ]
        let sentences = all.map { DatabaseWriteThrough.line($0) }
        #expect(Set(sentences).count == all.count)
    }
}
