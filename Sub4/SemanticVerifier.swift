//
//  SemanticVerifier.swift
//  Sub4
//
//  Does the database say the same thing as the stores — step 3.5, patch 263,
//  ADR-0003 §12.16.
//
//  THE SENTENCE THIS FILE EXISTS FOR
//  --------------------------------
//  `migration_run` has had a `verified` state since patch 255 and nothing has
//  ever been able to reach it. Every successful import stops at `pending`,
//  which the ledger's own header calls "the honest answer: the verifier is the
//  next patch". This is that patch, eight patches later.
//
//  D7 switches the app's reads to the database. That decision cannot be made
//  from an import report, because an import report says what the importer
//  believes it did. This says whether it is true.
//
//  IT DOES NOT STOP AT THE FIRST FAILURE
//  -------------------------------------
//  A verifier that quits on the first mismatch tells you one thing when you
//  need all of them, and turns "what is wrong with this migration" into a
//  sequence of runs. Every check runs, every check reports, and the report
//  carries both figures — not a tick.
//
//  THE EXPECTATIONS COME FROM THE STORES, NEVER FROM THE EXCLUSION RULES
//  --------------------------------------------------------------------
//  A weather reading, a trace and a detail are only expected in the database
//  if their activity is IN THE STORE. That is the whole rule, and it is
//  deliberately not "…unless `DataCorrections` excludes it".
//
//  The difference matters. Excluded activities never reach `ActivityStore` —
//  `ExcludedRecordingTests` asserts that — so deriving the expectation from
//  the store's own contents gets the exclusions right for free, WITHOUT this
//  file knowing the exclusion policy exists. A verifier that imported the
//  policy would agree with the importer about anything the policy got wrong,
//  which is the one class of error a verifier is for.
//
//  WHAT IS DELIBERATELY NOT HERE: CTL
//  ----------------------------------
//  The plan names "CTL on a chosen day" among the representative domain
//  outputs, and it is not in this patch. `PMC.build` takes `[DailyLoad]`, and
//  the code that produces those reads `Activity` values. Comparing CTL both
//  ways would mean writing a SECOND `DailyLoad` builder against SQL — and a
//  disagreement between two builders is ambiguous in exactly the wrong way:
//  nobody could tell whether the data diverged or the second builder is wrong.
//
//  The right place for it is D6 shadow parity, where the app grows a
//  database-backed activity reader and the SAME `PMC` runs over both sides.
//  Then a divergence means the data diverged, which is the question being
//  asked. Recorded here rather than quietly skipped.
//

import Foundation
import GRDB

// MARK: - One comparison

nonisolated struct VerificationCheck: Equatable, Identifiable {
    /// What was compared, in the terms the athlete would use.
    let name: String
    /// The table it lives in. THE ACCEPTANCE CRITERION: a failure names this,
    /// because "the verifier failed" sends somebody looking through fifty-one
    /// tables.
    let table: String
    let expected: String
    let found: String
    let passed: Bool
    /// What to look at, when a count is not enough. May carry the athlete's
    /// own identifiers, so it goes on the screen and never in the paste.
    let detail: String?

    var id: String { name }

    static func compare(_ name: String, table: String,
                        expected: Int, found: Int,
                        detail: String? = nil) -> VerificationCheck {
        .init(name: name, table: table,
              expected: "\(expected)", found: "\(found)",
              passed: expected == found, detail: detail)
    }
}

// MARK: - The whole run

nonisolated struct VerificationReport: Equatable {
    let checks: [VerificationCheck]
    let seconds: Double

    /// Passing means every comparison passed. There is no partial credit and
    /// no "mostly" — `verified` is a state D7 acts on.
    var passed: Bool {
        let failures = checks.filter { !$0.passed }
        return failures.isEmpty
    }

    var failures: [VerificationCheck] { checks.filter { !$0.passed } }

    // MARK: Whether any of it is evidence — patch 354, ADR-0003 §12.99

    /// Comparisons whose expectation came from something the database does not
    /// feed. THESE ARE THE ONES THAT CAN FAIL.
    var independentChecks: [VerificationCheck] {
        checks.filter { HydratedStores.entry(for: $0.name) == nil }
    }

    /// Comparisons reading a store this build hydrates FROM the database.
    ///
    /// They still run and still print. A self-referential check that DISAGREED
    /// would mean hydration itself is broken, which is worth knowing — it is
    /// only as evidence that the migration carried something that they are
    /// worth nothing.
    var selfReferentialChecks: [VerificationCheck] {
        checks.filter { HydratedStores.entry(for: $0.name) != nil }
    }

    /// Declared hydrated, and naming no comparison in this report.
    ///
    /// §12.15 IN ITS SHARPEST FORM. `HydratedStores` joins to the checks BY
    /// NAME. A rename on one side and not the other would silently move a
    /// self-referential check back into the evidence column, and every number
    /// below would read better than the truth. An entry that matches nothing is
    /// the symptom that produces, so it is surfaced rather than ignored.
    ///
    /// **AND IT POINTS ONE WAY ONLY — PATCH 385, §12.129.** This reports an
    /// ENTRY naming no check. Nothing reports a CHECK naming no entry, and that
    /// is the direction the damage runs: a comparison whose expectation comes
    /// from a hydrated store and which nobody declared counts as evidence, in
    /// silence, and reads on the device exactly like a comparison that could
    /// have failed. `activity fields` did that for three patches.
    ///
    /// It cannot be closed from this end. Deciding whether a check is
    /// self-referential means knowing WHICH STORE FIELD its expectation came
    /// from, and this type is handed arrays. **386 moves that answer to each
    /// check's own construction site**, where the compiler can require it, and
    /// this property and the list behind it both stop existing.
    var unmatchedHydratedEntries: [HydratedStores.Entry] {
        let names = Set(checks.map(\.name))
        return HydratedStores.all.filter { !names.contains($0.check) }
    }

    /// WHAT `verified` MAY BE GRANTED ON — and it is no longer `passed`.
    ///
    /// Three conditions, each with a distinct failure: every comparison agreed,
    /// at least one of them was CAPABLE of disagreeing, and the list that
    /// decides which is which still lines up with the checks.
    ///
    /// The middle one is the whole patch. At B9 every store is fed by the
    /// database, `independentChecks` is empty, and twenty green rows mean
    /// nothing at all. This is the line that refuses to write `verified` on
    /// that — which forces the question then, rather than after activation.
    var isTrustworthyEvidence: Bool {
        passed && !independentChecks.isEmpty && unmatchedHydratedEntries.isEmpty
    }

    /// Non-nil when the report PASSED and still may not be believed. Nil when
    /// it failed — that is `failures`' story and this one would only blur it.
    var withheldReason: String? {
        guard passed else { return nil }
        if !unmatchedHydratedEntries.isEmpty {
            let n = unmatchedHydratedEntries.count
            return "the hydrated-store list names \(n) comparison"
                 + (n == 1 ? "" : "s") + " this report does not contain"
        }
        if independentChecks.isEmpty {
            return "every comparison reads a store the database feeds, so none "
                 + "of them could have disagreed"
        }
        return nil
    }

    /// One line for the ledger. Counts only — this is stored in the database
    /// and read back into the redacted paste.
    var ledgerNote: String {
        guard passed else {
            return "\(failures.count) of \(checks.count) comparisons disagreed"
        }
        // PATCH 354. THE DURABLE RECORD CARRIES HOW MUCH OF IT WAS EVIDENCE.
        // "20 comparisons, all agreed" is what a row from B1 onward says, and
        // it is true and misleading in the same breath. Rows written before
        // this patch keep their own note; that is what a ledger is.
        return "\(checks.count) comparisons, all agreed · "
             + "\(independentChecks.count) independent"
    }

    /// COUNTS AND TABLE NAMES ONLY, like §12.9e's survey and for the same
    /// reason: `detail` can carry an activity id or a session uid, and §12.7
    /// promises the paste carries neither.
    var diagnosticLines: [String] {
        var out = [String(format: "Verification: %.2f s — %@", seconds,
                          passed ? "agreed" : "DISAGREED")]
        // PATCH 354 — §12.99. UNCONDITIONAL, and ABOVE the checks, because it
        // is what the numbers below it mean. A reader who sees twenty ticks
        // and no independent count cannot tell a verified migration from a
        // database agreeing with itself twenty times.
        out.append("  comparisons: \(checks.count) — "
                 + "\(independentChecks.count) independent, "
                 + "\(selfReferentialChecks.count) reading a store the "
                 + "database feeds")
        out.append("  may be believed: \(isTrustworthyEvidence ? "yes" : "no")"
                 + (withheldReason.map { " — \($0)" } ?? ""))
        for e in unmatchedHydratedEntries {
            out.append("  DECLARED HYDRATED AND NOT COMPARED: \(e.check) "
                     + "(\(e.note))")
        }
        for c in checks {
            let mark = HydratedStores.entry(for: c.name)
                .map { " · self-referential: \($0.note)" } ?? ""
            out.append("  \(c.passed ? "ok" : "NO") \(c.name) [\(c.table)]: "
                       + "expected \(c.expected), found \(c.found)\(mark)")
        }
        return out
    }
}

// MARK: - Which corrections have a comparison

/// The `(subjectKind, field)` pairs some store in this app is the writer of.
///
/// **PATCH 361, AND IT WAS LATENT FROM 280.** The `corrections` comparison
/// expected the commute decisions and counted `SELECT COUNT(*) FROM
/// correction`. Those agreed for one reason: the commute decisions were the
/// only rows the table had. The schema never believed that —
/// `subjectKind IN ('activity', 'planSession')` is in the CREATE TABLE, and a
/// `field` column beside it — so a second claimant was designed in from the
/// start. The first plan-session correction would have failed a comparison
/// named `corrections` with `expected 1, found 2`, which sends the reader to
/// look at the commute decisions.
///
/// **THE LIST IS THE POINT, NOT THE `WHERE` CLAUSE.** Qualifying the commute
/// comparison alone stops the false failure and buys a silence in its place:
/// every row of every future family counted by nothing at all. §12.54.2 — a
/// row that vanishes at zero cannot be told from a row nobody wired in. So the
/// same list drives `unclaimed corrections`, which counts what this list does
/// not name and expects none of it.
///
/// The consequence is deliberate. The patch that teaches a store to write a
/// new family must add a line here in the same diff, or the verifier fails on
/// the first row with a sentence naming `subjectKind · field`. That is
/// `AppStores.fieldCount` pinned at 17, aimed at a table instead of a struct.
nonisolated enum ComparedCorrections {

    nonisolated struct Family: Equatable, Sendable {
        /// The `correction.subjectKind` value.
        let subjectKind: String
        /// The `correction.field` value.
        let field: String
        /// The comparison that counts it, BY NAME.
        ///
        /// `everyFamilyNamesARealComparison` joins on this exactly the way
        /// `unmatchedHydratedEntries` joins on `HydratedStores.Entry.check`,
        /// and for the same reason: a rename finished on one side only leaves
        /// a family whose comparison does not exist, and `unclaimed
        /// corrections` would then count rows the report claims to compare.
        let check: String
    }

    /// **THE PAIR COMES FROM THE WRITER**, not from a literal retyped here.
    /// §12.43. A verifier holding its own copy of the importer's key does not
    /// throw when the copy is wrong — it counts zero, and a comparison that
    /// counts zero forever agrees with an empty store forever.
    nonisolated static let commute = Family(subjectKind: Sub4Import.commuteSubject,
                                            field: Sub4Import.commuteField,
                                            check: "commute corrections")

    /// PATCH 363 — THE SECOND CLAIMANT, AND THE REASON 361 EXISTED.
    ///
    /// This line and `Sub4Import.importMoves` had to land in the same diff.
    /// `unclaimed corrections` fails on a row belonging to a family no
    /// comparison names, so a build that wrote plan-session rows without this
    /// entry would fail the verifier on the athlete's first move. That is the
    /// forcing function doing precisely what it was built for, and taking it
    /// seriously means adding the family here rather than turning it off.
    nonisolated static let planMove = Family(subjectKind: Sub4Import.moveSubject,
                                             field: Sub4Import.moveField,
                                             check: "session moves")

    nonisolated static let all: [Family] = [commute, planMove]
}

// MARK: - The verifier

@MainActor
enum SemanticVerifier {

    /// Everything the migration claims to have carried, compared.
    ///
    /// Takes the same inputs `Sub4Import.run` takes, so the two are looking at
    /// the same stores rather than at two readings of them taken at different
    /// moments.
    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],
                       syncState: SyncState? = nil,
                       workItems: [WorkItem] = [],
                       rejections: [RejectionReceipt] = [],
                       commutes: [CommuteDecision] = [],
                       moves: [PlanMove] = [],
                       matchDecisions: [MatchDecision] = [],
                       weather: [ActivityWeather] = [],
                       zones: [AthleteStore.HRZone] = [],
                       streams: [ActivityStreams] = [],
                       details: [ActivityDetail] = []) throws -> VerificationReport {

        let clock = ContinuousClock()
        var checks: [VerificationCheck] = []

        let elapsed = try clock.measure {
            // The id every other expectation is derived from.
            let storeIDs = Set(activities.map(\.id))

            try db.queue.read { d in
                checks.append(contentsOf: try countChecks(
                    d, activities: activities, shoes: shoes, notes: notes,
                    proposals: proposals, workItems: workItems,
                    rejections: rejections, commutes: commutes,
                    moves: moves, matchDecisions: matchDecisions,
                    weather: weather, zones: zones, streams: streams,
                    details: details, storeIDs: storeIDs))
                // A COUNT WOULD NOT BE ENOUGH HERE, which is why this is a
                // check of its own rather than a line in `countChecks`.
                // `sync_state` holds exactly one row per source; comparing 1
                // against 1 would agree while the cursor inside it was a week
                // out, and a cursor a week out is what D7 would resume from.
                if let syncState {
                    checks.append(try syncStateCheck(d, expected: syncState))
                }
                checks.append(try identityCheck(d, storeIDs: storeIDs))
                checks.append(try fingerprintCheck(d, activities: activities))
                checks.append(contentsOf: try domainChecks(
                    d, activities: activities, weather: weather,
                    details: details, storeIDs: storeIDs))
            }
        }

        return VerificationReport(checks: checks, seconds: seconds(elapsed))
    }

    /// `verify`, for a caller that has nowhere to put a thrown error.
    ///
    /// RETURNS A FAILED REPORT RATHER THAN NIL. A database that cannot be read
    /// is the most serious answer this screen can give, and returning nil would
    /// render as an empty section — indistinguishable from not having pressed
    /// the button. So it comes back as one check, failed, saying so.
    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        syncState: SyncState? = nil,
                        workItems: [WorkItem] = [],
                        rejections: [RejectionReceipt] = [],
                        commutes: [CommuteDecision] = [],
                        moves: [PlanMove] = [],
                        matchDecisions: [MatchDecision] = [],
                        weather: [ActivityWeather] = [],
                        zones: [AthleteStore.HRZone] = [],
                        streams: [ActivityStreams] = [],
                        details: [ActivityDetail] = []) -> VerificationReport {
        do {
            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, proposals: proposals,
                              syncState: syncState, workItems: workItems,
                              rejections: rejections, commutes: commutes,
                              moves: moves, matchDecisions: matchDecisions,
                              weather: weather, zones: zones,
                              streams: streams, details: details)
        } catch {
            return VerificationReport(checks: [
                .init(name: "reading the database", table: "—",
                      expected: "readable", found: "failed",
                      passed: false, detail: String(describing: error))
            ], seconds: 0)
        }
    }

    /// The cursor itself, not the number of rows holding one — patch 275.
    ///
    /// Compares the STRING both sides use, so this cannot pass by rounding.
    /// The store renders the `Double` once, in `ActivityStore.syncState`, and
    /// what lands in the column is that same rendering; if the two ever
    /// diverged, D7 would resume from a position nothing had checked.
    private static func syncStateCheck(_ d: Database,
                                       expected: SyncState) throws -> VerificationCheck {
        let found = try String.fetchOne(d, sql: """
            SELECT cursor FROM sync_state WHERE accountID = ? AND sourceID = ?
            """, arguments: [Sub4Import.accountID, expected.sourceID])

        let agrees = found == expected.cursor

        // THE VALUES GO IN `detail`, NOT IN `expected`/`found` — and that is a
        // privacy decision, not a formatting one. `diagnosticLines` prints
        // every check's expected and found into the redacted paste, and this
        // cursor is the start time of the athlete's most recent activity.
        // §12.7 promises that paste carries no dates from his history.
        // `detail` is documented as screen-only for exactly this case.
        return .init(name: "sync position",
                     table: "sync_state",
                     expected: "the store's cursor",
                     found: agrees ? "the same"
                          : (found == nil ? "no row" : "a different one"),
                     passed: agrees,
                     detail: agrees ? nil
                           : "store \(expected.cursor ?? "—") · "
                             + "database \(found ?? "none")")
    }

    // MARK: 1 — Counts

    /// The cheapest layer, and the one the acceptance criterion is written
    /// against: delete a row by hand and exactly one of these must fail and
    /// name its table.
    private static func countChecks(_ d: Database,
                                    activities: [Activity],
                                    shoes: [AthleteStore.Shoe],
                                    notes: [NotesStore.Note],
                                    proposals: [ProposalStore.Record],
                                    workItems: [WorkItem],
                                    rejections: [RejectionReceipt],
                                    commutes: [CommuteDecision],
                                    moves: [PlanMove],
                                    matchDecisions: [MatchDecision],
                                    weather: [ActivityWeather],
                                    zones: [AthleteStore.HRZone],
                                    streams: [ActivityStreams],
                                    details: [ActivityDetail],
                                    storeIDs: Set<String>) throws -> [VerificationCheck] {

        // Only records whose activity is in the store are expected. See the
        // header: this is how the exclusions come out right without this file
        // knowing they exist.
        // PATCH 272, and the subtle one. A decision naming an activity the
        // store does not have is held back by the importer rather than written
        // with a NULL — so it must not be expected here either, or every
        // device carrying a stale override would report a permanent
        // disagreement the athlete could do nothing about. "Explicitly
        // nothing" IS expected: it is a row, with a NULL in it.
        let expectedDecisions = matchDecisions.filter {
            guard let id = $0.activityId else { return true }
            return storeIDs.contains(id)
        }.count

        let expectedWeather = weather.filter { storeIDs.contains($0.activityId) }.count
        let keptStreams = streams.filter { storeIDs.contains($0.activityId) }
        let keptDetails = details.filter { storeIDs.contains($0.activityId) }
        let expectedStreams = keptStreams.count
        let expectedDetails = keptDetails.count

        // THE CHILD ROWS, COUNTED IN TOTAL — added after the tests found the
        // gap. The domain layer compares the splits of ONE activity, chosen as
        // the richest so the check has something to fail on. That is a
        // representative check by design, and a representative check misses
        // everything it does not represent: a split deleted from any other
        // activity passed every layer.
        //
        // A total is the cheap complement. It cannot say WHICH split went, and
        // the domain check cannot say that a split went at all unless it was
        // the chosen one. Together they cover it.
        let expectedSplits = keptDetails.reduce(0) { $0 + $1.splits.count }
        let expectedSamples = keptStreams.reduce(0) { $0 + $1.count }

        return [
            .compare("activities", table: "activity",
                     expected: activities.count, found: try count(d, "activity")),
            .compare("gear", table: "gear",
                     expected: shoes.count, found: try count(d, "gear")),
            .compare("notes", table: "user_note",
                     expected: notes.count, found: try count(d, "user_note")),
            .compare("match decisions", table: "match_decision",
                     expected: expectedDecisions,
                     found: try count(d, "match_decision")),
            // PATCH 274, AND IT SHOULD HAVE BEEN HERE SINCE 263.
            //
            // The verifier has compared notes since the day it was written and
            // has never compared reviews — so when the rehearsal record was
            // deleted from `proposals.json` on 5 August and stayed in the
            // database, fourteen comparisons agreed and the run was marked
            // verified. The one store in this app that cannot be re-fetched is
            // the one nothing was checking.
            //
            // COUNTS THE PARENT ONLY. Its four children are reachable from it
            // and cascade with it; a count of `proposal_change` would be
            // asserting the shape of somebody's review rather than that the
            // review is there.
            .compare("reviews", table: "review",
                     expected: proposals.count, found: try count(d, "review")),
            // A COUNT IS ENOUGH HERE, unlike the sync position. Every row is
            // one id the app will never ask about again, so the number of them
            // IS the fact — and the importer prunes, so a stale row shows up
            // as a disagreement rather than being quietly tolerated.
            .compare("stopped asking", table: "work_queue",
                     expected: workItems.count, found: try count(d, "work_queue")),
            // NOT filtered by `storeIDs`, unlike weather and the traces. A
            // rejection is ABOUT a recording the database deliberately does
            // not hold — expecting only the ones with an activity would expect
            // none of them.
            .compare("refused recordings", table: "rejection",
                     expected: rejections.count, found: try count(d, "rejection")),
            // FILTERED BY `storeIDs`, unlike the rejections directly above.
            // A correction is ABOUT an activity the database holds; a rejection
            // is about one it refuses. The two lines look alike and mean
            // opposite things.
            //
            // QUALIFIED SINCE 361, AND NAMED FOR THE FAMILY IT COUNTS. `found`
            // was `count(d, "correction")` — the whole table — which was right
            // only while the commute decisions were the only rows in it. See
            // `ComparedCorrections` for why the fix is a list rather than a
            // `WHERE` clause.
            .compare(ComparedCorrections.commute.check, table: "correction",
                     expected: commutes.filter { storeIDs.contains($0.activityId) }.count,
                     found: try count(d, ComparedCorrections.commute)),
            // NOT FILTERED, unlike the commute comparison directly above, and
            // the two lines look alike for the third time on this table.
            //
            // A commute decision naming an activity the store does not have is
            // held back by the importer, so expecting it here would report a
            // permanent disagreement nobody could act on. A move is written
            // whatever its uid names — there is no resolution step to fail —
            // so every move the store holds is expected, orphans included.
            //
            // AND THIS ONE IS EVIDENCE. Nothing hydrates `PlanMoveStore` from
            // the database, so the expectation comes from a file the database
            // does not feed. It is the first comparison added since B1 that
            // could actually disagree. §12.99.
            .compare(ComparedCorrections.planMove.check, table: "correction",
                     expected: moves.count,
                     found: try count(d, ComparedCorrections.planMove)),
            // AND EVERY ROW NOBODY ABOVE COUNTED. Zero is the assertion, not a
            // placeholder: a row belonging to a family no comparison names is a
            // claimant that arrived without a verifier, and the report says so
            // rather than passing over it. §12.69 — this check can fail, and
            // `CorrectionFamilyTests` makes it.
            try unclaimedCorrections(d),
            .compare("weather readings", table: "weather",
                     expected: expectedWeather, found: try count(d, "weather")),
            .compare("traces", table: "recording",
                     expected: expectedStreams, found: try count(d, "recording")),
            .compare("details", table: "activity_detail",
                     expected: expectedDetails, found: try count(d, "activity_detail")),
            .compare("splits", table: "activity_split",
                     expected: expectedSplits, found: try count(d, "activity_split")),
            .compare("trace samples", table: "recording_sample",
                     expected: expectedSamples, found: try count(d, "recording_sample")),
            .compare("heart-rate zones", table: "hr_zone",
                     expected: zones.count, found: try count(d, "hr_zone")),
        ]
    }

    // MARK: 2 — Identity

    /// THE SAME 667, not merely 667.
    ///
    /// Two sets of equal size can disagree completely, and the count check
    /// above would pass on both. This is the one that would catch an activity
    /// imported twice under two ids while another was dropped.
    private static func identityCheck(_ d: Database,
                                      storeIDs: Set<String>) throws -> VerificationCheck {
        let rows = try String.fetchAll(d, sql: """
            SELECT externalID FROM activity_alias WHERE sourceID = ?
            """, arguments: [Sub4Import.sourceID])
        let dbIDs = Set(rows)

        let missing = storeIDs.subtracting(dbIDs).sorted()
        let extra = dbIDs.subtracting(storeIDs).sorted()
        let ok = missing.isEmpty && extra.isEmpty

        var detail: String?
        if !ok {
            // Named, and capped. A list of six hundred is not a diagnosis, and
            // the count beside it says the list is not the whole story.
            detail = """
                missing \(missing.count): \(missing.prefix(5).joined(separator: ", ")) · \
                unexpected \(extra.count): \(extra.prefix(5).joined(separator: ", "))
                """
        }
        return .init(name: "activity identities", table: "activity_alias",
                     expected: "\(storeIDs.count) ids",
                     found: "\(dbIDs.count) ids, \(missing.count) missing, \(extra.count) unexpected",
                     passed: ok, detail: detail)
    }

    // MARK: 3 — Content

    /// A row that exists with the wrong distance passes both layers above.
    ///
    /// Seven fields per activity: the ones every screen in the app reads and
    /// every training figure is computed from. Not every column — `createdUTC`
    /// is written by the importer and has nothing to compare against.
    private static func fingerprintCheck(_ d: Database,
                                         activities: [Activity]) throws -> VerificationCheck {
        var stored: [String: String] = [:]
        let rows = try Row.fetchAll(d, sql: """
            SELECT al.externalID  AS ext,
                   a.startLocal   AS startLocal,
                   a.dayKey       AS dayKey,
                   a.discipline   AS discipline,
                   a.name         AS name,
                   a.distanceM    AS distanceM,
                   a.movingSeconds  AS movingSeconds,
                   a.elapsedSeconds AS elapsedSeconds
              FROM activity a
              JOIN activity_alias al
                ON al.activityID = a.id AND al.sourceID = ?
            """, arguments: [Sub4Import.sourceID])

        for r in rows {
            guard let ext = r["ext"] as String? else { continue }
            stored[ext] = fingerprint(startLocal: r["startLocal"] as String? ?? "",
                                      dayKey: r["dayKey"] as String? ?? "",
                                      discipline: r["discipline"] as String? ?? "",
                                      name: r["name"] as String? ?? "",
                                      distanceM: r["distanceM"] as Double? ?? 0,
                                      moving: r["movingSeconds"] as Int? ?? 0,
                                      elapsed: r["elapsedSeconds"] as Int? ?? 0)
        }

        var differing: [String] = []
        for a in activities {
            let mine = fingerprint(startLocal: a.startLocal,
                                   dayKey: a.dayKey,
                                   discipline: (a.discipline ?? .other).rawValue,
                                   name: a.name,
                                   distanceM: a.distance,
                                   moving: a.movingTime,
                                   elapsed: a.elapsedTime)
            // An activity with no row at all is the identity check's finding,
            // not this one. Reporting it twice would make one fault look like
            // two.
            guard let theirs = stored[a.id] else { continue }
            if theirs != mine { differing.append(a.id) }
        }

        return .init(name: "activity fields", table: "activity",
                     expected: "\(activities.count) matching",
                     found: "\(activities.count - differing.count) matching, \(differing.count) different",
                     passed: differing.isEmpty,
                     detail: differing.isEmpty ? nil
                             : differing.prefix(5).joined(separator: ", "))
    }

    private static func fingerprint(startLocal: String, dayKey: String,
                                    discipline: String, name: String,
                                    distanceM: Double, moving: Int,
                                    elapsed: Int) -> String {
        // Distance to the millimetre. `Double` round-trips exactly through
        // SQLite's REAL, so this is not a tolerance — it is a format, and a
        // tolerance here would hide the rounding bug it looks like it prevents.
        String(format: "%@|%@|%@|%@|%.3f|%d|%d",
               startLocal, dayKey, discipline, name, distanceM, moving, elapsed)
    }

    // MARK: 4 — Domain outputs

    /// Counts, ids and fields can all agree while a figure the app SHOWS comes
    /// out different. These are the three that are computable on both sides
    /// today without writing a second implementation of anything.
    private static func domainChecks(_ d: Database,
                                     activities: [Activity],
                                     weather: [ActivityWeather],
                                     details: [ActivityDetail],
                                     storeIDs: Set<String>) throws -> [VerificationCheck] {
        var out: [VerificationCheck] = []

        // 4a. Volume by discipline — what Today and History add up.
        var storeVolume: [String: (m: Double, s: Int)] = [:]
        for a in activities {
            let k = (a.discipline ?? .other).rawValue
            var v = storeVolume[k] ?? (0, 0)
            v.m += a.distance
            v.s += a.movingTime
            storeVolume[k] = v
        }
        var dbVolume: [String: (m: Double, s: Int)] = [:]
        for r in try Row.fetchAll(d, sql: """
            SELECT discipline, SUM(distanceM) AS m, SUM(movingSeconds) AS s
              FROM activity GROUP BY discipline
            """) {
            guard let k = r["discipline"] as String? else { continue }
            dbVolume[k] = (r["m"] as Double? ?? 0, r["s"] as Int? ?? 0)
        }
        let storeLine = volumeLine(storeVolume)
        let dbLine = volumeLine(dbVolume)
        out.append(.init(name: "volume by discipline", table: "activity",
                         expected: storeLine, found: dbLine,
                         passed: storeLine == dbLine, detail: nil))

        // 4b. One activity's splits. The richest one, so the check has
        // something to fail on — a detail with no splits proves nothing.
        let candidates = details.filter { storeIDs.contains($0.activityId) }
        let deepest = candidates.max { $0.splits.count < $1.splits.count }
        if let deepest, !deepest.splits.isEmpty {
            let stored = try Row.fetchOne(d, sql: """
                SELECT COUNT(*) AS n, COALESCE(SUM(s.distanceM), 0) AS m
                  FROM activity_split s
                  JOIN activity_detail ad ON ad.id = s.activityDetailID
                  JOIN activity_alias al ON al.activityID = ad.activityID
                                        AND al.sourceID = ?
                 WHERE al.externalID = ?
                """, arguments: [Sub4Import.sourceID, deepest.activityId])
            let n = stored?["n"] as Int? ?? 0
            let m = stored?["m"] as Double? ?? 0
            let mine = String(format: "%d splits, %.1f m", deepest.splits.count,
                              deepest.splits.reduce(0) { $0 + $1.distanceM })
            let theirs = String(format: "%d splits, %.1f m", n, m)
            out.append(.init(name: "splits of one activity", table: "activity_split",
                             expected: mine, found: theirs,
                             passed: mine == theirs,
                             detail: mine == theirs ? nil : deepest.activityId))
        }

        // 4c. One weather reading. Chosen by sorted id rather than at random,
        // so two runs over one database compare the same reading and a
        // difference between runs means the data moved.
        let readable = weather.filter { storeIDs.contains($0.activityId) }
            .sorted { $0.activityId < $1.activityId }
        if let first = readable.first {
            let stored = try Row.fetchOne(d, sql: """
                SELECT w.tempC AS t, w.samples AS n
                  FROM weather w
                  JOIN activity_alias al ON al.activityID = w.activityID
                                        AND al.sourceID = ?
                 WHERE al.externalID = ?
                """, arguments: [Sub4Import.sourceID, first.activityId])
            // `1 samples` on the device, 5 August. Both sides go through the
            // same formatter, so the comparison was never wrong — it just read
            // badly, and a screen that reads badly gets trusted less than one
            // that does not.
            func line(_ t: Double, _ n: Int) -> String {
                String(format: "%.2f °C, %d sample%@", t, n, n == 1 ? "" : "s")
            }
            let mine = line(first.tempC, first.samples)
            let theirs = stored.map {
                line($0["t"] as Double? ?? 0, $0["n"] as Int? ?? 0)
            } ?? "no row"
            out.append(.init(name: "one weather reading", table: "weather",
                             expected: mine, found: theirs,
                             passed: mine == theirs,
                             detail: mine == theirs ? nil : first.activityId))
        }

        return out
    }

    private static func volumeLine(_ v: [String: (m: Double, s: Int)]) -> String {
        v.keys.sorted().map { k in
            let e = v[k] ?? (0, 0)
            return String(format: "%@ %.1fm/%ds", k, e.m, e.s)
        }.joined(separator: " · ")
    }

    // MARK: Reaching `verified`

    /// Moves a run to `verified`, and ONLY on a report that passed.
    ///
    /// The one line in this file that must never be made convenient. A run
    /// marked `verified` by something that verified nothing is the defect this
    /// project has found six times, and D7 acts on this state.
    @discardableResult
    static func record(_ report: VerificationReport,
                       for runID: String,
                       in db: Sub4Database) throws -> Bool {
        // PATCH 354 — `isTrustworthyEvidence`, NOT `passed`, and the doc
        // above is the reason. A report where every comparison read a store the
        // database feeds passes trivially: it is the database agreeing with
        // itself, and `verified` is what D7's activation reads. §12.69.
        //
        // This is the sixth time this project has had to make a check able to
        // fail before believing it, and the first time the erosion was
        // gradual rather than present on day one.
        guard report.isTrustworthyEvidence else { return false }
        return try MigrationLedger.verifyPending(db, id: runID,
                                                 note: report.ledgerNote)
    }

    // MARK: Small

    private static func count(_ d: Database, _ table: String) throws -> Int {
        // The table name is a literal from `countChecks` and never from input.
        try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    /// One family's rows, keyed the way the writer keys them — patch 361.
    ///
    /// Overloads `count(_:_:)` on purpose. The two read the same at the call
    /// site and the argument is what says whether the whole table or one
    /// family is meant, which is the distinction this patch exists to make
    /// impossible to lose.
    private static func count(_ d: Database,
                              _ f: ComparedCorrections.Family) throws -> Int {
        try Int.fetchOne(d, sql: """
            SELECT COUNT(*) FROM correction
            WHERE subjectKind = ? AND field = ?
            """, arguments: [f.subjectKind, f.field]) ?? 0
    }

    /// Rows belonging to no family in `ComparedCorrections.all`.
    ///
    /// THE PREDICATE IS BUILT FROM THE LIST rather than written out beside it,
    /// so adding a family narrows this check automatically and cannot be
    /// half-done. A list and a hand-written `WHERE` that drifted apart would
    /// leave a family both counted and claimed, or neither.
    ///
    /// `found` is a bare count and `detail` names the kinds and fields — the
    /// §12.7 split. `subjectKind` and `field` are column vocabulary and safe on
    /// a screen; `subjectID` is the athlete's own identifier and appears in
    /// neither.
    private static func unclaimedCorrections(_ d: Database) throws -> VerificationCheck {
        let families = ComparedCorrections.all
        // AN EMPTY LIST WOULD BUILD `WHERE NOT ()`, which is a SQL syntax error
        // — a verifier that threw instead of reporting is §12.15. It cannot
        // happen today (`all` is a literal with one entry) and it is handled
        // rather than asserted, because the honest answer to an empty list is
        // "then nothing is claimed", not a crash.
        var args: [DatabaseValue] = []
        for f in families {
            args.append(f.subjectKind.databaseValue)
            args.append(f.field.databaseValue)
        }
        let clause = families
            .map { _ in "(subjectKind = ? AND field = ?)" }
            .joined(separator: " OR ")
        let sql = clause.isEmpty
            ? "SELECT subjectKind, field FROM correction"
            : "SELECT subjectKind, field FROM correction WHERE NOT (\(clause))"

        let rows = try Row.fetchAll(d, sql: sql,
                                    arguments: StatementArguments(args))
        let pairs = Set(rows.map { r -> String in
            let kind = r["subjectKind"] as String? ?? "?"
            let field = r["field"] as String? ?? "?"
            return "\(kind) · \(field)"
        }).sorted()

        return .init(name: "unclaimed corrections", table: "correction",
                     expected: "0", found: "\(rows.count)",
                     passed: rows.isEmpty,
                     detail: rows.isEmpty ? nil
                           : "no comparison claims: "
                             + pairs.joined(separator: ", "))
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
