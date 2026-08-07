#!/usr/bin/env python3
"""
Patch 311 — who started this run.

The diagnostics paste said `migration_run: 45`. Forty-five ledger rows after
three days of D6b, and no way to tell which were you pressing a button and which
were the app writing through on its own. That is groundwork §5.4.

  · THE TRIGGER COLUMN. A new migration adds `triggeredBy` to `migration_run`,
    with a frozen four-word vocabulary — manual, backgrounded, foregrounded,
    backgroundRefresh — CHECKed in the migration body and held to the enum by
    `migrationRunTriggersMatch`, like every other vocabulary in this schema.

    Until patch 303 the two could be told apart BY ACCIDENT: an automatic run
    passed no snapshot id. 303 fixed a real defect and, in doing so, removed the
    only distinction the table had. Nothing was wrong with 303 — the
    distinction was never a column, it was a side effect, and a side effect is
    not a record.

    NULLABLE. The 45 existing rows have no answer and get one, honestly: "not
    recorded (before patch 311)". A NOT NULL with a default would have meant
    guessing, and a guessed `backgrounded` is indistinguishable from a recorded
    one — §12.15's shape, for the eighth time.

  · RETENTION, AND IT ONLY REMOVES ONE THING. Successful automatic runs beyond
    the newest 200. Manual runs, failed runs, interrupted runs, verified and
    activated runs, and rows whose trigger was never recorded are all kept
    forever. `prunableTriggers` is written out rather than derived, because
    `allCases.filter { $0 != .manual }` fails towards deleting: a trigger added
    later and forgotten grows the table, which is visible; one included by
    accident destroys evidence, which is not.

  · A DEFECT FOUND WHILE READING, WHICH IS THE POINT OF READING.
    `MigrationLedger.stale` was `all(db, limit: 100).filter { $0.state ==
    .running }` — it asks the newest hundred rows and then looks for interrupted
    ones among them. At patch 255 that was the whole table. At D6b it is about a
    day, so an interrupted run from two days ago was already invisible and the
    screen said "Interrupted runs: 0" with complete confidence.

    A count taken from a page is not a count of the table.

  · AND THE SCREEN SAYS ALL OF IT, UNCONDITIONALLY. "Started by" is always
    there; "Interrupted runs" is now always there rather than only when
    non-zero; the paste gains a census that names every trigger even at zero,
    with the row total as its denominator. §12.54.2, four hours after 310.

ONE NEW FILE, so this needs a full quit and reopen:
  Sub4/Sub4Migrations+RunTrigger.swift

Files replaced wholesale (they are in the zip, copy them over)
  Sub4/MigrationLedger.swift           trigger, census, prune, stale fixed
  Sub4/Sub4Migrations.swift            + runTrigger, registered and declared
  Sub4/AppStores.swift                 trigger REQUIRED on the overload
  Sub4/DatabaseWriteThrough.swift      run(reason:trigger:)
  Sub4/AppVersion.swift                311
  Sub4CoreTests/MigrationLedgerTests.swift      + 16
  Sub4CoreTests/DatabaseWriteThroughTests.swift + 1
  Sub4CoreTests/AppStoresTests.swift            + 1

Files this script edits in place
  Sub4/Sub4Import.swift                trigger threaded to the ledger
  Sub4/DatabaseHealthView.swift        two buttons, two rows, the census
  Sub4/BackgroundRefresh.swift         manual -> .manual, iOS -> .backgroundRefresh
  Sub4CoreTests/DomainSchemaTests.swift + the frozen vocabulary test
  docs/ADR-0003-database-contract.md   + §12.55

Run from ~/Documents/Developer/sub4/Sub4/docs
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


IMPORT = "Sub4/Sub4Import.swift"
HEALTH = "Sub4/DatabaseHealthView.swift"
REFRESH = "Sub4/BackgroundRefresh.swift"
SCHEMA = "Sub4CoreTests/DomainSchemaTests.swift"
ADR = "docs/ADR-0003-database-contract.md"

# ---------------------------------------------------------------- Sub4Import

edit(IMPORT, r'''                    appVersion: String = "unknown",
                    snapshotID: String? = nil) throws -> Report {''',
     r'''                    appVersion: String = "unknown",
                    snapshotID: String? = nil,
                    // WHO CAUSED THIS RUN — patch 311, groundwork §5.4.
                    //
                    // Defaulted to nil HERE and required on the `AppStores`
                    // overload every production caller goes through. That is
                    // the split on purpose: the two call sites that can answer
                    // must, and the several dozen test call sites that have no
                    // answer are left alone.
                    //
                    // A nil is stored as NULL and reads back as "not recorded",
                    // which is what the 45 rows written before this patch
                    // honestly are.
                    trigger: MigrationRunTrigger? = nil) throws -> Report {''',
     "the granular signature takes a trigger")

edit(IMPORT, r'''        let runID = try MigrationLedger.open(db, appVersion: appVersion,
                                             snapshotID: snapshotID, now: now)''',
     r'''        let runID = try MigrationLedger.open(db, appVersion: appVersion,
                                             snapshotID: snapshotID,
                                             trigger: trigger, now: now)''',
     "and hands it to the ledger")

# --------------------------------------------------------- BackgroundRefresh

edit(REFRESH, r'''        await DatabaseWriteThrough.shared.run(
            reason: manual ? "a refresh asked for in Settings"
                           : "a background refresh from iOS")''',
     r'''        await DatabaseWriteThrough.shared.run(
            reason: manual ? "a refresh asked for in Settings"
                           : "a background refresh from iOS",
            // ONE CODE PATH, TWO ANSWERS TO "WHO STARTED THIS" — patch 311.
            // A refresh the athlete asked for in Settings is a person pressing
            // a button; one iOS scheduled is not, and the whole point of the
            // column is that the ledger can tell them apart afterwards.
            trigger: manual ? .manual : .backgroundRefresh)''',
     "the two ways a refresh starts")

# ------------------------------------------------------- DatabaseHealthView

edit(HEALTH, r'''                importReport = try Sub4Import.run(
                    into: db,
                    stores: AppStores.current(),
                    appVersion: AppVersion.patchLabel,''',
     r'''                importReport = try Sub4Import.run(
                    into: db,
                    stores: AppStores.current(),
                    appVersion: AppVersion.patchLabel,
                    // Patch 311. The button on this screen is a person, and so
                    // is the one below it, and so is Run the task now in
                    // Settings. All three are `manual`, because the question
                    // the column answers is whether somebody caused the run —
                    // which button it was lives in the failure journal's
                    // reason, where it is a sentence rather than a value.''',
     "the Import button is manual (comment)")

edit(HEALTH, r'''                    snapshotID: snapshot?.id)
                await recheck(db)''',
     r'''                    snapshotID: snapshot?.id,
                    trigger: .manual)
                await recheck(db)''',
     "the Import button is manual")

edit(HEALTH, r'''                Button("Write through now") {
                    Task {
                        await writeThrough.run(reason: "asked for on this screen")''',
     r'''                Button("Write through now") {
                    Task {
                        await writeThrough.run(reason: "asked for on this screen",
                                               trigger: .manual)''',
     "the Write through button is manual")

edit(HEALTH, r'''                LabeledContent("By", value: "patch \(r.appVersion)")
                    .font(.caption).foregroundStyle(Color.dim)''',
     r'''                LabeledContent("By", value: "patch \(r.appVersion)")
                    .font(.caption).foregroundStyle(Color.dim)
                // ALWAYS PRESENT — patch 311, and §12.54.2 is four hours old.
                // A row that vanished when the trigger was NULL would be
                // indistinguishable from a row nobody wired in; a NULL says
                // "not recorded (before patch 311)", which is the truth about
                // the 45 rows this patch found.
                LabeledContent("Started by", value: r.triggerLabel)
                    .font(.caption)
                    .foregroundStyle(r.triggeredBy == nil ? Color.secondary : Color.dim)''',
     "Started by, unconditional")

edit(HEALTH, r'''                if staleRuns > 0 {
                    // Not repaired automatically — see `MigrationLedger.stale`.
                    // Rewriting these would destroy the only evidence the app
                    // was killed while writing.
                    LabeledContent("Interrupted runs", value: "\(staleRuns)")
                        .font(.caption).foregroundStyle(.red)
                }''',
     r'''                // UNCONDITIONAL AT 311, and it was hidden-when-zero before.
                //
                // That is exactly what §12.54.2 was written about yesterday —
                // and worse here, because `stale` was ALSO reading only the
                // newest hundred rows, so the row could have been absent while
                // an interrupted run sat two days down the table. Two ways to
                // show nothing, one of them wrong, and no way to tell from a
                // screenshot.
                LabeledContent("Interrupted runs", value: "\(staleRuns)")
                    .font(.caption)
                    .foregroundStyle(staleRuns > 0 ? Color.red : Color.dim)''',
     "Interrupted runs, unconditional")

edit(HEALTH, r'''            Text("One row per import. A run reaches \"imported, not verified\" "
                 + "when the write commits; the verifier that can move it to "
                 + "\"verified\" is the next step, and until it exists nothing "
                 + "may switch its reads to this database.")''',
     r'''            // "One row per import" is what this said until 311, and it
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
                 + "evidence the app was killed while writing.")''',
     "the footer stops saying one row per import")

edit(HEALTH, r'''    private func reloadLedger(_ db: Sub4Database) async {
        let read: (run: MigrationRun?, stale: Int)? = await Task.detached(priority: .utility) {
            guard let latest = try? MigrationLedger.latest(db) else { return nil }
            let stale = (try? MigrationLedger.stale(db).count) ?? 0
            return (latest, stale)
        }.value
        lastRun = read?.run
        staleRuns = read?.stale ?? 0
    }''',
     r'''    /// What one read of the ledger produces. A named type rather than a tuple
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
    }''',
     "reloadLedger also counts")

edit(HEALTH, r'''    @State private var staleRuns: Int = 0''',
     r'''    @State private var staleRuns: Int = 0
    /// Patch 311. The whole table, tallied by what started each run — the
    /// answer `migration_run: 45` could not give.
    @State private var ledgerCensus: LedgerCensus?''',
     "the census, held")

edit(HEALTH, r'''        if let r = lastRun {
            lines.append("")
            lines.append("Last import: \(r.line)")
            if staleRuns > 0 { lines.append("Interrupted runs: \(staleRuns)") }
        }''',
     r'''        // PATCH 311, AND EVERY LINE OF IT IS UNCONDITIONAL. `migration_run: 45`
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
        }''',
     "the census joins the paste")

# ------------------------------------------------------- DomainSchemaTests

edit(SCHEMA, r'''    @Test("The weather provider constraint lists exactly the providers in use")''',
     r'''    @Test("The trigger vocabulary lists exactly the ways a run can start")
    func migrationRunTriggersMatch() {
        // Patch 311, and the same rule as the five states above it. The
        // migration body freezes four literals in a CHECK; this is what makes
        // adding a fifth a red build and a new migration rather than an edit to
        // history.
        //
        // It is also what `MigrationLedger.row` depends on: an unknown string
        // in that column would read back as nil and print as "not recorded",
        // which is only safe because the CHECK makes it impossible to store.
        #expect(Set(Sub4Migrations.migrationRunTriggers)
                == Set(MigrationRunTrigger.allCases.map(\.rawValue)),
                "got \(Sub4Migrations.migrationRunTriggers)")
    }

    @Test("The weather provider constraint lists exactly the providers in use")''',
     "the frozen vocabulary test")

# --------------------------------------------------------------------- ADR

ADR_SECTION = r'''## 12.55 Who started this run — patch 311

`migration_run: 45` in the diagnostics paste. Forty-five ledger rows after three
days of D6b, and no way to tell which were a person pressing a button and which
were the app writing through on its own.

### 12.55.1 The distinction existed, and it was never a column

Until patch 303 the two could be told apart **by accident**: an automatic run
passed no snapshot id, so a NULL in `snapshotID` meant "not a manual import".

303 fixed a real defect — an automatic run does have a snapshot preceding it, and
recording it is accurate rather than convenient (§12.47) — and in doing so
removed the only distinction the table had. Nothing was wrong with 303.

> **A side effect is not a record.** A fact you can only read by knowing which
> other fact happens to be absent is a fact you will lose the first time
> somebody fixes the absence.

That is the same shape as §12.42.1.1's `?? .distantPast` and §12.15's whole
family, arriving from a new direction: not a diagnostic that cannot say why it
has no answer, but an answer that was only ever a coincidence.

### 12.55.2 A table whose own comment stopped being true

`Sub4Migrations+MigrationRun.swift` says, in the body of the migration:

> The only query this table has: newest first. **Small forever — one row per
> import** — but the index costs nothing…

True for two hundred patches. False the day D6b landed: a background/foreground
cycle writes **two** rows on its own (§12.49.3), and `BackgroundRefresh` adds
more. Forty-five in three days, growing, with no upper bound anywhere.

So retention, and the argument is entirely about what it does **not** remove:

| kept forever | why |
|---|---|
| `manual` | the athlete did it on purpose |
| `failed` | the reason anybody opens this table |
| `running` | the only evidence the app was killed mid-write |
| `verified`, `activated` | D7 decides on the strength of these |
| trigger not recorded | the 45 cannot be identified as automatic |

Only *successful automatic* runs are trimmed, beyond the newest 200 — a few
weeks at two per app switch.

`prunableTriggers` is **written out rather than derived**. `allCases.filter { $0
!= .manual }` is the obvious expression and it fails in the wrong direction: a
trigger added later would be swept into the prune by default. Written out, a
forgotten trigger makes the table grow — visible in the census — and an included
one destroys evidence, which is visible nowhere. **Between a leak and a
shredder, pick the leak.** `prunableIsEveryAutomaticTrigger` asserts the two
agree today, so adding a case is a decision somebody makes rather than one that
gets made for them.

### 12.55.3 The defect found while reading, which is the point of reading

```swift
static func stale(_ db: Sub4Database) throws -> [MigrationRun] {
    try all(db, limit: 100).filter { $0.state == .running }
}
```

It asks for the newest hundred rows and then looks for interrupted ones among
them. At patch 255, when this table held one row per import, a hundred was the
whole table. At D6b it is **about a day** — so an interrupted run from two days
ago was already invisible, and the screen said `Interrupted runs: 0` with
complete confidence.

> **A count taken from a page is not a count of the table.**

Nothing about the old code looks wrong. It broke because a number that was a
generous over-estimate became a tight limit, without a line changing.
`anInterruptedRunIsFoundBeyondThePage` builds 151 rows over one interrupted run,
which is the size the old implementation fails at.

### 12.55.4 Two rows and a tally, all unconditional

§12.54.2 was written down four hours before this patch, and this screen had two
live instances of the thing it describes:

- **Interrupted runs** was `if staleRuns > 0`. Combined with §12.55.3, that row
  had two ways to be absent — nothing wrong, or something wrong two days down
  the table — and a screenshot could not tell them apart.
- **Started by** would have been the same the moment it was written as
  `if let t = r.triggeredBy`, because NULL is what the 45 existing rows hold.

Both are unconditional. A NULL prints `not recorded (before patch 311)`, which
is the truth about those rows and is why the column is nullable at all: a NOT
NULL with a default would have meant guessing a value for them, and a guessed
`backgrounded` is indistinguishable from a recorded one.

The paste gains a census that names **every** trigger every time, at zero, with
the row total as its denominator — §12.54.3's argument arriving one screen over.
`migration_run: 45` is what a number without a breakdown looks like.

### 12.55.5 Four values, not five, and the reason it is not tidiness

Three buttons produce a manual run: Import and Write through now on the Database
screen, and Run the task now in Settings. All three are `manual`.

`DatabaseWriteThrough.run` therefore takes **both** a `trigger` and a `reason`,
which looks redundant and is not. The trigger is a stored value from a frozen
vocabulary that a query groups by; the reason is a sentence a person reads in
the unsaved-stores list when a write fails, and it distinguishes things the
vocabulary deliberately does not. Collapsing them costs either the journal's
detail or a fifth enum case meaning "manual, but from the other button" —
§12.39.2, where a field name that carries detail stops being a field name.

### 12.55.6 `trigger` is required in exactly one place

The `AppStores` overload — the single door every production import comes through
(§12.45). The granular signature under it defaults to nil, so the several dozen
test call sites that have no answer are untouched, and the two call sites that
do have one cannot forget.

Which is §12.45's own argument about defaulted parameters, pointed at the
parameter that says who caused the run.

'''

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     ADR_SECTION + "## 12.10 The athlete profile, the zones and the resting series",
     "§12.55")


def main():
    check = "--check" in sys.argv
    print(f"ROOT = {ROOT}")
    if not (ROOT / "Sub4.xcodeproj").exists():
        print("!! that is not the project root — expected Sub4.xcodeproj beside Sub4/")
        return 1

    failures = 0
    writes = {}
    for path, old, new, why in EDITS:
        if not path.exists():
            print(f"MISSING  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        text = writes.get(path, path.read_text(encoding="utf-8"))
        if new in text and old not in text:
            print(f"already  {path.relative_to(ROOT)}  ({why})")
            continue
        n = text.count(old)
        if n != 1:
            print(f"ANCHOR x{n}  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        writes[path] = text.replace(old, new, 1)
        print(f"ok       {path.relative_to(ROOT)}  ({why})")

    # The wholesale replacements. Copied from the zip, not written here — this
    # only checks they arrived, so a half-applied patch is a red script rather
    # than a red build twenty minutes later.
    copied = ["Sub4/Sub4Migrations+RunTrigger.swift",
              "Sub4/MigrationLedger.swift",
              "Sub4/Sub4Migrations.swift",
              "Sub4/AppStores.swift",
              "Sub4/DatabaseWriteThrough.swift",
              "Sub4/AppVersion.swift",
              "Sub4CoreTests/MigrationLedgerTests.swift",
              "Sub4CoreTests/DatabaseWriteThroughTests.swift",
              "Sub4CoreTests/AppStoresTests.swift"]
    for g in copied:
        here = (ROOT / g).exists()
        print(f"{'ok      ' if here else 'MISSING '} {g}  (copied from the zip)")
        if not here:
            failures += 1

    # And that the copies are the 311 ones, not last patch's. `AppVersion` is
    # the number this project already trusts for exactly this question.
    marker = (ROOT / "Sub4/MigrationLedger.swift")
    if marker.exists() and "triggeredBy" not in marker.read_text(encoding="utf-8"):
        print("STALE    Sub4/MigrationLedger.swift  (still the 310 copy)")
        failures += 1

    if failures:
        print(f"\n{failures} item(s) failed — nothing written.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. ONE NEW FILE — quit Xcode entirely (⌘Q) and reopen")
    print("  2. run the suite")
    print("  3. ⌘R → Settings → Database health. The ledger section now has")
    print("     'Started by', and 'Interrupted runs' is ALWAYS there.")
    print("     The newest row should read 'Started by  you' after Import.")
    print("  4. Home screen, wait, come back. Reopen Database health: the")
    print("     newest row should now say 'leaving the app' or 'coming back")
    print("     to the app' — that is the distinction this patch bought.")
    print("  5. Copy diagnostics. The paste gains, unconditionally:")
    print("       Import ledger: 47 rows")
    print("         manual: 1 · backgrounded: 1 · foregrounded: 1 ·")
    print("         backgroundRefresh: 0")
    print("         trigger not recorded: 45")
    print("         interrupted (still running): 0")
    print("     Forty-five is the honest count of rows written before today.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
