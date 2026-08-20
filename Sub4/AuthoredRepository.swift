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

    // MARK: The two verdicts — patch 357, §12.92

    /// DID THE READ SUCCEED. True for a clean read of an empty database.
    ///
    /// `isTrustworthy` above answers the same question and keeps its name
    /// because six call sites ask it; this one exists so the bootstrap can ask
    /// it in the same words as the other four families. §12.92 is the record of
    /// what happens when one word carries both this and the question below.
    var wasReadCleanly: Bool { isTrustworthy }

    /// IS THERE ANYTHING HERE TO HYDRATE A STORE FROM.
    ///
    /// FALSE IS NOT A FAULT AND IS NOT RARE. A device where the athlete has
    /// written no notes and ruled on no rides reads cleanly and holds nothing,
    /// for ever, legitimately. What it is NOT is a reason to hydrate: see
    /// `DatabaseBootstrap.hydratableAuthored`.
    var holdsContent: Bool {
        guard case .loaded(let notes, let commutes, _) = self else { return false }
        return !notes.isEmpty || !commutes.isEmpty
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

    // MARK: The two verdicts — patch 357, §12.92

    /// Did the read succeed. True for a clean read of an empty table.
    var wasReadCleanly: Bool { isTrustworthy }

    /// Is there anything here to hydrate `Matcher` from.
    ///
    /// FALSE ON THIS DEVICE TODAY, and that is the honest state: no match
    /// decision has ever been recorded, so `match_decision` holds nothing and
    /// this family will not hydrate until one is.
    var holdsContent: Bool {
        guard case .loaded(let d, _) = self else { return false }
        return !d.isEmpty
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

    /// ONE IMPLEMENTATION SINCE 364 — see `ColumnDate`. This wrapper stays so
    /// the six call sites above are unmoved; what it no longer holds is a
    /// second copy of the option set.
    private static func date(_ s: String) -> Date { ColumnDate.parse(s) }

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

// MARK: - The moved sessions — patch 364

/// What a read of the `planSession` / `date` corrections produced.
///
/// ITS OWN TYPE, like `MatchDecisionLoad` and for 355's reason: adding a
/// fourth associated value to `AuthoredLoad.loaded` would rewrite every
/// construction and every pattern match of it, in tests and in the bootstrap,
/// for no behaviour.
nonisolated enum PlanMoveLoad: Sendable {
    case loaded(moves: [PlanMove], skipped: Int)
    case unavailable
    case failed(String)

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Did the read succeed. True for a clean read of an empty table — §12.92.
    var wasReadCleanly: Bool { isTrustworthy }

    /// Is there anything here. FALSE ON EVERY DEVICE TODAY, and that is the
    /// honest state: no gesture writes a move until 366.
    var holdsContent: Bool {
        guard case .loaded(let m, _) = self else { return false }
        return !m.isEmpty
    }

    /// Nil rather than `[]` when the read failed — `AuthoredLoad`'s rule.
    var moves: [PlanMove]? {
        if case .loaded(let m, _) = self { return m }
        return nil
    }

    /// Rows in the table that could not become a record. Here that is a
    /// `value` which is not a day key — see `PlanMoveRepository`.
    var skipped: Int {
        if case .loaded(_, let s) = self { return s }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(let m, let skipped):
            skipped == 0
                ? "\(m.count) moved sessions."
                : "\(m.count) moved sessions; \(skipped) rows could not be read."
        case .unavailable: "The database is not open."
        case .failed(let why): "The database could not be read — \(why)"
        }
    }
}

/// **THE WRITER'S FORMATTER, READ BACKWARDS — ONE COPY.**
///
/// `Sub4Import.iso8601` writes with `.withInternetDateTime`, so every reader of
/// a timestamp column parses with the same option set rather than with
/// `JSONDecoder.sub4` or a bare `ISO8601DateFormatter`. Contract item 4's rule,
/// applied to a column instead of a file.
///
/// It was written twice — once in `AuthoredRepository`, once in
/// `MatchDecisionRepository` — and 364 would have made three. Two copies of a
/// rule can disagree; three is a habit. §12.43. Both existing functions now
/// delegate here, so every call site is unmoved and there is exactly one place
/// the option set can be wrong.
///
/// A STRING THAT WILL NOT PARSE BECOMES 1970 RATHER THAN NIL, deliberately.
/// 1970 matches nothing any store holds, so it shows as a `created`, `decided`
/// or `movedTo` difference — a row that is WRONG rather than a row that
/// vanished.
nonisolated enum ColumnDate {
    static func parse(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }
}

/// THE READER FOR THE SECOND CLAIMANT ON `correction`.
///
/// **IT JOINS NOTHING, AND THAT IS THE WHOLE SHAPE OF IT.** `commuteSQL` joins
/// `activity_alias` and `decisionSQL` LEFT JOINs it, both because the column
/// holds the CANONICAL activity id while the store is keyed by Strava's — the
/// canonical-id trap, §12.9, §12.19 and patch 289.
///
/// A move names a plan session. `correction.subjectID` holds
/// `plan_session.uid` verbatim, because `importMoves` writes it verbatim
/// (§12.107.3). A reader that added the join its two neighbours have would
/// return nothing at all, for ever, and the comparison would report every move
/// as lost.
nonisolated enum PlanMoveRepository {

    static func load(_ db: Sub4Database,
                     accountID: String = Sub4Import.accountID) -> PlanMoveLoad {
        do {
            return try db.queue.read { d -> PlanMoveLoad in
                var out: [PlanMove] = []
                var skipped = 0
                for row in try Row.fetchAll(
                    d, sql: moveSQL,
                    arguments: [accountID, Sub4Import.moveSubject,
                                Sub4Import.moveField]) {
                    // `PlanMove.isDayKey` AND NOT A FORMATTER. The store's own
                    // check, from 362 — §12.43, and the reader must decline
                    // exactly what the writer would have refused.
                    //
                    // COUNTED, NOT DROPPED. `skipped` feeds `unexplained`, so a
                    // row this declines shows as a disagreement rather than as
                    // a store quietly holding one fewer move. §12.89.
                    guard let uid = row["sessionUID"] as String?,
                          let movedTo = row["movedTo"] as String?,
                          let authored = row["authoredUTC"] as String?,
                          PlanMove.isDayKey(movedTo) else {
                        skipped += 1; continue
                    }
                    out.append(PlanMove(sessionUid: uid,
                                        movedTo: movedTo,
                                        decided: ColumnDate.parse(authored)))
                }
                return .loaded(moves: out, skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// THE KEY IS BOUND, NOT SPELLED. `Sub4Import.moveSubject` and `moveField`
    /// are the writer's own constants — 361's rule, third reader.
    private static let moveSQL = """
        SELECT subjectID   AS sessionUID,
               value       AS movedTo,
               authoredUTC AS authoredUTC
          FROM correction
         WHERE accountID = ? AND subjectKind = ? AND field = ?
         ORDER BY subjectID
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

        // Patch 364 — the moved sessions, the fourth family out of this one
        // read-back. `moveRowsSkipped` is a `value` that is not a day key.
        var movesInApp = 0
        var movesInDatabase = 0
        var movesCompared = 0
        var moveFieldsCompared = 0
        var moveRowsSkipped = 0
        /// PATCH 356 — WHERE THE APP SIDE OF THIS COMPARISON CAME FROM.
        ///
        /// The default names the singletons because that is what any caller
        /// which has not been updated is still using. `ReadBacks.authored`
        /// overwrites it. A report that still says "the app's stores" after B2
        /// is a comparison of the database against itself, and this line is
        /// what makes that visible instead of invisible. §12.15.
        var appSideCameFrom = "the app's stores"

        /// False when the independent read failed — Application Support
        /// unreachable, or a file present and undecodable. Distinct from
        /// finding nothing: `.absent` is a clean read of an empty store.
        var appSideWasReadCleanly = true

        /// Set when `compareDecisions` ran at all. Without it a report that was
        /// never given the decisions is indistinguishable from one where both
        /// sides were empty — §12.15, and both print zeros.
        var decisionsWereRead = false

        /// The same flag for the moves, and it earns its place twice over:
        /// `moves.json` is empty on every device until 366, so "both sides had
        /// nothing" is the EXPECTED reading and the one a missing call would
        /// imitate perfectly.
        var movesWereRead = false

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

        /// Session uids and FIELD NAMES. **Never the day.** A note's text is
        /// the obvious thing §12.7 keeps out of this paste; `movedTo` is the
        /// quiet one — a date from the athlete's own training history, which is
        /// exactly what §12.7 promises the file does not carry. So a difference
        /// reads `wk-03-sun-long · movedTo` and never says which day.
        var movesOnlyInApp: [String] = []
        var movesOnlyInDatabase: [String] = []
        var moveDifferences: [String] = []

        // Context, printed rather than asserted

        /// Notes carrying an RPE at all, both sides. **This is the row slice 3
        /// depends on**: an RPE is what becomes an sRPE, and a note without one
        /// contributes nothing to the load.
        var appNotesWithRPE = 0
        var databaseNotesWithRPE = 0

        var totalCompared: Int {
            notesCompared + commutesCompared + decisionsCompared + movesCompared
        }

        var unexplained: Int {
            notesOnlyInApp.count + notesOnlyInDatabase.count
            + noteDifferences.count
            + commutesOnlyInApp.count + commutesOnlyInDatabase.count
            + commuteDifferences.count
            + decisionsOnlyInApp.count + decisionsOnlyInDatabase.count
            + decisionDifferences.count
            + movesOnlyInApp.count + movesOnlyInDatabase.count
            + moveDifferences.count
            + rowsSkipped + decisionRowsSkipped + moveRowsSkipped
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

        /// **THE `correction` TABLE'S OWN COUNT — patch 413, §12.158.**
        ///
        /// Nil is "no `COUNT(*)` was taken", which is a real state for every
        /// caller that compares in-memory fixtures, and prints as such rather
        /// than as a zero. `ReadBacks` fills it; the tests leave it alone.
        var correctionRowsInDatabase: Int?

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
                // PATCH 356 — §12.101. UNCONDITIONAL and FIRST, because it is
                // what every count below it means. A read-back that does not
                // say where its own side came from cannot be checked by
                // anybody who was not holding the phone.
                "  the app side came from: \(appSideCameFrom)",
                "  the app side was read cleanly: "
                + "\(appSideWasReadCleanly ? "yes" : "NO")",
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
                "  moved sessions in the app: \(movesInApp)",
                "  moved sessions in the database: \(movesInDatabase)",

                "  moved sessions compared: \(movesCompared)",
                "  moved session fields compared: \(moveFieldsCompared)",
                "  moved sessions only in the app: \(movesOnlyInApp.count)",
                "  moved sessions only in the database: "
                + "\(movesOnlyInDatabase.count)",
                "  moved session fields that differ: \(moveDifferences.count)",
                // §12.15. Zero moves is the reading on every device until a
                // gesture exists, so "both sides had nothing" and "nobody asked"
                // print identically without this line.
                "  moved sessions were read: "
                + "\(movesWereRead ? "yes" : "NO — nothing was compared")",
                // **PATCH 413 — AND IT SITS BESIDE `skipped` ON PURPOSE.**
                // The line below counts rows that came back and would not
                // decode; this one counts rows that never came back at all.
                // On 20 August the first read 0 while the second would have
                // read 1. §12.158.
                CorrectionCensus.line(total: correctionRowsInDatabase,
                                      commutesRead: commutesInDatabase,
                                      movesRead: movesInDatabase),
                "  rows the reader could not read: "
                + "\(rowsSkipped) notes and commutes, "
                + "\(decisionRowsSkipped) match decisions, "
                + "\(moveRowsSkipped) moved sessions",
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
            for d in moveDifferences.prefix(6) { lines.append("    \(d)") }
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

    // MARK: The moved sessions — patch 364

    /// `compareDecisions`' shape, fourth family.
    ///
    /// `inout`, and for the same reason: this is not a second report. A caller
    /// that forgets it leaves `movesWereRead` false, which the paste prints in
    /// capitals rather than as a row of zeros — and on a device where the
    /// honest answer IS zero, that distinction is the only thing separating
    /// "nothing has been moved" from "nobody looked".
    ///
    /// **NO IGNORE FILTER**, unlike the commutes and the match decisions above.
    /// Those two skip records about activities `DataCorrections` excludes,
    /// because the importer refuses them at the door and reporting a refusal as
    /// a loss is §12.42.2. `importMoves` refuses nothing — it has no exclusion
    /// list to consult and no lookup to fail (§12.107.3) — so every move the
    /// store holds is expected in the database, orphans included.
    static func compareMoves(store: [PlanMove],
                             database: PlanMoveLoad,
                             into r: inout Report) {
        r.movesWereRead = true
        r.movesInApp = store.count

        guard case .loaded(let theirs, let skipped) = database else { return }
        r.movesInDatabase = theirs.count
        r.moveRowsSkipped = skipped

        let mine = Dictionary(store.map { ($0.sessionUid, $0) },
                              uniquingKeysWith: { first, _ in first })
        let yours = Dictionary(theirs.map { ($0.sessionUid, $0) },
                               uniquingKeysWith: { first, _ in first })
        let mineKeys = Set(mine.keys)
        let yourKeys = Set(yours.keys)

        r.movesOnlyInApp = mineKeys.subtracting(yourKeys).sorted()
        r.movesOnlyInDatabase = yourKeys.subtracting(mineKeys).sorted()

        for uid in mineKeys.intersection(yourKeys).sorted() {
            guard let a = mine[uid], let b = yours[uid] else { continue }
            r.movesCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.moveFieldsCompared += 1
                if !same { r.moveDifferences.append("\(uid) · \(name)") }
            }
            // THE FIELD NAME, NEVER THE VALUE. `movedTo` is a date out of the
            // athlete's own history and this list is printed into the paste.
            check("movedTo", a.movedTo == b.movedTo)
            // TIMESTAMPS COMPARED AS THE WRITER RENDERS THEM, which is this
            // file's rule for every other family: `Sub4Import.iso8601` on both
            // sides rather than a tolerance that would forgive a real drift.
            check("decided", Sub4Import.iso8601(a.decided)
                             == Sub4Import.iso8601(b.decided))
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
                for row in try Row.fetchAll(
                    d, sql: commuteSQL,
                    arguments: [sourceID, accountID,
                                Sub4Import.commuteSubject,
                                Sub4Import.commuteField]) {
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

    /// ONE IMPLEMENTATION SINCE 364 — see `ColumnDate`, which carries the
    /// reasoning this comment used to. The wrapper stays so every call site in
    /// this type is unmoved.
    private static func date(_ s: String) -> Date { ColumnDate.parse(s) }

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
    ///
    /// **THE KEY IS BOUND SINCE 364.** 361 gave the importer and the verifier
    /// one spelling of `('activity', …, 'isCommute')`; this read-back was the
    /// third reader and still had the literals inline. A reader holding its own
    /// copy of a writer's key does not throw when the copy is wrong — it
    /// returns nothing, and a comparison that finds nothing for ever agrees
    /// with an empty store for ever. §12.43, last place it applied.
    private static let commuteSQL = """
        SELECT al.externalID   AS storeID,
               c.value         AS value,
               c.authoredUTC   AS authoredUTC
          FROM correction c
          JOIN activity_alias al
            ON al.activityID = c.subjectID AND al.sourceID = ?
         WHERE c.accountID = ?
           AND c.subjectKind = ?
           AND c.field = ?
         ORDER BY al.externalID
        """
}

// MARK: - The narrow write — patch 408, ADR-0003 §12.152

/// What a single-record write did.
///
/// **COUNTS AND A REASON, NOT A `Bool`.** §12.15: "the database refused it" and
/// "there was no database" send a caller to different places, and a mutation
/// that reports only success or failure cannot tell the athlete which.
/// **RENAMED FROM `NoteWrite` AT 411.** 408 built it for the notes and 411
/// gives the commutes, the plan moves and the match decisions the same three
/// outcomes — so it is one enum with four callers rather than four enums that
/// agree until one of them stops. §12.43, whose worst instance was five copies
/// of one rule disagreeing for 230 patches.
nonisolated enum AuthoredWrite: Equatable, Sendable {
    /// The row is committed. `inserted` false means it updated one.
    case wrote(inserted: Bool)
    /// The transaction refused. Carries what SQLite said, and NOTHING is
    /// committed — the caller still holds the only copy of the edit.
    case refused(String)
    /// There is no database to write to. Not a failure of this edit: the
    /// launch gate has its own condition and its own screen.
    case noDatabase

    var committed: Bool {
        if case .wrote = self { return true }
        return false
    }

    /// One line, always sayable — §12.54.2.
    var line: String {
        switch self {
        case .wrote(let inserted): inserted ? "written" : "updated"
        case .refused(let why):    "REFUSED — \(why)"
        case .noDatabase:          "the database is not open"
        }
    }
}

/// One note, one transaction — patch 408, §12.152.
///
/// **IT CALLS THE IMPORTER'S MAPPING RATHER THAN COPYING IT.** `importNotes`
/// owns note→row: which columns move, that `planVersionID` and `activityID`
/// stay NULL because resolving a note to an activity is a MATCHING decision
/// (§12.7.1), and that each row gets its own savepoint. A second mapping here
/// would be §12.43's defect in the one place it is most expensive — two ways
/// to write the athlete's own words, disagreeing about which columns matter.
///
/// So the single-note write hands `importNotes` an array of one. The array is
/// the interface; the loop inside it is already per-note.
///
/// **NO WHOLE-WORLD IMPORT.** The plan's 1B requirement in as many words: a
/// note mutation must not re-read and re-write 694 activities and 199,848
/// samples to record one sentence.
nonisolated enum NoteRepository {

    static func upsert(_ note: NotesStore.Note, in db: Sub4Database?,
                       now: Date = Date()) -> AuthoredWrite {
        guard let db else { return .noDatabase }
        do {
            var report = Sub4Import.Report()
            let stamp = Sub4Import.iso8601(now)
            try db.queue.write { d in
                try Sub4Import.importNotes(d, notes: [note], now: stamp,
                                           into: &report)
            }
            // A REFUSAL INSIDE THE SAVEPOINT IS NOT A THROW. `importNotes`
            // catches per note and records a refusal, so a caller that only
            // checked for a thrown error would read "refused" as "written" —
            // which is the failure this whole patch is about.
            if let refusal = report.refusals.first {
                return .refused(refusal.reason)
            }
            return .wrote(inserted: report.notesImported > 0)
        } catch {
            return .refused(String(describing: error))
        }
    }

    /// Removes one note by the session it belongs to.
    ///
    /// **NOT `removeMissing`.** That deletes every key absent from a set and is
    /// the reconciliation pass's shape; pointing it at one note would mean
    /// handing it every OTHER note as the keep-set, so a caller with a stale
    /// list would delete the difference. A targeted delete duplicates no
    /// mapping — there is nothing to map, only a key.
    ///
    /// Deleting a note that is not there is `.wrote(inserted: false)` and not a
    /// refusal: the caller asked for it to be gone and it is gone. §12.15's
    /// distinction applies to reasons, not to work that was already done.
    static func delete(noteFor sessionUid: String, in db: Sub4Database?) -> AuthoredWrite {
        guard let db else { return .noDatabase }
        do {
            try db.queue.write { d in
                try d.execute(sql: """
                    DELETE FROM user_note
                    WHERE accountID = ? AND planSessionUID = ?
                    """, arguments: [Sub4Import.accountID, sessionUid])
            }
            return .wrote(inserted: false)
        } catch {
            return .refused(String(describing: error))
        }
    }
}

// MARK: - The other three authored families — patch 411, §12.156

/// **ONE COMMUTE DECISION, ONE TRANSACTION — patch 411.**
///
/// `NoteRepository`'s shape, and the differences are the whole patch.
///
/// **THE PRUNE LIVES INSIDE THIS IMPORTER, AND THAT IS A TRAP.**
/// `importCorrections` builds its keep-set from the array it is handed and then
/// deletes every commute row outside it. `importNotes` does not — the notes'
/// reconciliation is a separate pass in `reconcileAuthored` — so 408 could hand
/// it one note and nothing else moved. **Handing this one decision with
/// `reconcile: .run` would delete every OTHER commute decision the athlete has
/// ever made**, from a function whose name says "import".
///
/// `.skipped` is not a workaround for that; it is the parameter doing its job.
/// The reason string reaches the health screen, so a single-record write says
/// out loud that it did not reconcile — "a store could not be read" and "the
/// caller did not ask" are both refusals and only one of them is the gate
/// working (`Reconciliation`'s own doc).
///
/// `commutesAreNotPrunedByASingleWrite` is the control, and it is the one to
/// read: it writes one decision into a database holding three and asserts the
/// other two are still there.
nonisolated enum CommuteRepository {

    static func upsert(_ decision: CommuteDecision, in db: Sub4Database?,
                       now: Date = Date()) -> AuthoredWrite {
        guard let db else { return .noDatabase }
        do {
            var report = Sub4Import.Report()
            try db.queue.write { d in
                try Sub4Import.importCorrections(
                    d, decisions: [decision],
                    reconcile: .skipped("one commute decision was saved, so "
                                        + "the store was not reconciled"),
                    now: Sub4Import.iso8601(now), into: &report)
            }
            // §12.152.3 — a refusal inside the savepoint is not a throw.
            if let refusal = report.refusals.first {
                return .refused(refusal.reason)
            }
            return .wrote(inserted: report.correctionsImported > 0)
        } catch {
            return .refused(String(describing: error))
        }
    }

    /// **THE DISCRIMINATOR IS NOT OPTIONAL.** `correction` holds the commute
    /// decisions AND the plan moves — one row each, told apart by
    /// `subjectKind` and `field`, and the census counts them together (3 rows
    /// on 19 August: one commute, two moves). A delete keyed on `subjectID`
    /// alone would be correct only by luck, because the two families draw their
    /// subjects from different namespaces — an activity id and a plan session
    /// uid — and luck is not a constraint.
    ///
    /// The `WHERE` is `pruneCommutes`'s, minus the keep-set. Same four columns,
    /// same constants, so the two cannot drift apart on which rows are a
    /// commute decision.
    ///
    /// **AND THE SUBJECT IS THE CANONICAL ACTIVITY, NOT THE ONE THE CALLER
    /// HOLDS.** §3.1 — Strava ids are never primary keys — so
    /// `importCorrections` resolves `decision.activityId` through
    /// `canonicalActivity` before it writes, and the row is filed under the
    /// internal id. `CommuteStore` keys its dictionary by the EXTERNAL id, so a
    /// delete that passed it straight into the `WHERE` would match nothing and
    /// report success. **The first version of this did exactly that**, and
    /// `theDiscriminatorIsLoadBearing` caught it — a test written about a
    /// different mistake.
    ///
    /// §12.43: the resolution is a rule, so it is called rather than copied.
    ///
    /// An id that resolves to nothing means there is no row to delete —
    /// `canonicalActivity` is how one gets written in the first place. The one
    /// state that leaves behind is a correction whose activity has since been
    /// removed, which `pruneCommutes` is what clears.
    static func delete(commuteFor activityId: String,
                       in db: Sub4Database?) -> AuthoredWrite {
        guard let db else { return .noDatabase }
        do {
            try db.queue.write { d in
                guard let canonical = try Sub4Import.canonicalActivity(
                    d, externalID: activityId) else { return }
                try d.execute(sql: """
                    DELETE FROM correction
                    WHERE accountID = ? AND subjectKind = ? AND field = ?
                      AND subjectID = ?
                    """, arguments: [Sub4Import.accountID,
                                     Sub4Import.commuteSubject,
                                     Sub4Import.commuteField, canonical])
            }
            return .wrote(inserted: false)
        } catch {
            return .refused(String(describing: error))
        }
    }
}

/// One moved session, one transaction — patch 411.
///
/// `importMoves` carries the same inside-the-importer prune as
/// `importCorrections`, for the same reason and with the same guard. It takes
/// no `now:` — a move's timestamp is its own `decided`.
extension PlanMoveRepository {

    static func upsert(_ move: PlanMove, in db: Sub4Database?) -> AuthoredWrite {
        guard let db else { return .noDatabase }
        do {
            var report = Sub4Import.Report()
            try db.queue.write { d in
                try Sub4Import.importMoves(
                    d, moves: [move],
                    reconcile: .skipped("one moved session was saved, so the "
                                        + "store was not reconciled"),
                    into: &report)
            }
            if let refusal = report.refusals.first {
                return .refused(refusal.reason)
            }
            return .wrote(inserted: report.movesImported > 0)
        } catch {
            return .refused(String(describing: error))
        }
    }

    /// `pruneMoves`'s `WHERE`, minus the keep-set. See
    /// `CommuteRepository.delete` for why the discriminator is load-bearing.
    static func delete(moveFor sessionUid: String,
                       in db: Sub4Database?) -> AuthoredWrite {
        guard let db else { return .noDatabase }
        do {
            try db.queue.write { d in
                try d.execute(sql: """
                    DELETE FROM correction
                    WHERE accountID = ? AND subjectKind = ? AND field = ?
                      AND subjectID = ?
                    """, arguments: [Sub4Import.accountID,
                                     Sub4Import.moveSubject,
                                     Sub4Import.moveField, sessionUid])
            }
            return .wrote(inserted: false)
        } catch {
            return .refused(String(describing: error))
        }
    }
}

/// One match decision, one transaction — patch 411.
///
/// **THE EASY ONE, AND IT IS WORTH SAYING WHY.** `match_decision` is its own
/// table and its removal pass lives in `reconcileAuthored` rather than inside
/// `importMatchDecisions`, so handing the importer a single decision moves
/// nothing else — exactly as `importNotes` behaved for 408. No `reconcile:`
/// parameter exists here because there is nothing to skip.
extension MatchDecisionRepository {

    static func upsert(_ decision: MatchDecision, in db: Sub4Database?,
                       now: Date = Date()) -> AuthoredWrite {
        guard let db else { return .noDatabase }
        do {
            var report = Sub4Import.Report()
            try db.queue.write { d in
                try Sub4Import.importMatchDecisions(
                    d, decisions: [decision],
                    now: Sub4Import.iso8601(now), into: &report)
            }
            if let refusal = report.refusals.first {
                return .refused(refusal.reason)
            }
            return .wrote(inserted: report.matchDecisionsImported > 0)
        } catch {
            return .refused(String(describing: error))
        }
    }

    static func delete(decisionFor sessionUid: String,
                       in db: Sub4Database?) -> AuthoredWrite {
        guard let db else { return .noDatabase }
        do {
            try db.queue.write { d in
                try d.execute(sql: """
                    DELETE FROM match_decision
                    WHERE accountID = ? AND planSessionUID = ?
                    """, arguments: [Sub4Import.accountID, sessionUid])
            }
            return .wrote(inserted: false)
        } catch {
            return .refused(String(describing: error))
        }
    }
}

// MARK: - The residual over `correction` — patch 413, §12.158

/// **WHAT THE `correction` TABLE HOLDS THAT NOBODY READ — patch 413.**
///
/// `correction` holds two families: the commute decisions and the plan moves,
/// told apart by `subjectKind` and `field`. The census prints its TOTAL and the
/// authored read-back prints the two families. **Nothing printed the
/// difference**, and on 20 August the difference was 1: the census said four
/// rows while the readers accounted for three, and by the end of the same
/// session both said six. A row that could not be seen became visible and **no
/// line moved in either direction** (§12.157.9).
///
/// **`skipped` DOES NOT COVER THIS, AND THAT IS THE WHOLE REASON THIS EXISTS.**
/// `AuthoredLoad`'s *"rows the reader could not read"* counts rows that came
/// back and would not DECODE. `commuteSQL` inner-joins `activity_alias` on one
/// `sourceID`, so a row whose alias is missing under that source is never
/// returned at all — there is nothing to fail to decode. It read `0` on the
/// morning a row was invisible. §12.15: the diagnostic that existed answered a
/// different question, and answered it correctly.
///
/// **THE RESIDUAL IS TAKEN AGAINST THE READERS, NOT AGAINST THE KINDS.**
/// Counting `subjectKind`/`field` here would have reported zero unaccounted on
/// that morning, because the row HAD a valid kind — it was the join that
/// dropped it. Subtracting what the app's own readers actually returned is what
/// makes a reader's blind spot visible, and it is the only version of this that
/// would have caught the thing it was written for. §6: *an account beats a
/// list; a residual cannot hide a case.*
nonisolated enum CorrectionCensus {

    /// One `COUNT(*)`, the authority. Nil means no database — which is
    /// **not zero**, and the caller's line says so rather than printing a
    /// total nobody counted (§12.54.2, the shape 410 fixed one table over).
    static func rows(in db: Sub4Database?) -> Int? {
        guard let db else { return nil }
        return try? db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM correction WHERE accountID = ?
                """, arguments: [Sub4Import.accountID])
        } ?? nil
    }

    /// UNCONDITIONAL, and it names both families and the remainder — 266c's
    /// rule. A residual that only printed when non-zero could not be told from
    /// one nobody wired in, which is the defect this patch closes.
    static func line(total: Int?, commutesRead: Int, movesRead: Int) -> String {
        guard let total else {
            return "  correction rows: not counted — the database is not open"
        }
        let unaccounted = total - commutesRead - movesRead
        var s = "  correction rows: \(total) — \(commutesRead) read as commute "
              + "decisions, \(movesRead) as moved sessions"
        // NEGATIVE IS ITS OWN ANSWER. It cannot happen from these three
        // queries against one table, so if it ever prints, the assumption that
        // `correction` holds exactly these two families has broken — which is
        // worth a sentence rather than a `max(0,)` that hides it.
        if unaccounted > 0 {
            s += ", \(unaccounted) NOT READ BY EITHER"
        } else if unaccounted < 0 {
            s += ", and the readers returned \(-unaccounted) MORE than the table holds"
        } else {
            s += ", 0 unaccounted"
        }
        return s
    }
}

