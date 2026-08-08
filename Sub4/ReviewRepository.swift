//
//  ReviewRepository.swift
//  Sub4
//
//  The review trail, read back — D6c slice 7, patch 327, ADR-0003 §12.71.
//
//  WHAT THIS IS FOR
//  ----------------
//  Ninth repository, and the one D6c has been putting off since the groundwork
//  was written, because slice 7 is the only slice whose subject matter does not
//  exist yet. `ReviewDue.state()` needs four finished plan weeks; the block
//  began Monday 27 July, week 4 ends Sunday 23 August, and the first real
//  review is due **Monday 24 August 2026**. Until that day `proposals.json`
//  either does not exist or holds one rehearsal record, and six tables hold
//  either nothing or one synthetic tree.
//
//  So this is written now and proved later, and the numbers on screen are
//  arranged so that the difference between those two states is legible rather
//  than inferred. That is the whole design constraint of this file.
//
//  THREE NUMBERS, NOT ONE — AND THIS SLICE NEEDS THEM MORE THAN ANY OTHER
//  ---------------------------------------------------------------------
//  Groundwork §2.1 asks every D6c diagnostic to carry a denominator, because a
//  comparison of zero against zero agrees perfectly and proves nothing. Every
//  other slice satisfied that by having hundreds of rows on both sides. This
//  one may legitimately have none.
//
//  `reviewsInApp`, `reviewsInDatabase` and `reviewsCompared` are therefore
//  three separate figures, and the summary line says which of four worlds the
//  reader is in:
//
//    0 / 0 / 0   — no review has been run. The expected state before 24 August,
//                  and the line says so with the date attached, because a bare
//                  "nothing compared" is exactly §12.15's shape: a diagnostic
//                  that cannot say why it has no answer will be read as having
//                  one.
//    1 / 1 / 1   — the rehearsal, or the first real review, round-tripped.
//    n / 0 / 0   — reviews exist and the import never reached them. A red row.
//    0 / n / 0   — the database holds reviews the app has lost. The state
//                  §12.8.1 records from the day a reinstall took every past
//                  review, and the reason `ProposalStore` migrates rather than
//                  clears. Not red — see below.
//
//  NO CONTENT IS EVER PRINTED, AND THAT IS A HARDER RULE HERE THAN AT 322
//  ---------------------------------------------------------------------
//  322 established that `user_note` text never reaches the diagnostics block.
//  This slice carries strictly more: `review_evidence.body` is the entire
//  evidence pack — every figure the model was given about the athlete's
//  training — and `proposal.reasoning` is a model's prose about the athlete,
//  at length.
//
//  So a difference is named by its FIELD and quantified by CHARACTER COUNT, and
//  never by its value:
//
//      review 1 · evidence body (app 4812 chars, database 4780)
//
//  That is enough to act on — a length difference says truncation, an equal
//  length with a difference says substitution — and it discloses nothing. The
//  diagnostics block stays safe to paste, which is the property that makes it
//  useful at all.
//
//  WHAT THE IMPORTER ACTUALLY WRITES, WHICH IS NOT WHAT THE SCHEMA ANTICIPATES
//  --------------------------------------------------------------------------
//  Six tables were built for this trail. The importer writes five of them, and
//  the shapes it writes are narrower than the columns allow. Read out of
//  `Sub4Import+Authored.importProposals` rather than assumed, because the gap
//  between a schema's ambition and a writer's behaviour is where 324 found two
//  defects:
//
//    review                 written · 5 comparable fields
//    review_evidence        written · EXACTLY ONE row per review, sectionKey
//                           always 'pack', wasSent always true
//    review_evidence_source NOTHING WRITES IT — see below
//    proposal               written · 5 comparable fields, and `decision` and
//                           `decidedUTC` are columns with no app-side field
//    proposal_change        written · 6 comparable fields
//    proposal_watch         written · 1 comparable field
//
//  `review_evidence_source` IS THE FINDING, AND IT IS NOT A ZERO
//  ------------------------------------------------------------
//  The table exists because ADR-0002's purge has to find every stored piece of
//  evidence with Strava lineage and remove it while leaving the verdict
//  standing — which is a query, so lineage has to be queryable. The schema
//  comment argues that at length and it is right.
//
//  Nothing writes it. Not the importer, not the review runner, not the
//  rehearsal. Its only INSERT in the entire project is inside
//  `DomainSchemaTests`. So it holds zero rows on every device, and will hold
//  zero rows on 24 August too, and the lineage obligation ADR-0002 records is
//  presently unmet by construction rather than by accident.
//
//  §12.54.2 is why this gets a line of its own that prints whether or not it is
//  zero, and why that line is worded as a statement about the writer rather
//  than a count: a row that vanishes at zero cannot be told from a row nobody
//  wired in. Here nobody wired it in, and the screen says so.
//
//  THE SIXTH CANONICAL-ID INSTANCE, AND THE FIRST THAT CAN BE RESOLVED
//  ------------------------------------------------------------------
//  `proposal_change.planSessionUID` is deliberately not a foreign key — the
//  migration header says so, because a proposal must survive a plan revision
//  that renumbers the week it names. It holds `Change.sessionUid`, which is the
//  plan session's **uid**, the same column 323 compared, and NOT `plan_session
//  .id`. Sixth member of the family and the fifth time the distinction has
//  mattered.
//
//  Because it is not an FK, nothing checks it, and `ReviewProposal
//  .rejections(plan:)` already has a name for a change that names no session:
//  *"no session with that id — invented"*. So this resolves every stored
//  `planSessionUID` against `SELECT DISTINCT uid FROM plan_session` and reports
//  how many of how many resolved. That is the denominator rule applied to the
//  one number in this slice nobody else computes, and it is the check most
//  likely to catch something real.
//
//  AND A DATABASE WITH NO PLAN IN IT CANNOT ANSWER THE QUESTION. 327 counted
//  those as failures; 327b counts them as unanswerable, on their own line. See
//  `Report.changesUnresolvable` — a check that cannot run must not be reported
//  as a check that failed.
//
//  Resolved across ALL versions, not the active one. A proposal written against
//  Rev 4.0 names uids that Rev 4.1 may have dropped; counting that as
//  unresolved would report history as corruption.
//
//  WHAT IS NOT COMPARED, AND WHY
//  -----------------------------
//  `ReviewProposal.acceptedChanges(plan:)` and `rejections(plan:)` are
//  guardrails applied at READ time on the app side. They are not stored and
//  must not be: the database keeps what the model said, and the guardrails are
//  a judgement made freshly against whatever plan is current. Comparing them
//  would be comparing a derivation against a record, which is slice 8's job for
//  the summaries and nobody's job here.
//
//  §12.43, TENTH APPLICATION
//  -------------------------
//  `proposal_change.what` has no app-side field. The importer derives it with
//  `Sub4Import.changeSummary(_:)`, and this file CALLS that function rather
//  than rewriting `c.skip ? "Skip this session" : c.newDetail`. Two lines is
//  exactly the size of copy that gets away with drifting.
//  `Sub4Import.iso8601(_:)` and `Sub4Import.reviewProvider` are called for the
//  same reason.
//

import Foundation
import GRDB

// MARK: - What the read produced

nonisolated enum ReviewTrailLoad: Sendable {

    // NESTED, like `WeatherGearLoad.StoredGear` — and the grep that says why is
    // worth recording. `ReviewLoad` is ALREADY A TYPE IN THIS APP: it turns the
    // load engine into things the monthly review can say. A top-level
    // `ReviewLoad` here would have collided with it, and four top-level
    // `Stored*` types in a project of 165 Swift files is asking for the next
    // collision. §12.61.9 — and this is the first time that rule caught a NAME
    // rather than a duplicated test.
    //
    // `nonisolated` on the enclosing enum reaches these, which is what makes
    // them constructible inside `db.queue.read` — patch 324's lesson, where
    // reading a stored property worked and CONSTRUCTING the type did not.

    struct StoredChange: Sendable {
        let ordinal: Int
        let planSessionUID: String
        let what: String
        let why: String?
        let newDetail: String?
        /// Nullable by decision — a proposal imported before the column existed
        /// has NO ANSWER, which the migration header distinguishes from "does
        /// not skip". Compared as an optional against a non-optional `Bool`, so
        /// a NULL reports as a difference rather than as `false`.
        let isSkip: Bool?
        let evidence: String?
    }

    struct StoredProposal: Sendable {
        let id: String
        let verdict: String
        let summary: String
        let reasoning: String
        let confidence: Int?
        let receivedUTC: String
        /// No app-side counterpart at all. See `ReviewRoundTrip.approved`.
        let decision: String?
        let decidedUTC: String?
        let changes: [StoredChange]
        let watch: [String]
    }

    struct StoredEvidence: Sendable {
        let id: String
        let sectionKey: String
        let title: String
        let body: String
        let wasSent: Bool
        /// From `review_evidence_source`. Empty on every device — §12.71.3.
        let sourceIDs: [String]
    }

    struct StoredReview: Sendable {
        let id: String
        let ranUTC: String
        let windowStartDayKey: String
        let windowEndDayKey: String
        let provider: String
        let model: String?
        let appVersion: String?
        let evidence: [StoredEvidence]
        let proposals: [StoredProposal]
    }


    /// `reviews` empty is a real and expected answer, not a failure. See the
    /// header's four worlds.
    ///
    /// `planSessionUIDs` is carried on the loaded case rather than fetched by
    /// the comparison, because it is read inside the same transaction as the
    /// changes it resolves. A second read could see a plan that had been
    /// re-imported in between and report resolutions that were never true
    /// together.
    case loaded(reviews: [StoredReview],
                planSessionUIDs: Set<String>,
                evidenceSourceRows: Int,
                skipped: Int)
    case unavailable
    case failed(String)

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    var reviews: [StoredReview]? {
        if case .loaded(let r, _, _, _) = self { return r }
        return nil
    }

    var planSessionUIDs: Set<String> {
        if case .loaded(_, let u, _, _) = self { return u }
        return []
    }

    var evidenceSourceRows: Int {
        if case .loaded(_, _, let n, _) = self { return n }
        return 0
    }

    var skipped: Int {
        if case .loaded(_, _, _, let s) = self { return s }
        return 0
    }

    /// THE DATE IS IN THE LINE ON PURPOSE — §12.15.
    ///
    /// "Nothing compared" is the same sentence whether the review path is
    /// broken or whether it is three weeks from its first run. Only one of
    /// those is worth acting on, and the reader cannot tell them apart without
    /// being told which it is.
    var line: String {
        switch self {
        case .loaded(let reviews, _, let sourceRows, let skipped):
            guard !reviews.isEmpty else {
                return "No review is stored. The first is due 24 August 2026, "
                     + "so this is the expected state until then."
            }
            let proposals = reviews.reduce(0) { $0 + $1.proposals.count }
            let base = "\(reviews.count) "
                     + (reviews.count == 1 ? "review" : "reviews")
                     + ", \(proposals) "
                     + (proposals == 1 ? "proposal" : "proposals")
                     + ", \(sourceRows) evidence-lineage rows."
            return skipped == 0 ? base
                                : base + " \(skipped) rows could not be read."
        case .unavailable:
            return "The database is not open."
        case .failed(let why):
            return "The read failed: \(why)"
        }
    }
}

// MARK: - The comparison

nonisolated enum ReviewRoundTrip {

    /// Three, all structural, all with a reason and the patch that made it.
    ///
    /// Groundwork §5: the list is a decision record, not a suppression list,
    /// and an entry nobody can justify is a bug that has been given a hiding
    /// place.
    struct ApprovedDifference: Sendable {
        var field: String
        var why: String
    }

    static let approved: [ApprovedDifference] = [
        .init(field: "Record.id",
              why: "the app keys a review by window label and run count; the "
                 + "database mints a UUID and keys on (accountID, ranUTC). "
                 + "No column, and none is wanted — patch 327."),
        .init(field: "review.provider",
              why: "the app stores a model but no provider. The importer "
                 + "writes the constant Sub4Import.reviewProvider rather than "
                 + "guessing one from the model string — §12.7.2 — so the "
                 + "comparison checks it against that constant."),
        .init(field: "proposal.decision / decidedUTC",
              why: "two columns for accepting or rejecting a proposal. "
                 + "ReviewProposal has no such field and no screen offers the "
                 + "choice, so nothing writes them. Same shape as "
                 + "gear.retiredUTC at 324 — patch 327.")
    ]

    struct Report: Sendable {

        // MARK: Denominators

        var reviewsInApp = 0
        var reviewsInDatabase = 0
        var reviewsCompared = 0
        /// Five: window start, window end, provider, model, appVersion.
        var reviewFieldsCompared = 0

        var evidenceInApp = 0
        var evidenceInDatabase = 0
        var evidenceCompared = 0
        /// Four: sectionKey, title, body, wasSent.
        var evidenceFieldsCompared = 0

        var proposalsInApp = 0
        var proposalsInDatabase = 0
        var proposalsCompared = 0
        /// Five: verdict, summary, reasoning, confidence, receivedUTC.
        var proposalFieldsCompared = 0

        var changesInApp = 0
        var changesInDatabase = 0
        var changesCompared = 0
        /// Six per change.
        var changeFieldsCompared = 0

        var watchInApp = 0
        var watchInDatabase = 0
        var watchCompared = 0

        // MARK: The resolve — the number nobody else computes

        /// Distinct `plan_session.uid` values across every stored version.
        var planSessionUIDsKnown = 0
        /// How many stored `planSessionUID` values name one of them.
        var changesNamingAKnownSession = 0

        /// COULD NOT BE CHECKED IS NOT THE SAME AS FAILED — patch 327b, and
        /// the tests found it.
        ///
        /// 327 counted every unresolved uid against the database, including on
        /// a database holding no plan at all. That conflates *"the model
        /// invented a session"* with *"the plan has not been imported"*, which
        /// is §12.15's shape inside a number instead of inside a sentence: a
        /// check that cannot run reported as a check that failed.
        ///
        /// It is also `StoreReadJournal.canReconcile`'s argument in a second
        /// place — do not act on the strength of an incomplete reading. There
        /// the act was a delete; here it is an accusation.
        var changesUnresolvable: Int {
            planSessionUIDsKnown == 0 ? changesCompared : 0
        }
        var changesResolvable: Int { changesCompared - changesUnresolvable }

        // MARK: Columns nothing occupies

        /// Rows in `review_evidence_source`, across the whole table. Printed
        /// whether or not it is zero, and worded as a fact about the writer.
        var evidenceSourceRows = 0
        /// Proposals carrying a decision. Structurally zero.
        var proposalsCarryingADecision = 0

        // MARK: Shapes the schema allows and the writer never produces

        /// Distinct `sectionKey` values seen. `['pack']` today.
        var sectionKeysSeen: [String] = []
        /// Evidence rows with `wasSent = 0`. Structurally zero — the importer
        /// writes 1 unconditionally, because `Record.evidence` IS what was
        /// sent. The schema's withheld-section case has never had a row.
        var evidenceWithheld = 0
        /// The observed `confidence` range, as text. `ReviewProposal.confidence`
        /// documents itself as 1–5; the column's CHECK permits 0–100. Printed
        /// so the day those two disagree is visible — §12.71.4.
        var confidenceRange = "—"

        // MARK: Differences, named — never valued

        /// "review 2026-08-06 · appVersion"
        var reviewDifferences: [String] = []
        /// "review 1 · evidence body (app 4812 chars, database 4780)"
        var evidenceDifferences: [String] = []
        var proposalDifferences: [String] = []
        /// "review 1 · change 0 · planSessionUID"
        var changeDifferences: [String] = []
        var watchDifferences: [String] = []

        /// Keyed by `ranUTC`, so these are ISO timestamps and nothing else.
        var reviewsOnlyInApp: [String] = []
        var reviewsOnlyInDatabase: [String] = []
        /// Two app records with the same `ranAt`. Reported rather than one of
        /// them being dropped by the dictionary that keys them.
        var duplicateRunTimes: [String] = []

        var rowsSkipped = 0

        var totalCompared: Int {
            reviewsCompared + evidenceCompared + proposalsCompared
            + changesCompared + watchCompared
        }

        /// A review the database holds and the app does not is NOT red.
        ///
        /// §12.8.1 records the day a reinstall took every past review and there
        /// was nowhere to get them back from. If that happens again the
        /// database is the only copy, and the row that shows it must not be
        /// styled as a fault in the thing that saved the data.
        var unexplained: Int {
            reviewDifferences.count + evidenceDifferences.count
            + proposalDifferences.count + changeDifferences.count
            + watchDifferences.count
            + reviewsOnlyInApp.count
            + duplicateRunTimes.count
            + (changesResolvable - changesNamingAKnownSession)
            + rowsSkipped
        }

        /// Deliberately NOT `totalCompared > 0`.
        ///
        /// Every other slice can assume its subject exists. This one cannot
        /// until 24 August, and a screen that called the expected state
        /// "nothing compared · unhealthy" for three weeks would train its
        /// reader to ignore the row — §12.40.1 measured that once already.
        var bothSidesAreEmpty: Bool {
            reviewsInApp == 0 && reviewsInDatabase == 0
        }

        var lookedAtSomething: Bool { totalCompared > 0 || bothSidesAreEmpty }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            if bothSidesAreEmpty {
                return "no review stored yet · first due 24 Aug 2026"
            }
            guard totalCompared > 0 else { return "nothing compared" }
            return unexplained == 0
                ? "\(totalCompared) compared · no differences"
                : "\(totalCompared) compared · \(unexplained) differences"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        ///
        /// SAFE TO PASTE, and this one was checked rather than assumed: counts,
        /// field names, ISO timestamps, plan session uids and character counts.
        /// No evidence pack, no model prose, no session detail, no titles.
        ///
        /// BUILT BY APPEND, NOT AS ONE ARRAY LITERAL — patch 327a, and it is
        /// the first time this failure has appeared outside a SwiftUI `body`.
        /// Thirty-eight elements, most carrying interpolation and two carrying
        /// `+` concatenation, is one expression the type-checker has to solve
        /// as a whole: *"unable to type-check this expression in reasonable
        /// time"*. `PlanExtrasRoundTrip` has thirty-four and compiles, so the
        /// threshold is somewhere in between and is not worth locating. One
        /// statement per line costs nothing and cannot recur.
        var diagnosticLines: [String] {
            var lines: [String] = []
            lines.append("Review read-back: \(summary)")
            lines.append("  reviews in the app: \(reviewsInApp)")
            lines.append("  reviews in the database: \(reviewsInDatabase)")
            lines.append("  reviews compared: \(reviewsCompared)")
            lines.append("  review fields compared: \(reviewFieldsCompared)")
            lines.append("  evidence rows in the app: \(evidenceInApp)")
            lines.append("  evidence rows in the database: \(evidenceInDatabase)")
            lines.append("  evidence rows compared: \(evidenceCompared)")
            lines.append("  evidence fields compared: \(evidenceFieldsCompared)")

            let keys = sectionKeysSeen.isEmpty
                     ? "none" : sectionKeysSeen.joined(separator: ", ")
            lines.append("  section keys seen: \(keys)")
            lines.append("  evidence built and withheld: \(evidenceWithheld)")

            lines.append("  proposals in the app: \(proposalsInApp)")
            lines.append("  proposals in the database: \(proposalsInDatabase)")
            lines.append("  proposals compared: \(proposalsCompared)")
            lines.append("  proposal fields compared: \(proposalFieldsCompared)")
            lines.append("  confidence range seen: \(confidenceRange)")

            lines.append("  changes in the app: \(changesInApp)")
            lines.append("  changes in the database: \(changesInDatabase)")
            lines.append("  changes compared: \(changesCompared)")
            lines.append("  change fields compared: \(changeFieldsCompared)")
            lines.append("  plan session uids known to the database: "
                         + "\(planSessionUIDsKnown)")
            lines.append("  changes naming a known session: "
                         + "\(changesNamingAKnownSession) of \(changesResolvable)")
            lines.append("  changes whose session could not be checked: "
                         + "\(changesUnresolvable) "
                         + "(the database holds no plan)")

            lines.append("  watch items in the app: \(watchInApp)")
            lines.append("  watch items in the database: \(watchInDatabase)")
            lines.append("  watch items compared: \(watchCompared)")

            // WORDED AS A FACT ABOUT THE WRITER, not as a count — §12.54.2.
            lines.append("  evidence lineage rows: \(evidenceSourceRows) "
                         + "(nothing in the app writes review_evidence_source)")
            lines.append("  proposals carrying a decision: "
                         + "\(proposalsCarryingADecision) "
                         + "(no screen offers the choice)")

            lines.append("  reviews only in the app: \(reviewsOnlyInApp.count)")
            lines.append("  reviews only in the database: "
                         + "\(reviewsOnlyInDatabase.count)")
            lines.append("  app records sharing a run time: "
                         + "\(duplicateRunTimes.count)")

            lines.append("  review fields that differ: \(reviewDifferences.count)")
            lines.append("  evidence fields that differ: \(evidenceDifferences.count)")
            lines.append("  proposal fields that differ: \(proposalDifferences.count)")
            lines.append("  change fields that differ: \(changeDifferences.count)")
            lines.append("  watch items that differ: \(watchDifferences.count)")
            lines.append("  rows the reader could not read: \(rowsSkipped)")

            let approvedFields = ReviewRoundTrip.approved.map(\.field)
                .joined(separator: ", ")
            lines.append("  approved differences: \(approvedFields)")
            lines.append("  unexplained differences: \(unexplained)")

            for d in reviewsOnlyInApp.prefix(4) {
                lines.append("    only in the app: \(d)")
            }
            for d in reviewsOnlyInDatabase.prefix(4) {
                lines.append("    only in the database: \(d)")
            }
            for d in duplicateRunTimes.prefix(4) { lines.append("    \(d)") }
            for d in reviewDifferences.prefix(6) { lines.append("    \(d)") }
            for d in evidenceDifferences.prefix(6) { lines.append("    \(d)") }
            for d in proposalDifferences.prefix(6) { lines.append("    \(d)") }
            for d in changeDifferences.prefix(8) { lines.append("    \(d)") }
            if changeDifferences.count > 8 {
                lines.append("    + \(changeDifferences.count - 8) more entries")
            }
            for d in watchDifferences.prefix(4) { lines.append("    \(d)") }
            return lines
        }
    }

    // MARK: The walk

    /// EVERY STORED FIELD, NAMED — as everywhere else. No reflection.
    static func compare(storeRecords: [ProposalStore.Record],
                        database: ReviewTrailLoad) -> Report {
        var r = Report()
        r.reviewsInApp = storeRecords.count

        guard let stored = database.reviews else { return r }

        r.reviewsInDatabase = stored.count
        r.rowsSkipped = database.skipped
        r.evidenceSourceRows = database.evidenceSourceRows
        r.planSessionUIDsKnown = database.planSessionUIDs.count

        r.evidenceInApp = storeRecords.count      // one pack per record, always
        r.proposalsInApp = storeRecords.count     // one proposal per record
        r.changesInApp = storeRecords.reduce(0) { $0 + $1.proposal.changes.count }
        r.watchInApp = storeRecords.reduce(0) { $0 + $1.proposal.watchFor.count }

        r.evidenceInDatabase = stored.reduce(0) { $0 + $1.evidence.count }
        r.proposalsInDatabase = stored.reduce(0) { $0 + $1.proposals.count }
        r.changesInDatabase = stored.reduce(0) { partial, review in
            partial + review.proposals.reduce(0) { $0 + $1.changes.count }
        }
        r.watchInDatabase = stored.reduce(0) { partial, review in
            partial + review.proposals.reduce(0) { $0 + $1.watch.count }
        }

        // Shapes the schema allows and the writer never produces.
        var keys = Set<String>()
        for review in stored {
            for e in review.evidence {
                keys.insert(e.sectionKey)
                if !e.wasSent { r.evidenceWithheld += 1 }
            }
        }
        r.sectionKeysSeen = keys.sorted()

        let confidences = stored.flatMap { $0.proposals.compactMap(\.confidence) }
        if let lo = confidences.min(), let hi = confidences.max() {
            r.confidenceRange = lo == hi ? "\(lo)" : "\(lo)–\(hi)"
        }
        r.proposalsCarryingADecision = stored.reduce(0) { partial, review in
            partial + review.proposals.filter { $0.decision != nil }.count
        }

        // MARK: Pairing, by run time

        // KEYED BY `ranUTC`, WHICH IS WHAT THE IMPORTER LOOKS UP. A collision
        // is reported rather than resolved: `uniquingKeysWith` would keep one
        // silently and the count of compared reviews would quietly stop
        // matching the count in the app.
        var mine: [String: ProposalStore.Record] = [:]
        for record in storeRecords {
            let key = Sub4Import.iso8601(record.ranAt)
            if mine[key] != nil {
                r.duplicateRunTimes.append("two app records ran at \(key)")
            } else {
                mine[key] = record
            }
        }
        let theirs = Dictionary(stored.map { ($0.ranUTC, $0) },
                                uniquingKeysWith: { a, _ in a })

        let mineKeys = Set(mine.keys)
        let theirKeys = Set(theirs.keys)
        r.reviewsOnlyInApp = mineKeys.subtracting(theirKeys).sorted()
        r.reviewsOnlyInDatabase = theirKeys.subtracting(mineKeys).sorted()

        for key in mineKeys.intersection(theirKeys).sorted() {
            guard let a = mine[key], let b = theirs[key] else { continue }
            r.reviewsCompared += 1
            compareReview(key: key, app: a, database: b,
                          planSessionUIDs: database.planSessionUIDs, into: &r)
        }

        return r
    }

    // MARK: One review

    private static func compareReview(key: String,
                                      app a: ProposalStore.Record,
                                      database b: ReviewTrailLoad.StoredReview,
                                      planSessionUIDs: Set<String>,
                                      into r: inout Report) {
        let tag = "review \(key)"

        // FIVE FIELDS, AND THE 5 IS WRITTEN BESIDE THE FIVE LINES rather than
        // accumulated by a helper. See the comparators below: 326 lost a build
        // to two `inout` arguments derived from the same `Report`, and this
        // shape has no `inout` in it at all.
        //
        // `provider` is compared against the constant the importer writes, not
        // against anything on the record — §12.63.8: compare what the writer
        // draws, not the field it came from. There is no field it came from.
        //
        // `Optional(...)` on the app side, deliberately and not incidentally:
        // both of those columns are nullable and both record fields are not, so
        // the comparison has to be able to see a NULL as a difference rather
        // than coalesce it away.
        r.reviewFieldsCompared += 5
        r.reviewDifferences += [
            diff("\(tag) · window start", a.startDay, b.windowStartDayKey),
            diff("\(tag) · window end", a.endDay, b.windowEndDayKey),
            diff("\(tag) · provider", Sub4Import.reviewProvider, b.provider),
            diff("\(tag) · model", Optional(a.model), b.model),
            diff("\(tag) · appVersion", Optional(a.appVersion), b.appVersion)
        ].compactMap { $0 }

        compareEvidence(tag: tag, app: a, database: b, into: &r)
        compareProposals(tag: tag, app: a, database: b,
                         planSessionUIDs: planSessionUIDs, into: &r)
    }

    // MARK: Evidence — one row, and the count is the check

    private static func compareEvidence(tag: String,
                                        app a: ProposalStore.Record,
                                        database b: ReviewTrailLoad.StoredReview,
                                        into r: inout Report) {
        // The app holds ONE pack. More than one evidence row means something
        // wrote a decomposition nothing on this side can produce, and pairing
        // by position would compare the pack against whichever came first.
        guard b.evidence.count == 1 else {
            r.evidenceDifferences.append(
                "\(tag) · \(b.evidence.count) evidence rows, expected 1")
            return
        }
        let e = b.evidence[0]
        r.evidenceCompared += 1
        r.evidenceFieldsCompared += 4
        r.evidenceDifferences += [
            diff("\(tag) · evidence sectionKey", "pack", e.sectionKey),
            diff("\(tag) · evidence title", a.windowLabel, e.title),
            // LENGTHS, NEVER VALUES. See the header — this field is the entire
            // evidence pack.
            lengthDiff("\(tag) · evidence body", a.evidence, e.body),
            diff("\(tag) · evidence wasSent", true, e.wasSent)
        ].compactMap { $0 }
    }

    // MARK: Proposals, changes and watch items

    private static func compareProposals(tag: String,
                                         app a: ProposalStore.Record,
                                         database b: ReviewTrailLoad.StoredReview,
                                         planSessionUIDs: Set<String>,
                                         into r: inout Report) {
        guard b.proposals.count == 1 else {
            r.proposalDifferences.append(
                "\(tag) · \(b.proposals.count) proposals, expected 1")
            return
        }
        let p = a.proposal
        let q = b.proposals[0]
        r.proposalsCompared += 1
        r.proposalFieldsCompared += 5
        r.proposalDifferences += [
            diff("\(tag) · verdict", p.verdict.rawValue, q.verdict),
            // PROSE, BOTH OF THEM. Lengths only.
            lengthDiff("\(tag) · summary", p.summary, q.summary),
            lengthDiff("\(tag) · reasoning", p.reasoning, q.reasoning),
            diff("\(tag) · confidence", Optional(p.confidence), q.confidence),
            // DERIVED, NOT STORED: the importer writes the review's run time
            // into `receivedUTC`. Compared against that rather than against a
            // field, because there is no field — the app never records when the
            // answer came back separately from when the review ran.
            diff("\(tag) · receivedUTC", b.ranUTC, q.receivedUTC)
        ].compactMap { $0 }

        // MARK: Changes, by ordinal

        guard p.changes.count == q.changes.count else {
            r.changeDifferences.append(
                "\(tag) · \(p.changes.count) changes in the app, "
                + "\(q.changes.count) in the database")
            return
        }
        for (i, change) in p.changes.enumerated() {
            let stored = q.changes[i]
            let ctag = "\(tag) · change \(i)"
            r.changesCompared += 1
            r.changeFieldsCompared += 6

            if stored.ordinal != i {
                r.changeDifferences.append("\(ctag) · ordinal is \(stored.ordinal)")
            }

            r.changeDifferences += [
                diff("\(ctag) · planSessionUID",
                     change.sessionUid, stored.planSessionUID),
                // §12.43: the importer's own derivation, called.
                diff("\(ctag) · what",
                     Sub4Import.changeSummary(change), stored.what),
                diff("\(ctag) · why", Optional(change.reason), stored.why),
                // `?? ""` WOULD HAVE HIDDEN THE ONE CASE WORTH SEEING. The
                // column is nullable and the field is not, so the importer
                // writes an empty string for a skip and never NULL. A NULL here
                // means something other than this importer wrote the row, and
                // coalescing it would compare "" against "" and agree.
                nullableLengthDiff("\(ctag) · newDetail",
                                   change.newDetail, stored.newDetail),
                diff("\(ctag) · isSkip", Optional(change.skip), stored.isSkip),
                diff("\(ctag) · evidence",
                     Optional(change.evidence), stored.evidence)
            ].compactMap { $0 }

            // THE RESOLVE. Counted, not reported as a difference of its own —
            // it reaches `unexplained` through the subtraction, so an
            // unresolved uid is red exactly once.
            if planSessionUIDs.contains(stored.planSessionUID) {
                r.changesNamingAKnownSession += 1
            }
        }

        // MARK: Watch items, by ordinal

        guard p.watchFor.count == q.watch.count else {
            r.watchDifferences.append(
                "\(tag) · \(p.watchFor.count) watch items in the app, "
                + "\(q.watch.count) in the database")
            return
        }
        for (i, text) in p.watchFor.enumerated() {
            r.watchCompared += 1
            // Model prose about the athlete. Length only, like the rest.
            if let d = lengthDiff("\(tag) · watch \(i)", text, q.watch[i]) {
                r.watchDifferences.append(d)
            }
        }
    }

    // MARK: Comparators
    //
    // NO `inout`, ANYWHERE. 326 shipped a helper that took `into r: inout
    // Report` alongside `count: inout Int`, and every call site passed
    // `&r.productsCompared` beside `&r` — seven overlapping-access errors and
    // the first build failure `scripts/test.sh` ever reported. These return a
    // difference or nil, the caller appends, and the field count is a literal
    // written beside the literal list of fields it counts. There is nothing
    // left to alias.

    /// For values that are safe to have compared but must never be printed —
    /// the line carries the FIELD only. Identifiers, booleans, integers and day
    /// keys, none of which is content.
    private static func diff<T: Equatable>(_ label: String,
                                           _ a: T, _ b: T) -> String? {
        a == b ? nil : label
    }

    /// For anything that could be prose. A length difference says truncation;
    /// equal lengths with a difference says substitution. Both are actionable
    /// and neither discloses a character of the text.
    private static func lengthDiff(_ label: String,
                                   _ a: String, _ b: String) -> String? {
        guard a != b else { return nil }
        return a.count == b.count
            ? "\(label) (same length, \(a.count) chars, different text)"
            : "\(label) (app \(a.count) chars, database \(b.count))"
    }

    /// The same, for a nullable column whose app-side field is not optional.
    /// A NULL is its own message rather than an empty string.
    private static func nullableLengthDiff(_ label: String,
                                           _ a: String, _ b: String?) -> String? {
        guard let b else { return "\(label) is NULL in the database" }
        return lengthDiff(label, a, b)
    }
}

// MARK: - The reader

nonisolated enum ReviewRepository {

    static func load(_ db: Sub4Database) -> ReviewTrailLoad {
        do {
            return try db.queue.read { d -> ReviewTrailLoad in
                var skipped = 0
                var reviews: [ReviewTrailLoad.StoredReview] = []

                for row in try Row.fetchAll(d, sql: reviewSQL,
                                            arguments: [Sub4Import.accountID]) {
                    guard let id = row["id"] as String?,
                          let ranUTC = row["ranUTC"] as String?,
                          let start = row["windowStartDayKey"] as String?,
                          let end = row["windowEndDayKey"] as String?,
                          let provider = row["provider"] as String? else {
                        skipped += 1; continue
                    }
                    // HOISTED, not written inline as two arguments to one
                    // initialiser. Both take `&skipped`, and two `inout`
                    // accesses to the same variable inside one call expression
                    // is the shape 326 lost a build to. Sequential `let`s make
                    // the accesses obviously disjoint — the same shape
                    // `PlanExtrasRepository.load` uses for `readFuel` and
                    // `readWarmup`.
                    let evidence = try readEvidence(d, reviewID: id,
                                                    skipped: &skipped)
                    let proposals = try readProposals(d, reviewID: id,
                                                      skipped: &skipped)
                    reviews.append(ReviewTrailLoad.StoredReview(
                        id: id,
                        ranUTC: ranUTC,
                        windowStartDayKey: start,
                        windowEndDayKey: end,
                        provider: provider,
                        model: row["model"] as String?,
                        appVersion: row["appVersion"] as String?,
                        evidence: evidence,
                        proposals: proposals))
                }

                // ONE TRANSACTION for the uids too — see `ReviewTrailLoad.loaded`.
                let uids = try String.fetchSet(
                    d, sql: "SELECT DISTINCT uid FROM plan_session")
                let sourceRows = try Int.fetchOne(
                    d, sql: "SELECT COUNT(*) FROM review_evidence_source") ?? 0

                return .loaded(reviews: reviews,
                               planSessionUIDs: uids,
                               evidenceSourceRows: sourceRows,
                               skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: Evidence

    private static func readEvidence(_ d: Database,
                                     reviewID: String,
                                     skipped: inout Int)
                                     throws -> [ReviewTrailLoad.StoredEvidence] {
        var out: [ReviewTrailLoad.StoredEvidence] = []
        for row in try Row.fetchAll(d, sql: evidenceSQL, arguments: [reviewID]) {
            guard let id = row["id"] as String?,
                  let sectionKey = row["sectionKey"] as String?,
                  let title = row["title"] as String?,
                  let body = row["body"] as String?,
                  let wasSent = row["wasSent"] as Bool? else {
                skipped += 1; continue
            }
            let sources = try String.fetchAll(d, sql: evidenceSourceSQL,
                                              arguments: [id])
            out.append(ReviewTrailLoad.StoredEvidence(
                id: id, sectionKey: sectionKey, title: title, body: body,
                wasSent: wasSent, sourceIDs: sources))
        }
        return out
    }

    // MARK: Proposals

    private static func readProposals(_ d: Database,
                                      reviewID: String,
                                      skipped: inout Int)
                                      throws -> [ReviewTrailLoad.StoredProposal] {
        var out: [ReviewTrailLoad.StoredProposal] = []
        for row in try Row.fetchAll(d, sql: proposalSQL, arguments: [reviewID]) {
            guard let id = row["id"] as String?,
                  let verdict = row["verdict"] as String?,
                  let summary = row["summary"] as String?,
                  let reasoning = row["reasoning"] as String?,
                  let receivedUTC = row["receivedUTC"] as String? else {
                skipped += 1; continue
            }

            var changes: [ReviewTrailLoad.StoredChange] = []
            for c in try Row.fetchAll(d, sql: changeSQL, arguments: [id]) {
                guard let ordinal = c["ordinal"] as Int?,
                      let uid = c["planSessionUID"] as String?,
                      let what = c["what"] as String? else {
                    skipped += 1; continue
                }
                changes.append(ReviewTrailLoad.StoredChange(
                    ordinal: ordinal,
                    planSessionUID: uid,
                    what: what,
                    why: c["why"] as String?,
                    newDetail: c["newDetail"] as String?,
                    isSkip: c["isSkip"] as Bool?,
                    evidence: c["evidence"] as String?))
            }

            var watch: [String] = []
            for w in try Row.fetchAll(d, sql: watchSQL, arguments: [id]) {
                guard let text = w["text"] as String? else {
                    skipped += 1; continue
                }
                watch.append(text)
            }

            out.append(ReviewTrailLoad.StoredProposal(
                id: id, verdict: verdict, summary: summary,
                reasoning: reasoning,
                confidence: row["confidence"] as Int?,
                receivedUTC: receivedUTC,
                decision: row["decision"] as String?,
                decidedUTC: row["decidedUTC"] as String?,
                changes: changes, watch: watch))
        }
        return out
    }

    // MARK: SQL — every list ordered, because every list is a sequence

    private static let reviewSQL = """
        SELECT id, ranUTC, windowStartDayKey, windowEndDayKey,
               provider, model, appVersion
          FROM review WHERE accountID = ? ORDER BY ranUTC
        """

    private static let evidenceSQL = """
        SELECT id, sectionKey, title, body, wasSent
          FROM review_evidence WHERE reviewID = ? ORDER BY sectionKey
        """

    private static let evidenceSourceSQL = """
        SELECT sourceID FROM review_evidence_source
         WHERE evidenceID = ? ORDER BY sourceID
        """

    /// `proposal` carries no ordinal — one per review is the only shape the
    /// writer produces. Ordered by `receivedUTC` then `id` so that a second one
    /// arriving would at least be reported in a stable order rather than
    /// whichever SQLite happened to return first.
    private static let proposalSQL = """
        SELECT id, verdict, summary, reasoning, confidence,
               receivedUTC, decision, decidedUTC
          FROM proposal WHERE reviewID = ? ORDER BY receivedUTC, id
        """

    private static let changeSQL = """
        SELECT ordinal, planSessionUID, what, why, newDetail, isSkip, evidence
          FROM proposal_change WHERE proposalID = ? ORDER BY ordinal
        """

    private static let watchSQL = """
        SELECT ordinal, text FROM proposal_watch
         WHERE proposalID = ? ORDER BY ordinal
        """
}
