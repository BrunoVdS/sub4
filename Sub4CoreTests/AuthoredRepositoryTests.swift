//
//  AuthoredRepositoryTests.swift
//  Sub4CoreTests
//
//  The authored tables, read back — D6c slice 5b, patch 322, ADR-0003 §12.65.
//
//  WHAT THESE ARE FOR
//  ------------------
//  Two prove the round trip. The rest prove the comparison can FAIL, and three
//  of them are about traps this reader could have walked into silently:
//
//    `theCanonicalIdIsResolvedBack`
//        — `correction.subjectID` is the CANONICAL id and the store keys by
//          Strava's. A reader that returned the column would report four
//          decisions as lost, which is a join it got wrong. Third instance of
//          this trap: gear at 289, provenance at 317, this.
//
//    `anUnknownFeelIsSkippedNotNilled`
//        — mapping an unrecognised raw value to nil would turn a schema drift
//          into a silent data change.
//
//    `anUnknownFeelIsSkippedNotNilled` and `aSkippedRowIsADifference`
//        — PATCH 322b. Both failed on their SETUP, not their assertion:
//          `user_note.feel` carries a CHECK constraint and SQLite refused the
//          UPDATE that builds the row. They now force it past the constraint
//          and `theSchemaRefusesAnUnknownFeel` asserts the refusal that
//          stopped them, so the reason is in the file rather than in a
//          terminal.
//
//    `theTimestampsCompareAsTheWriterWroteThem`
//        — the importer's own formatter on both sides, so a sub-second
//          difference the column cannot hold is not reported as a divergence
//          and a real one still is.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
@MainActor
struct AuthoredRepositoryTests {

    // MARK: Fixtures

    private func note(_ uid: String = "s-w03-tue",
                      rpe: Int? = 5,
                      feel: NotesStore.Note.Feel? = .expected,
                      text: String = "First good run.",
                      created: Double = 1_785_000_000,
                      edited: Double = 1_785_000_060) -> NotesStore.Note {
        NotesStore.Note(sessionUid: uid, rpe: rpe, feel: feel, text: text,
                        created: Date(timeIntervalSince1970: created),
                        edited: Date(timeIntervalSince1970: edited))
    }

    private func ride(_ id: String = "19580875358") -> Activity {
        Activity(id: id, name: "Evening Ride", sportType: "Ride",
                 startLocal: "2026-07-28T18:02:00", distance: 24_300,
                 movingTime: 3_240, elapsedTime: 3_600,
                 elevationGain: 142, averageHeartrate: 131, isTrainer: false,
                 maxHeartrate: 168, gearId: nil, maxSpeed: 12.4,
                 deviceWatts: true, averageWatts: 168,
                 startUTC: "2026-07-28T16:02:00Z", startLat: 51.21, startLon: 4.41,
                 timeZoneIdentifier: "Europe/Brussels", startOffsetSeconds: 7200)
    }

    private func commute(_ id: String = "19580875358",
                         isCommute: Bool = true,
                         decided: Double = 1_785_000_000) -> CommuteDecision {
        CommuteDecision(activityId: id, isCommute: isCommute,
                        decided: Date(timeIntervalSince1970: decided))
    }

    // MARK: Writing what the schema forbids

    /// PATCH 322b, AND THE COMMENT IS THE POINT OF THE HELPER.
    ///
    /// `user_note.feel` carries
    /// `CHECK (feel IS NULL OR feel IN ('easier', 'expected', 'harder'))`, so
    /// the two tests that need an unreadable row could not build one: SQLite
    /// refused the UPDATE and they failed on the setup rather than on what
    /// they were written to assert.
    ///
    /// **The reader's skip branch is still live**, which is why the state is
    /// forced rather than the tests deleted. The constraint enumerates what
    /// THIS schema knows. A later migration widening the list — the migrations
    /// are append-only, so widening means a new one — produces exactly the row
    /// a binary compiled against the older `Feel` cannot map, and that binary
    /// must decline it rather than call it a nil feel.
    ///
    /// `DomainSchemaTests.feelsMatch` already pins the constraint's LIST
    /// against `Feel.allCases`. This does not restate it — §12.43.
    ///
    /// `writeWithoutTransaction` deliberately: the pragma is a connection
    /// setting, and this keeps it clear of a transaction boundary. It is turned
    /// off again before the connection goes back, so nothing after this call
    /// runs with the schema's checks disabled.
    private func forceUnknownFeel(_ db: Sub4Database,
                                  _ raw: String = "elated") throws {
        try db.queue.writeWithoutTransaction { d in
            try d.execute(sql: "PRAGMA ignore_check_constraints = ON")
            defer { try? d.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
            try d.execute(sql: "UPDATE user_note SET feel = ?", arguments: [raw])
        }
    }

    // MARK: Nothing there is not the same as could not look

    /// §12.15, the tenth instance. A fresh install has neither table populated
    /// and that is an answer.
    @Test("An empty database reads as empty and says so")
    func emptyIsAnAnswer() throws {
        let db = try Sub4Database.inMemory()
        let load = AuthoredRepository.load(db)

        #expect(load.isTrustworthy)
        #expect(load.notes?.isEmpty == true)
        #expect(load.commutes?.isEmpty == true)
        #expect(load.skipped == 0)
        #expect(load.line == "0 notes, 0 commute decisions.")
    }

    @Test("An untrustworthy read hands back nothing, not empty lists")
    func anUntrustworthyReadIsNotEmpty() {
        for load: AuthoredLoad in [.unavailable, .failed("the file is locked")] {
            #expect(!load.isTrustworthy)
            #expect(load.notes == nil,
                    "a caller must not reach [] without deciding what this means")
            #expect(load.commutes == nil)
        }
    }

    // MARK: The round trip

    @Test("A note survives the round trip, field by field")
    func theNoteRoundTrips() throws {
        let db = try Sub4Database.inMemory()
        let original = note()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [original])

        let back = try #require(AuthoredRepository.load(db).notes?.first)
        #expect(back.sessionUid == original.sessionUid)
        #expect(back.rpe == 5, "the figure that becomes an sRPE")
        #expect(back.feel == .expected)
        #expect(back.text == original.text)
        #expect(Sub4Import.iso8601(back.created)
                == Sub4Import.iso8601(original.created))
        #expect(Sub4Import.iso8601(back.edited)
                == Sub4Import.iso8601(original.edited))
    }

    /// An unanswered RPE is a real state and must not collapse to 0, which
    /// would drag every average down and read as an effortless session.
    @Test("A note with no RPE comes back with none, not zero")
    func anAbsentRPEStaysAbsent() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [],
                               notes: [note(rpe: nil, feel: nil)])
        let back = try #require(AuthoredRepository.load(db).notes?.first)
        #expect(back.rpe == nil)
        #expect(back.feel == nil)
    }

    /// THE THIRD INSTANCE OF THIS TRAP. `correction.subjectID` is the canonical
    /// activity id; `CommuteDecision.activityId` is Strava's. Reading the
    /// column straight through would hand the store an id matching nothing.
    @Test("A commute decision comes back keyed by the id the store uses")
    func theCanonicalIdIsResolvedBack() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               commutes: [commute()])

        let canonical = try db.queue.read { d in
            try String.fetchOne(d, sql: """
                SELECT subjectID FROM correction WHERE field = 'isCommute'
                """)
        }
        #expect(canonical != nil, "the importer resolved and wrote it")
        #expect(canonical != "19580875358", "and it wrote the CANONICAL id")

        let back = try #require(AuthoredRepository.load(db).commutes?.first)
        #expect(back.activityId == "19580875358",
                "the reader must hand back the id the store keys by")
        #expect(back.isCommute)
        #expect(Sub4Import.iso8601(back.decided)
                == Sub4Import.iso8601(commute().decided))
    }

    @Test("A decision of false comes back as false, not as absent")
    func falseIsNotAbsent() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               commutes: [commute(isCommute: false)])
        let back = try #require(AuthoredRepository.load(db).commutes?.first)
        #expect(back.isCommute == false)
    }

    // MARK: Rows this reader declines

    /// WHY THE TWO TESTS BELOW HAVE TO FORCE THE ROW — asserted rather than
    /// described. `feelsMatch` pins WHICH values the constraint lists; nothing
    /// pinned that the constraint is enforced at all, and patch 322 found that
    /// out by failing on it. A schema that stopped enforcing this would make
    /// `forceUnknownFeel` unnecessary and silently make these tests weaker;
    /// this is the line that would notice.
    @Test("The schema refuses an unknown feel through an ordinary write")
    func theSchemaRefusesAnUnknownFeel() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], notes: [note()])
        #expect(throws: DatabaseError.self) {
            try db.queue.write { d in
                try d.execute(sql: "UPDATE user_note SET feel = 'elated'")
            }
        }
    }

    /// Mapping an unrecognised `feel` to nil would turn a schema drift into a
    /// silent data change — the note would come back looking answered-with-
    /// nothing rather than unreadable.
    @Test("An unknown feel is skipped and counted, not nilled")
    func anUnknownFeelIsSkippedNotNilled() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], notes: [note()])
        try forceUnknownFeel(db)

        let load = AuthoredRepository.load(db)
        #expect(load.isTrustworthy, "the read itself worked")
        #expect(load.notes?.isEmpty == true)
        #expect(load.skipped == 1)
        #expect(load.line.contains("1 rows could not be read"))
    }

    /// `correction.value` is `String(Bool)`. Anything else is declined rather
    /// than guessed at, and a guess would silently flip a ride's eligibility.
    @Test("A correction value that is not a boolean is skipped and counted")
    func anUnparseableValueIsSkipped() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               commutes: [commute()])
        try db.queue.write { d in
            try d.execute(sql: "UPDATE correction SET value = 'maybe'")
        }
        let load = AuthoredRepository.load(db)
        #expect(load.commutes?.isEmpty == true)
        #expect(load.skipped == 1)
    }

    /// A skipped row is a difference, not a shrug — otherwise a reader that
    /// declined every row would agree with an empty store.
    @Test("A skipped row fails the comparison")
    func aSkippedRowIsADifference() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], notes: [note()])
        try forceUnknownFeel(db)
        let r = AuthoredRoundTrip.compare(storeNotes: [note()], storeCommutes: [],
                                          database: AuthoredRepository.load(db))
        #expect(r.rowsSkipped == 1)
        #expect(!r.isHealthy)
    }

    // MARK: The comparison

    @Test("The store and the database agree on every compared field")
    func theRealRoundTripAgrees() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               notes: [note()], commutes: [commute()])

        let r = AuthoredRoundTrip.compare(storeNotes: [note()],
                                          storeCommutes: [commute()],
                                          database: AuthoredRepository.load(db))
        #expect(r.notesCompared == 1)
        #expect(r.noteFieldsCompared == 5, "compared \(r.noteFieldsCompared)")
        #expect(r.commutesCompared == 1)
        #expect(r.commuteFieldsCompared == 2)
        #expect(r.totalCompared == 2)
        #expect(r.appNotesWithRPE == 1)
        #expect(r.databaseNotesWithRPE == 1)
        #expect(r.rpeLine == "1 vs 1")
        #expect(r.unexplained == 0, "differed on \(r.noteDifferences)")
        #expect(r.isHealthy)
    }

    /// Groundwork §2.1 case 2.
    @Test("Nothing compared is not a pass")
    func nothingComparedIsNotAPass() {
        let r = AuthoredRoundTrip.compare(storeNotes: [], storeCommutes: [],
                                          database: .loaded(notes: [], commutes: [],
                                                            skipped: 0))
        #expect(r.unexplained == 0)
        #expect(!r.lookedAtSomething)
        #expect(!r.isHealthy, "zero of zero must not read as healthy")
        #expect(r.summary == "nothing compared")
    }

    /// THE FIELD SLICE 3 DEPENDS ON. A wrong RPE is a wrong sRPE is a wrong
    /// training load for that session, with nothing on any chart looking broken.
    @Test("A changed RPE is caught and named")
    func aChangedRPEIsCaught() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [], notes: [note()])
        try db.queue.write { d in
            try d.execute(sql: "UPDATE user_note SET rpe = 9")
        }
        let r = AuthoredRoundTrip.compare(storeNotes: [note()], storeCommutes: [],
                                          database: AuthoredRepository.load(db))
        #expect(r.noteDifferences == ["s-w03-tue · rpe"])
        #expect(r.noteFieldsCompared == 5, "the denominator survives a difference")
        #expect(!r.isHealthy)
    }

    @Test("A changed feel, text and timestamp are each caught")
    func theOtherNoteFieldsAreCaught() {
        let stored = note()
        for altered in [note(feel: .harder),
                        note(text: "something else"),
                        note(edited: 1_785_999_999)] {
            let r = AuthoredRoundTrip.compare(
                storeNotes: [stored], storeCommutes: [],
                database: .loaded(notes: [altered], commutes: [], skipped: 0))
            #expect(r.noteDifferences.count == 1, "one field, not five")
            #expect(!r.isHealthy)
        }
    }

    /// The importer's own formatter on both sides. A sub-second difference the
    /// column cannot hold is not a divergence; a real one still is.
    @Test("Timestamps compare as the writer wrote them")
    func theTimestampsCompareAsTheWriterWroteThem() {
        let stored = note(created: 1_785_000_000.4)
        let back = note(created: 1_785_000_000)
        let r = AuthoredRoundTrip.compare(
            storeNotes: [stored], storeCommutes: [],
            database: .loaded(notes: [back], commutes: [], skipped: 0))
        #expect(r.noteDifferences.isEmpty,
                "four tenths of a second is below what the column holds")

        let later = note(created: 1_785_000_002)
        let real = AuthoredRoundTrip.compare(
            storeNotes: [stored], storeCommutes: [],
            database: .loaded(notes: [later], commutes: [], skipped: 0))
        #expect(real.noteDifferences == ["s-w03-tue · created"],
                "and two seconds is")
    }

    @Test("A changed commute decision is caught")
    func aChangedCommuteIsCaught() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               commutes: [commute()])
        try db.queue.write { d in
            try d.execute(sql: "UPDATE correction SET value = 'false'")
        }
        let r = AuthoredRoundTrip.compare(storeNotes: [], storeCommutes: [commute()],
                                          database: AuthoredRepository.load(db))
        #expect(r.commuteDifferences == ["19580875358 · isCommute"])
        #expect(!r.isHealthy)
    }

    // MARK: Membership

    @Test("A note the database does not have is counted")
    func aMissingNoteIsCounted() {
        let r = AuthoredRoundTrip.compare(
            storeNotes: [note("a"), note("b")], storeCommutes: [],
            database: .loaded(notes: [note("a")], commutes: [], skipped: 0))
        #expect(r.notesOnlyInApp == ["b"])
        #expect(r.notesCompared == 1)
        #expect(!r.isHealthy)
    }

    @Test("A note only in the database is counted")
    func aSurplusNoteIsCounted() {
        let r = AuthoredRoundTrip.compare(
            storeNotes: [note("a")], storeCommutes: [],
            database: .loaded(notes: [note("a"), note("b")], commutes: [],
                              skipped: 0))
        #expect(r.notesOnlyInDatabase == ["b"])
        #expect(!r.isHealthy)
    }

    /// ABSENT ON PURPOSE IS NOT ABSENT — §12.42.2, and patch 257's rule: the
    /// importer skips a decision about an ignored activity at the door, before
    /// it is even counted as seen. Reporting it as a loss would report a
    /// refusal as a fault.
    @Test("A commute decision about a refused activity is not a loss")
    func aDecisionAboutARefusedActivityIsNotMissing() throws {
        let refused = DataCorrections.ignoredActivities.keys.sorted().first
        let id = try #require(refused)

        let r = AuthoredRoundTrip.compare(
            storeNotes: [], storeCommutes: [commute("keep"), commute(id)],
            database: .loaded(notes: [], commutes: [commute("keep")], skipped: 0))
        #expect(r.commutesOnlyInApp.isEmpty,
                "the importer refuses it by name, so its absence is a decision")
        #expect(r.commutesCompared == 1)
        #expect(r.isHealthy)
    }

    // MARK: The approved list

    /// A DECISION RECORD, NOT A SUPPRESSION LIST. Both entries are columns the
    /// importer leaves NULL on purpose, with the reason written at the line
    /// that does it.
    @Test("Both approved differences carry a reason and a patch")
    func theApprovedListIsJustified() {
        #expect(AuthoredRoundTrip.approved.count == 2,
                "the list grew — every entry needs its own argument")
        for entry in AuthoredRoundTrip.approved {
            #expect(entry.patch == "322")
            #expect(entry.reason.count > 60, "an approved difference needs an argument")
            #expect(entry.field.hasPrefix("user_note."))
        }
        #expect(Set(AuthoredRoundTrip.approved.map(\.field))
                == ["user_note.activityID", "user_note.planVersionID"])
    }

    // MARK: The paste

    /// UNCONDITIONAL, every line, including the zeros — 266c's rule.
    /// A note's TEXT is compared and never printed.
    @Test("Every diagnostic line is present, and none of them is the note text")
    func theDiagnosticLinesAreUnconditional() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride()], shoes: [],
                               notes: [note()], commutes: [commute()])
        let lines = AuthoredRoundTrip.compare(storeNotes: [note()],
                                              storeCommutes: [commute()],
                                              database: AuthoredRepository.load(db))
            .diagnosticLines
        let text = lines.joined(separator: "\n")

        for expected in ["Authored read-back: 2 compared",
                         "notes in the app: 1",
                         "notes compared: 1",
                         "note fields compared: 5",
                         "notes only in the app: 0",
                         "note fields that differ: 0",
                         "notes carrying an RPE: 1 vs 1",
                         "commute decisions compared: 1",
                         "commute fields compared: 2",
                         "commute fields that differ: 0",
                         "rows the reader could not read: 0",
                         "approved differences: 2",
                         "unexplained differences: 0"] {
            #expect(text.contains(expected), "the paste is missing: \(expected)")
        }
        #expect(!text.contains("First good run"),
                "the athlete's own words must never reach the paste")
    }
}
