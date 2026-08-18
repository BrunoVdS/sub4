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
    /// PATCH 341. OBSERVED RATHER THAN OWNED, like `parity`, `rollUp`,
    /// `writeThrough` and `verification`.
    ///
    /// This was `@State private var importReport`, drawn in the Import section
    /// and referenced nowhere in `diagnosticsText` — so the counts a person
    /// actually wants to send were reachable only by screenshot, and died with
    /// the sheet. §12.57, and the last block on this screen that had it.
    /// §12.89.
    @State private var lastImport = LastImport.shared
    @State private var importError: String?
    /// The authored export's own outcome. Nil until the button is pressed;
    /// the file itself goes out through `shared`, like the diagnostics.
    @State private var authoredExported: String?

    /// Patch 247 — migration contract item 3. Manual for now, like the import
    /// above it: launch ownership belongs to the migration engine, and wiring a
    /// capture into launch before the ledger exists would be a second answer to
    /// a question one patch away from being answered once.
    @State private var snapshotting = false
    @State private var snapshot: SnapshotManifest?
    @State private var snapshotError: String?
    @State private var snapshotNotice: String?

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
    /// PATCH 355 — D7 slice B2. `match_decision` had a table and no reader
    /// until this patch; this is the load, beside the two it joins.
    @State private var decisionLoad: MatchDecisionLoad?
    /// PATCH 364. Held for the same reason `decisionLoad` is: the paste's
    /// fallback branch prints it when no comparison has run this launch.
    @State private var moveLoad: PlanMoveLoad?
    @State private var planLoad: PlanLoad?
    @State private var planTrip: PlanRoundTrip.Report?
    @State private var planExtrasLoad: PlanExtrasLoad?
    @State private var planExtrasTrip: PlanExtrasRoundTrip.Report?
    // PATCH 352 — §12.97. NOT a read-back, and it is below them because it is
    // read at the same moment rather than because it is one of them: it
    // compares nothing against a store, and it reads every stored version
    // where the read-back above reads exactly one.
    //
    // `planPrune` is a value and not an optional. "Never run" and "ran and
    // found nothing" are different states and an optional would collapse them
    // — §12.15, and `PlanVersionPrune.didRun` is what keeps them apart.
    @State private var planCensus: PlanVersionCensus?
    @State private var planPrune = PlanVersionPrune()
    @State private var weatherGearLoad: WeatherGearLoad?
    @State private var weatherGearTrip: WeatherGearRoundTrip.Report?
    // PATCH 374. `lastWeatherRestore` is an optional and `planPrune` above is
    // not, and the difference is real: a prune that never ran and a prune that
    // ran and pruned nothing are both facts the screen states, while a restore
    // that has not run has nothing to say at all.
    @State private var restoringWeather = false
    @State private var weatherRestoreError: String?
    @State private var lastWeatherRestore: StoreRestore.Receipt?
    // PATCH 400. Receipts, plural: one control restores TWO stores and each
    // has its own answer. A single combined count would say "added 4" over two
    // files and leave a reader unable to tell which one was empty. §12.15.
    @State private var restoringAuthored = false
    @State private var authoredRestoreFailures: [StoreRestore.Failure] = []
    @State private var lastAuthoredRestore: [StoreRestore.Receipt] = []
    // PATCH 327 — D6c slice 7. The ninth read-back, and the only one whose
    // subject may legitimately not exist yet: the first real review is due
    // 24 August 2026.
    @State private var reviewLoad: ReviewTrailLoad?
    @State private var reviewTrip: ReviewRoundTrip.Report?
    @State private var verifying = false
    /// PATCH 340. OBSERVED RATHER THAN OWNED, like `parity`, `writeThrough`
    /// and `rollUp` below.
    ///
    /// A passing comparison and a durable ledger transition are separate
    /// facts, and both used to be `@State` on this view — so the one piece of
    /// evidence D7's entry gate turns on did not survive pressing Done, and
    /// the diagnostics paste omitted the whole block unless it was taken from
    /// inside the sheet that produced it. §12.57, fourth instance, on the
    /// control that matters most. §12.88.
    @State private var verification = VerificationResult.shared

    /// D6c — patch 312, moved off `@State` at 313.
    ///
    /// OBSERVED RATHER THAN OWNED, like `writeThrough` above. The result used
    /// to live here, so pressing Done discarded it — and the diagnostics paste,
    /// which is the thing somebody reads later, said "Not compared since this
    /// launch" a minute after the comparison passed. True of the `@State` and
    /// false about the world. §12.57.
    ///
    /// PATCH 330c. The parity ROWS moved to `ShadowParitySections`, which
    /// observes the same shared runner. This reference stays because the
    /// diagnostics paste below still needs the outcome — and because that is
    /// the whole point of the runner owning it rather than a view.
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

    /// PATCH 331. Observed, like `writeThrough` and `parity` above, and for
    /// the same reason: the backlog changes WHILE this screen is open. A drain
    /// finishing behind a sheet that keeps showing the count it opened with is
    /// the exact shape 306 fixed for the ledger.
    @State private var detailStore = DetailStore.shared

    /// PATCH 332. Nil until the share button writes a file. `ShareItem` is the
    /// wrapper `ShareSheet.swift` owns so that `.sheet(item:)` has something
    /// `Identifiable` without a retroactive conformance on `URL`.
    @State private var shared: ShareItem?
    @State private var shareFailed = false

    /// PATCH 333. Observed, like `parity` and `writeThrough`. The roll-up's
    /// RESULT lives on the runner so that pressing Done does not discard it —
    /// §12.57, which 313 fixed for shadow parity and never for these nine.
    @State private var rollUp = ReadBackRollUp.shared
    /// The spinner stays here. A spinner that outlives its screen is a lie of
    /// a different kind.
    @State private var rollingUp = false

    /// **WHICH SECTIONS ARE OPEN — patch 393, §12.137.**
    ///
    /// EMPTY IS COLLAPSED AND EMPTY IS THE DEFAULT. This screen is twenty-three
    /// sections and roughly four hundred lines; opening it as an index of
    /// headers is the whole point.
    ///
    /// **A PLAIN `@State`, SO IT DIES WITH THE SHEET, AND THAT IS THE DECISION
    /// RATHER THAN AN OVERSIGHT.** §12.57 is this screen's own history — a
    /// result that evaporated on Done — so a `@State` here needs saying out
    /// loud: what evaporates is a VIEW PREFERENCE, not an answer. Bruno's call,
    /// 17 August: back to collapsed every time the sheet opens.
    @State private var expanded: Set<String> = []

    /// Asked by every section's content and footer. One place, so a section
    /// cannot disagree with its own header about whether it is open.
    private func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

    var body: some View {
        NavigationStack {
            List {
                switch opened {
                case .none:
                    Section { HStack { ProgressView(); Text("Opening…") } }
                case .failure(let error):
                    failureSection(error)
                case .success(let db):
                    // SIX GROUPS AND A CHILD VIEW, NOT TWENTY-ONE SECTIONS —
                    // patch 330c. The sections and their order are unchanged;
                    // what changed is how deeply they nest. A `@ViewBuilder`
                    // block of twenty-one children is a left-leaning chain
                    // twenty `TupleView`s deep, and SwiftUI walks that chain
                    // recursively before it draws anything — which is what
                    // `EXC_BAD_ACCESS` inside `___chkstk_darwin` on opening
                    // this tab was. Six groups of three or four is depth nine.
                    // See ShadowParitySections' header and ADR-0003 §12.76.
                    stateSections(db)
                    inputSections(db)
                    ledgerSections(db)
                    activityReadBackSections(db)
                    recordReadBackSections(db)
                    // AFTER the read-backs, because it asks the question they
                    // cannot: they compare RECORDS, this compares the list the
                    // app would DERIVE from them. The screen reads in the
                    // order the two questions relate — are the rows the same,
                    // and then would the screens be the same.
                    //
                    // A SEPARATE VIEW rather than a group, because it is the
                    // largest thing on this screen by a wide margin and it
                    // needs none of this screen's state. §12.76.2.
                    ShadowParitySections(db: db, shared: $shared, expanded: $expanded)
                    toolSections(db)
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
            // PATCH 332. The only presentation modifier on this screen, and it
            // is here rather than on the diagnostics Section because a sheet
            // presented from inside a `List` row is presented from a view the
            // list is free to recycle.
            .sheet(item: $shared) { item in
                ShareSheet(items: [item.url])
            }

        }
    }

    // MARK: - The six groups — patch 330c

    /// PURELY STRUCTURAL. Every group below is a bag of the sections that used
    /// to sit side by side in `body`, in the same order, drawn identically.
    /// The grouping exists to make the view tree a tree instead of a chain;
    /// nothing here decides anything.

    /// What the file is and what is in it.
    @ViewBuilder
    private func stateSections(_ db: Sub4Database) -> some View {
        verdictSection
        fileSection(db)
        contentsSection
    }

    /// What goes in, and what protects what goes in.
    @ViewBuilder
    private func inputSections(_ db: Sub4Database) -> some View {
        // BEFORE the import, on screen and in the contract. Item 3 says copy
        // every legacy input before decoding, and a screen that offers to
        // import above the button that protects the inputs teaches the wrong
        // order.
        snapshotSection
        importSection(db)
        // PATCH 331. Between the import and the write-through, because it is
        // the answer to "why is the import finding less than I expected" —
        // and the answer is usually that Strava has not sent it yet.
        traceBacklogSection
        // PATCH 302. Directly after the Import section, because it IS that
        // import — fired without anybody pressing it. The screen reads in the
        // order the two things relate: here is the button, and here is what
        // happens when nobody presses it.
        writeThroughSection(db)
    }

    /// What ran, and whether it was believed.
    @ViewBuilder
    private func ledgerSections(_ db: Sub4Database) -> some View {
        ledgerSection
        // DIRECTLY AFTER THE LEDGER, because it is the thing that moves a run
        // out of `pending`. The screen reads in the order the states go:
        // imported, then verified.
        verifySection(db)
    }

    /// The three read-backs behind a press — 669 rows, 667 details and roughly
    /// 1.5 million sample comparisons between them.
    @ViewBuilder
    private func activityReadBackSections(_ db: Sub4Database) -> some View {
        // PATCH 333. FIRST, and above the nine it summarises, for
        // `verdictSection`'s reason: a verdict assembled by the reader from
        // nine sections further down is a verdict that gets skimmed.
        rollUpSection(db)
        readBackSection(db)
        detailReadBackSection(db)
        recordingReadBackSection(db)
        // PATCH 352 — §12.97. It is in THIS group and not beside the plan
        // read-back because it needs the database: it carries the only
        // destructive button on this screen.
        //
        // THE SECOND HALF OF THIS NOTE WAS TRUE UNTIL 374c. It read "and the
        // sections above the read-backs are the ones that take `db`", which
        // stopped being so when `recordReadBackSections` took it — weather's
        // repair button has to sit beside the count that justifies it, and
        // moving the section up here the way this one moved would have
        // separated them. §12.118.9.
        planVersionSection(db)
    }

    /// The six that run themselves on open, because each costs one read.
    ///
    /// **IT TAKES THE DATABASE SINCE 374c, AND 352 SAID IT WOULD NOT.**
    /// That patch had a section needing `db` for a button and moved the
    /// SECTION into a group that had one, accepting the loss of adjacency with
    /// the numbers beside it. Weather went the other way: "only in the
    /// database: 601" and the button that acts on it have to be one row apart,
    /// so the database comes down here instead. The note in `ledgerSections`
    /// is corrected to match. §12.118.9.
    @ViewBuilder
    private func recordReadBackSections(_ db: Sub4Database) -> some View {
        // PATCH 317. The fourth, and the one that closes D6a's gap:
        // `athlete_profile`, `resting_month` and `hr_zone` were the only
        // imported tables nothing ever read back. FIRST of these because the
        // parity section below depends on it — shadow parity holds constants,
        // zones and FTP from the app, and this is what turns that from an
        // assumption into a check.
        athleteReadBackSection
        // PATCH 322. The fifth, and the one that closes the loop 321 opened:
        // `note.rpe` was slice 3's last unverified input, and `correction`
        // holds one of slice 5's three held ones.
        //
        // ONE SECTION FOR TWO TABLES, deliberately. Groundwork §7 warned that
        // a screen nobody scrolls to the bottom of is a screen whose bottom
        // rows are not read, and §12.40.1 measured that once already. Eleven
        // records do not need two headings.
        authoredReadBackSection
        // PATCH 323. Sixth read-back and the largest by a wide margin — 260
        // sessions where the athlete's profile was 27 fields. Its numbers need
        // reading twice: the compared count is a third of the table's, and the
        // row that says why is directly under it.
        planReadBackSection
        // PATCH 324. The one that closes slice 6 — 583 readings and eleven
        // shoes.
        weatherGearReadBackSection(db)
        // PATCH 327. Ninth and last of the read-backs, and the one that
        // finishes D6c's record side. It sits at the end because it is the
        // only one that can legitimately compare nothing: the first real
        // review is due 24 August 2026, and until then a green "no review
        // stored yet" is the correct answer rather than a missing one.
        reviewReadBackSection
    }

    /// The three that are about this screen rather than about the data.
    @ViewBuilder
    private func toolSections(_ db: Sub4Database) -> some View {
        // AFTER the import and before the benchmark. It is about the files the
        // import reads FROM, so it belongs beside the import; it is a survey
        // rather than an action, so it does not go above it.
        legacySection
        benchmarkSection
        diagnosticsSection(db)
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
            if isExpanded("file") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "The file",
                                        key: "file",
                                        expanded: $expanded,
                                        lines: { fileLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("file") {
            Text("The database and its journal files sit in their own folder, "
                 + "which carries the protection class so anything SQLite "
                 + "creates inside it inherits. Delete local data removes the "
                 + "folder whole, so nothing is left in a sidecar.")
                .font(.caption2)
        }
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
            if isExpanded("rows") {
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
        }
        } header: {
            // **THE ONE INTERPOLATED TITLE, AND THE REASON `key` EXISTS.**
            // Keying the expansion on this text would close the section the
            // moment a table count moved. §12.137.
            DiagnosticSectionHeader(title: "Rows — \(counts.count) table\(counts.count == 1 ? "" : "s")",
                                        key: "rows",
                                        expanded: $expanded,
                                        lines: { tableLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("rows") {
            Text(importedRows == 0
                 ? "Nothing imported yet, which is correct: the schema is built "
                 + "and step 3.3 is what fills it. The rows in source are seeded "
                 + "by the migration — they are the list of places data can come "
                 + "from, not data."
                 : "\(importedRows) imported rows, \(totalRows) in total.")
                .font(.caption2)
        }
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
            if isExpanded("snapshot") {
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

                LabeledContent("Captured at",
                               value: m.createdDate.flatMap { _ in
                                   AppTime.local(m.createdUTC)
                               } ?? "not recorded by this older manifest")
                    .font(.caption)
                    .foregroundStyle(m.createdDate == nil ? Color.secondary : Color.dim)

                LabeledContent("Files copied", value: "\(m.copiedCount) of \(m.presentCount)")
                    .font(.caption)
                LabeledContent("Size",
                               value: ByteCountFormatter.string(
                                fromByteCount: Int64(m.totalBytes), countStyle: .file))
                    .font(.caption)
                // PATCH 336. UNCONDITIONAL, and split — §12.54.2 and §12.54.3.
                //
                // It was gated on `> 0` and stood alone, so on 9 August it read
                // "5" over three lost stores and two retired formats, and a
                // reader had no way to tell which five. `details.json` and
                // `streams.json` were replaced by the `details/` and `streams/`
                // directories, so they cannot exist on any install after the
                // per-activity split — **the total has a floor of two and only
                // the second number can reach zero.** §12.84.
                LabeledContent("Declared but not present", value: "\(m.missingCount)")
                    .font(.caption).foregroundStyle(Color.dim)
                LabeledContent("  retired formats", value: "\(m.retiredFormatsAbsent)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("  stores not written", value: "\(m.storesNotWritten)")
                    .font(.caption2).foregroundStyle(Color.dim)
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
            if let notice = snapshotNotice {
                Text(notice).font(.caption2).foregroundStyle(Color.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        } header: {
            DiagnosticSectionHeader(title: "Protected snapshot",
                                        key: "snapshot",
                                        expanded: $expanded,
                                        lines: { snapshotLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("snapshot") {
            Text("A dated copy of every legacy file plus the declared "
                 + "UserDefaults values, with a SHA-256 for each. Live data is "
                 + "never moved or removed. After a new copy verifies, that copy "
                 + "and the newest previous verified copy stay in full; older complete "
                 + "copies become small audit receipts. Incomplete or unreadable "
                 + "snapshots are never pruned. Delete local data removes all of it.")
        }
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
            if isExpanded("import") {
            if importing {
                HStack { ProgressView(); Text("Importing…").font(.caption) }
            } else {
                // PATCH 370. IT SAYS SO. A button that quietly does a
                // second thing is a screen that has stopped describing
                // itself — §12.54.2, applied to a control rather than a row.
                Button("Import and verify") { runImport(db) }
            }

            if let e = importError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let r = lastImport.last.report, r.activitiesSeen == 0 {
                // Patch 220. All-zero counts read exactly like a broken button —
                // which is how a first run against empty stores looked.
                Text("The app's stores are empty, so there was nothing to copy. "
                     + "Open Today and let the sync finish first.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let r = lastImport.last.report {
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

                // PATCH 363. Named "Moved sessions" for 280's reason one row
                // up: it says what these rows ARE rather than what table they
                // happen to share with the commute decisions.
                LabeledContent("Moved sessions",
                               value: r.movesSeen == 0
                               ? "none"
                               : "\(r.movesImported) new, \(r.movesUpdated) refreshed")
                    .font(.caption)
                if r.movesOrphaned > 0 {
                    // NOT A FAULT, AND THE WORDING SAYS SO. A plan revision
                    // reissues session uids; the session simply shows on its
                    // planned day again. Groundwork §8.2, ADR §12.106.4.
                    LabeledContent("  move naming a session the plan no longer has",
                                   value: "\(r.movesOrphaned)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.movesRemoved > 0 {
                    LabeledContent("  moves withdrawn",
                                   value: "\(r.movesRemoved)")
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

                // PATCH 331. The trace account MOVED OUT of this report and
                // into `traceBacklogSection` below. It was never about the
                // import: it describes what Strava has not sent yet, it is
                // recomputed on every render, and living here meant it only
                // existed after somebody pressed Import in this launch — the
                // §12.57 evaporation, one screen later. See §12.77.

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
        }
        } header: {
            DiagnosticSectionHeader(title: "Import",
                                        key: "import",
                                        expanded: $expanded,
                                        lines: { lastImport.last.diagnosticLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("import") {
            Text("Copies activities and gear from the app's current stores into "
                 + "the database. Nothing else changes: the app still reads its "
                 + "JSON files, and the JSON files are not touched. Running it "
                 + "twice imports nothing twice.")
                .font(.caption2)
        }
        }
    }

    /// Off the main actor, and not as a nicety: this hashes and copies every
    /// file the app has ever written — on this device roughly 850 files and 25
    /// megabytes. `LegacySnapshot` is `nonisolated` throughout so the work can
    /// leave the main actor here and only the result comes back to it.
    private func runSnapshot() {
        snapshotting = true
        snapshotError = nil
        snapshotNotice = nil
        // `patchLabel` since 284: a snapshot taken under a fix-up should say
        // so. This string is the manifest's only record of what took it.
        let version = AppVersion.patchLabel
        // Read here, on the main actor, where the inventory lives. Inside the
        // detached task below it would not be reachable.
        let items = DataLifecycle.appSupportItems
        let capturedAt = Date()
        let preferenceSupplement: SnapshotSupplement
        do {
            let values: [String: Any]
            if let domain = Bundle.main.bundleIdentifier {
                values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            } else {
                values = UserDefaults.standard.dictionaryRepresentation()
            }
            preferenceSupplement = try LegacySnapshot.preferenceSupplement(
                keys: DataLifecycle.preferenceKeys, values: values)
        } catch {
            snapshotError = "The declared preferences could not be protected: "
                          + error.localizedDescription
            snapshotting = false
            return
        }
        Task {
            let result: Result<SnapshotCaptureResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try LegacySnapshot.capture(
                        at: capturedAt, appVersion: version, items: items,
                        supplements: [preferenceSupplement]))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let result):
                let m = result.manifest
                snapshot = m
                let archived = result.retention.pruned.count
                snapshotNotice = archived > 0
                    ? "Archived \(archived) older full snapshot"
                      + (archived == 1 ? "" : "s")
                      + " as detailed audit receipt"
                      + (archived == 1 ? "" : "s") + ". "
                      + "\(result.retention.fullSnapshots) full copies and "
                      + "\(result.retention.receipts) receipts remain."
                    : "\(result.retention.fullSnapshots) full snapshot"
                      + (result.retention.fullSnapshots == 1 ? "" : "s")
                      + " and \(result.retention.receipts) audit receipts retained."
                var messages = result.retention.warnings
                if m.failureCount > 0 {
                    messages.insert(
                        "\(m.failureCount) file\(m.failureCount == 1 ? "" : "s") "
                        + "could not be copied or did not verify. The manifest "
                        + "in \(m.id) names each one.", at: 0)
                }
                snapshotError = messages.isEmpty ? nil : messages.joined(separator: "\n")
            case .failure(let error):
                snapshotNotice = nil
                snapshotError = error.localizedDescription
            }
            snapshotting = false
        }
    }

    /// Patch 277. Recomputed on every render rather than stored: it is six
    /// counters over an array the screen already holds, and a cached copy
    /// would be the thing that goes stale after an import.
    private var coverage: TraceCoverage { DetailStore.shared.traceCoverage() }

    // MARK: - The nine, in one press — patch 333

    /// ONE BUTTON, ONE VERDICT, AND IT SURVIVES DONE.
    ///
    /// The nine sections below each answer their own question well. What none
    /// of them could answer is *are all nine green right now*, because the
    /// three expensive ones need a press, the six cheap ones ran when the
    /// screen opened, and every result died with the sheet.
    ///
    /// EVERY LINE UNCONDITIONAL, and the summary names three states rather
    /// than two: agreed, differed, and could not look. §12.15 — "eight of
    /// nine" is not a verdict when the ninth might not have been asked.
    @ViewBuilder
    private func rollUpSection(_ db: Sub4Database) -> some View {
        Section {
            if isExpanded("rollup") {
            if rollingUp {
                HStack { ProgressView(); Text("Reading all nine…").font(.caption) }
            } else {
                Button("Read everything back") { runRollUp(db) }
            }

            LabeledContent("Roll-up", value: rollUp.last.line)
                .font(.caption)
                .foregroundStyle(rollUp.last.isHealthy ? Color.dim : .red)

            // PATCH 333a. RED IS FOR A FAULT, not for an absence. A line
            // that compared nothing is dim and says so — it is unproven, not
            // broken, and a permanently red row is a row that stops being
            // read. §12.54.2 cuts both ways.
            ForEach(rollUp.last.lines) { l in
                // THE SHORT MARK — patch 389. A value-string swap, not a row:
                // this screen's budget is DEPTH and §12.76 has cost three
                // fix-ups. The paste carries which store and which slice.
                LabeledContent(l.name,
                               value: l.value
                                    + l.reads.screenMark(given: rollUp.last.sources))
                    .font(.caption2)
                    .foregroundStyle(l.isFault ? .red : Color.dim)
            }
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back roll-up",
                                        key: "rollup",
                                        expanded: $expanded,
                                        lines: { rollUp.last.diagnosticLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("rollup") {
            Text(Self.rollUpFooter).font(.caption2)
        }
        }
    }

    /// Runs all nine and records the verdict.
    ///
    /// It assigns the nine `@State` pairs as it goes, so the sections below
    /// show the same data the roll-up just judged. A roll-up that left the
    /// detail sections holding older numbers would be two answers to one
    /// question — §12.29's problem, on the screen that keeps finding it.
    private func runRollUp(_ db: Sub4Database) {
        rollingUp = true
        Task {
            var lines: [ReadBackRollUp.Line] = []

            let a = await ReadBacks.activities(db)
            roundTripLoad = a.load; roundTrip = a.report
            lines.append(ReadBackRollUp.line("Activities", a.report?.totalCompared,
                                   a.report?.unexplained,
                                   trustworthy: a.load.isTrustworthy && a.report != nil,
                                   reads: a.source, a.load.line))

            let d = await ReadBacks.details(db)
            detailLoad = d.load; detailTrip = d.report
            lines.append(ReadBackRollUp.line("Details", d.report?.totalCompared,
                                   d.report?.unexplained,
                                   trustworthy: d.load.isTrustworthy && d.report != nil,
                                   reads: d.source, d.load.line))

            let rec = await ReadBacks.recordings(db)
            recordingTrip = rec.report
            lines.append(ReadBackRollUp.line("Recordings", rec.report.totalCompared,
                                   rec.report.unexplained,
                                   trustworthy: rec.report.isTrustworthy,
                                   reads: rec.source, rec.report.line))

            let at = await ReadBacks.athlete(db)
            athleteLoad = at.load; athleteTrip = at.report
            lines.append(ReadBackRollUp.line("Athlete", at.report.totalCompared,
                                   at.report.unexplained,
                                   trustworthy: at.load.isTrustworthy,
                                   reads: at.source, at.load.line))

            let au = await ReadBacks.authored(db)
            authoredLoad = au.load; authoredTrip = au.report
            decisionLoad = au.decisions; moveLoad = au.moves
            lines.append(ReadBackRollUp.line("Notes and commutes", au.report.totalCompared,
                                   au.report.unexplained,
                                   trustworthy: au.load.isTrustworthy,
                                   reads: au.source, au.load.line))

            let pl = await ReadBacks.plan(db)
            planLoad = pl.load; planTrip = pl.report
            planExtrasLoad = pl.extrasLoad; planExtrasTrip = pl.extrasReport
            planCensus = await ReadBacks.planVersions(
                db, readerSessionCount: pl.report.sessionsInDatabase)
            lines.append(ReadBackRollUp.line("Plan", pl.report.totalCompared,
                                   pl.report.unexplained,
                                   trustworthy: pl.load.isTrustworthy,
                                   reads: pl.source, pl.load.line))
            lines.append(ReadBackRollUp.line("Plan trimmings", pl.extrasReport.totalCompared,
                                   pl.extrasReport.unexplained,
                                   trustworthy: pl.extrasLoad.isTrustworthy,
                                   reads: pl.source, pl.extrasLoad.line))

            let wg = await ReadBacks.weatherGear(db)
            weatherGearLoad = wg.load; weatherGearTrip = wg.report
            lines.append(ReadBackRollUp.line("Weather and gear", wg.report.totalCompared,
                                   wg.report.unexplained,
                                   trustworthy: wg.load.isTrustworthy,
                                   reads: wg.source, wg.load.line))

            let rv = await ReadBacks.review(db)
            reviewLoad = rv.load; reviewTrip = rv.report
            lines.append(ReadBackRollUp.line("Review trail", rv.report.totalCompared,
                                   rv.report.unexplained,
                                   trustworthy: rv.load.isTrustworthy,
                                   reads: rv.source, rv.load.line))

            // **`.live` IS ASKED FOR HERE AND NOWHERE ELSE ON THIS PATH** —
            // patch 389, §12.130.7's rule. Every store it consults has just
            // been read by the nine calls above, so this instantiates nothing
            // new; a `ReadBackRollUp` that reached for `.live` itself would
            // move that cost into every test that builds an outcome.
            rollUp.record(lines, sources: .live)
            rollingUp = false
        }
    }

    // THE ADAPTER MOVED TO `ReadBackRollUp` AT 341, unchanged. It lived here
    // as a private static on a view, which is why the function that shipped
    // 333's defect had no test until Stage A2 item 7 asked for one. See
    // `ReadBackRollUp.line` and `RollUpAdapterTests`. §12.89.

    private static let rollUpFooter =
        "Runs all nine read-backs in one press and keeps the answer. Every "
      + "record the migration wrote, read back out of the database and "
      + "compared field by field against the store it came from.\n\n"
      + "FOUR STATES, NOT TWO. A line can agree, disagree, fail to look, or "
      + "look and find nothing on either side. The last two are not the same "
      + "fact: a read that failed is a question nobody answered, and an empty "
      + "comparison is an answer that proves nothing. Zero compared to zero "
      + "agrees perfectly.\n\n"
      // PATCH 389a — THE SUMMARY GREW A FIFTH TERM AND THIS SENTENCE DID NOT.
      // 389 added `2 read a store the database feeds` to the line above and
      // left the paragraph below it enumerating four, so the screen printed
      // five terms and explained four. §12.128's own shape — a document beside
      // a number that does not describe it — in the patch whose whole subject
      // was a count nobody could read.
      + "THE FIFTH NUMBER IS NOT A FIFTH STATE. It counts how many rows "
      + "compared the database against something the database itself feeds. "
      + "Such a row still agreed, or differed, or could not look — the count "
      + "cuts across the four rather than joining them, and it is what tells "
      + "\"eight agreed\" from \"eight agreed, and two of them could not have "
      + "disagreed\". Each row says which it is: read the files itself, "
      + "self-referential, or taking a store nothing feeds yet — and the third "
      + "is the one that turns into the second the day its slice flips.\n\n"
      + "Only a difference or a failed read turns this red. An empty "
      + "comparison is counted on its own and left dim, because a row that is "
      + "permanently red is a row that stops being read — and because whether "
      + "an absence is acceptable is a decision for a person. Before D7 it is "
      + "not.\n\n"
      + "The result survives this sheet being closed and reaches the "
      + "diagnostics paste, which the nine sections below could never do — "
      + "their reports lived and died with the screen. ADR-0003 §12.80.\n\n"
      // PATCH 389a — 674 WAS TWENTY SHORT AND HAD BEEN SINCE 333. The device
      // holds 694 of each. The sample figure is COMPARISONS and this sentence
      // has always said so correctly; §5.6 and B4's groundwork read it as a row
      // count, which it is not — `recording_sample` holds 199,848.
      //
      // PATCH 392a — AND THE MAGNITUDE IS GONE, WHICH IS §12.127.5.
      //
      // 389a replaced "roughly 1.5 million" with "roughly 1.6 million", worked
      // out as eight series over 199,848 rows. The device says **1,453,877**:
      // not every recording carries all eight, so the multiplication was an
      // upper bound rather than a count, and the sentence it replaced had been
      // right for ninety-eight patches.
      //
      // *A sentence about what the data currently IS cannot be a constant.*
      // That is the rule this project bought at 383 and it applies here, in a
      // footer somebody reads as fact. The shape stays — every sample in every
      // series is what makes this the slow one — and the magnitude goes,
      // because since 391 the app PRINTS it two rows down and in the exported
      // file. A number the app computes has no business being typed out beside
      // it.
      + "The three activity read-backs are the slow part: 694 activities, "
      + "694 details, and every sample of every series inside 668 recordings — "
      + "the recording section counts them. During a backfill they will "
      + "legitimately report less than the store holds — check Traces still to "
      + "fetch first."

    // MARK: - What Strava has not sent yet — patch 331

    /// PATCH 331 — THE BACKLOG, VISIBLE WITHOUT PRESSING ANYTHING.
    ///
    /// Every figure here already existed. `TraceCoverage` has counted them
    /// since 277 and `DetailStore.backfillRemaining` has been `pending.count`
    /// since it was written — its own comment says "nothing has ever shown
    /// it". They were drawn inside `if let importReport`, so they existed only
    /// after somebody pressed Import in the current launch, and vanished with
    /// the sheet. That is §12.57's evaporation on a second screen: a true
    /// answer that a dismissal turns into no answer.
    ///
    /// It stopped being a readability point on 9 August. A reinstall emptied
    /// the phone, 674 activities came back from Strava in one sync and their
    /// details did not — the queue drains 30 per sync against Strava's 100
    /// requests per 15 minutes and 1,000 per day, so it is a two-day job. For
    /// those two days the only question that matters is "how many are left,
    /// and am I rate-limited right now", and the app could answer neither.
    ///
    /// UNCONDITIONAL, INCLUDING AT ZERO — §12.54.2, which this screen has now
    /// learned four times. The block used to be gated on `missing > 0`, so a
    /// finished backfill and a section nobody wired in looked identical. The
    /// whole point of a backlog row is to be read on the day it reaches zero.
    @ViewBuilder
    private var traceBacklogSection: some View {
        Section {
            if isExpanded("traces") {
            backlogHeadlineRows
            backlogAccountRows
        }
        } header: {
            DiagnosticSectionHeader(title: "Traces still to fetch",
                                        key: "traces",
                                        expanded: $expanded,
                                        lines: { traceBacklogLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("traces") {
            Text(Self.backlogFooter).font(.caption2)
        }
        }
    }

    /// The three rows somebody watching a backfill actually wants.
    @ViewBuilder
    private var backlogHeadlineRows: some View {
        // PATCH 333. THE CONTROL, BESIDE THE NUMBER.
        //
        // 331 made the backlog readable and left the only thing that moves it
        // on another screen — Settings, Strava, Check now. The predictable
        // happened within the hour: Import was pressed instead, which copies
        // the app's stores INTO the database and never speaks to Strava, so it
        // reported 0 new of everything and looked like a stall. A number with
        // no control beside it invites the nearest button.
        //
        // This calls the drain directly rather than a full sync, which also
        // saves the activity-list request a sync spends out of the same
        // hundred-per-fifteen-minutes.
        if detailStore.isFetching {
            HStack { ProgressView(); Text("Fetching…").font(.caption) }
        } else {
            Button("Fetch now") { DetailStore.shared.enqueueAndDrain() }
                .disabled(detailStore.backfillRemaining == 0
                          || Self.isLimited(detailStore.rateLimitedUntil))
        }

        LabeledContent("Still to fetch", value: "\(detailStore.backfillRemaining)")
            .font(.caption)
            .foregroundStyle(detailStore.backfillRemaining == 0 ? Color.dim : Color.ink)
        LabeledContent("Fetching now", value: detailStore.isFetching ? "yes" : "no")
            .font(.caption2).foregroundStyle(Color.dim)
        // NOT "no" WHEN IT IS NIL AND NOTHING ELSE — §12.15. A limit that has
        // expired and a limit that never happened are the same fact about now,
        // and the row says so in words rather than leaving the reader to infer
        // it from an absent line.
        LabeledContent("Rate limited", value: Self.rateLimitLine(detailStore.rateLimitedUntil))
            .font(.caption2)
            .foregroundStyle(Self.isLimited(detailStore.rateLimitedUntil) ? Color.ink : Color.dim)
    }

    /// PATCH 277's account, unchanged in substance.
    ///
    /// `activity: 668` and `recording: 645` sat four lines apart in the table
    /// list and nothing accounted for the difference — finding out what it was
    /// took reading `DetailStore`, which is not a thing a number on a screen
    /// should require.
    ///
    /// Every activity lands in exactly one bucket and the buckets sum to the
    /// total, so `unexplained` is the only line worth watching: it is zero
    /// today, and the day it is not is the day an activity has no trace for a
    /// reason nothing here has a name for.
    @ViewBuilder
    private var backlogAccountRows: some View {
        LabeledContent("Activities with no trace",
                       value: "\(coverage.missing) of \(coverage.total)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("  queued, not yet reached", value: "\(coverage.queued)")
            .font(.caption2).foregroundStyle(Color.dim)
        LabeledContent("  under 500 m, never asked", value: "\(coverage.belowThreshold)")
            .font(.caption2).foregroundStyle(Color.dim)
        LabeledContent("  asked, nothing there", value: "\(coverage.answeredEmpty)")
            .font(.caption2).foregroundStyle(Color.dim)
        LabeledContent("  the source refused it", value: "\(coverage.refused)")
            .font(.caption2).foregroundStyle(Color.dim)
        // RED WHEN IT IS NOT ZERO — the residual is the whole point of the
        // account, and a line that only appears when it is non-zero cannot be
        // told apart from a line nobody wired in.
        LabeledContent("  unexplained", value: "\(coverage.unexplained)")
            .font(.caption2)
            .foregroundStyle(coverage.isFullyExplained ? Color.dim : Color.red)
    }

    private static func isLimited(_ until: Date?) -> Bool {
        guard let until else { return false }
        return Date() < until
    }

    /// Local wall-clock, because the reader is deciding whether to press a
    /// button in the next ten minutes. `Date.FormatStyle` rather than a stored
    /// `DateFormatter`: a `static let DateFormatter` is a non-Sendable global
    /// and this project already carries two of those under
    /// `nonisolated(unsafe)`. A third is not worth a time of day.
    private static func clock(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    private static func rateLimitLine(_ until: Date?) -> String {
        guard let until else { return "no — not once this launch" }
        return Date() < until
            ? "yes — until \(clock(until))"
            : "no — last cleared at \(clock(until))"
    }

    private static let backlogFooter =
        "What Strava has not sent yet. Details and heart-rate traces arrive "
      + "one activity at a time, 30 per sync, and each costs up to two "
      + "requests — so a sync uses about 60 of Strava's 100 requests per 15 "
      + "minutes. The daily ceiling is 1,000 requests, which is the number "
      + "that decides how long a full backfill takes; a bigger batch would "
      + "mean fewer presses, not more activities in a day.\n\n"
      + "Still to fetch is the queue. It reaches zero when the backfill is "
      + "done, and this section keeps saying zero rather than disappearing, "
      + "because a section that vanishes when it is finished cannot be told "
      + "from one nobody wired in.\n\n"
      + "It counts activities missing a DETAIL or a TRACE. Queued, not yet "
      + "reached below counts only those missing a trace — so the two differ "
      + "by the activities whose detail has landed and whose trace has not, "
      + "and that difference is not an error.\n\n"
      + "The five rows under Activities with no trace are an account, not a "
      + "list: every activity lands in exactly one of them and they sum to "
      + "the total. Under 500 m is never asked at all — a strength session "
      + "has no distance axis to plot. Unexplained is the residual, and the "
      + "day it is not zero is the day an activity has no trace for a reason "
      + "this screen has no name for. ADR-0003 §12.77."

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
                let at = Sub4Import.iso8601(Date())
                let report = try Sub4Import.run(
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
                    trigger: .manual,
                    // PATCH 406 — THE OTHER CALLER THAT HAS AN ANSWER. A KIND
                    // of change, never a record: §12.7 holds because this is a
                    // literal in the source, and `causeIsAConstantSentence`
                    // keeps every one of them so.
                    cause: "Import and verify was pressed")
                lastImport.record(report, trigger: .manual, atUTC: at)
                await recheck(db)
                await reloadLedger(db)
                // PATCH 370 — THE TAP THAT WRITES CHECKS WHAT IT WROTE.
                //
                // AFTER `reloadLedger`, and that is not tidiness:
                // `verifyNewestRun` marks `lastRun`, which this call is what
                // sets. Before it, the run being blessed would be the previous
                // one — which `SemanticVerifier.record` would refuse, correctly
                // and confusingly.
                //
                // ONLY HERE. Backgrounded, foregrounded and authored runs reach
                // the importer by other paths and are untouched: the verifier
                // reads 8 187 splits and 198 948 trace samples, and 39 authored
                // runs happened in one afternoon this week. The cost belongs on
                // the deliberate tap.
                await verifyNewestRun(db)
            } catch {
                importError = String(describing: error)
                lastImport.recordFailure(String(describing: error),
                                         atUTC: Sub4Import.iso8601(Date()))
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
            if isExpanded("benchmark") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Benchmark",
                                        key: "benchmark",
                                        expanded: $expanded,
                                        lines: { benchmark.result?.diagnosticLines ?? ["Benchmark: not run"] },
                                        shared: $shared)
        } footer: {
            if isExpanded("benchmark") {
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
            if isExpanded("verification") {
            if verifying {
                HStack { ProgressView(); Text("Comparing…").font(.caption) }
            } else {
                Button("Verify against the app's stores") { runVerify(db) }
            }

            if let v = verification.last.report {
                LabeledContent("Verdict",
                               value: v.passed ? "everything agreed"
                                               : "\(v.failures.count) disagreed")
                    .font(.caption)
                    .foregroundStyle(v.passed ? Color.dim : .red)
                // PATCH 354 — §12.99. A SWAPPED ROW, NOT AN ADDED ONE, for
                // the reason stated three lines down: this screen's budget is
                // depth. "20 things" was true and told nobody that one of them
                // could not fail.
                LabeledContent("Compared",
                               value: "\(v.checks.count) · "
                                    + "\(v.independentChecks.count) independent")
                    .font(.caption)
                    .foregroundStyle(v.independentChecks.isEmpty
                                     ? .red : Color.dim)
                // THE SAME ROW COUNT AS BEFORE. This screen's budget is DEPTH
                // and a `@ViewBuilder` block is built pairwise, so swapping a
                // row is free and adding one is not. §12.76.
                LabeledContent("Ledger", value: verification.last.ledgerLine)
                    .font(.caption2)
                    .foregroundStyle(verification.last.ledgerAgreed
                                     ? Color.dim : .red)

                ForEach(v.checks) { check in
                    // PATCH 354. The label is swapped, not a row added. A
                    // self-referential check draws the same tick as a real one
                    // and means something entirely different.
                    // 387 — THE ANSWER MOVED, THE ROW DID NOT. This read
                    // `HydratedStores.entry(for:)`; it now asks the check
                    // itself, against what this build is serving. Still a label
                    // swap, so the screen's DEPTH does not move. §12.76.
                    LabeledContent(check.isSelfReferential(given: v.sources)
                                   ? "  \(check.name) — self-referential"
                                   : "  \(check.name)",
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Verification",
                                        key: "verification",
                                        expanded: $expanded,
                                        lines: { verification.last.diagnosticLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("verification") {
            Text("Compares the database against the app's own stores: counts, "
                 + "which activities are there, the fields of every one, and a "
                 + "few figures the app actually shows. The last import is "
                 + "marked verified only if every comparison agrees AND at "
                 + "least one of them could have disagreed.\n\n"
                 + "A comparison reading a store the database now feeds is "
                 + "the database agreeing with itself. B1 made that true of "
                 + "the heart-rate zones; B9 will make it true of everything, "
                 + "and at that point nothing here can be marked verified — "
                 + "ADR-0003 §12.99.")
                .font(.caption2)
        }
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
            if isExpanded("readback-activities") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back",
                                        key: "readback-activities",
                                        expanded: $expanded,
                                        lines: { roundTrip?.diagnosticLines ?? ["Activity read-back: \(roundTripLoad?.line ?? "not read")"] },
                                        shared: $shared)
        } footer: {
            if isExpanded("readback-activities") {
            Text("Reads every activity out of the database through "
                 + "ActivityRepository and compares it, field by field, to the "
                 + "one the app is running on. This is the question D6c asks of "
                 + "everything, asked of one table now. Nothing is written.")
                .font(.caption2)
        }
        }
    }

    /// PATCH 291. The same shape as the activity read-back, one level down.
    @ViewBuilder
    private func detailReadBackSection(_ db: Sub4Database) -> some View {
        Section {
            if isExpanded("readback-details") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back · details",
                                        key: "readback-details",
                                        expanded: $expanded,
                                        lines: { detailTrip?.diagnosticLines ?? ["Detail read-back: \(detailLoad?.line ?? "not read")"] },
                                        shared: $shared)
        } footer: {
            if isExpanded("readback-details") {
            Text("The same comparison one level down: splits, laps and best "
                 + "efforts, matched by index and by name rather than by "
                 + "position. A heart rate the importer normalised to nothing "
                 + "is expected to show here, as one row rather than one per "
                 + "lap — see ADR-0003 §12.37 and §12.40.")
                .font(.caption2)
        }
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
            if isExpanded("readback-recordings") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back · recordings",
                                        key: "readback-recordings",
                                        expanded: $expanded,
                                        lines: { recordingTrip?.diagnosticLines ?? ["Recording read-back: not read"] },
                                        shared: $shared)
        } footer: {
            if isExpanded("readback-recordings") {
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
    }

    private func runRecordingReadBack(_ db: Sub4Database) {
        readingBackRecording = true
        Task {
            // OFF the main actor, unlike the two above — 645 read transactions
            // and ~1.5 million comparisons. See `compareOffMain`.
            recordingTrip = await ReadBacks.recordings(db).report
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
            if isExpanded("readback-athlete") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back · athlete",
                                        key: "readback-athlete",
                                        expanded: $expanded,
                                        lines: { athleteTrip?.diagnosticLines ?? ["Athlete read-back: \(athleteLoad?.line ?? "not read")"] },
                                        shared: $shared)
        } footer: {
            if isExpanded("readback-athlete") {
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
            if isExpanded("readback-authored") {
            // PATCH 400 — ONE CHILD, NOT FOUR. §12.76's budget is DEPTH, and
            // 331 is the precedent: a group of rows behind a `@ViewBuilder`
            // function adds one link to the chain rather than one per row.
            // The button, its error and its two receipts are inside it.
            authoredRestoreRows
            if let load = authoredLoad {
                // PATCH 355 — A SWAPPED ROW, NOT AN ADDED ONE (§12.76). Both
                // reads are one sentence because they are one read-back, and
                // the decisions' own `line` says its skipped count.
                // PATCH 364 — A THIRD SENTENCE IN THE SAME ROW, not a fourth
                // row. §12.76: this screen's budget is depth, and the three
                // reads are one read-back.
                LabeledContent("The read",
                               value: load.line + " "
                                    + (decisionLoad?.line ?? "Not read.") + " "
                                    + (moveLoad?.line ?? "Not read."))
                    .font(.caption)
                    .foregroundStyle(load.isTrustworthy
                                     && (decisionLoad?.isTrustworthy ?? false)
                                     && (moveLoad?.isTrustworthy ?? false)
                                     ? Color.dim : .red)
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back · authored",
                                        key: "readback-authored",
                                        expanded: $expanded,
                                        lines: { (authoredTrip?.diagnosticLines ?? ["Authored read-back: \(authoredLoad?.line ?? "not read")"]) + authoredRestoreLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("readback-authored") {
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
    /// PATCH 352 — every stored version, and the only destructive button on
    /// this screen. ADR-0003 §12.97.
    ///
    /// A DIFFERENT CLAIM FROM THE READ-BACK ABOVE IT, which is why it is its
    /// own section. The read-back says the ACTIVE version inverts its
    /// decomposition. This says how many versions exist, which of them hold
    /// identical training, which session uids would leave with a delete, and
    /// how many of those something else names.
    ///
    /// THE BUTTON IS DISABLED WHEN THERE IS NOTHING TO REMOVE and the rows
    /// above it are what says why. `Last prune` prints "not run" rather than
    /// disappearing — §12.15, and the same argument the paste makes.
    @ViewBuilder
    private func planVersionSection(_ db: Sub4Database) -> some View {
        Section {
            if isExpanded("plan-versions") {
            if let c = planCensus {
                LabeledContent("Stored", value: c.line)
                    .font(.caption)
                    .foregroundStyle(c.readFailure == nil ? Color.dim : .red)
                LabeledContent("Agrees with the read-back", value: c.agreementLine)
                    .font(.caption2)
                    .foregroundStyle(c.agreesWithReader == false ? .red : Color.dim)
                LabeledContent("Session uids, all versions",
                               value: "\(c.allSessionUIDs.count)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("  in the active version",
                               value: "\(c.activeVersion?.sessionUIDs.count ?? 0)")
                    .font(.caption2).foregroundStyle(Color.dim)
                LabeledContent("Proposals naming no stored session",
                               value: "\(c.danglingReferences.count)")
                    .font(.caption2)
                    .foregroundStyle(c.danglingReferences.isEmpty ? Color.dim : .red)

                ForEach(c.versions, id: \.id) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("[\(v.short)]" + (v.isActive ? " · active" : "")
                             + " · " + v.importedUTC)
                            .font(.caption.weight(.semibold))
                        Text(v.rowLine)
                            .font(.caption2).foregroundStyle(Color.dim)
                        Text("fingerprint \(String(v.fingerprint.prefix(12)))"
                             + " · uids only here \(c.uidsHeldOnlyBy(v).count)")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                }

                LabeledContent("Removable", value: "\(c.removableCount)")
                    .font(.caption)
                    .foregroundStyle(c.removableCount == 0 ? Color.dim : .orange)
                Button("Remove duplicate versions", role: .destructive) {
                    // OFF THE MAIN ACTOR, like every other write this screen
                    // starts. A cascade over three thousand rows is fast and
                    // is still not this actor's work — and `reloadPlan` after
                    // it is what makes the rows above redraw from the
                    // database rather than from what was true before.
                    Task {
                        planPrune = await Task.detached(priority: .userInitiated) {
                            PlanVersionPrune.run(db)
                        }.value
                        await reloadPlan(db)
                    }
                }
                .font(.caption)
                .disabled(c.removableCount == 0)
                LabeledContent("Last prune", value: planPrune.line)
                    .font(.caption2).foregroundStyle(Color.dim)
            } else {
                HStack { ProgressView(); Text("Counting versions…").font(.caption) }
            }
        }
        } header: {
            DiagnosticSectionHeader(title: "The plan's versions",
                                        key: "plan-versions",
                                        expanded: $expanded,
                                        lines: { planCensus?.diagnosticLines ?? ["Plan versions: not counted"] },
                                        shared: $shared)
        } footer: {
            if isExpanded("plan-versions") {
            Text("A stored version is a full copy of one plan. Four of them is "
                 + "not four copies of the same thing: every revision writes "
                 + "one, and the older ones are what a note or a proposal "
                 + "written against a since-renamed session still resolves "
                 + "against — ADR-0003 §12.7 and §12.11.\n\n"
                 + "The fingerprint is taken over the stored rows with their "
                 + "row ids dropped, which is what `contentHash` cannot do: "
                 + "that hash is over the imported file and changes when the "
                 + "same plan arrives in a different array order — §12.93.3, "
                 + "which is where the removable version came from.\n\n"
                 + "The button deletes only a version whose training another "
                 + "stored version still holds, byte for byte. Nothing it "
                 + "removes can orphan a reference, because every uid it "
                 + "carries survives in its twin.")
                .font(.caption2)
        }
        }
    }

    @ViewBuilder
    private var planReadBackSection: some View {
        Section {
            if isExpanded("readback-plan") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back · the plan",
                                        key: "readback-plan",
                                        expanded: $expanded,
                                        lines: { planReadBackLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("readback-plan") {
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
    }

    /// Same shape as `reloadAuthored`: the read off the main actor, the
    /// comparison on it, because `PlanStore` is a main-actor singleton.
    private func reloadPlan(_ db: Sub4Database) async {
        let r = await ReadBacks.plan(db)
        planLoad = r.load
        planTrip = r.report
        planExtrasLoad = r.extrasLoad
        planExtrasTrip = r.extrasReport
        // PATCH 352. HERE AS WELL AS IN THE ROLL-UP, and for the reason
        // `onChange(of: writeThrough.runs)` reloads six things: a screen left
        // open across an import would otherwise keep describing the versions
        // as they were before it — which is the exact shape of the defect that
        // once made the run trigger look dead.
        planCensus = await ReadBacks.planVersions(
            db, readerSessionCount: r.report.sessionsInDatabase)
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
    /// **IT HAS A BUTTON SINCE 374, AND THIS LINE USED TO SAY IT DID NOT.**
    ///
    /// §12.54.2 cuts both ways: a screen that stops describing itself is the
    /// defect whether the drift is in a row or in the note above it. The rows
    /// stay unconditional; what changed is that the section which REPORTS the
    /// discrepancy now offers the repair.
    ///
    /// Here rather than on Data controls, because "only in the database: 601"
    /// and the button that acts on it belong in one place — a repair the
    /// athlete has to go looking for is one he takes at the wrong moment. The
    /// weather row over there gains a sentence pointing at this.
    @ViewBuilder
    private func weatherGearReadBackSection(_ db: Sub4Database) -> some View {
        Section {
            if isExpanded("readback-weather-gear") {
            // PATCH 374. First in the section, like `Import and verify`: the
            // action, then the numbers that justify it.
            if restoringWeather {
                HStack { ProgressView(); Text("Restoring…").font(.caption) }
            } else {
                Button("Restore weather from the database") { runWeatherRestore(db) }
                    .font(.caption)
            }

            if let e = weatherRestoreError {
                Text(e).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // UNCONDITIONAL ONCE IT HAS RUN, and the zero cases are worth as
            // much as the others: "added 0, already held 602" is the store
            // agreeing with the database, and "added 0, already held 0" is a
            // database with no weather in it. §12.15.
            if let r = lastWeatherRestore {
                LabeledContent("Restored", value: r.line)
                    .font(.caption).foregroundStyle(Color.dim)
                if let aside = r.setAside {
                    Text("The unreadable file was kept as "
                         + aside.lastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back · weather and gear",
                                        key: "readback-weather-gear",
                                        expanded: $expanded,
                                        lines: { (weatherGearTrip?.diagnosticLines ?? ["Weather and gear read-back: \(weatherGearLoad?.line ?? "not read")"]) + weatherRestoreLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("readback-weather-gear") {
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
    }

    /// Same shape as `reloadPlan`: the read off the main actor, the comparison
    /// on it, because all three stores it reaches are main-actor singletons.
    ///
    /// The activity roster goes in as a `Set` so the comparison can tell a
    /// reading the database refused from a reading it lost.
    private func reloadWeatherGear(_ db: Sub4Database) async {
        let r = await ReadBacks.weatherGear(db)
        weatherGearLoad = r.load
        weatherGearTrip = r.report
    }

    /// PATCH 374, §12.118.
    ///
    /// **IT READS THE DATABASE AGAIN RATHER THAN USING `weatherGearLoad`.**
    /// That value was read when the screen appeared and an import may have run
    /// since; a write must act on what is there now, not on what was displayed.
    /// The cost is one read of a table this screen already reads on appear.
    ///
    /// The read-back is refreshed afterwards so the counts underneath describe
    /// the store as it is now — otherwise the section reports "only in the
    /// database: 601" directly beneath a line saying 601 were just added.
    /// **PATCH 402, §12.146.** One builder, two readers — the section's own
    /// export and the whole-screen paste — so the two cannot disagree about
    /// what a restore did. Before this, neither carried it at all.
    private var authoredRestoreLines: [String] {
        StoreRestore.lines(lastAuthoredRestore, failures: authoredRestoreFailures,
                           subject: "Authored")
    }

    private var weatherRestoreLines: [String] {
        StoreRestore.lines(lastWeatherRestore.map { [$0] } ?? [], failures: [],
                           subject: "Weather")
    }

    /// **THE ACTION §5.5 CALLED THE LARGEST OPEN RISK — patch 400, §12.144.**
    ///
    /// First in the section, like `Import and verify` and like the weather
    /// restore: the action, then the numbers that justify it.
    ///
    /// TWO STORES, ONE TAP, TWO RECEIPTS. `notes.json` and `commutes.json`
    /// come out of one read and are two files, so they get two lines — "added
    /// 4" over both would leave a reader unable to say which one was empty.
    @ViewBuilder
    private var authoredRestoreRows: some View {
        if restoringAuthored {
            HStack { ProgressView(); Text("Restoring…").font(.caption) }
        } else {
            Button("Restore notes, commutes and moves from the database") {
                runAuthoredRestore()
            }
            .font(.caption)
            // DISABLED UNTIL THE READ HAS HAPPENED, because the restore reads
            // the load this section is already showing — offering it before
            // there is one would throw `databaseUnreadable` at somebody who
            // did nothing wrong.
            .disabled(authoredLoad == nil)
        }

        ForEach(authoredRestoreFailures, id: \.store) { f in
            Text(f.line).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        // UNCONDITIONAL ONCE IT HAS RUN, and the zero cases are worth as much
        // as the others: "added 0, already held 5" is the file agreeing with
        // the database, and "added 0, already held 0" is a database with
        // nothing in it. §12.15.
        ForEach(lastAuthoredRestore, id: \.store) { r in
            LabeledContent("Restored", value: r.line)
                .font(.caption).foregroundStyle(Color.dim)
            if let aside = r.setAside {
                Text("The unreadable file was kept as \(aside.lastPathComponent)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// **NO DATABASE ARGUMENT, AND THAT IS DELIBERATE.** It restores from
    /// `authoredLoad` — the very load whose counts are on screen two rows
    /// below — so the receipt and the numbers that justified pressing the
    /// button describe the same read. The weather restore re-reads because its
    /// section was built before that load was held; copying that here would
    /// mean the screen could say 5 notes and the restore act on 4.
    /// **EACH STORE IS TRIED, AND EACH GETS AN OUTCOME — patch 404.**
    ///
    /// The first version stopped at the first throw. Three independent files
    /// make that wrong: a notes problem has nothing to do with `moves.json`,
    /// and stopping leaves the rest untried AND unreported — so a reader cannot
    /// tell *moves was fine* from *moves was never attempted*. §12.15.
    ///
    /// So every store is attempted, receipts and failures are collected side by
    /// side, and the paste carries both.
    private func runAuthoredRestore() {
        guard let load = authoredLoad else { return }
        restoringAuthored = true
        lastAuthoredRestore = []
        authoredRestoreFailures = []

        func attempt(_ store: String,
                     _ body: () throws -> StoreRestore.Receipt) {
            do {
                lastAuthoredRestore.append(try body())
            } catch let fault as AuthoredRestoreFault {
                authoredRestoreFailures.append(.init(store: store, why: fault.line))
            } catch let write as StoreWriteError {
                authoredRestoreFailures.append(
                    .init(store: store, why: write.reason))
            } catch {
                authoredRestoreFailures.append(
                    .init(store: store, why: error.localizedDescription))
            }
        }

        attempt("notes.json") { try NotesStore.shared.restore(from: load) }
        attempt("commutes.json") { try CommuteStore.shared.restore(from: load) }
        // MOVES READS ITS OWN LOAD. `AuthoredLoad` carries notes and commutes;
        // `moves.json` comes from `PlanMoveRepository`, which the screen has
        // already read into `moveLoad` for the row two below. Using it means
        // the receipt and the count on screen describe the same read.
        if let moves = moveLoad {
            attempt("moves.json") { try PlanMoveStore.shared.restore(from: moves) }
        } else {
            authoredRestoreFailures.append(
                .init(store: "moves.json", why: "the read has not run yet"))
        }
        restoringAuthored = false
    }

    private func runWeatherRestore(_ db: Sub4Database) {
        restoringWeather = true
        weatherRestoreError = nil
        Task {
            defer { restoringWeather = false }
            do {
                // OFF THE MAIN ACTOR — patch 376, §12.120.2. 374 called this
                // synchronously inside a Task that is already main-actor, so a
                // whole-table read ran on the main thread. This is
                // `ReadBacks.weatherGear`'s line, unchanged, reading the same
                // table one section below.
                let stored = await Task.detached(priority: .utility) {
                    WeatherGearRepository.load(db)
                }.value
                lastWeatherRestore = try WeatherStore.shared.restore(from: stored)
                await reloadWeatherGear(db)
            } catch {
                weatherRestoreError = error.localizedDescription
            }
        }
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
      + "TWO approved differences since patch 337, and the one that went was "
      + "Record.id. It claimed the app's key and the database's key could "
      + "differ harmlessly; on 9 August two reviews written in the same second "
      + "proved otherwise, and one review's evidence and proposal were "
      + "overwritten by the other's. review.recordKey now carries the app's "
      + "own record id, and the run time is an ordinary field. Two rows here "
      + "show it landed: paired by record key, and paired by run time — the "
      + "second is the one-import fallback for rows written before the "
      + "migration and should read zero afterwards.\n\n"
      + "Two records sharing a run time is no longer a fault and is no longer "
      + "red. It is still counted, because that count is what found the loss.\n\n"
      + "The lineage is written since patch 335 — one row per source the "
      + "review builder consults, so ADR-0002's purge has something to query. "
      + "It reads zero until a review exists, which before 24 August 2026 "
      + "means it reads zero unless the rehearsal has been run. ADR-0003 "
      + "§12.71, §12.83 and §12.85."

    @ViewBuilder
    private var reviewReadBackSection: some View {
        Section {
            if isExpanded("readback-reviews") {
            // PATCH 353 — §12.98. FIRST IN THE SECTION, because it changes
            // what every count below it means: six of the six reviews compared
            // are rehearsals, and a reader who does not know that reads this
            // section as six months of work round-tripping.
            let rehearsals = ReviewDue.rehearsals(
                in: ProposalStore.shared.records).count
            LabeledContent("Rehearsals stored", value: "\(rehearsals)")
                .font(.caption)
                .foregroundStyle(rehearsals == 0 ? Color.dim : .orange)
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
                Self.reviewKeyRows(r)
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
                // PATCH 335b. STILL NOT A COUNT — BUT A DIFFERENT STATEMENT.
                //
                // Until 335 this read "0 — nothing writes this table", which
                // was true and is now false: `Sub4Import+Authored` writes one
                // row per source in `ReviewLineage`. 335 wrote the writer and
                // left the sentence describing its absence, which is §12.15
                // pointing the other way — a zero with a confident and wrong
                // explanation is worse than a bare one.
                //
                // THREE ZEROS THAT ARE NOT THE SAME ZERO, and only the middle
                // one is a fault: no review yet (correct, and the state until
                // 24 August), reviews stored but no lineage (the writer did
                // not run), and rows present (what it should say).
                LabeledContent("Lineage rows", value: Self.lineageLine(r))
                    .font(.caption2)
                    .foregroundStyle(Self.lineageIsAFault(r) ? .red : Color.dim)
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Read-back · reviews",
                                        key: "readback-reviews",
                                        expanded: $expanded,
                                        lines: { reviewTrip?.diagnosticLines ?? ["Review read-back: \(reviewLoad?.line ?? "not read")"] },
                                        shared: $shared)
        } footer: {
            if isExpanded("readback-reviews") {
            // HOISTED TO A CONSTANT — patch 327a, same reason `diagnosticLines`
            // stopped being one array literal. A footer built from eleven `+`
            // concatenations is one expression, and this file already carries
            // the largest `body` in the project.
            Text(Self.reviewFooter)
                .font(.caption2)
        }
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
        let r = await ReadBacks.review(db)
        reviewLoad = r.load
        reviewTrip = r.report
    }

    /// Same shape as `reloadAthlete`: the read off the main actor, the
    /// comparison on it, because the stores it compares against are main-actor
    /// singletons.
    private func reloadAuthored(_ db: Sub4Database) async {
        let r = await ReadBacks.authored(db)
        authoredLoad = r.load
        authoredTrip = r.report
        // PATCH 355. HERE AS WELL AS IN THE ROLL-UP, for the reason
        // `onChange(of: writeThrough.runs)` reloads six things: a screen left
        // open across an import would otherwise keep describing the decisions
        // as they were before it.
        decisionLoad = r.decisions
        moveLoad = r.moves
    }

    /// The read off the main actor, the comparison on it — the stores it
    /// compares against are main-actor singletons and the database read is not
    /// this screen's to block on, however small it is.
    private func reloadAthlete(_ db: Sub4Database) async {
        // PATCH 333. The read moved to `ReadBacks`; this is one of its two
        // callers. §12.43 — the roll-up runs the same nine.
        let r = await ReadBacks.athlete(db)
        athleteLoad = r.load
        athleteTrip = r.report
    }

    /// PATCH 335b. Which of the three zeros this is.
    ///
    /// `evidenceSourceRows` counts the whole table. Zero means *no review has
    /// been stored yet* when the database holds none — the correct state until
    /// 24 August — and means *the writer did not run* when it holds some. One
    /// number, two facts, and only the second is a defect.
    /// PATCH 337 — FIVE ROWS WHERE ONE STOOD, AND NET ZERO CHILDREN in the
    /// caller's block. §12.76: the review section's `@ViewBuilder` is already
    /// near its depth budget, so the row this replaces is swapped for one
    /// function rather than four more siblings.
    ///
    /// WHAT EACH ROW IS FOR
    /// --------------------
    /// The first two are the pairing rules, both printed, because "5 paired"
    /// cannot tell a device that has adopted the new key from one that has
    /// not. `by run time` and `awaiting a key` are the pre-337 state; both go
    /// to zero after one import and stay there.
    ///
    /// `awaiting a key` is amber rather than red: before the first import
    /// after 337 it is the correct and expected answer, and a row that is red
    /// while it is right is a row its reader learns to ignore — §12.40.1
    /// measured that cost once already.
    ///
    /// The run-time row IS NO LONGER RED AT ANY VALUE. It was red because the
    /// run time was the key; it is not, and the honest reading of two records
    /// in one second is now "that happened" rather than "something is wrong".
    /// The two key-collision rows below it are the ones that cannot fire
    /// without a bug, and those are red.
    @ViewBuilder
    private static func reviewKeyRows(_ r: ReviewRoundTrip.Report) -> some View {
        LabeledContent("Paired by record key", value: "\(r.pairedByRecordKey)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("  paired by run time, not yet keyed",
                       value: "\(r.pairedByRunTime)")
            .font(.caption2).foregroundStyle(Color.dim)
        LabeledContent("Rows awaiting a record key",
                       value: "\(r.reviewsAwaitingAKey)")
            .font(.caption)
            .foregroundStyle(r.reviewsAwaitingAKey == 0 ? Color.dim : .orange)
        LabeledContent("App records sharing a run time",
                       value: "\(r.duplicateRunTimes.count)")
            .font(.caption).foregroundStyle(Color.dim)
        LabeledContent("Records or rows sharing a record key",
                       value: "\(r.duplicateRecordKeys.count + r.duplicateStoredKeys.count)")
            .font(.caption)
            .foregroundStyle(r.duplicateRecordKeys.isEmpty
                             && r.duplicateStoredKeys.isEmpty ? Color.dim : .red)
    }

    private static func lineageLine(_ r: ReviewRoundTrip.Report) -> String {
        if r.evidenceSourceRows > 0 {
            return "\(r.evidenceSourceRows) — one per source in ReviewLineage"
        }
        return r.reviewsInDatabase == 0
            ? "0 — no review stored yet"
            : "0 — but \(r.reviewsInDatabase) reviews are stored"
    }

    /// Red only for the middle case. A row that is permanently red until
    /// August is a row that stops being read.
    private static func lineageIsAFault(_ r: ReviewRoundTrip.Report) -> Bool {
        r.evidenceSourceRows == 0 && r.reviewsInDatabase > 0
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
        Task {
            let r = await ReadBacks.details(db)
            detailLoad = r.load
            detailTrip = r.report
            readingBackDetail = false
        }
    }

    private func runReadBack(_ db: Sub4Database) {
        readingBack = true
        Task {
            let r = await ReadBacks.activities(db)
            roundTripLoad = r.load
            roundTrip = r.report
            readingBack = false
        }
    }

    private func runVerify(_ db: Sub4Database) {
        Task { await verifyNewestRun(db) }
    }

    /// **ONE VERIFICATION, TWO CALLERS — patch 370.**
    ///
    /// The button below and the import above. Copying these forty lines would
    /// have been the obvious way and the wrong one: the `else if` chain encodes
    /// 354's ordering — `noIndependentEvidence` BEFORE `notTheNewestRun`,
    /// because a passing-but-withheld report reported as a ledger-ordering
    /// problem sends somebody to press Import. A second copy is a second place
    /// for that order to be got wrong, silently. §12.43.
    ///
    /// IT DOES NOT DECIDE ANYTHING. `SemanticVerifier.record` refuses or
    /// marks; this reads which happened and says so. That was true when the
    /// code lived in the button and is worth restating now that two things
    /// call it.
    private func verifyNewestRun(_ db: Sub4Database) async {
        verifying = true
        defer { verifying = false }
        // The same gathered value the import uses — 301. The verifier
        // reads a subset of it on purpose; see the overload's comment.
        let report = SemanticVerifier.attempt(db, stores: AppStores.current())
        // A passing run moves the ledger to `verified`. A failing one
        // leaves it where it is — `SemanticVerifier.record` is what
        // refuses, not this screen.
        //
        // PATCH 340. The four sentences moved into
        // `VerificationResult.Ledger` unchanged. They are the same words;
        // what is new is that they have a type, so a test can assert each
        // one and the paste can print it after this sheet is gone.
        if let runID = lastRun?.id {
            let outcome: VerificationResult.Ledger
            do {
                let moved = try SemanticVerifier.record(report, for: runID, in: db)
                if moved {
                    outcome = .marked
                } else if !report.passed {
                    outcome = .reportDidNotPass
                } else if let why = report.withheldReason {
                    // PATCH 354 — §12.99. BEFORE `notTheNewestRun`, and the
                    // order is the whole point: `record` now refuses on
                    // `isTrustworthyEvidence`, so a passing report that was
                    // withheld would otherwise be reported as a ledger
                    // ordering problem and send somebody to press Import.
                    outcome = .noIndependentEvidence(why)
                } else {
                    outcome = .notTheNewestRun
                }
            } catch {
                outcome = .failed(String(describing: error))
            }
            verification.record(report, ledger: outcome)
            await reloadLedger(db)
        } else {
            verification.record(report, ledger: .noRun)
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
            if isExpanded("app-files") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "The app's own files",
                                        key: "app-files",
                                        expanded: $expanded,
                                        lines: { storeFileLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("app-files") {
            Text("Reads every file the app has written and classifies it: "
                 + "readable, missing, interrupted part way, or holding a "
                 + "record that is filed under one name and claims another. "
                 + "Nothing is changed and nothing is held back — this patch "
                 + "only looks.")
                .font(.caption2)
        }
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
            // PATCH 332. A SECOND BUTTON, NOT A REPLACEMENT.
            //
            // The paste is the fast path when the Mac is in reach of the
            // clipboard; this one is for when it is not. It ships a FILE, so
            // AirDrop, Save to Files and Mail all appear, and the name carries
            // the day and the patch — which is worth more than the transport,
            // because a capture that names its own build is a capture that can
            // still be read next week. §12.79.
            // PATCH 341. TWO BUTTONS IN ONE CHILD, not two children.
            // This screen's budget is DEPTH and a `@ViewBuilder` block is
            // built pairwise, so a group costs nothing and a sibling costs a
            // level. §12.76, which this screen has now learned three times.
            exportButtons
            if shareFailed {
                Text("The file could not be written. Copy diagnostics still works.")
                    .font(.caption2).foregroundStyle(.red)
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
                 + "from the survey — it is safe to paste into a message.\n\n"
                 + "Share writes the same text to a dated file and hands it to "
                 + "the system sheet — AirDrop to a Mac, Save to Files, or "
                 + "attach it to a message. The file is temporary; the numbers "
                 + "in it are not stored anywhere.")
                .font(.caption2)
        }
    }

    /// The two things that leave the phone — patch 341.
    ///
    /// The diagnostics file is counts about the data. The authored export is
    /// the data: `notes.json`, `commutes.json`, `moves.json`,
    /// `proposals.json`, `athlete.json` and `constants.json` — the stores no
    /// source can send again. SIX SINCE 362, and this sentence said five until
    /// 363; the list it describes lives in `AuthoredExport.stores`, which is
    /// the thing to read rather than this. On 9 August a hand-delete took all of them AND the protected
    /// snapshot that held them, because the snapshot lives inside the
    /// container. Stage A1 item 5 exists for exactly that, and until now it
    /// could only be done by downloading the whole container from Xcode.
    @ViewBuilder
    private var exportButtons: some View {
        Button("Share diagnostics") {
            shared = writeDiagnostics().map(ShareItem.init(url:))
        }
        Button("Export the notes and decisions") {
            writeAuthoredExport()
        }
        if let authoredExported {
            Text(authoredExported).font(.caption2).foregroundStyle(Color.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Builds the authored export and hands it to the share sheet.
    ///
    /// The summary is counts only — a handful of small files, and a note's
    /// text is the athlete writing about his own training. §12.7 applies to
    /// this screen's captions as much as to the paste.
    ///
    /// NO NUMBER IN THE SENTENCE. It said "five" and went wrong the first time
    /// an authored store was added; the summary itself counts
    /// `AuthoredExport.stores`, which is where the answer belongs.
    private func writeAuthoredExport() {
        authoredExported = nil
        let document = AuthoredExport.build(appVersion: AppVersion.patchLabel)
        do {
            let url = try AuthoredExport.write(document, day: Self.exportDay())
            shared = ShareItem(url: url)
            authoredExported = "Exported \(document.summary)."
        } catch {
            shareFailed = true
            authoredExported = "The export could not be written."
        }
    }

    /// `yyyyMMdd`, for the filename. Its own formatter rather than `DayKey`'s,
    /// which is `nonisolated(unsafe)` and documented as never to be mutated.
    private static func exportDay(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: now)
    }

    /// PATCH 332. Written on the press, never on a redraw.
    ///
    /// `ShareSheet` rather than SwiftUI's `ShareLink`, and `ShareSheet.swift`
    /// says why in its own header: `ShareLink` needs its item at view
    /// construction time, the file does not exist until the button is pressed,
    /// and the one that shipped at patch 183 "rendered and did nothing at all
    /// when tapped". Second caller of a wrapper built for the notes CSV.
    ///
    /// TEMPORARY IS RIGHT. The file is a transport. Every number in it is
    /// derived from stores that are still on the phone, so nothing is lost when
    /// iOS reclaims it, and a diagnostic that accumulated dated copies in the
    /// container would be a store nobody declared.
    private func writeDiagnostics() -> URL? {
        let name = "sub4-diagnostics-\(DayKey.key())-p\(AppVersion.patchLabel).txt"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
        guard let data = diagnosticsText.data(using: .utf8) else {
            shareFailed = true
            return nil
        }
        do {
            // The same protection class as the stores it describes — patch 190.
            // It carries no names or places, but "it is only counts" is an
            // argument about today's content, not about the file.
            try data.write(to: url, options: FileProtection.options)
            shareFailed = false
            return url
        } catch {
            // §12.15. A button that silently does nothing is indistinguishable
            // from a button nobody wired up, and this one has exactly one
            // failure mode worth naming.
            shareFailed = true
            return nil
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
            // The preview/fallback path obeys the same process boundary as
            // `Sub4Launch`; otherwise it could leave old `running` rows open.
            _ = try MigrationLedger.closeInterrupted(db)
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
            if isExpanded("write-through") {
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
        }
        } header: {
            DiagnosticSectionHeader(title: "Write-through",
                                        key: "write-through",
                                        expanded: $expanded,
                                        lines: { writeThrough.diagnosticLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("write-through") {
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
            if isExpanded("ledger") {
            if let recoveryFailure = Sub4Launch.shared.ledgerRecoveryFailure {
                Text("Interrupted-run recovery failed: \(recoveryFailure)")
                    .font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let r = lastRun {
                LabeledContent("State") {
                    Text(r.state.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle((r.state == .failed || r.state == .interrupted)
                                         ? Color.red : Color.secondary)
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
                if let recovered = r.recoveredUTC {
                    LabeledContent("Recovered on next launch",
                                   value: AppTime.local(recovered) ?? recovered)
                        .font(.caption)
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
                LabeledContent("Runs open right now", value: "\(staleRuns)")
                    .font(.caption)
                    .foregroundStyle(staleRuns > 0 ? Color.red : Color.dim)
            } else {
                Text("No import has been recorded. Nothing in this database can "
                     + "be called verified until one has.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        } header: {
            DiagnosticSectionHeader(title: "Import ledger",
                                        key: "ledger",
                                        expanded: $expanded,
                                        lines: { ledgerLines },
                                        shared: $shared)
        } footer: {
            if isExpanded("ledger") {
            // "One row per import" is what this said until 311, and it
            // is the sentence the migration's own body still carries. It
            // stopped being true the day the write-through landed.
            Text("A run reaches \"imported, not verified\" when the write "
                 + "commits. A passing verifier may move only the newest "
                 + "completed pending run to \"verified\"; interrupted, failed, "
                 + "older and still-running rows are refused.\n\n"
                 + "Most rows are not you. Leaving the app, coming back, and a "
                 + "background refresh each write one, so the ledger keeps the "
                 + "newest 200 successful automatic runs and 20 automatic "
                 + "interruptions. Runs you started, failures, verified runs and "
                 + "older rows whose trigger was never recorded are kept.")
        }
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

    // MARK: - The blocks a section can hand over — patch 392, §12.136

    //  EVERY SECTION ON THIS SCREEN CAN NOW EXPORT ITS OWN NUMBERS, and the
    //  numbers it exports are the ones the paste carries — the same property,
    //  not a second rendering of the same figures. §12.43: a block written
    //  twice is two things that can drift, and this screen's whole value is
    //  that a figure read here and a figure read in a message are the same
    //  figure.
    //
    //  Fifteen sections already owned a `diagnosticLines` on their report type.
    //  The six below were written INLINE in `diagnosticsText` and belonged to
    //  nobody, so a header had nothing to hand over. Extracting them changed no
    //  text: `diagnosticsText` appends exactly these, in exactly this order.

    /// "The file" — what this database IS, what opened it, and what every store
    /// is reading. One run with no blank line in it, because a reader meets the
    /// verdict, the mode and the stores as one fact.
    private var fileLines: [String] {
        var l = [AppVersion.full]
        if let report {
            l.append("Integrity: \(report.quickCheck)")
            l.append("Orphaned rows: \(report.foreignKeyViolations)")
            l.append("Foreign keys: \(report.foreignKeysEnabled ? "on" : "OFF")")
            l.append("Migrations: \(report.appliedMigrations.joined(separator: ", "))")
            l.append("Expected: \(Sub4Migrations.all.joined(separator: ", "))")
            if let bytes = report.bytesOnDisk {
                l.append("Size: \(bytes) bytes")
            }
        }
        l.append("Prepared: \(Sub4Launch.shared.database != nil ? "at launch" : "by this screen")")
        l.append("Reads from: \(Sub4Launch.shared.persistence.line)")
        // PATCH 398a — "AT LAUNCH", AND IT IS A CORRECTION. This is
        // `Sub4Launch`'s account of what THE LAUNCH fed, and since 395 that
        // correctly excludes the details and the traces: `DetailStore` fills
        // itself at construction, after the first frame (§12.139). Labelled
        // `Hydration:` it read as a complete account and silently omitted two
        // families, leaving "hydration did not include the details" beside
        // "Detail store reads: the database" with nothing saying why. §12.15.
        // The store lines below give the whole picture; this one now says which
        // question it is answering.
        l.append("Hydration at launch: \(Sub4Launch.shared.hydration.line)")
        if let boot = Sub4Launch.shared.bootstrap {
            l.append(contentsOf: boot.diagnosticLines)
        } else {
            l.append("Database bootstrap: not assembled — the database did "
                     + "not open this launch")
        }
        // PATCH 394 — WHAT THE BOOTSTRAP COST, UNCONDITIONALLY. §12.138: B4
        // adds the two largest families the app has and the read is awaited
        // before `.ready`, so this is time in front of first paint. Printed on
        // every launch, including the fast ones, or a slow one cannot be told
        // from a line nobody wired in.
        l.append(Sub4Launch.shared.bootstrapTiming.line)
        // PATCH 395 — WHAT BUILDING `DetailStore` COST, AND FROM WHICH SIDE.
        // §12.139: the launch line above no longer carries these two families,
        // so this is the only place the app says what its largest read costs.
        // Reading this property is what CONSTRUCTS the store if the Database
        // screen is the first thing to touch it — which is honest, because the
        // figure then describes this screen's own read rather than somebody
        // else's.
        l.append(DetailStore.shared.constructionTiming.line)
        l.append("Plan store reads: \(PlanStore.shared.servedFrom.line)")
        l.append("Athlete store reads: \(AthleteStore.shared.servedFrom.line)")
        l.append("Constants store reads: \(ConstantsStore.shared.servedFrom.line)")
        l.append("Notes store reads: \(NotesStore.shared.servedFrom.line)")
        l.append("Commute store reads: \(CommuteStore.shared.servedFrom.line)")
        l.append("Matcher reads: \(Matcher.shared.servedFrom.line)")
        l.append("Move store reads: \(PlanMoveStore.shared.servedFrom.line)")
        l.append("Activity store reads: \(ActivityStore.shared.servedFrom.line)")
        // PATCH 394 — THE NINTH AND TENTH STORE LINES, and the family is not
        // fed yet. 380's argument one slice later: a store with no line cannot
        // be told from a store nobody wired in (§12.54.2), and the line has to
        // exist BEFORE the thing it reports on. They say the files until 395.
        l.append("Detail store reads: \(DetailStore.shared.detailsServedFrom.line)")
        l.append("Trace store reads: \(DetailStore.shared.tracesServedFrom.line)")
        return l
    }

    /// "Rows — N tables". EVERY TABLE, INCLUDING THE EMPTY ONES — patch 336.
    private var tableLines: [String] {
        ["Tables: \(counts.count), imported rows: \(importedRows), total: \(totalRows)"]
        + counts.map { "  \($0.table): \($0.rows)" }
    }

    /// "Protected snapshot" — the manifest and what retention did to it.
    private var snapshotLines: [String] {
        (snapshot?.redactedLines ?? ["Protected snapshot: none taken"])
        + [""] + LegacySnapshot.retentionLines()
    }

    /// "Import ledger" — the newest run, what is open, and the census.
    private var ledgerLines: [String] {
        var l = ["Last import: \(lastRun?.line ?? "no import has been recorded")",
                 "Runs open right now: \(staleRuns)",
                 "Recovered at launch: \(Sub4Launch.shared.interruptedAtLaunch)",
                 "Recovery error: "
                 + (Sub4Launch.shared.ledgerRecoveryFailure == nil
                    ? "none" : "present — see the on-device screen")]
        if let c = ledgerCensus {
            l.append(contentsOf: c.diagnosticLines)
        } else {
            l.append("Import ledger: could not be counted")
        }
        return l
    }

    /// "Read-back · the plan" — the plan and its trimmings, which the screen
    /// draws as one section because they describe one version.
    private var planReadBackLines: [String] {
        (planTrip?.diagnosticLines
         ?? ["Plan read-back: \(planLoad?.line ?? "not read")"])
        + [""]
        + (planExtrasTrip?.diagnosticLines
           ?? ["Plan extras read-back: \(planExtrasLoad?.line ?? "not read")"])
    }

    /// "The app's own files" — the two journals, the roster and the file tally.
    /// The survey is separate because it only exists once somebody has run it.
    private var storeFileLines: [String] {
        StoreWriteJournal.shared.diagnosticLines
        + StoreReadJournal.shared.diagnosticLines
        + ActivityStore.shared.loadDiagnosticLines
        + ["Detail and trace files: \(DetailStore.shared.tally.line)"]
        + (survey.map { [""] + LegacyReader.diagnosticLines($0) } ?? [])
    }

    /// "Traces still to fetch" — patch 331's block.
    private var traceBacklogLines: [String] {
        ["Traces still to fetch: \(detailStore.backfillRemaining)",
         "  fetching now: \(detailStore.isFetching ? "yes" : "no")",
         "  rate limited: \(Self.rateLimitLine(detailStore.rateLimitedUntil))",
         "  activities with no trace: \(coverage.missing) of \(coverage.total)",
         "    queued, not yet reached: \(coverage.queued)",
         "    under 500 m, never asked: \(coverage.belowThreshold)",
         "    asked, nothing there: \(coverage.answeredEmpty)",
         "    the source refused it: \(coverage.refused)",
         "    unexplained: \(coverage.unexplained)"]
    }

    /// Built from figures that cannot describe anybody — see the header.
    private var diagnosticsText: String {
        // PATCH 392 — ONE COPY. Every run below is a property above, so a
        // section header and this paste hand over the same lines rather than
        // two renderings of the same figures. §12.43.
        var lines = fileLines
        lines.append(contentsOf: tableLines)
        lines.append("")
        lines.append(contentsOf: snapshotLines)
        lines.append("")
        lines.append(contentsOf: lastImport.last.diagnosticLines)
        lines.append("")
        lines.append(contentsOf: ledgerLines)
        if let r = benchmark.result {
            lines.append("")
            lines.append(contentsOf: r.diagnosticLines)
        }
        // Patch 262. COUNTS AND CONDITION NAMES ONLY. The two disputed names in
        // an identity fault are the athlete's own identifiers, and §12.7
        // promises this paste carries none — so the screen gets the names and
        // this gets how many there were.
        lines.append(contentsOf: verification.last.diagnosticLines)
        // Patch 266c. UNCONDITIONAL, unlike the two above it. Those are nil
        // until a button is pressed; the journal always has an answer, and
        // "none" is that answer said out loud. A section that simply vanished
        // when nothing was wrong would be indistinguishable from a check that
        // never ran — which is the same argument §12.9c makes for `absent`.
        //
        // Store names, stages and counts only. The underlying reason is left
        // out because a file-system error can carry a container path.
        lines.append("")
        lines.append(contentsOf: storeFileLines)
        lines.append("")
        lines.append(contentsOf: traceBacklogLines)
        // PATCH 333. The roll-up, and it is the only place in this paste where
        // all nine read-backs are answered together. Unconditional — §12.54.2,
        // and `.never` says "not rolled up since this launch" rather than
        // being absent.
        lines.append("")
        lines.append(contentsOf: rollUp.last.diagnosticLines)
        // PATCH 391 — THE THREE THE ROLL-UP SUMMARISED AND NOBODY COULD READ.
        //
        // §12.135. Every other read-back on this screen puts its breakdown in
        // this paste; these three put one line each into the roll-up above and
        // kept the rest inside a `@State` that died with the sheet. They are
        // the three most expensive comparisons the app makes — 694 activities ×
        // nineteen fields, 694 details with every split, lap and effort, and
        // 668 recordings over 199,848 samples — and the only way to read which
        // field differed was a screenshot. §12.57, one level down from the
        // defect the roll-up itself was written to close.
        //
        // UNCONDITIONAL, and the `else` is the point: "not read" is what a
        // launch where nobody pressed the button should say, and it cannot be
        // told from a block nobody wired in if the block is simply absent.
        // §12.54.2.
        lines.append("")
        if let r = roundTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Activity read-back: \(roundTripLoad?.line ?? "not read")")
        }
        lines.append("")
        if let r = detailTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Detail read-back: \(detailLoad?.line ?? "not read")")
        }
        lines.append("")
        if let r = recordingTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Recording read-back: not read")
        }
        // PATCH 391 — AND THE ONE SECTION THAT HAD NEVER REACHED THIS PASTE AT
        // ALL. Twenty-two of the twenty-three sections on this screen were
        // here; the write-through was not, so the mechanism that carries every
        // change made outside an import could only be read with the sheet open.
        lines.append("")
        lines.append(contentsOf: writeThrough.diagnosticLines)
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
            lines.append("  match decisions: "
                       + "\(decisionLoad?.line ?? "not read")")
            lines.append("  moved sessions: "
                       + "\(moveLoad?.line ?? "not read")")
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
        // PATCH 352 — §12.97. UNCONDITIONAL, and the "none" case is the whole
        // point: a paste that mentioned versions only when one was a duplicate
        // could not be used to show that none of them is. §12.54.2.
        lines.append("")
        if let c = planCensus {
            lines.append(contentsOf: c.diagnosticLines)
        } else {
            lines.append("Plan versions: not counted")
        }
        lines.append(contentsOf: authoredRestoreLines)
        lines.append(contentsOf: planPrune.diagnosticLines)
        // PATCH 324. Strava activity ids, gear ids, field names and counts.
        lines.append("")
        if let r = weatherGearTrip {
            lines.append(contentsOf: r.diagnosticLines)
        } else {
            lines.append("Weather and gear read-back: "
                       + "\(weatherGearLoad?.line ?? "not read")")
        }
        lines.append(contentsOf: weatherRestoreLines)
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
        // PATCH 353 — §12.98. UNCONDITIONAL, for §12.54.2's reason. "0 stored"
        // is what proves they went, and this is the number that decides
        // whether `review: 6` in the table census above is six reviews or six
        // rehearsals.
        lines.append(ReviewDue.rehearsalLine(in: ProposalStore.shared.records))

        return lines.joined(separator: "\n")
    }
}
