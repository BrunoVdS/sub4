//
//  ActivityStoreReadTests.swift
//  Sub4CoreTests
//
//  The seventh store — patch 378, ADR-0003 §12.122.
//
//  WHY THIS SUITE CAN EXIST AT ALL
//  -------------------------------
//  `init(directory:)`. `ActivityStore.shared` reads Application Support on a
//  device, so nothing could put a corrupt `activities.json` in front of it and
//  the guard below could not be shown to fail. §12.69: a check that cannot
//  fail has not been tested, and that applies to guards before anything else.
//
//  THE TWO THAT ARE THE POINT
//  --------------------------
//  `aCorruptFileIsNotAnEmptyStore` is the defect. `resetStillWritesOverAn
//  UnreadableFile` is the one a careless fix would have broken: the athlete's
//  recovery path runs through `save()`, and a guard with no way past it would
//  leave him holding a corrupt file for ever.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The activity cache tells a bad read from an empty one")
@MainActor
struct ActivityStoreReadTests {

    /// A directory of its own per test. `FileManager.default.temporaryDirectory`
    /// shared between tests is how one test's leftover file decides another
    /// test's verdict.
    private func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("sub4-378-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d,
                                                withIntermediateDirectories: true)
        return d
    }

    private func write(_ text: String, to dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent("activities.json"))
    }

    private func onDisk(_ dir: URL) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent("activities.json"))
    }

    // MARK: The three answers

    @Test("No file is absent, and a fresh install may still write")
    func noFileIsAbsent() throws {
        let dir = try scratch()
        let store = ActivityStore(directory: dir)

        #expect(store.lastLoad == .absent)
        #expect(store.lastLoad.isTrustworthy,
                "a fresh install has nothing and that is a fact, not a failure")
        #expect(store.activities.isEmpty)
        #expect(store.save(), "a device with no file must be able to make one")
    }

    /// **THE ONE THAT IS THE POINT.**
    @Test("A corrupt file is not an empty store")
    func aCorruptFileIsNotAnEmptyStore() throws {
        let dir = try scratch()
        try write("{ this is not activities }", to: dir)
        let before = onDisk(dir)

        let store = ActivityStore(directory: dir)

        #expect(!store.lastLoad.isTrustworthy,
                "the file was there and did not decode")
        #expect(store.activities.isEmpty,
                "memory is left as it was — the point is what happens next")

        #expect(!store.save(),
                "this is the write that put one sync window over 661 activities")
        #expect(onDisk(dir) == before,
                "and the refusal has to reach the disk, not just the return value")
    }

    /// An empty FILE is not an empty STORE either — `StoreRead` calls a
    /// zero-byte file unreadable, because that is what an interrupted write
    /// leaves behind.
    @Test("A zero-byte file is unreadable, not empty")
    func aZeroByteFileIsUnreadable() throws {
        let dir = try scratch()
        try write("", to: dir)
        let store = ActivityStore(directory: dir)

        #expect(!store.lastLoad.isTrustworthy)
        #expect(!store.save())
    }

    @Test("A file holding an empty list is a clean read of nothing")
    func anEmptyListIsClean() throws {
        let dir = try scratch()
        try write("[]", to: dir)
        let store = ActivityStore(directory: dir)

        #expect(store.lastLoad == .loaded,
                "the app could read it; it said there is nothing")
        #expect(store.activities.isEmpty)
        #expect(store.save(), "and a clean read of nothing may be written back")
    }

    // MARK: THE ONE A CARELESS FIX WOULD HAVE BROKEN

    /// **THE RECOVERY PATH — §12.122.**
    ///
    /// `resetCache()` is how an athlete whose file is corrupt gets a good one.
    /// It runs through `save()`. A guard with no way past it would refuse the
    /// write that fixes the file and leave him holding the corrupt one for
    /// ever — this patch causing the harm it exists to prevent.
    ///
    /// Driven through `save(rebuildingFromScratch:)` rather than `resetCache()`
    /// itself, because that method also clears `UserDefaults` keys the
    /// singleton owns and a test must not reach into those.
    @Test("A rebuild still writes over an unreadable file")
    func resetStillWritesOverAnUnreadableFile() throws {
        let dir = try scratch()
        try write("{ not activities }", to: dir)
        let store = ActivityStore(directory: dir)

        #expect(!store.lastLoad.isTrustworthy)
        #expect(!store.save(), "the ordinary write refuses")
        #expect(store.save(rebuildingFromScratch: true),
                "and the recovery does not — otherwise it is unrecoverable")

        let after = onDisk(dir)
        #expect(after != nil)
        let text = String(data: after ?? Data(), encoding: .utf8) ?? ""
        #expect(text.contains("["), "what landed is a list, not the old rubbish")
    }

    // MARK: What the athlete and the paste are told

    @Test("The summary tells a missing file from an unreadable one")
    func theSummaryTellsThemApart() throws {
        let missing = try scratch()
        let corrupt = try scratch()
        try write("{ no }", to: corrupt)

        let a = ActivityStore(directory: missing).loadSummary
        let b = ActivityStore(directory: corrupt).loadSummary

        #expect(a != b, "§12.15 — these are opposite facts, not one sentence")
        #expect(a.contains("no cached file"))
        #expect(b.contains("could not be read"))
    }

    /// The paste says THAT and not WHY — `StoreRead`'s doc reserves the reason
    /// for the athlete's own screen, because a file-system error can carry a
    /// path and this text gets copied into a chat window.
    @Test("The paste names the bad read without naming the reason")
    func thePasteWithholdsTheReason() throws {
        let dir = try scratch()
        try write("{ no }", to: dir)
        let lines = ActivityStore(directory: dir).loadDiagnosticLines

        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("could not be read"))
        #expect(!joined.contains("did not decode"),
                "the reason belongs on the athlete's screen, not in the paste")
        #expect(lines.contains(where: { $0.hasPrefix("Activities arriving late:") }),
                "376's line is unconditional and 378 must not have dropped it")
    }
}
