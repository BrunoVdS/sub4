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
            Text("The diagnostic is counts, sizes, migration names and SQLite's "
                 + "own verdicts. No session names, no places, no dates from "
                 + "your history — it is safe to paste into a message.")
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

    private func load() async {
        guard opened == nil else { return }
        do {
            let db = try Sub4Database.open()
            opened = .success(db)
            await recheck(db)
        } catch {
            opened = .failure(error)
        }
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
        lines.append("Tables: \(counts.count), imported rows: \(importedRows), total: \(totalRows)")
        for row in counts where row.rows > 0 {
            lines.append("  \(row.table): \(row.rows)")
        }
        return lines.joined(separator: "\n")
    }
}
