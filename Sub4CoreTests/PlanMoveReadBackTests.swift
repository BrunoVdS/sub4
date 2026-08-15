//
//  PlanMoveReadBackTests.swift
//  Sub4CoreTests
//
//  The read-back covers the moves — patch 364, ADR-0003 §12.108.
//
//  THE ONE WITH A REAL FAILURE MODE IS `theUidIsReadBackWithoutAJoin`
//  ------------------------------------------------------------------
//  `commuteSQL` joins `activity_alias` and `decisionSQL` LEFT JOINs it, both
//  because their column holds the CANONICAL activity id while the store is
//  keyed by Strava's. Every neighbour of `moveSQL` joins. A reader that
//  followed the pattern would return NOTHING — for ever — and the comparison
//  would report every move the athlete made as lost.
//
//  Nothing about that failure is loud. It reads as data loss, which is the
//  worst possible disguise for a join somebody got wrong. §12.9 named it on the
//  weather, §12.19 on the match decisions, 289 on the gear.
//
//  AND `theDifferenceNamesTheFieldAndNeverTheDay`
//  ----------------------------------------------
//  `moveDifferences` is printed into the diagnostics file. A note's text is the
//  obvious thing §12.7 keeps out of it; `movedTo` is the quiet one — a date out
//  of the athlete's own training history. The difference says which FIELD
//  disagreed and never which day.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A moved session comes back out of the database")
@MainActor
struct PlanMoveReadBackTests {

    private let decidedAt = Date(timeIntervalSince1970: 1_786_000_000)
    private let session = "wk-03-sun-long"
    private let monday = "2026-08-17"

    private func ride(_ id: String = "19580875358") -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 4_000,
                 movingTime: 900, elapsedTime: 960,
                 elevationGain: 12, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 8.0,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T16:02:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    private func move(_ uid: String, _ day: String) -> PlanMove {
        PlanMove(sessionUid: uid, movedTo: day, decided: decidedAt)
    }

    private func commute(_ id: String = "19580875358") -> CommuteDecision {
        CommuteDecision(activityId: id, isCommute: true, decided: decidedAt)
    }

    /// A report built the way `ReadBacks.authored` builds one, with only the
    /// moves filled in. The other three families are empty on both sides, which
    /// is a clean comparison of nothing.
    private func compared(store: [PlanMove],
                          database: PlanMoveLoad) -> AuthoredRoundTrip.Report {
        var r = AuthoredRoundTrip.compare(storeNotes: [], storeCommutes: [],
                                          database: .loaded(notes: [],
                                                            commutes: [],
                                                            skipped: 0))
        AuthoredRoundTrip.compareMoves(store: store, database: database,
                                       into: &r)
        return r
    }

    // MARK: The read

    @Test("A stored move comes back with every field intact")
    func aStoredMoveComesBackWhole() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)])

        let load = PlanMoveRepository.load(db)
        #expect(load.isTrustworthy)
        #expect(load.holdsContent)
        #expect(load.skipped == 0)
        let moves = try #require(load.moves)
        #expect(moves.count == 1)
        let m = try #require(moves.first)
        #expect(m.sessionUid == session)
        #expect(m.movedTo == monday)
        // The instant the athlete decided, round-tripped through the writer's
        // own ISO-8601 option set.
        #expect(Sub4Import.iso8601(m.decided) == Sub4Import.iso8601(decidedAt))
    }

    /// **THE ONE THAT MATTERS.** Both neighbouring readers join
    /// `activity_alias`. A move's subject is the plan's own uid, so a join here
    /// finds nothing and every move reads as lost.
    @Test("The uid comes back verbatim, with no alias join")
    func theUidIsReadBackWithoutAJoin() throws {
        let db = try Sub4Database.inMemory()
        // An activity IS present, so a join would have a table to fail against
        // rather than an empty one — the failure has to be reachable.
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               moves: [move(session, monday)])

        let moves = try #require(PlanMoveRepository.load(db).moves)
        #expect(moves.count == 1, "the reader joined something and found nothing")
        #expect(moves.first?.sessionUid == session)
    }

    @Test("An empty table reads cleanly and holds nothing")
    func anEmptyTableIsAnAnswer() throws {
        let db = try Sub4Database.inMemory()
        let load = PlanMoveRepository.load(db)

        // §12.92. A clean read of nothing is not a failed read, and the two
        // verdicts are separate words for exactly this case.
        #expect(load.wasReadCleanly)
        #expect(!load.holdsContent)
        #expect(load.moves?.isEmpty == true)
        #expect(load.line.contains("0 moved sessions"))
    }

    /// §12.43 and §12.89. The reader declines what the writer would have
    /// refused, and counts what it declined.
    @Test("A value that is not a day key is declined and counted")
    func aValueThatIsNotADayKeyIsDeclined() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)])
        // Written straight in: `PlanMoveStore.set` refuses this before it
        // touches memory, so only something other than the store could put it
        // in the column — which is the case worth surfacing.
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO correction
                  (id, accountID, subjectKind, subjectID, field, value,
                   reason, authoredUTC)
                VALUES (?, ?, 'planSession', 'wk-04-tue-easy', 'date',
                        '17 August', 'hand-written', '2026-08-17T18:40:00Z')
                """, arguments: [UUID().uuidString, Sub4Import.accountID])
        }

        let load = PlanMoveRepository.load(db)
        #expect(load.skipped == 1)
        #expect(load.moves?.count == 1, "the good row still came back")
        #expect(load.line.contains("1 rows could not be read"))

        // AND IT SHOWS AS A DISAGREEMENT rather than as a store holding one
        // fewer move — the whole reason it is counted instead of dropped.
        let r = compared(store: [move(session, monday)], database: load)
        #expect(r.moveRowsSkipped == 1)
        #expect(r.unexplained == 1)
    }

    // MARK: The comparison

    @Test("A move on both sides agrees on both fields")
    func aMatchingMoveAgrees() throws {
        let db = try Sub4Database.inMemory()
        let mine = [move(session, monday)]
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], moves: mine)

        let r = compared(store: mine, database: PlanMoveRepository.load(db))
        #expect(r.movesWereRead)
        #expect(r.movesInApp == 1)
        #expect(r.movesInDatabase == 1)
        #expect(r.movesCompared == 1)
        #expect(r.moveFieldsCompared == 2, "movedTo and decided")
        #expect(r.moveDifferences.isEmpty)
        #expect(r.movesOnlyInApp.isEmpty)
        #expect(r.movesOnlyInDatabase.isEmpty)
        #expect(r.unexplained == 0)
        #expect(r.totalCompared == 1, "the moves reach the total")
    }

    @Test("A move the database does not have is named")
    func aMoveOnlyInTheAppIsNamed() throws {
        let db = try Sub4Database.inMemory()
        let r = compared(store: [move(session, monday)],
                         database: PlanMoveRepository.load(db))

        #expect(r.movesOnlyInApp == [session])
        #expect(r.movesOnlyInDatabase.isEmpty)
        #expect(r.unexplained == 1)
    }

    @Test("A move the app no longer holds is named")
    func aMoveOnlyInTheDatabaseIsNamed() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)])

        let r = compared(store: [], database: PlanMoveRepository.load(db))
        #expect(r.movesOnlyInDatabase == [session])
        #expect(r.movesOnlyInApp.isEmpty)
        #expect(r.unexplained == 1)
    }

    /// **§12.7.** The difference names the field. `movedTo` is a date out of the
    /// athlete's history and this list is printed into the diagnostics file.
    @Test("A changed day is a field difference that never says which day")
    func theDifferenceNamesTheFieldAndNeverTheDay() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)])

        // The store now says a different day. The database still holds Monday.
        let r = compared(store: [move(session, "2026-08-19")],
                         database: PlanMoveRepository.load(db))

        #expect(r.movesCompared == 1)
        #expect(r.moveDifferences == ["\(session) · movedTo"])
        #expect(r.unexplained == 1)

        for line in r.diagnosticLines {
            #expect(!line.contains(monday),
                    "a day out of the athlete's history reached the paste")
            #expect(!line.contains("2026-08-19"),
                    "so did the day it was moved to")
        }
    }

    @Test("A decided timestamp that differs is caught")
    func aChangedDecisionTimeIsCaught() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               moves: [move(session, monday)])

        let later = PlanMove(sessionUid: session, movedTo: monday,
                             decided: decidedAt.addingTimeInterval(3600))
        let r = compared(store: [later], database: PlanMoveRepository.load(db))
        #expect(r.moveDifferences == ["\(session) · decided"])
    }

    // MARK: What the paste says

    /// §12.15, and on this device it is the whole point: `moves.json` is empty
    /// until a gesture exists, so "both sides had nothing" is the expected
    /// reading and a forgotten call would imitate it perfectly.
    @Test("A report nobody gave the moves says so in capitals")
    func aReportNobodyGaveTheMovesSaysSo() {
        let r = AuthoredRoundTrip.Report()
        #expect(!r.movesWereRead)
        #expect(r.diagnosticLines.contains(where: {
            $0.contains("moved sessions were read: NO")
        }))
    }

    @Test("A report that was given them says yes, even when both are empty")
    func anEmptyComparisonStillSaysItRan() {
        let r = compared(store: [], database: .loaded(moves: [], skipped: 0))
        #expect(r.movesWereRead)
        #expect(r.diagnosticLines.contains(where: {
            $0.contains("moved sessions were read: yes")
        }))
        #expect(r.diagnosticLines.contains(where: {
            $0.contains("moved sessions in the app: 0")
        }))
        #expect(r.diagnosticLines.contains(where: {
            $0.contains("moved sessions compared: 0")
        }))
    }

    @Test("The skipped line names all three readers")
    func theSkippedLineNamesEveryReader() {
        let lines = AuthoredRoundTrip.Report().diagnosticLines
        let skipped = lines.first(where: {
            $0.contains("rows the reader could not read")
        })
        #expect(skipped?.contains("notes and commutes") == true)
        #expect(skipped?.contains("match decisions") == true)
        #expect(skipped?.contains("moved sessions") == true)
    }

    // MARK: The key that stopped being retyped

    /// The regression on 364's other half. `commuteSQL` now binds
    /// `Sub4Import.commuteSubject` and `commuteField` instead of spelling them,
    /// and a wrong binding does not throw — it returns nothing.
    @Test("The commute reader still reads after its key was bound")
    func theCommuteReaderStillReads() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               commutes: [commute()],
                               moves: [move(session, monday)])

        let authored = AuthoredRepository.load(db)
        let commutes = try #require(authored.commutes)
        #expect(commutes.count == 1, "the bound key found nothing")
        #expect(commutes.first?.activityId == "19580875358",
                "the alias join still reverses to the store's own id")
        #expect(authored.skipped == 0)
    }

    /// The two families share a table and must not read each other's rows.
    @Test("Neither reader returns the other family's rows")
    func theTwoReadersDoNotOverlap() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               commutes: [commute()],
                               moves: [move(session, monday)])

        let moves = try #require(PlanMoveRepository.load(db).moves)
        #expect(moves.count == 1)
        #expect(moves.first?.sessionUid == session)

        let commutes = try #require(AuthoredRepository.load(db).commutes)
        #expect(commutes.count == 1)
        #expect(commutes.first?.activityId != session)
    }

    // MARK: One parser

    /// §12.43. An unparseable timestamp becomes 1970 rather than nil, so the
    /// row shows as WRONG rather than as a row that vanished — and all three
    /// readers get that behaviour from one implementation now.
    @Test("An unparseable timestamp becomes 1970 rather than a lost row")
    func abadTimestampIsAWrongRowNotAMissingOne() throws {
        let db = try Sub4Database.inMemory()
        // An empty run seeds the account rather than this test knowing the
        // account table's shape — `ensureAccount` is the importer's job.
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO correction
                  (id, accountID, subjectKind, subjectID, field, value,
                   reason, authoredUTC)
                VALUES (?, ?, 'planSession', ?, 'date', ?, 'hand-written',
                        'not a timestamp')
                """, arguments: [UUID().uuidString, Sub4Import.accountID,
                                 session, monday])
        }

        let moves = try #require(PlanMoveRepository.load(db).moves)
        #expect(moves.count == 1, "the row is wrong, not absent")
        #expect(moves.first?.decided == Date(timeIntervalSince1970: 0))
        #expect(ColumnDate.parse("not a timestamp")
                == Date(timeIntervalSince1970: 0))
        #expect(ColumnDate.parse("2026-08-17T18:40:00Z")
                != Date(timeIntervalSince1970: 0))
    }
}
