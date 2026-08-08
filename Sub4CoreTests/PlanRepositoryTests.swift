//
//  PlanRepositoryTests.swift
//  Sub4CoreTests
//
//  The plan, read back — D6c slice 6b, patch 323, ADR-0003 §12.66.
//
//  WHAT THESE ARE FOR
//  ------------------
//  Two prove the round trip. The rest prove the comparison can FAIL, and three
//  of them guard traps this reader could have walked into silently:
//
//    `theWeekUidIsThePlansOwnAndNotTheRowId`
//        — `plan_session.planWeekID` is a UUID; `Session.weekUid` is "w1". The
//          column is spelled with "ID" and the field with "Uid" and they are
//          one letter apart. A reader returning the column would report all 260
//          sessions as differing while nothing was wrong. Fourth instance of
//          the canonical-id trap: 289, 317, 322, this.
//
//    `aStrengthBreakdownDoesNotComeBackAsASwim`
//        — `breakdown` is `swimDetail ?? strengthDetail`, so a reader that puts
//          a strength breakdown in the wrong property compares EQUAL on every
//          block and every field of the detail, and the session draws with the
//          wrong icon. `kind` exists in the schema for this and nothing checked
//          that it was used.
//
//    `onlyTheActiveVersionIsRead`
//        — three versions are stored on the device and the app holds one plan.
//          Reading them all would triple every count and report 520 phantom
//          sessions as "only in the database".
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct PlanRepositoryTests {

    // MARK: Fixtures

    private func meta(race: String = "2027-03-21") -> Meta {
        Meta(plan: "Operation Sub-4", week1Monday: "2026-07-27",
             raceDate: race, targetTime: "4:00:00", targetPaceSecKm: 341)
    }

    private func week(_ uid: String, no: Int? = 1,
                      logged: Bool = false,
                      stats: [String: Double] = ["km": 42, "h": 8.5]) -> Week {
        Week(uid: uid, weekNo: no, label: no.map(String.init) ?? "P1",
             dateRange: "27 Jul – 2 Aug", startDate: "2026-07-27",
             tag: "Base", badge: "Down", kind: "cut",
             logged: logged, stats: stats)
    }

    private func session(_ uid: String, week weekUid: String,
                         discipline: Discipline = .run,
                         intensity: Intensity? = .easy,
                         date: String? = "2026-07-27",
                         fuel: String? = "Water only",
                         swim: SessionDetail? = nil,
                         strength: SessionDetail? = nil,
                         seq: Int = 0) -> Session {
        Session(uid: uid, weekUid: weekUid, day: "Mon", date: date,
                discipline: discipline, intensity: intensity,
                title: "Easy run", detail: "8 km easy", fuel: fuel,
                prep: nil, seq: seq,
                swimDetail: swim, strengthDetail: strength)
    }

    private var detail: SessionDetail {
        SessionDetail(total: "~20 min", tag: "On-ramp", focus: "Two easy rounds",
                      blocks: [Block(d: "5′", t: "Warm-up", x: "Easy movement", u: nil),
                               Block(d: "×10/leg", t: "Split squat", x: "Slow", u: "https://v/1"),
                               Block(d: "×8", t: "Row", x: "Squeeze", u: "https://v/2")])
    }

    private func plan(weeks: [Week], sessions: [Session],
                      race: String = "2027-03-21") -> Plan {
        Plan(meta: meta(race: race), weeks: weeks, sessions: sessions,
             exercises: [], fuel: nil, warmup: nil)
    }

    @discardableResult
    private func imported(_ db: Sub4Database, _ p: Plan) throws -> Sub4Import.Report {
        try Sub4Import.run(into: db, activities: [], shoes: [], plan: p)
    }

    private func compare(_ db: Sub4Database, _ p: Plan) -> PlanRoundTrip.Report {
        PlanRoundTrip.compare(storeMeta: p.meta,
                              storeWeeks: p.weeks,
                              storeSessions: p.sessions,
                              database: PlanRepository.load(db))
    }

    // MARK: Writing what the schema forbids — patch 322b's helper, second use

    /// `plan_session.discipline` carries
    /// `CHECK (discipline IN ('run','bike','swim','strength','rest','other'))`,
    /// so the row this reader is built to decline cannot be written by an
    /// ordinary UPDATE. It is forced past the constraint for the same reason
    /// `AuthoredRepositoryTests.forceUnknownFeel` forces `feel`: the branch is
    /// live for a binary reading a database a later migration widened, and the
    /// constraint only rules out the state arising TODAY. §12.65.11.
    private func forceUnknownDiscipline(_ db: Sub4Database,
                                        _ raw: String = "kayak") throws {
        try db.queue.writeWithoutTransaction { d in
            try d.execute(sql: "PRAGMA ignore_check_constraints = ON")
            defer { try? d.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
            try d.execute(sql: "UPDATE plan_session SET discipline = ?",
                          arguments: [raw])
        }
    }

    @Test("The schema refuses an unknown discipline through an ordinary write")
    func theSchemaRefusesAnUnknownDiscipline() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(weeks: [week("w1")],
                              sessions: [session("s1", week: "w1")]))
        #expect(throws: DatabaseError.self) {
            try db.queue.write { d in
                try d.execute(sql: "UPDATE plan_session SET discipline = 'kayak'")
            }
        }
    }

    // MARK: Nothing there is not the same as could not look

    /// §12.15, the eleventh instance — and the first where the empty answer has
    /// TWO shapes. No plan imported and a plan imported but never activated are
    /// different states, and a reader that returned `[]` for both would let the
    /// second pass as the first.
    @Test("An empty database says no plan has been imported")
    func emptyIsAnAnswer() throws {
        let db = try Sub4Database.inMemory()
        let load = PlanRepository.load(db)

        #expect(!load.isTrustworthy)
        #expect(load.weeks == nil, "not [] — the caller must decide what this means")
        #expect(load.sessions == nil)
        if case .noActiveVersion(let n) = load {
            #expect(n == 0)
        } else {
            Issue.record("expected .noActiveVersion, got \(load)")
        }
        #expect(load.line == "No plan has been imported.")
    }

    /// A version stored and none active. The partial unique index permits zero
    /// as well as one, so this is a state the schema allows and the reader has
    /// to be able to name — it is not the same as an empty database and it is
    /// not a failure either.
    @Test("A stored but unactivated plan is named, not read as empty")
    func storedButNotActivatedIsItsOwnAnswer() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(weeks: [week("w1")],
                              sessions: [session("s1", week: "w1")]))
        try db.queue.write { d in
            try d.execute(sql: "UPDATE plan_version SET activatedUTC = NULL")
        }

        let load = PlanRepository.load(db)
        #expect(!load.isTrustworthy)
        if case .noActiveVersion(let n) = load {
            #expect(n == 1, "the version is still there — it is just not active")
        } else {
            Issue.record("expected .noActiveVersion, got \(load)")
        }
        #expect(load.line.contains("none is active"))
    }

    @Test("An untrustworthy read hands back nothing, not empty lists")
    func anUntrustworthyReadIsNotEmpty() {
        for load: PlanLoad in [.unavailable, .failed("the file is locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.weeks == nil)
            #expect(load.sessions == nil)
            #expect(load.meta == nil)
        }
    }

    // MARK: The round trip

    @Test("A week survives the round trip, field by field")
    func theWeekRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = week("w1", no: 14, stats: ["km": 42, "h": 8.5, "long": 26])
        try imported(db, plan(weeks: [original],
                              sessions: [session("s1", week: "w1")]))

        let back = try #require(PlanRepository.load(db).weeks?.first)
        #expect(back.uid == original.uid)
        #expect(back.weekNo == original.weekNo)
        #expect(back.label == original.label)
        #expect(back.dateRange == original.dateRange)
        #expect(back.startDate == original.startDate)
        #expect(back.tag == original.tag)
        #expect(back.badge == original.badge)
        #expect(back.kind == original.kind)
        #expect(back.logged == original.logged)
        #expect(back.stats == original.stats, "key by key, not just the count")
    }

    /// A prologue week has no number and no stats. §6: absent, not zero — a
    /// reader turning `weekNo` into 0 would put P1 before week 1 on every
    /// screen that sorts.
    @Test("A logged prologue week comes back with no number")
    func aLoggedWeekKeepsItsAbsences() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(weeks: [week("p1", no: nil, logged: true, stats: [:])],
                              sessions: [session("s1", week: "p1", date: nil)]))

        let back = try #require(PlanRepository.load(db).weeks?.first)
        #expect(back.weekNo == nil)
        #expect(back.logged)
        #expect(back.stats.isEmpty)
        let s = try #require(PlanRepository.load(db).sessions?.first)
        #expect(s.date == nil, "the prologue sessions carry no calendar date")
    }

    @Test("A session survives the round trip, field by field")
    func theSessionRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = session("s-w14-sat", week: "w1", discipline: .bike,
                               intensity: .threshold, fuel: "~65 g/hr", seq: 3)
        try imported(db, plan(weeks: [week("w1")], sessions: [original]))

        let back = try #require(PlanRepository.load(db).sessions?.first)
        #expect(back.uid == original.uid)
        #expect(back.weekUid == original.weekUid)
        #expect(back.day == original.day)
        #expect(back.date == original.date)
        #expect(back.discipline == original.discipline)
        #expect(back.intensity == original.intensity)
        #expect(back.title == original.title)
        #expect(back.detail == original.detail)
        #expect(back.fuel == original.fuel)
        #expect(back.prep == original.prep)
        #expect(back.seq == original.seq)
    }

    @Test("The plan's own header survives")
    func theMetaRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(weeks: [week("w1")], sessions: [session("s1", week: "w1")])
        try imported(db, p)

        let back = try #require(PlanRepository.load(db).meta)
        #expect(back.plan == p.meta.plan)
        #expect(back.week1Monday == p.meta.week1Monday)
        #expect(back.raceDate == p.meta.raceDate)
        #expect(back.targetTime == p.meta.targetTime)
        #expect(back.targetPaceSecKm == p.meta.targetPaceSecKm)
    }

    // MARK: The canonical-id trap, fourth instance

    /// THE ONE THAT WOULD HAVE BROKEN EVERY SESSION AT ONCE.
    ///
    /// `plan_session.planWeekID` is a UUID minted by the importer.
    /// `Session.weekUid` is the plan's own "w1". Returning the column instead
    /// of joining `plan_week` compiles, type-checks, reads plausibly, and makes
    /// all 260 sessions report a `weekUid` difference with the data intact.
    @Test("weekUid comes back as the plan's own uid, not the row id")
    func theWeekUidIsThePlansOwnAndNotTheRowId() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(weeks: [week("w1")],
                              sessions: [session("s1", week: "w1")]))

        let stored = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT planWeekID FROM plan_session")
        }
        let weekID = try #require(stored)
        #expect(weekID != "w1", "the column holds a row id, not the plan's uid")
        #expect(weekID.count == 36, "a UUID, which is what makes this inviting")

        let back = try #require(PlanRepository.load(db).sessions?.first)
        #expect(back.weekUid == "w1",
                "the reader must hand back the uid the app keys weeks by")
    }

    // MARK: Breakdowns

    @Test("A swim breakdown comes back as a swim, blocks in order")
    func theSwimBreakdownRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = session("s1", week: "w1", discipline: .swim, swim: detail)
        try imported(db, plan(weeks: [week("w1")], sessions: [original]))

        let back = try #require(PlanRepository.load(db).sessions?.first)
        #expect(back.swimDetail != nil)
        #expect(back.strengthDetail == nil)

        let d = try #require(back.breakdown)
        #expect(d.total == detail.total)
        #expect(d.tag == detail.tag)
        #expect(d.focus == detail.focus)
        #expect(d.blocks.count == 3)
        #expect(d.blocks.map(\.t) == ["Warm-up", "Split squat", "Row"],
                "ordinal order, not insertion or hash order")
        #expect(d.blocks[1].d == "×10/leg")
        #expect(d.blocks[1].x == "Slow")
        #expect(d.blocks[2].u == "https://v/2")
        #expect(d.blocks[0].u == nil, "a block with no video keeps its absence")
    }

    /// `breakdown` is `swimDetail ?? strengthDetail`, so putting a strength
    /// breakdown in the wrong property compares EQUAL on every block and every
    /// field. What changes is the icon the session draws with. `kind` is in the
    /// schema for exactly this and nothing had ever checked it was read.
    @Test("A strength breakdown does not come back as a swim")
    func aStrengthBreakdownDoesNotComeBackAsASwim() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(weeks: [week("w1")],
                              sessions: [session("s1", week: "w1",
                                                 discipline: .strength,
                                                 strength: detail)]))

        let back = try #require(PlanRepository.load(db).sessions?.first)
        #expect(back.strengthDetail != nil)
        #expect(back.swimDetail == nil,
                "the same blocks in the other property would compare equal")
        #expect(back.breakdown?.blocks.count == 3)
    }

    @Test("A session with no breakdown comes back with neither property set")
    func noBreakdownIsNotAnEmptyOne() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(weeks: [week("w1")],
                              sessions: [session("s1", week: "w1")]))
        let back = try #require(PlanRepository.load(db).sessions?.first)
        #expect(back.swimDetail == nil)
        #expect(back.strengthDetail == nil)
        #expect(back.breakdown == nil, "not an empty SessionDetail")
    }

    // MARK: Versions

    /// THE REASON THE DEVICE SHOWS 260 AGAINST 780. Three imports of the same
    /// content leave three versions; the app holds one plan. Reading them all
    /// would report every session three times over.
    @Test("Only the active version is read, and the raw totals are still reported")
    func onlyTheActiveVersionIsRead() throws {
        let db = try Sub4Database.inMemory()
        let first = plan(weeks: [week("w1")],
                         sessions: [session("s1", week: "w1"),
                                    session("s2", week: "w1", seq: 1)])
        // SAME plan header, different sessions — which is what a re-extracted
        // plan.json looks like. The content hash changes, so this mints and
        // activates a second version OF THE SAME PLAN. Changing the race date
        // instead would mint a second PLAN, which is the other test below.
        let second = plan(weeks: [week("w1")],
                          sessions: [session("s1", week: "w1")])
        try imported(db, first)
        try imported(db, second)

        let load = PlanRepository.load(db)
        #expect(load.sessions?.count == 1, "the active version has one session")
        #expect(load.rows.sessions == 3, "and the table holds both versions' rows")
        #expect(load.rows.plans == 1, "one plan, two versions of it")
        #expect(load.version?.versionsPresent == 2)

        let r = compare(db, second)
        #expect(r.isHealthy)
        #expect(r.versionLine == "1 of 3 rows · 2 versions")
    }

    /// THE STATE THE SCHEMA ALLOWS AND NOTHING RESOLVES.
    ///
    /// `plan_version_one_active` is `UNIQUE(planID) WHERE activatedUTC IS NOT
    /// NULL` — one active version PER PLAN. `upsertPlan` keys the plan row on
    /// `(week1Monday, raceDate)`, so moving the race date mints a second plan,
    /// and `activate` clears the flag only within one planID. Two active
    /// versions, both legal, and nothing anywhere says which the app runs.
    ///
    /// A `fetchOne` would have picked one and been right by luck until the day
    /// the race moved.
    @Test("Two plans each with an active version is named, not silently picked")
    func twoActivePlansAreAmbiguous() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(weeks: [week("w1")],
                              sessions: [session("s1", week: "w1")]))
        // A different race date is a different plan, not a different version.
        try imported(db, plan(weeks: [week("w1")],
                              sessions: [session("s1", week: "w1")],
                              race: "2027-04-18"))

        let activeCount = try db.queue.read { d in
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM plan_version WHERE activatedUTC IS NOT NULL
                """) ?? 0
        }
        #expect(activeCount == 2, "the schema permits this — one per plan")

        let load = PlanRepository.load(db)
        #expect(!load.isTrustworthy)
        #expect(load.sessions == nil, "no guess is made")
        if case .ambiguousActiveVersion(let active, let plans) = load {
            #expect(active == 2)
            #expect(plans == 2)
        } else {
            Issue.record("expected .ambiguousActiveVersion, got \(load)")
        }
        #expect(load.line.contains("which plan the app is running"))
    }

    // MARK: Rows this reader declines

    /// Mapping an unrecognised discipline to `.other` would turn a schema drift
    /// into a silent data change — a kayak session would read as an "other" and
    /// nothing on any screen would say a value had been lost.
    /// `Discipline.init(from:)` does exactly that, deliberately, when decoding
    /// the bundled file. This is the other side of that boundary.
    @Test("An unknown discipline is skipped and counted, not mapped to other")
    func anUnknownDisciplineIsSkippedNotMapped() throws {
        let db = try Sub4Database.inMemory()
        try imported(db, plan(weeks: [week("w1")],
                              sessions: [session("s1", week: "w1")]))
        try forceUnknownDiscipline(db)

        let load = PlanRepository.load(db)
        #expect(load.isTrustworthy, "the read itself worked")
        #expect(load.sessions?.isEmpty == true)
        #expect(load.skipped == 1)
        #expect(load.weeks?.count == 1, "the weeks are unaffected")
    }

    /// A skipped row is a difference, not a shrug — otherwise a reader that
    /// declined every session would agree with an empty plan.
    @Test("A skipped row fails the comparison")
    func aSkippedRowIsADifference() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(weeks: [week("w1")], sessions: [session("s1", week: "w1")])
        try imported(db, p)
        try forceUnknownDiscipline(db)

        let r = compare(db, p)
        #expect(r.rowsSkipped == 1)
        #expect(!r.isHealthy)
        #expect(r.sessionsOnlyInApp == ["s1"])
    }

    // MARK: The comparison

    @Test("The store and the database agree on every compared field")
    func theRealRoundTripAgrees() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(weeks: [week("w1"), week("w2", no: 2)],
                     sessions: [session("s1", week: "w1", swim: detail),
                                session("s2", week: "w2", seq: 1)])
        try imported(db, p)

        let r = compare(db, p)
        #expect(r.isHealthy)
        #expect(r.weeksCompared == 2)
        #expect(r.sessionsCompared == 2)
        #expect(r.metaFieldsCompared == 5)
        #expect(r.weekFieldsCompared == 18, "nine per week")
        #expect(r.sessionFieldsCompared == 22, "eleven per session")
        #expect(r.weekStatsCompared == 4, "two keys on each of two weeks")
        #expect(r.breakdownsCompared == 1)
        #expect(r.blocksCompared == 3)
        #expect(r.blockFieldsCompared == 12, "four per block")
        #expect(r.unexplained == 0)
    }

    /// The comparison has to be able to fail on each shape independently, or a
    /// pass says nothing about which parts were examined.
    @Test("A changed field is caught and named")
    func aChangedFieldIsNamed() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(weeks: [week("w1")],
                     sessions: [session("s1", week: "w1", swim: detail)])
        try imported(db, p)
        try db.queue.write { d in
            try d.execute(sql: "UPDATE plan_session SET title = 'Something else'")
            try d.execute(sql: "UPDATE plan_week SET badge = 'Peak long run'")
            try d.execute(sql: "UPDATE plan_week_stat SET value = 99 WHERE key = 'km'")
            try d.execute(sql: "UPDATE plan_session_block SET title = 'Wrong' "
                             + "WHERE ordinal = 1")
        }

        let r = compare(db, p)
        #expect(!r.isHealthy)
        #expect(r.sessionDifferences.contains("s1 · title"))
        #expect(r.weekDifferences.contains("w1 · badge"))
        #expect(r.weekStatDifferences.contains("w1 · stat km"))
        #expect(r.blockDifferences.contains("s1 · block 1 · title"))
        #expect(r.unexplained == 4)
    }

    /// A block moved rather than changed. Comparing the blocks as a set would
    /// call this identical, and the session would read in the wrong order.
    @Test("Reordered blocks are a difference")
    func reorderedBlocksAreCaught() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(weeks: [week("w1")],
                     sessions: [session("s1", week: "w1", swim: detail)])
        try imported(db, p)
        try db.queue.write { d in
            // Swap ordinals 0 and 2 through a temporary, since the pair is unique.
            try d.execute(sql: "UPDATE plan_session_block SET ordinal = 9 WHERE ordinal = 0")
            try d.execute(sql: "UPDATE plan_session_block SET ordinal = 0 WHERE ordinal = 2")
            try d.execute(sql: "UPDATE plan_session_block SET ordinal = 2 WHERE ordinal = 9")
        }

        let r = compare(db, p)
        #expect(!r.isHealthy)
        #expect(r.blockDifferences.contains { $0.hasPrefix("s1 · block 0") })
        #expect(r.blockDifferences.contains { $0.hasPrefix("s1 · block 2") })
    }

    @Test("A session missing from the database is named, not silently dropped")
    func aMissingSessionIsNamed() throws {
        let db = try Sub4Database.inMemory()
        let p = plan(weeks: [week("w1")],
                     sessions: [session("s1", week: "w1"),
                                session("s2", week: "w1", seq: 1)])
        try imported(db, p)
        try db.queue.write { d in
            try d.execute(sql: "DELETE FROM plan_session WHERE uid = 's2'")
        }

        let r = compare(db, p)
        #expect(r.sessionsOnlyInApp == ["s2"])
        #expect(r.sessionsOnlyInDatabase.isEmpty)
        #expect(!r.isHealthy)
    }

    /// Zero compared is a failure here, unlike the authored read-back where an
    /// empty side is a real state. Every device that has launched has a plan.
    @Test("Nothing compared is not a pass")
    func nothingComparedIsNotAPass() throws {
        let db = try Sub4Database.inMemory()
        let r = compare(db, plan(weeks: [], sessions: []))
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy)
        #expect(r.summary == "nothing compared")
    }

    // MARK: The paste

    /// UNCONDITIONAL, every line, including the zeros — §12.54.2. A row that
    /// vanishes at zero cannot be told from a row nobody wired in.
    @Test("The diagnostic lines are unconditional")
    func theDiagnosticLinesAreUnconditional() {
        let lines = PlanRoundTrip.Report().diagnosticLines
        for needle in ["weeks compared", "week stats compared",
                       "sessions compared", "session fields compared",
                       "blocks compared", "block fields compared",
                       "sessions carrying a date",
                       "sessions carrying a fuelling line",
                       "plans stored",
                       "rows in the tables, all versions",
                       "rows the reader could not read",
                       "approved differences", "unexplained differences",
                       "versions stored", "active version"] {
            #expect(lines.contains { $0.contains(needle) },
                    "an empty report still prints \(needle)")
        }
        #expect(lines.contains { $0.contains("approved differences: none") },
                "the absence of a list is stated, not left off")
    }
}
