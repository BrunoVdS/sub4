//
//  PlanExtrasRepositoryTests.swift
//  Sub4CoreTests
//
//  The plan's trimmings, read back — D6c slice 6c, patch 326, ADR-0003 §12.70.
//
//  WHAT THESE ARE FOR
//  ------------------
//  Two prove the round trip. The rest prove the comparison can FAIL, and three
//  guard decisions this reader could have got quietly wrong:
//
//    `eachCautionIsNamedByItsParent`
//        — Fuel.caution, Fuel.RaceDay.caution and Warmup.caution are one type
//          reached from three places. Compared as a set, an importer writing
//          one parent's caution into another compares EQUAL.
//
//    `aShuffledLadderIsADifference`
//        — every list here is a sequence with an ordinal column behind it. A
//          fuel ladder in the wrong order is a different instruction.
//
//    `anEmptyCautionAndNoCautionAreNotDistinguished`
//        — asserts the ambiguity rather than pretending it is resolved: two
//          NULL columns cannot say whether a Caution existed, which is why the
//          comparison walks tag and text and never the wrapper.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct PlanExtrasRepositoryTests {

    // MARK: Fixtures

    private var caution: Fuel.Caution {
        Fuel.Caution(tag: "Careful", text: "Nothing new on race day.")
    }

    private func fuel(ladder: [Fuel.LadderStep]? = nil,
                      raceDay: Fuel.RaceDay? = nil,
                      caution c: Fuel.Caution? = nil) -> Fuel {
        Fuel(intro: "Practise it.",
             timingRule: "Start at 40 minutes.",
             products: [Fuel.Product(name: "Leppin", carbs: "22 g",
                                     caffeine: nil, use: "Long runs"),
                        Fuel.Product(name: "Gel", carbs: "25 g",
                                     caffeine: "50 mg", use: "Race")],
             perSession: [Fuel.SessionTarget(session: "Long run",
                                             target: "60 g/hr", take: "Two gels"),
                          Fuel.SessionTarget(session: "Easy",
                                             target: nil, take: "Water only")],
             ladder: ladder ?? [Fuel.LadderStep(run: "16 km", carbs: "40 g",
                                                take: "One gel"),
                                Fuel.LadderStep(run: "26 km", carbs: "65 g",
                                                take: "Three gels")],
             caution: c ?? caution,
             raceDay: raceDay)
    }

    private var raceDay: Fuel.RaceDay {
        Fuel.RaceDay(intro: "The morning.",
                     before: ["Carb load Friday", "Porridge at 06:00"],
                     timeline: [Fuel.RaceDay.Step(time: "0:40", dist: "8 km",
                                                  take: "Gel", total: "25 g"),
                                Fuel.RaceDay.Step(time: "1:20", dist: "16 km",
                                                  take: "Gel", total: "50 g")],
                     totals: "~65 g/hr",
                     hydration: "250 ml every 5 km",
                     pacing: "Even.",
                     caution: Fuel.Caution(tag: "Race", text: "Do not chase."))
    }

    private func warmup(caution c: Fuel.Caution? = nil) -> Warmup {
        Warmup(intro: "Ninety minutes before.",
               timeline: [Warmup.Step(time: "−90", action: "Arrive",
                                      detail: "Bag drop"),
                          Warmup.Step(time: "−20", action: "Circuit",
                                      detail: "Twice through")],
               circuit: [Warmup.Movement(movement: "Leg swings", dose: "×10/leg"),
                         Warmup.Movement(movement: "Skips", dose: "20 m")],
               circuitNote: "Twice through, no rush.",
               conditions: [Warmup.Condition(condition: "Cold",
                                             what: "Keep the layer on")],
               caution: c ?? Fuel.Caution(tag: "Warm-up",
                                          text: "Not a workout."))
    }

    private func exercise(_ uid: String, name: String = "Back squat",
                          uses: Int = 4) -> Exercise {
        Exercise(uid: uid, name: name, videoUrl: "https://v/\(uid)",
                 cue: "Slow down, drive up", uses: uses)
    }

    private func plan(fuel f: Fuel? = nil, warmup w: Warmup? = nil,
                      exercises: [Exercise] = []) -> Plan {
        Plan(meta: Meta(plan: "Operation Sub-4", week1Monday: "2026-07-27",
                        raceDate: "2027-03-21", targetTime: "4:00:00",
                        targetPaceSecKm: 341),
             weeks: [Week(uid: "w1", weekNo: 1, label: "1", dateRange: nil,
                          startDate: "2026-07-27", tag: nil, badge: nil,
                          kind: nil, logged: false, stats: [:])],
             sessions: [], exercises: exercises, fuel: f, warmup: w)
    }

    @discardableResult
    private func imported(_ db: Sub4Database, _ p: Plan) throws -> Sub4Import.Report {
        try Sub4Import.run(into: db, activities: [], shoes: [], plan: p)
    }

    private func compare(_ db: Sub4Database, _ p: Plan) -> PlanExtrasRoundTrip.Report {
        PlanExtrasRoundTrip.compare(storeFuel: p.fuel,
                                    storeWarmup: p.warmup,
                                    storeExercises: p.exercises,
                                    database: PlanExtrasRepository.load(db))
    }

    // MARK: Nothing there is not the same as could not look

    @Test("An empty database says no plan has been imported")
    func emptyIsAnAnswer() throws {
        let db = try Sub4Database.inMemory()
        let load = PlanExtrasRepository.load(db)
        #expect(!load.isTrustworthy)
        #expect(load.exercises == nil, "not [] — the caller must decide")
        if case .noActiveVersion(let n) = load {
            #expect(n == 0)
        } else {
            Issue.record("expected .noActiveVersion, got \(load)")
        }
    }

    /// A PLAN WITH NO TRIMMINGS IS A REAL STATE, not a failure. `fuel` and
    /// `warmup` are optional on `Plan` so a plan.json produced before the
    /// extractor could read sections 09 and 10b still decodes.
    @Test("A plan with no fuelling section reads as loaded with none")
    func absentSectionsAreLoadedNotFailed() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan())

        let load = PlanExtrasRepository.load(db)
        #expect(load.isTrustworthy, "the read worked; there is simply nothing there")
        #expect(load.exercises?.isEmpty == true)
        if case .loaded(let f, let w, _, _) = load {
            #expect(f == nil)
            #expect(w == nil)
        } else {
            Issue.record("expected .loaded, got \(load)")
        }
        #expect(load.line.contains("no fuelling plan"))
        #expect(load.line.contains("no warm-up"))
    }

    @Test("An untrustworthy read hands back nothing, not empty lists")
    func anUntrustworthyReadIsNotEmpty() {
        for load: PlanExtrasLoad in [.unavailable, .failed("locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.exercises == nil)
        }
    }

    // MARK: The round trip

    @Test("The fuelling plan survives, field by field")
    func theFuelRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = fuel(raceDay: raceDay)
        try imported(db, plan(fuel: original))

        let load = PlanExtrasRepository.load(db)
        guard case .loaded(let back?, _, _, _) = load else {
            Issue.record("expected a fuelling plan, got \(load)"); return
        }
        #expect(back.intro == original.intro)
        #expect(back.timingRule == original.timingRule)
        #expect(back.caution?.tag == original.caution?.tag)
        #expect(back.caution?.text == original.caution?.text)
        #expect(back.products.count == 2)
        #expect(back.products.map(\.name) == ["Leppin", "Gel"], "ordinal order")
        #expect(back.products[1].caffeine == "50 mg")
        #expect(back.products[0].caffeine == nil, "an absence survives")
        #expect(back.perSession.count == 2)
        #expect(back.perSession[1].target == nil)
        #expect(back.ladder.map(\.run) == ["16 km", "26 km"])

        let r = try #require(back.raceDay)
        #expect(r.intro == raceDay.intro)
        #expect(r.before == ["Carb load Friday", "Porridge at 06:00"])
        #expect(r.timeline.count == 2)
        #expect(r.timeline[1].total == "50 g")
        #expect(r.totals == raceDay.totals)
        #expect(r.hydration == raceDay.hydration)
        #expect(r.pacing == raceDay.pacing)
        #expect(r.caution?.tag == "Race")
    }

    @Test("The warm-up survives, field by field")
    func theWarmupRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = warmup()
        try imported(db, plan(warmup: original))

        let load = PlanExtrasRepository.load(db)
        guard case .loaded(_, let back?, _, _) = load else {
            Issue.record("expected a warm-up, got \(load)"); return
        }
        #expect(back.intro == original.intro)
        #expect(back.circuitNote == original.circuitNote)
        #expect(back.caution?.tag == "Warm-up")
        #expect(back.timeline.map(\.action) == ["Arrive", "Circuit"])
        #expect(back.timeline[0].time == "−90")
        #expect(back.circuit.map(\.movement) == ["Leg swings", "Skips"])
        #expect(back.conditions.count == 1)
        #expect(back.conditions[0].what == "Keep the layer on")
    }

    @Test("The exercise library survives, keyed by uid")
    func theExercisesRoundTrip() throws {
        let db = try Sub4Database.inMemory()
        let library = [exercise("e1"), exercise("e2", name: "Row", uses: 7)]
        try imported(db, plan(exercises: library))

        let back = try #require(PlanExtrasRepository.load(db).exercises)
        #expect(back.count == 2)
        let byUid = Dictionary(back.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byUid["e2"]?.name == "Row")
        #expect(byUid["e2"]?.uses == 7)
        #expect(byUid["e1"]?.videoUrl == "https://v/e1")
        #expect(byUid["e1"]?.cue == "Slow down, drive up")
    }

    // MARK: The caution, three times

    /// ONE TYPE, THREE PARENTS. An importer writing the fuel caution into the
    /// warm-up's columns would compare EQUAL against a set of cautions and
    /// would draw the wrong warning on the race-day screen.
    @Test("Each caution is named by its parent")
    func eachCautionIsNamedByItsParent() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(fuel: fuel(raceDay: raceDay), warmup: warmup())
        try imported(db, p)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE plan_fuel SET cautionTag = 'Swapped'")
            try d.execute(sql: "UPDATE plan_warmup SET cautionText = 'Other'")
        }

        let r = compare(db, p)
        #expect(!r.isHealthy)
        #expect(r.fuelDifferences.contains("fuel · caution tag"))
        #expect(r.warmupDifferences.contains("warmup · caution text"))
        #expect(!r.fuelDifferences.contains("fuel · raceDay caution tag"),
                "the race-day caution is untouched and must not be implicated")
    }

    @Test("The race-day caution differs on its own")
    func theRaceDayCautionIsSeparate() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(fuel: fuel(raceDay: raceDay))
        try imported(db, p)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE plan_fuel SET raceCautionText = 'Changed'")
        }

        let r = compare(db, p)
        #expect(r.fuelDifferences == ["fuel · raceDay caution text"])
    }

    /// THE AMBIGUITY, ASSERTED RATHER THAN PAPERED OVER. `cautionTag` and
    /// `cautionText` both NULL means either "no caution" or "a caution with
    /// nothing in it", and no column distinguishes them. The reader chooses
    /// absent; the comparison never asks, because it walks tag and text.
    @Test("An empty caution and no caution are not distinguished")
    func anEmptyCautionAndNoCautionAreNotDistinguished() throws {
        let db = try Sub4Database.inMemory()
        let empty = Fuel.Caution(tag: nil, text: nil)
        let p = plan(fuel: fuel(caution: empty))
        try imported(db, p)

        let load = PlanExtrasRepository.load(db)
        guard case .loaded(let back?, _, _, _) = load else {
            Issue.record("expected a fuelling plan"); return
        }
        #expect(back.caution == nil, "two NULLs read back as absent")

        // AND THE COMPARISON STILL PASSES, which is the point: it asks about
        // tag and text, both nil on both sides.
        let r = compare(db, p)
        #expect(r.isHealthy)
    }

    // MARK: Order

    /// Every list here has a `UNIQUE(parent, ordinal)` behind it because these
    /// are sequences a person reads in order. A ladder in the wrong order is a
    /// different instruction.
    @Test("A shuffled ladder is a difference")
    func aShuffledLadderIsADifference() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(fuel: fuel())
        try imported(db, p)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE plan_fuel_ladder SET ordinal = 9 WHERE ordinal = 0")
            try d.execute(sql: "UPDATE plan_fuel_ladder SET ordinal = 0 WHERE ordinal = 1")
            try d.execute(sql: "UPDATE plan_fuel_ladder SET ordinal = 1 WHERE ordinal = 9")
        }

        let r = compare(db, p)
        #expect(!r.isHealthy)
        #expect(r.listDifferences.contains { $0.hasPrefix("ladder 0") })
        #expect(r.listDifferences.contains { $0.hasPrefix("ladder 1") })
    }

    @Test("A missing race-day line is a difference")
    func aMissingRaceBeforeLineIsCaught() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(fuel: fuel(raceDay: raceDay))
        try imported(db, p)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM plan_fuel_race_before WHERE ordinal = 1")
        }

        let r = compare(db, p)
        #expect(!r.isHealthy)
        #expect(r.listDifferences.contains { $0.contains("raceDay before · line count") })
    }

    // MARK: The comparison

    @Test("The store and the database agree on every compared field")
    func theRealRoundTripAgrees() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(fuel: fuel(raceDay: raceDay), warmup: warmup(),
                     exercises: [exercise("e1"), exercise("e2", name: "Row")])
        try imported(db, p)

        let r = compare(db, p)
        #expect(r.isHealthy)
        #expect(r.fuelFieldsCompared == 10, "two scalars, two cautions, six race-day")
        #expect(r.productsCompared == 2)
        #expect(r.productFieldsCompared == 8, "four per product")
        #expect(r.targetsCompared == 2)
        #expect(r.ladderStepsCompared == 2)
        #expect(r.raceBeforeCompared == 2)
        #expect(r.raceStepsCompared == 2)
        #expect(r.raceStepFieldsCompared == 8, "four per step")
        #expect(r.warmupFieldsCompared == 4)
        #expect(r.warmupStepsCompared == 2)
        #expect(r.movementsCompared == 2)
        #expect(r.conditionsCompared == 1)
        #expect(r.exercisesCompared == 2)
        #expect(r.exerciseFieldsCompared == 8, "four per exercise")
        #expect(r.appHasRaceDay && r.databaseHasRaceDay)
        #expect(r.unexplained == 0)
    }

    @Test("A changed field is caught and named")
    func aChangedFieldIsNamed() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(fuel: fuel(), warmup: warmup(),
                     exercises: [exercise("e1")])
        try imported(db, p)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE plan_fuel SET timingRule = 'Later'")
            try d.execute(sql: "UPDATE plan_warmup_movement SET dose = 'x99' "
                             + "WHERE ordinal = 0")
            try d.execute(sql: "UPDATE plan_exercise SET uses = 99")
        }

        let r = compare(db, p)
        #expect(!r.isHealthy)
        #expect(r.fuelDifferences == ["fuel · timingRule"])
        #expect(r.listDifferences.contains("movement 0 · dose"))
        #expect(r.exerciseDifferences == ["e1 · uses"])
        #expect(r.unexplained == 3)
    }

    @Test("An exercise missing from the database is named")
    func aMissingExerciseIsNamed() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(exercises: [exercise("e1"), exercise("e2")])
        try imported(db, p)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM plan_exercise WHERE uid = 'e2'")
        }

        let r = compare(db, p)
        #expect(r.exercisesOnlyInApp == ["e2"])
        #expect(!r.isHealthy)
    }

    @Test("Nothing compared is not a pass")
    func nothingComparedIsNotAPass() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan())
        let r = compare(db, plan())
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy)
        #expect(r.summary == "nothing compared")
    }

    // MARK: One copy of "which version" — §12.43

    /// The reader calls `PlanRepository.activeVersion` rather than resolving
    /// the version again, so the two-plans state §12.66.3 found is refused here
    /// without a second implementation to keep in step.
    @Test("Two plans each with an active version is refused here too")
    func theAmbiguityIsInheritedNotReimplemented() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(fuel: fuel()))
        var second = plan(fuel: fuel())
        second = Plan(meta: Meta(plan: "Operation Sub-4",
                                 week1Monday: "2026-07-27",
                                 raceDate: "2027-04-18",
                                 targetTime: "4:00:00", targetPaceSecKm: 341),
                      weeks: second.weeks, sessions: [], exercises: [],
                      fuel: second.fuel, warmup: nil)
        try imported(db, second)

        let load = PlanExtrasRepository.load(db)
        if case .ambiguousActiveVersion(let active, let plans) = load {
            #expect(active == 2)
            #expect(plans == 2)
        } else {
            Issue.record("expected .ambiguousActiveVersion, got \(load)")
        }
    }

    // MARK: The paste

    @Test("The diagnostic lines are unconditional")
    func theDiagnosticLinesAreUnconditional() {
        let lines = PlanExtrasRoundTrip.Report().diagnosticLines
        for needle in ["a fuelling plan on each side", "a race-day section",
                       "a warm-up on each side", "fuel fields compared",
                       "products compared", "session targets compared",
                       "ladder steps compared", "race-day lines compared",
                       "race-day steps compared", "warm-up fields compared",
                       "circuit movements compared", "conditions compared",
                       "exercises compared", "exercise fields compared",
                       "rows the reader could not read",
                       "approved differences", "unexplained differences"] {
            #expect(lines.contains { $0.contains(needle) },
                    "an empty report still prints \(needle)")
        }
    }
}
