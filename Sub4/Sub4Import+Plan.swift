//
//  Sub4Import+Plan.swift
//  Sub4
//
//  The bundled plan, whole — patch 237, ADR-0003 §12.11.
//
//  THE ONE STORE THAT IS NOT THE ATHLETE'S DATA
//  --------------------------------------------
//  Everything imported so far was recorded: activities happened, notes were
//  written, weather was measured. The plan is the opposite — it is the
//  INTENTION, shipped in the app bundle, replaced wholesale on update, and
//  identical on every device running the same build.
//
//  Which raises the fair question of why it is in the database at all when it
//  is already in the bundle. The answer is `plan_version`. A note written in
//  March was written against the plan as it stood in March; a proposal's
//  reasoning refers to sessions that a later build may renumber, retitle or
//  drop. §12.7 records that `user_note.planSessionUID` is deliberately NOT a
//  foreign key for exactly this reason — an FK would delete the reasoning
//  behind every past note the first time a week was renumbered. Storing each
//  version, hashed and dated, is what turns that dangling reference into
//  something answerable later.
//
//  IDENTITY IS THE CONTENT HASH
//  ----------------------------
//  Not the file name, not the app version, not the import time. A build that
//  ships an unchanged plan.json must not mint a second version, and a build
//  that changes one session's detail must. `contentHash` is over the bytes of
//  the decoded JSON, and it is UNIQUE in the schema, so the second import of
//  an unchanged plan is a no-op that the database enforces rather than the
//  importer remembering to check.
//
//  ONE ACTIVE VERSION, ENFORCED BY A PARTIAL INDEX
//  -----------------------------------------------
//  `plan_version_one_active` is a unique index on `planID WHERE activatedUTC
//  IS NOT NULL`. So activating a new version means clearing the old one's
//  timestamp first, in the same transaction. Doing it the other way round —
//  insert then clear — violates the index halfway through, which is the index
//  working. It is written in the correct order here and asserted by test,
//  because "the constraint caught it" is only comforting the first time.
//
//  A VERSION'S CONTENT IS REPLACED, NEVER MERGED
//  ---------------------------------------------
//  Re-importing an existing version deletes its weeks, sessions, exercises,
//  fuel and warm-up and writes them again. Merging would need an identity for
//  a fuelling ladder step, and it has none — it is the third row in a list.
//  `ON DELETE CASCADE` from `plan_version` makes deleting the version's
//  children a single statement per top-level table.
//
//  ORDER IS STORED, NOT ASSUMED
//  ----------------------------
//  Every list here carries an `ordinal` written from its position in the JSON
//  array. SQLite makes no promise about the order rows come back without an
//  ORDER BY, and a warm-up timeline read back shuffled is a different warm-up.
//

import Foundation
import CryptoKit
import GRDB

extension Sub4Import {

    /// Everything about the bundled plan, in one call.
    ///
    /// Returns the plan version id when a version was written or found, so a
    /// later step can attach to it. Nil when there is no plan to import.
    @discardableResult
    nonisolated static func importPlan(
        _ d: Database,
        plan: Plan,
        sourceLabel: String,
        now: String,
        into report: inout Report
    ) throws -> String? {

        report.planSeen += 1
        let hash = contentHash(of: plan)

        do {
            var versionID: String?
            try d.inSavepoint {
                let planID = try upsertPlan(d, meta: plan.meta, now: now)

                // Already here, byte for byte. Nothing is rewritten: the rows
                // cannot have drifted, because the hash covers all of them.
                if let existing = try String.fetchOne(d, sql: """
                    SELECT id FROM plan_version WHERE contentHash = ?
                    """, arguments: [hash]) {
                    versionID = existing
                    report.planUnchanged += 1
                    try activate(d, versionID: existing, planID: planID, now: now)
                    return .commit
                }

                let id = UUID().uuidString
                try d.execute(sql: """
                    INSERT INTO plan_version
                      (id, planID, contentHash, sourceLabel, importedUTC)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id, planID, hash, sourceLabel, now])
                try activate(d, versionID: id, planID: planID, now: now)

                try writeWeeksAndSessions(d, plan: plan, versionID: id, into: &report)
                try writeExercises(d, plan.exercises, versionID: id, into: &report)
                try writeFuel(d, plan.fuel, versionID: id, into: &report)
                try writeWarmup(d, plan.warmup, versionID: id, into: &report)

                versionID = id
                report.planImported += 1
                return .commit
            }
            return versionID
        } catch {
            report.refusals.append(.init(externalID: "plan \(plan.meta.plan)",
                                         reason: String(describing: error)))
            return nil
        }
    }

    // MARK: Identity

    /// SHA-256 over the plan re-encoded with sorted keys.
    ///
    /// Re-encoded rather than hashing the file: the bundle's bytes include
    /// whitespace the extractor happens to emit, so a formatting change would
    /// mint a version with identical content. Sorted keys because dictionary
    /// order is not stable across encodes, and a hash that changes on its own
    /// would mint a new version on every launch.
    nonisolated static func contentHash(of plan: Plan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan) else { return "unhashable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// One plan row, keyed by the race it is for. `week1Monday` and `raceDate`
    /// together are what make two plans different objects rather than two
    /// versions of one.
    private nonisolated static func upsertPlan(_ d: Database,
                                               meta: Meta,
                                               now: String) throws -> String {
        if let id = try String.fetchOne(d, sql: """
            SELECT id FROM plan WHERE week1Monday = ? AND raceDate = ?
            """, arguments: [meta.week1Monday, meta.raceDate]) {
            try d.execute(sql: """
                UPDATE plan SET name = ?, targetTime = ?, targetPaceSecKm = ?
                WHERE id = ?
                """, arguments: [meta.plan, meta.targetTime,
                                 meta.targetPaceSecKm, id])
            return id
        }
        let id = UUID().uuidString
        try d.execute(sql: """
            INSERT INTO plan
              (id, name, week1Monday, raceDate, targetTime, targetPaceSecKm, createdUTC)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, meta.plan, meta.week1Monday, meta.raceDate,
                             meta.targetTime, meta.targetPaceSecKm, now])
        return id
    }

    /// CLEAR THEN SET, in that order. `plan_version_one_active` is a unique
    /// partial index; setting first would violate it while both rows carry a
    /// timestamp.
    private nonisolated static func activate(_ d: Database,
                                             versionID: String,
                                             planID: String,
                                             now: String) throws {
        try d.execute(sql: """
            UPDATE plan_version SET activatedUTC = NULL
            WHERE planID = ? AND id <> ?
            """, arguments: [planID, versionID])
        try d.execute(sql: """
            UPDATE plan_version SET activatedUTC = ? WHERE id = ?
            """, arguments: [now, versionID])
    }

    // MARK: Weeks, sessions, blocks

    private nonisolated static func writeWeeksAndSessions(
        _ d: Database, plan: Plan, versionID: String, into report: inout Report
    ) throws {
        var weekIDByUid: [String: String] = [:]

        for week in plan.weeks {
            let id = UUID().uuidString
            weekIDByUid[week.uid] = id
            try d.execute(sql: """
                INSERT INTO plan_week
                  (id, planVersionID, uid, weekNo, label, startDate,
                   dateRange, tag, badge, kind, logged)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, versionID, week.uid, week.weekNo,
                                 week.label, week.startDate, week.dateRange,
                                 week.tag, week.badge, week.kind, week.logged])
            report.planWeeks += 1

            // The document's own totals. Sorted so two imports of the same
            // plan produce the same ordinals — a dictionary has no order, and
            // leaving it to hashing would make the rows differ run to run.
            for key in week.stats.keys.sorted() {
                guard let value = week.stats[key] else { continue }
                try d.execute(sql: """
                    INSERT INTO plan_week_stat (id, planWeekID, key, value)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, id, key, value])
                report.planWeekStats += 1
            }
        }

        for session in plan.sessions {
            // A session whose week is not in the file is a broken plan, not a
            // row to invent a parent for. Refused individually so the rest of
            // the plan still arrives and the report names the session.
            guard let weekID = weekIDByUid[session.weekUid] else {
                report.refusals.append(.init(
                    externalID: "session \(session.uid)",
                    reason: "names week \(session.weekUid), which is not in the plan"))
                continue
            }

            let id = UUID().uuidString
            try d.execute(sql: """
                INSERT INTO plan_session
                  (id, planVersionID, planWeekID, uid, day, date, discipline,
                   intensity, title, detail, fuel, prep, seq)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, versionID, weekID, session.uid,
                                 session.day, session.date,
                                 session.discipline.rawValue,
                                 session.intensity?.rawValue,
                                 session.title, session.detail,
                                 session.fuel, session.prep, session.seq])
            report.planSessions += 1

            // `breakdown` is `swimDetail ?? strengthDetail`, and the kind has
            // to be recorded from WHICH field held it — the blocks look
            // identical either way, and "was this a swim or a strength
            // session" is not recoverable from them afterwards.
            if let detail = session.swimDetail {
                try writeDetail(d, detail, kind: "swim", sessionID: id, into: &report)
            } else if let detail = session.strengthDetail {
                try writeDetail(d, detail, kind: "strength", sessionID: id, into: &report)
            }
        }
    }

    private nonisolated static func writeDetail(
        _ d: Database, _ detail: SessionDetail, kind: String,
        sessionID: String, into report: inout Report
    ) throws {
        let id = UUID().uuidString
        try d.execute(sql: """
            INSERT INTO plan_session_detail
              (id, planSessionID, kind, total, tag, focus)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id, sessionID, kind, detail.total,
                             detail.tag, detail.focus])
        report.planDetails += 1

        for (i, block) in detail.blocks.enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_session_block
                  (id, planSessionDetailID, ordinal, duration, title, cue, videoURL)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i,
                                 block.d, block.t, block.x, block.u])
            report.planBlocks += 1
        }
    }

    private nonisolated static func writeExercises(
        _ d: Database, _ exercises: [Exercise], versionID: String,
        into report: inout Report
    ) throws {
        for e in exercises {
            try d.execute(sql: """
                INSERT INTO plan_exercise
                  (id, planVersionID, uid, name, videoURL, cue, uses)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, versionID, e.uid,
                                 e.name, e.videoUrl, e.cue, e.uses])
            report.planExercises += 1
        }
    }

    // MARK: Fuelling

    private nonisolated static func writeFuel(
        _ d: Database, _ fuel: Fuel?, versionID: String, into report: inout Report
    ) throws {
        // Optional on the type so a plan.json produced before the extractor
        // learned to read section 09 still decodes. Absent is a fact about the
        // file, not a failure, and nothing is written for it.
        guard let fuel else { return }

        let id = UUID().uuidString
        let race = fuel.raceDay
        try d.execute(sql: """
            INSERT INTO plan_fuel
              (id, planVersionID, intro, timingRule, cautionTag, cautionText,
               raceIntro, raceTotals, raceHydration, racePacing,
               raceCautionTag, raceCautionText)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, versionID, fuel.intro, fuel.timingRule,
                             fuel.caution?.tag, fuel.caution?.text,
                             race?.intro, race?.totals, race?.hydration,
                             race?.pacing, race?.caution?.tag,
                             race?.caution?.text])
        report.planFuel += 1

        for (i, p) in fuel.products.enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_fuel_product
                  (id, planFuelID, ordinal, name, carbs, caffeine, use)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i, p.name, p.carbs,
                                 p.caffeine, p.use])
            report.planFuelRows += 1
        }
        for (i, t) in fuel.perSession.enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_fuel_target
                  (id, planFuelID, ordinal, session, target, take)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i, t.session,
                                 t.target, t.take])
            report.planFuelRows += 1
        }
        for (i, s) in fuel.ladder.enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_fuel_ladder
                  (id, planFuelID, ordinal, run, carbs, take)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i, s.run, s.carbs, s.take])
            report.planFuelRows += 1
        }
        for (i, line) in (race?.before ?? []).enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_fuel_race_before (id, planFuelID, ordinal, text)
                VALUES (?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i, line])
            report.planFuelRows += 1
        }
        for (i, s) in (race?.timeline ?? []).enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_fuel_race_step
                  (id, planFuelID, ordinal, time, dist, take, total)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i, s.time, s.dist,
                                 s.take, s.total])
            report.planFuelRows += 1
        }
    }

    // MARK: The warm-up

    private nonisolated static func writeWarmup(
        _ d: Database, _ warmup: Warmup?, versionID: String,
        into report: inout Report
    ) throws {
        guard let warmup else { return }

        let id = UUID().uuidString
        try d.execute(sql: """
            INSERT INTO plan_warmup
              (id, planVersionID, intro, circuitNote, cautionTag, cautionText)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id, versionID, warmup.intro, warmup.circuitNote,
                             warmup.caution?.tag, warmup.caution?.text])
        report.planWarmup += 1

        for (i, s) in warmup.timeline.enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_warmup_step
                  (id, planWarmupID, ordinal, time, action, detail)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i, s.time, s.action,
                                 s.detail])
            report.planWarmupRows += 1
        }
        for (i, m) in warmup.circuit.enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_warmup_movement
                  (id, planWarmupID, ordinal, movement, dose)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i, m.movement, m.dose])
            report.planWarmupRows += 1
        }
        for (i, c) in warmup.conditions.enumerated() {
            try d.execute(sql: """
                INSERT INTO plan_warmup_condition
                  (id, planWarmupID, ordinal, condition, what)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, id, i, c.condition, c.what])
            report.planWarmupRows += 1
        }
    }
}
