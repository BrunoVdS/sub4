//
//  VerificationResult.swift
//  Sub4
//
//  Where the verifier's answer lives — patch 340, ADR-0003 §12.88.
//
//  §12.57 FOR THE FOURTH TIME, ON THE ONE CONTROL D7 TURNS ON
//  ----------------------------------------------------------
//  313 moved shadow parity's result off `@State` because the diagnostics paste
//  said *"Not compared since this launch"* a minute after the comparison
//  passed. 333 did the same for the nine read-backs. Both times the sentence
//  was true of the `@State` and false about the world.
//
//  `SemanticVerifier`'s report was never moved, and it is the one that matters
//  most: D7's entry gate is *"a verified run exists over the current data"*,
//  and until this patch that fact was readable only between pressing Verify and
//  pressing Done. The paste printed the verification block ONLY while the sheet
//  that produced it was open — so the single piece of evidence the whole ladder
//  turns on could not be captured, sent, or read later by somebody who was not
//  holding the phone.
//
//  TWO FACTS, NOT ONE, AND THEY FAIL SEPARATELY
//  --------------------------------------------
//  A comparison that passed and a ledger row that moved are different claims.
//  Until 338 the second sat behind a `try?`, so a passing report over a failed
//  ledger write looked identical to a clean pass. 338 put the sentence on the
//  screen; this puts it in the paste and gives it a type, so each outcome can
//  be asserted rather than compared as prose.
//
//  `Ledger` DELIBERATELY KEEPS THE SENTENCES 338 WROTE, word for word. They are
//  what is on the screen today and they say the right thing; moving them into
//  an enum is about making them reachable from a test and from the paste, not
//  about rewording them.
//
//  WHAT THIS IS NOT
//  ----------------
//  It is not persisted, for `ShadowParity`'s reason: the question it answers is
//  *does the database agree with the stores right now*, and an answer from
//  three launches ago would be a second answer to a question the current data
//  already settles — §12.29.
//
//  The DURABLE half of the same fact lives in the ledger itself.
//  `LedgerCensus.everVerified` counts the rows, survives every launch, and is
//  printed in the paste unconditionally. This type says what the last press
//  found; the census says whether any press ever succeeded. Neither can replace
//  the other, and before 340 the app had neither.
//

import Foundation
import Observation

@MainActor
@Observable
final class VerificationResult {

    static let shared = VerificationResult()

    private init() {}

    /// Whether the ledger row moved, and why not when it did not.
    ///
    /// FIVE CASES BECAUSE THERE ARE FIVE ANSWERS. `verifyPending` refuses on
    /// three separate conditions — the row must be `pending`, it must have a
    /// finish time, and it must be the newest row in the table — and all three
    /// collapse into `notTheNewestRun` here because the screen cannot tell them
    /// apart from the one boolean it gets back. That is honest: the remedy is
    /// the same in every case, and it is the sentence.
    enum Ledger: Equatable, Sendable {
        /// The run moved to `verified`.
        case marked
        /// The comparison disagreed, so nothing was changed.
        case reportDidNotPass
        /// The comparison agreed and the row would not take it — something
        /// opened a newer run between the import and the press.
        case notTheNewestRun
        /// The update threw.
        case failed(String)
        /// There was no run to mark.
        case noRun

        /// The five sentences, unchanged from patch 338's screen.
        var line: String {
            switch self {
            case .marked:
                "the run is marked verified"
            case .reportDidNotPass:
                "the report did not pass, so no run was changed"
            case .notTheNewestRun:
                "not recorded — import again, then verify the newest completed "
                + "pending run"
            case .failed(let why):
                "the run could not be marked verified: \(why)"
            case .noRun:
                "no run to mark — the ledger is empty"
            }
        }

        /// ONLY `marked` IS AGREEMENT. `reportDidNotPass` is not a ledger
        /// fault — the ledger did exactly the right thing — but it is not a
        /// pass either, and a row that drew it dim would be telling somebody
        /// the gate was met.
        var agreed: Bool { self == .marked }
    }

    /// `.never` is not agreement and not a failure — the same shape as
    /// `ShadowParity.Outcome` and `ReadBackRollUp.Outcome`, and for the same
    /// reason: not having looked is a third state.
    enum Outcome: Equatable {
        case never
        case ran(VerificationReport, ledger: Ledger)

        var report: VerificationReport? {
            if case .ran(let r, _) = self { return r }
            return nil
        }

        var ledger: Ledger? {
            if case .ran(_, let l) = self { return l }
            return nil
        }

        /// What the Ledger row draws. `.never` never reaches it — the row is
        /// inside `if let report` — but a value that cannot be nil is easier
        /// to test than an optional the caller unwraps.
        var ledgerLine: String { ledger?.line ?? "nothing has been verified yet" }

        var ledgerAgreed: Bool { ledger?.agreed ?? false }

        var line: String {
            switch self {
            case .never:
                "Not run since this launch."
            case .ran(let r, let l):
                (r.passed ? "\(r.checks.count) comparisons agreed"
                          : "\(r.failures.count) of \(r.checks.count) disagreed")
                + " · " + l.line
            }
        }

        /// A press that agreed AND moved the ledger. `.never` is healthy for
        /// `ShadowParity`'s reason: not having pressed the button is not a
        /// fault.
        var isHealthy: Bool {
            switch self {
            case .never:               true
            case .ran(let r, let l):   r.passed && l.agreed
            }
        }

        /// UNCONDITIONAL IN THE PASTE — §12.54.2. Before 340 this block was
        /// absent until somebody pressed the button, which is indistinguishable
        /// from a button nobody wired in.
        ///
        /// COUNTS AND TABLE NAMES ONLY. `VerificationReport.diagnosticLines`
        /// already excludes every check's `detail`, which can carry an activity
        /// id — §12.7 — and the ledger sentences carry none.
        var diagnosticLines: [String] {
            switch self {
            case .never:
                ["Verification: not run since this launch."]
            case .ran(let r, let l):
                r.diagnosticLines + ["  ledger: \(l.line)"]
            }
        }
    }

    private(set) var last: Outcome = .never

    /// Presses since this launch. Like `ShadowParity.runs` and
    /// `DatabaseWriteThrough.runs`, it answers "did the button do anything at
    /// all", which is a question about now.
    private(set) var runs = 0

    func record(_ report: VerificationReport, ledger: Ledger) {
        last = .ran(report, ledger: ledger)
        runs += 1
    }
}
