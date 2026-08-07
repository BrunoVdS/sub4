//
//  ShadowParity.swift
//  Sub4
//
//  D6c — one run, every slice. Patch 313, groundwork §7, ADR-0003 §12.57.
//
//  WHY THIS EXISTS, AND IT IS A CORRECTION TO 312
//  ----------------------------------------------
//  312 put the running and the holding inside `ActivityParity`, because there
//  was one slice and one place to put them. Slice 2 made two things wrong with
//  that, and both are worth naming rather than quietly fixing.
//
//  **A second button would read the database twice.** Both slices need the same
//  672-row read and the same `ActivityRoster.settle`. Running them separately
//  would do that work twice for no reason — and worse, somebody who pressed one
//  and not the other would get an answer that looked complete and was half.
//  Groundwork §7 said the roll-up arrives when there is more than one slice.
//  There is.
//
//  **The result evaporated on Done.** `@State` on a sheet is discarded when the
//  sheet is dismissed, so the diagnostics paste — the thing that gets read later
//  by somebody who was not there — said *"Not compared since this launch"* a
//  minute after the comparison passed. The line was true of that `@State` and
//  false about the world, which is §12.15's shape wearing a fresh coat.
//
//  So the result lives on a singleton, like `DatabaseWriteThrough` since 302,
//  and survives dismissal within a launch. Not persisted: the question it
//  answers is "does the database agree with the app right now", and a stored
//  answer from three launches ago would be a second answer to a question the
//  current data already settles — §12.29's problem.
//
//  ONLY PARITY MOVES. The three read-backs and the survey keep their `@State`
//  and their current behaviour. Changing five things to fix one is how a slice
//  patch stops being checkable.
//
//  `ActivityParity` AND `VolumeParity` ARE NOW PURE COMPARISONS
//  -----------------------------------------------------------
//  Each takes two `[Activity]` and returns a `Report`. Neither reads a
//  database, a store or a clock. That is what lets a test build their two sides
//  from genuinely different places, and it is the property slice 3 will inherit
//  for free.
//

import Foundation

@MainActor
@Observable
final class ShadowParity {

    static let shared = ShadowParity()

    private init() {}

    /// What the last run produced.
    ///
    /// `.never` is not agreement and not a failure — the eighth instance of
    /// §12.15's shape in this project, and the reason this is an enum rather
    /// than an optional report.
    enum Outcome: Equatable {
        case never
        case ran(activities: ActivityParity.Report, volume: VolumeParity.Report)
        /// The launch gate never opened one. Not the same as a read failing.
        case noDatabase
        case readFailed(String)

        var line: String {
            switch self {
            case .never:
                "Not compared since this launch."
            case .ran(let a, let v):
                a.unexplained + v.unexplained == 0
                    ? "\(a.common) activities · \(v.daysCompared) days · no differences"
                    : "\(a.unexplained + v.unexplained) differences"
            case .noDatabase:
                "The database is not open, so nothing was derived."
            case .readFailed(let why):
                "The database could not be read — \(why)"
            }
        }

        /// `.never` is healthy. Not having looked is not a fault; looking and
        /// disagreeing is, and so is looking at nothing.
        var isHealthy: Bool {
            switch self {
            case .never:                true
            case .ran(let a, let v):    a.isHealthy && v.isHealthy
            case .noDatabase, .readFailed: false
            }
        }

        var activities: ActivityParity.Report? {
            if case .ran(let a, _) = self { return a }
            return nil
        }

        var volume: VolumeParity.Report? {
            if case .ran(_, let v) = self { return v }
            return nil
        }

        /// Both slices' lines, or the reason there are none. Unconditional —
        /// 266c's rule, and the paste is where this patch's own defect showed.
        var diagnosticLines: [String] {
            switch self {
            case .ran(let a, let v):
                a.diagnosticLines + [""] + v.diagnosticLines
            case .never, .noDatabase, .readFailed:
                ["Shadow parity: \(line)"]
            }
        }
    }

    private(set) var last: Outcome = .never
    private(set) var isRunning = false
    /// Runs since this launch, like `DatabaseWriteThrough.runs` and for the
    /// same reason: it answers "is this firing at all", which is about now.
    private(set) var runs = 0

    /// ONE READ, ONE SETTLE, EVERY SLICE.
    ///
    /// OFF THE MAIN ACTOR FOR THE READ, ON IT FOR THE RULES. `ActivityLoad` is
    /// `Sendable` precisely so that hand-off is legal, and `ActivityRoster` is
    /// `@MainActor` because `isKept` reads `MatchRules` and `DataCorrections`.
    ///
    /// The suspension is load-bearing for a second reason: 312 did the read
    /// synchronously inside a `Task`, so `isRunning` went true and false in the
    /// same main-actor hop and the spinner never drew. Nobody noticed, because
    /// the run is fast — which is exactly the kind of thing that stops being
    /// true when a slice is added.
    ///
    /// ONE `settle`, TWO COMPARISONS. Slice 1 is handed the raw rows because it
    /// reports what the rules dropped; slice 2 is handed the settled list
    /// because it compares what the app would show.
    func run(_ db: Sub4Database) async {
        isRunning = true
        defer { isRunning = false }

        let load = await Task.detached(priority: .userInitiated) {
            ActivityRepository.all(db)
        }.value

        switch load {
        case .unavailable:
            last = .noDatabase
        case .failed(let why):
            last = .readFailed(why)
        case .loaded(let rows, let skipped):
            let twin = ActivityRoster.settle(rows)
            let mine = ActivityStore.shared.activities
            last = .ran(activities: ActivityParity.compare(store: mine,
                                                           databaseRows: rows,
                                                           databaseSkipped: skipped),
                        volume: VolumeParity.compare(store: mine,
                                                     database: twin.activities))
            runs += 1
        }
    }
}
