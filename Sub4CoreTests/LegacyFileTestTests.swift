//
//  LegacyFileTestTests.swift
//  Sub4CoreTests
//
//  Patch 433, ADR-0003 §12.187.
//
//  THE TWO THAT MATTER MOST ARE ABOUT NOT LOSING ANYTHING.
//
//  `aFileWrittenWhileHiddenIsKept` — `StoreLoad.absent` is TRUSTWORTHY, so a
//  store whose file is hidden reads nothing, decides that is legitimate, and
//  writes a fresh one on the next save. Restore then finds a live file where it
//  wants to put the original back, and **overwriting it would destroy a write
//  the athlete made during the test.**
//
//  `hidingTwiceIsRefused` — a second hide over a first would bury the original
//  under exactly that freshly-written file.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct LegacyFileTestTests {

    private func container() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func read(_ name: String, in dir: URL) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name)))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Hiding

    @Test("Hiding moves the named files and nothing else")
    func hidingMovesOnlyTheNamed() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("A", "athlete.json", in: dir)
        try write("W", "weather.json", in: dir)
        try write("C", "constants.json", in: dir)

        let out = LegacyFileTest.hide(in: dir)
        #expect(out == .moved(["athlete.json", "weather.json"], kept: []))
        #expect(read("athlete.json", in: dir) == nil)
        #expect(read("weather.json", in: dir) == nil)
        // NOT B5's, so NOT touched.
        #expect(read("constants.json", in: dir) == "C")
    }

    /// **IT RENAMES. IT NEVER DELETES.** The whole design rests on this.
    @Test("Hidden files still exist, beside where they were")
    func hidingNeverDeletes() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("A", "athlete.json", in: dir)
        _ = LegacyFileTest.hide(in: dir)

        let stored = dir.appendingPathComponent(LegacyFileTest.directoryName)
            .appendingPathComponent("athlete.json")
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect((try? String(contentsOf: stored, encoding: .utf8)) == "A")
    }

    /// The state is a directory, so it survives the force-quit that IS the test.
    @Test("What is hidden is read off the disk")
    func theStateIsOnDisk() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("A", "athlete.json", in: dir)
        #expect(LegacyFileTest.hiddenNow(in: dir).isEmpty)
        _ = LegacyFileTest.hide(in: dir)
        #expect(LegacyFileTest.hiddenNow(in: dir) == ["athlete.json"])
    }

    @Test("Hiding nothing says so rather than claiming success")
    func hidingNothingSaysSo() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .nothingToMove = LegacyFileTest.hide(in: dir) else {
            Issue.record("an empty container reported a move")
            return
        }
    }

    /// A second hide would bury the original under the file the app wrote while
    /// it was hidden.
    @Test("Hiding twice is refused")
    func hidingTwiceIsRefused() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("original", "athlete.json", in: dir)
        _ = LegacyFileTest.hide(in: dir)
        try write("written while hidden", "athlete.json", in: dir)

        guard case .refused(let why) = LegacyFileTest.hide(in: dir) else {
            Issue.record("a second hide buried the original")
            return
        }
        // **THE MESSAGE, NOT JUST THE REFUSAL.** Found by sabotage: deleting
        // the `already.isEmpty` guard still refuses, because `moveItem` cannot
        // write over the stored copy — so a test that only checked "it was
        // refused" passed with the guard gone and could not tell the two
        // apart. Asserting the SENTENCE is what discriminates the deliberate
        // refusal from the accidental one, and the deliberate one is the only
        // one that names what to do next.
        #expect(why.contains("already hidden"),
                "the refusal came from the filesystem rather than from the guard")
        #expect(why.contains("put them back first"))
        #expect(why.contains("athlete.json"))
        // And the original is untouched.
        let stored = dir.appendingPathComponent(LegacyFileTest.directoryName)
            .appendingPathComponent("athlete.json")
        #expect((try? String(contentsOf: stored, encoding: .utf8)) == "original")
    }

    // MARK: Restoring

    @Test("Restoring puts them back where they were")
    func restoringPutsThemBack() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("A", "athlete.json", in: dir)
        try write("W", "weather.json", in: dir)
        _ = LegacyFileTest.hide(in: dir)

        let out = LegacyFileTest.restore(in: dir)
        #expect(out == .moved(["athlete.json", "weather.json"], kept: []))
        #expect(read("athlete.json", in: dir) == "A")
        #expect(read("weather.json", in: dir) == "W")
        #expect(LegacyFileTest.hiddenNow(in: dir).isEmpty)
    }

    /// **THE ONE THAT PROTECTS A WRITE MADE DURING THE TEST.** `StoreLoad`
    /// treats an absent file as trustworthy, so the store rewrites it.
    @Test("A file written while hidden is kept, not overwritten")
    func aFileWrittenWhileHiddenIsKept() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("original", "athlete.json", in: dir)
        _ = LegacyFileTest.hide(in: dir)
        // The store notices nothing is there and saves a fresh one.
        try write("written while hidden", "athlete.json", in: dir)

        let out = LegacyFileTest.restore(in: dir)
        #expect(read("athlete.json", in: dir) == "original",
                "the original did not come back")
        // **PATCH 433a — IT HAS TO SAY SO.** The first device run of 433 kept
        // a rewritten `athlete.json` correctly and reported only "moved
        // athlete.json, weather.json". The preservation is the interesting
        // half; silence about it weakened the very row the test exists for.
        #expect(out == .moved(["athlete.json"],
                              kept: ["athlete.json.written-while-hidden"]))
        #expect(out.line.contains("AND KEPT"))
        #expect(out.line.contains("written by the app while hidden"))
        let kept = dir.appendingPathComponent(LegacyFileTest.directoryName)
            .appendingPathComponent("athlete.json.written-while-hidden")
        #expect((try? String(contentsOf: kept, encoding: .utf8)) == "written while hidden",
                "a write made during the test was destroyed")
    }

    @Test("Restoring nothing says so")
    func restoringNothingSaysSo() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .nothingToMove = LegacyFileTest.restore(in: dir) else {
            Issue.record("restoring an empty container reported a move")
            return
        }
    }

    // MARK: The line

    /// **UNCONDITIONAL, AND IT NAMES THE FILES.** A device left with its data
    /// hidden must say so from the screen and from the paste.
    @Test("The line says what is hidden, and says when nothing is")
    func theLineIsUnconditional() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LegacyFileTest.line(in: dir).contains("every legacy file is in its place"))

        try write("A", "athlete.json", in: dir)
        _ = LegacyFileTest.hide(in: dir)
        let line = LegacyFileTest.line(in: dir)
        #expect(line.contains("HIDDEN"))
        #expect(line.contains("athlete.json"))
        #expect(line.contains("put them back"))
    }

    /// A kept copy is a fact about the container, not about the current
    /// hiding, so it is reported after the test is over too — which is when
    /// somebody reads the paste and wonders what happened.
    @Test("A file kept from an earlier test is reported after the restore")
    func theKeptFileOutlivesTheTest() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("original", "athlete.json", in: dir)
        _ = LegacyFileTest.hide(in: dir)
        try write("written while hidden", "athlete.json", in: dir)
        _ = LegacyFileTest.restore(in: dir)

        #expect(LegacyFileTest.hiddenNow(in: dir).isEmpty)
        #expect(LegacyFileTest.writtenWhileHidden(in: dir)
                == ["athlete.json.written-while-hidden"])
        let line = LegacyFileTest.line(in: dir)
        #expect(line.contains("every legacy file is in its place"))
        #expect(line.contains("kept from an earlier test"),
                "the paste forgot a file the app wrote during a test")
    }

    /// A second test must not fail because the first left a kept copy behind.
    @Test("A second run replaces the kept copy rather than refusing")
    func aSecondRunIsNotBlockedByTheKeptCopy() throws {
        let dir = try container()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("first", "athlete.json", in: dir)
        _ = LegacyFileTest.hide(in: dir)
        try write("written once", "athlete.json", in: dir)
        _ = LegacyFileTest.restore(in: dir)

        _ = LegacyFileTest.hide(in: dir)
        try write("written twice", "athlete.json", in: dir)
        let out = LegacyFileTest.restore(in: dir)
        #expect(out == .moved(["athlete.json"],
                              kept: ["athlete.json.written-while-hidden"]))
        #expect(read("athlete.json", in: dir) == "first")
    }

    @Test("An unreachable container says so rather than reporting nothing hidden")
    func anUnreachableContainerSaysSo() {
        #expect(LegacyFileTest.line(in: nil).contains("unreachable"))
    }

    /// The list is B5's two and stays short on purpose — hiding seven at once
    /// answers D8's question, not a slice's.
    @Test("The list is B5's two files")
    func theListIsShort() {
        #expect(LegacyFileTest.names == ["athlete.json", "weather.json"])
    }
}
