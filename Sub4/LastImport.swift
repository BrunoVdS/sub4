//
//  LastImport.swift
//  Sub4
//
//  What the newest import did, after the sheet that ran it is gone — patch 341,
//  ADR-0003 §12.89.
//
//  §12.57, AND THIS IS THE LAST BLOCK STILL TRAPPED BEHIND THE SCREEN
//  ------------------------------------------------------------------
//  313 moved shadow parity's result off `@State`. 333 did it for the nine
//  read-backs. 340 did it for the verifier. The import report was the last one:
//  `DatabaseHealthView.importReport` was a `@State` property drawn in the
//  Import section and referenced NOWHERE in `diagnosticsText`, so the only way
//  to send somebody "Notes: 1 new, Gear: 0 new, 11 known, 1 refreshed" was a
//  screenshot. It was screenshotted twice on 10 August, which is how it was
//  found.
//
//  WHY NOT `DatabaseWriteThrough.last`, WHICH ALREADY HOLDS A REPORT
//  -----------------------------------------------------------------
//  Because they answer different questions and only one of them is about the
//  data. `DatabaseWriteThrough.last` answers *is the automatic trigger firing,
//  and did it fail* — it is fed only by backgrounding, returning and the
//  background refresh, and the Database screen's Import button never touches
//  it. This answers *what did the newest import of ANY kind write*, which is
//  the question a paste is read for.
//
//  Both hold a `Sub4Import.Report`, and that is a duplication with a reason:
//  collapsing them would make the write-through's health line change when a
//  person pressed a button, which is exactly the confusion §12.39.2 warns
//  about. The two are written from the two call sites of `Sub4Import.run`.
//
//  NOT PERSISTED, like every other result on that screen. The question is
//  "what happened just now"; an answer from three launches ago would be a
//  second answer to a question the current data already settles — §12.29.
//

import Foundation
import Observation

@MainActor
@Observable
final class LastImport {

    static let shared = LastImport()

    private init() {}

    /// `.never` is not success and not failure — the same shape as
    /// `ShadowParity.Outcome`, `ReadBackRollUp.Outcome` and
    /// `VerificationResult.Outcome`, and for the same reason.
    enum Outcome: Equatable {
        case never
        case ran(Sub4Import.Report, trigger: MigrationRunTrigger, atUTC: String)
        case failed(String, atUTC: String)

        var report: Sub4Import.Report? {
            if case .ran(let r, _, _) = self { return r }
            return nil
        }

        var line: String {
            switch self {
            case .never:
                "No import has run since this launch."
            case .ran(let r, let t, let at):
                "\(AppTime.local(at) ?? at) · \(t.rawValue) · \(r.summary)"
            case .failed(_, let at):
                "\(AppTime.local(at) ?? at) — the import failed."
            }
        }

        /// The failure text in full, for the screen. Kept out of `line` for the
        /// reason `DatabaseWriteThrough` keeps its own apart: one belongs in a
        /// row and the other in a paragraph.
        var failureDetail: String? {
            if case .failed(let why, _) = self { return why }
            return nil
        }

        var isHealthy: Bool {
            switch self {
            case .never, .ran: true
            case .failed:      false
            }
        }

        /// UNCONDITIONAL IN THE PASTE — §12.54.2. `.never` says so rather than
        /// the block being absent, which is indistinguishable from a block
        /// nobody wired in.
        ///
        /// COUNTS ONLY. `Report.refusals` carries an `externalID` — a Strava
        /// activity id — and §12.7 promises this paste carries none, so the
        /// refusals reach it as a number and their detail stays on screen.
        var diagnosticLines: [String] {
            switch self {
            case .never:
                ["Last import report: no import has run since this launch."]
            case .failed(_, let at):
                ["Last import report: failed at \(at) — see the on-device screen."]
            case .ran(let r, let t, let at):
                ["Last import report: \(at) · \(t.rawValue)"] + r.redactedLines
            }
        }
    }

    private(set) var last: Outcome = .never

    /// Imports since this launch, however they were fired. Like
    /// `ShadowParity.runs`, it answers "is this happening at all".
    private(set) var runs = 0

    func record(_ report: Sub4Import.Report,
                trigger: MigrationRunTrigger,
                atUTC: String) {
        last = .ran(report, trigger: trigger, atUTC: atUTC)
        runs += 1
    }

    func recordFailure(_ why: String, atUTC: String) {
        last = .failed(why, atUTC: atUTC)
        runs += 1
    }
}
