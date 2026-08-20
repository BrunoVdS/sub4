//
//  CommuteStore.swift
//  Sub4
//
//  Which rides are commutes, decided by the athlete — patch 251.
//
//  WHY THIS EXISTS RATHER THAN A STRAVA FIELD
//  ------------------------------------------
//  Patch 250 read Strava's own `commute` boolean and was right for one day.
//  ADR-0002 retires Strava; Phase 4A makes Apple Health canonical. A
//  classification whose source of truth is a field in a service this app is
//  leaving would have to be rebuilt at the moment the service goes away, and
//  the decisions already made would have nowhere to live in the meantime. So
//  the flag is read no longer, and the answer is held here.
//
//  ONE SOURCE OF TRUTH, AND IT IS THIS FILE. Nothing consults Strava about a
//  commute any more. `StravaActivityDTO` no longer decodes the field and
//  `Activity` no longer carries it.
//
//  WHY NOT A COLUMN ON `Activity`
//  ------------------------------
//  Because it would be destroyed every two hours. Since patch 249 the sync
//  re-reads all 661 activities from the cutoff on every run and `ingest`
//  replaces each row wholesale — `byID[a.id] = a`. Anything the athlete wrote
//  onto an `Activity` would survive until the next launch. Authored data has to
//  live beside the fetched data, never inside it, and that is true of every
//  store in this app: notes, corrections, match overrides.
//
//  THREE STATES, AND ALL THREE ARE USED
//  ------------------------------------
//  `true`  — you said this is a commute, whatever its distance.
//  `false` — you said this is not, whatever its distance.
//  absent  — you have not said, so `Activity.commuteByDistance` decides.
//
//  The default is what the app has always used: a bike ride under
//  `MatchRules.minRideKm` is a commute. On thirteen months of real history that
//  rule is right almost every time — but "almost" is doing work it should not,
//  and on 16 July 2026 a 9,985.9 m ride was a commute by fourteen metres. The
//  toggle is how that gets settled by the person who was on the bike.
//
//  A DECISION CARRIES ITS DATE. Not decoration: the `correction` table in
//  ADR-0003 §8 wants provenance for exactly this kind of row, and a decision
//  with no timestamp cannot be reconciled against a later one. ISO-8601, like
//  notes and proposals — authored data uses `JSONEncoder.sub4` throughout, and
//  `LegacyInput.commutes` in the fixture corpus states it.
//

import Foundation
import Observation

/// One ride, and what the athlete said about it.
struct CommuteDecision: Codable, Hashable, Identifiable {
    /// The activity's id — a Strava id today, remapped through `activity_alias`
    /// when the database becomes authoritative. The same remapping problem the
    /// match overrides already have, and recorded as such in the inventory.
    var activityId: String
    var isCommute: Bool
    var decided: Date

    var id: String { activityId }
}

@Observable
final class CommuteStore {

    static let shared = CommuteStore()

    private(set) var decisions: [String: CommuteDecision] = [:]

    /// Where the decisions this store is serving came from — patch 357.
    private(set) var servedFrom: StoreSource = .files

    private let fileURL: URL

    private init() {
        database = .theLaunchs
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("commutes.json")
        load()
        StoreReadJournal.shared.record("commutes.json", lastLoad)
    }

    /// A store rooted somewhere else — patch 265, exactly as
    /// `NotesStore(directory:)`, and NOT ONLY FOR THE TESTS since 356.
    ///
    /// A failable save nobody has watched fail is `try?` with more words around
    /// it — that is why it was written. `ReadBacks.authoredSources` is why it
    /// is now also production: B2 hydrates `shared` from the database, and the
    /// read-back needs `commutes.json` itself. §12.91.2.
    /// A seam that commits, for 412's controls. A second initialiser rather
    /// than a default argument — §12.95.4, whose instance cost 350a four
    /// patches of a green suite.
    init(directory: URL, database: Sub4Database) {
        self.database = .given(database)
        fileURL = directory.appendingPathComponent("commutes.json")
        load()
    }

    init(directory: URL) {
        // SEE `AuthoredDatabase`. A seam does not reach the launch's.
        database = .none
        fileURL = directory.appendingPathComponent("commutes.json")
        load()
    }

    // MARK: Hydration — D7 slice B2, patch 357

    /// Replaces the decisions with the stored ones. Does not write, for
    /// `NotesStore.hydrate`'s reason.
    func hydrate(from stored: [CommuteDecision]) {
        decisions = Dictionary(stored.map { ($0.activityId, $0) },
                               uniquingKeysWith: { first, _ in first })
        servedFrom = .database
    }

    // MARK: Reading

    /// What the athlete said, or nil if he has not said.
    ///
    /// Nil is not "no". A ride nobody has ruled on falls through to the
    /// distance rule, and collapsing that into `false` would silently promote
    /// every unreviewed commute into a training ride.
    func decision(for activityId: String) -> Bool? {
        decisions[activityId]?.isCommute
    }

    var count: Int { decisions.count }

    /// The decisions that disagree with what the distance rule would have said.
    /// The interesting ones — and the only evidence that the toggle earns its
    /// place rather than restating the default.
    func overrides(in activities: [Activity]) -> [CommuteDecision] {
        activities.compactMap { a in
            guard let d = decisions[a.id], d.isCommute != a.commuteByDistance else { return nil }
            return d
        }
        .sorted { $0.decided > $1.decided }
    }

    // MARK: Writing

    /// THROWS SINCE PATCH 265, and the memory is rolled back when it does.
    ///
    /// The rollback is also the visual revert, and that is not a coincidence
    /// worth relying on twice: `Activity.isCommuteRide` reads this store, so
    /// putting the old answer back IS the toggle snapping back. Nothing in the
    /// view has to undo anything, and there is no second opinion about what
    /// happened that could drift from this one.
    /// **DATABASE-FIRST SINCE 412, §12.157.** This was memory, then
    /// `commutes.json`, then a fire-and-forget whole-world import — so a
    /// termination before that import committed left SQLite older than the
    /// file, and since B2 the launch hydrates from SQLite. The athlete's answer
    /// reverted at the next launch, which for a commute decision means a ride
    /// going back to the distance rule.
    func set(_ isCommute: Bool, for activityId: String, now: Date = Date()) throws {
        let candidate = CommuteDecision(activityId: activityId,
                                        isCommute: isCommute, decided: now)
        let committed = try commitToDatabase(candidate)       // 2. the authority
        let previous = decisions[activityId]                  // 3. publish
        decisions[activityId] = candidate
        try mirror(previous: previous, subject: activityId,   // 4. the mirror
                   committed: committed)
    }

    /// Removes the decision, returning the ride to the distance rule. Distinct
    /// from setting `false`: "I have no opinion" and "this is not a commute"
    /// are different answers and the second one survives a change to the
    /// threshold.
    /// Inverted the same way, and it is the worse direction: the old order
    /// removed the answer from memory and the file and left the row for the
    /// next import, so a termination in that window brought the decision back
    /// at the next launch. Putting it back on a failed mirror still matters —
    /// forgetting an answer returns the ride to the distance rule, so a clear
    /// that silently did not happen leaves the athlete believing the threshold
    /// governs a ride it does not.
    func clear(_ activityId: String) throws {
        guard let previous = decisions[activityId] else { return }
        let committed = try deleteFromDatabase(activityId)
        decisions.removeValue(forKey: activityId)
        try mirror(previous: previous, subject: activityId,
                   committed: committed)
    }


    // MARK: The authoritative commit — patch 412, §12.157

    /// Which database this instance commits to. See `AuthoredDatabase`: a seam
    /// is inert unless it is handed one on purpose, because the alternative
    /// reaches a process-wide singleton from a store rooted in a temp folder.
    private let database: AuthoredDatabase

    /// Whether the last commute decision reached the database — `AuthoredCommit`.
    private(set) var lastCommit: AuthoredCommit = .noneThisLaunch

    /// Step 2, and the only step that may refuse the athlete's edit.
    ///
    /// **NO DATABASE IS NOT A REFUSAL.** The gate may not have opened and the
    /// app must work without it until B9; refusing would mean a shut database
    /// destroys the ability to record an answer at all. The file still takes
    /// it, the next import catches the rows up, and `lastCommit` makes the gap
    /// visible rather than assumed — §12.54.2.
    @discardableResult
    private func commitToDatabase(_ candidate: CommuteDecision) throws -> Bool {
        switch CommuteRepository.upsert(candidate, in: database.live) {
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
        switch CommuteRepository.delete(commuteFor: subject, in: database.live) {
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
    private func mirror(previous: CommuteDecision?, subject: String,
                        committed: Bool) throws {
        do {
            try save()
        } catch {
            guard committed else {
                if let previous { decisions[subject] = previous }
                else { decisions.removeValue(forKey: subject) }
                throw error
            }
            StoreWriteJournal.shared.attempt("commutes.json") { throw error }
        }
    }

    // MARK: Disk

    /// What the last read of `commutes.json` found — patch 273, §12.20.
    ///
    /// An unreadable file here reads as "you have not ruled on any ride", so
    /// every decision silently falls back to `commuteByDistance` — the very
    /// rule patch 251 exists to override.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        let (value, outcome) = StoreRead.decode([String: CommuteDecision].self,
                                                at: fileURL)
        if let value { decisions = value }
        lastLoad = outcome
    }


    // MARK: - Restore — patch 400, §12.144

    /// **PUTS BACK WHAT THE FILE LOST, FROM THE DATABASE.**
    ///
    /// The contract, its reasoning and its two subtle steps are in
    /// `StoreRestore` — §12.43, and `WeatherStore.restore` is the same ten
    /// lines over the same helpers. What is genuinely this store's is here:
    /// which load it reads, which file it writes and which memory it rolls
    /// back.
    ///
    /// ADDITIVE, so a commute decision written since the last import survives; the guard is
    /// satisfied rather than bypassed; memory goes back if the write does not
    /// land; and there is NO write-through, because these records came out of
    /// the database and announcing them back is a loop.
    ///
    /// - Throws: `AuthoredRestoreFault.databaseUnreadable` when the load
    ///   produced nothing, the underlying error when an unreadable file cannot
    ///   be moved, and `StoreWriteError` when the write does not land. In every
    ///   one of those, nothing has been written and memory is as it was.
    @discardableResult
    func restore(from load: AuthoredLoad, now: Date = Date()) throws
    -> StoreRestore.Receipt {
        // BOUND ONCE, AS WHAT IT IS. The first draft bound both halves and
        // used one — a templated `notes` this store has no business touching,
        // and `eachStoreTakesItsOwnHalf` is the test that says so. The compiler
        // said it too; neither `test.sh` nor `preflight.sh` reads warnings.
        guard case .loaded(_, let stored, _) = load else {
            throw AuthoredRestoreFault.databaseUnreadable(load.line)
        }
        // Nothing to restore is not a repair. Returning early means an empty
        // database cannot move a readable file aside or write over anything —
        // and the counts still tell the two cases apart, because "added 0,
        // already held 0" is only reachable from here.
        guard !stored.isEmpty else { return .nothingStored("commutes.json") }

        let setAside = try StoreRestore.setAsideIfUnreadable(
            at: fileURL, trustworthy: lastLoad.isTrustworthy, now: now)
        // THE HALF THE HELPER CANNOT DO. `save()`'s guard reads `lastLoad`, and
        // a store whose file was unreadable stays unwritable for the rest of
        // the session unless the verdict moves with the bytes. §12.371.
        if setAside != nil { lastLoad = .absent }

        let before = decisions
        let m = StoreRestore.merge(stored, into: decisions)
        decisions = m.merged
        do {
            // `write()`, NOT `save()` — §12.149. These records came out of the
            // database; announcing them back is a loop, and `.authored` would
            // arrive carrying permission to reconcile, so a repair could prune.
            try write()
        } catch {
            // §12.17. The screens read this store, so putting memory back is
            // what stops them showing records that are not on the disk. The
            // file moved aside STAYS moved: it is the only copy of bytes nobody
            // could read, and moving it back is a second operation that can
            // fail the same way as the first.
            decisions = before
            throw error
        }
        return StoreRestore.Receipt(store: "commutes.json", added: m.added,
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
        DatabaseWriteThrough.shared.noteAuthoredChange("a commute decision was saved")
    }

    /// The bytes on disk, and nothing else — patch 405.
    ///
    /// **THE GUARD IS HERE, NOT IN `save()`.** §12.116's protection is about
    /// not overwriting a file nobody could read, which is as true of a restore
    /// as of a mutation. What the restore must skip is the ANNOUNCEMENT, so
    /// the split is announcement-shaped rather than guard-shaped.
    private func write() throws {
        guard lastLoad.isTrustworthy else {
            throw StoreWriteError(store: "commutes.json", stage: .refused,
                                  reason: "the store was not read cleanly at launch")
        }
        try StoreWrite.encode(decisions, to: fileURL, store: "commutes.json")
    }

    /// Drops everything held in memory WITHOUT writing to disk — the
    /// counterpart to `DataLifecycleCoordinator.deleteEverything`. Same reason
    /// as `NotesStore.dropInMemory`: resetting would write an empty file and
    /// recreate the store that was just deleted, and leaving the memory copy
    /// alive would let the next save resurrect it.
    func dropInMemory() {
        decisions = [:]
    }
}
