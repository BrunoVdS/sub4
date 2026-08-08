//
//  PlanRepository.swift
//  Sub4
//
//  The plan, read back out — D6c slice 6b, ADR-0003 §12.66.
//
//  WHAT THIS IS FOR
//  ----------------
//  Sixth repository, and the one that closes a sentence two other screens have
//  been carrying. `LoadParity` says it holds "sRPE given the plan"; `MatchParity`
//  says it holds "the plan, the match decisions and the commute decisions".
//  Both of those caveats exist because nothing had ever read `plan_session`
//  back. This does, and both lines shorten.
//
//  THE PLAN IS READ-ONLY AT RUNTIME, WHICH MAKES THIS A DIFFERENT CLAIM.
//  `plan.json` ships in the bundle and is replaced wholesale on app update, so
//  unlike the athlete's constants or the notes, the app cannot have drifted
//  from the database by writing. What can have drifted is the IMPORT: 260
//  sessions decomposed across six tables and reassembled here. A difference is
//  a decomposition that does not invert.
//
//  THE ACTIVE VERSION, AND WHY THE RAW COUNTS ARE PRINTED BESIDE IT
//  ---------------------------------------------------------------
//  `plan_session` holds 780 rows. The app holds 260 sessions. Both are correct:
//  three `plan_version` rows exist, each a full import of the same content, and
//  a partial unique index makes at most one of them active. Every plan table
//  divides by three exactly — 111 weeks, 552 stats, 780 sessions, 246 details,
//  1902 blocks — which is the arithmetic saying so.
//
//  So this reads the ACTIVE version and reports both numbers. "260 compared"
//  beside a table holding 780 reads as data loss to anyone who does not already
//  know why; "260 of 780 rows, in the active version of three" does not. That
//  is §12.15 applied to a denominator rather than to an error.
//
//  "AT MOST ONE ACTIVE" IS PER PLAN, NOT PER DATABASE
//  --------------------------------------------------
//  `plan_version_one_active` is `UNIQUE(planID) WHERE activatedUTC IS NOT NULL`.
//  Read quickly that says one active version exists. It says one active version
//  exists PER PLAN — and `Sub4Import.upsertPlan` keys the `plan` row on
//  `(week1Monday, raceDate)`, so moving the race date mints a second plan.
//  `activate` then clears the flag `WHERE planID = ?`, leaving the first plan's
//  version active as well.
//
//  Today the device holds one plan and three versions of it, so a bare
//  `fetchOne` would have worked and kept working until the day the race moved.
//  It would then have picked one of two silently. So this counts them and
//  refuses rather than guessing — §12.15 again, and §12.60.1's rule about not
//  reasoning by analogy over two numbers without checking whether one
//  determines the other.
//
//  THE CANONICAL-ID TRAP, FOR THE FOURTH TIME
//  ------------------------------------------
//  `Session.weekUid` is the plan's own week identifier — "w14". The column
//  `plan_session.planWeekID` is a UUID row id and is NOT that. A reader that
//  returned the column would hand back a uid matching no week in the app, and
//  every session would report a `weekUid` difference while the data was
//  perfectly intact. So this joins `plan_week` and returns `w.uid`.
//
//  Fourth instance: `gearId` at 289, athlete provenance at 317,
//  `correction.subjectID` at 322, this. The rule has not changed — **any column
//  referencing another table holds that table's canonical id, and every store
//  keys by the source's.** This one is the most inviting of the four, because
//  the column is spelled with "ID" and the field is spelled with "Uid" and they
//  are two different things one letter apart.
//
//  A ROW THIS READER DECLINES, AND THE SHAPE 322b LEFT BEHIND
//  ----------------------------------------------------------
//  `discipline` and `intensity` are frozen vocabularies with CHECK constraints,
//  exactly like `user_note.feel`. An unrecognised value is a row this reader
//  cannot reconstitute, and it is skipped and counted rather than mapped to
//  `.other` — `Discipline.init(from:)` maps unknown to `.other` when DECODING
//  THE BUNDLED FILE, which is right there and wrong here. There it keeps a new
//  plan loading; here it would turn a schema drift into a silent data change.
//
//  As at 322b, the constraint means the state cannot arise from this schema, so
//  the test that covers it forces the row past the check. See
//  `PlanRepositoryTests.forceUnknownDiscipline`.
//
//  WHAT THIS DOES NOT COVER
//  ------------------------
//  `plan_exercise`, the five fuel tables and the four warm-up tables — about
//  150 rows across ten tables. They are drawn on screens and feed no
//  derivation, so they change nothing about what "held from the app" means.
//  That is slice 6c.
//

import Foundation
import GRDB

// MARK: - What the read produced

nonisolated enum PlanLoad: Sendable {

    case loaded(meta: Meta,
                weeks: [Week],
                sessions: [Session],
                version: VersionNote,
                rows: TableRows,
                skipped: Int)

    /// THREE VERSIONS AND NONE ACTIVE IS NOT AN EMPTY PLAN. The partial unique
    /// index allows zero active versions as well as one, so this is a state the
    /// schema permits and the reader has to be able to name. Without it, a plan
    /// that imported but never activated would read identically to a device
    /// where the import never ran — §12.15, eleventh instance.
    case noActiveVersion(versionsPresent: Int)

    /// TWO PLANS, EACH WITH AN ACTIVE VERSION. Permitted by the schema — see
    /// the header — and there is no rule anywhere saying which one the app is
    /// running. Naming it is the only honest answer; picking one would make the
    /// whole comparison a coin toss nobody could see being flipped.
    case ambiguousActiveVersion(activeCount: Int, plansPresent: Int)

    case unavailable
    case failed(String)

    /// Which import the records came from, printed rather than compared: the
    /// app holds no notion of a version, so there is nothing on the other side.
    struct VersionNote: Sendable {
        let sourceLabel: String
        let importedUTC: String
        let versionsPresent: Int
    }

    /// The raw table totals, ACROSS ALL VERSIONS. Printed beside the compared
    /// counts so the three-to-one ratio is visible instead of surprising.
    struct TableRows: Sendable {
        var plans = 0
        var versions = 0
        var weeks = 0
        var weekStats = 0
        var sessions = 0
        var details = 0
        var blocks = 0
    }

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Nil rather than `[]` on every unhappy path — a caller must not reach the
    /// comparison without deciding what the absence means.
    var weeks: [Week]? {
        if case .loaded(_, let w, _, _, _, _) = self { return w }
        return nil
    }

    var sessions: [Session]? {
        if case .loaded(_, _, let s, _, _, _) = self { return s }
        return nil
    }

    var meta: Meta? {
        if case .loaded(let m, _, _, _, _, _) = self { return m }
        return nil
    }

    var version: VersionNote? {
        if case .loaded(_, _, _, let v, _, _) = self { return v }
        return nil
    }

    var rows: TableRows {
        if case .loaded(_, _, _, _, let r, _) = self { return r }
        return TableRows()
    }

    var skipped: Int {
        if case .loaded(_, _, _, _, _, let s) = self { return s }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(_, let w, let s, let v, let rows, let skipped):
            let base = "\(w.count) weeks, \(s.count) sessions "
                     + "from \(v.sourceLabel); "
                     + "\(rows.sessions) session rows in \(v.versionsPresent) "
                     + "versions."
            return skipped == 0 ? base : base + " \(skipped) rows could not be read."
        case .noActiveVersion(let n):
            return n == 0
                ? "No plan has been imported."
                : "\(n) plan versions are stored and none is active."
        case .ambiguousActiveVersion(let active, let plans):
            return "\(active) versions are active across \(plans) plans — "
                 + "the schema allows one per plan, so nothing here can say "
                 + "which plan the app is running."
        case .unavailable: return "The database is not open."
        case .failed(let why): return "The database could not be read — \(why)"
        }
    }
}

// MARK: - The comparison

nonisolated enum PlanRoundTrip {

    /// GROUNDWORK §5's LIST — **and this round trip has no entries on it.**
    ///
    /// Every field of `Week`, `Session`, `SessionDetail`, `Block` and `Meta`
    /// has a column, and every column is written. So there is no list here, and
    /// deliberately not an empty one: `AthleteRoundTrip` and `AuthoredRoundTrip`
    /// have each declared their own `ApprovedDifference` struct, which is
    /// already two declarations of one idea, and a third — holding nothing —
    /// would be a type written in anticipation. 321 deleted a forwarder for
    /// that reason and this follows it.
    ///
    /// The screen and the paste still say **"approved differences: none"**,
    /// because the absence has to be visible: a reader who sees no such line
    /// cannot tell "nothing needed approving" from "nobody looked". §12.54.2.
    ///
    /// **The two existing declarations should become one.** That is a change to
    /// two shipped files for no behavioural gain, so it does not belong inside
    /// a slice patch; recorded in §12.66.5 so it is a decision rather than an
    /// oversight.
    static let approvedNote = "none"

    struct Report: Sendable {

        // MARK: Denominators

        var versionsPresent = 0
        var activeVersion = "—"

        var metaFieldsCompared = 0
        var metaDifferences: [String] = []

        var weeksInApp = 0
        var weeksInDatabase = 0
        var weeksCompared = 0
        /// Nine per week — every field but `uid`, which is the key.
        var weekFieldsCompared = 0
        /// The document's own weekly totals, key by key. A separate denominator
        /// because `Week.stats` is a dictionary: equal counts prove nothing
        /// about equal contents, and an empty stats block on both sides would
        /// otherwise be indistinguishable from a compared one.
        var weekStatsCompared = 0

        var sessionsInApp = 0
        var sessionsInDatabase = 0
        var sessionsCompared = 0
        /// Eleven per session — ten fields plus which of the two detail
        /// properties held the breakdown.
        var sessionFieldsCompared = 0

        var breakdownsInApp = 0
        var breakdownsInDatabase = 0
        var breakdownsCompared = 0
        var breakdownFieldsCompared = 0
        var blocksCompared = 0
        /// Four per block.
        var blockFieldsCompared = 0

        /// The raw table totals across all versions, so the ratio is on screen.
        var rowsInTable = PlanLoad.TableRows()
        var rowsSkipped = 0

        // MARK: Differences, named

        var weeksOnlyInApp: [String] = []
        var weeksOnlyInDatabase: [String] = []
        /// "w14 · badge"
        var weekDifferences: [String] = []
        /// "w14 · stat runKm"
        var weekStatDifferences: [String] = []

        var sessionsOnlyInApp: [String] = []
        var sessionsOnlyInDatabase: [String] = []
        /// "s-w14-sat · intensity"
        var sessionDifferences: [String] = []
        /// "s-w03-tue · block 2 · title"
        var blockDifferences: [String] = []

        // MARK: Context, printed rather than asserted

        /// Sessions the plan gives a calendar date. The prologue weeks P1–P3
        /// are logged history and carry none, so this being short of the total
        /// is correct — §6, absent rather than zero.
        var appSessionsWithADate = 0
        var databaseSessionsWithADate = 0

        /// Sessions carrying the plan's own fuelling line. 180 of them, and the
        /// ones without are strength, rest, travel and walks.
        var appSessionsWithFuel = 0
        var databaseSessionsWithFuel = 0

        var totalCompared: Int { weeksCompared + sessionsCompared }

        var unexplained: Int {
            metaDifferences.count
            + weeksOnlyInApp.count + weeksOnlyInDatabase.count
            + weekDifferences.count + weekStatDifferences.count
            + sessionsOnlyInApp.count + sessionsOnlyInDatabase.count
            + sessionDifferences.count + blockDifferences.count
            + rowsSkipped
        }

        /// A plan with no weeks and no sessions is not a plan. Unlike the
        /// authored tables, where an empty side is a real state, both halves
        /// here are always populated on any device that has launched — so zero
        /// compared is a failure rather than a quiet pass.
        var lookedAtSomething: Bool { weeksCompared > 0 && sessionsCompared > 0 }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else { return "nothing compared" }
            return unexplained == 0
                ? "\(totalCompared) compared · no differences"
                : "\(totalCompared) compared · \(unexplained) differences"
        }

        var datedLine: String {
            "\(appSessionsWithADate) vs \(databaseSessionsWithADate)"
        }

        var fuelLine: String {
            "\(appSessionsWithFuel) vs \(databaseSessionsWithFuel)"
        }

        /// The ratio, stated rather than left to be worked out.
        var versionLine: String {
            "\(sessionsCompared) of \(rowsInTable.sessions) rows · "
            + "\(versionsPresent) versions"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        ///
        /// SAFE TO PASTE. The plan is bundled content, not anything the athlete
        /// wrote, so unlike the authored read-back there is nothing here to
        /// withhold. What is printed is uids and field names regardless.
        var diagnosticLines: [String] {
            var lines = [
                "Plan read-back: \(totalCompared) compared",
                "  active version: \(activeVersion)",
                "  versions stored: \(versionsPresent)",
                "  meta fields compared: \(metaFieldsCompared)",
                "  meta fields that differ: \(metaDifferences.count)",
                "  weeks in the app: \(weeksInApp)",
                "  weeks in the database: \(weeksInDatabase)",
                "  weeks compared: \(weeksCompared)",
                "  week fields compared: \(weekFieldsCompared)",
                "  week stats compared: \(weekStatsCompared)",
                "  weeks only in the app: \(weeksOnlyInApp.count)",
                "  weeks only in the database: \(weeksOnlyInDatabase.count)",
                "  week fields that differ: \(weekDifferences.count)",
                "  week stats that differ: \(weekStatDifferences.count)",
                "  sessions in the app: \(sessionsInApp)",
                "  sessions in the database: \(sessionsInDatabase)",
                "  sessions compared: \(sessionsCompared)",
                "  session fields compared: \(sessionFieldsCompared)",
                "  sessions only in the app: \(sessionsOnlyInApp.count)",
                "  sessions only in the database: \(sessionsOnlyInDatabase.count)",
                "  session fields that differ: \(sessionDifferences.count)",
                "  sessions carrying a date: \(datedLine)",
                "  sessions carrying a fuelling line: \(fuelLine)",
                "  breakdowns in each side: "
                + "\(breakdownsInApp) vs \(breakdownsInDatabase)",
                "  breakdowns compared: \(breakdownsCompared)",
                "  breakdown fields compared: \(breakdownFieldsCompared)",
                "  blocks compared: \(blocksCompared)",
                "  block fields compared: \(blockFieldsCompared)",
                "  blocks that differ: \(blockDifferences.count)",
                "  plans stored: \(rowsInTable.plans)",
                "  rows in the tables, all versions: "
                + "\(rowsInTable.weeks) weeks, \(rowsInTable.weekStats) stats, "
                + "\(rowsInTable.sessions) sessions, \(rowsInTable.details) "
                + "breakdowns, \(rowsInTable.blocks) blocks",
                "  rows the reader could not read: \(rowsSkipped)",
                "  approved differences: \(PlanRoundTrip.approvedNote)",
                "  unexplained differences: \(unexplained)"]
            for d in metaDifferences { lines.append("    \(d)") }
            for d in weekDifferences.prefix(6) { lines.append("    \(d)") }
            if weekDifferences.count > 6 {
                lines.append("    + \(weekDifferences.count - 6) more weeks")
            }
            for d in weekStatDifferences.prefix(6) { lines.append("    \(d)") }
            for d in sessionDifferences.prefix(8) { lines.append("    \(d)") }
            if sessionDifferences.count > 8 {
                lines.append("    + \(sessionDifferences.count - 8) more sessions")
            }
            for d in blockDifferences.prefix(6) { lines.append("    \(d)") }
            if blockDifferences.count > 6 {
                lines.append("    + \(blockDifferences.count - 6) more blocks")
            }
            return lines
        }
    }

    /// EVERY STORED FIELD, NAMED — the same argument
    /// `ActivityRoundTrip.differingFields` and `AuthoredRoundTrip.compare` make.
    /// There is no reflection here that would not also silently skip something.
    static func compare(storeMeta: Meta,
                        storeWeeks: [Week],
                        storeSessions: [Session],
                        database: PlanLoad) -> Report {

        var r = Report()
        r.weeksInApp = storeWeeks.count
        r.sessionsInApp = storeSessions.count
        r.appSessionsWithADate = storeSessions.filter { $0.date != nil }.count
        r.appSessionsWithFuel = storeSessions.filter { $0.fuel != nil }.count
        r.breakdownsInApp = storeSessions.filter { $0.breakdown != nil }.count

        switch database {
        case .noActiveVersion(let n):
            r.versionsPresent = n
        case .ambiguousActiveVersion(let active, let plans):
            r.versionsPresent = active
            r.activeVersion = "ambiguous — \(active) active across \(plans) plans"
        default:
            break
        }

        guard case .loaded(let dbMeta, let dbWeeks, let dbSessions,
                           let version, let rows, let skipped) = database else {
            return r
        }

        r.weeksInDatabase = dbWeeks.count
        r.sessionsInDatabase = dbSessions.count
        r.databaseSessionsWithADate = dbSessions.filter { $0.date != nil }.count
        r.databaseSessionsWithFuel = dbSessions.filter { $0.fuel != nil }.count
        r.breakdownsInDatabase = dbSessions.filter { $0.breakdown != nil }.count
        r.activeVersion = version.sourceLabel
        r.versionsPresent = version.versionsPresent
        r.rowsInTable = rows
        r.rowsSkipped = skipped

        // MARK: The plan's own header

        func meta(_ name: String, _ same: Bool) {
            r.metaFieldsCompared += 1
            if !same { r.metaDifferences.append("meta · \(name)") }
        }
        meta("plan", storeMeta.plan == dbMeta.plan)
        meta("week1Monday", storeMeta.week1Monday == dbMeta.week1Monday)
        meta("raceDate", storeMeta.raceDate == dbMeta.raceDate)
        meta("targetTime", storeMeta.targetTime == dbMeta.targetTime)
        meta("targetPaceSecKm", storeMeta.targetPaceSecKm == dbMeta.targetPaceSecKm)

        // MARK: Weeks, by the plan's own uid

        let myWeeks = Dictionary(storeWeeks.map { ($0.uid, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let theirWeeks = Dictionary(dbWeeks.map { ($0.uid, $0) },
                                    uniquingKeysWith: { first, _ in first })

        // KEYS, NOT VALUES — §12.65.10. `Week` is `Hashable` and this would
        // compile either way; asking the keys is what the question actually is.
        let myWeekKeys = Set(myWeeks.keys)
        let theirWeekKeys = Set(theirWeeks.keys)
        r.weeksOnlyInApp = myWeekKeys.subtracting(theirWeekKeys).sorted()
        r.weeksOnlyInDatabase = theirWeekKeys.subtracting(myWeekKeys).sorted()

        for uid in myWeekKeys.intersection(theirWeekKeys).sorted() {
            guard let a = myWeeks[uid], let b = theirWeeks[uid] else { continue }
            r.weeksCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.weekFieldsCompared += 1
                if !same { r.weekDifferences.append("\(uid) · \(name)") }
            }
            check("weekNo", a.weekNo == b.weekNo)
            check("label", a.label == b.label)
            check("dateRange", a.dateRange == b.dateRange)
            check("startDate", a.startDate == b.startDate)
            check("tag", a.tag == b.tag)
            check("badge", a.badge == b.badge)
            check("kind", a.kind == b.kind)
            check("logged", a.logged == b.logged)
            check("stats count", a.stats.count == b.stats.count)

            // Key by key, both directions. A stat present on one side only is a
            // difference; so is the same key holding a different number.
            for key in Set(a.stats.keys).union(b.stats.keys).sorted() {
                r.weekStatsCompared += 1
                if a.stats[key] != b.stats[key] {
                    r.weekStatDifferences.append("\(uid) · stat \(key)")
                }
            }
        }

        // MARK: Sessions, by the plan's own uid

        let mySessions = Dictionary(storeSessions.map { ($0.uid, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let theirSessions = Dictionary(dbSessions.map { ($0.uid, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let myKeys = Set(mySessions.keys)
        let theirKeys = Set(theirSessions.keys)
        r.sessionsOnlyInApp = myKeys.subtracting(theirKeys).sorted()
        r.sessionsOnlyInDatabase = theirKeys.subtracting(myKeys).sorted()

        for uid in myKeys.intersection(theirKeys).sorted() {
            guard let a = mySessions[uid], let b = theirSessions[uid] else { continue }
            r.sessionsCompared += 1

            func check(_ name: String, _ same: Bool) {
                r.sessionFieldsCompared += 1
                if !same { r.sessionDifferences.append("\(uid) · \(name)") }
            }
            // THE ONE THE CANONICAL-ID TRAP WOULD HAVE BROKEN, first.
            check("weekUid", a.weekUid == b.weekUid)
            check("day", a.day == b.day)
            check("date", a.date == b.date)
            check("discipline", a.discipline == b.discipline)
            check("intensity", a.intensity == b.intensity)
            check("title", a.title == b.title)
            check("detail", a.detail == b.detail)
            check("fuel", a.fuel == b.fuel)
            check("prep", a.prep == b.prep)
            check("seq", a.seq == b.seq)

            // WHICH FIELD HELD THE BREAKDOWN, not just whether one did.
            // `breakdown` is `swimDetail ?? strengthDetail`, so a reader that
            // put a strength breakdown into `swimDetail` would compare equal on
            // every block and still be wrong — the session would draw as a swim.
            check("breakdown kind", kind(a) == kind(b))

            compareBreakdown(uid: uid, a.breakdown, b.breakdown, into: &r)
        }

        return r
    }

    /// "swim", "strength" or "none" — the property that held it, which is the
    /// thing `kind` exists in the schema to preserve.
    private static func kind(_ s: Session) -> String {
        if s.swimDetail != nil { return "swim" }
        if s.strengthDetail != nil { return "strength" }
        return "none"
    }

    private static func compareBreakdown(uid: String,
                                         _ a: SessionDetail?,
                                         _ b: SessionDetail?,
                                         into r: inout Report) {
        guard let a, let b else {
            // One side has a breakdown and the other does not. Already caught
            // by "breakdown kind" above; not double-counted here.
            return
        }
        r.breakdownsCompared += 1

        func check(_ name: String, _ same: Bool) {
            r.breakdownFieldsCompared += 1
            if !same { r.sessionDifferences.append("\(uid) · breakdown \(name)") }
        }
        check("total", a.total == b.total)
        check("tag", a.tag == b.tag)
        check("focus", a.focus == b.focus)
        check("block count", a.blocks.count == b.blocks.count)

        // BY ORDINAL, which is why the column exists. The blocks are a sequence
        // — "Warm-up" then "Back squat" then "Cool-down" — and a set comparison
        // would call a shuffled session identical.
        for i in 0..<min(a.blocks.count, b.blocks.count) {
            let x = a.blocks[i], y = b.blocks[i]
            func field(_ name: String, _ same: Bool) {
                r.blockFieldsCompared += 1
                if !same { r.blockDifferences.append("\(uid) · block \(i) · \(name)") }
            }
            r.blocksCompared += 1
            field("duration", x.d == y.d)
            field("title", x.t == y.t)
            field("cue", x.x == y.x)
            field("videoURL", x.u == y.u)
        }
    }
}

// MARK: - The reader

nonisolated enum PlanRepository {

    // MARK: The active version, resolved once — §12.43

    /// WHICH VERSION EVERY PLAN READER WORKS FROM.
    ///
    /// Extracted at 326 so `PlanExtrasRepository` calls it rather than writing
    /// the query again. §12.43: do not reimplement, call. Two copies of this
    /// would be two places to remember that "at most one active" is per PLAN
    /// and not per table — §12.66.3 — and the second copy is exactly where that
    /// would be forgotten.
    nonisolated enum ActiveVersion: Sendable {
        case one(id: String, planID: String,
                 sourceLabel: String, importedUTC: String,
                 versionsPresent: Int)
        case none(versionsPresent: Int)
        case ambiguous(activeCount: Int, plansPresent: Int)
        case malformed(String)
    }

    static func activeVersion(_ d: Database) throws -> ActiveVersion {
        let versionsPresent = try count(d, "plan_version")

        // ALL OF THEM, THEN COUNTED. `fetchOne` would be a silent choice
        // between two plans' active versions — §12.66.3.
        let active = try Row.fetchAll(d, sql: activeVersionSQL)
        guard let v = active.first else {
            return .none(versionsPresent: versionsPresent)
        }
        guard active.count == 1 else {
            return .ambiguous(activeCount: active.count,
                              plansPresent: try count(d, "plan"))
        }
        guard let id = v["id"] as String?,
              let planID = v["planID"] as String?,
              let sourceLabel = v["sourceLabel"] as String?,
              let importedUTC = v["importedUTC"] as String? else {
            return .malformed("the active plan version is missing a column")
        }
        return .one(id: id, planID: planID, sourceLabel: sourceLabel,
                    importedUTC: importedUTC, versionsPresent: versionsPresent)
    }

    static func load(_ db: Sub4Database) -> PlanLoad {
        do {
            return try db.queue.read { d -> PlanLoad in

                // The raw totals first, across every version, so they are on
                // the report even when the active-version read finds nothing.
                var rows = PlanLoad.TableRows()
                rows.weeks = try count(d, "plan_week")
                rows.weekStats = try count(d, "plan_week_stat")
                rows.sessions = try count(d, "plan_session")
                rows.details = try count(d, "plan_session_detail")
                rows.blocks = try count(d, "plan_session_block")
                rows.plans = try count(d, "plan")
                rows.versions = try count(d, "plan_version")

                let versionsPresent = rows.versions

                // ONE COPY OF THIS QUESTION, CALLED — §12.43.
                let versionID: String, planID: String
                let sourceLabel: String, importedUTC: String
                switch try activeVersion(d) {
                case .one(let id, let plan, let label, let imported, _):
                    versionID = id; planID = plan
                    sourceLabel = label; importedUTC = imported
                case .none:
                    return .noActiveVersion(versionsPresent: versionsPresent)
                case .ambiguous(let activeCount, let plansPresent):
                    return .ambiguousActiveVersion(activeCount: activeCount,
                                                   plansPresent: plansPresent)
                case .malformed(let why):
                    return .failed(why)
                }

                guard let p = try Row.fetchOne(d, sql: planSQL, arguments: [planID]),
                      let name = p["name"] as String?,
                      let week1 = p["week1Monday"] as String?,
                      let raceDate = p["raceDate"] as String?,
                      let targetTime = p["targetTime"] as String?,
                      let pace = p["targetPaceSecKm"] as Int? else {
                    return .failed("the active version names a plan row that is "
                                 + "not there or is missing a column")
                }
                let meta = Meta(plan: name, week1Monday: week1,
                                raceDate: raceDate, targetTime: targetTime,
                                targetPaceSecKm: pace)

                var skipped = 0

                // MARK: Weeks and their stats

                var statsByWeekID: [String: [String: Double]] = [:]
                for row in try Row.fetchAll(d, sql: weekStatSQL,
                                            arguments: [versionID]) {
                    guard let weekID = row["planWeekID"] as String?,
                          let key = row["key"] as String?,
                          let value = row["value"] as Double? else {
                        skipped += 1; continue
                    }
                    statsByWeekID[weekID, default: [:]][key] = value
                }

                var weeks: [Week] = []
                for row in try Row.fetchAll(d, sql: weekSQL, arguments: [versionID]) {
                    guard let id = row["id"] as String?,
                          let uid = row["uid"] as String?,
                          let label = row["label"] as String?,
                          let logged = row["logged"] as Bool? else {
                        skipped += 1; continue
                    }
                    weeks.append(Week(uid: uid,
                                      weekNo: row["weekNo"] as Int?,
                                      label: label,
                                      dateRange: row["dateRange"] as String?,
                                      startDate: row["startDate"] as String?,
                                      tag: row["tag"] as String?,
                                      badge: row["badge"] as String?,
                                      kind: row["kind"] as String?,
                                      logged: logged,
                                      stats: statsByWeekID[id] ?? [:]))
                }

                // MARK: Breakdowns and their blocks, gathered before the sessions

                var blocksByDetailID: [String: [Block]] = [:]
                for row in try Row.fetchAll(d, sql: blockSQL, arguments: [versionID]) {
                    guard let detailID = row["detailID"] as String? else {
                        skipped += 1; continue
                    }
                    // ORDER BY ordinal in the SQL, so appending preserves it.
                    blocksByDetailID[detailID, default: []].append(
                        Block(d: row["duration"] as String?,
                              t: row["title"] as String?,
                              x: row["cue"] as String?,
                              u: row["videoURL"] as String?))
                }

                var detailBySessionUid: [String: (kind: String, detail: SessionDetail)] = [:]
                for row in try Row.fetchAll(d, sql: detailSQL, arguments: [versionID]) {
                    guard let sessionUid = row["sessionUid"] as String?,
                          let detailID = row["detailID"] as String?,
                          let kind = row["kind"] as String? else {
                        skipped += 1; continue
                    }
                    let detail = SessionDetail(total: row["total"] as String?,
                                               tag: row["tag"] as String?,
                                               focus: row["focus"] as String?,
                                               blocks: blocksByDetailID[detailID] ?? [])
                    detailBySessionUid[sessionUid] = (kind, detail)
                }

                // MARK: Sessions

                var sessions: [Session] = []
                for row in try Row.fetchAll(d, sql: sessionSQL, arguments: [versionID]) {
                    guard let uid = row["uid"] as String?,
                          // THE JOINED COLUMN, NOT `planWeekID` — see the header.
                          let weekUid = row["weekUid"] as String?,
                          let rawDiscipline = row["discipline"] as String?,
                          let seq = row["seq"] as Int? else {
                        skipped += 1; continue
                    }
                    // Frozen vocabularies. `Discipline(rawValue:)`, NOT
                    // `Discipline(from:)` — the decoder maps unknown to `.other`
                    // to keep a new bundled plan loading, and doing that here
                    // would turn a schema drift into a silent data change.
                    guard let discipline = Discipline(rawValue: rawDiscipline) else {
                        skipped += 1; continue
                    }
                    var intensity: Intensity?
                    if let raw = row["intensity"] as String? {
                        guard let i = Intensity(rawValue: raw) else {
                            skipped += 1; continue
                        }
                        intensity = i
                    }

                    let breakdown = detailBySessionUid[uid]
                    sessions.append(Session(
                        uid: uid,
                        weekUid: weekUid,
                        day: row["day"] as String?,
                        date: row["date"] as String?,
                        discipline: discipline,
                        intensity: intensity,
                        title: row["title"] as String?,
                        detail: row["detail"] as String?,
                        fuel: row["fuel"] as String?,
                        prep: row["prep"] as String?,
                        seq: seq,
                        swimDetail: breakdown?.kind == "swim" ? breakdown?.detail : nil,
                        strengthDetail: breakdown?.kind == "strength"
                            ? breakdown?.detail : nil))
                }

                return .loaded(meta: meta,
                               weeks: weeks,
                               sessions: sessions,
                               version: PlanLoad.VersionNote(
                                   sourceLabel: sourceLabel,
                                   importedUTC: importedUTC,
                                   versionsPresent: versionsPresent),
                               rows: rows,
                               skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Not private since 326 — `activeVersion` is called from
    /// `PlanExtrasRepository` and this is how it counts what it reports.
    static func count(_ d: Database, _ table: String) throws -> Int {
        // The table name is a literal from this file, never an argument.
        try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    /// The partial unique index `plan_version_one_active` makes "at most one"
    /// a property of the schema, so `fetchOne` is not a silent choice between
    /// candidates — there cannot be two.
    static let activeVersionSQL = """
        SELECT id, planID, sourceLabel, importedUTC
          FROM plan_version
         WHERE activatedUTC IS NOT NULL
        """

    private static let planSQL = """
        SELECT name, week1Monday, raceDate, targetTime, targetPaceSecKm
          FROM plan WHERE id = ?
        """

    private static let weekSQL = """
        SELECT id, uid, weekNo, label, startDate, dateRange, tag, badge,
               kind, logged
          FROM plan_week
         WHERE planVersionID = ?
         ORDER BY uid
        """

    private static let weekStatSQL = """
        SELECT planWeekID, key, value
          FROM plan_week_stat
         WHERE planWeekID IN (SELECT id FROM plan_week WHERE planVersionID = ?)
        """

    /// THE JOIN THAT UNDOES THE DECOMPOSITION. `s.planWeekID` is a UUID row id;
    /// `Session.weekUid` is the plan's own "w14". Returning the column instead
    /// of `w.uid` would report all 260 sessions as differing on `weekUid` while
    /// nothing at all was wrong with the data. §12.66.2.
    private static let sessionSQL = """
        SELECT s.uid          AS uid,
               w.uid          AS weekUid,
               s.day          AS day,
               s.date         AS date,
               s.discipline   AS discipline,
               s.intensity    AS intensity,
               s.title        AS title,
               s.detail       AS detail,
               s.fuel         AS fuel,
               s.prep         AS prep,
               s.seq          AS seq
          FROM plan_session s
          JOIN plan_week w ON w.id = s.planWeekID
         WHERE s.planVersionID = ?
         ORDER BY s.uid
        """

    private static let detailSQL = """
        SELECT s.uid AS sessionUid,
               d.id  AS detailID,
               d.kind, d.total, d.tag, d.focus
          FROM plan_session_detail d
          JOIN plan_session s ON s.id = d.planSessionID
         WHERE s.planVersionID = ?
        """

    private static let blockSQL = """
        SELECT d.id AS detailID,
               b.ordinal, b.duration, b.title, b.cue, b.videoURL
          FROM plan_session_block b
          JOIN plan_session_detail d ON d.id = b.planSessionDetailID
          JOIN plan_session s        ON s.id = d.planSessionID
         WHERE s.planVersionID = ?
         ORDER BY d.id, b.ordinal
        """
}
