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
    /// Patch 311. The whole table, tallied by what started each run — the
    /// answer `migration_run: 45` could not give.
    @State private var ledgerCensus: LedgerCensus?

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

    /// PATCH 317 — the fourth read-back, and the only one with no button.
    ///
    /// The three above are behind a press because they cost 669 rows, 667
    /// details and roughly 1.5 million sample comparisons. This one is ONE
    /// ROW, thirteen months and five zones. Running it when the screen opens
    /// costs nothing measurable, and it dissolves the `@State` evaporation
    /// §12.57 had to work around for parity rather than working around it
    /// again: a check that runs itself every time the screen appears can never
    /// be pasted as "not run since this launch", because the paste and the run
    /// are the same visit.
    @State private var athleteLoad: AthleteLoad?
    @State private var athleteTrip: AthleteRoundTrip.Report?

    /// PATCH 322 — the fifth read-back, and the second with no button.
    ///
    /// Seven notes and four commute decisions. Like the athlete's, it costs one
    /// read and therefore runs on open rather than behind a press — §12.61.4's
    /// argument, and the same dissolution of the `@State` evaporation trap.
    @State private var authoredLoad: AuthoredLoad?
    @State private var authoredTrip: AuthoredRoundTrip.Report?
    @State private var planLoad: PlanLoad?
    @State private var planTrip: PlanRoundTrip.Report?
    @State private var planExtrasLoad: PlanExtrasLoad?
    @State private var planExtrasTrip: PlanExtrasRoundTrip.Report?
    @State private var weatherGearLoad: WeatherGearLoad?
    @State private var weatherGearTrip: WeatherGearRoundTrip.Report?
    // PATCH 327 — D6c slice 7. The ninth read-back, and the only one whose
    // subject may legitimately not exist yet: the first real review is due
    // 24 August 2026.
    @State private var reviewLoad: ReviewTrailLoad?
    @State private var reviewTrip: ReviewRoundTrip.Report?
    @State private var verifying = false
    @State private var verification: VerificationReport?

    /// D6c — patch 312, moved off `@State` at 313.
    ///
    /// OBSERVED RATHER THAN OWNED, like `writeThrough` above. The result used
    /// to live here, so pressing Done discarded it — and the diagnostics paste,
    /// which is the thing somebody reads later, said "Not compared since this
    /// launch" a minute after the comparison passed. True of the `@State` and
    /// false about the world. §12.57.
    @State private var parity = ShadowParity.shared

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
                    // PATCH 317. The fourth, and the one that closes D6a's
                    // gap: `athlete_profile`, `resting_month` and `hr_zone`
                    // were the only imported tables nothing ever read back.
                    // LAST of the four because it is the smallest and because
                    // the section under it now depends on it — shadow parity
                    // holds constants, zones and FTP from the app, and this is
                    // what turns that from an assumption into a check.
                    athleteReadBackSection
                    // PATCH 322. The fifth, and the one that closes the loop
                    // 321 opened: `note.rpe` was slice 3's last unverified
                    // input, and `correction` holds one of slice 5's three
                    // held ones.
                    //
                    // ONE SECTION FOR TWO TABLES, deliberately. Groundwork §7
                    // warned that a screen nobody scrolls to the bottom of is a
                    // screen whose bottom rows are not read, and §12.40.1
                    // measured that once already. Eleven records do not need
                    // two headings.
                    authoredReadBackSection
                    // PATCH 323. Sixth read-back and the largest by a wide
                    // margin — 260 sessions where the athlete's profile was 27
                    // fields. It sits last of the read-backs because it is the
                    // one whose numbers need reading twice: the compared count
                    // is a third of the table's, and the row that says why is
                    // directly under it.
                    planReadBackSection
                    // PATCH 324. Last of the read-backs and the one that closes
                    // slice 6 — 583 readings and eleven shoes.
                    weatherGearReadBackSection
                    // PATCH 327. Ninth and last of the read-backs, and the one
                    // that finishes D6c's record side. It sits at the end
                    // because it is the only one that can legitimately compare
                    // nothing: the first real review is due 24 August 2026, and
                    // until then a green "no review stored yet" is the correct
                    // answer rather than a missing one.
                    reviewReadBackSection
                    // AFTER the three read-backs, because it asks the question
                    // they cannot: they compare RECORDS, this compares the list
                    // the app would DERIVE from them. The screen reads in the
                    // order the two questions relate — are the rows the same,
                    // and then would the screens be the same.
                    paritySection(db)
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
            // THE LEDGER FOLLOWS EVERY RUN, not just the button — patch 306.
            //
            // 303 reloaded it after a press. An AUTOMATIC run while this screen
            // is open left it showing whatever was current when the screen
            // opened, which is what made the trigger look dead during testing:
            // `Last run` moved and the row under it did not.
            //
            // Keyed on `runs`, which changes exactly once per completed run
            // whatever fired it.
            .onChange(of: writeThrough.runs) {
                if case .success(let db) = opened {
                    // AND THE ATHLETE, for 306's reason one row down: a write
                    // that happened while this screen was open would otherwise
                    // leave the read-back describing the database as it was
                    // before it, which is the exact shape of the bug that made
                    // the run trigger look dead.
                    Task {
                        await reloadLedger(db)
                        await reloadAthlete(db)
                        await reloadAuthored(db)
                        await reloadPlan(db)
                        await reloadWeatherGear(db)
                        await reloadReview(db)
                    }
                }
            }

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
                LabeledContent("Gear", value: "\(r.gearInserted) new, "
                               + "\(r.gearAlreadyPresent) known, "
                               + "\(r.gearRefreshed) refreshed")
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
                    // Patch 311. The button on this screen is a person, and so
                    // is the one below it, and so is Run the task now in
                    // Settings. All three are `manual`, because the question
                    // the column answers is whether somebody caused the run —
                    // which button it was lives in the failure journal's
                    // reason, where it is a sentence rather than a value.
                    // The link between contract items 3 and 11: a run records
                    // which snapshot of its inputs was taken first, or records
                    // that none was.
                    snapshotID: snapshot?.id,
                    trigger: .manual)
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

    /// PATCH 317 — the fourth read-back, D6c slice 6a, ADR-0003 §12.61.
    ///
    /// THE ONE TABLE GROUP D6a NEVER READ BACK. 289 through 294 built readers
    /// for activities, details and recordings and compared every field of
    /// each. `athlete_profile`, `resting_month` and `hr_zone` got a row count
    /// from the semantic verifier and nothing else — so the constants that
    /// scale EVERY training load this app has ever computed were the least
    /// checked thing in the database.
    ///
    /// NO BUTTON, unlike the three above it. See `athleteLoad`.
    ///
    /// EVERY ROW UNCONDITIONAL — §12.54.2. A row that vanishes at zero cannot
    /// be told from a row nobody wired in, and this screen has learned that
    /// twice already.
    @ViewBuilder
    private var athleteReadBackSection: some View {
        Section {
            if let load = athleteLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            } else {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            }

            if let r = athleteTrip {
                // THE DENOMINATORS FIRST — groundwork §2.1 case 2. "No
                // differences" and "nothing was examined" read identically
                // without them, and `.missing` reaching here produces the
                // second while looking like the first.
                LabeledContent("Compared", value: "\(r.totalCompared)")
                    .font(.caption)
                    .foregroundStyle(r.lookedAtSomething ? Color.dim : .red)
                LabeledContent("  profile fields", value: "\(r.fieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("  resting months", value: "\(r.monthsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("  zones", value: "\(r.zonesCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)

                LabeledContent("Fields that differ", value: "\(r.differences.count)")
                    .font(.caption)
                    .foregroundStyle(r.differences.isEmpty ? Color.dim : .red)
                LabeledContent("Months that differ", value: "\(r.monthsDiffering.count)")
                    .font(.caption)
                    .foregroundStyle(r.monthsDiffering.isEmpty ? Color.dim : .red)
                LabeledContent("Zones that differ", value: "\(r.zonesDiffering.count)")
                    .font(.caption)
                    .foregroundStyle(r.zonesDiffering.isEmpty ? Color.dim : .red)

                // THE TWO FIGURES THAT SCALE EVERYTHING, printed as both sides
                // rather than as a verdict. A reader can hold these against the
                // Settings screen without pressing anything else.
                LabeledContent("HR max", value: r.hrMaxLine)
                    .font(.caption)
                    .foregroundStyle(r.appHRMax == r.databaseHRMax ? Color.dim : .red)
                LabeledContent("FTP", value: r.ftpLine)
                    .font(.caption)
                    .foregroundStyle(r.appFTP == r.databaseFTP ? Color.dim : .red)

                // NAMED, NOT COUNTED. "3 differences" sends somebody through a
                // profile; "3, all in restByMonth" is a one-line answer.
                ForEach(r.differences, id: \.self) { field in
                    Text("    \(field)").font(.caption2).foregroundStyle(.red)
                }
                ForEach(r.monthsDiffering.prefix(6), id: \.self) { month in
                    Text("    restByMonth[\(month)]")
                        .font(.caption2).foregroundStyle(.red)
                }
                if r.monthsDiffering.count > 6 {
                    Text("    + \(r.monthsDiffering.count - 6) more months")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                ForEach(r.zonesDiffering, id: \.self) { ordinal in
                    Text("    zone \(ordinal)").font(.caption2).foregroundStyle(.red)
                }

                // DIM, AND ALWAYS PRESENT. An approved difference that only
                // showed when it fired would be a suppression list nobody ever
                // reads. Each entry carries its reason in the source and its
                // patch number; the screen carries the field name so the list
                // cannot grow silently.
                LabeledContent("Approved differences",
                               value: AthleteRoundTrip.approved.isEmpty
                                   ? "none"
                                   : AthleteRoundTrip.approved.map(\.field)
                                       .joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        } header: {
            Text("Read-back · athlete")
        } footer: {
            Text("Reads the profile, the resting series and the zones back out "
                 + "and compares them, field by field, to the ones the app is "
                 + "running on. These are the least-checked rows in the "
                 + "database and the denominator of every training-load figure "
                 + "in it: `sexCoefficient` is an exponent, and a single wrong "
                 + "figure here rescales thirteen months of history with "
                 + "nothing visibly broken.\n\n"
                 + "It runs when this screen opens and after every write, "
                 + "because it costs one row rather than a press. `version` is "
                 + "a local counter with no column and is listed as an approved "
                 + "difference rather than compared — ADR-0003 §12.61.")
                .font(.caption2)
        }
    }

    /// PATCH 322 — the fifth read-back, D6c slice 5b, ADR-0003 §12.65.
    ///
    /// TWO TABLES, ONE SECTION. `user_note` and `correction` between them hold
    /// eleven records, and both are authored by the athlete rather than fetched
    /// — which is what makes them one heading rather than two.
    ///
    /// WHAT IT IS FOR, BEYOND ITSELF. `note.rpe` was the last unverified input
    /// to slice 3's sRPE, and `correction` holds the commute decisions slice 5
    /// takes from the app. Both of those lines on the Shadow parity section
    /// below now say "verified" instead of only "held".
    ///
    /// NO BUTTON, like the athlete's, and every row unconditional — §12.54.2.
    @ViewBuilder
    private var authoredReadBackSection: some View {
        Section {
            if let load = authoredLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            } else {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            }

            if let r = authoredTrip {
                LabeledContent("Compared", value: "\(r.totalCompared)")
                    .font(.caption)
                    .foregroundStyle(r.lookedAtSomething ? Color.dim : .red)

                Text("Notes")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.notesInApp) vs \(r.notesInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.notesCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.noteFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Only in the app", value: "\(r.notesOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(r.notesOnlyInApp.isEmpty ? Color.dim : .red)
                LabeledContent("Only in the database",
                               value: "\(r.notesOnlyInDatabase.count)")
                    .font(.caption)
                    .foregroundStyle(r.notesOnlyInDatabase.isEmpty ? Color.dim : .red)
                LabeledContent("Fields that differ", value: "\(r.noteDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.noteDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.noteDifferences.prefix(6), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }
                // THE ROW SLICE 3 DEPENDS ON. An RPE is what becomes an sRPE; a
                // note without one contributes nothing to the load, so these
                // two matching is what earns the "verified" line below.
                LabeledContent("Carrying an RPE", value: r.rpeLine)
                    .font(.caption)
                    .foregroundStyle(r.appNotesWithRPE == r.databaseNotesWithRPE
                                     ? Color.dim : .red)

                Text("Commute decisions")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.commutesInApp) vs \(r.commutesInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.commutesCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.commuteFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Only in the app", value: "\(r.commutesOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(r.commutesOnlyInApp.isEmpty ? Color.dim : .red)
                LabeledContent("Only in the database",
                               value: "\(r.commutesOnlyInDatabase.count)")
                    .font(.caption)
                    .foregroundStyle(r.commutesOnlyInDatabase.isEmpty ? Color.dim : .red)
                LabeledContent("Fields that differ",
                               value: "\(r.commuteDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.commuteDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.commuteDifferences.prefix(4), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("Rows the reader could not read",
                               value: "\(r.rowsSkipped)")
                    .font(.caption)
                    .foregroundStyle(r.rowsSkipped == 0 ? Color.dim : .red)
                LabeledContent("Approved differences",
                               value: AuthoredRoundTrip.approved.isEmpty
                                   ? "none"
                                   : AuthoredRoundTrip.approved.map(\.field)
                                       .joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        } header: {
            Text("Read-back · authored")
        } footer: {
            Text("The two tables the athlete writes rather than the source: "
                 + "session notes and commute decisions. Small, and load-"
                 + "bearing twice over — an RPE becomes the sRPE that scales a "
                 + "session's training load, and a commute decision decides "
                 + "whether a ride may satisfy a planned session at all.\n\n"
                 + "Timestamps are compared as the strings the importer writes, "
                 + "through its own formatter, rather than parsed back into "
                 + "dates and forgiven by a tolerance.\n\n"
                 + "A note's text is compared and never printed here. Two "
                 + "columns are left NULL by the importer on purpose and are "
                 + "listed as approved differences — ADR-0003 §12.65.")
                .font(.caption2)
        }
    }

    /// PATCH 323 — the sixth read-back, D6c slice 6b, ADR-0003 §12.66.
    ///
    /// THE SECTION WHOSE NUMBERS NEED A SECOND LINE TO BE HONEST. `plan_session`
    /// holds three times what the app holds, because three versions of the same
    /// plan are stored and one is active. "260 compared" above a table of 780
    /// reads as data loss to anyone who has not been told why, so the row
    /// underneath states the ratio and the version count rather than leaving it
    /// to be worked out. §12.15 applied to a denominator.
    ///
    /// WHAT IT IS FOR, BEYOND ITSELF. Slice 3 said "sRPE given the plan" and
    /// slice 5 said it held "the plan" — both because nothing had read
    /// `plan_session` back. Both lines below now shorten.
    ///
    /// NO BUTTON, like the athlete's and the authored, and every row
    /// unconditional — §12.54.2.
    @ViewBuilder
    private var planReadBackSection: some View {
        Section {
            if let load = planLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            } else {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            }

            if let r = planTrip {
                LabeledContent("Compared", value: "\(r.totalCompared)")
                    .font(.caption)
                    .foregroundStyle(r.lookedAtSomething ? Color.dim : .red)
                // THE ROW THAT STOPS 260-OF-780 READING AS LOSS.
                LabeledContent("Of the table", value: r.versionLine)
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Active version", value: r.activeVersion)
                    .font(.caption2).foregroundStyle(Color.dim)

                Text("The plan's header")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("Fields compared", value: "\(r.metaFieldsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Fields that differ", value: "\(r.metaDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.metaDifferences.isEmpty ? Color.dim : .red)

                Text("Weeks")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.weeksInApp) vs \(r.weeksInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.weeksCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.weekFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("  stats compared", value: "\(r.weekStatsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Only in the app", value: "\(r.weeksOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(r.weeksOnlyInApp.isEmpty ? Color.dim : .red)
                LabeledContent("Only in the database",
                               value: "\(r.weeksOnlyInDatabase.count)")
                    .font(.caption)
                    .foregroundStyle(r.weeksOnlyInDatabase.isEmpty ? Color.dim : .red)
                LabeledContent("Fields that differ", value: "\(r.weekDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.weekDifferences.isEmpty ? Color.dim : .red)
                LabeledContent("Stats that differ",
                               value: "\(r.weekStatDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.weekStatDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.weekDifferences.prefix(4), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }

                Text("Sessions")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.sessionsInApp) vs \(r.sessionsInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.sessionsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.sessionFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Only in the app", value: "\(r.sessionsOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(r.sessionsOnlyInApp.isEmpty ? Color.dim : .red)
                LabeledContent("Only in the database",
                               value: "\(r.sessionsOnlyInDatabase.count)")
                    .font(.caption)
                    .foregroundStyle(r.sessionsOnlyInDatabase.isEmpty ? Color.dim : .red)
                LabeledContent("Fields that differ",
                               value: "\(r.sessionDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.sessionDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.sessionDifferences.prefix(6), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }
                // Context, not assertions. A session without a date is a
                // prologue week; a session without a fuelling line is strength,
                // rest, travel or a walk. Both counts matching is the claim.
                LabeledContent("Carrying a date", value: r.datedLine)
                    .font(.caption2)
                    .foregroundStyle(r.appSessionsWithADate
                                     == r.databaseSessionsWithADate
                                     ? Color.dim : .red)
                LabeledContent("Carrying a fuelling line", value: r.fuelLine)
                    .font(.caption2)
                    .foregroundStyle(r.appSessionsWithFuel
                                     == r.databaseSessionsWithFuel
                                     ? Color.dim : .red)

                Text("Breakdowns")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.breakdownsInApp) vs \(r.breakdownsInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.breakdownsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.breakdownFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Blocks compared", value: "\(r.blocksCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.blockFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Blocks that differ", value: "\(r.blockDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.blockDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.blockDifferences.prefix(4), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("Rows the reader could not read",
                               value: "\(r.rowsSkipped)")
                    .font(.caption)
                    .foregroundStyle(r.rowsSkipped == 0 ? Color.dim : .red)
                // PATCH 326 — slice 6c, under the same heading as slice 6b.
                // A ninth heading for 150 rows nobody derives anything from is
                // the wrong trade on a screen this long — groundwork §7.
                Text("The trimmings")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let x = planExtrasTrip {
                    LabeledContent("Compared", value: "\(x.totalCompared)")
                        .font(.caption)
                        .foregroundStyle(x.lookedAtSomething ? Color.dim : .red)
                    LabeledContent("A fuelling plan on each side", value: x.fuelLine)
                        .font(.caption2)
                        .foregroundStyle(x.appHasFuel == x.databaseHasFuel
                                         ? Color.dim : .red)
                    LabeledContent("A race-day section", value: x.raceDayLine)
                        .font(.caption2)
                        .foregroundStyle(x.appHasRaceDay == x.databaseHasRaceDay
                                         ? Color.dim : .red)
                    LabeledContent("A warm-up on each side", value: x.warmupLine)
                        .font(.caption2)
                        .foregroundStyle(x.appHasWarmup == x.databaseHasWarmup
                                         ? Color.dim : .red)
                    LabeledContent("  fuel fields compared",
                                   value: "\(x.fuelFieldsCompared)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("  products · targets · ladder",
                                   value: "\(x.productsCompared) · "
                                        + "\(x.targetsCompared) · "
                                        + "\(x.ladderStepsCompared)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("  race-day lines · steps",
                                   value: "\(x.raceBeforeCompared) · "
                                        + "\(x.raceStepsCompared)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("  warm-up fields · steps",
                                   value: "\(x.warmupFieldsCompared) · "
                                        + "\(x.warmupStepsCompared)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("  movements · conditions",
                                   value: "\(x.movementsCompared) · "
                                        + "\(x.conditionsCompared)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("Exercises",
                                   value: "\(x.exercisesInApp) vs \(x.exercisesInDatabase)")
                        .font(.caption).foregroundStyle(Color.dim)
                    LabeledContent("  fields compared",
                                   value: "\(x.exerciseFieldsCompared)")
                        .font(.caption2).foregroundStyle(Color.dim)
                    LabeledContent("Fuel fields that differ",
                                   value: "\(x.fuelDifferences.count)")
                        .font(.caption)
                        .foregroundStyle(x.fuelDifferences.isEmpty ? Color.dim : .red)
                    LabeledContent("Warm-up fields that differ",
                                   value: "\(x.warmupDifferences.count)")
                        .font(.caption)
                        .foregroundStyle(x.warmupDifferences.isEmpty ? Color.dim : .red)
                    LabeledContent("List entries that differ",
                                   value: "\(x.listDifferences.count)")
                        .font(.caption)
                        .foregroundStyle(x.listDifferences.isEmpty ? Color.dim : .red)
                    LabeledContent("Exercise fields that differ",
                                   value: "\(x.exerciseDifferences.count)")
                        .font(.caption)
                        .foregroundStyle(x.exerciseDifferences.isEmpty ? Color.dim : .red)
                    ForEach((x.fuelDifferences + x.warmupDifferences
                             + x.listDifferences + x.exerciseDifferences)
                                .prefix(6), id: \.self) { d in
                        Text("    \(d)").font(.caption2).foregroundStyle(.red)
                    }
                    LabeledContent("Rows the reader could not read",
                                   value: "\(x.rowsSkipped)")
                        .font(.caption)
                        .foregroundStyle(x.rowsSkipped == 0 ? Color.dim : .red)
                }

                LabeledContent("Approved differences",
                               value: PlanRoundTrip.approvedNote)
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        } header: {
            Text("Read-back · the plan")
        } footer: {
            Text("The bundled plan, decomposed across six tables on import and "
                 + "reassembled here. Unlike every other read-back this one "
                 + "cannot be testing for drift — plan.json is read-only at "
                 + "runtime and is replaced wholesale on app update. What it "
                 + "tests is whether the decomposition inverts.\n\n"
                 + "The compared count is about a third of the rows in the "
                 + "tables, and that is correct: three versions of the same "
                 + "plan are stored and one is active. Every plan table "
                 + "divides by three exactly.\n\n"
                 + "Every field of every week, session, breakdown and block "
                 + "has a column and every column is written, so there are no "
                 + "approved differences — ADR-0003 §12.66.\n\n"
                 + "The trimmings — the fuelling plan, the race-day warm-up "
                 + "and the exercise library — are ten more tables that feed "
                 + "no derivation. They are a separate comparison under the "
                 + "same heading, so a red row says which half broke: this one "
                 + "means a screen draws wrong, the one above means a training "
                 + "figure is wrong. §12.70.")
                .font(.caption2)
        }
    }

    /// Same shape as `reloadAuthored`: the read off the main actor, the
    /// comparison on it, because `PlanStore` is a main-actor singleton.
    private func reloadPlan(_ db: Sub4Database) async {
        let load = await Task.detached(priority: .utility) {
            PlanRepository.load(db)
        }.value
        planLoad = load
        let store = PlanStore.shared
        planTrip = PlanRoundTrip.compare(storeMeta: store.plan.meta,
                                         storeWeeks: store.plan.weeks,
                                         storeSessions: store.plan.sessions,
                                         database: load)

        // PATCH 326. A second read rather than one that returns everything:
        // the trimmings are a separate claim and a separate report, so a red
        // row says which half broke. Same actor shape as above.
        let extras = await Task.detached(priority: .utility) {
            PlanExtrasRepository.load(db)
        }.value
        planExtrasLoad = extras
        planExtrasTrip = PlanExtrasRoundTrip.compare(
            storeFuel: store.plan.fuel,
            storeWarmup: store.plan.warmup,
            storeExercises: store.plan.exercises,
            database: extras)
    }

    /// PATCH 324 — the seventh read-back, D6c slice 6, ADR-0003 §12.67.
    ///
    /// TWO TABLES, ONE SECTION, for §12.65.7's reason: both are caches of
    /// fetched source data making the same shape of claim, and this screen now
    /// carries seven read-backs. Weather is the largest table that had no
    /// reader; gear is eleven rows and the more interesting half, because the
    /// approved list gains its only two STRUCTURAL entries — one field with no
    /// column, one column with no field.
    ///
    /// THE ROW THAT STOPS A CORRECT DATABASE LOOKING BROKEN. A reading whose
    /// activity the roster dropped cannot be stored — `weather.activityID` is a
    /// foreign key. Those are counted on their own line rather than reported as
    /// missing, and the line is unconditional so a device with none still says
    /// zero.
    ///
    /// NO BUTTON, and every row unconditional — §12.54.2.
    @ViewBuilder
    private var weatherGearReadBackSection: some View {
        Section {
            if let load = weatherGearLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            } else {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            }

            if let r = weatherGearTrip {
                LabeledContent("Compared", value: "\(r.totalCompared)")
                    .font(.caption)
                    .foregroundStyle(r.lookedAtSomething ? Color.dim : .red)

                Text("Weather")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.readingsInApp) vs \(r.readingsInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.readingsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.readingFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Only in the app", value: "\(r.readingsOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(r.readingsOnlyInApp.isEmpty ? Color.dim : .red)
                // NOT RED AT ANY VALUE. These are readings the database is
                // right to refuse, and colouring them would train the eye to
                // ignore the row above.
                LabeledContent("  for an activity the app does not hold",
                               value: "\(r.readingsForUnknownActivities)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Only in the database",
                               value: "\(r.readingsOnlyInDatabase.count)")
                    .font(.caption)
                    .foregroundStyle(r.readingsOnlyInDatabase.isEmpty ? Color.dim : .red)
                LabeledContent("Fields that differ",
                               value: "\(r.readingDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.readingDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.readingDifferences.prefix(6), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }
                // Context. The normalisation made visible rather than hidden by
                // the thing that makes it harmless — see §12.67.3.
                LabeledContent("With no stored source",
                               value: "\(r.readingsWithNoStoredSource)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("From Apple Weather", value: r.appleLine)
                    .font(.caption2)
                    .foregroundStyle(r.appReadingsFromAppleWeather
                                     == r.databaseReadingsFromAppleWeather
                                     ? Color.dim : .red)

                Text("Gear")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.gearInApp) vs \(r.gearInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.gearCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.gearFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Only in the app", value: "\(r.gearOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(r.gearOnlyInApp.isEmpty ? Color.dim : .red)
                // NOT RED AT ANY VALUE, and 325 is why. These are shoes the
                // source has stopped listing; the database keeping them is the
                // reason `gear.sourceID` is nullable at all.
                LabeledContent("Kept after the source dropped it",
                               value: "\(r.gearKeptAfterTheSourceDropped.count)")
                    .font(.caption).foregroundStyle(Color.dim)
                ForEach(r.gearKeptAfterTheSourceDropped.prefix(6), id: \.self) { g in
                    Text("    \(g)").font(.caption2).foregroundStyle(Color.dim)
                }
                LabeledContent("Fields that differ", value: "\(r.gearDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.gearDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.gearDifferences.prefix(4), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }
                // EXPECTED ZERO, PRINTED ANYWAY. The column exists and nothing
                // writes it; the day that changes, this row is where it shows.
                LabeledContent("Carrying a retirement date",
                               value: "\(r.gearCarryingRetirement)")
                    .font(.caption2).foregroundStyle(Color.dim)

                LabeledContent("Rows the reader could not read",
                               value: "\(r.rowsSkipped)")
                    .font(.caption)
                    .foregroundStyle(r.rowsSkipped == 0 ? Color.dim : .red)
                LabeledContent("Approved differences",
                               value: WeatherGearRoundTrip.approved.map(\.field)
                                   .joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        } header: {
            Text("Read-back · weather and gear")
        } footer: {
            Text("The two caches of fetched source data. Weather is the largest "
                 + "table in the database and is drawn on every activity "
                 + "screen; gear is eleven rows that outlive the source they "
                 + "came from.\n\n"
                 + "Readings are keyed by Strava's activity id on both sides — "
                 + "the column holds the canonical id and the query reverses "
                 + "the alias, which is what the importer did on the way in. "
                 + "The doubles are compared exactly: a REAL column round trip "
                 + "is lossless, so a tolerance would forgive a changed value.\n\n"
                 + "A reading whose activity the app no longer holds cannot be "
                 + "stored at all — the column is a foreign key — so those are "
                 + "counted separately rather than reported as missing.\n\n"
                 + "Gear the source no longer lists is kept, not deleted — "
                 + "that is why gear.sourceID is nullable — so it is counted "
                 + "rather than reported as a difference. The cost is that a "
                 + "gear row that should never have been written looks the "
                 + "same, and nothing records when a row was last seen.\n\n"
                 + "Two approved differences, both structural: Shoe.primary has "
                 + "no column, and gear.retiredUTC is a column nothing writes — "
                 + "ADR-0003 §12.67 and §12.68.")
                .font(.caption2)
        }
    }

    /// Same shape as `reloadPlan`: the read off the main actor, the comparison
    /// on it, because all three stores it reaches are main-actor singletons.
    ///
    /// The activity roster goes in as a `Set` so the comparison can tell a
    /// reading the database refused from a reading it lost.
    private func reloadWeatherGear(_ db: Sub4Database) async {
        let load = await Task.detached(priority: .utility) {
            WeatherGearRepository.load(db)
        }.value
        weatherGearLoad = load
        weatherGearTrip = WeatherGearRoundTrip.compare(
            storeWeather: Array(WeatherStore.shared.byActivity.values),
            // `allGear`, NOT `shoes` — patch 325a, and the bug it fixes is
            // instructive. `AthleteStore` holds `shoes`, `bikes` and `retired`
            // separately and exposes `allGear` as the sum. 324 passed `shoes`,
            // so the comparison saw six items against the database's eleven and
            // reported five as "kept after the source dropped it". Four of those
            // ids begin with `b`: they are bikes the app holds, in a property
            // nobody handed to the comparison. §12.68.6.
            //
            // The importer has always been given all eleven — `11 known` on the
            // import panel is the number that says so, and it was on screen the
            // whole time.
            storeGear: AthleteStore.shared.allGear,
            knownActivityIDs: Set(ActivityStore.shared.activities.map(\.id)),
            database: load)
    }

    /// PATCH 327 — the ninth read-back, D6c slice 7, ADR-0003 §12.71.
    ///
    /// SIX TABLES, ONE SECTION. `review`, `review_evidence`,
    /// `review_evidence_source`, `proposal`, `proposal_change` and
    /// `proposal_watch` are one tree with one root, and a person reading this
    /// screen has one question about them: did the review that ran survive the
    /// round trip whole.
    ///
    /// THE ONLY SECTION ON THIS SCREEN THAT IS GREEN WHILE COMPARING NOTHING.
    /// `ReviewDue.state()` needs four finished plan weeks; the block began
    /// Monday 27 July and the first review is due Monday 24 August 2026. Until
    /// that day the honest answer is "nothing has been written yet", and a row
    /// that said "0 compared" in red for three weeks would teach its reader to
    /// scroll past it — which is exactly what §12.40.1 measured and what
    /// §12.15 warns about from the other direction. So the empty state is
    /// stated, with the date, and is not styled as a fault.
    ///
    /// THE THREE ROWS THAT ARE NOT COUNTS. Evidence lineage, decisions, and
    /// withheld sections are columns nothing writes. They are printed as
    /// statements about the writer rather than as numbers, because §12.54.2's
    /// whole point is that a zero cannot say which kind of zero it is.
    ///
    /// NO BUTTON, and every row unconditional.
    /// The reviews footer, as a constant. See the footer's own comment.
    private static let reviewFooter =
        "The monthly review trail — six tables holding what the model was "
      + "told, what it said, and what it would change. The one thing in this "
      + "database that cannot be re-fetched: a review costs a call to a model "
      + "over data that has since moved.\n\n"
      + "The first real review is due 24 August 2026, so until then an empty "
      + "read is the correct answer and is not marked as a fault. A review the "
      + "database holds and the app has lost is not marked as one either — "
      + "that is the case this whole table group exists for.\n\n"
      + "The evidence pack and the model's prose are compared in full and "
      + "never printed: a difference is named by its field and measured in "
      + "characters. Nothing in this section or in the diagnostics paste "
      + "carries review text.\n\n"
      + "proposal_change.planSessionUID is deliberately not a foreign key — a "
      + "proposal has to survive a plan revision that renumbers the week it "
      + "names — so nothing but this resolves it against the sessions the "
      + "database holds.\n\n"
      + "Three approved differences, all structural, and one finding that is "
      + "not approved: review_evidence_source is written by nothing, so "
      + "ADR-0002's lineage purge has no rows to query. ADR-0003 §12.71."

    @ViewBuilder
    private var reviewReadBackSection: some View {
        Section {
            if let load = reviewLoad {
                LabeledContent("The read", value: load.line)
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy ? Color.dim : .red)
            } else {
                HStack { ProgressView(); Text("Reading back…").font(.caption) }
            }

            if let r = reviewTrip {
                LabeledContent("Compared", value: r.summary)
                    .font(.caption)
                    .foregroundStyle(r.lookedAtSomething ? Color.dim : .red)

                Text("Reviews")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.reviewsInApp) vs \(r.reviewsInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.reviewsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.reviewFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Only in the app", value: "\(r.reviewsOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(r.reviewsOnlyInApp.isEmpty ? Color.dim : .red)
                // NOT RED AT ANY VALUE — §12.8.1. A review the database holds
                // and the app has lost is the database doing the one job that
                // matters most here; colouring it would style the rescue as
                // the fault.
                LabeledContent("Only in the database",
                               value: "\(r.reviewsOnlyInDatabase.count)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("App records sharing a run time",
                               value: "\(r.duplicateRunTimes.count)")
                    .font(.caption)
                    .foregroundStyle(r.duplicateRunTimes.isEmpty ? Color.dim : .red)
                LabeledContent("Fields that differ",
                               value: "\(r.reviewDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.reviewDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.reviewDifferences.prefix(4), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }

                Text("Evidence")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.evidenceInApp) vs \(r.evidenceInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.evidenceCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.evidenceFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Section keys seen",
                               value: r.sectionKeysSeen.isEmpty
                                      ? "none" : r.sectionKeysSeen.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Color.dim)
                // EXPECTED ZERO, PRINTED ANYWAY. The importer writes wasSent = 1
                // unconditionally, so the schema's withheld-section case has
                // never had a row. The day a review learns to hold a section
                // back, this is where it shows.
                LabeledContent("Built and withheld", value: "\(r.evidenceWithheld)")
                    .font(.caption2).foregroundStyle(Color.dim)
                // NOT A COUNT — A STATEMENT. See §12.71.3: nothing in the app
                // writes review_evidence_source, so ADR-0002's lineage purge
                // has nothing to query. Worded so the zero cannot be read as
                // "checked, and clean".
                LabeledContent("Lineage rows",
                               value: r.evidenceSourceRows == 0
                                      ? "0 — nothing writes this table"
                                      : "\(r.evidenceSourceRows)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Fields that differ",
                               value: "\(r.evidenceDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.evidenceDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.evidenceDifferences.prefix(4), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }

                Text("Proposals")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("In each side",
                               value: "\(r.proposalsInApp) vs \(r.proposalsInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.proposalsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.proposalFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                // The type documents itself as 1–5 and the column's CHECK
                // permits 0–100. Printed so the day those two disagree is a
                // thing somebody can see — §12.71.4.
                LabeledContent("Confidence range seen", value: r.confidenceRange)
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Carrying a decision",
                               value: r.proposalsCarryingADecision == 0
                                      ? "0 — no screen offers the choice"
                                      : "\(r.proposalsCarryingADecision)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Fields that differ",
                               value: "\(r.proposalDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.proposalDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.proposalDifferences.prefix(4), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }

                Text("Changes and watch items")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LabeledContent("Changes in each side",
                               value: "\(r.changesInApp) vs \(r.changesInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.changesCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  fields compared", value: "\(r.changeFieldsCompared)")
                    .font(.caption2).foregroundStyle(Color.dim)
                // THE ONE NUMBER NOBODY ELSE COMPUTES. planSessionUID is not a
                // foreign key by design, so nothing but this resolves it, and
                // `rejections(plan:)` already has a name for what a failure
                // means: "no session with that id — invented".
                LabeledContent("Naming a known session",
                               value: "\(r.changesNamingAKnownSession) of \(r.changesResolvable)")
                    .font(.caption)
                    .foregroundStyle(r.changesNamingAKnownSession == r.changesResolvable
                                     ? Color.dim : .red)
                LabeledContent("  plan session uids in the database",
                               value: "\(r.planSessionUIDsKnown)")
                    .font(.caption2).foregroundStyle(Color.dim)
                // NOT RED — patch 327b. A database with no plan in it cannot
                // answer whether a uid is real, and reporting that as a failed
                // resolve would accuse the model of inventing sessions on a
                // device that has simply not imported the plan yet.
                LabeledContent("  could not be checked",
                               value: "\(r.changesUnresolvable)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Fields that differ",
                               value: "\(r.changeDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.changeDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.changeDifferences.prefix(6), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }
                LabeledContent("Watch items in each side",
                               value: "\(r.watchInApp) vs \(r.watchInDatabase)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.watchCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("That differ", value: "\(r.watchDifferences.count)")
                    .font(.caption)
                    .foregroundStyle(r.watchDifferences.isEmpty ? Color.dim : .red)
                ForEach(r.watchDifferences.prefix(4), id: \.self) { d in
                    Text("    \(d)").font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("Rows the reader could not read",
                               value: "\(r.rowsSkipped)")
                    .font(.caption)
                    .foregroundStyle(r.rowsSkipped == 0 ? Color.dim : .red)
                LabeledContent("Approved differences",
                               value: ReviewRoundTrip.approved.map(\.field)
                                   .joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        } header: {
            Text("Read-back · reviews")
        } footer: {
            // HOISTED TO A CONSTANT — patch 327a, same reason `diagnosticLines`
            // stopped being one array literal. A footer built from eleven `+`
            // concatenations is one expression, and this file already carries
            // the largest `body` in the project.
            Text(Self.reviewFooter)
                .font(.caption2)
        }
    }

    /// Same shape as `reloadWeatherGear`: the read off the main actor, the
    /// comparison on it, because `ProposalStore` is a main-actor singleton.
    ///
    /// `ProposalStore.records` and NOT a filtered view of it. 325a is the
    /// reason that sentence is here: `AthleteStore` exposes `shoes`, `bikes`
    /// and `retired` separately as well as `allGear`, and passing the part
    /// where the whole was meant produced five phantom differences that were
    /// reasoned about twice before the wiring was checked. This store exposes
    /// exactly one collection, which is why this one is safe — recorded so the
    /// next reader knows it was checked rather than assumed.
    private func reloadReview(_ db: Sub4Database) async {
        let load = await Task.detached(priority: .utility) {
            ReviewRepository.load(db)
        }.value
        reviewLoad = load
        reviewTrip = ReviewRoundTrip.compare(
            storeRecords: ProposalStore.shared.records,
            database: load)
    }

    /// Same shape as `reloadAthlete`: the read off the main actor, the
    /// comparison on it, because the stores it compares against are main-actor
    /// singletons.
    private func reloadAuthored(_ db: Sub4Database) async {
        let load = await Task.detached(priority: .utility) {
            AuthoredRepository.load(db)
        }.value
        authoredLoad = load
        authoredTrip = AuthoredRoundTrip.compare(
            storeNotes: Array(NotesStore.shared.all.values),
            storeCommutes: Array(CommuteStore.shared.decisions.values),
            database: load)
    }

    /// The read off the main actor, the comparison on it — the stores it
    /// compares against are main-actor singletons and the database read is not
    /// this screen's to block on, however small it is.
    private func reloadAthlete(_ db: Sub4Database) async {
        let load = await Task.detached(priority: .utility) {
            AthleteRepository.load(db)
        }.value
        athleteLoad = load
        athleteTrip = AthleteRoundTrip.compare(store: ConstantsStore.shared.c,
                                               storeFTP: AthleteStore.shared.ftp,
                                               storeZones: AthleteStore.shared.hrZones,
                                               database: load)
    }

    /// D6c — patch 312, restructured at 313 when slice 2 arrived.
    ///
    /// ONE SECTION, ONE BUTTON, EVERY SLICE. Groundwork §7 left the shape open
    /// until there was more than one comparison to lay out. There are two now,
    /// they need the SAME database read and the SAME `ActivityRoster.settle`,
    /// and two buttons would let somebody run half of it and see something that
    /// looked whole.
    ///
    /// The three sections above ask *do both sides hold the same records* —
    /// nineteen named fields per activity. This asks *would the app derive the
    /// same answers*: the same list, in the same order, in the same days, and
    /// now adding up to the same distances.
    ///
    /// EVERY ROW IS UNCONDITIONAL once a comparison has run. §12.54.2, and this
    /// screen has now learned that twice.
    @ViewBuilder
    private func paritySection(_ db: Sub4Database) -> some View {
        Section {
            if parity.isRunning {
                HStack { ProgressView(); Text("Deriving…").font(.caption) }
            } else {
                Button("Compare the derived lists") { runParity(db) }
            }

            LabeledContent("Parity", value: parity.last.line)
                .font(.caption)
                .foregroundStyle(parity.last.isHealthy ? Color.dim : .red)

            // MARK: Slice 1 — the list

            if let r = parity.last.activities {
                Text("The list")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                // THE THREE DENOMINATORS — groundwork §2.1 case 2. A dead read
                // stops them matching, and zero compared to zero agrees
                // perfectly while meaning nothing.
                LabeledContent("In the app", value: "\(r.storeCount)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("In the database",
                               value: "\(r.databaseKept) of \(r.databaseOffered) rows")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Compared", value: "\(r.common)")
                    .font(.caption)
                    .foregroundStyle(r.lookedAtSomething ? Color.dim : .red)

                LabeledContent("In the app only", value: "\(r.storeOnly.count)")
                    .font(.caption)
                    .foregroundStyle(r.storeOnly.isEmpty ? Color.dim : .red)
                LabeledContent("In the database only", value: "\(r.databaseOnly.count)")
                    .font(.caption)
                    .foregroundStyle(r.databaseOnly.isEmpty ? Color.dim : .red)

                LabeledContent("Order disagreements",
                               value: "\(r.orderDiffered) of \(r.orderCompared)")
                    .font(.caption)
                    .foregroundStyle(r.orderDiffered == 0 ? Color.dim : .red)
                if let at = r.firstOrderDisagreement {
                    Text("  first at position \(at + 1)")
                        .font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("Days compared", value: "\(r.daysCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Days that disagree",
                               value: "\(r.daysOnlyInStore.count + r.daysOnlyInDatabase.count + r.daysWithDifferentMembers.count)")
                    .font(.caption)
                    .foregroundStyle(r.daysOnlyInStore.isEmpty
                                     && r.daysOnlyInDatabase.isEmpty
                                     && r.daysWithDifferentMembers.isEmpty
                                     ? Color.dim : .red)
                ForEach(r.daysWithDifferentMembers.prefix(5), id: \.self) { day in
                    Text("  \(day)").font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("Time-zone changes",
                               value: r.zonesAgree
                                   ? "\(r.zoneChangesCompared), agreed"
                                   : "\(r.zoneChangesCompared), disagreed")
                    .font(.caption)
                    .foregroundStyle(r.zonesAgree ? Color.dim : .red)

                // DIM WHEN ZERO, INK WHEN NOT — not red. These are not
                // disagreements; they are rows the database is still carrying
                // that the app's own rules refuse. §12.46.3 predicted them.
                LabeledContent("Rows the rules dropped", value: "\(r.databaseDropped)")
                    .font(.caption)
                    .foregroundStyle(r.databaseDropped == 0 ? Color.dim : Color.ink)
                LabeledContent("Rows collapsed as duplicates",
                               value: "\(r.databaseCollapsed)")
                    .font(.caption)
                    .foregroundStyle(r.databaseCollapsed == 0 ? Color.dim : Color.ink)
                LabeledContent("Rows the reader could not read",
                               value: "\(r.databaseSkipped)")
                    .font(.caption)
                    .foregroundStyle(r.databaseSkipped == 0 ? Color.dim : .red)

                LabeledContent("The app's list is settled",
                               value: r.storeIsSettled ? "yes" : "no")
                    .font(.caption)
                    .foregroundStyle(r.storeIsSettled ? Color.dim : .red)
            }

            // MARK: Slice 2 — the numbers derived from it

            if let v = parity.last.volume {
                Text("Daily and weekly volume")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                // EACH COUNT BESIDE ITS OWN DENOMINATOR — §12.54.3. "0 of 324"
                // is evidence; a bare 0 is noise.
                LabeledContent("Day distances",
                               value: "\(v.daysDiffering.count) of \(v.daysCompared) disagree")
                    .font(.caption)
                    .foregroundStyle(v.daysDiffering.isEmpty ? Color.dim : .red)
                ForEach(v.daysDiffering.prefix(5), id: \.self) { day in
                    Text("  \(day)").font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("Week figures",
                               value: "\(v.weeksDiffering.count) of \(v.weekValuesCompared) disagree")
                    .font(.caption)
                    .foregroundStyle(v.weeksDiffering.isEmpty ? Color.dim : .red)
                ForEach(v.weeksDiffering.prefix(5), id: \.self) { w in
                    Text("  \(w)").font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("History bands",
                               value: "\(v.bandsDiffering.count) of \(v.bandsCompared) disagree")
                    .font(.caption)
                    .foregroundStyle(v.bandsDiffering.isEmpty ? Color.dim : .red)
                ForEach(v.bandsDiffering.prefix(6), id: \.self) { b in
                    Text("  \(b)").font(.caption2).foregroundStyle(.red)
                }

                LabeledContent("The history starts on the same day",
                               value: v.historyStartAgrees ? "yes" : "no")
                    .font(.caption)
                    .foregroundStyle(v.historyStartAgrees ? Color.dim : .red)

                // ON SCREEN, because a threshold nobody can see is a threshold
                // nobody can argue with.
                LabeledContent("Tolerance", value: VolumeParity.toleranceLabel)
                    .font(.caption).foregroundStyle(Color.dim)
            }

            // MARK: Slice 3 — the fitness curve, patch 315

            if let l = parity.last.load {
                Text("Fitness and load")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                LabeledContent("Days in each series",
                               value: "\(l.appDays) vs \(l.databaseDays)")
                    .font(.caption)
                    .foregroundStyle(l.appDays == l.databaseDays ? Color.dim : .red)
                LabeledContent("Days compared", value: "\(l.daysCompared)")
                    .font(.caption)
                    .foregroundStyle(l.daysCompared > 0 ? Color.dim : .red)
                // THE DEEP DENOMINATOR. Four hundred rest days would satisfy
                // the row above and describe no training at all.
                LabeledContent("Sessions compared", value: "\(l.workoutsCompared)")
                    .font(.caption)
                    .foregroundStyle(l.workoutsCompared > 0 ? Color.dim : .red)
                LabeledContent("Scored from a trace",
                               value: "\(l.appTraces) vs \(l.databaseTraces)")
                    .font(.caption)
                    .foregroundStyle(l.appTraces == l.databaseTraces ? Color.dim : .red)

                LabeledContent("Days with a different state",
                               value: "\(l.daysWithDifferentState.count)")
                    .font(.caption)
                    .foregroundStyle(l.daysWithDifferentState.isEmpty ? Color.dim : .red)
                ForEach(l.daysWithDifferentState.prefix(5), id: \.self) { day in
                    Text("  \(day)").font(.caption2).foregroundStyle(.red)
                }
                LabeledContent("Days with a different total",
                               value: "\(l.daysWithDifferentLoad.count)")
                    .font(.caption)
                    .foregroundStyle(l.daysWithDifferentLoad.isEmpty ? Color.dim : .red)
                ForEach(l.daysWithDifferentLoad.prefix(5), id: \.self) { day in
                    Text("  \(day)").font(.caption2).foregroundStyle(.red)
                }

                // THE ROW THIS SLICE EXISTS FOR — see LoadParity's header. A
                // session scored from the trace on one side and from the
                // session average on the other is D6a's accepted trace loss
                // costing a number somebody reads.
                LabeledContent("Sessions on a different rung",
                               value: "\(l.workoutsWithDifferentSource.count)")
                    .font(.caption)
                    .foregroundStyle(l.workoutsWithDifferentSource.isEmpty
                                     ? Color.dim : .red)
                LabeledContent("Sessions with a different figure",
                               value: "\(l.workoutsWithDifferentFigure.count)")
                    .font(.caption)
                    .foregroundStyle(l.workoutsWithDifferentFigure.isEmpty
                                     ? Color.dim : .red)

                // THE SHAPE UNDER THE NUMBER — patch 316. TRIMP is an
                // integral; this is the distribution it integrates. Two
                // different distributions produce the same TRIMP, and the
                // distribution is what the Time-in-zone card draws.
                LabeledContent("Heart-rate buckets compared",
                               value: "\(l.hrBucketsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Sessions with a different distribution",
                               value: "\(l.workoutsWithDifferentHistogram.count)")
                    .font(.caption)
                    .foregroundStyle(l.workoutsWithDifferentHistogram.isEmpty
                                     ? Color.dim : .red)
                LabeledContent("Zones that disagree",
                               value: "\(l.zonesDiffering.count) of \(l.zonesCompared)")
                    .font(.caption)
                    .foregroundStyle(l.zonesDiffering.isEmpty ? Color.dim : .red)
                LabeledContent("Sessions in the zone card",
                               value: "\(l.zoneTracedApp) vs \(l.zoneTracedDatabase)")
                    .font(.caption)
                    .foregroundStyle(l.zoneTracedApp == l.zoneTracedDatabase
                                     ? Color.dim : .red)
                LabeledContent("Sessions it left out",
                               value: "\(l.zoneUntracedApp) vs \(l.zoneUntracedDatabase)")
                    .font(.caption)
                    .foregroundStyle(l.zoneUntracedApp == l.zoneUntracedDatabase
                                     ? Color.dim : .red)

                LabeledContent("Curve points that disagree",
                               value: "\(l.pointsWithDifferentFitness) of \(l.pointsCompared)")
                    .font(.caption)
                    .foregroundStyle(l.pointsWithDifferentFitness == 0 ? Color.dim : .red)
                LabeledContent("Fitness", value: l.fitnessLine)
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Fatigue", value: l.fatigueLine)
                    .font(.caption).foregroundStyle(Color.dim)

                // THE LIMIT, PRINTED. A comparison that does not say what it
                // held constant is a comparison whose result cannot be read.
                LabeledContent("Held from the app", value: LoadParity.heldFromTheApp)
                    .font(.caption).foregroundStyle(Color.dim)
                // PATCH 317. "Held from the app" and "held from the app and
                // never checked" are different sentences, and until the athlete
                // read-back above existed this screen could only say the
                // second one.
                LabeledContent("Of those, verified", value: LoadParity.verifiedByReadBack)
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Tolerance", value: LoadParity.toleranceLabel)
                    .font(.caption).foregroundStyle(Color.dim)
            } else if case .ran = parity.last {
                // NOT ZERO DIFFERENCES — NO ANSWER. The app's own series had
                // not been built, so there was nothing to compare against.
                LabeledContent("Fitness and load",
                               value: "the app's load series was not built")
                    .font(.caption).foregroundStyle(.red)
            }

            // MARK: Slice 4 — details, splits and laps

            if let d = parity.last.details {
                Text("Details, splits and laps")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                LabeledContent("Details in each side",
                               value: "\(d.appDetails) vs \(d.databaseDetails)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Details compared", value: "\(d.detailsCompared)")
                    .font(.caption)
                    .foregroundStyle(d.detailsCompared > 0 ? Color.dim : .red)
                LabeledContent("In the app only", value: "\(d.detailsOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(d.detailsOnlyInApp.isEmpty ? Color.dim : .red)
                // DIM, NOT RED — patch 298's rule. DataCorrections refuses two
                // sessions and the importer declines their details at the door,
                // while DetailStore keeps them because it keys by Strava id and
                // never sees an Activity. A permanently correct red row is a row
                // that stops being read.
                LabeledContent("Excluded on purpose",
                               value: "\(d.detailsExcluded.count)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("In the database only",
                               value: "\(d.detailsOnlyInDatabase.count)")
                    .font(.caption)
                    .foregroundStyle(d.detailsOnlyInDatabase.isEmpty ? Color.dim : .red)

                // THE TWO DENOMINATORS, AND THE SECOND IS THE REAL ONE. A pace
                // that is nil on both sides agrees perfectly and proves nothing,
                // so the count of figures BOTH sides answered is what says
                // whether this looked at anything.
                LabeledContent("Pace figures compared",
                               value: "\(d.paceFiguresCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  both sides answered",
                               value: "\(d.paceFiguresAnswered)")
                    .font(.caption)
                    .foregroundStyle(d.paceFiguresAnswered > 0 ? Color.dim : .red)
                LabeledContent("Pace figures that differ",
                               value: "\(d.paceFiguresDiffering.count)")
                    .font(.caption)
                    .foregroundStyle(d.paceFiguresDiffering.isEmpty ? Color.dim : .red)
                ForEach(d.paceFiguresDiffering.prefix(6), id: \.self) { f in
                    Text("    \(f)").font(.caption2).foregroundStyle(.red)
                }
                if d.paceFiguresDiffering.count > 6 {
                    Text("    + \(d.paceFiguresDiffering.count - 6) more figures")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                LabeledContent("Splits compared", value: "\(d.splitsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Splits with a different pace",
                               value: "\(d.splitsWithDifferentPace)")
                    .font(.caption)
                    .foregroundStyle(d.splitsWithDifferentPace == 0 ? Color.dim : .red)
                LabeledContent("Splits with a different heart rate",
                               value: "\(d.splitsWithDifferentHR)")
                    .font(.caption)
                    .foregroundStyle(d.splitsWithDifferentHR == 0 ? Color.dim : .red)
                // DIM AND ALWAYS PRESENT — patch 320a. Carried differently,
                // drawn the same: the importer's `positiveOrNil` on a stored
                // zero. Not a difference, and not allowed to vanish either.
                LabeledContent("  zero heart rates normalised",
                               value: "\(d.splitsWithNormalisedHR)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Details with a different split set",
                               value: "\(d.detailsWithDifferentSplitSet.count)")
                    .font(.caption)
                    .foregroundStyle(d.detailsWithDifferentSplitSet.isEmpty
                                     ? Color.dim : .red)
                LabeledContent("Details with different flags",
                               value: "\(d.detailsWithDifferentFlags.count)")
                    .font(.caption)
                    .foregroundStyle(d.detailsWithDifferentFlags.isEmpty
                                     ? Color.dim : .red)
                LabeledContent("Details with different elevation",
                               value: "\(d.detailsWithDifferentElevation.count)")
                    .font(.caption)
                    .foregroundStyle(d.detailsWithDifferentElevation.isEmpty
                                     ? Color.dim : .red)
                LabeledContent("Details with a different track",
                               value: "\(d.detailsWithDifferentTrack.count)")
                    .font(.caption)
                    .foregroundStyle(d.detailsWithDifferentTrack.isEmpty
                                     ? Color.dim : .red)

                LabeledContent("Laps offered to the detector",
                               value: "\(d.lapsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Details read as intervals", value: d.intervalLine)
                    .font(.caption)
                    .foregroundStyle(d.appDetailsReadAsIntervals
                                     == d.databaseDetailsReadAsIntervals
                                     ? Color.dim : .red)
                LabeledContent("Details with a different lap reading",
                               value: "\(d.detailsWithDifferentLapReading.count)")
                    .font(.caption)
                    .foregroundStyle(d.detailsWithDifferentLapReading.isEmpty
                                     ? Color.dim : .red)
                LabeledContent("Reps compared", value: "\(d.repsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Reps that differ", value: "\(d.repsDiffering)")
                    .font(.caption)
                    .foregroundStyle(d.repsDiffering == 0 ? Color.dim : .red)
                LabeledContent("  zero heart rates normalised",
                               value: "\(d.repsWithNormalisedHR)")
                    .font(.caption2).foregroundStyle(Color.dim)

                // THE ROW D6a's ACCEPTED LOSS IS AIMED AT. `hasHRSplits` is the
                // only derived property that reads averageHR, and it treats a
                // stored zero and a missing value alike — so these two matching
                // is the evidence that the normalisation costs no figure.
                LabeledContent("Details with heart-rate splits", value: d.hrSplitsLine)
                    .font(.caption)
                    .foregroundStyle(d.appDetailsWithHRSplits
                                     == d.databaseDetailsWithHRSplits
                                     ? Color.dim : .red)
                LabeledContent("Details with a route", value: d.routeLine)
                    .font(.caption)
                    .foregroundStyle(d.appDetailsWithRoute == d.databaseDetailsWithRoute
                                     ? Color.dim : .red)

                LabeledContent("Held from the app", value: DetailParity.heldFromTheApp)
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("Tolerance", value: DetailParity.toleranceLabel)
                    .font(.caption).foregroundStyle(Color.dim)
            } else if case .ran = parity.last {
                // NOT ZERO DIFFERENCES — NO ANSWER, again. The detail read
                // itself failed, which is a different fact from a device that
                // holds no details.
                LabeledContent("Details, splits and laps",
                               value: "the details could not be read")
                    .font(.caption).foregroundStyle(.red)
            }

            // MARK: Slice 5 — plan matching

            if let m = parity.last.matches {
                Text("Plan matching")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                LabeledContent("Days compared", value: "\(m.daysCompared)")
                    .font(.caption)
                    .foregroundStyle(m.daysCompared > 0 ? Color.dim : .red)
                LabeledContent("Planned sessions compared",
                               value: "\(m.sessionsCompared)")
                    .font(.caption).foregroundStyle(Color.dim)
                // THE DENOMINATOR THAT MEANS SOMETHING. Most planned sessions
                // resolve to nothing on both sides and agree perfectly; this is
                // the count of sessions that actually claimed an activity.
                LabeledContent("  claimed an activity on both sides",
                               value: "\(m.matchesResolved)")
                    .font(.caption)
                    .foregroundStyle(m.matchesResolved > 0 ? Color.dim : .red)
                LabeledContent("Extras compared", value: "\(m.extrasCompared)")
                    .font(.caption).foregroundStyle(Color.dim)

                LabeledContent("Days only in the app",
                               value: "\(m.daysOnlyInApp.count)")
                    .font(.caption)
                    .foregroundStyle(m.daysOnlyInApp.isEmpty ? Color.dim : .red)
                LabeledContent("Days only in the database",
                               value: "\(m.daysOnlyInDatabase.count)")
                    .font(.caption)
                    .foregroundStyle(m.daysOnlyInDatabase.isEmpty ? Color.dim : .red)
                LabeledContent("Sessions on one side only",
                               value: "\(m.sessionsOnOneSideOnly.count)")
                    .font(.caption)
                    .foregroundStyle(m.sessionsOnOneSideOnly.isEmpty ? Color.dim : .red)

                // THE ROW THIS SLICE EXISTS FOR.
                LabeledContent("Sessions that claimed a different activity",
                               value: "\(m.sessionsWithADifferentActivity.count)")
                    .font(.caption)
                    .foregroundStyle(m.sessionsWithADifferentActivity.isEmpty
                                     ? Color.dim : .red)
                ForEach(m.sessionsWithADifferentActivity.prefix(6), id: \.self) { u in
                    Text("    \(u)").font(.caption2).foregroundStyle(.red)
                }
                // AND THE ONE THAT TURNS 4/4 INTO 3/4.
                LabeledContent("Sessions done on one side only",
                               value: "\(m.sessionsDoneOnOneSideOnly.count)")
                    .font(.caption)
                    .foregroundStyle(m.sessionsDoneOnOneSideOnly.isEmpty
                                     ? Color.dim : .red)
                ForEach(m.sessionsDoneOnOneSideOnly.prefix(6), id: \.self) { u in
                    Text("    \(u)").font(.caption2).foregroundStyle(.red)
                }
                LabeledContent("Sessions chosen a different way",
                               value: "\(m.sessionsWithADifferentSource.count)")
                    .font(.caption)
                    .foregroundStyle(m.sessionsWithADifferentSource.isEmpty
                                     ? Color.dim : .red)
                LabeledContent("Days with different extras",
                               value: "\(m.daysWithDifferentExtras.count)")
                    .font(.caption)
                    .foregroundStyle(m.daysWithDifferentExtras.isEmpty
                                     ? Color.dim : .red)
                LabeledContent("Days with a different extras order",
                               value: "\(m.daysWithDifferentExtraOrder.count)")
                    .font(.caption)
                    .foregroundStyle(m.daysWithDifferentExtraOrder.isEmpty
                                     ? Color.dim : .red)

                // THE WEEK SCREEN'S OWN FIGURE, both sides. A reader can hold
                // this against the Week tab without pressing anything else.
                LabeledContent("Adherence", value: m.adherenceLine)
                    .font(.caption)
                    .foregroundStyle(m.appSessionsDone == m.databaseSessionsDone
                                     ? Color.dim : .red)
                // ZERO IS THE HONEST ANSWER TODAY — match_decision holds no
                // rows. Printed so that "no differences" is not read as
                // coverage of the override branch, which was never entered.
                LabeledContent("Overrides applied", value: "\(m.overridesApplied)")
                    .font(.caption).foregroundStyle(Color.dim)

                LabeledContent("Held from the app", value: MatchParity.heldFromTheApp)
                    .font(.caption).foregroundStyle(Color.dim)
                // PATCH 322. One of the three is now checked by the authored
                // read-back above rather than assumed.
                LabeledContent("Of those, verified",
                               value: MatchParity.verifiedByReadBack)
                    .font(.caption).foregroundStyle(Color.dim)
            }
        } header: {
            Text("Shadow parity")
        } footer: {
            Text("Builds the activity list a second time, from the database "
                 + "instead of the files, and compares what the app would "
                 + "derive from each. Both sides run through the same rules — "
                 + "one copy, called twice — so a difference here is a "
                 + "difference in the DATA, not in how it was derived.\n\n"
                 + "It does not re-check fields. The three read-backs above do "
                 + "that.\n\n"
                 + "Volume is compared with a tolerance, because two identical "
                 + "sums of decimals can end in a different last digit. A "
                 + "difference under a metre or a second is arithmetic; "
                 + "anything larger is data.\n\n"
                 + "Rows the rules dropped are not disagreements: the database "
                 + "is carrying something the app no longer wants, which is "
                 + "what automatic write-throughs not reconciling looks like. "
                 + "Details excluded on purpose are not disagreements either — "
                 + "two sessions are refused by name. Every other number above "
                 + "zero is real.\n\n"
                 + "Details, splits and laps compare what the activity screen "
                 + "would DERIVE: the closing, opening and best-window paces, "
                 + "the split table, and what the laps read as. The plan is not "
                 + "consulted, so laps are read with no cut pace — that is "
                 + "slice 5. A pace that is missing on both sides agrees and "
                 + "proves nothing, which is why the figures BOTH sides "
                 + "answered are counted separately.\n\n"
                 + "Heart rates are compared as the tables DRAW them — every "
                 + "one of them guards `hr > 0`, so a stored zero and a missing "
                 + "value are the same pixel. What is carried differently and "
                 + "drawn the same is counted on its own line, dim, because a "
                 + "row that vanishes once it is understood is a row nobody can "
                 + "watch. See ADR-0003 §12.63.8.\n\n"
                 + "Plan matching runs the app's own resolver twice, over two "
                 + "activity lists. The plan, the match decisions and the "
                 + "commute decisions come from the app on both sides, so the "
                 + "only thing that moves is the activities. A vague session "
                 + "takes the first candidate, so the ORDER of that list "
                 + "decides what it claims — which is why this slice's answer "
                 + "rests on the list slice reporting zero order "
                 + "disagreements. See ADR-0003 §12.64.\n\n"
                 + "The fitness comparison holds the constants, your zones, "
                 + "the FTP, your session RPEs and Apple Health identical on "
                 + "both sides — the database has no reader for them yet, and "
                 + "Health it will never have. So it answers one question: do "
                 + "the database's activities and traces produce the same "
                 + "load, and the same shape underneath it.\n\n"
                 + "A training load is an integral over the heart-rate trace. "
                 + "The distribution it integrates is what the Time-in-zone "
                 + "card draws, and two different distributions can add up to "
                 + "the same load — so both are compared. See ADR-0003 "
                 + "§12.56, §12.57, §12.59 and §12.60.")
                .font(.caption2)
        }
    }

    private func runParity(_ db: Sub4Database) {
        // The runner holds the result now, so it survives this sheet being
        // dismissed — patch 313. It also does the read off the main actor,
        // which is what lets the spinner draw before the work starts.
        Task { await parity.run(db) }
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
            await reloadAthlete(db)
            await reloadAuthored(db)
            await reloadPlan(db)
            await reloadWeatherGear(db)
            await reloadReview(db)
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
            await reloadAthlete(db)
            await reloadAuthored(db)
            await reloadPlan(db)
            await reloadWeatherGear(db)
            await reloadReview(db)
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
                        await writeThrough.run(reason: "asked for on this screen",
                                               trigger: .manual)
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
                // ALWAYS PRESENT — patch 311, and §12.54.2 is four hours old.
                // A row that vanished when the trigger was NULL would be
                // indistinguishable from a row nobody wired in; a NULL says
                // "not recorded (before patch 311)", which is the truth about
                // the 45 rows this patch found.
                LabeledContent("Started by", value: r.triggerLabel)
                    .font(.caption)
                    .foregroundStyle(r.triggeredBy == nil ? Color.secondary : Color.dim)
                LabeledContent("Snapshot", value: r.snapshotID ?? "none taken")
                    .font(.caption)
                    .foregroundStyle(r.snapshotID == nil ? Color.red : Color.dim)
                if let n = r.note, !n.isEmpty {
                    Text(n).font(.caption2).foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // UNCONDITIONAL AT 311, and it was hidden-when-zero before.
                //
                // That is exactly what §12.54.2 was written about yesterday —
                // and worse here, because `stale` was ALSO reading only the
                // newest hundred rows, so the row could have been absent while
                // an interrupted run sat two days down the table. Two ways to
                // show nothing, one of them wrong, and no way to tell from a
                // screenshot.
                LabeledContent("Interrupted runs", value: "\(staleRuns)")
                    .font(.caption)
                    .foregroundStyle(staleRuns > 0 ? Color.red : Color.dim)
            } else {
                Text("No import has been recorded. Nothing in this database can "
                     + "be called verified until one has.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Import ledger")
        } footer: {
            // "One row per import" is what this said until 311, and it
            // is the sentence the migration's own body still carries. It
            // stopped being true the day the write-through landed.
            Text("A run reaches \"imported, not verified\" when the write "
                 + "commits; the verifier that can move it to \"verified\" is "
                 + "the next step, and until it exists nothing may switch its "
                 + "reads to this database.\n\n"
                 + "Most rows are not you. Leaving the app, coming back, and a "
                 + "background refresh each write one, so the ledger keeps the "
                 + "newest 200 of those and discards older ones. Runs you "
                 + "started, runs that failed, and runs that were interrupted "
                 + "are kept for good — an interrupted run is the only "
                 + "evidence the app was killed while writing.")
        }
    }

    /// What one read of the ledger produces. A named type rather than a tuple
    /// because it grew a third member at 311 and because the old version threw
    /// all three away when `latest` returned nothing — an empty ledger is a
    /// real answer ("0 rows"), not a reason to stop counting.
    private nonisolated struct LedgerRead: Sendable {
        var run: MigrationRun?
        var stale = 0
        var census: LedgerCensus?
    }

    private func reloadLedger(_ db: Sub4Database) async {
        let read = await Task.detached(priority: .utility) { () -> LedgerRead in
            var r = LedgerRead()
            r.run = try? MigrationLedger.latest(db)
            r.stale = (try? MigrationLedger.stale(db).count) ?? 0
            r.census = try? MigrationLedger.census(db)
            return r
        }.value
        lastRun = read.run
        staleRuns = read.stale
        ledgerCensus = read.census
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
        // PATCH 311, AND EVERY LINE OF IT IS UNCONDITIONAL. `migration_run: 45`
        // in the table counts above is what made this patch necessary, and a
        // tally that only appeared when something was wrong would repeat
        // §12.54.2 in the same week it was written down.
        lines.append("")
        lines.append("Last import: \(lastRun?.line ?? "no import has been recorded")")
        lines.append("Interrupted runs: \(staleRuns)")
        if let c = ledgerCensus {
            lines.append(contentsOf: c.diagnosticLines)
        } else {
            lines.append("Import ledger: could not be counted")
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
        // PATCH 310. UNCONDITIONAL, for 266c's reason, which 309 briefly
        // forgot on the Settings screen — see §12.54.2. This is also the only
        // place the roster's numbers appear when they are all zero, which is
        // what makes "0 collapsed" evidence rather than an absence.
        lines.append(contentsOf: ActivityStore.shared.loadDiagnosticLines)
        // PATCH 312, BOTH SLICES AT 313. Only after a run — this one costs a
        // database read and two full derivations, so there is nothing to print
        // until somebody presses the button. `Outcome.diagnosticLines` says
        // WHICH of the four states it is rather than being absent, and the
        // result now survives the sheet being dismissed, which is the defect
        // this line had on the day it shipped.
        lines.append("")
        lines.append(contentsOf: parity.last.diagnosticLines)
        // PATCH 317. UNCONDITIONAL, and the first read-back to reach the paste
        // at all. The other three cannot: their differences are named by
        // ACTIVITY ID, and §12.7 promises this paste carries none. This one
        // names FIELDS — `sexCoefficient`, `restByMonth[2026-06]`, `zone 3` —
        // plus a heart-rate maximum and an FTP, which describe a body's
        // capacity rather than anything the athlete did or where.
        lines.append("")
        if let r = athleteTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Athlete read-back: \(athleteLoad?.line ?? "not read")")
        }
        // PATCH 322. Session uids, field names and counts. A note's TEXT is
        // compared and never printed — it is the athlete writing about their
        // own training, and §12.7 promises this paste carries nothing of the
        // kind.
        lines.append("")
        if let r = authoredTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Authored read-back: \(authoredLoad?.line ?? "not read")")
        }
        // PATCH 323. Bundled plan content — uids, field names and counts, and
        // nothing the athlete wrote.
        lines.append("")
        if let r = planTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Plan read-back: \(planLoad?.line ?? "not read")")
        }
        lines.append("")
        if let r = planExtrasTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Plan extras read-back: "
                       + "\(planExtrasLoad?.line ?? "not read")")
        }
        // PATCH 324. Strava activity ids, gear ids, field names and counts.
        lines.append("")
        if let r = weatherGearTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Weather and gear read-back: "
                       + "\(weatherGearLoad?.line ?? "not read")")
        }
        // PATCH 327. Counts, field names, ISO run times, plan session uids and
        // CHARACTER COUNTS. The evidence pack and the model's prose are
        // compared and never printed — §12.7 promises this paste carries
        // nothing the athlete wrote, and this slice carries strictly more of
        // that kind of text than 322 did.
        lines.append("")
        if let r = reviewTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Review read-back: \(reviewLoad?.line ?? "not read")")
        }

        return lines.joined(separator: "\n")
    }
}
