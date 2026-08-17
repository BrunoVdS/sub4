//
//  DetailHydrationTests.swift
//  Sub4CoreTests
//
//  The two largest families are not read at launch, and the store that owns
//  them says what building it cost — patch 395, D7 slice B4, ADR-0003 §12.139.
//
//  WHY THIS FILE CHANGED SHAPE ONE PATCH AFTER IT WAS WRITTEN
//  ----------------------------------------------------------
//  394 put `activity_detail` and `recording` into the launch bootstrap and
//  measured it on the device: **3.963 s in front of first paint, of which
//  3.730 s was 668 recordings over 199,848 sample rows.** That was the one
//  question B4's plan said had to be answered before the flip, and the answer
//  killed the design rather than confirming it.
//
//  So 395 takes them back out — `fieldCount` returns to 7 and the launch to
//  0.038 s — and moves the read to the place it belongs: `DetailStore`'s own
//  construction. It is the ONLY store in this ladder that is not built while
//  `ContentView`'s stored properties initialise; its first caller is
//  `LoadStore.recomputeIfNeeded` inside a `.task`, after the first frame.
//  Hydrating it from the launch would have CONSTRUCTED it — 1,362 files and
//  19.1 MB decoded, then thrown away and replaced by rows read a second time.
//
//  WHAT IS PROVED HERE AND WHAT ONLY THE PHONE CAN SAY
//  ---------------------------------------------------
//  The structure is testable and is tested below. The number is not: a
//  simulator's decode of two fixture files says nothing about 19.1 MB on the
//  device. `constructionTiming` exists so 396 can be argued against a measured
//  file baseline instead of against 3.730 s alone.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The detail families are not read at launch")
@MainActor
struct DetailHydrationTests {

    // MARK: Fixtures

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-395-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func detail(_ id: String, splits: Int) -> ActivityDetail {
        ActivityDetail(activityId: id,
                       splits: (1...splits).map {
                           .init(index: $0, distanceM: 1000, movingTime: 300,
                                 elapsedTime: 305, elevationDiff: nil,
                                 averageHR: 140)
                       },
                       bestEfforts: [], laps: [],
                       fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func streams(_ id: String, samples: Int) -> ActivityStreams {
        ActivityStreams(activityId: id,
                        distanceM: (0..<samples).map { Double($0) * 100 },
                        heartRate: Array(repeating: 140, count: samples),
                        speed: nil, altitude: nil, grade: nil, power: nil,
                        latitude: nil, longitude: nil,
                        fetched: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func seed(_ dir: URL,
                      details: [ActivityDetail] = [],
                      streams: [ActivityStreams] = []) throws {
        let d = dir.appendingPathComponent("details", isDirectory: true)
        let s = dir.appendingPathComponent("streams", isDirectory: true)
        try FileManager.default.createDirectory(at: d,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s,
                                                withIntermediateDirectories: true)
        for v in details {
            try JSONEncoder().encode(v)
                .write(to: d.appendingPathComponent(v.activityId + ".json"))
        }
        for v in streams {
            try JSONEncoder().encode(v)
                .write(to: s.appendingPathComponent(v.activityId + ".json"))
        }
    }

    // MARK: The launch does not read them

    /// **THE ASSERTION THAT IS THE PATCH.** Seven families in the bootstrap,
    /// and the two that cost 3.9 s are not among them.
    ///
    /// Written as the count AND the two names, because either alone is weak:
    /// the count alone passes if somebody swaps a family for another, and the
    /// names alone pass if a tenth arrives beside them.
    @Test("The launch reads seven families and neither of the expensive two")
    func theLaunchReadsSeven() {
        #expect(DatabaseBootstrap.fieldCount == 7,
                "394's two came back out — §12.139")
        #expect(DatabaseBootstrap.diagnosticLineCount == 13)

        let boot = DatabaseBootstrap(plan: HydrationFixtures.loadedPlan(),
                                     extras: HydrationFixtures.loadedExtras(),
                                     athlete: HydrationFixtures.loadedAthlete(),
                                     authored: .noneWritten,
                                     decisions: .noneRecorded,
                                     moves: .loaded(moves: [], skipped: 0),
                                     activities: .loaded(activities: [], skipped: 0))
        let lines = boot.diagnosticLines
        #expect(lines.count == DatabaseBootstrap.diagnosticLineCount)
        #expect(!lines.contains { $0.hasPrefix("  details:") },
                "a line here means the launch read them again")
        #expect(!lines.contains { $0.hasPrefix("  traces:") })
    }

    /// **398 — THE FLIP, AND IT IS TWO CASES ON ONE LINE.** What changed at 395
    /// is who consults the switch; what changed here is the switch. The store
    /// reads it, not `Sub4Launch` — §12.139 measured why.
    @Test("Both families are fed, and the store is what asks")
    func bothFamiliesAreFed() {
        let read = Set(PersistenceAuthority.Family.allCases)
        let fed = PersistenceAuthority.hydratedFamilies
        #expect(read.subtracting(fed).isEmpty, "nine declared, nine fed")
        #expect(PersistenceAuthority.hydrates(.details))
        #expect(PersistenceAuthority.hydrates(.traces))
        // AND THE LAUNCH STILL DOES NOT NAME THE STORE — the assertion below
        // this one in the file. The flip did not move the read back into the
        // launch path, which is the thing 395 was for.
    }

    /// **THE STORE IS NOT TOUCHED BY THE LAUNCH, AND THAT IS LOAD-BEARING.**
    /// Touching `DetailStore.shared` constructs it, and constructing it decodes
    /// 19.1 MB. §12.139's whole argument is that the launch must not do that,
    /// so the launch must not name it either.
    ///
    /// A SOURCE ASSERTION BECAUSE THE ALTERNATIVE IS UNTESTABLE: a test cannot
    /// watch a singleton not being constructed — it would have to construct it
    /// to ask.
    @Test("Nothing in the launch sequence names the store")
    func theLaunchDoesNotNameTheStore() throws {
        let launch = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Sub4CoreTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sub4/Sub4Launch.swift")
        let source = try String(contentsOf: launch, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("DetailStore."),
                "the launch names DetailStore; naming it constructs it, and that is 19.1 MB in front of the first frame — §12.139")
    }

    // MARK: What the store says about itself

    /// §12.54.2 and §12.15. The number is worthless without its source: 3.7 s
    /// from rows argues for a different fix from 3.7 s from files, and a
    /// duration on its own cannot tell a reader which patch it belongs to.
    @Test("The construction line says its cost, its source and its counts")
    func theConstructionLineSaysItsSource() throws {
        let dir = try directory()
        try seed(dir, details: [detail("1", splits: 3), detail("2", splits: 4)],
                 streams: [streams("1", samples: 12)])

        let store = DetailStore(directory: dir)
        #expect(store.detailsServedFrom == .files,
                "395 changes where the read happens, not which side it reads")
        #expect(store.tracesServedFrom == .files)

        let t = DetailStoreTiming(source: .files, seconds: 1.234,
                                  details: 694, traces: 668)
        #expect(t.line.contains("1.234 s"))
        #expect(t.line.contains("the app's own files"))
        #expect(t.line.contains("694 details"))
        #expect(t.line.contains("668 traces"))

        // UNCONDITIONAL. A store built too fast to measure still prints, or a
        // slow build cannot be told from a line nobody wired in.
        #expect(DetailStoreTiming().line.contains("0.000 s"))
        // AND THE SOURCE IS PART OF THE VALUE, not appended by the caller —
        // 396 changes one argument here and the line follows it.
        #expect(DetailStoreTiming(source: .database, seconds: 0, details: 0,
                                  traces: 0).line.contains("the database"))
    }

    /// **THE SEAM STAYS ON THE FILES WHATEVER THE BUILD DOES, AND 396 IS WHY
    /// THIS IS WRITTEN NOW.** `DetailStore(directory:)` is what Compare's
    /// slice 4 and two read-backs use to read the athlete's files for
    /// themselves (§12.134). The day the singleton reads rows, this instance
    /// reading rows too would make three comparisons the database against
    /// itself — which is the exact defect 390 was written to prevent.
    @Test("The seam reads files no matter what the singleton is told to do")
    func theSeamAlwaysReadsFiles() throws {
        let dir = try directory()
        try seed(dir, details: [detail("1", splits: 3)],
                 streams: [streams("1", samples: 12)])

        let seam = DetailStore(directory: dir)
        #expect(seam.detailsServedFrom == .files)
        #expect(seam.tracesServedFrom == .files)
        #expect(seam.constructionTiming.source == .files)
        #expect(seam.details.count == 1)
        #expect(seam.streams.count == 1)
        #expect(seam.constructionTiming.details == 1,
                "the timing counts what this instance actually read")
    }

    /// §12.121.1. The files stay complete and authoritative while the slice is
    /// under test — that is the whole of what makes a slice a slice, and the
    /// seam is the instance that could destroy them.
    @Test("Building the seam changes nothing on disk")
    func buildingTheSeamChangesNothing() throws {
        let dir = try directory()
        try seed(dir, details: [detail("1", splits: 3)],
                 streams: [streams("1", samples: 12)])
        let file = dir.appendingPathComponent("details/1.json")
        let before = try Data(contentsOf: file)

        _ = DetailStore(directory: dir)

        let after = try Data(contentsOf: file)
        #expect(after == before, "the seam wrote over the file it was reading")
    }

    // MARK: Which side each family is served from — patch 398, §12.142

    private func fullDetails() -> DetailLoad {
        .loaded(details: [detail("1", splits: 3)], skipped: 0)
    }
    private func fullTraces() -> RecordingLoad {
        .loaded(recordings: [streams("1", samples: 12)], skipped: 0)
    }

    /// **THE ONE WITH 19.1 MB BEHIND IT.**
    ///
    /// A clean read of an empty table is the backfill mid-flight — 668 traces
    /// in `streams/` and none in `recording`, which is exactly what this device
    /// looked like for three days in August. Taking it would blank every
    /// heart-rate profile and every map and take `LoadStore`'s `streamCount` to
    /// zero with them.
    ///
    /// `wasReadCleanly` is TRUE here. That is the point: the read succeeded and
    /// the answer is still no.
    @Test("An empty table never wins, however clean the read")
    func anEmptyTableNeverWins() {
        let empty = DetailFill.decide(details: .loaded(details: [], skipped: 0),
                                      traces: .loaded(recordings: [], skipped: 0),
                                      hydratesDetails: true, hydratesTraces: true)
        #expect(empty.takeDetails == false)
        #expect(empty.takeTraces == false)
        #expect(empty.needsFiles, "so the files are read and the store is whole")

        // THE CONTROL. If a full table also lost, the assertions above would be
        // passing on a stuck `false` — zero compared to zero, which is what
        // every parity report in this project carries a denominator to avoid.
        let full = DetailFill.decide(details: fullDetails(), traces: fullTraces(),
                                     hydratesDetails: true, hydratesTraces: true)
        #expect(full.takeDetails)
        #expect(full.takeTraces)
        #expect(full.needsFiles == false, "both sides stored, so the files are never opened")
    }

    /// A FAILED READ IS A DIFFERENT NIL FROM AN EMPTY TABLE — §12.92 — and both
    /// end at the files. They are separated here so a future caller that wants
    /// to tell them apart finds them already apart.
    @Test("A failed read falls back, and is not an empty table")
    func aFailedReadFallsBack() {
        let broken = DetailFill.decide(details: .failed("disk I/O error"),
                                       traces: .failed("disk I/O error"),
                                       hydratesDetails: true, hydratesTraces: true)
        #expect(broken.takeDetails == false)
        #expect(broken.takeTraces == false)
        #expect(broken.needsFiles)

        let shut = DetailFill.decide(details: .unavailable, traces: .unavailable,
                                     hydratesDetails: true, hydratesTraces: true)
        #expect(shut.needsFiles, "a database that never opened serves the files")
    }

    /// **HALF IS PERMITTED HERE AND NOWHERE ELSE IN THIS LADDER.** The plan and
    /// the athlete are all-or-nothing because half a plan blanks a screen while
    /// every other figure stays right. A split table and a heart-rate profile
    /// are drawn from different rows by different views, so the two flip
    /// together and can be reverted apart — and `hydratedFamilies` losing one
    /// of them has to leave the other working.
    @Test("One family can be fed while the other reads its files")
    func oneFamilyCanBeFedAlone() {
        let detailsOnly = DetailFill.decide(details: fullDetails(),
                                            traces: fullTraces(),
                                            hydratesDetails: true,
                                            hydratesTraces: false)
        #expect(detailsOnly.takeDetails)
        #expect(detailsOnly.takeTraces == false, "this build does not feed them")
        #expect(detailsOnly.needsFiles, "so the files still have to be read")

        let tracesOnly = DetailFill.decide(details: fullDetails(),
                                           traces: fullTraces(),
                                           hydratesDetails: false,
                                           hydratesTraces: true)
        #expect(tracesOnly.takeDetails == false)
        #expect(tracesOnly.takeTraces)

        // AND THE TABLE STILL HAS TO HOLD SOMETHING. A build that feeds a
        // family says nothing about whether the family is there.
        let wanted = DetailFill.decide(details: .loaded(details: [], skipped: 0),
                                       traces: fullTraces(),
                                       hydratesDetails: true, hydratesTraces: true)
        #expect(wanted.takeDetails == false, "wanted, read cleanly, and empty")
        #expect(wanted.takeTraces)
    }

    /// A build that feeds neither takes neither, whatever the tables hold.
    /// This is what deleting both cases from `hydratedFamilies` does, and it is
    /// the rollback the whole ladder is built on.
    @Test("The rollback is the switch, not the data")
    func theRollbackIsTheSwitch() {
        let off = DetailFill.decide(details: fullDetails(), traces: fullTraces(),
                                    hydratesDetails: false, hydratesTraces: false)
        #expect(off.takeDetails == false)
        #expect(off.takeTraces == false)
        #expect(off.needsFiles, "and the files are complete, which is why it works")
    }

    // MARK: What the flip costs the verifier — patch 398, §12.142

    /// **FIVE COMPARISONS STOP BEING EVIDENCE, AND THIS IS WHERE THAT IS SAID.**
    /// `ActivitiesAreReadTests.fourComparisonsStoppedBeingEvidence` is the same
    /// assertion one slice earlier, and §12.125's rule is why both exist: the
    /// patch before a flip is the one that asks what the flip makes vacuous.
    /// 388 recounted the buckets, 389 and 390 gave Compare's slice 4 and the
    /// two read-backs their own reads, so what is left to lose here is exactly
    /// these five and nothing that mattered goes with them.
    ///
    /// **INJECTED RATHER THAN OBSERVED.** In the test process `DetailStore.shared`
    /// has no database to read, so its `servedFrom` stays `.files` however
    /// `hydratedFamilies` reads — the live accounting only moves on the device.
    /// `ExpectationSources(fedByTheDatabase:)` is what makes the consequence
    /// assertable here rather than discovered in a paste.
    @Test("Five comparisons stop being evidence when both families are fed")
    func fiveComparisonsStopBeingEvidence() throws {
        let db = try Sub4Database.inMemory()
        let before = try SemanticVerifier.verify(
            db, activities: [], sources: ExpectationSources(fedByTheDatabase: []))
        let after = try SemanticVerifier.verify(
            db, activities: [],
            sources: ExpectationSources(fedByTheDatabase: [.details, .traces]))

        for name in ["traces", "details", "splits", "trace samples",
                     "splits of one activity"] {
            guard let c = before.checks.first(where: { $0.name == name }) else {
                // NOT `#expect(c != nil)`. `splits of one activity` is built
                // only when a detail is deep enough to compare, so on an empty
                // database it is legitimately absent — and a bare nil check
                // would make this loop fail for the wrong reason. What must
                // hold is the field of every one that IS built.
                continue
            }
            #expect(c.reads.field == .details || c.reads.field == .traces,
                    "\(name) takes its expectation from a store B4 feeds")
            #expect(!after.independentChecks.contains { $0.name == name },
                    "\(name) still counts as evidence after the flip")
            #expect(after.selfReferentialChecks.contains { $0.name == name })
        }

        #expect(ExpectationField.details.slice == "B4")
        #expect(ExpectationField.traces.slice == "B4")

        // **DERIVED, NOT TYPED — and the first draft of this line typed 5 and
        // failed.** Five comparisons declare these two fields in the source;
        // four are built here, because `splits of one activity` needs a detail
        // deep enough to compare and this database is empty. A hand-written 5
        // would have been a number describing the SOURCE asserted against a
        // report — §12.54.2's cousin, and exactly the mistake `HydratedStores`
        // made at 387.
        let affected = before.checks.filter {
            $0.reads.field == .details || $0.reads.field == .traces
        }
        #expect(affected.count == 4,
                "four of B4's five comparisons are built on an empty database; a fifth appearing here means a new one was added without this test being read")
        #expect(after.independentChecks.count + affected.count
                    == before.independentChecks.count,
                "every comparison reading a fed field left the evidence column, and none that did not")
        #expect(!after.independentChecks.isEmpty,
                "B4 is not B9 — there is still evidence left, and B9 is where that ends")
    }
}
