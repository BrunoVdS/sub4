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
    /// PATCH 357 — D7 slice B2. Notes and commute decisions come out of ONE
    /// read and are one family; match decisions are a second read that can fail
    /// on its own, which is `fieldCount`'s rule and the same reason the plan and
    /// its trimmings are two entries.
    let authored: AuthoredLoad
    let decisions: MatchDecisionLoad
    /// **PATCH 377 — D7 slice B2, finished.** A third read that can fail on its
    /// own, for `decisions`' reason. The moves were built at 365 and the slice
    /// table of 10 August has no row for them; they are authored data of
    /// exactly B2's kind and were the last of it still on a file.
    let moves: PlanMoveLoad
    /// **PATCH 379 — D7 slice B3, groundwork.** The seventh family, and the
    /// first one the bootstrap reads without feeding anything from it.
    ///
    /// APPENDED RATHER THAN PLACED BESIDE THE ATHLETE, where it arguably
    /// belongs by subject. Field order is `firstFault`'s order and the paste's
    /// order, and reordering the six that exist would move every line a reader
    /// has learned the position of, to buy nothing. `moves` was appended at
    /// 377 for the same reason.
    let activities: ActivityLoad

    /// THE NUMBER A TEST HOLDS — see `AppStores.fieldCount` and its comment.
    ///
    /// Pinning the count does not prove the forwarding. It makes adding a
    /// family a thing somebody has to acknowledge, which is the half that can
    /// be checked cheaply. Three at B1: the plan, its trimmings, and the
    /// athlete.
    static let fieldCount = 7

    // MARK: The two verdicts

    /// Did every read succeed. TRUE FOR A CLEAN READ OF AN EMPTY DATABASE.
    ///
    /// False means something is wrong with the database or the schema, and a
    /// launch that hydrated anyway would be serving whatever the failure left
    /// behind. See the header for why this is not `isTrustworthy`.
    var wasReadCleanly: Bool {
        plan.wasReadCleanly && extras.wasReadCleanly && athlete.wasReadCleanly
            && authored.wasReadCleanly && decisions.wasReadCleanly
            && moves.wasReadCleanly && activities.wasReadCleanly
    }

    /// Does every family hold something to hydrate a store from.
    ///
    /// FALSE IS NOT A FAULT. A migrated database nobody has imported into reads
    /// cleanly and holds nothing; that is a fresh install, and the answer is to
    /// leave the stores on their files rather than to fail.
    /// THE TWO AUTHORED FAMILIES ARE DELIBERATELY NOT HERE — patch 357.
    ///
    /// This verdict means "the database has been imported into". The plan, its
    /// trimmings and the athlete always hold content after an import, so their
    /// emptiness is diagnostic. **Zero notes is not.** A device where the
    /// athlete has written nothing reads cleanly and holds nothing for ever,
    /// and letting that block the plan's hydration would make a legitimate
    /// state look like a fresh install.
    ///
    /// What each authored family does about its own emptiness is
    /// `hydratableAuthored`'s and `hydratableDecisions`' answer, and it is not
    /// the same answer.
    /// **AND `.activities` IS DELIBERATELY NOT HERE EITHER — patch 379.**
    /// The three above are filled by a plan import, which runs at every
    /// launch. Activities arrive from a Strava sync, which is a different
    /// event that may never have run. A device on its first launch holds a
    /// plan and no activities, and reading that as "there is nothing here to
    /// hydrate from" would refuse the plan over the absence of a sync.
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
        if !authored.wasReadCleanly {
            return "the notes and commutes — \(authored.line)"
        }
        if !decisions.wasReadCleanly {
            return "the match decisions — \(decisions.line)"
        }
        if !moves.wasReadCleanly { return "the plan moves — \(moves.line)" }
        if !activities.wasReadCleanly {
            return "the activities — \(activities.line)"
        }
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

    /// The authored families that read cleanly and hold nothing.
    ///
    /// SEPARATE FROM `firstEmpty`, and the separation is the decision. That one
    /// answers "has this database been imported into", where empty is a
    /// finding. This answers "which stores keep their files this launch", where
    /// empty is ordinary and permanent — and it is a LIST rather than a first,
    /// because both can be true at once and a reader wants both.
    var emptyAuthoredFamilies: [String] {
        var out: [String] = []
        if authored.wasReadCleanly, !authored.holdsContent {
            out.append("notes and commutes")
        }
        if decisions.wasReadCleanly, !decisions.holdsContent {
            out.append("match decisions")
        }
        if moves.wasReadCleanly, !moves.holdsContent {
            out.append("plan moves")
        }
        return out
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

    /// Notes and commute decisions, together, or nil.
    ///
    /// TOGETHER FOR `hydratablePlan`'S REASON: they come out of one read and
    /// feed two stores, and handing over half of them would leave one screen
    /// showing database values beside another showing file values with nothing
    /// saying which.
    ///
    /// **NIL WHEN THE FAMILY IS EMPTY, AND THAT IS THE DECISION OF 14 AUGUST.**
    /// A clean read holding no notes does not mean the athlete wrote none — it
    /// can also mean the write-through has not caught up, and hydrating there
    /// would blank `notes.json`'s only copy. §12.8.1 is what that costs. An
    /// empty family keeps its files and `emptyAuthoredFamilies` says so.
    var hydratableAuthored: (notes: [NotesStore.Note],
                             commutes: [CommuteDecision])? {
        guard case .loaded(let notes, let commutes, _) = authored,
              authored.holdsContent
        else { return nil }
        return (notes, commutes)
    }

    /// The stored match decisions, or nil. Same rule, same reason — and on this
    /// device it is nil, because none has ever been recorded.
    var hydratableDecisions: [MatchDecision]? {
        guard case .loaded(let d, _) = decisions, decisions.holdsContent
        else { return nil }
        return d
    }

    /// The stored plan moves, or nil. Same rule, same reason — patch 377.
    ///
    /// NIL WHEN EMPTY, and on this store that matters more than on the others:
    /// a move is one row in `correction`, the athlete makes them rarely, and a
    /// clean read of an empty table is indistinguishable from a write-through
    /// that has not caught up. Hydrating there would blank `moves.json`, which
    /// is the legacy side's only copy. §12.8.1.
    var hydratableMoves: [PlanMove]? {
        guard case .loaded(let m, _) = moves, moves.holdsContent
        else { return nil }
        return m
    }

    /// The stored activities, or nil — patch 380, D7 slice B3.
    ///
    /// **NIL WHEN EMPTY, AND IT IS THE SAME RULE FOR A DIFFERENT REASON.** The
    /// three authored families withhold an empty payload because the athlete's
    /// writing cannot be fetched again. This one withholds because a clean
    /// read of an empty `activity` table is a device between its first launch
    /// and its first sync — and hydrating there would replace a store holding
    /// the whole history with nothing at all.
    ///
    /// That the rows are RE-FETCHABLE is not the answer to that. §12.122.1:
    /// nothing re-fetches on its own, the cursor survives, and what the
    /// athlete sees is his history disappear until he notices and presses
    /// Reset. An empty history that looks like real data is `Sub4Launch`'s own
    /// worst failure, and this is the cheapest place to refuse it.
    ///
    /// STILL DELIBERATELY NOT IN `emptyAuthoredFamilies` — that list means
    /// "stores keeping a file nobody may blank", and this file can be rebuilt
    /// from the source. §12.123.3.
    var hydratableActivities: [Activity]? {
        guard case .loaded(let a, _) = activities, activities.holdsContent
        else { return nil }
        return a
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
        // PATCH 358 — "READ AT LAUNCH", AND IT IS A DEFECT FIX.
        //
        // On 14 August the device recorded two match decisions, imported them,
        // and this block said `match decisions: 0` twenty-six lines above
        // `match_decision: 2`. Both numbers were right: `Sub4Launch.bootstrap`
        // is read once, at launch, ON PURPOSE — 345's argument is that it
        // records what the bootstrap saw on the launch that DECIDED the
        // hydration, and refreshing it would destroy exactly that. The table
        // counts further down are live.
        //
        // Nothing said which was which, so the paste contradicted itself and a
        // reader had to open `Sub4Launch` to learn that it did not. §12.15. The
        // sentence goes in the header because that is where a reader meets the
        // block, and it stays ONE line so `diagnosticLineCount` does not move.
        var l = ["Database bootstrap: \(Self.fieldCount) families, read at "
                 + "launch — the table counts further down are live and can "
                 + "have moved since",
                 "  plan: \(plan.line)",
                 "  plan trimmings: \(extras.line)",
                 "  athlete: \(athlete.line)",
                 "  notes and commutes: \(authored.line)",
                 "  match decisions: \(decisions.line)",
                 "  plan moves: \(moves.line)",
                 // PATCH 379. NOT under the authored families and not in
                 // `emptyAuthoredFamilies` below: activities are fetched, not
                 // written by the athlete, and an empty one is a device
                 // between its first launch and its first sync rather than a
                 // store keeping a file nobody may blank. §12.123.
                 "  activities: \(activities.line)"]
        l.append("  every read succeeded: \(wasReadCleanly ? "yes" : "no")")
        l.append("  first fault: \(firstFault ?? "none")")
        l.append("  every family holds data: \(canHydrate ? "yes" : "no")")
        l.append("  first family with nothing: \(firstEmpty ?? "none")")
        // PATCH 357. A SEPARATE LINE FROM THE ONE ABOVE, because they are
        // separate questions — see `emptyAuthoredFamilies`. Unconditional, so
        // "none" is the sentence that proves both families held something.
        l.append("  authored families keeping their files: "
                 + (emptyAuthoredFamilies.isEmpty
                    ? "none" : emptyAuthoredFamilies.joined(separator: ", ")))
        return l
    }

    /// How many lines `diagnosticLines` produces — pinned so a family added
    /// without a line is a test failure rather than a gap in the paste.
    static let diagnosticLineCount = fieldCount + 6
}

nonisolated enum DatabaseBootstrapReader {

    /// Reads every family, in one pass, off the main actor.
    ///
    /// ONE PLACE. A second assembly point is a second list that can disagree
    /// with this one — §12.43, eleven applications and counting.
    static func read(_ db: Sub4Database) -> DatabaseBootstrap {
        DatabaseBootstrap(plan: PlanRepository.load(db),
                          extras: PlanExtrasRepository.load(db),
                          athlete: AthleteRepository.load(db),
                          authored: AuthoredRepository.load(db),
                          decisions: MatchDecisionRepository.load(db),
                          moves: PlanMoveRepository.load(db),
                          // `all`, not `activity(_:storeID:)`. Ordered by
                          // `startUTC` — §4.1 makes that authoritative for
                          // order, where `startLocal` is authoritative for
                          // which training day a session belongs to.
                          activities: ActivityRepository.all(db))
    }
}

// MARK: - What a launch does about it

/// What happened to the hydration this launch, in one value that reaches the
/// paste — patch 345, D7 slice B1.
///
/// FOUR OUTCOMES, AND THREE OF THEM ARE "THE STORES KEPT THEIR FILES".
/// §12.54.2: a launch that decided not to hydrate and said nothing would be
/// indistinguishable from one where hydration was never wired in. The reason is
/// carried, not just the fact.
nonisolated enum HydrationOutcome: Equatable, Sendable {

    /// The mode does not want it. Carries the mode's own sentence, so the paste
    /// does not have to be read alongside `Reads from:` to make sense.
    case notWanted(String)

    /// A read did not succeed. THE STORES KEEP THEIR FILES AND THE BUNDLE IS
    /// NOT A RESCUE — §12.91.3. At B9 this becomes a blocked launch; until then
    /// it is a finding that has to be impossible to miss.
    case fault(String)

    /// Every read succeeded and a family holds nothing. A fresh install, not a
    /// fault, and the difference is the one the whole stage rests on.
    case nothingStored(String)

    /// It happened. Carries what moved.
    case hydrated(String)

    var line: String {
        switch self {
        case .notWanted(let mode):   "not this launch — \(mode)"
        case .fault(let why):        "REFUSED, a read did not succeed — \(why)"
        case .nothingStored(let who): "nothing stored to hydrate from — \(who)"
        case .hydrated(let what):    "hydrated \(what)"
        }
    }

    /// Whether this outcome is something wrong, as opposed to something that
    /// did not apply. Drives nothing at B1 — it is what B9 blocks on.
    var isFault: Bool {
        if case .fault = self { return true }
        return false
    }
}

/// The decision, pure — patch 345.
///
/// PURE FOR THE SAME REASON `PersistenceAuthority.derive` IS. Two of the four
/// outcomes have never occurred on a device and one of them never should; a
/// decision that can only be exercised by breaking a real database is a
/// decision nobody checks. Every combination is driven from a test instead.
///
/// `Sub4Launch` calls this and then does what it says. It holds no branch of
/// its own, because a second place deciding whether to hydrate is a second
/// place that can disagree — §12.43.
nonisolated enum HydrationPlanner {

    /// Either leave the stores alone and say why, or hand over everything three
    /// stores need.
    ///
    /// **A PARTIAL HYDRATION IS UNREPRESENTABLE.** `.hydrate` carries the whole
    /// plan and the whole athlete; there is no case that carries some of it. The
    /// same argument as `AppStores`' seventeen fields and `hydratablePlan`'s
    /// all-or-nothing: the type refuses what a caller could otherwise get wrong.
    enum Instruction {
        case leaveOnFiles(HydrationOutcome)
        case hydrate(plan: Plan,
                     constants: AthleteConstants,
                     zones: [AthleteStore.HRZone],
                     ftp: Int?,
                     // PATCH 357 — OPTIONAL, AND THAT IS NOT A WEAKENING OF THE
                     // RULE ABOVE. The plan and the athlete are still
                     // all-or-nothing; these are nil for two distinct and
                     // legitimate reasons — the build does not hydrate the
                     // family yet (358 is the line), or the family read cleanly
                     // and holds nothing. Both keep their files, and
                     // `emptyAuthoredFamilies` is what tells them apart in the
                     // paste.
                     authored: (notes: [NotesStore.Note],
                                commutes: [CommuteDecision])?,
                     decisions: [MatchDecision]?,
                     // PATCH 377 — the third optional family, nil for the same
                     // two distinct reasons as the two above it.
                     moves: [PlanMove]?,
                     // PATCH 380 — the fourth, and the first that is not the
                     // athlete's own writing. Nil for those same two distinct
                     // reasons: this build does not feed the family (381 is
                     // the line), or the table read cleanly and holds nothing.
                     // The plan and the athlete are still all-or-nothing.
                     activities: [Activity]?)
    }

    /// ORDER MATTERS AND IT IS THE POINT.
    ///
    /// The fault check comes before the content check, so an unreadable plan
    /// reports as a fault and not as "nothing stored". Those two sentences send
    /// a reader to completely different places — one to a corrupt database, the
    /// other to an import that has not run — and getting them the wrong way
    /// round is §12.15 in the one value a launch publishes about itself.
    static func decide(mode: PersistenceMode,
                       bootstrap: DatabaseBootstrap) -> Instruction {

        guard mode.hydratesFromDatabase else {
            return .leaveOnFiles(.notWanted(mode.line))
        }
        if let fault = bootstrap.firstFault {
            return .leaveOnFiles(.fault(fault))
        }

        // THE `if let` IS THE CHECK, and there is deliberately no `canHydrate`
        // guard in front of it. A guard whose failure the next line makes
        // impossible is §12.69's guard that cannot fail; this binds what it
        // needs and falls through when it cannot. `canHydrate` earns its keep
        // in the paste, where a reader wants the answer without the values.
        if let plan = bootstrap.hydratablePlan,
           case .loaded(let constants, let ftp, let zones) = bootstrap.athlete {
            // PATCH 357. TWO CONDITIONS PER FAMILY, ASKED SEPARATELY: does this
            // build hydrate it, and does the database hold anything for it. A
            // single combined check would collapse "not yet" and "nothing
            // stored" into one nil, and those send a reader to opposite places.
            return .hydrate(
                plan: plan, constants: constants, zones: zones, ftp: ftp,
                authored: PersistenceAuthority.hydrates(.authored)
                    ? bootstrap.hydratableAuthored : nil,
                decisions: PersistenceAuthority.hydrates(.decisions)
                    ? bootstrap.hydratableDecisions : nil,
                moves: PersistenceAuthority.hydrates(.moves)
                    ? bootstrap.hydratableMoves : nil,
                // PATCH 380. FALSE IN THIS BUILD, AND THAT IS THE PATCH —
                // `hydratedFamilies` does not name `.activities` until 381, so
                // the machinery below is complete and unreachable. The two
                // conditions stay separate for 357's reason: "this build does
                // not feed it" and "the table holds nothing" send a reader to
                // opposite places, and one combined check would collapse them
                // into one nil.
                activities: PersistenceAuthority.hydrates(.activities)
                    ? bootstrap.hydratableActivities : nil)
        }
        return .leaveOnFiles(
            .nothingStored(bootstrap.firstEmpty ?? "a family this build does not name"))
    }
}
