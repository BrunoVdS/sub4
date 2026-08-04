//
//  PlanImportTests.swift
//  Sub4CoreTests
//
//  The bundled plan, whole — patch 237, ADR-0003 §12.11.
//
//  TWO KINDS OF TEST HERE, DELIBERATELY
//  ------------------------------------
//  The structural ones build a small plan by hand, because a hand-built plan is
//  the only way to create the cases that must not happen — a session naming a
//  week that is not there, a second version of the same content, a list whose
//  order has to survive.
//
//  The last one imports the REAL bundled plan and counts what lands. That is
//  the one that would have caught this patch's whole reason for existing: the
//  schema had no home for 634 blocks, and every hand-built fixture I might have
//  written would have had exactly as many blocks as I remembered to put in it.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct PlanImportTests {

    // MARK: Fixtures

    private func meta(race: String = "2027-03-21") -> Meta {
        Meta(plan: "Operation Sub-4", week1Monday: "2026-07-27",
             raceDate: race, targetTime: "4:00:00", targetPaceSecKm: 341)
    }

    private func week(_ uid: String, no: Int? = 1,
                      stats: [String: Double] = ["km": 42, "h": 8]) -> Week {
        Week(uid: uid, weekNo: no, label: no.map(String.init) ?? "P1",
             dateRange: "27 Jul – 2 Aug", startDate: "2026-07-27",
             tag: nil, badge: nil, kind: nil, logged: false, stats: stats)
    }

    private func session(_ uid: String, week weekUid: String,
                         discipline: Discipline = .run,
                         swim: SessionDetail? = nil,
                         strength: SessionDetail? = nil,
                         seq: Int = 0) -> Session {
        Session(uid: uid, weekUid: weekUid, day: "Mon", date: "2026-07-27",
                discipline: discipline, intensity: .easy, title: "Easy run",
                detail: "8 km easy", fuel: "Water only", prep: nil, seq: seq,
                swimDetail: swim, strengthDetail: strength)
    }

    private var detail: SessionDetail {
        SessionDetail(total: "~20 min", tag: "On-ramp", focus: "Two easy rounds",
                      blocks: [Block(d: "5′", t: "Warm-up", x: "Easy movement", u: nil),
                               Block(d: "×10/leg", t: "Split squat", x: "Slow", u: "https://v/1"),
                               Block(d: "×8", t: "Row", x: "Squeeze", u: "https://v/2")])
    }

    private func plan(weeks: [Week], sessions: [Session],
                      exercises: [Exercise] = [],
                      fuel: Fuel? = nil, warmup: Warmup? = nil,
                      race: String = "2027-03-21") -> Plan {
        Plan(meta: meta(race: race), weeks: weeks, sessions: sessions,
             exercises: exercises, fuel: fuel, warmup: warmup)
    }

    // MARK: Identity and versioning

    /// The plan ships in the bundle and is replaced on app update. Importing the
    /// same bytes twice must not mint a second version — `contentHash` is
    /// unique in the schema, so this is the database enforcing it rather than
    /// the importer remembering.
    @Test("Re-importing an unchanged plan does not create a second version")
    func anUnchangedPlanIsNotReimported() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(weeks: [week("w1")], sessions: [session("s1", week: "w1")])

        let first = try Sub4Import.run(into: db, activities: [], shoes: [], plan: p)
        let second = try Sub4Import.run(into: db, activities: [], shoes: [], plan: p)

        #expect(first.planImported == 1)
        #expect(second.planImported == 0)
        #expect(second.planUnchanged == 1)

        let (versions, sessions) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_version") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_session") ?? -1)
        }
        #expect(versions == 1)
        #expect(sessions == 1, "the sessions were written a second time")
    }

    /// A changed plan is a new version alongside the old one — the point of
    /// keeping them is that a note written in March can still be read against
    /// the plan as it stood in March.
    @Test("A changed plan adds a version rather than replacing the old one")
    func aChangedPlanAddsAVersion() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1")]))
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1"),
                                                     session("s2", week: "w1", seq: 1)]))
        let versions = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_version") ?? -1
        }
        #expect(versions == 2)
    }

    /// `plan_version_one_active` is a unique partial index. The importer clears
    /// the previous timestamp before setting the new one; doing it the other way
    /// round violates the index halfway through.
    @Test("Exactly one version is active after a second import")
    func onlyOneVersionIsActive() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1")]))
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1"),
                                                     session("s2", week: "w1", seq: 1)]))
        let active = try db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM plan_version WHERE activatedUTC IS NOT NULL
                """) ?? -1
        }
        #expect(active == 1)
    }

    /// Two plans for two different races are two plans, not two versions.
    @Test("A plan for a different race is a separate plan")
    func adifferentRaceIsADifferentPlan() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1")]))
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1")],
                                          race: "2028-03-19"))
        let plans = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan") ?? -1
        }
        #expect(plans == 2)
    }

    // MARK: Session breakdowns

    /// THE STRUCTURAL ONE. 82 sessions carry a breakdown and the blocks are the
    /// prescription — without them `plan_session` holds a one-line summary of a
    /// session whose content is only in the bundle.
    @Test("A session breakdown and its blocks arrive in order")
    func aBreakdownArrivesInOrder() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1",
                                                             discipline: .strength,
                                                             strength: detail)]))
        let (kind, titles, urls) = try db.queue.read { d in
            (try String.fetchOne(d, sql: "SELECT kind FROM plan_session_detail"),
             try String.fetchAll(d, sql: """
                SELECT title FROM plan_session_block ORDER BY ordinal
                """),
             try String.fetchAll(d, sql: """
                SELECT videoURL FROM plan_session_block
                WHERE videoURL IS NOT NULL ORDER BY ordinal
                """))
        }
        #expect(kind == "strength")
        #expect(titles == ["Warm-up", "Split squat", "Row"])
        #expect(urls == ["https://v/1", "https://v/2"])
    }

    /// `breakdown` is `swimDetail ?? strengthDetail`, so the blocks alone cannot
    /// say which kind of session produced them. The column has to record which
    /// FIELD held it.
    @Test("A swim breakdown is recorded as a swim")
    func aSwimBreakdownKeepsItsKind() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1",
                                                             discipline: .swim,
                                                             swim: detail)]))
        let kind = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT kind FROM plan_session_detail")
        }
        #expect(kind == "swim")
    }

    /// One breakdown per session, stated in the schema. Two would mean one is
    /// unreachable in the app and present in the database.
    @Test("A session cannot hold two breakdowns")
    func oneBreakdownPerSession() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1")],
                                          sessions: [session("s1", week: "w1",
                                                             swim: detail,
                                                             strength: detail)]))
        let details = try db.queue.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_session_detail") ?? -1
        }
        #expect(details == 1, "both fields were written; the app reads only one")
    }

    // MARK: Weeks and refusals

    @Test("The document's own weekly totals are stored")
    func weekStatsAreStored() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [week("w1", stats: ["km": 42, "h": 8.5])],
                                          sessions: []))
        let rows = try db.queue.read { d in
            try Row.fetchAll(d, sql: "SELECT key, value FROM plan_week_stat ORDER BY key")
        }
        let keys = rows.map { $0["key"] as String? }
        let values = rows.map { $0["value"] as Double? }
        #expect(keys == ["h", "km"])
        #expect(values == [8.5, 42.0], "a half-hour week was narrowed to an integer")
    }

    /// A session naming a week that is not in the file is a broken plan. It is
    /// refused by name and the rest of the plan still arrives — the same rule
    /// as §12.2 for activities.
    @Test("A session naming a missing week is refused without costing the others")
    func anOrphanSessionIsRefusedAlone() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(
            into: db, activities: [], shoes: [],
            plan: plan(weeks: [week("w1")],
                       sessions: [session("good", week: "w1"),
                                  session("orphan", week: "nowhere", seq: 1)]))

        #expect(report.planSessions == 1)
        #expect(report.refusals.count == 1)
        let names = report.refusals.map(\.externalID)
        #expect(names == ["session orphan"])

        let uids = try db.queue.read { d in
            try String.fetchAll(d, sql: "SELECT uid FROM plan_session")
        }
        #expect(uids == ["good"])
    }

    // MARK: Fuel and warm-up

    @Test("The fuelling section arrives with its lists in order")
    func fuelArrives() throws {
        let db = try Sub4Database.inMemory()
        let fuel = Fuel(
            intro: "Practise it", timingRule: "Every 20 minutes",
            products: [.init(name: "Gel", carbs: "25 g", caffeine: "—", use: "Long runs"),
                       .init(name: "Leppin", carbs: "65 g", caffeine: nil, use: "Bottle")],
            perSession: [.init(session: "Long run", target: "~65 g/hr", take: "Bottle")],
            ladder: [.init(run: "18 km", carbs: "45 g", take: "One gel"),
                     .init(run: "24 km", carbs: "65 g", take: "Bottle + gel")],
            caution: .init(tag: "Careful", text: "Never new on race day"),
            raceDay: .init(intro: "The schema", before: ["Carb load", "Breakfast"],
                           timeline: [.init(time: "0:00", dist: "0 km", take: "Gel", total: "25 g")],
                           totals: "260 g", hydration: "500 ml/hr",
                           pacing: "5:41/km", caution: .init(tag: "Note", text: "Slow start")))

        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [], sessions: [], fuel: fuel))

        let (products, ladder, before, timing) = try db.queue.read { d in
            (try String.fetchAll(d, sql: "SELECT name FROM plan_fuel_product ORDER BY ordinal"),
             try String.fetchAll(d, sql: "SELECT run FROM plan_fuel_ladder ORDER BY ordinal"),
             try String.fetchAll(d, sql: "SELECT text FROM plan_fuel_race_before ORDER BY ordinal"),
             try String.fetchOne(d, sql: "SELECT timingRule FROM plan_fuel"))
        }
        #expect(products == ["Gel", "Leppin"])
        #expect(ladder == ["18 km", "24 km"], "the ladder came back out of order")
        #expect(before == ["Carb load", "Breakfast"])
        #expect(timing == "Every 20 minutes")
    }

    @Test("The warm-up arrives with its timeline in order")
    func warmupArrives() throws {
        let db = try Sub4Database.inMemory()
        let warmup = Warmup(
            intro: "Forty minutes",
            timeline: [.init(time: "-40:00", action: "Arrive", detail: nil),
                       .init(time: "-20:00", action: "Jog", detail: "10 minutes"),
                       .init(time: "0:00", action: "Gun", detail: nil)],
            circuit: [.init(movement: "Leg swings", dose: "×10/leg")],
            circuitNote: "Twice through",
            conditions: [.init(condition: "Cold", what: "Keep the layer on")],
            caution: .init(tag: "Note", text: "Do not sprint"))

        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               plan: plan(weeks: [], sessions: [], warmup: warmup))

        let (steps, movements, conditions) = try db.queue.read { d in
            (try String.fetchAll(d, sql: "SELECT time FROM plan_warmup_step ORDER BY ordinal"),
             try String.fetchAll(d, sql: "SELECT movement FROM plan_warmup_movement ORDER BY ordinal"),
             try String.fetchAll(d, sql: "SELECT condition FROM plan_warmup_condition ORDER BY ordinal"))
        }
        #expect(steps == ["-40:00", "-20:00", "0:00"],
                "the timeline order is the content and it did not survive")
        #expect(movements == ["Leg swings"])
        #expect(conditions == ["Cold"])
    }

    /// A plan.json produced before the extractor learned to read sections 09 and
    /// 10b decodes with both nil. Absent is a fact about the file, and nothing
    /// is written for it — not an empty row that later reads as "there is no
    /// fuelling advice".
    @Test("A plan with no fuel or warm-up writes neither")
    func absentSectionsWriteNothing() throws {
        let db = try Sub4Database.inMemory()
        let report = try Sub4Import.run(into: db, activities: [], shoes: [],
                                        plan: plan(weeks: [], sessions: []))
        #expect(report.planFuel == 0)
        #expect(report.planWarmup == 0)
        let (fuel, warmup) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_fuel") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_warmup") ?? -1)
        }
        #expect(fuel == 0)
        #expect(warmup == 0)
    }

    // MARK: The real plan

    /// THE ONE THAT MATTERS. Everything above uses fixtures I wrote, which
    /// contain exactly what I remembered to put in them — the same blind spot
    /// that let a schema ship with no home for 634 blocks. This imports the
    /// plan the app actually ships and asserts against the file's own counts.
    @Test("The bundled plan imports whole")
    func theBundledPlanImportsWhole() throws {
        let db = try Sub4Database.inMemory()
        let real = PlanStore.shared.plan
        let report = try Sub4Import.run(into: db, activities: [], shoes: [], plan: real)

        #expect(report.planImported == 1)
        #expect(report.refusals.isEmpty, "the bundled plan refused rows")

        // Counted from the type rather than hard-coded: a plan update changes
        // these numbers and should not fail the test, but a plan update that
        // silently stops importing a whole category should.
        let expectedDetails = real.sessions.filter {
            $0.swimDetail != nil || $0.strengthDetail != nil
        }.count
        let expectedBlocks = real.sessions.reduce(0) {
            $0 + ($1.swimDetail?.blocks.count ?? 0) + ($1.strengthDetail?.blocks.count ?? 0)
        }

        #expect(report.planWeeks == real.weeks.count)
        #expect(report.planSessions == real.sessions.count)
        #expect(report.planExercises == real.exercises.count)
        #expect(report.planDetails == expectedDetails)
        #expect(report.planBlocks == expectedBlocks)

        // And the rows are really there, not just counted.
        let (weeks, sessions, blocks) = try db.queue.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_week") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_session") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM plan_session_block") ?? -1)
        }
        #expect(weeks == real.weeks.count)
        #expect(sessions == real.sessions.count)
        #expect(blocks == expectedBlocks)
        #expect(blocks > 0, "the bundled plan carries no blocks at all")
    }

    /// Every session in the real plan resolves to a week in the same file. If
    /// this fails the plan itself is broken, not the importer — which is worth
    /// knowing separately from the count above.
    @Test("Every session in the bundled plan names a week that exists")
    func everyRealSessionHasItsWeek() {
        let real = PlanStore.shared.plan
        let uids = Set(real.weeks.map(\.uid))
        let orphans = real.sessions.filter { !uids.contains($0.weekUid) }
        #expect(orphans.isEmpty)
    }

    @Test("The new migration is declared and applied")
    func theMigrationIsDeclared() throws {
        #expect(Sub4Migrations.all.contains(Sub4Migrations.planContent))
        let db = try Sub4Database.inMemory()
        let applied = try db.integrityReport().appliedMigrations
        #expect(applied.contains(Sub4Migrations.planContent))
    }
}
