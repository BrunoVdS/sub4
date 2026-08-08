//
//  PlanExtrasRepository.swift
//  Sub4
//
//  The plan's trimmings, read back — D6c slice 6c, patch 326, ADR-0003 §12.70.
//
//  WHAT THIS IS FOR
//  ----------------
//  Eighth repository, and the one that finishes the plan. 323 read the weeks,
//  the sessions, the breakdowns and the blocks — everything the matcher and the
//  load depend on. This reads the ten tables nothing depends on: the fuelling
//  plan, the race-day warm-up protocol and the exercise library.
//
//  **They are decorative and that is the point of keeping them separate.** A
//  red row here means a screen will draw wrong; a red row in `PlanRoundTrip`
//  means a training figure is wrong. Folding the two into one report would have
//  made a difference in the fuel ladder and a difference in a session's
//  discipline look like the same event, which is the argument 321 made for
//  single-claim slices.
//
//  ONE COPY OF "WHICH VERSION" — §12.43
//  ------------------------------------
//  The active version is resolved by `PlanRepository.activeVersion`, extracted
//  at 326 for this caller. Writing the query again would have meant two places
//  to remember that `plan_version_one_active` is unique per PLAN and not per
//  table (§12.66.3), and the second copy is precisely where that gets
//  forgotten. Every count here is therefore over the same version 323 reports.
//
//  THE WRAPPER IS NEVER COMPARED, ONLY ITS FIELDS — §12.63.8, THIRD TIME
//  --------------------------------------------------------------------
//  `Fuel.Caution` is stored as two columns on its parent — `cautionTag`,
//  `cautionText` — and there is no column saying whether a `Caution` existed at
//  all. Two NULLs are therefore ambiguous: they mean `caution == nil` OR
//  `caution == Caution(tag: nil, text: nil)`, and no reader can tell.
//
//  So this compares `tag` and `text` as scalars belonging to their parent and
//  never compares the `Caution` object. Reconstructing one and comparing it
//  would report a difference whenever the app held an empty caution — a
//  difference that says nothing about the data and cannot be fixed by writing
//  anything.
//
//  The same argument covers `Fuel.RaceDay` and `Fuel` and `Warmup` themselves,
//  which are all optional on the type and all stored as columns on a row that
//  either exists or does not. Whether each side HAS one is printed as context
//  rather than asserted.
//
//  CAUTION IS COMPARED THREE TIMES, NAMED BY ITS PARENT
//  ----------------------------------------------------
//  `Fuel.caution`, `Fuel.RaceDay.caution` and `Warmup.caution` are the same
//  type reached from three places. Compared as a set they would be
//  indistinguishable if the importer wrote one parent's caution into another —
//  the identical failure mode as comparing a session's blocks as a set, which
//  323 rejected. So each is walked separately and any difference is named
//  "fuel · caution tag", "raceDay · caution text", "warmup · caution tag".
//
//  ORDINALS, NOT SETS
//  ------------------
//  Every list here — products, targets, ladder steps, race-before lines, race
//  steps, warm-up steps, movements, conditions — carries an `ordinal` column
//  and a `UNIQUE(parent, ordinal)`. They are sequences a person reads in order:
//  a fuel ladder shuffled is a different instruction. Compared by position.
//
//  The exercise library is the exception: it is keyed by `uid` and referenced
//  by name from the session blocks, so it is compared as a dictionary.
//

import Foundation
import GRDB

// MARK: - What the read produced

nonisolated enum PlanExtrasLoad: Sendable {

    case loaded(fuel: Fuel?, warmup: Warmup?, exercises: [Exercise], skipped: Int)
    case noActiveVersion(versionsPresent: Int)
    case ambiguousActiveVersion(activeCount: Int, plansPresent: Int)
    case unavailable
    case failed(String)

    var isTrustworthy: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Nil on every unhappy path, and `.loaded(fuel: nil, …)` is a DIFFERENT
    /// answer from that: it means the read worked and the plan carries no
    /// fuelling section, which is a real state for a plan.json produced before
    /// the extractor learned to read section 09.
    var fuel: Fuel?? {
        if case .loaded(let f, _, _, _) = self { return .some(f) }
        return nil
    }

    var warmup: Warmup?? {
        if case .loaded(_, let w, _, _) = self { return .some(w) }
        return nil
    }

    var exercises: [Exercise]? {
        if case .loaded(_, _, let e, _) = self { return e }
        return nil
    }

    var skipped: Int {
        if case .loaded(_, _, _, let s) = self { return s }
        return 0
    }

    var line: String {
        switch self {
        case .loaded(let f, let w, let e, let skipped):
            let base = "\(f == nil ? "no fuelling plan" : "a fuelling plan"), "
                     + "\(w == nil ? "no warm-up" : "a warm-up"), "
                     + "\(e.count) exercises."
            return skipped == 0 ? base : base + " \(skipped) rows could not be read."
        case .noActiveVersion(let n):
            return n == 0 ? "No plan has been imported."
                          : "\(n) plan versions are stored and none is active."
        case .ambiguousActiveVersion(let active, let plans):
            return "\(active) versions are active across \(plans) plans."
        case .unavailable: return "The database is not open."
        case .failed(let why): return "The database could not be read — \(why)"
        }
    }
}

// MARK: - The comparison

nonisolated enum PlanExtrasRoundTrip {

    /// No approved differences. Every field of `Fuel`, `Warmup` and `Exercise`
    /// has a column and every column is written — the same finding as
    /// §12.66.5, and stated as "none" on the screen for the same reason: the
    /// absence has to be visible or it cannot be told from nobody looking.
    static let approvedNote = "none"

    struct Report: Sendable {

        // MARK: Denominators

        var activeVersion = "—"

        var appHasFuel = false
        var databaseHasFuel = false
        var appHasWarmup = false
        var databaseHasWarmup = false
        var appHasRaceDay = false
        var databaseHasRaceDay = false

        /// Ten: intro, timingRule, two caution columns, four race-day scalars
        /// and two race-caution columns.
        var fuelFieldsCompared = 0
        var productsCompared = 0
        var productFieldsCompared = 0
        var targetsCompared = 0
        var targetFieldsCompared = 0
        var ladderStepsCompared = 0
        var ladderFieldsCompared = 0
        var raceBeforeCompared = 0
        var raceStepsCompared = 0
        var raceStepFieldsCompared = 0

        /// Four: intro, circuitNote and two caution columns.
        var warmupFieldsCompared = 0
        var warmupStepsCompared = 0
        var warmupStepFieldsCompared = 0
        var movementsCompared = 0
        var movementFieldsCompared = 0
        var conditionsCompared = 0
        var conditionFieldsCompared = 0

        var exercisesInApp = 0
        var exercisesInDatabase = 0
        var exercisesCompared = 0
        /// Four per exercise — name, videoUrl, cue, uses. `uid` is the key.
        var exerciseFieldsCompared = 0

        var rowsSkipped = 0

        // MARK: Differences, named

        /// "fuel · timingRule", "raceDay · caution tag", "warmup · intro"
        var fuelDifferences: [String] = []
        var warmupDifferences: [String] = []
        /// "product 2 · carbs", "ladder 4 · take"
        var listDifferences: [String] = []

        var exercisesOnlyInApp: [String] = []
        var exercisesOnlyInDatabase: [String] = []
        var exerciseDifferences: [String] = []

        var totalCompared: Int {
            productsCompared + targetsCompared + ladderStepsCompared
            + raceBeforeCompared + raceStepsCompared
            + warmupStepsCompared + movementsCompared + conditionsCompared
            + exercisesCompared
            + (databaseHasFuel ? 1 : 0) + (databaseHasWarmup ? 1 : 0)
        }

        var unexplained: Int {
            fuelDifferences.count + warmupDifferences.count
            + listDifferences.count
            + exercisesOnlyInApp.count + exercisesOnlyInDatabase.count
            + exerciseDifferences.count
            + rowsSkipped
        }

        /// A plan with no fuelling section and no warm-up and no exercises is
        /// possible — all three are optional on the type, for a plan.json the
        /// extractor produced before it could read those sections. So this
        /// asks whether anything was examined rather than whether a particular
        /// thing was there.
        var lookedAtSomething: Bool { totalCompared > 0 }

        var isHealthy: Bool { lookedAtSomething && unexplained == 0 }

        var summary: String {
            guard lookedAtSomething else { return "nothing compared" }
            return unexplained == 0
                ? "\(totalCompared) compared · no differences"
                : "\(totalCompared) compared · \(unexplained) differences"
        }

        /// Places one walk's numbers. Key paths rather than `inout` fields:
        /// `self` is the only thing being mutated, so there is nothing to
        /// alias — see `ListResult`.
        mutating func absorb(_ res: ListResult,
                             count: WritableKeyPath<Report, Int>,
                             fields: WritableKeyPath<Report, Int>) {
            self[keyPath: count] += res.count
            self[keyPath: fields] += res.fields
            listDifferences.append(contentsOf: res.differences)
        }

        var fuelLine: String {
            "\(appHasFuel ? "yes" : "no") vs \(databaseHasFuel ? "yes" : "no")"
        }
        var warmupLine: String {
            "\(appHasWarmup ? "yes" : "no") vs \(databaseHasWarmup ? "yes" : "no")"
        }
        var raceDayLine: String {
            "\(appHasRaceDay ? "yes" : "no") vs \(databaseHasRaceDay ? "yes" : "no")"
        }

        /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
        ///
        /// SAFE TO PASTE: bundled plan content and nothing the athlete wrote.
        var diagnosticLines: [String] {
            var lines = [
                "Plan extras read-back: \(totalCompared) compared",
                "  active version: \(activeVersion)",
                "  a fuelling plan on each side: \(fuelLine)",
                "  a race-day section on each side: \(raceDayLine)",
                "  a warm-up on each side: \(warmupLine)",
                "  fuel fields compared: \(fuelFieldsCompared)",
                "  products compared: \(productsCompared)",
                "  product fields compared: \(productFieldsCompared)",
                "  session targets compared: \(targetsCompared)",
                "  target fields compared: \(targetFieldsCompared)",
                "  ladder steps compared: \(ladderStepsCompared)",
                "  ladder fields compared: \(ladderFieldsCompared)",
                "  race-day lines compared: \(raceBeforeCompared)",
                "  race-day steps compared: \(raceStepsCompared)",
                "  race-day step fields compared: \(raceStepFieldsCompared)",
                "  warm-up fields compared: \(warmupFieldsCompared)",
                "  warm-up steps compared: \(warmupStepsCompared)",
                "  warm-up step fields compared: \(warmupStepFieldsCompared)",
                "  circuit movements compared: \(movementsCompared)",
                "  movement fields compared: \(movementFieldsCompared)",
                "  conditions compared: \(conditionsCompared)",
                "  condition fields compared: \(conditionFieldsCompared)",
                "  exercises in the app: \(exercisesInApp)",
                "  exercises in the database: \(exercisesInDatabase)",
                "  exercises compared: \(exercisesCompared)",
                "  exercise fields compared: \(exerciseFieldsCompared)",
                "  exercises only in the app: \(exercisesOnlyInApp.count)",
                "  exercises only in the database: \(exercisesOnlyInDatabase.count)",
                "  fuel fields that differ: \(fuelDifferences.count)",
                "  warm-up fields that differ: \(warmupDifferences.count)",
                "  list entries that differ: \(listDifferences.count)",
                "  exercise fields that differ: \(exerciseDifferences.count)",
                "  rows the reader could not read: \(rowsSkipped)",
                "  approved differences: \(PlanExtrasRoundTrip.approvedNote)",
                "  unexplained differences: \(unexplained)"]
            for d in fuelDifferences.prefix(6) { lines.append("    \(d)") }
            for d in warmupDifferences.prefix(6) { lines.append("    \(d)") }
            for d in listDifferences.prefix(8) { lines.append("    \(d)") }
            if listDifferences.count > 8 {
                lines.append("    + \(listDifferences.count - 8) more entries")
            }
            for d in exerciseDifferences.prefix(6) { lines.append("    \(d)") }
            return lines
        }
    }

    /// EVERY STORED FIELD, NAMED — as everywhere else. No reflection.
    static func compare(storeFuel: Fuel?,
                        storeWarmup: Warmup?,
                        storeExercises: [Exercise],
                        database: PlanExtrasLoad) -> Report {

        var r = Report()
        r.appHasFuel = storeFuel != nil
        r.appHasWarmup = storeWarmup != nil
        r.appHasRaceDay = storeFuel?.raceDay != nil
        r.exercisesInApp = storeExercises.count

        switch database {
        case .noActiveVersion:
            return r
        case .ambiguousActiveVersion(let active, let plans):
            r.activeVersion = "ambiguous — \(active) active across \(plans) plans"
            return r
        case .unavailable, .failed:
            return r
        case .loaded(let dbFuel, let dbWarmup, let dbExercises, let skipped):
            r.databaseHasFuel = dbFuel != nil
            r.databaseHasWarmup = dbWarmup != nil
            r.databaseHasRaceDay = dbFuel?.raceDay != nil
            r.exercisesInDatabase = dbExercises.count
            r.rowsSkipped = skipped

            compareFuel(storeFuel, dbFuel, into: &r)
            compareWarmup(storeWarmup, dbWarmup, into: &r)
            compareExercises(storeExercises, dbExercises, into: &r)
            return r
        }
    }

    // MARK: Fuel

    private static func compareFuel(_ a: Fuel?, _ b: Fuel?, into r: inout Report) {
        guard let a, let b else {
            // One side has a fuelling section and the other does not. Visible
            // on the "a fuelling plan on each side" row; not double-counted.
            if (a == nil) != (b == nil) {
                r.fuelDifferences.append("fuel · present on one side only")
            }
            return
        }

        func field(_ name: String, _ same: Bool) {
            r.fuelFieldsCompared += 1
            if !same { r.fuelDifferences.append("fuel · \(name)") }
        }
        field("intro", a.intro == b.intro)
        field("timingRule", a.timingRule == b.timingRule)
        // THE WRAPPER IS NEVER COMPARED — see the header. Two NULL columns
        // cannot say whether a Caution existed, so the scalars are compared and
        // the object is not.
        field("caution tag", a.caution?.tag == b.caution?.tag)
        field("caution text", a.caution?.text == b.caution?.text)
        field("raceDay intro", a.raceDay?.intro == b.raceDay?.intro)
        field("raceDay totals", a.raceDay?.totals == b.raceDay?.totals)
        field("raceDay hydration", a.raceDay?.hydration == b.raceDay?.hydration)
        field("raceDay pacing", a.raceDay?.pacing == b.raceDay?.pacing)
        // NAMED BY ITS PARENT, so one caution written into another is caught.
        field("raceDay caution tag", a.raceDay?.caution?.tag == b.raceDay?.caution?.tag)
        field("raceDay caution text", a.raceDay?.caution?.text == b.raceDay?.caution?.text)

        // BY ORDINAL. A fuel ladder shuffled is a different instruction.
        r.absorb(list("product", a.products, b.products) { x, y, f in
            f("name", x.name == y.name)
            f("carbs", x.carbs == y.carbs)
            f("caffeine", x.caffeine == y.caffeine)
            f("use", x.use == y.use)
        }, count: \.productsCompared, fields: \.productFieldsCompared)

        r.absorb(list("target", a.perSession, b.perSession) { x, y, f in
            f("session", x.session == y.session)
            f("target", x.target == y.target)
            f("take", x.take == y.take)
        }, count: \.targetsCompared, fields: \.targetFieldsCompared)

        r.absorb(list("ladder", a.ladder, b.ladder) { x, y, f in
            f("run", x.run == y.run)
            f("carbs", x.carbs == y.carbs)
            f("take", x.take == y.take)
        }, count: \.ladderStepsCompared, fields: \.ladderFieldsCompared)

        let beforeA = a.raceDay?.before ?? []
        let beforeB = b.raceDay?.before ?? []
        if beforeA.count != beforeB.count {
            r.listDifferences.append("raceDay before · line count")
        }
        for i in 0..<min(beforeA.count, beforeB.count) {
            r.raceBeforeCompared += 1
            if beforeA[i] != beforeB[i] {
                r.listDifferences.append("raceDay before \(i)")
            }
        }

        r.absorb(list("raceDay step",
                      a.raceDay?.timeline ?? [], b.raceDay?.timeline ?? []) { x, y, f in
            f("time", x.time == y.time)
            f("dist", x.dist == y.dist)
            f("take", x.take == y.take)
            f("total", x.total == y.total)
        }, count: \.raceStepsCompared, fields: \.raceStepFieldsCompared)
    }

    // MARK: Warm-up

    private static func compareWarmup(_ a: Warmup?, _ b: Warmup?,
                                      into r: inout Report) {
        guard let a, let b else {
            if (a == nil) != (b == nil) {
                r.warmupDifferences.append("warmup · present on one side only")
            }
            return
        }

        func field(_ name: String, _ same: Bool) {
            r.warmupFieldsCompared += 1
            if !same { r.warmupDifferences.append("warmup · \(name)") }
        }
        field("intro", a.intro == b.intro)
        field("circuitNote", a.circuitNote == b.circuitNote)
        field("caution tag", a.caution?.tag == b.caution?.tag)
        field("caution text", a.caution?.text == b.caution?.text)

        r.absorb(list("warm-up step", a.timeline, b.timeline) { x, y, f in
            f("time", x.time == y.time)
            f("action", x.action == y.action)
            f("detail", x.detail == y.detail)
        }, count: \.warmupStepsCompared, fields: \.warmupStepFieldsCompared)

        r.absorb(list("movement", a.circuit, b.circuit) { x, y, f in
            f("movement", x.movement == y.movement)
            f("dose", x.dose == y.dose)
        }, count: \.movementsCompared, fields: \.movementFieldsCompared)

        r.absorb(list("condition", a.conditions, b.conditions) { x, y, f in
            f("condition", x.condition == y.condition)
            f("what", x.what == y.what)
        }, count: \.conditionsCompared, fields: \.conditionFieldsCompared)
    }

    /// What one ordinal walk produced. RETURNED RATHER THAN WRITTEN THROUGH
    /// `inout`, and patch 326a is why: the first version took
    /// `count: inout Int` and `into r: inout Report` and every call site passed
    /// `&r.productsCompared` beside `&r`, which is two exclusive accesses to
    /// one variable. Seven compile errors, one per call site, all saying the
    /// same thing.
    ///
    /// A function that both reads a whole and writes one of its parts is asking
    /// the caller to alias, and Swift's exclusivity rule exists to refuse that.
    /// Returning the numbers and letting the caller place them removes the
    /// question rather than working around it. §12.70.7.
    struct ListResult: Sendable {
        var count = 0
        var fields = 0
        var differences: [String] = []
    }

    /// The ordinal walk, once. Every list in this file is a sequence with a
    /// `UNIQUE(parent, ordinal)` behind it, and every one of them is compared
    /// by POSITION rather than as a set — §12.66.6's argument about the session
    /// blocks, applied eight more times.
    private static func list<T>(_ label: String, _ a: [T], _ b: [T],
                                walk: (T, T, (String, Bool) -> Void) -> Void)
    -> ListResult {
        var out = ListResult()
        if a.count != b.count {
            out.differences.append("\(label) · count \(a.count) vs \(b.count)")
        }
        for i in 0..<min(a.count, b.count) {
            out.count += 1
            walk(a[i], b[i]) { name, same in
                out.fields += 1
                if !same { out.differences.append("\(label) \(i) · \(name)") }
            }
        }
        return out
    }

    // MARK: Exercises, by the library's own uid

    private static func compareExercises(_ store: [Exercise], _ db: [Exercise],
                                         into r: inout Report) {
        let mine = Dictionary(store.map { ($0.uid, $0) },
                              uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(db.map { ($0.uid, $0) },
                                uniquingKeysWith: { first, _ in first })
        // KEYS, NOT VALUES — §12.65.10.
        let myKeys = Set(mine.keys)
        let theirKeys = Set(theirs.keys)
        r.exercisesOnlyInApp = myKeys.subtracting(theirKeys).sorted()
        r.exercisesOnlyInDatabase = theirKeys.subtracting(myKeys).sorted()

        for uid in myKeys.intersection(theirKeys).sorted() {
            guard let a = mine[uid], let b = theirs[uid] else { continue }
            r.exercisesCompared += 1

            func field(_ name: String, _ same: Bool) {
                r.exerciseFieldsCompared += 1
                if !same { r.exerciseDifferences.append("\(uid) · \(name)") }
            }
            field("name", a.name == b.name)
            field("videoUrl", a.videoUrl == b.videoUrl)
            field("cue", a.cue == b.cue)
            // The count of session blocks naming this exercise. Derived by the
            // extractor, stored as written, and compared because a library
            // whose usage counts drift is a library that has been rebuilt from
            // a different plan.
            field("uses", a.uses == b.uses)
        }
    }
}

// MARK: - The reader

nonisolated enum PlanExtrasRepository {

    static func load(_ db: Sub4Database) -> PlanExtrasLoad {
        do {
            return try db.queue.read { d -> PlanExtrasLoad in
                // ONE COPY OF "WHICH VERSION", CALLED — §12.43.
                let versionID: String
                switch try PlanRepository.activeVersion(d) {
                case .one(let id, _, _, _, _):
                    versionID = id
                case .none(let n):
                    return .noActiveVersion(versionsPresent: n)
                case .ambiguous(let active, let plans):
                    return .ambiguousActiveVersion(activeCount: active,
                                                   plansPresent: plans)
                case .malformed(let why):
                    return .failed(why)
                }

                var skipped = 0
                let fuel = try readFuel(d, versionID: versionID, skipped: &skipped)
                let warmup = try readWarmup(d, versionID: versionID, skipped: &skipped)

                var exercises: [Exercise] = []
                for row in try Row.fetchAll(d, sql: exerciseSQL,
                                            arguments: [versionID]) {
                    guard let uid = row["uid"] as String?,
                          let name = row["name"] as String?,
                          let videoURL = row["videoURL"] as String?,
                          let uses = row["uses"] as Int? else {
                        skipped += 1; continue
                    }
                    exercises.append(Exercise(uid: uid, name: name,
                                              videoUrl: videoURL,
                                              cue: row["cue"] as String?,
                                              uses: uses))
                }

                return .loaded(fuel: fuel, warmup: warmup,
                               exercises: exercises, skipped: skipped)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: Fuel

    private static func readFuel(_ d: Database, versionID: String,
                                 skipped: inout Int) throws -> Fuel? {
        guard let row = try Row.fetchOne(d, sql: fuelSQL, arguments: [versionID]),
              let fuelID = row["id"] as String? else {
            // NOT a failure. A plan.json produced before the extractor could
            // read section 09 carries no fuelling plan, and `Fuel` is optional
            // on `Plan` for exactly that reason.
            return nil
        }

        var products: [Fuel.Product] = []
        for r in try Row.fetchAll(d, sql: productSQL, arguments: [fuelID]) {
            products.append(Fuel.Product(name: r["name"] as String?,
                                         carbs: r["carbs"] as String?,
                                         caffeine: r["caffeine"] as String?,
                                         use: r["use"] as String?))
        }
        var targets: [Fuel.SessionTarget] = []
        for r in try Row.fetchAll(d, sql: targetSQL, arguments: [fuelID]) {
            targets.append(Fuel.SessionTarget(session: r["session"] as String?,
                                              target: r["target"] as String?,
                                              take: r["take"] as String?))
        }
        var ladder: [Fuel.LadderStep] = []
        for r in try Row.fetchAll(d, sql: ladderSQL, arguments: [fuelID]) {
            ladder.append(Fuel.LadderStep(run: r["run"] as String?,
                                          carbs: r["carbs"] as String?,
                                          take: r["take"] as String?))
        }
        var before: [String] = []
        for r in try Row.fetchAll(d, sql: raceBeforeSQL, arguments: [fuelID]) {
            guard let text = r["text"] as String? else { skipped += 1; continue }
            before.append(text)
        }
        var timeline: [Fuel.RaceDay.Step] = []
        for r in try Row.fetchAll(d, sql: raceStepSQL, arguments: [fuelID]) {
            timeline.append(Fuel.RaceDay.Step(time: r["time"] as String?,
                                              dist: r["dist"] as String?,
                                              take: r["take"] as String?,
                                              total: r["total"] as String?))
        }

        // THE RACE-DAY OBJECT IS REBUILT ONLY IF SOMETHING IS IN IT. Its
        // scalars are columns on `plan_fuel` and there is no column saying
        // whether a `RaceDay` existed, so an all-NULL row with two empty lists
        // is indistinguishable from its absence. Choosing "absent" is the
        // conservative reading — see the header — and the comparison never
        // asks about the wrapper anyway, only its fields.
        let raceScalars = [row["raceIntro"] as String?,
                           row["raceTotals"] as String?,
                           row["raceHydration"] as String?,
                           row["racePacing"] as String?,
                           row["raceCautionTag"] as String?,
                           row["raceCautionText"] as String?]
        let hasRaceDay = raceScalars.contains { $0 != nil }
                      || !before.isEmpty || !timeline.isEmpty

        let raceDay: Fuel.RaceDay? = hasRaceDay
            ? Fuel.RaceDay(intro: row["raceIntro"] as String?,
                           before: before,
                           timeline: timeline,
                           totals: row["raceTotals"] as String?,
                           hydration: row["raceHydration"] as String?,
                           pacing: row["racePacing"] as String?,
                           caution: caution(row["raceCautionTag"] as String?,
                                            row["raceCautionText"] as String?))
            : nil

        return Fuel(intro: row["intro"] as String?,
                    timingRule: row["timingRule"] as String?,
                    products: products,
                    perSession: targets,
                    ladder: ladder,
                    caution: caution(row["cautionTag"] as String?,
                                     row["cautionText"] as String?),
                    raceDay: raceDay)
    }

    // MARK: Warm-up

    private static func readWarmup(_ d: Database, versionID: String,
                                   skipped: inout Int) throws -> Warmup? {
        guard let row = try Row.fetchOne(d, sql: warmupSQL, arguments: [versionID]),
              let warmupID = row["id"] as String? else { return nil }

        var timeline: [Warmup.Step] = []
        for r in try Row.fetchAll(d, sql: warmupStepSQL, arguments: [warmupID]) {
            timeline.append(Warmup.Step(time: r["time"] as String?,
                                        action: r["action"] as String?,
                                        detail: r["detail"] as String?))
        }
        var circuit: [Warmup.Movement] = []
        for r in try Row.fetchAll(d, sql: movementSQL, arguments: [warmupID]) {
            circuit.append(Warmup.Movement(movement: r["movement"] as String?,
                                           dose: r["dose"] as String?))
        }
        var conditions: [Warmup.Condition] = []
        for r in try Row.fetchAll(d, sql: conditionSQL, arguments: [warmupID]) {
            conditions.append(Warmup.Condition(condition: r["condition"] as String?,
                                               what: r["what"] as String?))
        }

        return Warmup(intro: row["intro"] as String?,
                      timeline: timeline,
                      circuit: circuit,
                      circuitNote: row["circuitNote"] as String?,
                      conditions: conditions,
                      caution: caution(row["cautionTag"] as String?,
                                       row["cautionText"] as String?))
    }

    /// Two NULL columns become no caution rather than an empty one. The
    /// comparison never asks which — it walks `tag` and `text` — so this choice
    /// affects only what a future caller sees, and "absent" is the reading that
    /// cannot invent a caution nobody wrote.
    private static func caution(_ tag: String?, _ text: String?) -> Fuel.Caution? {
        (tag == nil && text == nil) ? nil : Fuel.Caution(tag: tag, text: text)
    }

    // MARK: SQL — every list ordered by its ordinal

    private static let fuelSQL = """
        SELECT id, intro, timingRule, cautionTag, cautionText,
               raceIntro, raceTotals, raceHydration, racePacing,
               raceCautionTag, raceCautionText
          FROM plan_fuel WHERE planVersionID = ?
        """

    private static let productSQL = """
        SELECT name, carbs, caffeine, use FROM plan_fuel_product
         WHERE planFuelID = ? ORDER BY ordinal
        """

    private static let targetSQL = """
        SELECT session, target, take FROM plan_fuel_target
         WHERE planFuelID = ? ORDER BY ordinal
        """

    private static let ladderSQL = """
        SELECT run, carbs, take FROM plan_fuel_ladder
         WHERE planFuelID = ? ORDER BY ordinal
        """

    private static let raceBeforeSQL = """
        SELECT text FROM plan_fuel_race_before
         WHERE planFuelID = ? ORDER BY ordinal
        """

    private static let raceStepSQL = """
        SELECT time, dist, take, total FROM plan_fuel_race_step
         WHERE planFuelID = ? ORDER BY ordinal
        """

    private static let warmupSQL = """
        SELECT id, intro, circuitNote, cautionTag, cautionText
          FROM plan_warmup WHERE planVersionID = ?
        """

    private static let warmupStepSQL = """
        SELECT time, action, detail FROM plan_warmup_step
         WHERE planWarmupID = ? ORDER BY ordinal
        """

    private static let movementSQL = """
        SELECT movement, dose FROM plan_warmup_movement
         WHERE planWarmupID = ? ORDER BY ordinal
        """

    private static let conditionSQL = """
        SELECT condition, what FROM plan_warmup_condition
         WHERE planWarmupID = ? ORDER BY ordinal
        """

    /// Keyed by `uid`, not ordered by an ordinal: the library is referenced by
    /// name from the session blocks, so it is a dictionary rather than a
    /// sequence. Ordered here only so two reads produce the same list.
    private static let exerciseSQL = """
        SELECT uid, name, videoURL, cue, uses FROM plan_exercise
         WHERE planVersionID = ? ORDER BY uid
        """
}
