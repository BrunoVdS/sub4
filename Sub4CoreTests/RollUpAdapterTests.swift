//
//  RollUpAdapterTests.swift
//  Sub4CoreTests
//
//  Patch 341. The two things Stage A left untested, and the first one has
//  already shipped a defect.
//
//  WHY THIS FILE EXISTS, AND `ReadBackRollUpTests` SAYS IT ITSELF
//  --------------------------------------------------------------
//  That file's own header reads:
//
//    "333 shipped three states and collapsed two of them in the adapter. These
//     tests did not catch it, because they tested the type and the defect was
//     in the caller: every test below passed while the device reported 'could
//     not look' over a database it had read perfectly."
//
//  It documented the untested seam and left it untested, because the adapter
//  was a `private static func` on `DatabaseHealthView` and no test can reach a
//  SwiftUI view's private members. Patch 341 moves it to `ReadBackRollUp`
//  unchanged and these are the tests that were impossible before the move.
//
//  THE ONE WITH TEETH is `aTrustworthyReadOfAnEmptyDatabaseIsNotBlind`. That
//  is the exact case 333 got wrong and 333a fixed on the device within the
//  hour, and until now nothing but the device could tell.
//
//  THE SECOND HALF — the authored export — is Stage A1 item 5 in the product.
//  Its tests are about the distinction that made 9 August expensive: a store
//  that is absent and a store that could not be read are different facts, and
//  an export that flattened them would report a loss as a healthy empty file.
//

import Testing
import Foundation
@testable import Sub4

@MainActor
@Suite("The roll-up adapter, and the authored export")
struct RollUpAdapterTests {

    // MARK: The adapter — nine reports become nine verdicts

    /// The steady state: a read that happened, over rows that agree.
    @Test("A trustworthy read with no differences agrees")
    func trustworthyAndAgreeing() {
        let l = ReadBackRollUp.line("Activities", 680, 0,
                                    trustworthy: true, "unused")
        #expect(l.verdict == .agreed)
        #expect(l.couldNotLook == nil)
        #expect(l.value == "680 compared, no differences")
    }

    @Test("A trustworthy read with differences differs")
    func trustworthyAndDiffering() {
        let l = ReadBackRollUp.line("Weather and gear", 597, 1,
                                    trustworthy: true, "unused")
        #expect(l.verdict == .differed)
        #expect(l.isFault)
        #expect(l.value == "597 compared, 1 differ")
    }

    /// THE 333 DEFECT, STATED. A read that succeeded and found both sides
    /// empty is an answer that proves nothing — it is NOT a read that failed.
    /// 333 collapsed the two and the device reported "could not look" over a
    /// database it had read perfectly well.
    @Test("A trustworthy read of an empty database is not blind")
    func aTrustworthyReadOfAnEmptyDatabaseIsNotBlind() {
        let l = ReadBackRollUp.line("Notes and commutes", 0, 0,
                                    trustworthy: true,
                                    "0 notes, 0 commute decisions.")
        #expect(l.verdict == .nothingToCompare,
                "an empty comparison is not a failed read")
        #expect(l.couldNotLook == nil, "nothing failed, so nothing explains why")
        #expect(!l.isFault, "unproven is not broken")
        #expect(l.value == "nothing on either side")
    }

    /// THE OTHER HALF OF THE SAME DISTINCTION. An untrustworthy load is a
    /// question nobody answered, and its zeros must not be read as agreement.
    @Test("An untrustworthy read cannot agree, whatever its numbers say")
    func anUntrustworthyReadCannotAgree() {
        let l = ReadBackRollUp.line("Review trail", 60, 0,
                                    trustworthy: false,
                                    "The database could not be read — locked")
        #expect(l.verdict == .couldNotLook)
        #expect(l.isFault)
        #expect(l.compared == 0, "a number from a read that failed is not a number")
        #expect(l.value == "The database could not be read — locked")
    }

    /// The three expensive read-backs return an OPTIONAL report, and a nil one
    /// is not zero differences. `DatabaseHealthView` passes
    /// `report?.totalCompared`, so nil arrives here and must not become agreement.
    @Test("A missing report is a read that did not happen")
    func aMissingReportIsNotAgreement() {
        let l = ReadBackRollUp.line("Recordings", nil, nil,
                                    trustworthy: true,
                                    "the trace read failed")
        #expect(l.verdict == .couldNotLook)
        #expect(l.value == "the trace read failed")
    }

    /// THE NEGATIVE CONTROL FOR THE WHOLE ROLL-UP, which is what Stage A2
    /// item 7 asks for: one line going wrong takes the verdict with it.
    @Test("One bad line fails the roll-up, and the summary names which kind")
    func oneBadLineFailsTheWhole() {
        let good = (1 ... 8).map {
            ReadBackRollUp.line("ok \($0)", 10, 0, trustworthy: true, "unused")
        }
        let bad = ReadBackRollUp.line("Details", 680, 3,
                                      trustworthy: true, "unused")
        let outcome = ReadBackRollUp.Outcome.ran(good + [bad])
        #expect(!outcome.isHealthy)
        #expect(!outcome.provesSomething)
        #expect(outcome.differingCount == 1)
        #expect(outcome.healthyCount == 8)
        #expect(outcome.line.contains("8 of 9 agree"))
        #expect(outcome.line.contains("1 differ"))
    }

    /// `provesSomething` is D7's gate and `isHealthy` is not. An empty
    /// comparison passes the second and must fail the first.
    @Test("An empty comparison is healthy and does not prove anything")
    func anEmptyComparisonSplitsTheTwoVerdicts() {
        let good = (1 ... 8).map {
            ReadBackRollUp.line("ok \($0)", 10, 0, trustworthy: true, "unused")
        }
        let empty = ReadBackRollUp.line("Notes and commutes", 0, 0,
                                        trustworthy: true, "unused")
        let outcome = ReadBackRollUp.Outcome.ran(good + [empty])
        #expect(outcome.isHealthy, "nothing is broken")
        #expect(!outcome.provesSomething, "and nothing is proved either")
        #expect(outcome.emptyCount == 1)
    }

    // MARK: The authored export — Stage A1 item 5

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("authored-export-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private let when = Date(timeIntervalSince1970: 1_786_698_000)

    @Test("The export carries the five stores that cannot be re-fetched")
    func theExportNamesItsStores() {
        let names = AuthoredExport.stores.compactMap { store -> String? in
            guard case .file(let n) = store.item else { return nil }
            return n
        }
        #expect(names == ["notes.json", "commutes.json", "proposals.json",
                          "athlete.json", "constants.json"])
        // THE ONES DELIBERATELY LEFT OUT. A test that only asserted the five
        // present would pass on a version that also shipped 19 MB of traces.
        #expect(!names.contains("activities.json"))
        #expect(!names.contains("weather.json"))
    }

    @Test("A store that is there is copied verbatim and hashed")
    func aPresentStoreIsCopiedAndHashed() throws {
        let dir = try scratch()
        let body = #"{"s-w03-tue":{"rpe":6}}"#
        try body.write(to: dir.appendingPathComponent("notes.json"),
                       atomically: true, encoding: .utf8)

        let doc = AuthoredExport.build(appVersion: "341-test", now: when, base: dir)
        let notes = try #require(doc.entries.first { $0.name == "notes.json" })
        #expect(notes.contents == body, "the bytes go in as they are")
        #expect(notes.bytes == body.utf8.count)
        #expect(notes.error == nil)
        let digest = try #require(notes.sha256)
        #expect(digest.count == 64)
    }

    /// §12.15, and it is the distinction 9 August was about. A device with no
    /// commute decisions has no `commutes.json`, and that is an answer. A file
    /// that exists and cannot be read is a loss. An export that reported both
    /// as "not included" would hide the second inside the first.
    @Test("An absent store and an unreadable one are different facts")
    func absentIsNotTheSameAsUnreadable() throws {
        let dir = try scratch()
        try "{}".write(to: dir.appendingPathComponent("notes.json"),
                       atomically: true, encoding: .utf8)
        // A DIRECTORY WHERE A FILE SHOULD BE. `Data(contentsOf:)` throws on it,
        // which is the closest a test can get to an unreadable file without
        // changing permissions the simulator may ignore.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("commutes.json", isDirectory: true),
            withIntermediateDirectories: true)

        let doc = AuthoredExport.build(appVersion: "341-test", now: when, base: dir)
        let absent = try #require(doc.entries.first { $0.name == "athlete.json" })
        let broken = try #require(doc.entries.first { $0.name == "commutes.json" })

        #expect(absent.contents == nil)
        #expect(absent.error == nil, "absent is not a failure")
        #expect(broken.contents == nil)
        #expect(broken.error != nil, "unreadable says why")
    }

    @Test("Two different files do not hash the same")
    func differentContentsHashDifferently() throws {
        let dir = try scratch()
        try #"{"a":1}"#.write(to: dir.appendingPathComponent("notes.json"),
                              atomically: true, encoding: .utf8)
        try #"{"a":2}"#.write(to: dir.appendingPathComponent("commutes.json"),
                              atomically: true, encoding: .utf8)
        let doc = AuthoredExport.build(appVersion: "341-test", now: when, base: dir)
        let a = doc.entries.first { $0.name == "notes.json" }?.sha256
        let b = doc.entries.first { $0.name == "commutes.json" }?.sha256
        #expect(a != nil && b != nil)
        #expect(a != b, "a hash that cannot tell two files apart is not a hash")
    }

    @Test("The written document decodes back to what was exported")
    func theDocumentRoundTrips() throws {
        let dir = try scratch()
        try #"{"kept":true}"#.write(to: dir.appendingPathComponent("notes.json"),
                                    atomically: true, encoding: .utf8)
        let doc = AuthoredExport.build(appVersion: "341-test", now: when, base: dir)
        let url = try AuthoredExport.write(doc, day: "20260810", into: dir)

        #expect(url.lastPathComponent == "sub4-authored-20260810-p341-test.json")
        let data = try Data(contentsOf: url)
        let back = try JSONDecoder().decode(AuthoredExportDocument.self, from: data)
        #expect(back == doc)
        #expect(back.schemaVersion == AuthoredExport.schemaVersion)
        #expect(back.entries.count == AuthoredExport.stores.count)
    }

    /// The summary is what the screen and the paste print. Counts only — a
    /// note's text never appears in either. §12.7.
    @Test("The summary carries counts and nothing the athlete wrote")
    func theSummaryIsSafeToPaste() throws {
        let dir = try scratch()
        let secret = #"{"s-w01-mon":{"text":"felt awful"}}"#
        try secret.write(to: dir.appendingPathComponent("notes.json"),
                         atomically: true, encoding: .utf8)
        let doc = AuthoredExport.build(appVersion: "341-test", now: when, base: dir)
        #expect(doc.presentCount == 1)
        #expect(doc.absentCount == 4)
        #expect(doc.summary == "1 of 5 stores, \(secret.utf8.count) bytes")
        #expect(!doc.summary.contains("awful"))
    }
}
