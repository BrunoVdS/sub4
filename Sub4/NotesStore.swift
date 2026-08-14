//
//  NotesStore.swift
//  Sub4
//
//  Session notes — the only original data the app holds.
//
//  WHY THIS EXISTS
//  ---------------
//  The plan was written by an AI from a standing start. Nothing in it was
//  calibrated against how the sessions actually feel, and there is no coach to
//  notice that week 9 is too much. The intent is a monthly review: is the block
//  landing where it should, or does it need to get easier or harder?
//
//  That review needs something you can trend. Prose cannot be trended — thirty
//  entries of "felt rough" tell you nothing you can plot against planned load.
//  So a note is two numbers and a paragraph:
//
//    rpe   1–10, perceived effort, the standard Borg CR10 scale
//    feel  easier / as expected / harder, RELATIVE TO WHAT THE PLAN ASKED
//    text  free, for the reason — the outlier explainer
//
//  RPE and feel answer different questions and both are needed. A 9/10 RPE on a
//  session prescribed as a hard interval set is the plan working. The same 9 on
//  an easy 5 km is the plan failing. `feel` carries that comparison explicitly
//  so the review does not have to reconstruct it from the prescription.
//
//  THIS IS NOT A CACHE
//  -------------------
//  Every other store on disk (activities, details, streams, athlete) is a
//  mirror of something Strava can send again. This one is not. If it is lost it
//  is gone. Three consequences, all deliberate:
//
//    1. `resetCache()` does not exist here, and NotesStore must never be wired
//       into the "Rebuild activity cache" button in Settings.
//    2. The schema check MIGRATES. It never clears. The DetailStore pattern of
//       "version changed → delete the file" is right for a cache and would be
//       data loss here.
//    3. Writes are atomic and happen on every mutation, not on a timer. A note
//       typed and then backgrounded is a note that survives.
//
//  KEYING
//  ------
//  By `session.uid` alone, exactly like Matcher.overrides. Verified against
//  plan.json: 260 sessions, 260 distinct uids, none reused across weeks, and no
//  uid maps to more than one date. Dates would be worse — the eight logged
//  prologue sessions have `date: nil`.
//
//  The known exposure, shared with Matcher: if the plan is re-extracted and the
//  uid slugs change, notes orphan. `orphans(in:)` below exists so that is
//  detectable rather than silent, and the export carries the session text so a
//  re-key is always possible from the exported file.
//

import Foundation

@Observable
final class NotesStore {

    static let shared = NotesStore()

    // MARK: The note

    struct Note: Codable, Hashable, Identifiable {

        /// How the session landed against what the plan asked for. Raw values
        /// are stable strings, not ints — a future insertion in the middle of
        /// this enum must not silently rewrite existing notes.
        enum Feel: String, Codable, CaseIterable, Identifiable {
            case easier
            case expected
            case harder

            var id: String { rawValue }

            var label: String {
                switch self {
                case .easier:   "Easier"
                case .expected: "As expected"
                case .harder:   "Harder"
                }
            }

            /// Spelled out, for the export and for anything that reads the
            /// value without the surrounding UI to give it context.
            var longLabel: String {
                switch self {
                case .easier:   "Easier than the target"
                case .expected: "About what the plan asked"
                case .harder:   "Harder than the target"
                }
            }

            var symbol: String {
                switch self {
                case .easier:   "arrow.down.right"
                case .expected: "equal"
                case .harder:   "arrow.up.right"
                }
            }
        }

        var sessionUid: String
        /// Borg CR10. nil means "not answered" — an unanswered RPE is a real
        /// state and must not collapse to 0, which would drag every average
        /// down and read as an effortless session.
        var rpe: Int?
        var feel: Feel?
        var text: String
        var created: Date
        var edited: Date

        var id: String { sessionUid }

        /// A note with nothing in it is not worth storing. Used to decide
        /// whether saving is really a delete.
        var isEmpty: Bool {
            rpe == nil && feel == nil
                && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// One-line summary for a collapsed row.
        var summary: String {
            var parts: [String] = []
            if let rpe { parts.append("RPE \(rpe)") }
            if let feel { parts.append(feel.label) }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                let firstLine = t.split(separator: "\n").first.map(String.init) ?? t
                parts.append(firstLine)
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: State

    private(set) var notes: [String: Note] = [:]

    /// Where the notes this store is serving came from — patch 357, §12.102.
    ///
    /// `.files` until B2 flips. `PlanStore.servedFrom`'s argument applies
    /// unchanged: a store that cannot say where its values came from is a store
    /// whose read-back cannot be checked by anybody who was not there.
    private(set) var servedFrom: StoreSource = .files

    private let fileURL: URL
    private let schemaKey = "notes.schema"
    private let schemaVersion = 1

    // MARK: Init

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("notes.json")
        load()
        // SINGLETON ONLY — patch 273. `init(directory:)` deliberately does not
        // record: a test store writing into the shared journal would leak into
        // whatever ran next, and this journal's whole job is to be believed.
        StoreReadJournal.shared.record("notes.json", lastLoad)
        migrateIfNeeded()
    }

    /// A store rooted somewhere else — patch 264, and NOT ONLY FOR THE TESTS
    /// since 356.
    ///
    /// `ReadBacks.authoredSources` constructs one of these to read `notes.json`
    /// without going through the singleton. B2 hydrates `shared` from the
    /// database, and a read-back comparing the database against a store the
    /// database fed is the database against itself — §12.91.2, and 343 made
    /// the same move on the plan by decoding the bundle.
    ///
    /// IT STILL DOES NOT RECORD TO `StoreReadJournal`, and that was already the
    /// right decision for a different reason. 273 kept it out so a test store
    /// could not leak into the journal; the same line now keeps the READ-BACK's
    /// own read out of a journal whose job is to describe the APP's stores.
    ///
    /// It still does not run `migrateIfNeeded` either. The read-back wants the
    /// file as it is on disk, not the file as a migration would leave it.
    ///
    /// A failable save cannot be trusted until something has watched it fail,
    /// and the only honest way to make a write fail is to give it somewhere it
    /// cannot write to. That needs an instance which is not the singleton, so
    /// here is one. It does not run `migrateIfNeeded` — the migration reads a
    /// shared `UserDefaults` key, and a test instance has no business touching
    /// the real one.
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("notes.json")
        load()
    }

    // MARK: Reading

    func note(for session: Session) -> Note? { notes[session.uid] }
    func note(uid: String) -> Note? { notes[uid] }
    func has(_ session: Session) -> Bool { notes[session.uid] != nil }

    var count: Int { notes.count }

    /// Every note by session uid. Used by the load engine, which needs them all
    /// at once rather than one lookup per day.
    var all: [String: Note] { notes }

    /// Notes whose session is no longer in the plan. Non-empty means the plan
    /// was re-extracted with different uid slugs; the notes are still on disk
    /// and still in the export, they just no longer attach to anything.
    func orphans(in plan: PlanStore) -> [Note] {
        let live = Set(plan.plan.sessions.map(\.uid))
        return notes.values
            .filter { !live.contains($0.sessionUid) }
            .sorted { $0.created < $1.created }
    }

    // MARK: Writing

    /// Saves, or deletes when everything has been cleared. Returns the stored
    /// note, or nil if the call removed it.
    ///
    /// THROWS SINCE PATCH 264, and the memory is rolled back when it does.
    ///
    /// The rollback is the part worth reading. Before this, a failed write left
    /// the new note sitting in `notes` — so the editor closed, the list showed
    /// it, and the next launch read the old file back and it was gone. **A note
    /// that appears and then disappears overnight is worse than one that was
    /// refused**, because the athlete has no reason to write it again.
    ///
    /// So memory follows disk. If the write did not happen, neither did the
    /// edit, and the caller is told.
    @discardableResult
    func save(session: Session, rpe: Int?, feel: Note.Feel?, text: String) throws -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = Note(sessionUid: session.uid, rpe: rpe, feel: feel,
                             text: trimmed,
                             created: notes[session.uid]?.created ?? Date(),
                             edited: Date())

        if candidate.isEmpty {
            // Clearing every field is how you delete a note. Keeping an empty
            // record would put a note marker on a session with nothing behind
            // it, which reads as a bug.
            try remove(session: session)
            return nil
        }

        let previous = notes[session.uid]
        notes[session.uid] = candidate
        do {
            try save()
        } catch {
            if let previous { notes[session.uid] = previous }
            else { notes.removeValue(forKey: session.uid) }
            throw error
        }
        return candidate
    }

    func remove(session: Session) throws {
        guard let previous = notes.removeValue(forKey: session.uid) else { return }
        do {
            try save()
        } catch {
            // A delete that did not reach the disk is not a delete. Putting it
            // back is what stops the note reappearing at the next launch as if
            // the app had changed its mind.
            notes[session.uid] = previous
            throw error
        }
    }

    // MARK: Disk

    /// What the last read of `notes.json` found — patch 273, §12.20.
    ///
    /// The two `try?`s below used to make "there is no file" and "the file is
    /// there and will not decode" produce the identical state: an empty
    /// dictionary, no error, nothing anywhere saying which had happened. On
    /// the store that holds thirteen months of what the athlete thought after
    /// each session.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        let (value, outcome) = StoreRead.decode([String: Note].self, at: fileURL)
        // ONLY ON SUCCESS. A failed read leaves whatever was already in memory
        // rather than replacing it with an empty — which matters on a
        // re-entrant load and costs nothing on the first one.
        if let value { notes = value }
        lastLoad = outcome
    }


    // MARK: Hydration — D7 slice B2, patch 357

    /// Replaces the notes with the stored ones.
    ///
    /// IT DOES NOT WRITE, and `PlanStore.hydrate`'s comment is the reason word
    /// for word: under a slice under test `notes.json` is still the legacy
    /// side's only copy, and saving database-derived values over it would
    /// destroy the independent second opinion the whole stage is checked
    /// against. The apply script refuses a `save()` in here.
    ///
    /// IT IS NEVER CALLED WITH AN EMPTY ARRAY. `DatabaseBootstrap.hydratableAuthored`
    /// returns nil for a family that holds nothing, so a database that has not
    /// caught up cannot blank thirteen months of writing. §12.8.1.
    func hydrate(from stored: [Note]) {
        notes = Dictionary(stored.map { ($0.sessionUid, $0) },
                           uniquingKeysWith: { first, _ in first })
        servedFrom = .database
    }

    /// Drops everything held in memory WITHOUT writing to disk.
    ///
    /// The counterpart to `DataLifecycleCoordinator.deleteEverything`, and the
    /// reason it is not simply `resetCache`: reset saves an empty file, which
    /// after a delete recreates the very store that was just removed. Worse,
    /// leaving the in-memory copy alive means the next save resurrects the
    /// whole history from RAM — a delete that undoes itself the first time the
    /// app touches the store. Nothing here writes.
    func dropInMemory() {
        notes = [:]
    }

    /// TWO `try?`s AND A `return` UNTIL PATCH 264.
    ///
    /// A full disk, a device locked in a way that blocks writing, a container
    /// that moved — all of them landed here and did nothing at all. The only
    /// data in this app that cannot be fetched again was the least protected
    /// thing in it.
    private func save() throws {
        try StoreWrite.encode(notes, to: fileURL, store: "notes.json")
        // AFTER the write, so a throw above means no trigger — there is
        // nothing to catch the database up to. Patch 348, §12.94.
        DatabaseWriteThrough.shared.noteAuthoredChange("a session note was saved")
    }

    /// Migrates forward. Never clears — see the header. A future version 2 adds
    /// its own branch here and rewrites the file in the new shape.
    private func migrateIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: schemaKey)
        guard stored != schemaVersion else { return }
        // 0 → 1 is a fresh install or the first build with notes. Nothing to do
        // but stamp it; there is no earlier shape to convert from.
        UserDefaults.standard.set(schemaVersion, forKey: schemaKey)
    }

    // MARK: Export
    //
    // The monthly review does not happen in the app — it happens by reading the
    // data somewhere it can be sorted and charted. So the export is the point
    // of the feature, not an afterthought, and it carries the PLANNED session
    // alongside the note. A note without its prescription is unreadable: "RPE
    // 8, harder" means nothing until you know it was an easy 5 km.

    struct ExportRow {
        var date: String
        var week: String
        var day: String
        var discipline: String
        var intensity: String
        var title: String
        var planned: String
        var rpe: String
        var feel: String
        var text: String
    }

    /// Every note joined to its session, oldest first. Orphans are included
    /// with blank plan columns rather than dropped.
    func exportRows(plan: PlanStore) -> [ExportRow] {
        // uniquingKeysWith, not uniqueKeysWithValues: the latter TRAPS on a
        // duplicate key. Both are unique in the shipped plan.json (260/260
        // sessions, 37/37 weeks), but plan.json is regenerated by a script, and
        // a crash on the export button is not the way to find out that a slug
        // collided. First wins; the export is a read.
        let byUid = Dictionary(plan.plan.sessions.map { ($0.uid, $0) },
                               uniquingKeysWith: { a, _ in a })
        let weekLabel = Dictionary(plan.plan.weeks.map { ($0.uid, $0.label) },
                                   uniquingKeysWith: { a, _ in a })

        return notes.values.map { n -> ExportRow in
            let s = byUid[n.sessionUid]
            return ExportRow(
                date: s?.date ?? "",
                week: s.flatMap { weekLabel[$0.weekUid] } ?? "",
                day: s?.day ?? "",
                discipline: s?.discipline.rawValue ?? "",
                intensity: s?.intensity?.rawValue ?? "",
                title: s?.title ?? "",
                planned: s?.detail ?? "",
                rpe: n.rpe.map(String.init) ?? "",
                feel: n.feel?.longLabel ?? "",
                text: n.text)
        }
        .sorted {
            // Undated prologue notes sort last rather than first, where an
            // empty string would otherwise put them.
            ($0.date.isEmpty ? "9999" : $0.date, $0.day)
                < ($1.date.isEmpty ? "9999" : $1.date, $1.day)
        }
    }

    /// RFC 4180 CSV. Written rather than pulled from a library because the one
    /// rule that matters — double the quotes, wrap anything containing a comma,
    /// quote or newline — is three lines, and free-text notes will contain all
    /// three characters.
    func csv(plan: PlanStore) -> String {
        let header = ["date", "week", "day", "discipline", "intensity",
                      "title", "planned", "rpe", "feel", "note"]
        // No version banner line here, deliberately. A leading `#` comment is
        // not RFC 4180 — every parser, including a spreadsheet, reads it as a
        // one-column row. The version travels in the FILENAME instead, where it
        // costs the format nothing.
        var out = header.joined(separator: ",") + "\r\n"
        for r in exportRows(plan: plan) {
            let cells = [r.date, r.week, r.day, r.discipline, r.intensity,
                         r.title, r.planned, r.rpe, r.feel, r.text]
            out += cells.map { Self.escape($0) }.joined(separator: ",") + "\r\n"
        }
        return out
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Writes the CSV to a temporary file and returns it, for the share sheet.
    /// Temporary is right: the file is a transport, and the notes themselves
    /// live in notes.json.
    func writeCSV(plan: PlanStore) -> URL? {
        let name = "sub4-notes-\(Self.stamp.string(from: Date()))-p\(AppVersion.patchLabel).csv"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        guard let data = csv(plan: plan).data(using: .utf8) else { return nil }
        do {
            // Temporary, but it holds the same words as the store it came
            // from, so it gets the same protection class — patch 190.
            try data.write(to: url, options: FileProtection.options)
            return url
        } catch {
            return nil
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Coders
//
// ISO 8601 rather than the default double-since-2001, so notes.json can be read
// by anything — including whatever ends up doing the monthly review.

extension JSONEncoder {
    /// NONISOLATED — patch 264a, and it is §12.12.7 a second time.
    ///
    /// This is a computed property that builds a fresh `JSONEncoder` on every
    /// call. Nothing is shared, so there is no race for an actor to prevent —
    /// it was main-actor isolated because it is declared in a file the build
    /// setting isolates, not because anyone decided it should be.
    ///
    /// `StoreWrite` is nonisolated and takes this as a default argument, which
    /// is evaluated at the CALL SITE. Three warnings, all from one default.
    nonisolated static var sub4: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    /// Nonisolated for the same reason as the encoder above: a fresh instance
    /// per call, nothing shared, and the reader that will use it does not run
    /// on the main actor.
    nonisolated static var sub4: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
