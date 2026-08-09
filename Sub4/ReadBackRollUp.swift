//
//  ReadBackRollUp.swift
//  Sub4
//
//  Nine read-backs, one press, one answer that survives — patch 333.
//
//  WHY THIS EXISTS, IN ONE SENTENCE FROM CLAUDE.md
//  ----------------------------------------------
//  *"Nine buttons that must each be pressed is not a gate anybody can lean
//  on."* It has been on the pre-D7 list since D6c closed, and 9 August made it
//  urgent rather than tidy: a wipe destroyed every read-back result this
//  project had ever produced, and rebuilding the evidence means pressing nine
//  buttons and remembering nine numbers.
//
//  THE DEFECT IT CLOSES IS §12.57, NINE TIMES OVER
//  -----------------------------------------------
//  Every read-back's report lived in a `@State` property on
//  `DatabaseHealthView`. Pressing Done discarded all nine. The diagnostics
//  paste could print them only while the sheet that produced them was still
//  open, which is the exact defect 313 fixed for shadow parity — a result that
//  is true of the `@State` and false about the world.
//
//  So the RESULT lives here, on a shared observable that outlives the sheet,
//  and `runs` counts completed roll-ups the way `ShadowParity.runs` counts
//  comparisons. The spinner stays in the view, because a spinner that outlives
//  its screen is a lie of a different kind.
//
//  IT DOES NOT COMPARE ANYTHING
//  ----------------------------
//  `ReadBacks` runs the nine; this records what they said. The verdict for
//  each line is read from the report's OWN `isHealthy` and `unexplained`
//  wherever the report has them — six of the nine do — and the three that
//  predate that convention get the definition their own section already draws,
//  in an extension at the bottom of this file. Not a second opinion: the same
//  opinion, in one place. §12.43.
//
//  WHY A LINE CARRIES `couldNotLook` AS A SENTENCE AND NOT A BOOL
//  --------------------------------------------------------------
//  §12.15, thirteen instances and counting. "Nine of nine agree" said over a
//  read that failed is the single most expensive sentence this screen could
//  produce, because it is exactly what somebody would quote as the reason it
//  was safe to press D7. A line that could not look says so, in words, and is
//  counted apart from a line that looked and disagreed.
//

import Foundation
import Observation

@MainActor
@Observable
final class ReadBackRollUp {

    static let shared = ReadBackRollUp()

    /// WHAT A READ-BACK CAN HAVE DONE — patch 333a, and there are FOUR
    /// answers, not three.
    ///
    /// 333 shipped three and collapsed two of them in the adapter: it treated
    /// `lookedAtSomething == false` as "could not look", so a read that
    /// succeeded and found nothing on either side was reported as a blind
    /// read. On the device that made `Notes and commutes` red with the
    /// sentence "0 notes, 0 commute decisions." — which is the load's own
    /// description of a database that is fine.
    ///
    /// The two are not the same fact and the distinction is the whole point of
    /// §12.15. A read that failed is a question nobody answered. A read that
    /// found both sides empty is an answer that proves nothing — and those
    /// need different words, different colours, and different columns in the
    /// summary.
    enum Verdict: String, Sendable, Equatable {
        /// Compared something and found no differences.
        case agreed
        /// Compared something and found differences.
        case differed
        /// The read did not happen. Not zero differences — no answer.
        case couldNotLook
        /// The read happened and there was nothing on either side. Zero
        /// compared to zero agrees perfectly and proves nothing.
        case nothingToCompare
    }

    /// One read-back's verdict.
    ///
    /// `compared` is the denominator. §12.54.3: a count beside its own
    /// denominator is evidence, a bare zero is noise.
    struct Line: Sendable, Equatable, Identifiable {
        let name: String
        let compared: Int
        let unexplained: Int
        /// The LOAD's own failure sentence, or nil when the read succeeded.
        ///
        /// Taken from `isTrustworthy`, which every one of the eight load types
        /// and `RecordingRoundTrip.Report` carries. Deriving it from the
        /// report's `lookedAtSomething` instead is what 333 got wrong: that
        /// property answers *did this compare anything*, which is a different
        /// question from *did the read happen*.
        let couldNotLook: String?

        var id: String { name }

        var verdict: Verdict {
            if couldNotLook != nil     { return .couldNotLook }
            if unexplained > 0         { return .differed }
            return compared == 0 ? .nothingToCompare : .agreed
        }

        /// AGREEMENT ONLY. An empty comparison is not a pass — it is reported,
        /// counted on its own, and left for a person to accept.
        var isHealthy: Bool { verdict == .agreed }

        /// The two that mean something is wrong, as opposed to something is
        /// unproven.
        var isFault: Bool { verdict == .differed || verdict == .couldNotLook }

        var value: String {
            switch verdict {
            case .couldNotLook:     couldNotLook ?? "the read did not happen"
            case .differed:         "\(compared) compared, \(unexplained) differ"
            case .nothingToCompare: "nothing on either side"
            case .agreed:           "\(compared) compared, no differences"
            }
        }
    }

    /// `.never` is not agreement and not a failure — the same enum shape as
    /// `ShadowParity.Outcome`, and for the same reason.
    enum Outcome: Equatable {
        case never
        case ran([Line])
        case noDatabase
        case readFailed(String)

        var lines: [Line] {
            if case .ran(let l) = self { return l }
            return []
        }

        func count(_ v: Verdict) -> Int { lines.filter { $0.verdict == v }.count }

        var healthyCount: Int { count(.agreed) }
        var differingCount: Int { count(.differed) }
        var blindCount: Int { count(.couldNotLook) }
        var emptyCount: Int { count(.nothingToCompare) }

        /// ALL FOUR TERMS, ALWAYS — §12.54.2. A term that disappears at zero
        /// cannot be told from a term nobody wired in, and the reason this
        /// sentence exists at all is that "8 of 9 agree" hid two different
        /// facts on the first device run.
        var line: String {
            switch self {
            case .never:
                "Not rolled up since this launch."
            case .ran(let l) where l.isEmpty:
                "Nothing ran."
            case .ran(let l):
                "\(healthyCount) of \(l.count) agree · \(differingCount) differ · "
                + "\(blindCount) could not look · \(emptyCount) nothing to compare"
            case .noDatabase:
                "The database is not open, so nothing was read back."
            case .readFailed(let why):
                "The roll-up could not run — \(why)"
            }
        }

        /// A DIFFERENCE OR A BLIND READ FAILS IT. An empty comparison does
        /// not — it is not evidence of a fault, only an absence of evidence,
        /// and the count beside it is how a person decides whether that
        /// absence is acceptable today. Before D7 it will not be.
        var isHealthy: Bool {
            switch self {
            case .never:                     true
            case .ran(let l):                !l.isEmpty && l.allSatisfy { !$0.isFault }
            case .noDatabase, .readFailed:   false
            }
        }

        /// The stronger claim, and the one D7's gate needs: every read-back
        /// looked at something and every one agreed.
        var provesSomething: Bool {
            if case .ran(let l) = self { return !l.isEmpty && l.allSatisfy(\.isHealthy) }
            return false
        }

        /// UNCONDITIONAL, and one line per read-back whatever it said.
        var diagnosticLines: [String] {
            var out = ["Read-back roll-up: \(line)"]
            for l in lines { out.append("  \(l.name): \(l.value)") }
            return out
        }
    }

    private(set) var last: Outcome = .never
    /// Completed roll-ups since this launch. Like `ShadowParity.runs`, it
    /// answers "did the press do anything at all", which is about now.
    private(set) var runs = 0

    func record(_ lines: [Line]) {
        last = .ran(lines)
        runs += 1
    }

    func recordNoDatabase() { last = .noDatabase }
    func recordFailure(_ why: String) { last = .readFailed(why) }
}

// MARK: - The three reports that predate `isHealthy`

//  ADDED HERE RATHER THAN ON THE TYPES, and that is a compromise worth naming.
//
//  `AthleteRoundTrip.Report` and the five after it each carry `totalCompared`,
//  `unexplained`, `lookedAtSomething` and `isHealthy`, because the convention
//  existed by the time they were written. `ActivityRoundTrip` (289),
//  `DetailRoundTrip` (291) and `RecordingRoundTrip` (294) predate it and carry
//  `compared`, `missing`, `differences` and — for the last two — `excluded`.
//
//  The definitions below are not new judgements. Each one states what its own
//  section on the Database screen has drawn red since the day it shipped:
//  differences and unexplained absences count, deliberate exclusions do not,
//  and a read that failed is not a comparison that passed.
//
//  They belong on the types, in their own files, and go there the next time
//  those files are opened for a reason of their own. Putting three edits into
//  three repository files to add four computed properties each would have made
//  this patch touch seven files instead of four, on a screen that has cost
//  three fix-ups in two days.

extension ActivityRoundTrip.Report {
    var totalCompared: Int { compared }
    /// `missing` is in the store and not in the database, and nobody meant it.
    var unexplained: Int { differences.count + missing.count }
    var lookedAtSomething: Bool { compared > 0 }
    var isHealthy: Bool { lookedAtSomething && unexplained == 0 }
}

extension DetailRoundTrip.Report {
    var totalCompared: Int { compared }
    /// `excluded` is DELIBERATE — patch 298. `DataCorrections` refuses two
    /// sessions and the importer declines their details at the door. A
    /// permanently correct red row is a row that stops being read, so it is
    /// not counted here either.
    var unexplained: Int { differences.count + missing.count }
    var lookedAtSomething: Bool { compared > 0 }
    var isHealthy: Bool { lookedAtSomething && unexplained == 0 }
}

extension RecordingRoundTrip.Report {
    var totalCompared: Int { compared }
    /// A recording the reader could not read is not agreement. Neither is a
    /// failed id read, which is why `isTrustworthy` gates the whole thing
    /// rather than contributing to a count.
    var unexplained: Int {
        readFailure == nil ? differences.count + missing.count + unreadable.count : 0
    }
    var lookedAtSomething: Bool { isTrustworthy && compared > 0 }
    var isHealthy: Bool { lookedAtSomething && unexplained == 0 }
}
