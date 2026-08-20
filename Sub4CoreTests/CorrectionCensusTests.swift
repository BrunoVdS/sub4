//
//  CorrectionCensusTests.swift
//  Sub4CoreTests
//
//  The residual over `correction` — patch 413, ADR-0003 §12.158.
//
//  WHAT THIS IS A TEST OF
//  ----------------------
//  On 20 August, mid-campaign, the census read `correction: 4` while the
//  authored read-back accounted for one commute decision and two moved
//  sessions. By the end of the same session both said six — the readers had
//  gained three while the table gained two, so a row that could not be seen
//  became visible. **Nothing reported either event.**
//
//  `rows the reader could not read` was 0 throughout, correctly: it counts rows
//  that came back and would not DECODE, and a row the join never returned has
//  nothing to fail at. The first test below is that morning, reconstructed.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("The correction table's residual")
struct CorrectionCensusTests {

    private func ride(_ id: String) -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 4000,
                 movingTime: 900, elapsedTime: 960,
                 elevationGain: 12, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: 8.0,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: "2026-07-28T16:02:00Z", startLat: nil, startLon: nil,
                 timeZoneIdentifier: nil, startOffsetSeconds: 7200)
    }

    /// A commute correction filed against an activity that has no alias — the
    /// shape `commuteSQL`'s INNER JOIN drops. Written with SQL because no
    /// public path produces it: `importCorrections` resolves through
    /// `canonicalActivity` and refuses to write when that returns nothing.
    private func orphanCommute(_ db: Sub4Database) throws {
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO correction
                  (id, accountID, subjectKind, subjectID, field,
                   value, reason, authoredUTC)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, Sub4Import.accountID,
                                 Sub4Import.commuteSubject, "no-such-activity",
                                 Sub4Import.commuteField, "true",
                                 "a row no reader returns",
                                 "2026-08-20T05:10:00Z"])
        }
    }

    // MARK: 1 — the morning of 20 August

    @Test("A row no reader returns is counted, and says it was not read")
    func theInvisibleRowIsCounted() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride("a-1")], shoes: [])
        #expect(CommuteRepository.upsert(
            CommuteDecision(activityId: "a-1", isCommute: true,
                            decided: Date(timeIntervalSince1970: 1_755_000_000)),
            in: db).committed)
        try orphanCommute(db)

        // WHAT THE READERS SEE. `AuthoredRepository.load` is the app's own
        // path, joined through `activity_alias`, and it returns one.
        guard case .loaded(_, let commutes, let skipped) = AuthoredRepository.load(db) else {
            Issue.record("the load should have succeeded")
            return
        }
        #expect(commutes.count == 1, "the orphan is invisible to the reader")
        #expect(skipped == 0,
                "and `skipped` cannot see it — the row never came back to fail")

        // WHAT THE TABLE HOLDS.
        let total = CorrectionCensus.rows(in: db)
        #expect(total == 2)

        let line = CorrectionCensus.line(total: total, commutesRead: commutes.count,
                                         movesRead: 0)
        #expect(line.contains("1 NOT READ BY EITHER"),
                "this is the line that would have shown 20 August's gap when it opened")
    }

    // MARK: 2 — the ordinary day says so out loud

    @Test("A table both readers account for says zero unaccounted")
    func theHealthyDaySaysZero() {
        let line = CorrectionCensus.line(total: 6, commutesRead: 3, movesRead: 3)
        #expect(line.contains("0 unaccounted"))
        #expect(!line.contains("NOT READ"))
        // §12.54.2: a residual that only printed when non-zero could not be
        // told from one nobody wired in, which is the defect being closed.
        #expect(line.contains("correction rows: 6"))
    }

    @Test("No count taken is not a count of zero")
    func nothingCountedIsItsOwnAnswer() {
        let line = CorrectionCensus.line(total: nil, commutesRead: 0, movesRead: 0)
        #expect(line.contains("not counted"))
        #expect(!line.contains("0 unaccounted"),
                "a read that did not happen must not read as a clean one")
        #expect(CorrectionCensus.rows(in: nil) == nil)
    }

    @Test("Readers returning more than the table holds is its own sentence")
    func theImpossibleDirectionIsNamed() {
        // It cannot happen from three queries against one table — so if it ever
        // prints, the premise that `correction` holds exactly two families has
        // broken. `max(0,)` would have hidden that. §12.15.
        let line = CorrectionCensus.line(total: 2, commutesRead: 2, movesRead: 1)
        #expect(line.contains("MORE than the table holds"))
    }
}
