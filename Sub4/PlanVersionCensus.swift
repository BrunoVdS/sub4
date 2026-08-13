//
//  PlanVersionCensus.swift
//  Sub4
//
//  Every stored plan version, counted and fingerprinted — patch 352,
//  ADR-0003 §12.97.
//
//  THE QUESTION THIS EXISTS TO ANSWER
//  ----------------------------------
//  On 13 August the device reported `plan_session: 1043` against a plan of 260
//  sessions, and the honest first reading of that is "the plan has been
//  imported four times and every row is a copy". It has not been, and they are
//  not. 1043 is 261 + 261 + 261 + 260 — four versions holding three different
//  plans, of which exactly one pair is a duplicate.
//
//  That answer was reconstructed from arithmetic and from this document's own
//  history, which is a bad way to reach a conclusion you are about to delete
//  rows on the strength of. A count that divides by four is not evidence that
//  four things are the same, and a count that does not divide by four is not
//  evidence about WHICH of them differ. This file is the evidence.
//
//  WHY A FINGERPRINT AND NOT `contentHash`
//  ---------------------------------------
//  `plan_version.contentHash` is SHA-256 over the decoded `Plan` re-encoded
//  with sorted keys — §12.11.3. `.sortedKeys` sorts object KEYS and does not
//  sort ARRAYS, and §12.93.3 is the patch where that mattered: the store was
//  hydrated from rows read `ORDER BY uid`, `plan.json` is in the plan's own
//  order, and the same 261 sessions hashed to a different value and minted a
//  second version. So `contentHash` answers "did these bytes arrive in this
//  order before", which is the right question for an IMPORTER and the wrong
//  one here. Two versions with different hashes may hold identical plans, and
//  that is precisely the case this file has to detect.
//
//  The fingerprint here is taken over the STORED ROWS, every column that is not
//  a row identity, sorted before hashing. It answers "do these two versions
//  hold the same training", which is the question a prune has to be right
//  about.
//
//  WHAT IT COVERS, AND WHAT IT DOES NOT — stated because a fingerprint that
//  quietly omits a table would call two different plans identical
//  --------------------------------------------------------------------------
//  Covered: `plan_week`, `plan_week_stat`, `plan_session`, `plan_session_detail`,
//  `plan_session_block`, `plan_exercise`. That is every week, every stat line,
//  every session, every swim and strength breakdown, every block inside them,
//  and the exercise library — the training, in full.
//
//  NOT covered: the ten fuelling and warm-up tables. They are three products,
//  seven targets, a five-step ladder, a race-day schema and a nine-step warm-up
//  — static advice that no plan revision in this project has ever touched, and
//  the read-back compares all of it for the active version on every launch. A
//  version whose training is identical and whose fuelling differs would be
//  called a twin here and is not one. That is a real hole, it is small, and it
//  is written down rather than papered over: `censusCovers` is the line the
//  paste prints so the reader knows what the verdict is about.
//
//  THE ROW IDENTITIES ARE DROPPED, AND THAT IS THE WHOLE TRICK
//  -----------------------------------------------------------
//  Every content row carries a fresh `UUID` per import, so hashing rows as they
//  come would give four different fingerprints for four identical plans. The
//  ids are dropped and the foreign keys are replaced by the thing they point
//  at: a week stat is keyed by its week's `uid` rather than by `planWeekID`, a
//  block by its session's `uid` rather than by `planSessionDetailID`. What
//  survives is what the plan says.
//
//  §12.43 — THE SQL IS NOT REWRITTEN HERE.
//  `weekSQL`, `weekStatSQL`, `sessionSQL`, `detailSQL` and `blockSQL` all take a
//  version id and all already live on `PlanRepository`. They stopped being
//  `private` at this patch so this file can call them. A second copy of those
//  five queries is a second place to be wrong about what a version contains,
//  and this file's only value is being right about that.
//
//  EVERY DECLARATION IN THE EXTENSION BELOW SAYS `nonisolated`, AND HAS TO —
//  patch 352a, and it is the same trap `SWIFT_DEFAULT_ACTOR_ISOLATION` has set
//  before. `nonisolated` on the type above governs the members declared in the
//  type's own braces; members added in an EXTENSION take the build setting's
//  default instead, which in this project is `MainActor`. So `read` was
//  main-actor isolated inside a `nonisolated` struct, and the three warnings
//  that produced all pointed at the callers rather than at the cause: the
//  prune calling it synchronously, and `ReadBacks.planVersions` calling it
//  from a detached task.
//
//  The rule, since this will not be the last extension in this project: an
//  extension does not inherit its type's isolation. Write it on each member.
//
//  SAFE TO PASTE. Uids, field names, counts and hashes. The plan is bundled
//  content — §12.7's promise is untouched.
//

import Foundation
import CryptoKit
import GRDB

// MARK: - The census

nonisolated struct PlanVersionCensus: Sendable, Equatable {

    /// One stored version, as the tables actually hold it.
    nonisolated struct Version: Sendable, Equatable {
        let id: String
        let planID: String
        let sourceLabel: String
        let importedUTC: String
        let contentHash: String
        let isActive: Bool
        let weeks: Int
        let weekStats: Int
        let sessions: Int
        let details: Int
        let blocks: Int
        let exercises: Int
        /// SHA-256 over every content row this version owns, identities
        /// stripped and the lines sorted. See the header.
        let fingerprint: String
        let sessionUIDs: Set<String>

        var short: String { String(id.prefix(8)) }

        var rowLine: String {
            "\(weeks) weeks, \(weekStats) stats, \(sessions) sessions, "
            + "\(details) breakdowns, \(blocks) blocks, \(exercises) exercises"
        }
    }

    /// Oldest import first. Deterministic, because the paste is read by
    /// somebody comparing it against yesterday's.
    var versions: [Version] = []

    /// Every session uid named by a stored `proposal_change`. §12.7 refuses to
    /// make that column a foreign key, so nothing in the schema stops a delete
    /// from orphaning one — which makes this the number a prune has to check.
    var referencedUIDs: Set<String> = []

    /// What `PlanRoundTrip` says the ACTIVE version holds. Supplied by the
    /// caller so the census can be checked against the reader rather than
    /// believed. Nil when the caller had no report to hand.
    var readerSessionCount: Int?

    /// §12.15 — a census that could not read must not read as a census that
    /// found nothing. Set means `versions` is empty because of this, not
    /// because the database is.
    var readFailure: String?

    /// What the fingerprint is taken over, printed rather than assumed.
    static let censusCovers =
        "weeks, stats, sessions, breakdowns, blocks and exercises; "
        + "not the fuelling plan or the warm-up"

    // MARK: Derived

    var activeVersion: Version? { versions.first(where: { $0.isActive }) }

    var activeCount: Int { versions.filter({ $0.isActive }).count }

    /// Every session uid any version holds. The active plan holds 260 of them;
    /// the rest exist only in versions nobody reads, which is the mechanism
    /// §12.11 exists for and §12.96.3 relies on.
    var allSessionUIDs: Set<String> {
        versions.reduce(into: Set<String>()) { $0.formUnion($1.sessionUIDs) }
    }

    /// Named by a `proposal_change` and held by no stored version. Already
    /// dangling, today, before anything is deleted.
    var danglingReferences: [String] {
        referencedUIDs.subtracting(allSessionUIDs).sorted()
    }

    /// Groups of two or more versions carrying identical training.
    /// Oldest-first within a group, oldest group first.
    var twinGroups: [[Version]] {
        var byFingerprint: [String: [Version]] = [:]
        for v in versions { byFingerprint[v.fingerprint, default: []].append(v) }
        return byFingerprint.values
            .filter { $0.count > 1 }
            .map { $0.sorted(by: { $0.importedUTC < $1.importedUTC }) }
            .sorted(by: { ($0.first?.importedUTC ?? "") < ($1.first?.importedUTC ?? "") })
    }

    /// Session uids this version holds that no other stored version does.
    /// Deleting it would take these with it.
    func uidsHeldOnlyBy(_ v: Version) -> [String] {
        var others = Set<String>()
        for o in versions where o.id != v.id { others.formUnion(o.sessionUIDs) }
        return v.sessionUIDs.subtracting(others).sorted()
    }

    /// The one this census would keep out of a twin group: the active version
    /// if the group has one, otherwise the oldest. Nil only for an empty group,
    /// which `twinGroups` never produces.
    func keeper(of group: [Version]) -> Version? {
        group.first(where: { $0.isActive }) ?? group.first
    }

    /// The census counted the active version itself. The reader counted it
    /// through five joins and a decode. If those two disagree, this file is
    /// wrong about what a version contains and nothing below it can be trusted.
    var agreesWithReader: Bool? {
        guard let a = activeVersion, let r = readerSessionCount else { return nil }
        return a.sessions == r
    }

    var agreementLine: String {
        switch agreesWithReader {
        case .some(true):
            return "yes"
        case .some(false):
            return "NO — this census counts \(activeVersion?.sessions ?? -1) "
                 + "sessions in the active version and the read-back reports "
                 + "\(readerSessionCount ?? -1); trust neither number"
        case .none:
            return activeVersion == nil
                ? "no version is active, so there is nothing to agree about"
                : "the read-back's count was not supplied to this census"
        }
    }

    /// The verdict in one line, for a roll-up row or a section header.
    var line: String {
        if let why = readFailure { return "could not be read — \(why)" }
        if versions.isEmpty { return "no plan version is stored" }
        let twins = twinGroups.reduce(0) { $0 + $1.count - 1 }
        return twins == 0
            ? "\(versions.count) versions, all different"
            : "\(versions.count) versions, \(twins) removable"
    }

    /// How many versions a prune would delete. Zero is a real answer.
    var removableCount: Int {
        twinGroups.reduce(0) { $0 + $1.count - 1 }
    }

    // MARK: The paste

    /// UNCONDITIONAL, every line including the zeros — §12.54.2. A section that
    /// vanished when there were no twins could not be told from one nobody
    /// wired in, and "no twins" is the answer this was built to produce.
    var diagnosticLines: [String] {
        guard readFailure == nil else {
            return ["Plan versions: could not be read — \(readFailure ?? "")",
                    "  no count below this line is available, "
                    + "which is not the same as zero"]
        }

        var lines = [
            "Plan versions: \(versions.count) stored, \(activeCount) active",
            "  the census and the read-back agree: \(agreementLine)",
            "  fingerprint covers: \(Self.censusCovers)",
            "  session uids known to any version: \(allSessionUIDs.count)",
            "  session uids in the active version: "
            + "\(activeVersion?.sessionUIDs.count ?? 0)",
            "  uids named by a proposal_change: \(referencedUIDs.count)",
            "  of those, naming nothing any version holds: "
            + "\(danglingReferences.count)"]
        for d in danglingReferences.prefix(8) { lines.append("    \(d)") }

        for (i, v) in versions.enumerated() {
            let only = uidsHeldOnlyBy(v)
            let referenced = only.filter { referencedUIDs.contains($0) }
            lines.append("")
            lines.append("  version \(i + 1) of \(versions.count) [\(v.short)]"
                       + (v.isActive ? "  ACTIVE" : ""))
            lines.append("    imported: \(v.importedUTC)")
            lines.append("    source: \(v.sourceLabel)")
            lines.append("    contentHash: \(String(v.contentHash.prefix(12)))")
            lines.append("    fingerprint: \(String(v.fingerprint.prefix(12)))")
            lines.append("    rows: \(v.rowLine)")
            lines.append("    session uids no other version holds: \(only.count)")
            for u in only.prefix(12) { lines.append("      \(u)") }
            if only.count > 12 {
                lines.append("      + \(only.count - 12) more")
            }
            lines.append("    of those, named by a proposal_change: "
                       + "\(referenced.count)")
            for u in referenced.prefix(12) { lines.append("      \(u)") }
        }

        lines.append("")
        if twinGroups.isEmpty {
            lines.append("  twins — versions holding identical training: none")
            lines.append("  nothing stored here is a duplicate; "
                       + "every version is a different plan")
        } else {
            for g in twinGroups {
                lines.append("  twins — versions holding identical training: "
                           + g.map({ "[\($0.short)]" }).joined(separator: " "))
                lines.append("    a prune would keep "
                           + "[\(keeper(of: g)?.short ?? "—")] "
                           + "and delete "
                           + "\(g.count - 1) "
                           + (g.count - 1 == 1 ? "version" : "versions"))
            }
        }
        return lines
    }
}

// MARK: - Reading it

extension PlanVersionCensus {

    /// A struct rather than a tuple so the value crossing out of the database
    /// read has a name and a declared `Sendable` conformance.
    private nonisolated struct Reading: Sendable {
        let referenced: Set<String>
        let versions: [Version]
    }

    /// Every version, in import order. One read, one transaction.
    ///
    /// `readerSessionCount` is `PlanRoundTrip.Report.sessionsInDatabase` when
    /// the caller has a report. Passing nil is allowed and says so in the
    /// paste rather than silently printing "yes".
    nonisolated static func read(_ db: Sub4Database,
                     readerSessionCount: Int?) -> PlanVersionCensus {
        var c = PlanVersionCensus()
        c.readerSessionCount = readerSessionCount
        do {
            let reading = try db.queue.read { d -> Reading in
                let referenced = Set(try String.fetchAll(d, sql: """
                    SELECT DISTINCT planSessionUID FROM proposal_change
                    """))
                var out: [Version] = []
                for row in try Row.fetchAll(d, sql: versionSQL) {
                    guard let id = row["id"] as String?,
                          let planID = row["planID"] as String?,
                          let hash = row["contentHash"] as String?,
                          let label = row["sourceLabel"] as String?,
                          let imported = row["importedUTC"] as String?
                    else { continue }
                    out.append(try measure(d,
                                           id: id,
                                           planID: planID,
                                           contentHash: hash,
                                           sourceLabel: label,
                                           importedUTC: imported,
                                           isActive: (row["activatedUTC"] as String?) != nil))
                }
                return Reading(referenced: referenced, versions: out)
            }
            c.referencedUIDs = reading.referenced
            c.versions = reading.versions
        } catch {
            c.readFailure = String(describing: error)
        }
        return c
    }

    private nonisolated static func measure(_ d: Database,
                                id: String,
                                planID: String,
                                contentHash: String,
                                sourceLabel: String,
                                importedUTC: String,
                                isActive: Bool) throws -> Version {
        var text: [String] = []
        var uids = Set<String>()
        var weeks = 0, weekStats = 0, sessions = 0
        var details = 0, blocks = 0, exercises = 0

        // The week's row id is dropped from the fingerprint and kept here, so
        // its stats can be keyed by the week's uid instead.
        var weekUIDByRowID: [String: String] = [:]
        for r in try Row.fetchAll(d, sql: PlanRepository.weekSQL,
                                  arguments: [id]) {
            weeks += 1
            weekUIDByRowID[(r["id"] as String?) ?? ""] = (r["uid"] as String?) ?? "∅"
            text.append("week|" + fields(r, without: ["id"]))
        }
        for r in try Row.fetchAll(d, sql: PlanRepository.weekStatSQL,
                                  arguments: [id]) {
            weekStats += 1
            let w = weekUIDByRowID[(r["planWeekID"] as String?) ?? ""] ?? "∅"
            text.append("stat|\(w)|" + fields(r, without: ["planWeekID"]))
        }
        for r in try Row.fetchAll(d, sql: PlanRepository.sessionSQL,
                                  arguments: [id]) {
            sessions += 1
            if let u = r["uid"] as String? { uids.insert(u) }
            text.append("session|" + fields(r, without: []))
        }
        for r in try Row.fetchAll(d, sql: PlanRepository.detailSQL,
                                  arguments: [id]) {
            details += 1
            text.append("breakdown|" + fields(r, without: ["detailID"]))
        }
        for r in try Row.fetchAll(d, sql: PlanRepository.blockSQL,
                                  arguments: [id]) {
            blocks += 1
            text.append("block|" + fields(r, without: ["detailID"]))
        }
        for r in try Row.fetchAll(d, sql: exerciseSQL, arguments: [id]) {
            exercises += 1
            text.append("exercise|" + fields(r, without: []))
        }

        return Version(id: id,
                       planID: planID,
                       sourceLabel: sourceLabel,
                       importedUTC: importedUTC,
                       contentHash: contentHash,
                       isActive: isActive,
                       weeks: weeks,
                       weekStats: weekStats,
                       sessions: sessions,
                       details: details,
                       blocks: blocks,
                       exercises: exercises,
                       fingerprint: digest(text),
                       sessionUIDs: uids)
    }

    /// `name=value` for every column that is not a row identity. The value is
    /// `DatabaseValue`'s own description, so NULL and the empty string do not
    /// collapse into each other — §6, and a fingerprint that could not tell
    /// them apart would call two different plans the same.
    private nonisolated static func fields(_ row: Row, without drop: Set<String>) -> String {
        var parts: [String] = []
        for (name, value) in row {
            if drop.contains(name) { continue }
            parts.append("\(name)=\(value)")
        }
        return parts.joined(separator: "|")
    }

    /// SORTED BEFORE HASHING, and that is the point of the whole file.
    /// §12.93.3's defect was a hash that changed when the same content came
    /// back in a different order. This one cannot.
    private nonisolated static func digest(_ text: [String]) -> String {
        let joined = text.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static let versionSQL = """
        SELECT id, planID, contentHash, sourceLabel, importedUTC, activatedUTC
          FROM plan_version
         ORDER BY importedUTC, id
        """

    nonisolated static let exerciseSQL = """
        SELECT uid, name, videoURL, cue, uses
          FROM plan_exercise
         WHERE planVersionID = ?
        """
}

// MARK: - Removing a twin

/// WHAT A PRUNE IS ALLOWED TO DELETE.
///
/// One rule, and it is deliberately narrower than "anything inactive": a
/// version may be deleted only when ANOTHER STORED VERSION HOLDS IDENTICAL
/// TRAINING. Not "looks unused", not "is old", not "has no active flag" — the
/// content has to still be here afterwards.
///
/// That rule makes the dangerous case impossible rather than unlikely. §12.7
/// refuses to make `user_note.planSessionUID` and `proposal_change.planSessionUID`
/// foreign keys, precisely so a plan revision cannot delete thirteen months of
/// writing; the cost of that decision is that nothing in the schema would stop
/// this from orphaning a reference either. If every uid the doomed version
/// holds survives in its twin, there is nothing to orphan.
///
/// It is checked anyway, on the way out, because a guard that cannot fire has
/// not been tested — §12.69 — and `theRefusalFiresWhenAUIDWouldBeLost` builds
/// the database where it does.
nonisolated struct PlanVersionPrune: Sendable, Equatable {

    /// Short ids, because this goes in a paste somebody reads later.
    var deleted: [String] = []
    var kept: [String] = []
    /// Set means nothing was deleted, and says why. Nil after a delete.
    var refusal: String?
    /// Never run. Distinct from "ran and refused" — §12.15.
    var didRun: Bool = false

    var line: String {
        guard didRun else { return "not run" }
        if let why = refusal { return "nothing removed — \(why)" }
        return deleted.isEmpty
            ? "nothing removed"
            : "removed \(deleted.count), kept \(kept.count)"
    }

    var diagnosticLines: [String] {
        var lines = ["Plan version prune: \(line)"]
        for k in kept { lines.append("  kept: [\(k)]") }
        for d in deleted { lines.append("  removed: [\(d)]") }
        return lines
    }

    /// Non-nil when deleting `doomed` would take a session uid with it that no
    /// surviving version holds. Pure, so it can be tested on values the reader
    /// can see rather than on a database that cannot produce them.
    static func uidsLostRefusal(census: PlanVersionCensus,
                                doomed: [PlanVersionCensus.Version]) -> String? {
        let doomedIDs = Set(doomed.map { $0.id })
        var surviving = Set<String>()
        for v in census.versions where !doomedIDs.contains(v.id) {
            surviving.formUnion(v.sessionUIDs)
        }
        for v in doomed {
            let lost = v.sessionUIDs.subtracting(surviving)
            guard lost.isEmpty else {
                return "[\(v.short)] holds \(lost.count) session uids no "
                     + "surviving version holds — "
                     + lost.sorted().prefix(3).joined(separator: ", ")
            }
        }
        return nil
    }

    /// Reads the census, deletes every non-keeper in every twin group, and
    /// reports. The cascade in `plan_week`, `plan_session` and `plan_exercise`
    /// takes the content; `user_note.planVersionID` is `ON DELETE SET NULL`,
    /// so a note written against the removed version keeps its text and loses
    /// only the pointer.
    static func run(_ db: Sub4Database) -> PlanVersionPrune {
        var out = PlanVersionPrune()
        out.didRun = true

        let census = PlanVersionCensus.read(db, readerSessionCount: nil)
        if let why = census.readFailure {
            out.refusal = "the census could not be read — \(why)"
            return out
        }
        let groups = census.twinGroups
        guard !groups.isEmpty else {
            out.refusal = "no two stored versions hold identical training"
            return out
        }

        var doomed: [PlanVersionCensus.Version] = []
        for g in groups {
            guard let keeper = census.keeper(of: g) else { continue }
            out.kept.append(keeper.short)
            doomed.append(contentsOf: g.filter { $0.id != keeper.id })
        }
        guard !doomed.isEmpty else {
            out.kept = []
            out.refusal = "every twin group is a single version, which cannot happen"
            return out
        }
        if doomed.contains(where: { $0.isActive }) {
            out.kept = []
            out.refusal = "the active version was selected for deletion"
            return out
        }

        // THE GUARD THE RULE ABOVE MAKES UNREACHABLE, CHECKED ANYWAY — and
        // pulled out as a pure function so it can be. §12.69 says a guard that
        // cannot fail has not been tested; this one cannot fail while the
        // fingerprint covers `plan_session`, so it is exercised directly on
        // hand-built values by `theLostUIDRefusalFiresOnValuesThatWouldLoseOne`.
        //
        // It stays because the thing it protects against is not a bug in the
        // rule, it is a NARROWING OF THE FINGERPRINT: the day somebody drops
        // sessions from the covered set to make the census cheaper, two
        // versions with different training become twins and this is the line
        // that refuses to delete one of them.
        if let why = uidsLostRefusal(census: census, doomed: doomed) {
            out.kept = []
            out.refusal = why
            return out
        }

        do {
            try db.queue.write { d in
                for v in doomed {
                    try d.execute(sql: "DELETE FROM plan_version WHERE id = ?",
                                  arguments: [v.id])
                }
            }
            out.deleted = doomed.map { $0.short }
        } catch {
            out.kept = []
            out.refusal = "the delete failed — \(String(describing: error))"
        }
        return out
    }
}
