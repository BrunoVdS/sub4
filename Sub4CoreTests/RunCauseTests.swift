//
//  RunCauseTests.swift
//  Sub4CoreTests
//
//  Why a run happened, kept — patch 406, ADR-0003 §12.150.
//
//  WHAT THIS IS FOR
//  ----------------
//  On 18 August at 04:02 the ledger reported an authored run from four minutes
//  earlier and could not say what caused it. The question was not academic:
//  patch 405 had just stopped restores announcing, and that row could equally
//  have been a restore press proving the fix had failed, or `AthleteStore.save`
//  catching up an athlete cache after a launch sync. Two exports either side of
//  a press settled it by elimination — three presses would have shown three
//  more rows — but elimination is inference, and the table that records what
//  touched the database should not need any.
//
//  The sentence existed the whole time. `noteAuthoredChange("a session note was
//  saved")` writes it, `run(reason:)` carried it, and `record(outcome:reason:)`
//  used it on FAILURE only — so every run that worked became anonymous.
//

import Testing
import Foundation
@testable import Sub4

@Suite("Why a run happened")
@MainActor
struct RunCauseTests {

    private let t0 = "2026-08-19T06:00:00Z"

    private func db() throws -> Sub4Database { try Sub4Database.inMemory() }

    // MARK: The column

    /// The whole point: a run opened with a cause reports it, and one opened
    /// without says nothing rather than guessing.
    @Test("A run records why it happened, or records that nobody said")
    func aRunRecordsWhy() throws {
        let d = try db()
        _ = try MigrationLedger.open(d, appVersion: "406", snapshotID: nil,
                                     trigger: .authored,
                                     cause: "a session note was saved", now: t0)
        let with = try #require(try MigrationLedger.all(d).first)
        #expect(with.cause == "a session note was saved")
        #expect(with.line.contains("because a session note was saved"),
                "a column nobody can read is the defect this patch exists to fix")

        let e = try db()
        _ = try MigrationLedger.open(e, appVersion: "406", snapshotID: nil,
                                     trigger: .manual, now: t0)
        let without = try #require(try MigrationLedger.all(e).first)
        #expect(without.cause == nil, "nil is `not recorded`, not `it was nothing`")
        #expect(!without.line.contains("because"),
                "hundreds of rows predate this column; naming every one would be noise")
    }

    /// **THE AMBIGUITY THAT MADE THIS PATCH.** Two runs, same trigger, same
    /// second, different causes. Before 406 these two rows were identical and a
    /// reader had to infer which was which from how many appeared.
    @Test("Two authored runs in one second are told apart by their cause")
    func twoAuthoredRunsAreToldApart() throws {
        let d = try db()
        _ = try MigrationLedger.open(d, appVersion: "406", snapshotID: nil,
                                     trigger: .authored,
                                     cause: "a session note was saved", now: t0)
        _ = try MigrationLedger.open(d, appVersion: "406", snapshotID: nil,
                                     trigger: .authored,
                                     cause: "the athlete cache was saved", now: t0)

        let causes = try MigrationLedger.all(d).compactMap(\.cause)
        #expect(Set(causes) == ["a session note was saved",
                                "the athlete cache was saved"],
                "this is exactly the pair 04:02 could not distinguish")
    }

    // MARK: §12.7 — what it may not carry

    /// **A KIND OF CHANGE, NEVER A RECORD.** The cause reaches the paste, and
    /// §12.7 promises that carries no session names, places or dates from the
    /// athlete's history. That holds only while every cause is a LITERAL
    /// written at its call site rather than a string built from data.
    ///
    /// A SOURCE ASSERTION, because the property is about how the strings are
    /// WRITTEN and no runtime value can show it. Interpolation is what would
    /// break it: `"a note on \(session.uid) was saved"` compiles, reads
    /// naturally, and puts a session uid in the paste.
    @Test("Every cause is a constant sentence")
    func causeIsAConstantSentence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sub4")
        let sources = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        var found = 0
        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where
                line.contains("noteAuthoredChange(") || line.contains("cause: \"") {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard !s.hasPrefix("//"), !s.hasPrefix("///") else { continue }
                found += 1
                #expect(!s.contains("\\("),
                        "an interpolated cause puts the athlete's data in the paste — \(s)")
            }
        }
        #expect(found >= 7,
                "six announcers and the manual import; a smaller number means this test stopped finding them")
    }
}
