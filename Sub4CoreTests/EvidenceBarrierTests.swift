//
//  EvidenceBarrierTests.swift
//  Sub4CoreTests
//
//  Nothing moved while we were looking — patch 442, ADR-0003 §12.198.
//
//  WHAT THESE HAVE TO PROVE, AND WHAT THEY CANNOT
//  ----------------------------------------------
//  The barrier's guarantee is DETECTION: a package is refused when the state it
//  describes changed underneath it. So the tests that matter are the ones where
//  something DOES move — a file rewritten, a row inserted, a preference set —
//  and the capture has to come back refused rather than succeeding quietly.
//
//  RULE 16 covers the half no test can reach: that each writer claiming to wait
//  is actually wired to a guard. The suite can prove a guard which fires stops
//  its caller; only the invariant can prove the guard exists.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("Nothing moved while we were looking")
@MainActor
struct EvidenceBarrierTests {

    private nonisolated static let athlete = #"{"zones":[],"shoes":[]}"#

    private func base(_ files: [String: String] = ["athlete.json": athlete]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barrier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try Data(body.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func clean(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        EvidenceBarrier.releaseForTesting()
    }

    private var items: [AppSupportItem] { [.file("athlete.json")] }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "barrier-\(UUID().uuidString)"))
    }

    // MARK: The vocabulary

    /// **EVERY CASE ANSWERS, AND THE TWO BUCKETS ARE BOTH NON-EMPTY.** A
    /// vocabulary where everything is asked, or nothing is, would make the
    /// distinction the header argues for invisible.
    @Test("Every declared writer is in exactly one bucket")
    func theVocabularyIsComplete() {
        let all = Set(EvidenceBarrier.Writer.allCases)
        let asked = Set(EvidenceBarrier.Writer.asked)
        let detected = Set(EvidenceBarrier.Writer.detectedOnly)
        #expect(asked.union(detected) == all)
        #expect(asked.isDisjoint(with: detected))
        #expect(!asked.isEmpty && !detected.isEmpty)
        for w in all { #expect(!w.label.isEmpty) }
    }

    /// **THE ATHLETE'S SAVE OUTRANKS AN EVIDENCE CAPTURE.** This is the header's
    /// one deliberate departure from the runbook's wording, pinned so that
    /// nobody "completes" it later without reading why.
    @Test("The authored stores are detected, never refused", arguments: [
        EvidenceBarrier.Writer.authoredNotes, .authoredCommutes,
        .authoredMoves, .authoredMatchDecisions
    ])
    func authoredWritersAreNeverRefused(_ w: EvidenceBarrier.Writer) {
        #expect(w.isAskedToWait == false,
                "refusing \(w.label) to protect a capture loses the athlete's data")
    }

    // MARK: The hold

    @Test("A writer is only turned away while the barrier is up, and it is counted")
    func aWriterIsTurnedAwayAndCounted() throws {
        EvidenceBarrier.releaseForTesting()
        #expect(!EvidenceBarrier.isHeld)
        #expect(!EvidenceBarrier.shouldWait(.activitySync))

        let dir = try base(); defer { clean(dir) }
        let db = try Sub4Database.inMemory()
        var sawHeld = false
        var refused = false
        let outcome = EvidenceBarrier.capture(base: dir, items: items,
                                              preferenceKeys: [], database: db,
                                              defaults: try defaults()) { _ in
            sawHeld = EvidenceBarrier.isHeld
            refused = EvidenceBarrier.shouldWait(.activitySync)
            return 42
        }
        #expect(sawHeld, "the barrier was not up inside its own body")
        #expect(refused, "a writer got through while the barrier was up")
        #expect(EvidenceBarrier.refusals[.activitySync] == 1)
        #expect(try outcome.get().value == 42)
        #expect(!EvidenceBarrier.isHeld, "the hold outlived the capture")
    }

    /// **THE ONE THAT MATTERS MOST IF IT BREAKS.** A barrier left up after a
    /// throw stops the sync, the backfill and the background refresh for the
    /// rest of the launch — much worse than a failed capture, and the reason
    /// `scripts/lock.sh` is trap-safe.
    @Test("A body that throws still releases the hold")
    func aThrowReleasesTheHold() throws {
        let dir = try base(); defer { clean(dir) }
        let db = try Sub4Database.inMemory()
        struct Boom: Error {}
        let outcome: Result<EvidenceBarrier.Capture<Int>, EvidenceBarrier.Refusal> =
            EvidenceBarrier.capture(base: dir, items: items, preferenceKeys: [],
                                    database: db, defaults: try defaults()) { _ in
                throw Boom()
            }
        guard case .failure = outcome else {
            Issue.record("a throwing body produced a package")
            return
        }
        #expect(!EvidenceBarrier.isHeld, "the barrier is stuck up")
        #expect(!EvidenceBarrier.shouldWait(.detailBackfill),
                "the app is still refusing its own writers")
    }

    @Test("A second capture is refused rather than interleaved")
    func aSecondCaptureIsRefused() throws {
        let dir = try base(); defer { clean(dir) }
        let db = try Sub4Database.inMemory()
        var inner: Result<EvidenceBarrier.Capture<Int>, EvidenceBarrier.Refusal>?
        _ = EvidenceBarrier.capture(base: dir, items: items, preferenceKeys: [],
                                    database: db, defaults: try defaults()) { _ in
            inner = EvidenceBarrier.capture(base: dir, items: self.items,
                                            preferenceKeys: [], database: db,
                                            defaults: try self.defaults()) { _ in 1 }
            return 0
        }
        guard case .failure(let why) = try #require(inner) else {
            Issue.record("two captures ran at once")
            return
        }
        guard case .alreadyHeld = why else {
            Issue.record("refused for the wrong reason: \(why)")
            return
        }
    }

    // MARK: Detection — the guarantee

    @Test("A file rewritten during the capture refuses the package")
    func aFileThatMovesRefusesThePackage() throws {
        let dir = try base(); defer { clean(dir) }
        let db = try Sub4Database.inMemory()
        let outcome = EvidenceBarrier.capture(base: dir, items: items,
                                              preferenceKeys: [], database: db,
                                              defaults: try defaults()) { _ in
            try Data(#"{"zones":[],"shoes":[],"ftp":270}"#.utf8)
                .write(to: dir.appendingPathComponent("athlete.json"))
            return 0
        }
        guard case .failure(.movedDuringCapture(let what)) = outcome else {
            Issue.record("a file changed underneath the capture and it passed: \(outcome)")
            return
        }
        #expect(what.contains { $0.contains("athlete.json") }, "\(what)")
    }

    /// The database half of the same guarantee — and it is the half a file-hash
    /// check alone would miss entirely.
    @Test("A row written during the capture refuses the package")
    func aRowThatMovesRefusesThePackage() throws {
        let dir = try base(); defer { clean(dir) }
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [])

        let outcome = EvidenceBarrier.capture(base: dir, items: items,
                                              preferenceKeys: [], database: db,
                                              defaults: try defaults()) { _ in
            try db.queue.write { d in
                try d.execute(sql: """
                    INSERT INTO match_decision (id, accountID, planSessionUID, activityID, decidedUTC)
                    VALUES (?, ?, ?, NULL, ?)
                    """, arguments: [UUID().uuidString, Sub4Import.accountID,
                                     "wk-99-barrier", "2026-08-22T08:00:00Z"])
            }
            return 0
        }
        guard case .failure(.movedDuringCapture(let what)) = outcome else {
            Issue.record("a row was inserted underneath the capture and it passed")
            return
        }
        #expect(what.contains { $0.contains("match_decision") }, "\(what)")
    }

    @Test("A preference set during the capture refuses the package")
    func aPreferenceThatMovesRefusesThePackage() throws {
        let dir = try base(); defer { clean(dir) }
        let db = try Sub4Database.inMemory()
        let d = try defaults()
        d.set("dark", forKey: "appearance.selected")

        let outcome = EvidenceBarrier.capture(base: dir, items: items,
                                              preferenceKeys: ["appearance.selected"],
                                              database: db, defaults: d) { _ in
            d.set("light", forKey: "appearance.selected")
            return 0
        }
        guard case .failure(.movedDuringCapture(let what)) = outcome else {
            Issue.record("a preference changed underneath the capture and it passed")
            return
        }
        #expect(what.contains { $0.contains("appearance.selected") }, "\(what)")
    }

    /// **THE POSITIVE CONTROL.** Without it every test above passes for a
    /// barrier that refuses everything — zero compared to zero.
    @Test("A quiet capture succeeds and returns the reading it was taken against")
    func aQuietCaptureSucceeds() throws {
        let dir = try base(); defer { clean(dir) }
        let db = try Sub4Database.inMemory()
        let outcome = EvidenceBarrier.capture(base: dir, items: items,
                                              preferenceKeys: [], database: db,
                                              defaults: try defaults()) { pre in
            // The body is HANDED the pre-state, because a package has to record
            // what it was taken against rather than re-derive it afterwards.
            pre.items.count
        }
        let captured = try outcome.get()
        #expect(captured.value == 1)
        #expect(captured.before.items.first?.path == "athlete.json")
        // BOTH READINGS REACH THE CALLER — the manifest records the pair, and a
        // reader with only one of them takes the equality on trust.
        #expect(captured.after.differences(from: captured.before).isEmpty)
        guard case .hashed(let sha, let bytes) = try #require(captured.before.items.first).kind else {
            Issue.record("a single file was not hashed")
            return
        }
        #expect(bytes == Self.athlete.utf8.count)
        #expect(sha == LegacySnapshot.hex(Data(Self.athlete.utf8)))
    }

    // MARK: What a reading distinguishes

    /// §12.15. Absent and unreadable are different answers, and a fingerprint
    /// that collapsed them would compare equal across a file that vanished and
    /// a file that broke.
    @Test("Absent, hashed and tallied are three different readings")
    func theReadingsAreDistinct() throws {
        let dir = try base(); defer { clean(dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("details"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("details/1.json"))

        let db = try Sub4Database.inMemory()
        let result = EvidenceBarrier.fingerprint(
            base: dir,
            items: [.file("athlete.json"), .directory("details"), .file("gone.json")],
            preferenceKeys: [], database: db, defaults: try defaults(),
            now: Date(timeIntervalSince1970: 1_787_000_000))
        let f = try result.get()
        let by = Dictionary(f.items.map { ($0.path, $0.kind) }, uniquingKeysWith: { a, _ in a })

        guard case .hashed = try #require(by["athlete.json"]) else {
            Issue.record("a file was not hashed"); return
        }
        guard case .tallied(let files, let bytes, let newest) = try #require(by["details"]) else {
            Issue.record("a directory was hashed instead of tallied"); return
        }
        #expect(files == 1)
        #expect(bytes == 2)
        #expect(newest != nil)
        #expect(by["gone.json"] == .absent)
    }

    /// A directory is summarised, not hashed — so the summary has to move when
    /// its contents do, or the shortcut is a hole.
    @Test("A file added to a tallied directory is a difference")
    func aTalliedDirectoryNoticesANewFile() throws {
        let dir = try base(); defer { clean(dir) }
        let details = dir.appendingPathComponent("details")
        try FileManager.default.createDirectory(at: details, withIntermediateDirectories: true)
        let db = try Sub4Database.inMemory()

        let outcome = EvidenceBarrier.capture(base: dir, items: [.directory("details")],
                                              preferenceKeys: [], database: db,
                                              defaults: try defaults()) { _ in
            try Data("{}".utf8).write(to: details.appendingPathComponent("2.json"))
            return 0
        }
        guard case .failure(.movedDuringCapture(let what)) = outcome else {
            Issue.record("a trace arrived mid-capture and the package passed")
            return
        }
        #expect(what.contains { $0.contains("details") }, "\(what)")
    }

    /// Two readings of an unchanging app are taken seconds apart by definition.
    @Test("The time it was taken is not a difference")
    func theTimestampIsNotADifference() throws {
        let dir = try base(); defer { clean(dir) }
        let db = try Sub4Database.inMemory()
        let d = try defaults()
        let a = try EvidenceBarrier.fingerprint(base: dir, items: items, preferenceKeys: [],
                                                database: db, defaults: d,
                                                now: Date(timeIntervalSince1970: 1)).get()
        let b = try EvidenceBarrier.fingerprint(base: dir, items: items, preferenceKeys: [],
                                                database: db, defaults: d,
                                                now: Date(timeIntervalSince1970: 99_999)).get()
        #expect(a.takenUTC != b.takenUTC)
        #expect(a.differences(from: b).isEmpty, "\(a.differences(from: b))")
    }

    // MARK: The line

    @Test("The diagnostics line says the state and both counts")
    func theLineIsUnconditional() {
        EvidenceBarrier.releaseForTesting()
        let line = EvidenceBarrier.line
        #expect(line.contains("not held"))
        #expect(line.contains("\(EvidenceBarrier.Writer.asked.count) writers asked"))
        #expect(line.contains("\(EvidenceBarrier.Writer.detectedOnly.count) detected only"))
        #expect(line.contains("no writer has been turned away"))
    }
}
