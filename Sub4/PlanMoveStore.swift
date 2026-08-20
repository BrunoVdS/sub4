//
//  PlanMoveStore.swift
//  Sub4
//
//  When a session was actually done — patch 362, ADR-0003 §12.106.
//  PLAN-MOVES-GROUNDWORK §6.1.
//
//  WHAT A MOVE IS, AND WHAT IT IS NOT
//  ----------------------------------
//  The plan says Sunday's long run is on Sunday. It was done on Monday. A move
//  records that, and nothing else: it changes the plan's idea of WHEN a session
//  was due, on the day it was actually done.
//
//  It does NOT move the activity — Strava's record of what happened is not the
//  app's to edit. It does NOT change `weekUid`, so the session stays in the
//  week the plan put it in and the week's planned-km statistic does not move
//  (§3.1 of the groundwork, and the cost is stated there rather than hidden:
//  a session can appear in one week's list and on a day inside the next one).
//
//  NOTHING READS THIS YET, AND THAT IS THE PATCH
//  ---------------------------------------------
//  This file, `moves.json`, and every place a store file has to be DECLARED.
//  No database column, no importer claim, no application to a `Plan`, no
//  gesture in the UI. `theStoreIsNotWiredIntoAnything` is the test that says
//  so, and it is here so that the patch which wires it in has a diff
//  containing nothing else. B1 and B2 both paid for that twice — four failures
//  at 346, and at 358 the one line that mattered was visible in a diff of one
//  line.
//
//  DECLARED BEFORE ANYTHING WRITES IT, and that is patch 195's rule rather
//  than a preference. The alternative leaves a window in which a file exists
//  in Application Support and "Delete local data" walks straight past it —
//  which is exactly how `details.json` outlived four versions of this app. So
//  `DataLifecycle`, the delete flow, `LegacyStore`, the classifier, the
//  snapshot and the authored export all learn about `moves.json` in this
//  patch, while the file cannot yet exist on any device.
//
//  IT FOLLOWS `CommuteStore` EXACTLY
//  ---------------------------------
//  A dictionary keyed by the subject's id, a file in Application Support, a
//  failable save whose memory copy is rolled back when the write fails, a
//  `clear` that is a real answer distinct from never having decided, and
//  `DatabaseWriteThrough.noteAuthoredChange` fired AFTER a successful write
//  and never before — §12.94, the rule 348 established and B2 made
//  load-bearing.
//
//  Following it exactly is the point. A fifth authored store that invented its
//  own shape would be a fifth thing to check every time the rules around
//  authored data change, and those rules have changed three times this month.
//
//  WHAT `clear` MEANS, AND WHY IT IS NOT `set` WITH THE PLANNED DATE
//  -----------------------------------------------------------------
//  "I moved it back" and "I never moved it" are the same end state and
//  different facts. Writing the planned date as a move would leave a row
//  asserting an override that overrides nothing — and the reconciliation prune
//  would then have to decide whether a no-op correction is stale. Removing the
//  record says what happened.
//
//  THE UID IS THE PLAN'S OWN, AND IT CAN BE REISSUED
//  -------------------------------------------------
//  `plan_session.uid` carries the session's `seq` — its position within its day
//  (§12.96.3) — so a new plan version that changes what is on a day reissues
//  uids and a move naming an old one is orphaned. This is the exposure the
//  notes already have and have had since 274.
//
//  An orphaned move is harmless in a way an orphaned note is not: the session
//  simply shows on its planned day. Nothing is lost and nothing is wrong.
//  Recorded because the opposite assumption — that a move is durable across
//  plan versions — would be wrong, and `PlanVersionCensus.uidsHeldOnlyBy`
//  already surfaces the uids that would be affected.
//

import Foundation
import Observation

// MARK: - The record

/// One session, moved to one day.
///
/// `movedTo` IS A DAY KEY AND NOT A `Date`. `Session.date` is `String?`
/// holding `"yyyy-MM-dd"`, and the whole feature is an override of that field.
/// A `Date` here would need a calendar and a time zone to become the thing it
/// overrides, and the two conversions could disagree — §12.43 with a
/// formatter in it. The vocabulary the plan uses is the vocabulary stored.
nonisolated struct PlanMove: Codable, Hashable, Identifiable, Sendable {

    /// `plan_session.uid`. The plan's own identifier, never remapped.
    var sessionUid: String

    /// `"yyyy-MM-dd"` — the day it was actually done.
    var movedTo: String

    /// When the athlete said so. Not the day it was moved TO, and not the day
    /// this record was written to the database — `CommuteDecision.decided`'s
    /// rule, and the column `correction.authoredUTC` expects.
    var decided: Date

    var id: String { sessionUid }

    /// Whether a string is the shape `Session.date` holds.
    ///
    /// **NO FORMATTER, DELIBERATELY.** `DateFormatter` brings a locale, a
    /// calendar and a time zone to a question that has none of those in it:
    /// this asks whether ten characters look like a plan day key, which is a
    /// property of the string. A formatter would also accept things the plan
    /// never writes and reject things it does, depending on the device.
    ///
    /// IT DOES NOT CHECK THE DAY AGAINST THE MONTH. `2026-02-31` passes, and
    /// that is the honest limit of a shape check — stated rather than implied.
    /// Nothing downstream parses this: `PlanCorrections` will compare it to
    /// `Session.date` as a string, so a day that does not exist matches no
    /// session and shows nothing, which is the same outcome as an orphaned uid.
    nonisolated static func isDayKey(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        // ASCII DIGITS, NOT `isNumber`. `Character.isNumber` is true of Arabic-
        // Indic digits and of "½", none of which `Session.date` has ever held.
        for part in parts where !part.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return false
        }
        guard let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return false }
        return true
    }
}

/// Why a move was refused before anything was written.
///
/// ITS OWN TYPE RATHER THAN A `StoreWriteError`. That type says which store
/// failed at which STAGE of a write, and nothing was encoded or written here —
/// the value never got that far. Reporting a rejected day key as an encoding
/// failure would send somebody to look at the disk.
nonisolated enum PlanMoveFault: Error, Equatable {
    /// The string is not `"yyyy-MM-dd"`. Carries the offending value, which is
    /// a date the athlete chose and therefore screen-only — §12.7.
    case notADayKey(String)

    var line: String {
        switch self {
        case .notADayKey:
            "That is not a day the plan could name."
        }
    }
}

// MARK: - What the session side can undo — patch 367

/// Whether this session sits where the plan put it, and where that was.
///
/// **`MatchStanding`'s TWIN, AND THE PARALLEL IS THE DESIGN.** 359 built that
/// one because a recorded choice and no choice at all rendered identically in
/// the same sheet. This answers the same question about the DAY rather than the
/// recording, in the same shape, and its `line` is printed on every state
/// including the boring one — §12.54.2, a row that vanishes at zero cannot be
/// told from a row nobody wired in.
///
/// PURE, AND TAKING THE MOVE RATHER THAN THE STORE. What is needed is whether a
/// row exists and what the plan asked for; a test should not have to build a
/// `PlanMoveStore` on disk to ask. §12.69 — the decision lives here so it can
/// fail in a test rather than inside a `body`.
nonisolated enum MoveStanding: Equatable {

    /// No stored move. The session is on the day the plan asked for.
    case notMoved

    /// A move is stored, and the plan asked for this day.
    case movedFrom(String)

    /// A move is stored and the plan gives this session NO day at all — the
    /// logged prologue weeks. §12.110.7 disclosed that these could be moved and
    /// never put back, for want of a day to go back to. From the session side
    /// there is nothing to go back TO and nothing needed: removing the row
    /// returns the session to having no day.
    case movedFromNoDay

    /// Was anything stored at all — what the control is enabled on. A button
    /// that undoes nothing is a button that looks broken (359's rule, for the
    /// same reason).
    var isMoved: Bool { self != .notMoved }

    /// §12.54.2 — printed on every state, the boring one included.
    ///
    /// The middle case discloses what putting it back does NOT do BEFORE the
    /// tap. Afterwards `MatchStanding.choseSomethingGone` says the same thing
    /// about the state it leaves behind.
    var line: String {
        switch self {
        case .notMoved:
            "This session is on the day the plan asked for."
        case .movedFrom(let day):
            "You moved this session here from \(day). Putting it back does not "
            + "change which recording it is matched to — if that recording is "
            + "on another day, the session will read as not done until you "
            + "choose again."
        case .movedFromNoDay:
            "The plan gives this session no day of its own; you gave it one. "
            + "Putting it back removes that day, so it will not appear on any "
            + "day until you place it again."
        }
    }

    /// What the button says. Nil when there is nothing to undo — the caller
    /// still renders the control, disabled, so the row cannot be mistaken for
    /// one nobody wired in.
    var action: String {
        switch self {
        case .notMoved:
            return "Back to its planned day"
        case .movedFrom(let day):
            // §12.15 — a key the formatter cannot read falls back to the key
            // rather than to an empty button.
            guard let d = DayKey.date(day) else { return "Back to \(day)" }
            return "Back to \(DayKey.pretty(d))"
        case .movedFromNoDay:
            return "Back to no day at all"
        }
    }

    /// Takes the MOVE, not the store, and the PLANNED date, not the served one.
    ///
    /// The served date already carries the move — that was 366's defect
    /// (§12.110.7) — so deriving "is it moved" by comparing it against anything
    /// would be asking the corrected value whether it was corrected. The stored
    /// row is the only honest answer, and a row that happens to name the planned
    /// day (which 366 could write and 366a cannot) still counts as moved, so it
    /// can be cleared rather than stranded.
    nonisolated static func of(storedMove: PlanMove?,
                               plannedDate: String?) -> MoveStanding {
        guard storedMove != nil else { return .notMoved }
        guard let plannedDate else { return .movedFromNoDay }
        return .movedFrom(plannedDate)
    }
}

// MARK: - Applying them — patch 365

/// Rewrites `Session.date` for every session a move names.
///
/// **ONE APPLIER, AND `PlanStore` IS ITS ONLY CALLER.** The groundwork asked
/// for two — `PlanStore` and `PlanRepository.load` — so that both sides of the
/// plan read-back would agree. That instruction predates patch 343: the
/// read-back's app side is now `PlanStore.decodeBundle()`, a pristine bundle,
/// and its database side is `plan_session`, written from a seed that is also
/// the pristine bundle (§12.93). Both sides are already move-free.
///
/// Applying moves to both would add an operation to a comparison whose data
/// contains none, and it would blind the thing worth catching: **`plan_session`
/// must never hold a moved date.** A move lives in `correction`. If one ever
/// leaked into the plan tables, that comparison is what would see it — and
/// applying moves to both sides is precisely how it would stop being able to.
/// §12.99, in the direction nobody expects.
///
/// IT IS A PURE FUNCTION AND IT TAKES THE MOVES. No store, no singleton, no
/// database. That is what lets `PlanStore` stay testable and what lets this be
/// driven through every case without a container.
nonisolated enum PlanCorrections {

    /// The sessions, with every named one moved.
    ///
    /// A MOVE NAMING NO SESSION IS NOT AN ERROR. `plan_session.uid` carries the
    /// session's position within its day, so a plan revision reissues uids and
    /// a move naming an old one names nothing (§12.106.4). The session simply
    /// stays where the plan put it, which is the whole reason an orphan was
    /// described as harmless rather than fixed.
    ///
    /// IT WILL GIVE A DATE TO A SESSION THAT HAD NONE, and that is stated
    /// rather than guarded. The eight dateless sessions are the logged July
    /// prologue weeks; no screen offers a move for one, because the reverse
    /// picker lists sessions out of `byDate` and a dateless session is not in
    /// it. If one ever arrives here, moving it is the honest reading of what
    /// the record says.
    static func apply(_ sessions: [Session], moves: [PlanMove]) -> [Session] {
        guard !moves.isEmpty else { return sessions }
        let byUid = Dictionary(moves.map { ($0.sessionUid, $0) },
                               uniquingKeysWith: { first, _ in first })
        return sessions.map { s in
            guard let move = byUid[s.uid] else { return s }
            var moved = s
            moved.date = move.movedTo
            return moved
        }
    }

    /// The same, on a whole plan. `weeks` are untouched — a move changes the
    /// DAY a session was done and never its week membership, so the Week view
    /// and `plan_week_stat` keep the plan's own arithmetic. Groundwork §3.1,
    /// and the cost is disclosed there rather than hidden: a session can appear
    /// in one week's list and on a day inside the next one.
    static func apply(_ plan: Plan, moves: [PlanMove]) -> Plan {
        guard !moves.isEmpty else { return plan }
        return Plan(meta: plan.meta,
                    weeks: plan.weeks,
                    sessions: apply(plan.sessions, moves: moves),
                    exercises: plan.exercises,
                    fuel: plan.fuel,
                    warmup: plan.warmup)
    }
}

// MARK: - The store

@Observable
final class PlanMoveStore {

    static let shared = PlanMoveStore()

    private(set) var moves: [String: PlanMove] = [:]

    /// Where the moves this store is serving came from — patch 368.
    ///
    /// `.files` AND NOTHING SETS IT YET, WHICH IS THE POINT. Moves are not
    /// hydrated from the database, so this store reads its own file and the
    /// `session moves` comparison is a genuinely independent second opinion
    /// (§12.99). The launch block printed where four stores read and said
    /// nothing about this one, so a reader could not tell "reads its own file"
    /// from "not wired in" — §12.54.2, on the page whose job is answering
    /// exactly that. `CommuteStore.servedFrom` sat at `.files` the same way
    /// until B2 moved it, and when moves are hydrated this line moves on its
    /// own rather than going quietly stale.
    private(set) var servedFrom: StoreSource = .files

    // MARK: Hydration — D7 slice B2, patch 377

    /// Replaces the moves with the stored ones — and the comment above this
    /// property has been waiting for this function since 363.
    ///
    /// DOES NOT WRITE, for `NotesStore.hydrate`'s reason and
    /// `PersistenceMode`'s rule: `moves.json` stays complete and authoritative
    /// while the slice is under test, which is what makes taking `.moves` back
    /// out of `hydratedFamilies` a full rollback rather than a data loss.
    func hydrate(from stored: [PlanMove]) {
        moves = Dictionary(stored.map { ($0.sessionUid, $0) },
                           uniquingKeysWith: { first, _ in first })
        servedFrom = .database
    }

    private let fileURL: URL

    private init() {
        database = .theLaunchs
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("moves.json")
        load()
        StoreReadJournal.shared.record("moves.json", lastLoad)
    }

    /// A store rooted somewhere else — `CommuteStore(directory:)`'s seam.
    ///
    /// IT DOES NOT RECORD TO THE READ JOURNAL, and that is the journal's own
    /// rule rather than an omission here: a test store writing into the shared
    /// journal would leak into whatever ran next, and `canReconcile` reads that
    /// journal to decide whether rows may be deleted.
    /// A seam that commits, for 412's controls. See `CommuteStore`'s.
    init(directory: URL, database: Sub4Database) {
        self.database = .given(database)
        fileURL = directory.appendingPathComponent("moves.json")
        load()
    }

    init(directory: URL) {
        // SEE `AuthoredDatabase`. A seam does not reach the launch's.
        database = .none
        fileURL = directory.appendingPathComponent("moves.json")
        load()
    }

    // MARK: Reading

    /// The day this session was actually done, or nil if it has not moved.
    ///
    /// NIL IS NOT "THE PLANNED DAY". It is "no opinion", and the caller falls
    /// back to `Session.date` — the same shape `CommuteStore.decision(for:)`
    /// has, and for the same reason: collapsing the two would make an absent
    /// answer indistinguishable from an answer that agrees with the plan.
    func movedTo(_ sessionUid: String) -> String? {
        moves[sessionUid]?.movedTo
    }

    var count: Int { moves.count }

    /// Every move, ordered newest decision first. For a screen, and for the
    /// import — `Dictionary.values` has no order and a report that listed them
    /// differently on each run would be unreadable.
    var all: [PlanMove] {
        moves.values.sorted { $0.decided > $1.decided }
    }

    // MARK: Writing

    /// Records that `sessionUid` was done on `movedTo`.
    ///
    /// THROWS BEFORE IT TOUCHES MEMORY when the day key is malformed. The
    /// alternative — storing it and letting the comparison silently match
    /// nothing — is the shape of defect this project keeps finding: a value
    /// that is wrong in a way that produces an empty result rather than an
    /// error, which reads as "no moves" for ever.
    ///
    /// The rollback below is `CommuteStore.set`'s, unchanged. It matters for
    /// the same reason: the store is what the screen reads, so putting the old
    /// answer back IS the visual revert, and there is no second opinion about
    /// what happened that could drift from this one.
    func set(_ movedTo: String, for sessionUid: String,
             now: Date = Date()) throws {
        guard PlanMove.isDayKey(movedTo) else {
            throw PlanMoveFault.notADayKey(movedTo)
        }
        // DATABASE-FIRST SINCE 412 — §12.157, and the day-key guard stays
        // ahead of the commit: a malformed move is not the database's to
        // refuse.
        let candidate = PlanMove(sessionUid: sessionUid, movedTo: movedTo,
                                 decided: now)
        let committed = try commitToDatabase(candidate)
        let previous = moves[sessionUid]
        moves[sessionUid] = candidate
        try mirror(previous: previous, subject: sessionUid,
                   committed: committed)
    }

    /// Puts the session back on the day the plan asked for.
    ///
    /// See the header: this is a different fact from moving it to its own
    /// planned date, and writing that instead would leave a correction row
    /// overriding nothing.
    func clear(_ sessionUid: String) throws {
        guard let previous = moves[sessionUid] else { return }
        let committed = try deleteFromDatabase(sessionUid)
        moves.removeValue(forKey: sessionUid)
        try mirror(previous: previous, subject: sessionUid,
                   committed: committed)
    }


    // MARK: The authoritative commit — patch 412, §12.157

    /// Which database this instance commits to. See `AuthoredDatabase`: a seam
    /// is inert unless it is handed one on purpose, because the alternative
    /// reaches a process-wide singleton from a store rooted in a temp folder.
    private let database: AuthoredDatabase

    /// Whether the last moved session reached the database — `AuthoredCommit`.
    private(set) var lastCommit: AuthoredCommit = .noneThisLaunch

    /// Step 2, and the only step that may refuse the athlete's edit.
    ///
    /// **NO DATABASE IS NOT A REFUSAL.** The gate may not have opened and the
    /// app must work without it until B9; refusing would mean a shut database
    /// destroys the ability to record an answer at all. The file still takes
    /// it, the next import catches the rows up, and `lastCommit` makes the gap
    /// visible rather than assumed — §12.54.2.
    @discardableResult
    private func commitToDatabase(_ candidate: PlanMove) throws -> Bool {
        switch PlanMoveRepository.upsert(candidate, in: database.live) {
        case .wrote:
            lastCommit = .reached
            return true
        case .noDatabase:
            lastCommit = .missed
            return false
        case .refused(let why):
            throw StoreWriteError(store: "the database", stage: .writing,
                                  reason: why)
        }
    }

    /// `commitToDatabase`'s other half. Same three outcomes, same reasoning.
    @discardableResult
    private func deleteFromDatabase(_ subject: String) throws -> Bool {
        switch PlanMoveRepository.delete(moveFor: subject, in: database.live) {
        case .wrote:
            lastCommit = .reached
            return true
        case .noDatabase:
            lastCommit = .missed
            return false
        case .refused(let why):
            throw StoreWriteError(store: "the database", stage: .writing,
                                  reason: why)
        }
    }

    /// Step 4, and **whether a failure here is fatal depends on step 2.**
    ///
    /// **COMMITTED: memory stands and the failure is recorded.** §12.17 says
    /// the screens must not show what the disk does not hold — and the
    /// authoritative disk is SQLite, which holds it. Throwing would report a
    /// failure for an edit that is already saved.
    ///
    /// **NOT COMMITTED: the file is the only store, so the old rule stands.**
    /// Before B9 a shut database is an ordinary state and the file is
    /// authoritative in it; rolling memory back is what stops the screens
    /// showing an answer nothing holds.
    ///
    /// It calls `save()`, so the announcement is unchanged — 412 claims the
    /// ORDER and nothing about the write-through, which is topic 1C's subject.
    private func mirror(previous: PlanMove?, subject: String,
                        committed: Bool) throws {
        do {
            try save()
        } catch {
            guard committed else {
                if let previous { moves[subject] = previous }
                else { moves.removeValue(forKey: subject) }
                throw error
            }
            StoreWriteJournal.shared.attempt("moves.json") { throw error }
        }
    }

    // MARK: Disk

    /// What the last read of `moves.json` found — §12.20.
    ///
    /// An unreadable file here reads as "no session has been moved", so every
    /// moved session silently returns to its planned day. That is the same
    /// class of quiet loss `commutes.json` has, and it is why this outcome is
    /// recorded rather than swallowed.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        let (value, outcome) = StoreRead.decode([String: PlanMove].self,
                                                at: fileURL)
        if let value { moves = value }
        lastLoad = outcome
    }


    // MARK: - Restore — patch 404, §12.148

    /// **PUTS BACK WHAT THE FILE LOST, FROM THE DATABASE.**
    ///
    /// The third store on `StoreRestore`'s contract, and the last of the
    /// authored FILES. The reasoning and the two subtle steps are there —
    /// §12.43, and `NotesStore.restore` and `WeatherStore.restore` are the same
    /// ten lines over the same helpers. What is this store's is here: which
    /// load it reads, which file it writes and which memory it rolls back.
    ///
    /// **A MOVE IS THE ATHLETE DISAGREEING WITH THE PLAN**, and nothing else
    /// records it: `movedTo` says a session was done on a day the plan did not
    /// ask for, and it changes what Today shows, what counts as adherence and
    /// which session a match may satisfy. `moves.json` is the only copy.
    ///
    /// ADDITIVE, so a move made since the last import survives; the guard is
    /// satisfied rather than bypassed; memory goes back if the write does not
    /// land; and there is NO write-through, because these rows came out of the
    /// database and announcing them back is a loop.
    ///
    /// - Throws: `AuthoredRestoreFault.databaseUnreadable` when the load
    ///   produced nothing, the underlying error when an unreadable file cannot
    ///   be moved, and `StoreWriteError` when the write does not land. In every
    ///   one of those, nothing has been written and memory is as it was.
    @discardableResult
    func restore(from load: PlanMoveLoad, now: Date = Date()) throws
    -> StoreRestore.Receipt {
        guard case .loaded(let stored, _) = load else {
            throw AuthoredRestoreFault.databaseUnreadable(load.line)
        }
        // Nothing to restore is not a repair. Returning early means an empty
        // database cannot move a readable file aside or write over anything —
        // and the counts still tell the two cases apart, because "added 0,
        // already held 0" is only reachable from here.
        guard !stored.isEmpty else { return .nothingStored("moves.json") }

        let setAside = try StoreRestore.setAsideIfUnreadable(
            at: fileURL, trustworthy: lastLoad.isTrustworthy, now: now)
        // THE HALF THE HELPER CANNOT DO. `save()`'s guard reads `lastLoad`, and
        // a store whose file was unreadable stays unwritable for the rest of
        // the session unless the verdict moves with the bytes.
        if setAside != nil { lastLoad = .absent }

        let before = moves
        let m = StoreRestore.merge(stored, into: moves)
        moves = m.merged
        do {
            // `write()`, NOT `save()` — §12.149. These records came out of the
            // database; announcing them back is a loop, and `.authored` would
            // arrive carrying permission to reconcile, so a repair could prune.
            try write()
        } catch {
            // §12.17. The screens read this store, so putting memory back is
            // what stops Today showing a session moved to a day the disk does
            // not agree with. The file moved aside STAYS moved: it is the only
            // copy of bytes nobody could read.
            moves = before
            throw error
        }
        return StoreRestore.Receipt(store: "moves.json", added: m.added,
                                    alreadyHeld: m.alreadyHeld,
                                    setAside: setAside)
    }

    private func save() throws {
        // **THE 371 GUARD, ON THE STORE THAT CANNOT BE FETCHED AGAIN.**
        //
        // §12.116. An unreadable file read as an empty store, and the
        // first write after it saved that empty over thirteen months of
        // the real thing. THROWN rather than returned — the callers above
        // roll memory back and the alert already says what happened, and a
        // silent refusal here would be a quieter version of the defect
        // this file was written to end.
        try write()
        // ANNOUNCED HERE AND NOT IN `write()` — patch 405, §12.149. A restore
        // puts back rows that CAME FROM the database, so announcing them is a
        // loop; and `.authored` sets `reconcile`, so a repair would arrive
        // carrying permission to delete. Every ordinary mutation still goes
        // through `save()` and still announces; the restore calls `write()`.
        DatabaseWriteThrough.shared.noteAuthoredChange("a plan move was saved", family: .moves)
    }

    /// The bytes on disk, and nothing else — patch 405.
    ///
    /// **THE GUARD IS HERE, NOT IN `save()`.** §12.116's protection is about
    /// not overwriting a file nobody could read, which is as true of a restore
    /// as of a mutation. What the restore must skip is the ANNOUNCEMENT, so
    /// the split is announcement-shaped rather than guard-shaped.
    private func write() throws {
        guard lastLoad.isTrustworthy else {
            throw StoreWriteError(store: "moves.json", stage: .refused,
                                  reason: "the store was not read cleanly at launch")
        }
        try StoreWrite.encode(moves, to: fileURL, store: "moves.json")
    }

    /// Drops everything held in memory WITHOUT writing to disk — the
    /// counterpart to `DataLifecycleCoordinator.deleteEverything`. Resetting
    /// would write an empty file and recreate the store that was just deleted;
    /// leaving the memory copy alive would let the next save resurrect it.
    func dropInMemory() {
        moves = [:]
    }
}
