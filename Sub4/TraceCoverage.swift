//
//  TraceCoverage.swift
//  Sub4
//
//  Why 23 activities have no trace — patch 277, ADR-0003 §12.23.8.
//
//  THE COUNTER WITH NO DECISION BESIDE IT
//  --------------------------------------
//  `activity: 668` and `recording: 645` sit four lines apart on the Database
//  screen, and nothing anywhere accounts for the difference. §12.23.7 found
//  what it is — two recordings answered empty, twenty-one never asked because
//  `needsStreams` requires 500 m and a strength session is 0 m — but finding
//  it required reading `DetailStore`, which is not a thing a number on a
//  screen should require.
//
//  The standard this project set on 4 August: "every counter on the health
//  screen reads zero or has a decision beside it, so the next entry in any of
//  them is news." This is the decision, beside the counter.
//
//  IT IS AN ACCOUNT, AND `unexplained` IS THE POINT
//  ------------------------------------------------
//  Every activity lands in exactly one bucket, and the buckets sum to the
//  total. `unexplained` is what is left when none of the known reasons
//  applies — so it is zero today, and the day it is not is the day something
//  is wrong that nobody has a name for yet.
//
//  A total that balances is worth more than five numbers that do not. Five
//  numbers can each be right while the set of them is missing a case; a
//  residual cannot hide one.
//
//  PURE, AND THAT IS WHY IT CAN BE TESTED
//  --------------------------------------
//  `DetailStore` is a singleton over the real disk, so a function that read it
//  directly could only be tested by arranging the athlete's actual files.
//  Everything here takes its inputs, and the store supplies them in one line.
//

import Foundation

/// Why each activity does or does not have a recorded trace.
nonisolated struct TraceCoverage: Equatable, Sendable {

    var total = 0

    /// The trace is here.
    var withTrace = 0

    /// The source refused the recording — a 404. `DetailStore.failed`.
    var refused = 0

    /// The source was asked and had nothing. `DetailStore.noStreams`.
    var answeredEmpty = 0

    /// Under `minStreamDistance`, so nothing ever asked. The 21.
    var belowThreshold = 0

    /// In the queue and not yet reached.
    var queued = 0

    /// **THE IDS BEHIND TWO OF THE BUCKETS — patch 420, §12.165.**
    ///
    /// Topic 3 asks a tester to *"select an ID classified as answered-empty,
    /// then open Activities → activity detail"*. The screen said `asked,
    /// nothing there: 2` and named neither, so the step could not be
    /// performed — the same unperformable instruction 417's campaign shipped
    /// with and §12.162.5 recorded.
    ///
    /// **STRAVA IDS ARE EXPLICITLY PASTEABLE** — §12.7 excludes session names,
    /// places and dates, and names ids and field names as acceptable. So this
    /// is the one thing that can identify an activity in a diagnostic without
    /// carrying anything about the athlete's history.
    ///
    /// **UNCAPPED, AND THAT IS DELIBERATE.** A silent `prefix(10)` reads
    /// exactly like a complete list — §12.72.7's lesson, twice paid for. Both
    /// buckets are single digits on a real device (2 and 0 on 20 August), and
    /// if either ever grows the count beside it says so.
    var answeredEmptyIDs: [String] = []

    /// The bucket that means the app has no explanation. Naming these matters
    /// more than the others: a count of unexplained activities is a question,
    /// and the ids are what turns it into an answer.
    var unexplainedIDs: [String] = []

    /// None of the above.
    ///
    /// EXPECTED TO BE ZERO, and it is the only number here worth watching. The
    /// other five are descriptions of states the app knows about; this one is
    /// the residual, and a residual above zero means an activity has no trace
    /// for a reason nothing in this app has a name for.
    var unexplained = 0

    /// What the screen asks: how many are missing, and is any of it a mystery.
    var missing: Int { total - withTrace }

    var isFullyExplained: Bool { unexplained == 0 }

    /// Every activity lands in exactly one bucket. Asserted by test rather
    /// than hoped for.
    var balances: Bool {
        withTrace + refused + answeredEmpty + belowThreshold
            + queued + unexplained == total
    }
}

nonisolated enum TraceCoverageReport {

    /// Classifies every activity, in order, into exactly one bucket.
    ///
    /// THE ORDER IS THE DEFINITION and it is not arbitrary. A trace that is
    /// present outranks every reason it might have been absent — the reasons
    /// are stale the moment the data arrives. A refusal outranks an empty
    /// answer because a 404 stops the detail fetch before the stream fetch is
    /// reached. The distance rule comes before the queue because an activity
    /// under the threshold is never put in the queue at all.
    static func classify(activities: [Activity],
                         hasTrace: (String) -> Bool,
                         refused: Set<String>,
                         answeredEmpty: Set<String>,
                         queued: Set<String>,
                         minDistance: Double) -> TraceCoverage {

        var out = TraceCoverage()
        for a in activities {
            out.total += 1
            if hasTrace(a.id)                 { out.withTrace += 1 }
            else if refused.contains(a.id)    { out.refused += 1 }
            else if answeredEmpty.contains(a.id) {
                out.answeredEmpty += 1
                out.answeredEmptyIDs.append(a.id)
            }
            else if a.distance < minDistance  { out.belowThreshold += 1 }
            else if queued.contains(a.id)     { out.queued += 1 }
            else {
                out.unexplained += 1
                out.unexplainedIDs.append(a.id)
            }
        }
        // Sorted so two exports of one state are byte-identical — the diff of
        // a pair either side of an action is this project's best device
        // instrument, and an unstable order would make every pair differ.
        out.answeredEmptyIDs.sort()
        out.unexplainedIDs.sort()
        return out
    }
}
