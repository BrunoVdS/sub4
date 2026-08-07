//
//  DatabaseHealthView.swift
//  Sub4
//
//  What the database says about itself — patch 203, plan step 3.2.5.
//
//  WHY THIS SHIPS BEFORE ANYTHING USES THE DATABASE
//  ------------------------------------------------
//  Patches 195 and 202 built twenty-eight tables that no human being has seen.
//  Every claim about them so far — that the file is created, that the
//  migrations apply in order, that foreign keys are on, that the protection
//  class lands on the sidecars — has been checked in an in-memory database
//  inside a test runner. None of that is the phone.
//
//  This project's own record is the argument. Six of the eleven defects found
//  in Phase 2 were reachable only on hardware; the `Africa/Blantyre` finding
//  came from 661 real rows and not from 181 green tests. So the schema does not
//  get to be called done until somebody has looked at it on the device it will
//  live on, and this is the screen that makes that possible.
//
//  IT IS ALSO THE FIRST CALLER `Sub4Database.open()` HAS EVER HAD.
//  Until now nothing in the app created the file. Opening this screen is what
//  puts `db/sub4.sqlite` on disk for the first time — which is why the
//  inventory entry declared in patch 195, before there was anything to declare,
//  stops being theoretical today. "Delete local data" removes it from the first
//  moment it exists rather than from whenever someone remembered.
//
//  WHY OPENING LAZILY RATHER THAN AT LAUNCH
//  ----------------------------------------
//  Launch ownership belongs to 3.3, which has to run the migration engine
//  before any legacy store initialises. Wiring an open into launch now would be
//  a second answer to a question 3.3 exists to answer once, and it would put a
//  file on the device of anyone who never opens this screen. Opening here
//  proves creation, migration, protection and integrity, and changes nothing
//  else.
//
//  WHAT "REDACTED" MEANS ON THE COPY BUTTON
//  ----------------------------------------
//  Counts, sizes, migration identifiers, and SQLite's own verdicts. No session
//  names, no coordinates, no dates from the athlete's history. A diagnostic
//  that a person is invited to paste into a message has to be safe to paste
//  into a message, and the way to guarantee that is to build it from figures
//  that cannot describe anybody.
//

import SwiftUI

struct DatabaseHealthView: View {

    @Environment(\.dismiss) private var dismiss

    /// Opened once per presentation. `Result` rather than an optional plus an
    /// error string: a database that failed to open and one that has not been
    /// opened yet are different states, and this screen has to distinguish them
    /// or it will show "healthy" while nothing is there.
    @State private var opened: Result<Sub4Database, Error>?
    @State private var report: Sub4Database.IntegrityReport?
    @State private var counts: [(table: String, rows: Int)] = []
    @State private var failure: String?
    @State private var copied = false

    /// Patch 209. Owned by the screen rather than shared: two presentations
    /// should not see each other's run.
    @State private var benchmark = DatabaseBenchmarkRunner()
    @State private var benchmarkSize = DatabaseBenchmarkRunner.sizes[0]

    /// Patch 218 — 3.3.2. Manual for now: the import is a button, not a launch
    /// step, until 3.3.3 makes the database authoritative.
    @State private var importing = false
    @State private var importReport: Sub4Import.Report?
    @State private var importError: String?

    /// Patch 247 — migration contract item 3. Manual for now, like the import
    /// above it: launch ownership belongs to the migration engine, and wiring a
    /// capture into launch before the ledger exists would be a second answer to
    /// a question one patch away from being answered once.
    @State private var snapshotting = false
    @State private var snapshot: SnapshotManifest?
    @State private var snapshotError: String?

    /// Patch 255 — the import ledger. Read on open and after every import.
    @State private var lastRun: MigrationRun?
    @State private var staleRuns: Int = 0

    /// Patch 263 — the semantic verifier. Nil until the button is pressed,
    /// like the survey below and for the same reason: it reads every row the
    /// migration wrote and every value the stores hold.
    @State private var readingBackDetail = false
    @State private var detailTrip: DetailRoundTrip.Report?
    @State private var detailLoad: DetailLoad?
    @State private var readingBack = false
    @State private var roundTrip: ActivityRoundTrip.Report?
    @State private var roundTripLoad: ActivityLoad?
    /// Patch 294. No separate load state: this comparison does its own reading
    /// and the report carries the read's own outcome, because the id read
    /// failing means everything under it is unknown rather than zero.
    @State private var readingBackRecording = false
    @State private var recordingTrip: RecordingRoundTrip.Report?
    @State private var verifying = false
    @State private var verification: VerificationReport?

    /// Patch 262 — the legacy survey. Nil until the button is pressed.
    ///
    /// NOT run on open, unlike everything else on this screen. It reads every
    /// file the app has ever written and decodes all of them, which on this
    /// phone is 667 details and 643 traces. That belongs behind a press, and
    /// a screen that did it silently every time it opened would make opening
    /// the screen the expensive thing.
    /// Patch 302. Observed rather than read once: it changes while this screen
    /// is open, on any backgrounding.
    @State private var writeThrough = DatabaseWriteThrough.shared
    @State private var surveying = false
    @State private var survey: [LegacyReading]?

    var body: some View {
        NavigationStack {
            List {
                switch opened {
                case .none:
                    Section { HStack { ProgressView(); Text("Opening…") } }
                case .failure(let error):
                    failureSection(error)
                case .success(let db):
                    verdictSection
                    fileSection(db)
                    contentsSection
                    // BEFORE the import, on screen and in the contract. Item 3
                    // says copy every legacy input before decoding, and a
                    // screen that offers to import above the button that
                    // protects the inputs teaches the wrong order.
                    snapshotSection
                    importSection(db)
                    // PATCH 302. Directly after the Import section, because it
                    // IS that import — fired without anybody pressing it. The
                    // screen reads in the order the two things relate: here is
                    // the button, and here is what happens when nobody presses
                    // it.
                    writeThroughSection(db)
                    ledgerSection
                    // DIRECTLY AFTER THE LEDGER, because it is the thing that
                    // moves a run out of `pending`. The screen reads in the
                    // order the states go: imported, then verified.
                    verifySection(db)
                readBackSection(db)
                detailReadBackSection(db)
                recordingReadBackSection(db)
                    // AFTER the import and before the benchmark. It is about
                    // the files the import reads FROM, so it belongs beside
                    // the import; it is a survey rather than an action, so it
                    // does not go above it.
                    legacySection
                    benchmarkSection
                    diagnosticsSection(db)
                }
            }
            .navigationTitle("Database")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    // MARK: Sections

    /// FIRST, AND IN ONE LINE. A health screen whose verdict is assembled by
    /// the reader from four rows further down is a screen that gets skimmed.
    @ViewBuilder
    private var verdictSection: some View {
        Section {
            if let report {
                LabeledContent("Status") {
                    Text(report.isHealthy ? "Healthy" : "Problem")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(report.isHealthy ? Color.secondary : Color.red)
                }
                Text(report.summary)
                    .font(.caption)
                    .foregroundStyle(report.isHealthy ? Color.dim : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func fileSection(_ db: Sub4Database) -> some View {
        Section {
            LabeledContent("Location", value: db.location.isInMemory ? "In memory" : "On this phone")
            if let report {
                LabeledContent("Size", value: report.bytesOnDisk.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? "—")
                LabeledContent("Integrity", value: report.quickCheck)
                LabeledContent("Orphaned rows", value: "\(report.foreignKeyViolations)")
                // Asked of the connection rather than assumed of the library.
                // ADR-0003 §7 calls this "the single most common way a schema
                // with declared relationships turns out never to have enforced
                // them".
                LabeledContent("Foreign keys", value: report.foreignKeysEnabled ? "on" : "OFF")
                    .foregroundStyle(report.foreignKeysEnabled ? Color.primary : Color.red)
            }
            // WHO OPENED IT — patch 216, and the only self-evident proof that
            // 3.3.1 works.
            //
            // The claim the launch gate makes is that the database is prepared
            // before `ContentView` is constructed. Verifying that by deleting
            // the app, launching, avoiding Settings and looking at a healthy
            // screen depends entirely on the procedure being followed, and a
            // database that already existed looks identical.
            //
            // `Sub4Launch.shared.database` is non-nil only if the gate opened
            // it. If this screen had to fall back to opening its own connection,
            // the gate did not run — which on a real launch means it is broken.
            LabeledContent("Prepared",
                           value: Sub4Launch.shared.database != nil
                                ? "at launch" : "by this screen")
                .foregroundStyle(Sub4Launch.shared.database != nil
                                 ? Color.primary : Color.red)

            LabeledContent("Protection", value: "Until first unlock")
        } header: {
            Text("The file")
        } footer: {
            Text("The database and its journal files sit in their own folder, "
                 + "which carries the protection class so anything SQLite "
                 + "creates inside it inherits. Delete local data removes the "
                 + "folder whole, so nothing is left in a sidecar.")
                .font(.caption2)
        }
    }

    /// EVERY TABLE, INCLUDING THE EMPTY ONES, and the zeros are the point.
    ///
    /// Twenty-eight tables reading zero is the correct state today and the fact
    /// most worth seeing: it says the schema exists and nothing has been
    /// imported. A screen that hid empty tables to look tidier would show an
    /// empty list and leave the reader to guess whether that meant "no tables"
    /// or "no data".
    @ViewBuilder
    private var contentsSection: some View {
        Section {
            if counts.isEmpty {
                Text("No tables").foregroundStyle(.secondary)
            } else {
                ForEach(counts, id: \.table) { row in
                    LabeledContent(row.table) {
                        Text("\(row.rows)")
                            .monospacedDigit()
                            // Seeded rows are dimmed like empty ones: on this
                            // screen the emphasis means "something was
                            // imported", and six seeded sources were not.
                            .foregroundStyle(
                                row.rows == 0 || Sub4Database.seededTables.contains(row.table)
                                ? Color.dim : Color.primary)
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text("Rows — \(counts.count) table\(counts.count == 1 ? "" : "s")")
        } footer: {
            Text(importedRows == 0
                 ? "Nothing imported yet, which is correct: the schema is built "
                 + "and step 3.3 is what fills it. The rows in source are seeded "
                 + "by the migration — they are the list of places data can come "
                 + "from, not data."
                 : "\(importedRows) imported rows, \(totalRows) in total.")
                .font(.caption2)
        }
    }

    /// The snapshot: what the last one found, and a button to take another.
    ///
    /// Four numbers and not one. "Healthy" would be the wrong shape here —
    /// a capture that copied 800 files and missed one is not a failure and is
    /// not a success, and the only honest presentation is the counts.
    @ViewBuilder
    private var snapshotSection: some View {
        Section {
            if let m = snapshot {
                // NOT LOCALISED, and that is the decision — patch 304.
                //
                // `2026-08-05-202320` is a FOLDER NAME. It is a stamp being
                // used as an identifier, and rendering it as local time would
                // break the correspondence between this row and what is on
                // disk: you could no longer find the directory it names.
                //
                // A timestamp that is a name is not a time. §12.48.
                LabeledContent("Last snapshot", value: m.id)
                    .font(.caption)

                LabeledContent("Files copied", value: "\(m.copiedCount) of \(m.presentCount)")
                    .font(.caption)
                LabeledContent("Size",
                               value: ByteCountFormatter.string(
                                fromByteCount: Int64(m.totalBytes), countStyle: .file))
                    .font(.caption)
                if m.missingCount > 0 {
                    // Not red. A declared file that is not there is a normal
                    // answer on a fresh install, and the row exists so the
                    // number is visible rather than inferred from a total.
                    LabeledContent("Declared but not present", value: "\(m.missingCount)")
                        .font(.caption).foregroundStyle(Color.dim)
                }
                if m.failureCount > 0 {
                    LabeledContent("Failed to copy", value: "\(m.failureCount)")
                        .font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Taken by", value: "patch \(m.appVersion)")
                    .font(.caption).foregroundStyle(Color.dim)
            } else {
                Text("No snapshot has ever been taken. Every legacy file is "
                     + "one reinstall away from being gone — two of those "
                     + "happened in one week and cost four session notes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if snapshotting {
                HStack { ProgressView(); Text("Copying…").font(.caption) }
            } else {
                Button("Snapshot now") { runSnapshot() }
            }

            if let e = snapshotError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Protected snapshot")
        } footer: {
            Text("A dated copy of every file the app has written, with a "
                 + "SHA-256 for each, taken before anything reads them. "
                 + "Copies — nothing is moved or removed. Removed by Delete "
                 + "local data along with the database.")
        }
    }

    /// THE CUTOVER, RUN BY HAND — patch 218, plan step 3.3.2.
    ///
    /// A button rather than a launch step, deliberately. Until 3.3.3 makes the
    /// database authoritative, importing changes nothing the athlete sees, so
    /// there is no reason for it to happen without being asked for — and every
    /// reason to be able to run it, look at the counts, and run it again.
    ///
    /// It reads the STORES, not the JSON files. See `Sub4Import`'s header: the
    /// two differ by a gate, and a cutover has to land on what the app shows.
    @ViewBuilder
    private func importSection(_ db: Sub4Database) -> some View {
        Section {
            if importing {
                HStack { ProgressView(); Text("Importing…").font(.caption) }
            } else {
                Button("Import from the app's stores") { runImport(db) }
            }

            if let e = importError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let r = importReport, r.activitiesSeen == 0 {
                // Patch 220. All-zero counts read exactly like a broken button —
                // which is how a first run against empty stores looked.
                Text("The app's stores are empty, so there was nothing to copy. "
                     + "Open Today and let the sync finish first.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let r = importReport {
                LabeledContent("Activities seen", value: "\(r.activitiesSeen)")
                    .font(.caption)
                LabeledContent("Imported", value: "\(r.activitiesInserted)")
                    .font(.caption)
                LabeledContent("Refreshed", value: "\(r.activitiesUpdated)")
                    .font(.caption)
                LabeledContent("Gear", value: "\(r.gearInserted) new, \(r.gearAlreadyPresent) known")
                    .font(.caption)
                // The two that cannot be re-fetched, so they get their own rows
                // rather than being folded into a total.
                LabeledContent("Notes",
                               value: "\(r.notesImported) new, \(r.notesUpdated) refreshed")
                    .font(.caption)
                LabeledContent("Reviews",
                               value: "\(r.reviewsImported) new, \(r.reviewsUpdated) refreshed")
                    .font(.caption)
                // PATCH 272 — the third thing on this screen that cannot be
                // re-fetched from anywhere, so it gets a row of its own rather
                // than being folded into a total it would vanish inside.
                LabeledContent("Match decisions",
                               value: "\(r.matchDecisionsImported) new, \(r.matchDecisionsUpdated) refreshed")
                    .font(.caption)
                if r.matchDecisionsUnresolved > 0 {
                    // NEWS, unlike the two greyed rows below it. A decision
                    // naming an activity that is not here was held back, so
                    // the athlete's correction is not in the database and
                    // nothing else on this screen would say so.
                    LabeledContent("  decision naming a missing activity",
                                   value: "\(r.matchDecisionsUnresolved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.matchDecisionsIgnored > 0 {
                    LabeledContent("  decision on an excluded recording",
                                   value: "\(r.matchDecisionsIgnored)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                LabeledContent("Weather",
                               value: "\(r.weatherImported) new, \(r.weatherUpdated) refreshed")
                    .font(.caption)
                if r.weatherUnmatched > 0 {
                    // Not red: the schema is correctly declining to hold a
                    // reading about an activity that is not here.
                    //
                    // DEMOTED TO A SUB-ROW IN 257, to match the trace and the
                    // detail below. It is a fact ABOUT the Weather row, and
                    // rendering it at the same weight as its own parent made a
                    // known-benign count the loudest thing in the section.
                    LabeledContent("  weather with no activity",
                                   value: "\(r.weatherUnmatched)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.weatherIgnored > 0 {
                    // Patch 257. Named for the decision rather than the
                    // symptom: this reading belongs to a recording the app
                    // excludes on purpose, which is not the same thing as an
                    // activity that went missing.
                    LabeledContent("  weather for an excluded recording",
                                   value: "\(r.weatherIgnored)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                // Patch 228. Two hundred bytes, and the denominator of every
                // training-load figure in the app — so it gets rows of its own
                // rather than being folded into a total it would vanish inside.
                LabeledContent("Profile",
                               value: r.profileSeen == 0
                               ? "not offered"
                               : "\(r.profileImported) new, \(r.profileUpdated) refreshed")
                    .font(.caption)
                if r.profileProvenanceUnresolved > 0 {
                    // Not red, and not a refusal: the profile imported. What is
                    // missing is which activity produced the observed maximum.
                    LabeledContent("Observed max — no activity found", value: "1")
                        .font(.caption).foregroundStyle(Color.dim)
                }
                LabeledContent("Heart-rate zones",
                               value: r.zonesSeen == 0
                               ? "none held" : "\(r.zonesImported) of \(r.zonesSeen)")
                    .font(.caption)
                LabeledContent("Resting months",
                               value: "\(r.restingImported) new, \(r.restingUpdated) refreshed")
                    .font(.caption)

                // Patch 237. `unchanged` is the expected answer on every run
                // after the first — the content hash matched and nothing was
                // rewritten. Shown rather than hidden, because a plan import
                // that quietly did nothing and one that quietly did everything
                // twice would otherwise look the same.
                LabeledContent("Plan",
                               value: r.planSeen == 0 ? "not offered"
                                      : (r.planImported > 0 ? "new version"
                                         : "unchanged"))
                    .font(.caption)
                if r.planImported > 0 {
                    LabeledContent("  weeks / sessions",
                                   value: "\(r.planWeeks) / \(r.planSessions)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("  breakdowns / blocks",
                                   value: "\(r.planDetails) / \(r.planBlocks)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("  week stats / exercises",
                                   value: "\(r.planWeekStats) / \(r.planExercises)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("  fuel / warm-up rows",
                                   value: "\(r.planFuelRows) / \(r.planWarmupRows)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                // Patch 243. Traces and details, counted apart: a session
                // can have one, both or neither, and folding them into a total
                // would make "no trace" and "no detail" the same number.
                LabeledContent("Traces",
                               value: r.recordingsSeen == 0 ? "none held"
                                      : "\(r.recordingsImported) new, \(r.recordingsUpdated) replaced, \(r.recordingsUnchanged) unchanged")
                    .font(.caption)
                if r.samplesImported > 0 {
                    LabeledContent("  samples", value: "\(r.samplesImported)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.recordingsShort > 0 {
                    LabeledContent("  under 8 samples", value: "\(r.recordingsShort)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.recordingsUnmatched > 0 {
                    LabeledContent("  trace with no activity", value: "\(r.recordingsUnmatched)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.recordingsIgnored > 0 {
                    // Not a gap. `DataCorrections` names each one with its
                    // reason, and Settings lists them.
                    LabeledContent("  trace for an excluded recording",
                                   value: "\(r.recordingsIgnored)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                LabeledContent("Details",
                               value: r.detailsSeen == 0 ? "none held"
                                      : "\(r.detailsImported) new, \(r.detailsUpdated) replaced, \(r.detailsUnchanged) unchanged")
                    .font(.caption)
                if r.splitsImported + r.lapsImported + r.effortsImported > 0 {
                    LabeledContent("  splits / laps / efforts",
                                   value: "\(r.splitsImported) / \(r.lapsImported) / \(r.effortsImported)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.detailsUnmatched > 0 {
                    LabeledContent("  detail with no activity", value: "\(r.detailsUnmatched)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.detailsIgnored > 0 {
                    LabeledContent("  detail for an excluded recording",
                                   value: "\(r.detailsIgnored)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                if r.gearUnresolved > 0 {
                    LabeledContent("Naming unknown gear", value: "\(r.gearUnresolved)")
                        .font(.caption)
                    // WHICH ids, not just how many — patch 221. One untracked
                    // bike and forty missing shoes are different problems and a
                    // count cannot tell them apart.
                    ForEach(r.unresolvedGearRanked.prefix(10), id: \.external) { item in
                        LabeledContent(item.external) {
                            Text("\(item.count)").monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(Color.dim)
                    }
                }
                // PATCH 280. Named "Commute decisions" and not
                // "Corrections", because that is what these rows ARE today —
                // `DataCorrections` will land in the same table later and this
                // row would then be lying about what it counts.
                LabeledContent("Commute decisions",
                               value: r.correctionsSeen == 0
                               ? "none"
                               : "\(r.correctionsImported) new, \(r.correctionsUpdated) refreshed")
                    .font(.caption)
                if r.correctionsUnresolved > 0 {
                    LabeledContent("  decision naming a missing ride",
                                   value: "\(r.correctionsUnresolved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.correctionsIgnored > 0 {
                    LabeledContent("  decision on an excluded recording",
                                   value: "\(r.correctionsIgnored)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.correctionsRemoved > 0 {
                    LabeledContent("  opinions withdrawn",
                                   value: "\(r.correctionsRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                // PATCH 278. The one row on this screen that describes
                // recordings the database does not hold and never will — so it
                // sits with the counts rather than with the activities.
                LabeledContent("Refused recordings",
                               value: r.rejectionsSeen == 0
                               ? "none"
                               : "\(r.rejectionsImported) new, \(r.rejectionsUpdated) refreshed")
                    .font(.caption)

                // PATCH 277. THE COUNTER THAT HAD NO DECISION BESIDE IT.
                //
                // `activity: 668` and `recording: 645` sit four lines apart in
                // the table list and nothing accounted for the difference —
                // finding out what it was took reading `DetailStore`, which is
                // not a thing a number on a screen should require.
                //
                // Every activity lands in exactly one bucket and the buckets
                // sum to the total, so `unexplained` is the only line worth
                // watching: it is zero today, and the day it is not is the day
                // an activity has no trace for a reason nothing here has a
                // name for.
                if coverage.missing > 0 {
                    LabeledContent("Activities with no trace",
                                   value: "\(coverage.missing) of \(coverage.total)")
                        .font(.caption)
                    if coverage.answeredEmpty > 0 {
                        LabeledContent("  asked, nothing there",
                                       value: "\(coverage.answeredEmpty)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    if coverage.refused > 0 {
                        LabeledContent("  the source refused it",
                                       value: "\(coverage.refused)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    if coverage.belowThreshold > 0 {
                        LabeledContent("  under 500 m, never asked",
                                       value: "\(coverage.belowThreshold)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    if coverage.queued > 0 {
                        LabeledContent("  queued, not yet reached",
                                       value: "\(coverage.queued)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    // RED, AND SHOWN EVEN AT ZERO once anything is missing —
                    // the residual is the whole point of the account, and a
                    // line that only appears when it is non-zero cannot be
                    // told apart from a line nobody wired in.
                    LabeledContent("  unexplained", value: "\(coverage.unexplained)")
                        .font(.caption2)
                        .foregroundStyle(coverage.isFullyExplained ? Color.dim : Color.red)
                }

                // PATCH 276. Named for what it MEANS rather than for its
                // table: every row is a recording the app has decided not to
                // ask about again, and "work queue" would suggest something
                // still waiting to happen.
                LabeledContent("Stopped asking",
                               value: r.workItemsSeen == 0
                               ? "nothing"
                               : "\(r.workItemsImported) new, \(r.workItemsUpdated) refreshed")
                    .font(.caption)
                if r.workItemsRemoved > 0 {
                    LabeledContent("  no longer skipped",
                                   value: "\(r.workItemsRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                // PATCH 275. Its own row rather than a line inside Activities:
                // this is the only thing on this screen that says WHERE the
                // sync is, and at D7 it becomes the thing the sync reads.
                LabeledContent("Sync position",
                               value: r.syncStateSeen == 0
                               ? "not offered"
                               : "\(r.syncStateImported) new, \(r.syncStateUpdated) refreshed")
                    .font(.caption)

                // PATCH 274. A pass that DELETES has to say so on the same
                // screen and with the same weight as one that adds — a silent
                // removal is the defect §12.2 names, from the other side.
                LabeledContent("Reconciled", value: r.reconciled.line)
                    .font(.caption)
                    .foregroundStyle(r.reconciled.isRunning ? Color.primary : Color.red)
                if r.notesRemoved > 0 {
                    LabeledContent("  notes removed", value: "\(r.notesRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.matchDecisionsRemoved > 0 {
                    LabeledContent("  match decisions removed",
                                   value: "\(r.matchDecisionsRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.reviewsRemoved > 0 {
                    // Named with its consequence. One review takes its
                    // evidence, its proposal, its changes and its watch items
                    // with it, and a row saying "1" while five vanish is a
                    // number that invites the wrong arithmetic.
                    LabeledContent("  reviews removed, with their proposals",
                                   value: "\(r.reviewsRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                // PATCH 297. Computed since the importer existed, from a
                // ContinuousClock around the write, and displayed nowhere —
                // so the one number D6b's design turns on has been taken and
                // thrown away on every run. §12.41.2.
                //
                // Three decimals because the interesting question is whether
                // this is under two seconds, and "1 s" cannot answer it.
                LabeledContent("Took",
                               value: String(format: "%.3f s", r.seconds))
                    .font(.caption).foregroundStyle(Color.dim)

                // REFUSALS ARE SHOWN, NOT COUNTED AND HIDDEN. A silent
                // rejection is indistinguishable from a row that was never
                // there — §12.2.
                LabeledContent("Refused") {
                    Text("\(r.refusals.count)")
                        .foregroundStyle(r.isClean ? Color.dim : Color.red)
                }
                .font(.caption)
                ForEach(r.refusals) { refusal in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(refusal.externalID).font(.caption2.monospaced())
                        Text(refusal.reason).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Import")
        } footer: {
            Text("Copies activities and gear from the app's current stores into "
                 + "the database. Nothing else changes: the app still reads its "
                 + "JSON files, and the JSON files are not touched. Running it "
                 + "twice imports nothing twice.")
                .font(.caption2)
        }
    }

    /// Off the main actor, and not as a nicety: this hashes and copies every
    /// file the app has ever written — on this device roughly 850 files and 25
    /// megabytes. `LegacySnapshot` is `nonisolated` throughout so the work can
    /// leave the main actor here and only the result comes back to it.
    private func runSnapshot() {
        snapshotting = true
        snapshotError = nil
        // `patchLabel` since 284: a snapshot taken under a fix-up should say
        // so. This string is the manifest's only record of what took it.
        let version = AppVersion.patchLabel
        // Read here, on the main actor, where the inventory lives. Inside the
        // detached task below it would not be reachable.
        let items = DataLifecycle.appSupportItems
        Task {
            let stamp = LegacySnapshot.stamp(for: Date())
            let result: Result<SnapshotManifest, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try LegacySnapshot.capture(stamp: stamp,
                                                               appVersion: version,
                                                               items: items))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let m):
                snapshot = m
                if m.failureCount > 0 {
                    snapshotError = "\(m.failureCount) file\(m.failureCount == 1 ? "" : "s") "
                                  + "could not be copied or did not verify. The manifest "
                                  + "in \(m.id) names each one."
                }
            case .failure(let error):
                snapshotError = error.localizedDescription
            }
            snapshotting = false
        }
    }

    /// Patch 277. Recomputed on every render rather than stored: it is six
    /// counters over an array the screen already holds, and a cached copy
    /// would be the thing that goes stale after an import.
    private var coverage: TraceCoverage { DetailStore.shared.traceCoverage() }

    private func runImport(_ db: Sub4Database) {
        importing = true
        importError = nil
        Task {
            do {
                // ONE VALUE, GATHERED IN ONE PLACE — patch 301, §12.45.
                //
                // This used to be twenty hand-written arguments, and the
                // verifier forty lines below repeated thirteen of them.
                // `Sub4Import.run` defaults eighteen of its parameters, so a
                // forgotten one is not a compile error — it is a table that
                // silently stops being imported, which a read-back would then
                // report as data missing from the database.
                //
                // The gate patch 274 built moved with it. It still fails
                // closed, and `AppStores.reconcileRequires` is the list it
                // fails closed on — beside the fields it is about, because a
                // name MISSING from that list makes reconciliation more likely
                // to run, and reconciliation deletes.
                importReport = try Sub4Import.run(
                    into: db,
                    stores: AppStores.current(),
                    appVersion: AppVersion.patchLabel,
                    // The link between contract items 3 and 11: a run records
                    // which snapshot of its inputs was taken first, or records
                    // that none was.
                    snapshotID: snapshot?.id)
                await recheck(db)
                await reloadLedger(db)
            } catch {
                importError = String(describing: error)
                // The ledger recorded the failure inside `run`. Read it back so
                // the screen shows `failed` rather than the previous run.
                await reloadLedger(db)
            }
            importing = false
        }
    }

    /// PLAN STEP 3.2.7, ON THE DEVICE IT IS ABOUT.
    ///
    /// The tests run this benchmark on every build and assert nothing about its
    /// timings, deliberately — a threshold that fails on a busy CI machine
    /// teaches everybody to ignore the suite. The numbers that decide §9
    /// question 3 have to come from here, because the simulator has the Mac's
    /// disk and none of the phone's limits.
    @ViewBuilder
    private var benchmarkSection: some View {
        Section {
            Picker("Activities", selection: $benchmarkSize) {
                ForEach(DatabaseBenchmarkRunner.sizes, id: \.self) { n in
                    Text(n.formatted()).tag(n)
                }
            }
            .pickerStyle(.segmented)
            .disabled(benchmark.isRunning)

            if benchmark.isRunning {
                HStack {
                    ProgressView()
                    Text(benchmark.progressLine ?? "Running…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Stop", role: .destructive) { benchmark.cancel() }
            } else {
                Button("Run benchmark") {
                    copied = false
                    benchmark.start(activities: benchmarkSize)
                }
            }

            switch benchmark.phase {
            case .cancelled:
                Text("Stopped before finishing.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }

            if let r = benchmark.result {
                benchmarkResult(r)
            }
        } header: {
            Text("Benchmark")
        } footer: {
            Text(benchmark.result == nil
                 ? "Builds a throwaway database in temporary space, measures it, "
                 + "and deletes it. Your own database is never opened by this. "
                 + "10,000 activities is three million sample rows and writes "
                 + "several hundred megabytes while it runs — start at 500 to "
                 + "get a per-activity figure before committing to it."
                 : "Storage and read within three times the chunked shape means "
                 + "one row per sample stays. Above it, the recording tables and "
                 + "the importer both change, which is why this runs before step "
                 + "3.3 and not after.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func benchmarkResult(_ r: DatabaseBenchmark.Result) -> some View {
        LabeledContent("Ran", value: "\(r.activities.formatted()) activities")
        LabeledContent("Build", value: String(format: "%.1f s", r.buildSeconds))

        ForEach(r.queries) { m in
            LabeledContent(m.name) {
                Text("\(m.label) · \(m.rows) rows")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
        }

        LabeledContent("Normalised") {
            Text(bytes(r.storage.normalisedBytes)).monospacedDigit()
        }
        .font(.caption)
        LabeledContent("Chunked") {
            Text(bytes(r.storage.chunkedBytes)).monospacedDigit()
        }
        .font(.caption)
        LabeledContent("Storage cost") {
            Text(String(format: "×%.2f", r.storage.storageRatio)).monospacedDigit()
        }
        .font(.caption)
        LabeledContent("Read cost") {
            Text(String(format: "×%.2f", r.storage.readRatio)).monospacedDigit()
        }
        .font(.caption)

        // ABOVE THE VERDICT, NOT BELOW IT — patch 211.
        //
        // Patch 209 read the chunked side with the normalised side's key, so
        // it timed a lookup that matched nothing and the screen reported a
        // read cost with confidence. This row is what makes that impossible to
        // miss: both shapes hold the same series, so both must hand back the
        // same number of values.
        // THE BUDGETS, NOT THE RATIOS — patch 212. The ratios above describe
        // the difference between the shapes; these decide. Each shows what was
        // measured against what was allowed, so a fail says which budget and
        // by how much rather than only that something was wrong.
        ForEach(r.storage.budgetChecks) { check in
            LabeledContent(check.name) {
                Text("\(check.measured) / \(check.budget)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(check.passes ? Color.dim : Color.red)
            }
            .font(.caption)
        }

        LabeledContent("Read check") {
            Text(r.storage.readCheckLabel)
                .font(.caption)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(r.storage.readsAgree ? Color.dim : Color.red)
        }
        .font(.caption)

        // The verdict, first-class rather than left to the reader to compute
        // from two ratios — the same argument as the status row at the top.
        // Withheld outright when the read check failed: a verdict computed
        // from a measurement known to be invalid is worse than no verdict,
        // because somebody will write it into the ADR.
        LabeledContent("Verdict") {
            if r.storage.readsAgree {
                Text(r.storage.normalisedIsAffordable ? "Keep normalised" : "Chunk it")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(r.storage.normalisedIsAffordable ? Color.secondary : Color.red)
            } else {
                Text("Withheld")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.red)
            }
        }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    // MARK: The semantic verifier — patch 263

    /// Does the database say the same thing as the stores.
    ///
    /// EVERY COMPARISON IS LISTED, PASSING OR NOT. A green tick would be the
    /// same defect the import report avoided in patch 218: a control that says
    /// it is happy without saying what it looked at cannot be argued with, and
    /// D7 is a decision somebody has to be able to argue with.
    @ViewBuilder
    private func verifySection(_ db: Sub4Database) -> some View {
        Section {
            if verifying {
                HStack { ProgressView(); Text("Comparing…").font(.caption) }
            } else {
                Button("Verify against the app's stores") { runVerify(db) }
            }

            if let v = verification {
                LabeledContent("Verdict",
                               value: v.passed ? "everything agreed"
                                               : "\(v.failures.count) disagreed")
                    .font(.caption)
                    .foregroundStyle(v.passed ? Color.dim : .red)
                LabeledContent("Compared", value: "\(v.checks.count) things")
                    .font(.caption).foregroundStyle(Color.dim)

                ForEach(v.checks) { check in
                    LabeledContent("  \(check.name)",
                                   value: check.passed ? check.found
                                                       : "\(check.expected) → \(check.found)")
                        .font(.caption2)
                        .foregroundStyle(check.passed ? Color.dim : .red)
                    // Only failures earn a second line, and it names the table
                    // — the acceptance criterion, on screen.
                    if !check.passed {
                        Text("    in \(check.table)\(check.detail.map { " · " + $0 } ?? "")")
                            .font(.caption2).foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Verification")
        } footer: {
            Text("Compares the database against the app's own stores: counts, "
                 + "which activities are there, the fields of every one, and a "
                 + "few figures the app actually shows. The last import is "
                 + "marked verified only if every comparison agrees.")
                .font(.caption2)
        }
    }

    /// PATCH 290. The reader against the real data.
    ///
    /// Beside verification rather than inside it: the verifier compares COUNTS
    /// and a few figures, this compares one activity to another field by
    /// field. Equal counts can hide changed values — §12.16 — and this is the
    /// check that would notice.
    @ViewBuilder
    private func readBackSection(_ db: Sub4Database) -> some View {
        Section {
            if readingBack {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            } else {
                Button("Read the activities back out") { runReadBack(db) }
            }

            if let load = roundTripLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            }

            if let r = roundTrip {
                LabeledContent("Compared", value: "\(r.compared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Agreed on every field", value: "\(r.agreed)")
                    .font(.caption)
                    .foregroundStyle(r.agreed == r.compared ? Color.dim : Color.ink)

                if !r.missing.isEmpty {
                    LabeledContent("In the store, not in the database",
                                   value: "\(r.missing.count)")
                        .font(.caption).foregroundStyle(.red)
                }

                // THE FIELD TALLY FIRST. "12 differ" sends somebody through
                // twelve activities; "12, all on maxSpeed" is one fix.
                ForEach(r.fieldTally, id: \.field) { entry in
                    LabeledContent("  \(entry.field)", value: "\(entry.count)")
                        .font(.caption2).foregroundStyle(.red)
                }

                // A few ids to open, and the rest counted rather than dropped.
                ForEach(r.differences.prefix(5)) { d in
                    Text("    \(d.id) — \(d.fields.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.differences.count > 5 {
                    Text("    + \(r.differences.count - 5) more")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
            }
        } header: {
            Text("Read-back")
        } footer: {
            Text("Reads every activity out of the database through "
                 + "ActivityRepository and compares it, field by field, to the "
                 + "one the app is running on. This is the question D6c asks of "
                 + "everything, asked of one table now. Nothing is written.")
                .font(.caption2)
        }
    }

    /// PATCH 291. The same shape as the activity read-back, one level down.
    @ViewBuilder
    private func detailReadBackSection(_ db: Sub4Database) -> some View {
        Section {
            if readingBackDetail {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            } else {
                Button("Read the details back out") { runDetailReadBack(db) }
            }

            if let load = detailLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            }

            if let r = detailTrip {
                LabeledContent("Compared", value: "\(r.compared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Agreed on every field", value: "\(r.agreed)")
                    .font(.caption)
                    .foregroundStyle(r.agreed == r.compared ? Color.dim : Color.ink)
                if !r.missing.isEmpty {
                    LabeledContent("In the store, not in the database",
                                   value: "\(r.missing.count)")
                        .font(.caption).foregroundStyle(.red)
                }
                // Patch 298 — see the recording section. Dim, because it is a
                // decision rather than a shortfall.
                if !r.excluded.isEmpty {
                    LabeledContent("Excluded on purpose", value: "\(r.excluded.count)")
                        .font(.caption).foregroundStyle(Color.dim)
                }
                // The tally first, and this comment was RIGHT before the code
                // was — "all on splits[*].averageHR" is what it always meant to
                // say, and until 295 the tally could not say it. §12.40.
                ForEach(r.fieldTally.prefix(12), id: \.field) { entry in
                    LabeledContent("  \(entry.field)",
                                   value: entry.elements == entry.details
                                       ? "\(entry.details)"
                                       : "\(entry.details) · \(entry.elements) elements")
                        .font(.caption2).foregroundStyle(.red)
                }
                if r.fieldTally.count > 12 {
                    Text("  + \(r.fieldTally.count - 12) more fields")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                // AND THE IDS. Collapsing the tally moved the lap index out of
                // it, so it has to arrive here or it is gone from the screen —
                // a summary that leaves nothing to open is a dead end.
                ForEach(r.differences.prefix(5)) { d in
                    Text("    \(d.id) — \(fieldSummary(d.fields))")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.differences.count > 5 {
                    Text("    + \(r.differences.count - 5) more")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

            }
        } header: {
            Text("Read-back · details")
        } footer: {
            Text("The same comparison one level down: splits, laps and best "
                 + "efforts, matched by index and by name rather than by "
                 + "position. A heart rate the importer normalised to nothing "
                 + "is expected to show here, as one row rather than one per "
                 + "lap — see ADR-0003 §12.37 and §12.40.")
                .font(.caption2)
        }
    }

    /// PATCH 294. The third read-back, and the only one that walks samples.
    ///
    /// The tally is in TWO parts here and one part on the other two screens.
    /// "12 recordings differ on heartRate" is a different question from "91
    /// samples out of 186,204 differ on heartRate" — the first says how wide
    /// the problem is, the second says how deep — and one number cannot answer
    /// both. §12.39.2.
    @ViewBuilder
    private func recordingReadBackSection(_ db: Sub4Database) -> some View {
        Section {
            if readingBackRecording {
                HStack { ProgressView(); Text("Walking samples…").font(.caption) }
            } else {
                Button("Read the recordings back out") { runRecordingReadBack(db) }
            }

            if let r = recordingTrip {
                LabeledContent("The read", value: r.line)
                    .font(.caption)
                    .foregroundStyle(r.isTrustworthy ? Color.dim : .red)

                if r.isTrustworthy {
                    LabeledContent("Compared", value: "\(r.compared)")
                        .font(.caption).foregroundStyle(Color.dim)
                    LabeledContent("Agreed on every sample", value: "\(r.agreed)")
                        .font(.caption)
                        .foregroundStyle(r.agreed == r.compared ? Color.dim : Color.ink)
                    LabeledContent("Samples walked", value: "\(r.samplesWalked)")
                        .font(.caption).foregroundStyle(Color.dim)

                    if !r.missing.isEmpty {
                        LabeledContent("In the store, not in the database",
                                       value: "\(r.missing.count)")
                            .font(.caption).foregroundStyle(.red)
                    }
                    // DIM, NOT RED — patch 298. These are the sessions
                    // DataCorrections refuses; the store keeps their traces and
                    // the database declines them, permanently and on purpose.
                    // A red row that is correct for ever stops being read.
                    if !r.excluded.isEmpty {
                        LabeledContent("Excluded on purpose", value: "\(r.excluded.count)")
                            .font(.caption).foregroundStyle(Color.dim)
                    }
                    if !r.unreadable.isEmpty {
                        LabeledContent("Could not be read", value: "\(r.unreadable.count)")
                            .font(.caption).foregroundStyle(.red)
                    }

                    // How WIDE — recordings, by field.
                    ForEach(r.fieldTally.prefix(12), id: \.field) { entry in
                        LabeledContent("  \(entry.field)", value: "\(entry.count)")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    if r.fieldTally.count > 12 {
                        Text("  + \(r.fieldTally.count - 12) more fields")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }

                    // How DEEP — samples, by stream.
                    ForEach(r.sampleTally, id: \.stream) { entry in
                        LabeledContent("  \(entry.stream) samples",
                                       value: "\(entry.differing) of \(entry.walked)")
                            .font(.caption2).foregroundStyle(.red)
                    }

                    ForEach(r.differences.prefix(5)) { d in
                        Text("    \(d.id) — \(d.detail)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                    if r.differences.count > 5 {
                        Text("    + \(r.differences.count - 5) more")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                }
            }
        } header: {
            Text("Read-back · recordings")
        } footer: {
            Text("Every sample of every stream, compared one recording at a "
                 + "time. A recording whose lengths disagree is reported as a "
                 + "length and not walked, so one missing sample cannot report "
                 + "as three hundred. A stream that was shorter than the "
                 + "distance axis comes back padded with zeros and its "
                 + "original length is gone — that is a real loss and it is "
                 + "expected to show here. See ADR-0003 §12.39.")
                .font(.caption2)
        }
    }

    private func runRecordingReadBack(_ db: Sub4Database) {
        readingBackRecording = true
        let store = Array(DetailStore.shared.streams.values)
        Task {
            // OFF the main actor, unlike the two above — 645 read transactions
            // and ~1.5 million comparisons. See `compareOffMain`.
            recordingTrip = await RecordingRoundTrip.compareOffMain(db, store: store)
            readingBackRecording = false
        }
    }

    /// The precise names, trimmed. `laps[*].averageHR` in the tally says WHAT;
    /// this says which laps, on the ids it prints, so the collapsed row still
    /// leads somewhere.
    private func fieldSummary(_ fields: [String]) -> String {
        let shown = fields.prefix(4).joined(separator: ", ")
        return fields.count > 4 ? shown + " + \(fields.count - 4)" : shown
    }

    private func runDetailReadBack(_ db: Sub4Database) {
        readingBackDetail = true
        let store = Array(DetailStore.shared.details.values)
        Task {
            let load = ActivityDetailRepository.all(db)
            detailLoad = load
            detailTrip = load.details.map {
                DetailRoundTrip.compare(store: store, database: $0)
            }
            readingBackDetail = false
        }
    }

    private func runReadBack(_ db: Sub4Database) {
        readingBack = true
        let store = ActivityStore.shared.activities
        Task {
            let load = ActivityRepository.all(db)
            roundTripLoad = load
            roundTrip = load.activities.map {
                ActivityRoundTrip.compare(store: store, database: $0)
            }
            readingBack = false
        }
    }

    private func runVerify(_ db: Sub4Database) {
        verifying = true
        Task {
            // The same gathered value the import uses — 301. The verifier
            // reads a subset of it on purpose; see the overload's comment.
            let report = SemanticVerifier.attempt(db, stores: AppStores.current())
            verification = report
            // A passing run moves the ledger to `verified`. A failing one
            // leaves it where it is — `SemanticVerifier.record` is what
            // refuses, not this screen.
            if let runID = lastRun?.id {
                _ = try? SemanticVerifier.record(report, for: runID, in: db)
                await reloadLedger(db)
            }
            verifying = false
        }
    }

    // MARK: The legacy survey — patch 262

    /// What is actually on this phone, classified.
    ///
    /// Every row here is `LegacyCondition.summary` — prose in the athlete's
    /// terms, not error domains. The identity faults are the exception that
    /// earns its detail: they name both disputed names, because the whole
    /// decision in §12.9d is that the app does not choose between them and a
    /// person does. A row saying "1 record filed under one name and claiming
    /// another" without saying WHICH would be the same defect one level up.
    @ViewBuilder
    private var legacySection: some View {
        Section {
            if surveying {
                HStack { ProgressView(); Text("Reading…").font(.caption) }
            } else {
                Button("Survey the app's files") { runSurvey() }
            }

            if let survey {
                ForEach(survey) { reading in
                    if reading.files.count > 1 {
                        LabeledContent(reading.store.rawValue,
                                       value: "\(reading.files.count) files · \(reading.faults.count) at fault")
                            .font(.caption)
                    } else {
                        LabeledContent(reading.store.rawValue,
                                       value: reading.condition.summary)
                            .font(.caption)
                            .foregroundStyle(reading.condition.isFault ? .red : Color.dim)
                    }

                    // The files at fault, named. A count with nothing behind
                    // it is a number somebody has to come and ask about.
                    ForEach(reading.faults) { file in
                        LabeledContent("  \(file.path)", value: file.condition.summary)
                            .font(.caption2).foregroundStyle(.red)
                    }
                    // And within those, both names of every disputed record.
                    ForEach(Array(reading.identityFaults.enumerated()), id: \.offset) { _, fault in
                        Text("    \(fault.line)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                }
            }
        } header: {
            Text("The app's own files")
        } footer: {
            Text("Reads every file the app has written and classifies it: "
                 + "readable, missing, interrupted part way, or holding a "
                 + "record that is filed under one name and claims another. "
                 + "Nothing is changed and nothing is held back — this patch "
                 + "only looks.")
                .font(.caption2)
        }
    }

    private func runSurvey() {
        surveying = true
        Task {
            // Off the main actor would be better and is not available: every
            // type this decodes is main-actor isolated — §12.9c. A `Task` at
            // least lets the spinner render before the read begins.
            let result = LegacyReader.readAll()
            survey = result
            surveying = false
        }
    }

    @ViewBuilder
    private func diagnosticsSection(_ db: Sub4Database) -> some View {
        Section {
            Button(copied ? "Copied" : "Copy diagnostics") {
                UIPasteboard.general.string = diagnosticsText
                copied = true
            }
            Button("Re-check") {
                copied = false
                Task { await recheck(db) }
            }
        } footer: {
            Text("The diagnostic is counts, sizes, migration names, SQLite's "
                 + "own verdicts and — once you have run the survey — how many "
                 + "of the app's files read cleanly. No session names, no "
                 + "places, no dates from your history, and no identifiers "
                 + "from the survey — it is safe to paste into a message.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func failureSection(_ error: Error) -> some View {
        Section {
            Text("The database could not be opened.")
                .font(.callout.weight(.semibold))
            Text(error.localizedDescription)
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            // NOT AN APOLOGY, AND NOT A SHRUG. Nothing in the app reads the
            // database yet, so this failing costs no data and breaks no screen.
            // Saying so is the difference between a diagnostic and an alarm.
            Text("Nothing else in the app uses the database yet, so this does "
                 + "not affect any of your training data. It does mean step "
                 + "3.3 cannot start until it is fixed.")
                .font(.caption2)
        }
    }

    // MARK: Work

    private var totalRows: Int { counts.reduce(0) { $0 + $1.rows } }

    /// Rows that came from an import rather than from a migration.
    ///
    /// The figure the footer keys off, because it is the one that answers the
    /// question this screen exists to answer before 3.3: has anything been
    /// moved in yet. `source` is seeded by the initial migration, so a total
    /// that included it would read as six rows on a database holding nothing.
    private var importedRows: Int {
        counts.filter { !Sub4Database.seededTables.contains($0.table) }
              .reduce(0) { $0 + $1.rows }
    }

    /// THE CONNECTION IS THE LAUNCH'S, NOT THIS SCREEN'S — patch 215.
    ///
    /// This screen used to call `Sub4Database.open()` itself, and until 3.3.1
    /// it was the only caller, so that was also the only connection. Now the
    /// launch gate opens the database before `ContentView` exists; opening a
    /// second `DatabaseQueue` against the same file from here would put two
    /// connections on one SQLite file for no reason, and the first symptom of
    /// that is a busy timeout on a screen nobody suspects.
    ///
    /// The fallback stays for the case the gate never ran — a preview, or a
    /// future caller that presents this outside the app's scene.
    private func load() async {
        guard opened == nil else { return }

        // Reading the manifests touches the file system, so it goes off the
        // main actor too — the same rule as the capture, for a much smaller
        // amount of work, because the rule does not get exceptions for size.
        snapshot = await Task.detached(priority: .utility) {
            LegacySnapshot.latest()
        }.value

        if let db = Sub4Launch.shared.database {
            opened = .success(db)
            await recheck(db)
            await reloadLedger(db)
            return
        }
        if let message = Sub4Launch.shared.failureMessage {
            opened = .failure(Sub4DatabaseError.launchFailed(message))
            return
        }
        do {
            let db = try Sub4Database.open()
            opened = .success(db)
            await recheck(db)
            await reloadLedger(db)
        } catch {
            opened = .failure(error)
        }
    }

    /// PATCH 302 — D6b, §12.46.
    ///
    /// NO "LAST WRITTEN" FROM DISK. This reads only what has happened since
    /// launch, and says so in as many words. A persisted timestamp would be a
    /// second answer to a question `migration_run` already answers, and two
    /// answers is how §12.29's problem starts.
    @ViewBuilder
    private func writeThroughSection(_ db: Sub4Database) -> some View {
        Section {
            if writeThrough.isRunning {
                HStack { ProgressView(); Text("Writing through…").font(.caption) }
            } else {
                Button("Write through now") {
                    Task {
                        await writeThrough.run(reason: "asked for on this screen")
                        // THE LEDGER IS THE DURABLE ANSWER — patch 303, and 302
                        // left it stale.
                        //
                        // `runImport` has always ended with this line; the
                        // write-through button did not, so the two rows on this
                        // screen showed the same event two minutes apart and it
                        // read as the button doing nothing. One screen, two
                        // answers, one of them old — §12.34's shape. §12.47.
                        await reloadLedger(db)
                    }
                }
            }

            LabeledContent("Last run", value: writeThrough.line)
                .font(.caption)
                .foregroundStyle(writeThrough.isHealthy ? Color.dim : .red)
            LabeledContent("Runs since launch", value: "\(writeThrough.runs)")
                .font(.caption).foregroundStyle(Color.dim)

            if let why = writeThrough.failureDetail {
                Text(why).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Write-through")
        } footer: {
            Text("Runs the import above on its own when the app goes to the "
                 + "background. It costs about a third of a second and copies "
                 + "everything, so a missed run is picked up by the next one "
                 + "rather than leaving a gap.\n\n"
                 + "AUTOMATIC RUNS DO NOT DELETE. Reconciliation — removing "
                 + "rows the app no longer has — happens only when you press "
                 + "Import above. So a note or a decision you delete stays in "
                 + "the database until then. See ADR-0003 §12.46.\n\n"
                 + "The two figures above are for THIS LAUNCH only. The "
                 + "durable record is the import ledger below: after a "
                 + "write-through it is that run.")
                .font(.caption2)
        }
    }

    /// What the last import did, and how it ended — patch 255.
    ///
    /// AFTER the import section, because it is the record of the button above
    /// it. The state is the row that matters: everything else on this screen
    /// says what the database CONTAINS, and this says whether anything has
    /// checked it.
    ///
    /// RESTORED HERE AT 303. Patch 302 inserted the write-through section
    /// immediately above this one and left this comment stranded on it, so a
    /// paragraph about the import ledger sat over a function that is not the
    /// import ledger — and this one had no comment at all. Small, and the same
    /// category as everything else in that patch: prose describing the wrong
    /// thing. §12.34.
    @ViewBuilder
    private var ledgerSection: some View {
        Section {
            if let r = lastRun {
                LabeledContent("State") {
                    Text(r.state.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(r.state == .failed ? Color.red : Color.secondary)
                }
                // LOCAL, WITH THE RAW STRING AS THE FALLBACK — patch 304.
                //
                // These were the ISO-8601 UTC values verbatim, which are
                // correct and are two hours from what the clock on the phone
                // says. A `Z` is self-describing and a reader still has to do
                // the arithmetic; a screen should not ask them to. §12.48.
                //
                // If `AppTime` cannot parse it the raw value is printed, ugly
                // and true, rather than a guess — §12.42.1.1.
                LabeledContent("Started",
                               value: AppTime.local(r.startedUTC) ?? r.startedUTC)
                    .font(.caption)
                if let f = r.finishedUTC {

                    LabeledContent("Finished", value: AppTime.local(f) ?? f).font(.caption)

                }
                LabeledContent("By", value: "patch \(r.appVersion)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Snapshot", value: r.snapshotID ?? "none taken")
                    .font(.caption)
                    .foregroundStyle(r.snapshotID == nil ? Color.red : Color.dim)
                if let n = r.note, !n.isEmpty {
                    Text(n).font(.caption2).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if staleRuns > 0 {
                    // Not repaired automatically — see `MigrationLedger.stale`.
                    // Rewriting these would destroy the only evidence the app
                    // was killed while writing.
                    LabeledContent("Interrupted runs", value: "\(staleRuns)")
                        .font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("No import has been recorded. Nothing in this database can "
                     + "be called verified until one has.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Import ledger")
        } footer: {
            Text("One row per import. A run reaches \"imported, not verified\" "
                 + "when the write commits; the verifier that can move it to "
                 + "\"verified\" is the next step, and until it exists nothing "
                 + "may switch its reads to this database.")
        }
    }

    private func reloadLedger(_ db: Sub4Database) async {
        let read: (run: MigrationRun?, stale: Int)? = await Task.detached(priority: .utility) {
            guard let latest = try? MigrationLedger.latest(db) else { return nil }
            let stale = (try? MigrationLedger.stale(db).count) ?? 0
            return (latest, stale)
        }.value
        lastRun = read?.run
        staleRuns = read?.stale ?? 0
    }

    private func recheck(_ db: Sub4Database) async {
        do {
            report = try db.integrityReport()
            counts = try db.tableCounts()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Built from figures that cannot describe anybody — see the header.
    private var diagnosticsText: String {
        var lines: [String] = [AppVersion.full]
        if let report {
            lines.append("Integrity: \(report.quickCheck)")
            lines.append("Orphaned rows: \(report.foreignKeyViolations)")
            lines.append("Foreign keys: \(report.foreignKeysEnabled ? "on" : "OFF")")
            lines.append("Migrations: \(report.appliedMigrations.joined(separator: ", "))")
            lines.append("Expected: \(Sub4Migrations.all.joined(separator: ", "))")
            if let bytes = report.bytesOnDisk {
                lines.append("Size: \(bytes) bytes")
            }
        }
        lines.append("Prepared: \(Sub4Launch.shared.database != nil ? "at launch" : "by this screen")")
        lines.append("Tables: \(counts.count), imported rows: \(importedRows), total: \(totalRows)")
        for row in counts where row.rows > 0 {
            lines.append("  \(row.table): \(row.rows)")
        }
        // Patch 248. The five numbers on screen cannot say WHICH files are
        // missing or how the directories decompose, and the manifest that can
        // is inside the app container where nothing may read it.
        if let m = snapshot {
            lines.append("")
            lines.append(contentsOf: m.redactedLines)
        }
        // Patch 255. `MigrationRun.line` is counts and timestamps of the import
        // itself — nothing from the athlete's history — so it is safe here.
        if let r = lastRun {
            lines.append("")
            lines.append("Last import: \(r.line)")
            if staleRuns > 0 { lines.append("Interrupted runs: \(staleRuns)") }
        }
        // The benchmark is the reason this screen gets pasted at all now — the
        // §9 decision is made from these lines. They are counts and durations
        // over synthetic fixtures, so they describe nobody.
        if let r = benchmark.result {
            lines.append("")
            lines.append(contentsOf: r.diagnosticLines)
        }
        // Patch 262. COUNTS AND CONDITION NAMES ONLY. The two disputed names in
        // an identity fault are the athlete's own identifiers, and §12.7
        // promises this paste carries none — so the screen gets the names and
        // this gets how many there were.
        if let survey {
            lines.append("")
            lines.append(contentsOf: LegacyReader.diagnosticLines(survey))
        }
        // Patch 263. Counts, table names and verdicts — the `detail` on each
        // check can carry an activity id, and that stays on the screen.
        if let v = verification {
            lines.append("")
            lines.append(contentsOf: v.diagnosticLines)
        }
        // Patch 266c. UNCONDITIONAL, unlike the two above it. Those are nil
        // until a button is pressed; the journal always has an answer, and
        // "none" is that answer said out loud. A section that simply vanished
        // when nothing was wrong would be indistinguishable from a check that
        // never ran — which is the same argument §12.9c makes for `absent`.
        //
        // Store names, stages and counts only. The underlying reason is left
        // out because a file-system error can carry a container path.
        lines.append("")
        lines.append(contentsOf: StoreWriteJournal.shared.diagnosticLines)
        // PATCH 273. UNCONDITIONAL, like the line above it and for 266c's
        // reason: "Unreadable stores: none" in a paste is evidence, and a
        // line that only appears when something is wrong cannot be
        // distinguished from a line nobody wired in.
        lines.append(contentsOf: StoreReadJournal.shared.diagnosticLines)
        return lines.joined(separator: "\n")
    }
}
