//
//  AuthoredRepository.swift
//  Sub4
//
//  The two authored tables, read back — D6c slice 5b, patch 322, §12.65.
//
//  WHAT THIS CLOSES, AND IT IS A LOOP 321 OPENED
//  ---------------------------------------------
//  `LoadStore` builds the sRPE that scales a session's training load like this:
//
//      srpeByActivity[a.id] = Double(rpe)
//          * Double(DataCorrections.scoringSeconds(a)) / 60
//
//  keyed by the activity `Matcher.day(dayKey)` picked, for the session the plan
//  dated. Four inputs, and after 321 exactly one of them was unverified:
//
//    · **`note.rpe`**            — read out of `NotesStore`, never read back.
//    · `scoringSeconds`          — `officialTiming` and `useElapsedTime` are
//                                  COMPILE-TIME constants keyed by activity id.
//                                  They live in the binary, not the database,
//                                  so the two sides cannot differ. Nothing to
//                                  read and nothing to compare, ever.
//    · the matcher               — proven at 321, §12.64.
//    · the plan                  — held identically on both sides, so it cannot
//                                  differ. Held, not verified — slice 6b.
//
//  This reads `note.rpe` back. After it, slice 3's sRPE is **verified given the
//  plan**, which is a precise claim and deliberately not a larger one.
//
//  AND THE SECOND TABLE IS ONE OF SLICE 5'S OWN HELD INPUTS
//  --------------------------------------------------------
//  `correction` holds the commute decisions — 4 rows, `subjectKind = 'activity'`
//  and `field = 'isCommute'`. §12.64.3 held them because `isPlanEligible` reads
//  `CommuteStore` through `isCommuteRide` and patch 251 decided not to thread a
//  decision dictionary through fourteen call sites.
//
//  Held is still the right call — the same store answering the same ids cannot
//  make the two sides disagree. But held-and-checked is a different sentence
//  from held-and-assumed, and this is what earns the second one. §12.61.1's
//  argument, third application.
//
//  TIMESTAMPS ARE COMPARED AS STRINGS, NOT AS DATES
//  ------------------------------------------------
//  The importer writes `Sub4Import.iso8601(note.created)`. This reads the column
//  and compares it to `Sub4Import.iso8601` of the store's own `Date` — the
//  WRITER'S OWN FORMATTER, called on both sides.
//
//  Parsing the column back into a `Date` and comparing with a tolerance was the
//  other option and is worse in two ways: it needs a second formatter that
//  could disagree with the first (§12.43), and a tolerance would forgive a
//  drift the string comparison catches exactly. 291 needed `sameSecond` for
//  `fetched` because both sides held `Date`s; here one side holds text, and
//  text is the honest thing to compare it as.
//
//  THE CANONICAL ID TRAP, FOR THE THIRD TIME
//  -----------------------------------------
//  `correction.subjectID` is the CANONICAL activity id — the importer resolves
//  it through `activity_alias` before writing. `CommuteDecision.activityId` is
//  Strava's. Reading the column straight through would hand every one of the
//  four decisions an id that matches nothing in `CommuteStore`, and the
//  comparison would report four losses that are a join this reader got wrong.
//
//  Same trap as `gearId` at 289 and the athlete's provenance at 317. The join
//  goes back through `activity_alias`, which is the table the writer used —
//  **not** `activity_source_record`, which is where `ActivityRepository` looks.
//  The two hold the same pairs and only one of them is the writer's.
//
//  MEMBERSHIP IS ASKED OF THE KEYS, AND THAT IS NOT A STYLE CHOICE
//  ---------------------------------------------------------------
//  `dictionary[key] == nil` reads as a nil check and IS a call to
//  `Optional.==`, which requires `Wrapped: Equatable`. Both value types here
//  carry a main-actor-isolated synthesised conformance — `NotesStore.Note`
//  because it is nested in an `@Observable final class`, `CommuteDecision`
//  because it is unannotated under the module default — so neither is reachable
//  from this `nonisolated` enum.
//
//  The first version of this file wrote it that way and drew four warnings.
//  Set arithmetic over the KEYS asks the question the code actually has, and
//  the fix is smaller and faster than the thing it replaced. §12.65.10.
//
//  IT DISTINGUISHES "NOTHING THERE" FROM "COULD NOT LOOK"
//  -----------------------------------------------------
//  A fresh database has no notes and no corrections, and that is an answer
//  rather than a failure — §12.15, the tenth instance.
//

import Foundation
import GRDB

/// What a read of the authored tables produced.
///
/// NOT `Equatable`, for 289a's reason: `NotesStore.Note`'s synthesised
/// conformance is MainActor-isolated in this target, so a `nonisolated` type
/// carrying one cannot use it. Nothing needs to compare two loads.
nonisolated enum AuthoredLoad: Sendable {
    case loaded(notes: [NotesStore.Note], commutes: [CommuteDecision],
                skipped: Int)
    case unavailable
    case failed(String)

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Deliberately nil rather than `[]` when the read failed, so a caller
    /// cannot reach the happy path without deciding what that means.
    var notes: [NotesStore.Note]? {
        if case .loaded(let n, _, _) = self { return n }
        return nil
    }

    var commutes: [CommuteDecision]? {
        if case .loaded(_, let c, _) = self { return c }
        return nil
    }

    /// Rows that are in a table and could not become a record. Today that is
    /// exactly one case: a `correction.value` that is neither "true" nor
    /// "false". Counted rather than dropped, for 289's reason — a reader
    /// quietly returning fewer rows than the table holds is what a comparison
    /// would then report as missing data.
    var skipped: Int {
        if case .loaded(_, _, let s) = self { return s }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(let n, let c, let skipped):
            skipped == 0
                ? "\(n.count) notes, \(c.count) commute decisions."
                : "\(n.count) notes, \(c.count) commute decisions; "
                  + "\(skipped) rows could not be read."
        case .unavailable: "The database is not open."
        case .failed(let why): "The database could not be read — \(why)"
        }
    }
}

// MARK: - The match decisions — patch 355, D7 slice B2

/// What a read of `match_decision` produced.
///
/// ITS OWN TYPE RATHER THAN A FOURTH VALUE ON `AuthoredLoad`. Adding an
/// associated value to `.loaded` would rewrite every construction and every
/// pattern match of it — seven of them in tests alone — for no behaviour, and
/// B2's hydration patch has to touch that enum anyway. One thing at a time.
nonisolated enum MatchDecisionLoad: Sendable {
    case loaded(decisions: [MatchDecision], skipped: Int)
    case unavailable
    case failed(String)

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Nil rather than `[]` when the read failed — `AuthoredLoad`'s rule, and
    /// the same reason: a caller must not reach the happy path without
    /// deciding what a failed read means.
    var decisions: [MatchDecision]? {
        if case .loaded(let d, _) = self { return d }
        return nil
    }

    /// Rows in the table that could not become a record. Counted rather than
    /// dropped — §12.89's rule, and here it has a real case: a decision whose
    /// `activityID` resolves to no alias.
    var skipped: Int {
        if case .loaded(_, let s) = self { return s }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(let d, let skipped):
            skipped == 0
                ? "\(d.count) match decisions."
                : "\(d.count) match decisions; \(skipped) rows could not be read."
        case .unavailable: "The database is not open."
        case .failed(let why): "The database could not be read — \(why)"
        }
    }
}

/// THE READER THE GROUNDWORK SAID DID NOT EXIST.
///
/// `Sub4Import+Authored` has written `match_decision` since 274 and nothing has
/// ever read it back. The verifier counts the rows — `match decisions:
/// expected 0, found 0` — which agrees because both sides are empty, which is
/// the shape 354 spent a patch making visible.
nonisolated enum MatchDecisionRepository {

    static func load(_ db: Sub4Database,
                     accountID: String = Sub4Import.accountID,
                     sourceID: String = Sub4Import.sourceID) -> MatchDecisionLoad {
        do {
            return try db.queue.read { d -> MatchDecisionLoad in
                var out: [MatchDecision] = []
                var skipped = 0
                for row in try Row.fetchAll(d, sql: decisionSQL,
                                            arguments: [sourceID, accountID]) {
                    guard let uid = row["planSessionUID"] as String?,
                          let decided = row["decidedUTC"] as String? else {
                        skipped += 1; continue
                    }
                    // A DECISION WITH NO ACTIVITY IS NOT A BROKEN ROW.
                    // `activityID` is nullable and nil means "explicitly
                    // nothing" — the state the old `[String: String]` in
                    // UserDefaults had to spell `""`. What IS broken is a
                    // non-null `activityID` that resolves through no alias,
                    // and the LEFT JOIN below is what tells the two apart.
                    if row["activityID"] as String? != nil,
                       row["storeID"] as String? == nil {
                        skipped += 1; continue
                    }
                    out.append(MatchDecision(
                        sessionUid: uid,
                        activityId: row["storeID"] as String?,
                        decided: date(decided),
                        // NO COLUMN, AND THAT IS AN APPROVED DIFFERENCE.
                        // `dateIsKnown` distinguishes a date the athlete
                        // decided on from one synthesised when a dateless
                        // record was migrated. The schema never carried it.
                        // `true` rather than `false`, because every row in
                        // this table was written from a record that had a
                        // real date — see `approvedForDecisions`.
                        dateIsKnown: true))
                }
                return .loaded(decisions: out, skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// `AuthoredRepository.date`'s rule, and the same formatter: the writer
    /// uses `.withInternetDateTime`, so this parses with it. An unparseable
    /// string becomes 1970 rather than nil, so it shows as a `decided`
    /// difference instead of as a row that vanished.
    private static func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }

    /// A LEFT JOIN, NOT AN INNER ONE, and `AuthoredRepository.commuteSQL`'s
    /// join is the contrast worth reading. A commute correction ALWAYS names an
    /// activity, so an inner join loses nothing. A match decision may name
    /// none, and an inner join would silently drop every "explicitly nothing"
    /// the athlete recorded — the exact state `MatchDecision.activityId`'s doc
    /// says the nullable column exists to express.
    ///
    /// Through `activity_alias`, for `commuteSQL`'s reason: the writer resolved
    /// the athlete's Strava id to a canonical activity through the alias, so
    /// the reader reverses the alias.
    private static let decisionSQL = """
        SELECT m.planSessionUID AS planSessionUID,
               m.activityID     AS activityID,
               m.decidedUTC     AS decidedUTC,
               al.externalID    AS storeID
          FROM match_decision m
          LEFT JOIN activity_alias al
            ON al.activityID = m.activityID AND al.sourceID = ?
         WHERE m.accountID = ?
         ORDER BY m.planSessionUID
        """
}

// MARK: - The comparison

nonisolated enum AuthoredRoundTrip {

    /// GROUNDWORK §5's LIST — second and third entries, after `version` at 317.
    ///
    /// A DECISION RECORD, NOT A SUPPRESSION LIST. Both entries are columns the
    /// importer leaves NULL **on purpose**, with the reason written into
    /// `Sub4Import+Authored` at the line that does it.
    struct ApprovedDifference: Sendable {
        let field: String
        let reason: String
        let patch: String
    }

    static let approved: [ApprovedDifference] = [
        ApprovedDifference(
            field: "user_note.activityID",
            reason: "left NULL by the importer. Resolving a note to the "
                  + "activity that satisfied its session is a MATCHING "
                  + "decision, and the importer is not the matcher — the same "
                  + "rule that stops it merging the 21 April duplicate ride. "
                  + "The store holds no such link either, so there is nothing "
                  + "to lose and nothing to compare.",
            patch: "322"),
        ApprovedDifference(
            field: "user_note.planVersionID",
            reason: "left NULL by the importer. No plan version exists until "
                  + "the bundled plan is imported, and a note written before "
                  + "that would have nothing to point at. §12.7.1.",
            patch: "322")
    ]

    /// PATCH 355 — the decisions' own list, kept SEPARATE from `approved`.
    ///
    /// `approved` is about `user_note`, it is printed by name in the paste, and
    /// its count is pinned by test. A third entry about a different table would
    /// have moved a number that means "columns the importer leaves NULL in the
    /// notes" — so this is a second list rather than a longer one.
    static let approvedForDecisions: [ApprovedDifference] = [
        ApprovedDifference(
            field: "match_decision.dateIsKnown",
            reason: "no column. The flag says whether `decided` is when the "
                  + "athlete decided or when a dateless legacy record was "
                  + "migrated, and it was a migration concern of patch 272 "
                  + "rather than a property of the decision. Every row in the "
                  + "table was written from a record that carried a real "
                  + "date, so the reader returns true and the comparison does "
                  + "not walk the field.",
            patch: "355")
    ]

    struct Report: Sendable {

        // Denominators. Without them "no differences" and "nothing was
        // examined" read identically — groundwork §2.1 case 2.

        var notesInApp = 0
        var notesInDatabase = 0
        var notesCompared = 0
        /// Fields walked across every compared note. The deep denominator —
        /// five per note, and equal counts can hide changed values.
        var noteFieldsCompared = 0

        var commutesInApp = 0
        var commutesInDatabase = 0
        var commutesCompared = 0
        var commuteFieldsCompared = 0

        var rowsSkipped = 0

        // PATCH 355 — the match decisions. Additive: every counter starts at
        // zero, so a caller that does not compare them reads exactly as it did
        // before, and `lookedAtSomething` is unmoved.
        var decisionsInApp = 0
        var decisionsInDatabase = 0
        var decisionsCompared = 0
        var decisionFieldsCompared = 0
        var decisionRowsSkipped = 0
        /// Set when `compareDecisions` ran at all. Without it a report that was
        /// never given the decisions is indistinguishable from one where both
        /// sides were empty — §12.15, and both print zeros.
        var decisionsWereRead = false

        // Differences, named

        var notesOnlyInApp: [String] = []
        var notesOnlyInDatabase: [String] = []
        /// "s-w03-tue · rpe". Session uids and field names, never the text.
        var noteDifferences: [String] = []

        var commutesOnlyInApp: [String] = []
        var commutesOnlyInDatabase: [String] = []
        var commuteDifferences: [String] = []

        /// Session uids, like the notes'. Never an activity id — §12.7.
        var decisionsOnlyInApp: [String] = []
        var decisionsOnlyInDatabase: [String] = []
        var decisionDifferences: [String] = []

        // Context, printed rather than asserted

        /// Notes carrying an RPE at all, both sides. **This is the row slice 3
        /// depends on**: an RPE is what becomes an sRPE, and a note without one
        /// contributes nothing to the load.
        var appNotesWithRPE = 0
        var databaseNotesWithRPE = 0

        var totalCompared: Int {
            notesCompared + commutesCompared + decisionsCompared
        }

        var unexplained: Int {
            notesOnlyInApp.count + notesOnlyInDatabase.count
            + noteDifferences.count
            + commutesOnlyInApp.count + commutesOnlyInDatabase.count
            + commuteDifferences.count
            + decisionsOnlyInApp.count + decisionsOnlyInDatabase.count
            + decisionDifferences.count
            + rowsSkipped + decisionRowsSkipped
        }

        /// Zero records compared to zero records agrees perfectly. Both halves
        /// are allowed to be empty on their own — a device with no commute
        /// decisions is a real state — but not both at once.
        var lookedAtSomething: Bool { totalCompared > 0 }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else { return "nothing compared" }
            return unexplained == 0
                ? "\(totalCompared) compared · no differences"
                : "\(totalCompared) compared · \(unexplained) differences"
        }

        var rpeLine: String { "\(appNotesWithRPE) vs \(databaseNotesWithRPE)" }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        ///
        /// SAFE TO PASTE, AND THIS ONE NEEDED CHECKING. A note's TEXT is the
        /// athlete writing about their own training and never appears here —
        /// not in a count, not truncated, not at all. What appears is the
        /// session uid, which is the plan's identifier, and the names of the
        /// fields that differ.
        var diagnosticLines: [String] {
            var lines = [
                "Authored read-back: \(totalCompared) compared",
                "  notes in the app: \(notesInApp)",
                "  notes in the database: \(notesInDatabase)",
                "  notes compared: \(notesCompared)",
                "  note fields compared: \(noteFieldsCompared)",
                "  notes only in the app: \(notesOnlyInApp.count)",
                "  notes only in the database: \(notesOnlyInDatabase.count)",
                "  note fields that differ: \(noteDifferences.count)",
                "  notes carrying an RPE: \(rpeLine)",
                "  commute decisions in the app: \(commutesInApp)",
                "  commute decisions in the database: \(commutesInDatabase)",
                "  commute decisions compared: \(commutesCompared)",
                "  commute fields compared: \(commuteFieldsCompared)",
                "  commute decisions only in the app: \(commutesOnlyInApp.count)",
                "  commute decisions only in the database: "
                + "\(commutesOnlyInDatabase.count)",
                "  commute fields that differ: \(commuteDifferences.count)",
                "  match decisions in the app: \(decisionsInApp)",
                "  match decisions in the database: \(decisionsInDatabase)",
                "  match decisions compared: \(decisionsCompared)",
                "  match decision fields compared: \(decisionFieldsCompared)",
                "  match decisions only in the app: "
                + "\(decisionsOnlyInApp.count)",
                "  match decisions only in the database: "
                + "\(decisionsOnlyInDatabase.count)",
                "  match decision fields that differ: "
                + "\(decisionDifferences.count)",
                // §12.15. "0 of 0" is a pass and so is "never asked", and the
                // two must not print the same.
                "  match decisions were read: "
                + "\(decisionsWereRead ? "yes" : "NO — nothing was compared")",
                "  rows the reader could not read: "
                + "\(rowsSkipped) notes and commutes, "
                + "\(decisionRowsSkipped) match decisions",
                "  approved differences, match decisions: "
                + "\(approvedForDecisions.count) "
                + "(\(approvedForDecisions.map(\.field).joined(separator: ", ")))",
                "  approved differences: \(approved.count) "
                + "(\(approved.map(\.field).joined(separator: ", ")))",
                "  unexplained differences: \(unexplained)"]
            for d in noteDifferences.prefix(8) { lines.append("    \(d)") }
            if noteDifferences.count > 8 {
                lines.append("    + \(noteDifferences.count - 8) more")
            }
            for d in commuteDifferences.prefix(6) { lines.append("    \(d)") }
            for d in decisionDifferences.prefix(6) { lines.append("    \(d)") }
            return lines
        }
    }

    /// EVERY STORED FIELD, NAMED — the same argument
    /// `ActivityRoundTrip.differingFields` makes. There is no reflection here
    /// that would not also silently skip something.
    static func compare(storeNotes: [NotesStore.Note],
                        storeCommutes: [CommuteDecision],
                        database: AuthoredLoad) -> Report {

        var r = Report()
        r.notesInApp = storeNotes.count
        r.commutesInApp = storeCommutes.count

        guard case .loaded(let dbNotes, let dbCommutes, let skipped) = database else {
            // Nothing to compare against. The denominators stay zero and
            // `lookedAtSomething` refuses to call that a pass.
            return r
        }
        r.notesInDatabase = dbNotes.count
        r.commutesInDatabase = dbCommutes.count
        r.rowsSkipped = skipped

        // MARK: Notes, by session uid

        let mine = Dictionary(storeNotes.map { ($0.sessionUid, $0) },
                              uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(dbNotes.map { ($0.sessionUid, $0) },
                                uniquingKeysWith: { first, _ in first })

        r.appNotesWithRPE = storeNotes.filter { $0.rpe != nil }.count
        r.databaseNotesWithRPE = dbNotes.filter { $0.rpe != nil }.count

        // KEYS, NOT VALUES — patch 322a, and the reason is worth the line.
        // `theirs[$0] == nil` looks like a nil check and is a call to
        // `Optional.==`, which needs `Wrapped: Equatable`. `NotesStore.Note`'s
        // synthesised conformance is main-actor isolated because the type is
        // nested in an `@Observable final class`, so a `nonisolated` enum
        // cannot reach it. Set arithmetic over the KEYS asks the question this
        // code actually has — which uids are on one side only — and never
        // touches note equality. §12.65.10.s
        let mineKeys = Set(mine.keys)
        let theirKeys = Set(theirs.keys)
        r.notesOnlyInApp = mineKeys.subtracting(theirKeys).sorted()
        r.notesOnlyInDatabase = theirKeys.subtracting(mineKeys).sorted()

        for uid in mineKeys.intersection(theirKeys).sorted() {
            guard let a = mine[uid], let b = theirs[uid] else { continue }
            r.notesCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.noteFieldsCompared += 1
                if !same { r.noteDifferences.append("\(uid) · \(name)") }
            }
            // THE ONE SLICE 3 DEPENDS ON, first.
            check("rpe", a.rpe == b.rpe)
            check("feel", a.feel == b.feel)
            check("text", a.text == b.text)
            // THE WRITER'S OWN FORMATTER, on both sides — see the header.
            check("created", Sub4Import.iso8601(a.created)
                             == Sub4Import.iso8601(b.created))
            check("edited", Sub4Import.iso8601(a.edited)
                            == Sub4Import.iso8601(b.edited))
        }

        // MARK: Commute decisions, by the store's own id

        let myCommutes = Dictionary(storeCommutes.map { ($0.activityId, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let theirCommutes = Dictionary(dbCommutes.map { ($0.activityId, $0) },
                                       uniquingKeysWith: { first, _ in first })

        // A DECISION ABOUT AN IGNORED ACTIVITY IS NOT MISSING. The importer
        // skips those at the door — patch 257's rule, and it counts them as
        // `correctionsIgnored` rather than as seen. Reporting them here would
        // be reporting a refusal as a loss, which is §12.42.2's mistake.
        let myCommuteKeys = Set(myCommutes.keys)
        let theirCommuteKeys = Set(theirCommutes.keys)
        r.commutesOnlyInApp = myCommuteKeys.subtracting(theirCommuteKeys)
            .filter { !DataCorrections.isIgnored(id: $0) }
            .sorted()
        r.commutesOnlyInDatabase = theirCommuteKeys.subtracting(myCommuteKeys).sorted()

        for id in myCommuteKeys.intersection(theirCommuteKeys).sorted() {
            guard let a = myCommutes[id], let b = theirCommutes[id] else { continue }
            r.commutesCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.commuteFieldsCompared += 1
                if !same { r.commuteDifferences.append("\(id) · \(name)") }
            }
            check("isCommute", a.isCommute == b.isCommute)
            check("decided", Sub4Import.iso8601(a.decided)
                             == Sub4Import.iso8601(b.decided))
        }
        return r
    }

    /// PATCH 355 — the match decisions, filled into the same report.
    ///
    /// A SECOND FUNCTION RATHER THAN TWO MORE ARGUMENTS ON `compare`. Adding
    /// them there would rewrite seven existing test call sites and change
    /// nothing about what those tests assert. B2's hydration patch has to
    /// change that signature anyway — that is where the two fold into one.
    ///
    /// `inout`, and deliberately: this is not a second report. A caller that
    /// forgets to call it leaves `decisionsWereRead` false, which the paste
    /// prints in capitals rather than as a row of zeros.
    static func compareDecisions(store: [MatchDecision],
                                 database: MatchDecisionLoad,
                                 into r: inout Report) {
        r.decisionsWereRead = true
        r.decisionsInApp = store.count

        guard case .loaded(let theirs, let skipped) = database else { return }
        r.decisionsInDatabase = theirs.count
        r.decisionRowsSkipped = skipped

        // A DECISION ABOUT AN IGNORED ACTIVITY IS NOT MISSING — the commute
        // block's rule, and the importer applies the same one at the door:
        // `matchDecisionsIgnored` is counted rather than imported. Reporting
        // it here would be reporting a refusal as a loss, §12.42.2.
        let mine = Dictionary(store.map { ($0.sessionUid, $0) },
                              uniquingKeysWith: { first, _ in first })
        let yours = Dictionary(theirs.map { ($0.sessionUid, $0) },
                               uniquingKeysWith: { first, _ in first })
        let mineKeys = Set(mine.keys)
        let yourKeys = Set(yours.keys)

        r.decisionsOnlyInApp = mineKeys.subtracting(yourKeys)
            .filter { uid in
                guard let external = mine[uid]?.activityId else { return true }
                return !DataCorrections.isIgnored(id: external)
            }
            .sorted()
        r.decisionsOnlyInDatabase = yourKeys.subtracting(mineKeys).sorted()

        for uid in mineKeys.intersection(yourKeys).sorted() {
            guard let a = mine[uid], let b = yours[uid] else { continue }
            r.decisionsCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.decisionFieldsCompared += 1
                if !same { r.decisionDifferences.append("\(uid) · \(name)") }
            }
            // NIL AND A VALUE ARE DIFFERENT ANSWERS, and this is the field
            // where that matters: nil is "the athlete said nothing satisfied
            // this session", which is a decision, not an absence.
            check("activityId", a.activityId == b.activityId)
            check("decided", Sub4Import.iso8601(a.decided)
                             == Sub4Import.iso8601(b.decided))
            // `dateIsKnown` is NOT walked — `approvedForDecisions` says why.
        }
    }
}

// MARK: - The reader

nonisolated enum AuthoredRepository {

    static func load(_ db: Sub4Database,
                     accountID: String = Sub4Import.accountID,
                     sourceID: String = Sub4Import.sourceID) -> AuthoredLoad {
        do {
            return try db.queue.read { d -> AuthoredLoad in
                var notes: [NotesStore.Note] = []
                var skipped = 0

                for row in try Row.fetchAll(d, sql: noteSQL, arguments: [accountID]) {
                    guard let uid = row["planSessionUID"] as String?,
                          let created = row["createdUTC"] as String?,
                          let edited = row["editedUTC"] as String? else {
                        skipped += 1; continue
                    }
                    // `feel` is nullable and its raw values are frozen strings.
                    // An unknown one is a row this reader cannot reconstitute,
                    // not a nil feel — mapping it to nil would turn a schema
                    // drift into a silent data change.
                    var feel: NotesStore.Note.Feel?
                    if let raw = row["feel"] as String? {
                        guard let f = NotesStore.Note.Feel(rawValue: raw) else {
                            skipped += 1; continue
                        }
                        feel = f
                    }
                    notes.append(NotesStore.Note(
                        sessionUid: uid,
                        rpe: row["rpe"] as Int?,
                        feel: feel,
                        text: (row["text"] as String?) ?? "",
                        created: date(created),
                        edited: date(edited)))
                }

                var commutes: [CommuteDecision] = []
                for row in try Row.fetchAll(d, sql: commuteSQL,
                                            arguments: [sourceID, accountID]) {
                    guard let storeID = row["storeID"] as String?,
                          let value = row["value"] as String?,
                          let authored = row["authoredUTC"] as String?,
                          let isCommute = bool(value) else {
                        skipped += 1; continue
                    }
                    commutes.append(CommuteDecision(activityId: storeID,
                                                    isCommute: isCommute,
                                                    decided: date(authored)))
                }

                return .loaded(notes: notes, commutes: commutes, skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// `"true"` / `"false"` — what `String(Bool)` produces, which is what the
    /// importer writes. Anything else is a row this reader declines rather than
    /// guesses at, and `skipped` counts it.
    private static func bool(_ v: String) -> Bool? {
        switch v {
        case "true":  true
        case "false": false
        default:      nil
        }
    }

    /// THE WRITER'S FORMATTER, READ BACKWARDS. `Sub4Import.iso8601` uses
    /// `.withInternetDateTime`, so this parses with the same option set rather
    /// than with `JSONDecoder.sub4` or a bare `ISO8601DateFormatter` — contract
    /// item 4's rule applied to a column instead of a file.
    ///
    /// A string that will not parse becomes `Date(timeIntervalSince1970: 0)`
    /// rather than nil, and the comparison catches it: 1970 will not match
    /// anything the store holds, so it shows as a `created` or `decided`
    /// difference rather than as a row that vanished.
    private static func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }

    private static let noteSQL = """
        SELECT planSessionUID, rpe, feel, text, createdUTC, editedUTC
          FROM user_note
         WHERE accountID = ?
         ORDER BY planSessionUID
        """

    /// THROUGH `activity_alias`, NOT `activity_source_record`. Both hold the
    /// canonical-to-Strava pairing and only one of them is the table the writer
    /// used — `Sub4Import.canonicalActivity` resolves through the alias, so
    /// this reverses the alias. See the header.
    private static let commuteSQL = """
        SELECT al.externalID   AS storeID,
               c.value         AS value,
               c.authoredUTC   AS authoredUTC
          FROM correction c
          JOIN activity_alias al
            ON al.activityID = c.subjectID AND al.sourceID = ?
         WHERE c.accountID = ?
           AND c.subjectKind = 'activity'
           AND c.field = 'isCommute'
         ORDER BY al.externalID
        """
}
