//
//  StoreWriteTests.swift
//  Sub4CoreTests
//
//  A save that can fail — D4 step 1, patch 264.
//
//  EVERY TEST HERE THAT MATTERS MAKES A WRITE FAIL FIRST. A failable save
//  nobody has watched fail is not a failable save; it is the same `try?` with
//  more words around it, and this project has found that shape six times.
//
//  The way a write is made to fail is the honest one: the store is pointed at a
//  directory that does not exist. `Data.write(to:options:.atomic)` throws, the
//  same as it would on a full disk or a locked device, and nothing is mocked.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct StoreWriteTests {

    // MARK: Somewhere to write, and somewhere that will not take a write

    private func writableDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notes-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A path with no directory behind it. Not a mock — this is what a write
    /// failure actually looks like from `Foundation`.
    private func unwritableDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notes-missing-\(UUID().uuidString)", isDirectory: true)
    }

    private func session(_ uid: String = "w03-tue") -> Session {
        Session(uid: uid, weekUid: "w03", day: "Tue", date: "2026-08-04",
                discipline: .run, intensity: .easy, title: "Easy 8 km",
                detail: nil, fuel: nil, prep: nil, seq: 1,
                swimDetail: nil, strengthDetail: nil)
    }

    // MARK: The write itself

    @Test("A write that lands says nothing and leaves a file")
    func aGoodWriteIsSilent() throws {
        let dir = try writableDirectory()
        let url = dir.appendingPathComponent("thing.json")
        try StoreWrite.encode(["a": 1], to: url, store: "thing.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A write that cannot land throws, and says which store")
    func aFailedWriteNamesTheStore() {
        let url = unwritableDirectory().appendingPathComponent("thing.json")
        #expect(throws: StoreWriteError.self) {
            try StoreWrite.encode(["a": 1], to: url, store: "thing.json")
        }
    }

    @Test("A write failure is a writing failure, and is worth retrying")
    func theStageIsCarried() {
        let url = unwritableDirectory().appendingPathComponent("thing.json")
        do {
            try StoreWrite.encode(["a": 1], to: url, store: "thing.json")
            Issue.record("the write succeeded, so this test proves nothing")
        } catch let error as StoreWriteError {
            #expect(error.stage == .writing)
            #expect(error.store == "thing.json")
            // The distinction the alert is built on: a full disk is worth
            // another attempt, a broken encoder is not.
            #expect(error.stage.isWorthRetrying)
            #expect(!error.reason.isEmpty, "the system said nothing, which cannot be right")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("An encoding failure is NOT offered a retry")
    func encodingIsNotRetryable() {
        // Retrying runs the same encoder over the same value. A button that
        // offers it is a button that lies.
        #expect(!StoreWriteError.Stage.encoding.isWorthRetrying)
        #expect(StoreWriteError.Stage.writing.isWorthRetrying)
    }

    @Test("Both stages explain themselves, differently")
    func bothStagesSpeak() {
        let encoding = StoreWriteError(store: "notes.json", stage: .encoding, reason: "x")
        let writing = StoreWriteError(store: "notes.json", stage: .writing, reason: "x")
        #expect(encoding.errorDescription != writing.errorDescription,
                "one message for two conditions tells the athlete nothing")
        #expect(encoding.errorDescription?.contains("notes.json") == true)
        #expect(writing.errorDescription?.contains("notes.json") == true)
    }

    // MARK: What the note store does about it

    @Test("A note that saves is on disk and in memory")
    func aGoodSaveLands() throws {
        let dir = try writableDirectory()
        let store = NotesStore(directory: dir)
        let note = try store.save(session: session(), rpe: 5, feel: .expected,
                                  text: "Legs fine.")
        #expect(note != nil)
        #expect(store.count == 1)

        // Read back through a SECOND store over the same directory, because
        // "it is in memory" is exactly the claim that used to be false. Only
        // a fresh read proves the bytes landed.
        let reopened = NotesStore(directory: dir)
        #expect(reopened.count == 1)
        #expect(reopened.note(uid: "w03-tue")?.text == "Legs fine.")
    }

    @Test("A note that cannot be written throws rather than pretending")
    func aFailedSaveThrows() {
        let store = NotesStore(directory: unwritableDirectory())
        #expect(throws: StoreWriteError.self) {
            try store.save(session: session(), rpe: 5, feel: .expected,
                           text: "Legs fine.")
        }
    }

    @Test("A failed save leaves nothing behind in memory")
    func aFailedSaveRollsBack() {
        // THE ONE THIS PATCH IS ABOUT. Before 264 the note stayed in `notes`
        // after a failed write, so the editor closed, the list showed it, and
        // the next launch read the old file back and it was gone.
        let store = NotesStore(directory: unwritableDirectory())
        _ = try? store.save(session: session(), rpe: 5, feel: .expected, text: "Legs fine.")
        #expect(store.count == 0, "a note that was never written is in memory")
        #expect(store.note(uid: "w03-tue") == nil)
    }

    @Test("A failed edit leaves the PREVIOUS note intact")
    func aFailedEditKeepsTheOldNote() throws {
        // Rolling back to nothing would be its own defect: an edit that fails
        // must not delete what was already there.
        let dir = try writableDirectory()
        let store = NotesStore(directory: dir)
        _ = try store.save(session: session(), rpe: 4, feel: .easier, text: "First.")

        // Make the directory unreachable by moving it aside, so the same store
        // instance now has somewhere it cannot write.
        try FileManager.default.moveItem(at: dir, to: dir.appendingPathExtension("gone"))

        _ = try? store.save(session: session(), rpe: 9, feel: .harder, text: "Second.")
        let kept = store.note(uid: "w03-tue")
        #expect(kept?.text == "First.", "a failed edit overwrote the note in memory")
        #expect(kept?.rpe == 4)
    }

    @Test("A delete that cannot be written puts the note back")
    func aFailedDeleteRollsBack() throws {
        let dir = try writableDirectory()
        let store = NotesStore(directory: dir)
        _ = try store.save(session: session(), rpe: 4, feel: .easier, text: "First.")
        try FileManager.default.moveItem(at: dir, to: dir.appendingPathExtension("gone"))

        try? store.remove(session: session())
        // A delete that silently did not happen would put the note back at the
        // next launch, which reads as the app undoing a decision. Better to
        // put it back now and say so.
        #expect(store.count == 1)
        #expect(store.note(uid: "w03-tue")?.text == "First.")
    }

    @Test("Clearing every field still deletes, and still reports a failure")
    func clearingIsADeleteAndCanFail() throws {
        let dir = try writableDirectory()
        let store = NotesStore(directory: dir)
        _ = try store.save(session: session(), rpe: 4, feel: .easier, text: "First.")

        // Clearing everything is how a note is deleted — that route has to
        // fail the same way as the delete button.
        try FileManager.default.moveItem(at: dir, to: dir.appendingPathExtension("gone"))
        #expect(throws: StoreWriteError.self) {
            try store.save(session: session(), rpe: nil, feel: nil, text: "   ")
        }
        #expect(store.count == 1, "the note was removed from memory anyway")
    }

    @Test("Removing a note that is not there is not a failure")
    func removingNothingIsFine() throws {
        // Nothing to write, so nothing to fail. A store that threw here would
        // make the delete button unusable on a session with no note.
        let store = NotesStore(directory: unwritableDirectory())
        try store.remove(session: session("w99-sun"))
        #expect(store.count == 0)
    }
}

/// DELIBERATELY NOT `@MainActor` — patch 264a, and this is the third time this
/// project has needed a suite shaped exactly like this one.
///
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` isolated `JSONEncoder.sub4`
/// because it is declared in `NotesStore.swift`, and `StoreWrite` takes it as a
/// default argument — which is evaluated at the CALL SITE. One declaration,
/// three warnings, 559 tests passing over the top of them.
///
/// Nothing below asserts a value. It asserts that this file still COMPILES from
/// a nonisolated context, which is the only thing a warning-shaped defect can
/// be held to. `ExcludedRecordingNonisolationTests` is its older sibling.
@Suite
struct StoreWriteNonisolationTests {

    @Test("The shared coders are reachable without the main actor")
    func theCodersAreNonisolated() throws {
        let data = try JSONEncoder.sub4.encode(["a": 1])
        let back = try JSONDecoder.sub4.decode([String: Int].self, from: data)
        #expect(back["a"] == 1)
    }

    @Test("A store write runs without the main actor")
    func theWriteIsNonisolated() throws {
        // The call `StoreWrite.encode` is actually made in — from inside a
        // nonisolated store, with the encoder defaulted. If `sub4` goes back
        // to being isolated, this stops building.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonisolated-\(UUID().uuidString).json")
        try StoreWrite.encode(["a": 1], to: url, store: "nonisolated.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }
}
