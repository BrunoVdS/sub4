//
//  LegacyReaderTests.swift
//  Sub4CoreTests
//
//  The survey — patch 262.
//
//  Everything up to here classified BYTES. This is the first thing that goes
//  and finds them, so what it has to get right is the going: which paths, which
//  directories, and what a missing one means.
//
//  Built on a temporary directory rather than the app container, so these tests
//  say what the reader does with a known disk instead of what happens to be on
//  one.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct LegacyReaderTests {

    // MARK: A disk to read

    private func makeDisk(_ build: (URL) throws -> Void) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ damage: LegacyDamage, _ input: LegacyInput,
                       to root: URL, as name: String) throws {
        let data = try #require(damage.bytes(for: input))
        try data.write(to: root.appendingPathComponent(name))
    }

    private func reading(_ store: LegacyStore, in root: URL) throws -> LegacyReading {
        let all = LegacyReader.readAll(base: root)
        return try #require(all.first { $0.store == store })
    }

    // MARK: Nothing there

    @Test("An empty container reports every store absent, and no faults")
    func aFreshInstallIsClean() throws {
        let root = try makeDisk { _ in }
        let all = LegacyReader.readAll(base: root)

        #expect(all.count == LegacyStore.allCases.count)
        // Contract item 2, at the level the whole survey has to honour it. A
        // phone that has never run the app must produce a clean survey, not
        // eleven red rows.
        let conditions = all.map(\.condition)
        let allAbsent = conditions.allSatisfy { $0 == .absent }
        #expect(allAbsent)
        let anyFault = all.contains { !$0.faults.isEmpty }
        #expect(!anyFault)
    }

    @Test("Every store is surveyed, in a stable order")
    func everyStoreIsCovered() throws {
        let root = try makeDisk { _ in }
        let all = LegacyReader.readAll(base: root)
        #expect(all.map(\.store) == LegacyStore.allCases)
    }

    // MARK: The single files

    @Test("A readable file reads")
    func aGoodFileReads() throws {
        let root = try makeDisk { r in
            try write(.valid, .notes, to: r, as: "notes.json")
        }
        let notes = try reading(.notes, in: root)
        #expect(notes.condition == .readable)
        #expect(notes.files.count == 1)
        #expect(notes.bytes > 0)
    }

    @Test("A truncated file is reported as truncated, with its path")
    func aTruncatedFileIsNamed() throws {
        let root = try makeDisk { r in
            try write(.truncated, .weather, to: r, as: "weather.json")
        }
        let weather = try reading(.weather, in: root)
        #expect(weather.condition == .truncated)
        #expect(weather.faults.first?.path == "weather.json")
        #expect(weather.condition.suggestsRestore)
    }

    @Test("One bad file does not hide the others")
    func aFaultDoesNotStopTheSurvey() throws {
        // The failure `LegacySnapshot.describe` was written to avoid: a survey
        // that stops at the first problem is worth less than no survey,
        // because it looks like one.
        let root = try makeDisk { r in
            try write(.corrupt, .notes, to: r, as: "notes.json")
            try write(.valid, .weather, to: r, as: "weather.json")
            try write(.valid, .commutes, to: r, as: "commutes.json")
        }
        #expect(try reading(.notes, in: root).condition == .corrupt)
        #expect(try reading(.weather, in: root).condition == .readable)
        #expect(try reading(.commutes, in: root).condition == .readable)
    }

    @Test("The pre-split monoliths are read, because they are still on disk")
    func theLegacyFilesAreCovered() throws {
        // `details.json` outlived four versions of this app because nothing
        // listed it. This is the survey refusing to make that mistake twice.
        let root = try makeDisk { r in
            try write(.valid, .legacyDetails, to: r, as: "details.json")
            try write(.valid, .legacyStreams, to: r, as: "streams.json")
        }
        #expect(try reading(.legacyDetails, in: root).condition == .readable)
        #expect(try reading(.legacyStreams, in: root).condition == .readable)
    }

    // MARK: The directories — where `named:` finally has an argument

    @Test("A directory becomes one reading per file")
    func aDirectoryDecomposes() throws {
        let root = try makeDisk { r in
            let dir = r.appendingPathComponent("details", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try #require(LegacyDamage.valid.bytes(for: .detail))
            try data.write(to: dir.appendingPathComponent("11111111.json"))
            try data.write(to: dir.appendingPathComponent("22222222.json"))
        }
        let details = try reading(.detail, in: root)
        #expect(details.files.count == 2)
        #expect(details.files.map(\.path) == ["details/11111111.json",
                                              "details/22222222.json"])
    }

    @Test("The file name is compared against the id inside it")
    func theFileNameIsAnIdentityClaim() throws {
        // 261 built this comparison and had nothing to feed it — every test
        // passed `named: nil`, which skips the check. Here the name is real.
        let root = try makeDisk { r in
            let dir = r.appendingPathComponent("details", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try #require(LegacyDamage.valid.bytes(for: .detail))
            // The fixture's activityId is 11111111. Filed under 22222222.
            try data.write(to: dir.appendingPathComponent("22222222.json"))
        }
        let details = try reading(.detail, in: root)
        let fault = try #require(details.identityFaults.first)
        #expect(fault.filedAs == "22222222")
        #expect(fault.claims == "11111111")
        #expect(fault.field == "activityId")
    }

    @Test("A file whose name agrees is readable")
    func theRightNameIsClean() throws {
        let root = try makeDisk { r in
            let dir = r.appendingPathComponent("streams", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try #require(LegacyDamage.valid.bytes(for: .streams))
            try data.write(to: dir.appendingPathComponent("11111111.json"))
        }
        let streams = try reading(.streams, in: root)
        #expect(streams.files.first?.condition == .readable)
        #expect(streams.faults.isEmpty)
    }

    @Test("Good files in a directory are counted apart from the bad")
    func theCountsSplit() throws {
        let root = try makeDisk { r in
            let dir = r.appendingPathComponent("details", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let good = try #require(LegacyDamage.valid.bytes(for: .detail))
            let bad = try #require(LegacyDamage.truncated.bytes(for: .detail))
            try good.write(to: dir.appendingPathComponent("11111111.json"))
            try bad.write(to: dir.appendingPathComponent("33333333.json"))
        }
        let details = try reading(.detail, in: root)
        #expect(details.files.count == 2)
        #expect(details.readableCount == 1)
        #expect(details.faults.count == 1)
        // "details: mismatch" tells nobody which activity to open.
        #expect(details.faults.first?.path == "details/33333333.json")
    }

    @Test("Hidden files are not surveyed")
    func dotFilesAreSkipped() throws {
        let root = try makeDisk { r in
            let dir = r.appendingPathComponent("details", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try #require(LegacyDamage.valid.bytes(for: .detail))
            try data.write(to: dir.appendingPathComponent("11111111.json"))
            try Data("not ours".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        }
        let details = try reading(.detail, in: root)
        #expect(details.files.count == 1)
    }

    @Test("A directory that is not there is one row, not none")
    func aMissingDirectoryIsARow() throws {
        let root = try makeDisk { _ in }
        let details = try reading(.detail, in: root)
        // "no details on this phone" has to be distinguishable from "the
        // survey did not cover details", and zero rows says the second.
        #expect(details.files.count == 1)
        #expect(details.condition == .absent)
        #expect(!details.condition.isFault)
    }

    @Test("A directory that exists and is empty is absent, not broken")
    func anEmptyDirectoryIsAbsent() throws {
        let root = try makeDisk { r in
            try FileManager.default.createDirectory(
                at: r.appendingPathComponent("streams", isDirectory: true),
                withIntermediateDirectories: true)
        }
        let streams = try reading(.streams, in: root)
        #expect(streams.condition == .absent)
        #expect(!streams.condition.isFault)
    }

    // MARK: What the diagnostic may carry

    @Test("The diagnostic names no identifier of the athlete's")
    func theDiagnosticIsRedacted() throws {
        let root = try makeDisk { r in
            let dir = r.appendingPathComponent("details", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try #require(LegacyDamage.valid.bytes(for: .detail))
            try data.write(to: dir.appendingPathComponent("22222222.json"))
            try write(.keyMismatch, .notes, to: r, as: "notes.json")
        }
        let all = LegacyReader.readAll(base: root)
        let text = LegacyReader.diagnosticLines(all).joined(separator: "\n")

        // The paste promises no session names and nothing from the athlete's
        // history — §12.7. An identity fault is made of exactly those, so the
        // screen gets the names and this gets the count.
        #expect(!text.contains("w99-sun"))
        #expect(!text.contains("w03-tue"))
        #expect(!text.contains("22222222"))
        #expect(!text.contains("11111111"))
        // And it still says something useful.
        #expect(text.contains("identity-mismatch"))
        #expect(text.contains("notes"))
    }

    @Test("The diagnostic counts faults by kind")
    func theDiagnosticGroups() throws {
        let root = try makeDisk { r in
            let dir = r.appendingPathComponent("details", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let good = try #require(LegacyDamage.valid.bytes(for: .detail))
            let bad = try #require(LegacyDamage.truncated.bytes(for: .detail))
            try good.write(to: dir.appendingPathComponent("11111111.json"))
            try bad.write(to: dir.appendingPathComponent("33333333.json"))
            try bad.write(to: dir.appendingPathComponent("44444444.json"))
        }
        let all = LegacyReader.readAll(base: root)
        let text = LegacyReader.diagnosticLines(all).joined(separator: "\n")
        #expect(text.contains("truncated: 2"))
        #expect(text.contains("3 files, 1 readable, 2 at fault"))
    }

    @Test("Every condition has a stable diagnostic name")
    func everyConditionIsNameable() {
        // `summary` is prose for the athlete and may be reworded.
        // `diagnosticName` is compared and grouped, so it must not be — and a
        // condition that reused another's name would merge two faults into one
        // line silently.
        let all: [LegacyCondition] = [
            .absent, .empty, .whitespace, .notJSON, .truncated, .corrupt,
            .wrongContainer(expected: .object, found: .array),
            .undecodable("x"),
            .identityMismatch([.init(filedAs: "a", claims: "b", field: "id")]),
            .duplicateIdentity(["a"]), .readable,
        ]
        let names = Set(all.map(\.diagnosticName))
        #expect(names.count == all.count)
        let noneEmpty = all.allSatisfy { !$0.diagnosticName.isEmpty }
        #expect(noneEmpty)
    }
}
