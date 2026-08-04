//
//  DatabaseBenchmarkRunner.swift
//  Sub4
//
//  The benchmark, driven from a screen instead of a test runner — patch 209,
//  plan step 3.2.7.
//
//  WHY THIS EXISTS AT ALL, GIVEN THE TESTS ALREADY RUN IT
//  -----------------------------------------------------
//  The simulator's numbers are worthless for the question ADR-0003 §9 asks. It
//  has the Mac's SSD, the Mac's memory, no thermal ceiling and no jetsam. The
//  decision between one row per sample and one blob per recording turns on how
//  a phone behaves at three million rows, and the only way to know that is to
//  ask the phone.
//
//  This project's own record says the same thing more bluntly: six of the
//  eleven defects found in Phase 2 were reachable only on hardware.
//
//  WHY A CLASS AND NOT A `.task` IN THE VIEW
//  -----------------------------------------
//  `DatabaseBenchmark.run` is synchronous and, at ten thousand, slow. Run from
//  a view's `.task` it would inherit MainActor isolation and freeze the screen
//  for the whole run — including the progress lines it emits, which would all
//  arrive at once at the end and be useless. The work goes to a detached task
//  at utility priority; this class is the thing the detached task reports back
//  to.
//
//  CANCELLATION IS REAL, NOT COSMETIC
//  ----------------------------------
//  `Task.detached` does not inherit cancellation from anywhere, so the handle
//  is held here and cancelled directly. `DatabaseBenchmark` checks at each
//  batch boundary. A "Stop" button that only hid the spinner while three
//  million inserts carried on would be a lie told to somebody watching their
//  battery drain.
//

import Foundation
import Observation

@MainActor
@Observable
final class DatabaseBenchmarkRunner {

    enum Phase: Sendable, Equatable {
        case idle
        case running(String)
        case finished
        case cancelled
        case failed(String)
    }

    /// The sizes offered, smallest first.
    ///
    /// 10,000 IS THE ONE THE PLAN ASKS FOR — §9 question 3 says "benchmark at
    /// 10,000 in 3.2". The two below it are not hedging: they establish that
    /// the run works and give a per-activity cost to multiply, so nobody starts
    /// a several-minute run on a phone to discover the screen was broken.
    static let sizes = [500, 2_000, 10_000]

    private(set) var phase: Phase = .idle
    private(set) var result: DatabaseBenchmark.Result?
    /// The size the current `result` came from, so a stale result cannot be
    /// read as belonging to the size now selected.
    private(set) var resultSize: Int?

    private var work: Task<Outcome, Never>?
    private var watcher: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var progressLine: String? {
        if case .running(let line) = phase { return line }
        return nil
    }

    func start(activities: Int, samplesPerActivity: Int = 300) {
        guard !isRunning else { return }
        phase = .running("Starting…")
        result = nil
        resultSize = nil
        stopRequested = false

        // PROGRESS CROSSES BACK ON A STREAM, NOT ON A CAPTURED `self`.
        //
        // The first version of this captured `[weak self]` inside the
        // `@Sendable` progress closure and hopped to the MainActor once per
        // line. Two things wrong with it:
        //
        //   1. A weak capture is a `var` — it can become nil — and referencing
        //      a captured `var` from concurrently-executing code is a warning
        //      today and an error in the Swift 6 language mode.
        //   2. It was unordered. One independent Task per line means the
        //      MainActor can run them in any order, so a fast run could show
        //      "Building activities 500/5000" AFTER "Importing normalised".
        //
        // A stream fixes both: the detached task captures only the
        // continuation, which is Sendable by design, and delivery is ordered.
        // `.bufferingNewest(1)` is the right policy for a progress line —
        // whoever is reading it wants the latest, never a backlog.
        let (lines, sink) = AsyncStream.makeStream(of: String.self,
                                                   bufferingPolicy: .bufferingNewest(1))
        let report: @Sendable (String) -> Void = { _ = sink.yield($0) }

        let work = Task.detached(priority: .utility) { () -> Outcome in
            // Finishes on every path, including the throw from a cancellation,
            // or the watcher below would wait on a stream nobody will close.
            defer { sink.finish() }
            do {
                let r = try DatabaseBenchmark.run(activities: activities,
                                                  samplesPerActivity: samplesPerActivity,
                                                  progress: report)
                return .success(r, activities)
            } catch is CancellationError {
                return .cancelled
            } catch {
                // `String(describing:)` rather than `localizedDescription`: a
                // GRDB error's localized form drops the SQL and the SQLite
                // result code, which are the two things worth having.
                return .failed(String(describing: error))
            }
        }
        self.work = work

        watcher = Task { [weak self] in
            for await line in lines {
                guard let self else { break }
                self.note(line)
            }
            let outcome = await work.value
            guard let self else { return }
            switch outcome {
            case .success(let r, let size):
                self.result = r
                self.resultSize = size
                self.phase = .finished
            case .cancelled:
                self.phase = .cancelled
            case .failed(let message):
                self.phase = .failed(message)
            }
            self.work = nil
        }
    }

    func cancel() {
        work?.cancel()
        // The phase is NOT set to `.cancelled` here. It moves there when the
        // detached task actually stops, which can be a batch away — saying
        // "cancelled" while SQLite is still writing would be the same lie the
        // header objects to.
        guard isRunning else { return }
        phase = .running("Stopping at the next batch…")
        // And the flag, or the batch already in flight reports its own line a
        // moment later and the screen goes back to claiming it is importing.
        stopRequested = true
    }

    private var stopRequested = false

    private func note(_ line: String) {
        guard isRunning, !stopRequested else { return }
        phase = .running(line)
    }

    private enum Outcome: Sendable {
        case success(DatabaseBenchmark.Result, Int)
        case cancelled
        case failed(String)
    }
}
