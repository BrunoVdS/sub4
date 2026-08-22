//
//  DiagnosticDatabaseCopyTests.swift
//  Sub4CoreTests
//
//  A copy that is evidence, not a spare — patch 443, ADR-0003 §12.199.
//
//  THE ONE THAT MATTERS IS `theCopyHoldsWhatTheDatabaseHolds`.
//  A truncated copy still hashes, still opens, and still answers `ok` to
//  `PRAGMA quick_check`. Counting both sides is the only thing that can tell
//  a faithful copy from a plausible one — everything else here is a refusal
//  that fires before the copy exists.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite("A copy of the database that is evidence")
@MainActor
struct DiagnosticDatabaseCopyTests {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func directory() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbcopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func clean(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// A source with rows in it. **An empty database would make every count
    /// comparison below compare zero with zero** — the negative-control failure
    /// this project has recorded six times.
    private func populated() throws -> Sub4Database {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [ride("a-1"), ride("a-2")], shoes: [])
        return db
    }

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

    // MARK: It works, and the copy is faithful

    /// **THE POSITIVE CONTROL AND THE CENTRAL CLAIM IN ONE.** Every refusal
    /// below is vacuous without a path that succeeds.
    @Test("The copy holds what the database holds, and says so from the copy")
    func theCopyHoldsWhatTheDatabaseHolds() throws {
        let dir = try directory(); defer { clean(dir) }
        let db = try populated()

        let reading = try DiagnosticDatabaseCopy.write(from: db, into: dir, now: now).get()

        #expect(reading.fileName == DiagnosticDatabaseCopy.fileName)
        #expect(reading.bytes > 0)
        #expect(reading.sha256.count == 64)
        #expect(reading.quickCheck == "ok")
        #expect(reading.foreignKeyViolations == 0)
        #expect(reading.migrations == Sub4Migrations.all,
                "the copy is not at the schema the app is at")
        #expect(reading.copiedPageCount == reading.totalPageCount)
        #expect(reading.totalPageCount > 0)
        #expect(reading.tables["activity"] == 2)
        #expect(!reading.isSupportedRestoreArtifact)

        // The file on disk is the file that was hashed.
        let url = dir.appendingPathComponent(DiagnosticDatabaseCopy.fileName)
        let data = try Data(contentsOf: url)
        #expect(LegacySnapshot.hex(data) == reading.sha256)
        #expect(Int64(data.count) == reading.bytes)

        // And it opens as a database holding the same rows — read with a fresh
        // connection rather than trusting the reading that was just returned.
        let reopened = try DatabaseQueue(path: url.path)
        let activities = try reopened.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activity") }
        #expect(activities == 2)
        try reopened.close()
    }

    /// **ONE FILE, NOT THREE.** A `-wal` beside the copy would mean its hash
    /// describes half of it, and a validator reading the file alone would see
    /// an older database that reports `ok` — the exact failure the backup API
    /// is used to avoid.
    @Test("The finished artifact has no journal sidecars")
    func theArtifactIsOneFile() throws {
        let dir = try directory(); defer { clean(dir) }
        _ = try DiagnosticDatabaseCopy.write(from: try populated(), into: dir, now: now).get()

        for suffix in DiagnosticDatabaseCopy.sidecarSuffixes {
            let stray = dir.appendingPathComponent(DiagnosticDatabaseCopy.fileName + suffix)
            #expect(!FileManager.default.fileExists(atPath: stray.path),
                    "\(suffix) survived beside the copy")
        }
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(all == [DiagnosticDatabaseCopy.fileName], "\(all)")
    }

    /// The name is the only defence against a package being mined for a spare,
    /// so it is pinned rather than left to whoever edits the constant.
    @Test("The name says it is not a database to put back")
    func theNameSaysWhatItIs() {
        #expect(DiagnosticDatabaseCopy.fileName.contains("diagnostic"))
        #expect(DiagnosticDatabaseCopy.fileName != Sub4Database.fileName)
    }

    // MARK: What it refuses, each driven

    @Test("It never overwrites a destination that exists")
    func itRefusesAnExistingDestination() throws {
        let dir = try directory(); defer { clean(dir) }
        let existing = dir.appendingPathComponent(DiagnosticDatabaseCopy.fileName)
        try Data("not a database".utf8).write(to: existing)

        let outcome = DiagnosticDatabaseCopy.write(from: try populated(), into: dir, now: now)
        guard case .failure(.destinationExists) = outcome else {
            Issue.record("a package overwrote a file: \(outcome)")
            return
        }
        // AND IT LEFT IT ALONE.
        #expect(try Data(contentsOf: existing) == Data("not a database".utf8))
    }

    /// A stray `-wal` from an interrupted earlier attempt would be folded into
    /// the new copy by SQLite and silently change it.
    @Test("It refuses when a sidecar from an earlier attempt is lying about")
    func itRefusesAStraySidecar() throws {
        let dir = try directory(); defer { clean(dir) }
        try Data().write(to: dir.appendingPathComponent(
            DiagnosticDatabaseCopy.fileName + "-wal"))

        let outcome = DiagnosticDatabaseCopy.write(from: try populated(), into: dir, now: now)
        guard case .failure(.destinationExists(let name)) = outcome else {
            Issue.record("a stray journal did not stop the copy: \(outcome)")
            return
        }
        #expect(name.hasSuffix("-wal"))
    }

    /// **BEFORE, NOT DURING.** A backup that runs out of room halfway leaves a
    /// file that opens and is missing pages.
    @Test("It refuses before starting when there is not enough room")
    func itRefusesWhenThereIsNoRoom() throws {
        let dir = try directory(); defer { clean(dir) }
        let outcome = DiagnosticDatabaseCopy.write(from: try populated(), into: dir,
                                                   now: now, freeBytes: { _ in 1 })
        guard case .failure(.notEnoughSpace(let need, let free)) = outcome else {
            Issue.record("a full disk did not stop the copy: \(outcome)")
            return
        }
        #expect(free == 1)
        #expect(need > 1)
        // NOTHING WAS LEFT BEHIND.
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(all.isEmpty, "a refused copy left \(all)")
    }

    /// The refusal has to be reachable from the real reading too, or the
    /// injection above is testing a closure and nothing else.
    @Test("The free-space reading answers for a real directory")
    func theFreeSpaceReadingWorks() throws {
        let dir = try directory(); defer { clean(dir) }
        let free = DiagnosticDatabaseCopy.freeBytesOnVolume(dir)
        #expect(free != nil, "the volume's important-usage capacity could not be read")
        #expect((free ?? 0) > 0)
    }

    /// **A TABLE CREATED AFTER THE SOURCE WAS OPENED IS STILL CARRIED.**
    ///
    /// This was written to drive the disagreement branch and proves the
    /// opposite, which is the honest result: `sqlite3_backup_*` copies the
    /// whole file, so making the two sides differ would need the backup API to
    /// be wrong. Kept as a POSITIVE control on the comparison — without it,
    /// `theCountComparisonNoticesEveryShape` below would be a pure function
    /// nobody had connected to anything.
    @Test("A table the source gained is in the copy, so the counts agree")
    func theBackupCarriesTablesTheSourceGained() throws {
        let dir = try directory(); defer { clean(dir) }
        let db = try populated()

        // A temporary table exists on the source connection and is not copied
        // by the backup API — so the two sides genuinely disagree, without
        // anything having to lie about the comparison.
        try db.queue.write { d in
            try d.execute(sql: "CREATE TABLE only_on_the_source (id TEXT PRIMARY KEY)")
            try d.execute(sql: "INSERT INTO only_on_the_source VALUES ('x')")
        }
        let outcome = DiagnosticDatabaseCopy.write(from: db, into: dir, now: now)

        // The backup DOES carry a real table across, so this must SUCCEED and
        // the counts must match — which is the honest outcome and proves the
        // comparison is not simply always failing.
        let reading = try outcome.get()
        #expect(reading.tables["only_on_the_source"] == 1,
                "the backup did not carry a table the source had")
    }

    /// **THE RULE, DRIVEN DIRECTLY — §12.162.3, and §12.69 is why.**
    ///
    /// The branch that consumes this cannot be reached through the public API
    /// without a broken SQLite. So the decision is a pure function and the
    /// suite drives it with counts nobody had to corrupt a database to produce.
    /// Three shapes, because "the numbers differ" is only one of them.
    @Test("The count comparison notices every shape of disagreement")
    func theCountComparisonNoticesEveryShape() {
        let agree = DiagnosticDatabaseCopy.disagreements(
            source: ["activity": 699, "weather": 606],
            copy:   ["activity": 699, "weather": 606])
        #expect(agree.isEmpty, "\(agree)")

        let fewer = DiagnosticDatabaseCopy.disagreements(
            source: ["activity": 699], copy: ["activity": 12])
        #expect(fewer.count == 1)
        #expect(fewer[0].contains("activity") && fewer[0].contains("699")
                && fewer[0].contains("12"), "\(fewer)")

        // A TABLE THE COPY LOST ENTIRELY — a truncated copy's likeliest shape,
        // and the one a count-by-count walk over the COPY's tables alone would
        // never see, because it would never look for a table that is not there.
        let missing = DiagnosticDatabaseCopy.disagreements(
            source: ["activity": 699, "weather": 606], copy: ["activity": 699])
        #expect(missing.count == 1)
        #expect(missing[0].contains("weather") && missing[0].contains("no such table"),
                "\(missing)")

        // And one the copy has that the source does not, which would mean the
        // copy is not of this database at all.
        let extra = DiagnosticDatabaseCopy.disagreements(
            source: [:], copy: ["ghost": 1])
        #expect(extra.count == 1)
        #expect(extra[0].contains("ghost"), "\(extra)")
    }

    @Test("The disagreement message reaches the refusal line")
    func theDisagreementNamesTheTable() {
        let failure = DiagnosticDatabaseCopy.Failure.countsDisagree(
            DiagnosticDatabaseCopy.disagreements(source: ["activity": 699],
                                                 copy: ["activity": 12]))
        #expect(failure.line.contains("activity"))
        #expect(failure.line.contains("699"))
        #expect(failure.line.contains("12"))
        #expect(failure.line.hasPrefix("FAILED"))
    }

    @Test("Every refusal says what happened", arguments: [
        DiagnosticDatabaseCopy.Failure.destinationExists("x"),
        .notEnoughSpace(need: 2, free: 1),
        .couldNotOpenSource("why"),
        .couldNotCreateDestination("why"),
        .backupFailed("why"),
        .incomplete(copied: 1, total: 2),
        .countsDisagree(["a"]),
        .sidecarsRemain(["x-wal"]),
        .unreadableAfterWriting("why")
    ])
    func everyFailureSaysSomething(_ f: DiagnosticDatabaseCopy.Failure) {
        #expect(!f.line.isEmpty)
        #expect(f.line.hasPrefix("REFUSED") || f.line.hasPrefix("FAILED"))
    }

    // MARK: Stopping — patch 448, and the device is why

    /// **THE LONGEST STAGE HAD NO CHECKPOINT.**
    ///
    /// `pagesPerStep` was left at its default — one step — so the 39 MB backup
    /// could not be interrupted at all. On 22 August a person pressed Stop
    /// three times during it and three captures ran to completion. The default
    /// is not wrong for consistency; it was wrong for a control that offers to
    /// stop.
    @Test("A backup can be stopped, and leaves nothing behind")
    func aBackupCanBeStopped() throws {
        let dir = try directory(); defer { clean(dir) }
        let db = try populated()

        // A step small enough that this fixture has several of them. The
        // production default is 256 — about a megabyte — and a step larger
        // than the whole database is a checkpoint that never fires, which is
        // what the first draft of this shipped with.
        let outcome = DiagnosticDatabaseCopy.write(from: db, into: dir, now: now,
                                                   shouldCancel: { true },
                                                   pagesPerStep: 8)
        guard case .failure(.cancelled(let done, let total)) = outcome else {
            Issue.record("a backup asked to stop ran to completion: \(outcome)")
            return
        }
        #expect(total > 0, "the page count was not known when it stopped")
        #expect(done <= total)

        // NOTHING LEFT BEHIND — not the copy, not a journal.
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.isEmpty, "a stopped backup left \(left)")
    }

    /// Stopping is not failing. A person who changed their mind has not had a
    /// fault, and a line that says FAILED at them is wrong about what happened.
    @Test("Stopping reads as stopping")
    func stoppingIsNotFailing() {
        let line = DiagnosticDatabaseCopy.Failure.cancelled(afterPages: 12, of: 40).line
        #expect(line.hasPrefix("Stopped"))
        #expect(!line.contains("FAILED"))
        #expect(line.contains("12 of 40"))
        #expect(line.contains("Nothing was left behind"))
    }

    /// **AND IT STILL COMPLETES WHEN NOBODY ASKS IT TO STOP.** Without this the
    /// test above passes for a backup that always aborts.
    /// **THE DEFAULT MUST BE STOPPABLE, AND NOTHING ELSE CHECKS IT.**
    ///
    /// Every cancellation test above passes its own `pagesPerStep`, so putting
    /// the default back to GRDB's `-1` — one step, the state the device found —
    /// leaves all of them green. The first draft of this test compared two
    /// literals (`256 < 9_000`) and could not fail; the sabotage walked
    /// straight past it. §12.69.
    @Test("The default step can be stopped at all")
    func theDefaultCanBeStoppedAtAll() throws {
        #expect(DiagnosticDatabaseCopy.defaultPagesPerStep > 0,
                "a step of -1 is every page in one go — the uninterruptible backup 448 exists to fix")
        #expect(DiagnosticDatabaseCopy.defaultPagesPerStep <= 1024,
                "a step this large is a checkpoint that rarely fires")

        // AND IT IS THE VALUE THE PRODUCTION PATH ACTUALLY USES. Driven, so a
        // default nobody passes cannot drift away from the constant: this
        // fixture is smaller than the default step, so with a sane default it
        // completes, and with `-1` it also completes — which is why the two
        // assertions above are the ones that discriminate, and this half only
        // proves the constant is on the real path.
        let dir = try directory(); defer { clean(dir) }
        let reading = try DiagnosticDatabaseCopy.write(from: try populated(),
                                                       into: dir, now: now).get()
        #expect(reading.totalPageCount < Int(DiagnosticDatabaseCopy.defaultPagesPerStep),
                "this fixture is no longer smaller than one step, so the comment above is wrong")
    }

    @Test("Chunking did not break the copy")
    func chunkingDidNotBreakTheCopy() throws {
        let dir = try directory(); defer { clean(dir) }
        let reading = try DiagnosticDatabaseCopy.write(from: try populated(),
                                                       into: dir, now: now).get()
        #expect(reading.copiedPageCount == reading.totalPageCount)
        #expect(reading.quickCheck == "ok")
        #expect(reading.tables["activity"] == 2)
    }

    // MARK: The line

    @Test("The reading's line carries every figure a reader would check")
    func theLineIsComplete() throws {
        let dir = try directory(); defer { clean(dir) }
        let line = try DiagnosticDatabaseCopy.write(from: try populated(),
                                                    into: dir, now: now).get().line
        #expect(line.contains(DiagnosticDatabaseCopy.fileName))
        #expect(line.contains("integrity ok"))
        #expect(line.contains("pages"))
        #expect(line.contains("source journal"))
        #expect(line.contains("not a restore artifact"))
    }
}
