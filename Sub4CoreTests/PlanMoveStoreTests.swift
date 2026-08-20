//
//  PlanMoveStoreTests.swift
//  Sub4CoreTests
//
//  When a session was actually done — patch 362, ADR-0003 §12.106.
//
//  SAME RULE AS `CommuteWriteTests`: every test that matters makes a REAL
//  write fail first, by pointing the store at a directory that is not there.
//  Nothing is mocked, because a mocked write cannot fail the way a disk does.
//
//  THE TWO WORTH READING
//  ---------------------
//  `aMalformedDayIsRefusedBeforeAnythingIsTouched` — the rejection has to
//  happen before memory changes, not after. A store that accepted "17 August",
//  wrote it, and let the comparison match nothing would report "no moves" for
//  ever, which is the failure shape this project keeps finding.
//
//  `theStoreIsNotWiredIntoAnything` — 362 is machinery. The store exists, the
//  file exists, every declaration site knows about it, and NOTHING reads it.
//  That test is what lets the next patch have a diff containing only the
//  wiring.
//

import Testing
import Foundation
@testable import Sub4

@Suite("A session can be recorded as done on another day")
@MainActor
struct PlanMoveStoreTests {

    private func writableDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moves-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func unwritableDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moves-missing-\(UUID().uuidString)", isDirectory: true)
    }

    private let session = "w03-sun-long"
    private let monday = "2026-08-17"

    // MARK: When it lands

    @Test("A move that saves survives a reopen")
    func aGoodMoveLands() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        try store.set(monday, for: session)
        #expect(store.movedTo(session) == monday)

        let reopened = PlanMoveStore(directory: dir)
        #expect(reopened.movedTo(session) == monday,
                "the file did not carry the move back")
    }

    /// THE DATE THE ATHLETE SAID SO, not the day moved to. `correction
    /// .authoredUTC` is what this becomes, and the two are different days by
    /// construction — you record a move after the session, not on it.
    @Test("The record keeps when it was decided, not where it was moved to")
    func theDecisionCarriesItsOwnDate() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        let when = Date(timeIntervalSince1970: 1_786_000_000)
        try store.set(monday, for: session, now: when)

        let reopened = PlanMoveStore(directory: dir)
        let move = try #require(reopened.moves[session])
        #expect(move.movedTo == monday)
        #expect(move.decided == when, "ISO-8601 did not round-trip the instant")
        #expect(move.sessionUid == session)
        #expect(move.id == session)
    }

    @Test("Moving it back survives a reopen too")
    func aGoodClearLands() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        try store.set(monday, for: session)
        try store.clear(session)
        // Nil, not the planned date. "I moved it back" and "I never moved it"
        // are the same end state; a row asserting an override that overrides
        // nothing is not.
        #expect(store.movedTo(session) == nil)

        let reopened = PlanMoveStore(directory: dir)
        #expect(reopened.movedTo(session) == nil)
        #expect(reopened.count == 0)
    }

    @Test("A second move on the same session replaces the first")
    func aSessionHasOneMove() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        try store.set(monday, for: session)
        try store.set("2026-08-18", for: session)

        #expect(store.count == 1, "the file is keyed by session uid")
        #expect(store.movedTo(session) == "2026-08-18")
    }

    // MARK: The day key

    /// **THE ONE THAT MATTERS.** A malformed day must be refused BEFORE memory
    /// changes. Accepting it would store a value that matches no session, which
    /// reads as "nothing was moved" rather than as an error.
    @Test("A malformed day is refused before anything is touched")
    func aMalformedDayIsRefusedBeforeAnythingIsTouched() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)

        #expect(throws: PlanMoveFault.notADayKey("17 August")) {
            try store.set("17 August", for: session)
        }
        #expect(store.count == 0, "a refused move reached memory")
        #expect(store.movedTo(session) == nil)

        let reopened = PlanMoveStore(directory: dir)
        #expect(reopened.count == 0, "a refused move reached the disk")
    }

    /// A refusal that also overwrote a good answer would be worse than
    /// accepting the bad one.
    @Test("A refused move leaves an existing one alone")
    func aRefusalDoesNotDisturbWhatIsThere() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        try store.set(monday, for: session)
        try? store.set("tomorrow", for: session)

        #expect(store.movedTo(session) == monday)
    }

    @Test("The shapes the plan can name are accepted and the others are not")
    func theDayKeyShapeIsPinned() {
        for good in ["2026-08-17", "2027-03-21", "2026-01-01", "2026-12-31"] {
            #expect(PlanMove.isDayKey(good), "a real plan day key was refused")
        }
        for bad in ["17 August", "2026-8-17", "26-08-17", "2026-08-17T00:00:00Z",
                    "2026/08/17", "", "2026-13-01", "2026-08-32", "2026-08-",
                    "٢٠٢٦-٠٨-١٧"] {
            #expect(!PlanMove.isDayKey(bad), "a value the plan never writes was accepted")
        }
    }

    /// STATED, NOT FIXED. A shape check is a shape check; `2026-02-31` is not a
    /// day and this accepts it. The header says why that is harmless — nothing
    /// parses this value, so a day that does not exist matches no session.
    @Test("The shape check does not pretend to be a calendar")
    func theShapeCheckKnowsItsLimit() {
        #expect(PlanMove.isDayKey("2026-02-31"))
    }

    // MARK: When the write does not land

    @Test("A move that cannot be written throws")
    func aFailedMoveThrows() {
        let store = PlanMoveStore(directory: unwritableDirectory())
        #expect(throws: StoreWriteError.self) {
            try store.set(monday, for: session)
        }
    }

    @Test("A failed first move leaves no move behind")
    func aFailedMoveRollsBack() {
        let store = PlanMoveStore(directory: unwritableDirectory())
        try? store.set(monday, for: session)
        #expect(store.count == 0)
        #expect(store.movedTo(session) == nil)
    }

    @Test("A failed change leaves the previous move readable")
    func aFailedChangeKeepsTheOldAnswer() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        try store.set(monday, for: session)
        try FileManager.default.moveItem(at: dir,
                                         to: dir.appendingPathExtension("gone"))
        try? store.set("2026-08-19", for: session)

        #expect(store.movedTo(session) == monday,
                "the move a screen would render changed without a write")
    }

    @Test("A failed clear leaves the move readable")
    func aFailedClearKeepsTheOldAnswer() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        try store.set(monday, for: session)
        try FileManager.default.moveItem(at: dir,
                                         to: dir.appendingPathExtension("gone"))
        try? store.clear(session)

        #expect(store.movedTo(session) == monday,
                "the session went back to its planned day without a write")
    }

    @Test("Clearing a session that never moved writes nothing and throws nothing")
    func clearingNothingIsNotAFailure() throws {
        // §12.15. An absent record is an answer, not a fault — and a `clear`
        // that threw here would make the UI report a write failure for a
        // gesture that had nothing to do.
        let store = PlanMoveStore(directory: unwritableDirectory())
        try store.clear(session)
        #expect(store.count == 0)
    }

    @Test("The failure names moves.json")
    func theStoreIsNamed() throws {
        let store = PlanMoveStore(directory: unwritableDirectory())
        do {
            try store.set(monday, for: session)
            Issue.record("the write succeeded, so this test proves nothing")
        } catch let error as StoreWriteError {
            #expect(error.store == "moves.json")
            #expect(error.stage == .writing)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: Order

    @Test("The moves come back newest decision first")
    func theOrderIsByDecision() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        try store.set(monday, for: "w03-sun-long",
                      now: Date(timeIntervalSince1970: 1_786_000_000))
        try store.set("2026-08-20", for: "w04-tue-easy",
                      now: Date(timeIntervalSince1970: 1_786_400_000))

        // A dictionary has no order, so without this the report and any screen
        // would list them differently on each run.
        #expect(store.all.map(\.sessionUid) == ["w04-tue-easy", "w03-sun-long"])
    }

    @Test("Dropping memory does not write an empty file")
    func dropInMemoryLeavesTheFile() throws {
        let dir = try writableDirectory()
        let store = PlanMoveStore(directory: dir)
        try store.set(monday, for: session)
        store.dropInMemory()
        #expect(store.count == 0)

        // The file is still there. `deleteEverything` removes it separately;
        // a `dropInMemory` that saved would recreate the store it had just
        // been asked to forget.
        let reopened = PlanMoveStore(directory: dir)
        #expect(reopened.movedTo(session) == monday)
    }

    // MARK: What 362 deliberately is not

    /// **THE INVERSION, AND IT IS 363's WHOLE DIFF.**
    ///
    /// This read the other way at 362 — `fieldCount == 17`, one correction
    /// family, no `moves.json` in the gate — and every one of those flipped in
    /// a single patch, together, because they have to: `unclaimed corrections`
    /// fails on a family nobody names, and the gate has to gain a store in the
    /// same diff as the prune that deletes for it.
    ///
    /// Kept in this file rather than moved to the import suite. What it asserts
    /// is a property of the STORE's place in the app, and a reader arriving
    /// here from 362's history should find the sentence that changed rather
    /// than an absence.
    @Test("The store is wired into the import, the gate and the verifier")
    func theStoreIsWiredIn() throws {
        // `AppStores` is what the importer and the verifier are handed.
        #expect(AppStores.fieldCount == 18,
                "the moves are a field of AppStores since 363")

        // The verifier names the families of `correction` that have a
        // comparison. A plan-session row reaching the table without this entry
        // fails `unclaimed corrections` — 361's forcing function, which is why
        // this line and `importMoves` are the same patch.
        #expect(ComparedCorrections.all.count == 2)
        let move = try #require(
            ComparedCorrections.all.first { $0.subjectKind == "planSession" })
        #expect(move.field == "date")
        #expect(move.check == "session moves")

        // And the gate that decides whether rows may be deleted names this
        // store, because `pruneMoves` deletes on its behalf. §12.20.
        #expect(ReconcileFamily.moves.source == "moves.json",
                "something prunes for this store and the gate does not name it")
    }

    /// The declaration half, which IS in this patch. A file in Application
    /// Support that no category names is a file "Delete local data" walks past
    /// — patch 195's rule, and the reason `db` was declared before it existed.
    @Test("The file is declared before anything can write it")
    func theFileIsDeclared() {
        let declared = Set(DataLifecycle.appSupportItems.map(\.pathComponent))
        #expect(declared.contains("moves.json"),
                "moves.json is written by a store and named by no category")

        // And the snapshot vocabulary knows it, so a protected copy taken
        // after this patch includes the athlete's moves rather than skipping
        // them silently. §12.20 — this store cannot be re-fetched from
        // anywhere.
        #expect(LegacyStore.allCases.contains(.moves))
        #expect(LegacyStore.moves.item == .file("moves.json"))
        #expect(LegacyStore.moves.dates == .iso8601,
                "the encoder writes ISO-8601 and the classifier must read it back")
        #expect(LegacyStore.moves.container == .object)
        #expect(AuthoredExport.stores.contains(.moves),
                "an authored store that cannot be re-fetched is not exportable")
    }
}
