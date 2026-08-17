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

// MARK: - Where a read-back's APP SIDE came from — patch 389, §12.133

/// **THE UNIT IS NOT THE FIELD HERE, AND THAT IS THE FINDING.**
///
/// The verifier can classify by field alone because `AppStores.current()` always
/// reads the live store, so *which field* determines *which store* determines
/// *is it fed*. A read-back has a second degree of freedom: it may take its app
/// side from the live store, or it may go and read the files itself.
///
/// `Notes and commutes` is why this matters. It reads `.notes`, `.commutes`,
/// `.matchDecisions` and `.moves` — **every one of which the database feeds** —
/// and it is nonetheless real evidence, because 356 gave it `authoredSources()`:
/// its own `NotesStore(directory:)`, `CommuteStore(directory:)`,
/// `Matcher(defaults:)` and `PlanMoveStore(directory:)`. A field-only derivation
/// would mark that row self-referential and be wrong about the one row this
/// project already fixed.
///
/// So a row says which of the two it did, and only the second consults
/// `ExpectationSources`.
nonisolated enum ReadBackSource: Equatable, Sendable {

    /// A read this read-back made itself — a fresh decode of a file or of the
    /// bundle, independent of whatever the stores are serving. 343 (`plan`),
    /// 356 (`authored`) and 381 (`ActivitySource`) are the three that exist.
    ///
    /// The sentence is the one the read-back's own section prints, so the two
    /// cannot drift into saying different things about one read.
    case ownRead(String)

    /// Taken from live stores. Carries every store field the app side is built
    /// from, so `ExpectationSources` decides — the same origins
    /// `VerificationCheck.reads` carries, and the same resolution.
    case liveStores([ExpectationOrigin])

    /// True when any field this row's app side is built from is one the build
    /// feeds from the database — so the row is the database agreeing with
    /// itself, however many thousand fields it compared.
    func isSelfReferential(given sources: ExpectationSources) -> Bool {
        switch self {
        case .ownRead: false
        case .liveStores(let origins):
            origins.contains { sources.isFedByTheDatabase($0.field) }
        }
    }

    /// **THREE STATES, NOT TWO, AND THE THIRD IS THE TRIPWIRE** — §12.15.
    ///
    /// A row can be independent because it went and read the files, or
    /// independent because nothing has hydrated its store *yet*. Those look
    /// identical in a count and they are opposite facts: the first survives its
    /// slice, the second becomes self-referential on the day that slice flips
    /// and says nothing when it does. `Review trail` is the second kind and B7
    /// is the day.
    ///
    /// So the paste names which, for every row, whatever the answer is.
    func mark(given sources: ExpectationSources) -> String {
        switch self {
        case .ownRead(let how):
            return " · own read: \(how)"
        case .liveStores(let origins):
            let fed = origins.filter { sources.isFedByTheDatabase($0.field) }
            guard !fed.isEmpty else {
                let names = origins.map(\.storeDescription).joined(separator: ", ")
                return " · from the stores: \(names) — not fed yet"
            }
            let named = fed.map { o in
                o.storeDescription
                    + (o.field.slice.map { ", hydrated at \($0)" } ?? "")
            }.joined(separator: " · ")
            return " · self-referential: \(named)"
        }
    }

    /// The short form, for the screen. The row's value is already long and this
    /// sits beside it; the paste carries which store and which slice.
    func screenMark(given sources: ExpectationSources) -> String {
        isSelfReferential(given: sources) ? " · self-referential" : ""
    }
}

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

        /// **WHERE THIS ROW'S APP SIDE CAME FROM — PATCH 389, AND IT HAS NO
        /// DEFAULT ON PURPOSE.** `VerificationCheck.reads`' rule, one screen
        /// over: a row added without answering does not compile.
        ///
        /// §12.129 is what the alternative costs. A list of "which read-backs
        /// are self-referential" kept beside this type would have no way to
        /// notice a row that was never added to it — which is exactly how
        /// `Activities` and `Athlete` sat in the agreeing column for six and
        /// forty-two patches with nothing saying so.
        let reads: ReadBackSource

        var id: String { name }

        func isSelfReferential(given sources: ExpectationSources) -> Bool {
            reads.isSelfReferential(given: sources)
        }

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
        /// **CARRIES WHAT THE BUILD WAS SERVING WHEN IT RAN — patch 389.**
        ///
        /// Resolved at record time rather than read live, and that is the same
        /// decision `Sub4Launch.bootstrap` made and 358 had to explain: this
        /// result outlives the sheet that produced it, so it must describe the
        /// run that happened. A roll-up recorded before a slice flipped and
        /// re-read afterwards would otherwise change its own history.
        case ran([Line], ExpectationSources)
        case noDatabase
        case readFailed(String)

        var lines: [Line] {
            if case .ran(let l, _) = self { return l }
            return []
        }

        /// What was being served when this roll-up ran. `.allFromFiles` for
        /// every other case, which is the honest answer for a run that did not
        /// happen — nothing was compared, so nothing was self-referential.
        var sources: ExpectationSources {
            if case .ran(_, let s) = self { return s }
            return .allFromFiles
        }

        func count(_ v: Verdict) -> Int { lines.filter { $0.verdict == v }.count }

        var healthyCount: Int { count(.agreed) }
        var differingCount: Int { count(.differed) }
        var blindCount: Int { count(.couldNotLook) }
        var emptyCount: Int { count(.nothingToCompare) }

        /// **THE FIFTH COUNT — patch 389, §12.133.** How many rows compared the
        /// database against something the database feeds.
        ///
        /// It is NOT a fifth `Verdict`. A self-referential row still agreed, or
        /// differed, or could not look; this cuts across the four rather than
        /// joining them, exactly as the verifier's split cuts across `passed`.
        /// Deriving it from each row's own `reads` is §12.129's lesson: the
        /// list that would have said the same thing had no way to notice a row
        /// nobody added to it.
        var selfReferentialCount: Int {
            lines.filter { $0.isSelfReferential(given: sources) }.count
        }

        /// The rows that could still have disagreed about the app. The
        /// complement, and the number that matters when the other one grows.
        var independentCount: Int { lines.count - selfReferentialCount }

        /// ALL FIVE TERMS, ALWAYS — §12.54.2. A term that disappears at zero
        /// cannot be told from a term nobody wired in, and the reason this
        /// sentence exists at all is that "8 of 9 agree" hid two different
        /// facts on the first device run. The fifth is 389's and it hid two
        /// more: `Activities` since 382 and `Athlete` since 346.
        var line: String {
            switch self {
            case .never:
                "Not rolled up since this launch."
            case .ran(let l, _) where l.isEmpty:
                "Nothing ran."
            case .ran(let l, _):
                "\(healthyCount) of \(l.count) agree · \(differingCount) differ · "
                + "\(blindCount) could not look · \(emptyCount) nothing to compare"
                + " · \(selfReferentialCount) read a store the database feeds"
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
            case .ran(let l, _):             !l.isEmpty && l.allSatisfy { !$0.isFault }
            case .noDatabase, .readFailed:   false
            }
        }

        /// The stronger claim, and the one D7's gate needs: every read-back
        /// looked at something and every one agreed.
        ///
        /// **IT DELIBERATELY DOES NOT ASK `selfReferentialCount`, AND 389 IS
        /// WHERE THAT IS A DECISION RATHER THAN AN OVERSIGHT.** The verifier
        /// withholds `verified` when nothing could have disagreed, because that
        /// gate feeds `activateVerified`. This one is read by a person, and the
        /// count beside it is how they judge what the agreement is worth —
        /// §12.99's own split between *healthy* and *proved*, which 333a bought
        /// and 385 refused to weaken. Tightening it into this property is a
        /// decision for the slice that makes the number alarming, not for the
        /// patch that first prints it.
        var provesSomething: Bool {
            if case .ran(let l, _) = self { return !l.isEmpty && l.allSatisfy(\.isHealthy) }
            return false
        }

        /// UNCONDITIONAL, and one line per read-back whatever it said —
        /// including, since 389, where each row's app side came from.
        var diagnosticLines: [String] {
            var out = ["Read-back roll-up: \(line)"]
            let s = sources
            for l in lines {
                out.append("  \(l.name): \(l.value)\(l.reads.mark(given: s))")
            }
            return out
        }
    }

    private(set) var last: Outcome = .never
    /// Completed roll-ups since this launch. Like `ShadowParity.runs`, it
    /// answers "did the press do anything at all", which is about now.
    private(set) var runs = 0

    // MARK: - The adapter — patch 341

    /// ONE PLACE THAT TURNS A REPORT INTO A VERDICT.
    ///
    /// MOVED HERE FROM `DatabaseHealthView` AT 341, UNCHANGED. It was a
    /// `private static func` on a SwiftUI view, which meant no test could
    /// reach it — and it is the function that shipped a defect at 333 and was
    /// corrected on the device at 333a. `ReadBackRollUpTests`' own header says
    /// so: *"these tests did not catch it, because they tested the type and
    /// the defect was in the caller"*. It documented the untested seam and
    /// could not close it. This is the move that closes it; the body is
    /// identical and `RollUpAdapterTests` is the negative control Stage A2
    /// item 7 asks for.
    ///
    /// `trustworthy` COMES FROM THE LOAD, NOT FROM THE REPORT. 333 passed
    /// `lookedAtSomething` here, which answers *did this compare anything*,
    /// and used it to decide *did the read happen*. Those are different
    /// questions and the device answered them differently within the hour:
    /// `Notes and commutes` reported "could not look" over a database that had
    /// been read perfectly well and simply held nothing.
    ///
    /// Every load type carries `isTrustworthy` — all eight of them, plus
    /// `RecordingRoundTrip.Report` — so the honest input was there the whole
    /// time. §12.81, §12.89.
    /// **`reads:` HAS NO DEFAULT — patch 389.** It is the one argument here
    /// that cannot be computed from the report, because it is a fact about
    /// which code the caller chose to read from. See `ReadBackSource`.
    ///
    /// IT IS CARRIED ON BOTH PATHS, including the one that could not look. A
    /// read that failed still came from somewhere, and a row that dropped its
    /// provenance on failure would be a row whose classification depended on
    /// whether the read worked — which is §12.15 inside the mechanism written
    /// to answer §12.15.
    static func line(_ name: String,
                     _ compared: Int?,
                     _ unexplained: Int?,
                     trustworthy: Bool,
                     reads: ReadBackSource,
                     _ whyNot: @autoclosure () -> String) -> Line {
        guard trustworthy, let compared, let unexplained else {
            return .init(name: name, compared: 0, unexplained: 0,
                         couldNotLook: whyNot(), reads: reads)
        }
        return .init(name: name, compared: compared, unexplained: unexplained,
                     couldNotLook: nil, reads: reads)
    }

    /// **`sources` IS PASSED, NOT READ HERE — patch 389.** `ExpectationSources
    /// .live` asks six main-actor singletons what they are serving, and
    /// §12.130.7 is what happens when a bookkeeping type reaches for those on
    /// its own: thirty-four test call sites instantiated stores they had never
    /// touched. The caller that ran the read-backs has already touched every
    /// one of them.
    func record(_ lines: [Line], sources: ExpectationSources) {
        last = .ran(lines, sources)
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
