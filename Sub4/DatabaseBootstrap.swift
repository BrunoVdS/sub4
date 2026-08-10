//
//  DatabaseBootstrap.swift
//  Sub4
//
//  Everything the app hydrates FROM, as one value — D7, patch 343,
//  ADR-0003 §12.91.
//
//  THE MIRROR OF `AppStores`, AND THE SAME ARGUMENT
//  ------------------------------------------------
//  §12.45: `Sub4Import.run` took twenty parameters and eighteen were defaulted,
//  so a forgotten one was not a compile error — it was a table that quietly
//  stopped being imported, and nothing said so until a read-back reported the
//  rows as missing data. `AppStores` fixed that for the WRITE direction and
//  pins its own field count at 17 so adding one is a thing somebody has to
//  acknowledge.
//
//  D7 needs the mirror. Without it, activation is nine hand-written load lists
//  in nine stores, and a forgotten one is a store that hydrates from nothing —
//  which after B9 shows an empty training history that looks like real data.
//  `Sub4Launch`'s own header names that as the worst failure this app has
//  available.
//
//  THREE FIELDS AT B1, AND IT GROWS BY SLICE
//  -----------------------------------------
//  `fieldCount` is pinned by test exactly as `AppStores.fieldCount` is. Each
//  slice adds its family and bumps the number in the same patch, so the diff
//  shows the decision.
//
//  ASSEMBLED OFF THE MAIN ACTOR. Every repository `load` is `nonisolated`
//  already — that is what `ReadBacks` relies on — and every store it feeds is a
//  main-actor singleton. So the reads happen on a utility task and the
//  hydration happens on the actor, which is the same shape `ReadBacks` has used
//  since 333. §12.9c.
//
//  IT CARRIES, AND IT DECIDES NOTHING — AND AT 343 IT DOES NOT EVEN JUDGE
//  ----------------------------------------------------------------------
//  343 shipped this type with `isTrustworthy` and `firstFailure` on it. Its own
//  test found them wrong, and the finding is worth more than the code was.
//
//  THE THREE SIBLING LOADS DO NOT AGREE ABOUT WHAT `isTrustworthy` MEANS.
//
//    · `AthleteLoad.isTrustworthy` is TRUE for `.missing`, and its comment says
//      why: "No profile row. A fresh database, not a fault."
//    · `PlanLoad.isTrustworthy` and `PlanExtrasLoad.isTrustworthy` are FALSE
//      for `.noActiveVersion(versionsPresent: 0)` — the SAME situation, the
//      same fresh database, the opposite answer.
//
//  Neither is wrong on its own. `ReadBacks` asks each load one question — "is
//  there something here to compare?" — and for that question a clean read of an
//  empty database and a failed read really do have the same answer: no. Twelve
//  files rely on that reading and none of them is being changed here.
//
//  But `&&`-ing three of them together produces a boolean that means neither
//  thing, and a launch cannot act on it: "the plan could not be read" must stop
//  a hydration, "there is no plan yet" must not. §12.15, and this file's own
//  header used to claim it kept them apart while the code collapsed them.
//
//  So the verdicts are GONE from 343 rather than shipped wrong. They return in
//  344 with the hydration that consumes them, as two questions with two names —
//  did every read succeed, and does every family hold something — and the tests
//  below pin the disagreement so that resolving it has to be deliberate.
//
//  §12.69: a guard that cannot fail has not been tested. At 343 nothing calls
//  this type at all; a verdict with no caller is a guard that cannot fail.
//

import Foundation

/// What one launch read out of the database, before any store was touched.
///
/// EVERY FIELD IS A LOAD, NOT A VALUE. `PlanLoad` distinguishes loaded, a
/// legitimately absent optional, and a failed or corrupt read — four shapes at
/// 323, because "stored but not activated" and "two plans both active" are
/// states the schema permits and nothing else could name. Flattening those to
/// `Plan?` here would throw away the distinction the repositories exist for,
/// and it is the distinction the whole of D7's safety rests on.
nonisolated struct DatabaseBootstrap: Sendable {

    let plan: PlanLoad
    let extras: PlanExtrasLoad
    let athlete: AthleteLoad

    /// THE NUMBER A TEST HOLDS — see `AppStores.fieldCount` and its comment.
    ///
    /// Pinning the count does not prove the forwarding. It makes adding a
    /// family a thing somebody has to acknowledge, which is the half that can
    /// be checked cheaply. Three at B1: the plan, its trimmings, and the
    /// athlete.
    static let fieldCount = 3

    /// UNCONDITIONAL, one line per family — §12.54.2. Counts and sentences the
    /// loads already produce; nothing here names a session or an activity.
    ///
    /// THIS IS THE WHOLE INTERFACE AT 343. Each `line` already says which of
    /// the load's shapes it is in — "No plan has been imported." reads nothing
    /// like "The database could not be read — …" — so the paste carries the
    /// distinction in full even while no code judges it. A reader gets the
    /// truth before the launch does.
    var diagnosticLines: [String] {
        ["Database bootstrap: \(Self.fieldCount) families",
         "  plan: \(plan.line)",
         "  plan trimmings: \(extras.line)",
         "  athlete: \(athlete.line)"]
    }
}

nonisolated enum DatabaseBootstrapReader {

    /// Reads every family, in one pass, off the main actor.
    ///
    /// ONE PLACE. A second assembly point is a second list that can disagree
    /// with this one — §12.43, eleven applications and counting.
    static func read(_ db: Sub4Database) -> DatabaseBootstrap {
        DatabaseBootstrap(plan: PlanRepository.load(db),
                          extras: PlanExtrasRepository.load(db),
                          athlete: AthleteRepository.load(db))
    }
}
