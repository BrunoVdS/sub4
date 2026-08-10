//
//  DatabaseBootstrap.swift
//  Sub4
//
//  Everything the app hydrates FROM, as one value — D7, patches 343 and 344,
//  ADR-0003 §12.91 and §12.92.
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
//  IT IS ALSO THE GATE. Which families hydrate is not a list somebody keeps in
//  step with this one — it IS this value's contents. `sliceUnderTest` is a
//  single on-or-off switch and a label; what actually moves is whatever the
//  bootstrap carries. That is what stops B2 from silently un-hydrating B1 by
//  changing a string.
//
//  ASSEMBLED OFF THE MAIN ACTOR. Every repository `load` is `nonisolated`
//  already — that is what `ReadBacks` relies on — and every store it feeds is a
//  main-actor singleton. So the reads happen on a utility task and the
//  hydration happens on the actor, which is the same shape `ReadBacks` has used
//  since 333. §12.9c.
//
//  IT DECIDES NOTHING ABOUT WHAT TO DO. It reads, says what it got, and hands
//  over what can be hydrated from. Whether a fault stops a launch is
//  `Sub4Launch`'s question; whether the app may serve at all is
//  `PersistenceMode`'s. A bootstrap that quietly substituted an empty value for
//  a failed read would be the exact defect the whole stage is built to prevent.
//
//  THE TWO VERDICTS, AND WHY THEY ARE TWO — §12.92
//  -----------------------------------------------
//  343 gave this type ONE verdict, `isTrustworthy`, and its own test found the
//  problem: the three sibling loads do not agree about what that word means.
//  `AthleteLoad.missing` is trustworthy — "a fresh database, not a fault" —
//  while `PlanLoad.noActiveVersion(versionsPresent: 0)`, the same empty
//  database, is not. Both are right for the question `ReadBacks` asks each load
//  in isolation; `&&`-ing them produces a boolean that means neither thing.
//
//  A launch has two questions and they have different consequences:
//
//      wasReadCleanly   did every read succeed?      false stops a hydration
//      canHydrate       does every family hold data?  false is a fresh install
//
//  343c removed the single verdict rather than ship it meaning neither thing.
//  This is it back, as two, beside the code that consumes them.
//

import Foundation

// MARK: - Where a store's data came from

/// What a store is currently serving, and from where — patch 344.
///
/// IT LIVES HERE, WITH THE READ DIRECTION, and not in a file of its own,
/// because it is the read direction's vocabulary: three stores answer in it and
/// the diagnostic paste prints it.
///
/// **THE REASON IT EXISTS IS §12.15.** `PlanStore.init` decodes the bundle, so
/// a store that was never hydrated still holds a perfectly good plan and looks
/// from the outside exactly like one that was. Nothing else in the app can tell
/// those apart, and after B9 the difference is between the stored plan and a
/// seed nobody chose — the hazard `PlanStore.decodeBundle`'s comment names in
/// full.
nonisolated enum StoreSource: Equatable, Sendable {

    /// The app's own JSON, as every launch up to patch 344.
    case files

    /// Rows, for everything this store holds.
    case database

    /// SOME families from rows and the rest still from the file.
    ///
    /// A STATE, NOT AN OVERSIGHT. `AthleteStore` holds zones, FTP and gear;
    /// B1 hydrates the first two and B5 takes the third, because gear distance
    /// is a Strava refresh rather than a store write (§12.68.4). The halves
    /// share no invariant, so the split is safe — but a split nobody can read
    /// is one somebody has to remember, and this is the project that keeps
    /// finding out what remembering costs. Both sides are named.
    case partial(fromDatabase: String, fromFiles: String)

    var line: String {
        switch self {
        case .files:    "the app's own files"
        case .database: "the database"
        case .partial(let db, let files):
            "the database for \(db), the app's own files for \(files)"
        }
    }
}

// MARK: - The bootstrap

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

    // MARK: The two verdicts

    /// Did every read succeed. TRUE FOR A CLEAN READ OF AN EMPTY DATABASE.
    ///
    /// False means something is wrong with the database or the schema, and a
    /// launch that hydrated anyway would be serving whatever the failure left
    /// behind. See the header for why this is not `isTrustworthy`.
    var wasReadCleanly: Bool {
        plan.wasReadCleanly && extras.wasReadCleanly && athlete.wasReadCleanly
    }

    /// Does every family hold something to hydrate a store from.
    ///
    /// FALSE IS NOT A FAULT. A migrated database nobody has imported into reads
    /// cleanly and holds nothing; that is a fresh install, and the answer is to
    /// leave the stores on their files rather than to fail.
    var canHydrate: Bool {
        plan.holdsContent && extras.holdsContent && athlete.holdsContent
    }

    /// The first family whose read did not succeed, in field order, named.
    ///
    /// NAMED RATHER THAN COUNTED — §12.39. "Something failed" sends somebody
    /// through three repositories; "the plan — The database could not be read"
    /// is a one-line answer.
    var firstFault: String? {
        if !plan.wasReadCleanly { return "the plan — \(plan.line)" }
        if !extras.wasReadCleanly { return "the plan's trimmings — \(extras.line)" }
        if !athlete.wasReadCleanly { return "the athlete — \(athlete.line)" }
        return nil
    }

    /// The first family that read cleanly and holds nothing. Nil when every
    /// family has content, and NOT an error — see `canHydrate`.
    var firstEmpty: String? {
        if plan.wasReadCleanly, !plan.holdsContent { return "the plan" }
        if extras.wasReadCleanly, !extras.holdsContent { return "the plan's trimmings" }
        if athlete.wasReadCleanly, !athlete.holdsContent { return "the athlete" }
        return nil
    }

    // MARK: What a store can be given

    /// The stored plan, whole, or nil.
    ///
    /// **TWO LOADS, ONE STORE, AND THAT IS WHY THIS IS A PROPERTY AND NOT TWO.**
    /// `Plan` carries the meta, weeks and sessions that `PlanRepository` reads
    /// AND the fuelling, warm-up and exercises that `PlanExtrasRepository`
    /// does. They are two families in `fieldCount` because they are two reads
    /// that can fail separately — but they feed one `PlanStore`, and hydrating
    /// with half of them would blank the Fuelling & race-day screen while every
    /// other figure stayed right.
    ///
    /// So it is all-or-nothing, in one place, and a caller cannot assemble a
    /// half plan without writing the constructor itself. §12.43.
    ///
    /// NIL IS NOT A REASON TO READ THE BUNDLE. §12.91.3 — the database may hold
    /// a different plan version, and every note, match decision and review
    /// change is written against `plan_session.uid` values from the stored one.
    var hydratablePlan: Plan? {
        guard case .loaded(let meta, let weeks, let sessions, _, _, _) = plan,
              case .loaded(let fuel, let warmup, let exercises, _) = extras
        else { return nil }
        return Plan(meta: meta,
                    weeks: weeks,
                    sessions: sessions,
                    exercises: exercises,
                    fuel: fuel,
                    warmup: warmup)
    }

    // MARK: The paste

    /// UNCONDITIONAL, one line per family plus the two verdicts — §12.54.2.
    /// Counts and sentences the loads already produce; nothing here names a
    /// session or an activity.
    ///
    /// THE VERDICTS ARE PRINTED, not just acted on. A launch that decided not
    /// to hydrate and said nothing would be indistinguishable from one where
    /// hydration was never wired in — which is §12.54.2's whole subject.
    var diagnosticLines: [String] {
        var l = ["Database bootstrap: \(Self.fieldCount) families",
                 "  plan: \(plan.line)",
                 "  plan trimmings: \(extras.line)",
                 "  athlete: \(athlete.line)"]
        l.append("  every read succeeded: \(wasReadCleanly ? "yes" : "no")")
        l.append("  first fault: \(firstFault ?? "none")")
        l.append("  every family holds data: \(canHydrate ? "yes" : "no")")
        l.append("  first family with nothing: \(firstEmpty ?? "none")")
        return l
    }

    /// How many lines `diagnosticLines` produces — pinned so a family added
    /// without a line is a test failure rather than a gap in the paste.
    static let diagnosticLineCount = fieldCount + 5
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
