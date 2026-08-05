#!/usr/bin/env python3
"""
Patch 281 — the inventory said the database was empty. It holds 212,297 rows.

`.database` claimed "no training data at all — only an empty schema", declared
`lineage: [.device]`, and kept itself on a Strava disconnect ON THE STRENGTH OF
BEING EMPTY. Its own gap predicted the rewrite when step 3.4 landed. 3.4 landed
across patches 265–280 and the rewrite did not follow.

Nothing ships whole; every edit is by anchor, so there is no new file and no ⌘Q.

Three tests are added to `DataLifecycleTests.swift`, and TWO EXISTING TESTS ARE
REPLACED. Both were written to guard this exact entry, both were pinned to the
declared value rather than to reality, and both passed the whole way through
3.4 — see ADR-0003 §12.27.3. That is the finding, not a side effect.

Run from ~/Documents/Developer/sub4/Sub4/docs
Stops without changing anything if any anchor is missing or not unique.
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


L = "Sub4/DataLifecycle.swift"
T = "Sub4CoreTests/DataLifecycleTests.swift"
DT = "Sub4CoreTests/DatabaseTests.swift"
CT = "Sub4CoreTests/DataLifecycleCoordinatorTests.swift"

# ------------------------------------------------- DataLifecycle — what it is

edit(
    L,
    r'''            whatItIs: "A SQLite file and the journal files SQLite keeps beside "
                    + "it. Today it holds no training data at all — only an "
                    + "empty schema.",''',
    r'''            whatItIs: "A SQLite file and the journal files SQLite keeps beside "
                    + "it. It now holds a copy of nearly everything above — your "
                    + "activities, their traces and routes, the weather, your "
                    + "notes and your corrections — written by the import on the "
                    + "Database screen. No screen in the app reads from it yet; "
                    + "they all still read the files above.",''',
    "whatItIs stops claiming the database is empty",
)

# --------------------------------------------------------------- the lineage

edit(
    L,
    r'''            // HONEST FOR TODAY, AND WRONG BY 3.4. The file is created by this
            // phone and contains nothing from anywhere else, so `.device` is
            // the only true answer right now. The moment 3.4 imports the
            // stores, this set becomes the union of every category's lineage
            // and the disconnect rule below stops being `.keep`. Recorded as a
            // gap rather than pre-declared, because an inventory that describes
            // next month's behaviour is the thing this file exists to prevent.
            lineage: [.device],''',
    r'''            // CORRECTED IN 281, AND THE CORRECTION IS THE FINDING.
            //
            // This read `[.device]`, under a comment explaining that the file
            // "contains nothing from anywhere else" and that step 3.4 would
            // change it. 3.4 happened across patches 265–280. The rewrite did
            // not follow, so for sixteen patches the one place holding every
            // row claimed to hold none — and exempted itself from a disconnect
            // on that basis.
            //
            // The previous comment was right that pre-declaring next month's
            // behaviour is the thing this file exists to prevent. What it did
            // not have was anything that would notice when next month arrived.
            // That is what `databaseContributors` and its test are: the literal
            // below is held to the union of every category that feeds this
            // database, so changing a contributor's lineage names this file.
            lineage: [.strava, .appleHealth, .authored,
                      .weatherProvider, .bundled, .device],''',
    "lineage becomes the union of its inputs",
)

# ----------------------------------------------- the gaps and the disconnect

edit(
    L,
    r'''            gaps: ["Holds no training data yet. When step 3.4 moves the stores "
                 + "into it, this entry's lineage, export rule and disconnect "
                 + "rule must all be rewritten — a disconnect will have to "
                 + "delete Strava-derived ROWS rather than a file (ADR-0003 §8).",
                   "Not included in an export. The export writes JSON and a "
                 + "SQLite file is not JSON, so a readable dump has to exist "
                 + "before any category's data moves here (ADR-0003 §9.4).",
                   "Included in your device backup, like everything else under "
                 + "Application Support (ADR-0003 §9.4)."],
            onStravaDisconnect: .keep(why: "it is empty. When step 3.4 moves the training data into it, this rule has to change to one that deletes the Strava-derived rows")),''',
    r'''            gaps: ["A copy, not the original: it holds the rows and nothing "
                 + "reads them. When step 3.7 makes it the place the app reads "
                 + "from, a disconnect will have to delete the Strava-derived "
                 + "ROWS and re-key the ones you wrote, rather than removing "
                 + "the folder — the rule below is only correct while every row "
                 + "in here also exists in the files above (ADR-0003 §8).",
                   "Not included in an export, and it is now the only place "
                 + "your whole training record sits together. The export writes "
                 + "JSON and a SQLite file is not JSON, so a readable dump has "
                 + "to exist before this entry can honestly be exportable "
                 + "(ADR-0003 §9.4).",
                   "A disconnect removes the folder while the app still has the "
                 + "database open, so the rows survive in an unlinked file until "
                 + "you quit the app. Harmless while nothing reads them, and it "
                 + "has to become a real close before step 3.7 (ADR-0003 §8).",
                   "Included in your device backup, like everything else under "
                 + "Application Support (ADR-0003 §9.4)."],
            // FLIPPED IN 281, AND IT IS CORRECT ONLY WHILE THIS IS A COPY.
            //
            // The softer fix was to reword the `.keep` — which would leave
            // 212,297 Strava-derived rows on the phone of somebody who has just
            // been shown a receipt saying their Strava data was removed. That is
            // the same falsehood in better prose.
            //
            // Removing it is harmless (nothing reads it; the migrator rebuilds
            // an empty schema on the next launch), honest (every row in here
            // today is Strava-derived, weather, or written by you ABOUT Strava
            // data), and it finally sweeps `snapshots/`, which holds copies of
            // everything above and had been surviving every disconnect.
            //
            // It becomes WRONG the day a kept category's data lives only in
            // here — your notes, your corrections, a review verdict, all of
            // which the entries above promise survive a disconnect. That day is
            // step 3.7, and `theDisconnectRuleIsCoupledToActivation` fails the
            // build on it.
            onStravaDisconnect: .removeEverything),''',
    "the gaps and the disconnect rule",
)

# ------------------------------------------------- the contributor list

edit(
    L,
    r'''    static func entry(_ c: DataCategory) -> DataCategoryEntry? {
        entries.first { $0.category == c }
    }''',
    r'''    static func entry(_ c: DataCategory) -> DataCategoryEntry? {
        entries.first { $0.category == c }
    }

    /// The categories that put rows in the database — patch 281.
    ///
    /// DECLARED RATHER THAN COMPUTED, and the reason is structural: an entry
    /// cannot read the array it lives in, so `.database`'s `lineage` has to be
    /// a literal. Hand-writing that literal next to the entry is exactly how it
    /// went sixteen patches out of date. So the literal stays, this list stays
    /// beside it, and `databaseLineageIsTheUnionOfItsInputs` holds one to the
    /// other — change any contributor's lineage and the test names this file.
    ///
    /// `.reviews` is listed with an empty table behind it. The review importer
    /// exists and runs; there has simply been no review yet. This list is what
    /// the import WRITES, not what happens to be in the file this afternoon.
    ///
    /// `.database` IS DELIBERATELY NOT IN ITS OWN LIST. `migration_run` is
    /// generated by this phone and `.device` belongs in the set for it — but
    /// including the category here would make the assertion circular, since the
    /// value being checked would be one of its own inputs. The test adds
    /// `.device` explicitly instead.
    ///
    /// ABSENT AND CORRECTLY SO: `.trainingLoad`, which stores no rows — the
    /// curve is computed, and comparing it both ways is deferred to step 3.6
    /// (ADR-0003 §12.16); `.credentials`, which is Keychain and where nothing
    /// in this database is a secret; `.diagnostics` and `.appSettings`, whose
    /// preference keys are staying where they are.
    static let databaseContributors: [DataCategory] = [
        .activitySummaries,
        .routes,
        .sensorStreams,
        .weather,
        .athleteProfile,
        .sessionNotes,
        .matchDecisions,
        .reviews,
        .trainingPlan,
    ]''',
    "databaseContributors",
)

# ------------------------------------------------------------------- tests

edit(
    T,
    r'''    // MARK: The summary line''',
    r'''    // MARK: The database is a copy of everything, and said it was empty

    /// THE ASSERTION THIS PATCH EXISTS FOR — patch 281, ADR-0003 §12.27.
    ///
    /// `.removeEverything` is the right rule for a database nothing reads: the
    /// rows are a copy, the files above are the originals, and after a
    /// disconnect neither should survive. It becomes the WRONG rule the moment
    /// a kept category's data lives only in here.
    ///
    /// `migrationFailureBlocksTheApp` is this project's declared marker for
    /// that moment — "IT MUST BECOME `true` IN 3.3.3, the moment the first
    /// store reads its data from the database instead of from JSON" — and it is
    /// a stored constant precisely so that flipping it is a decision somebody
    /// makes on purpose. This test makes that decision fail the build until
    /// the disconnect has been taught to delete rows.
    ///
    /// So the person who activates the database reads is the same person who
    /// gets told what they now owe. That is the whole design: the act that
    /// makes the work necessary is the act that surfaces it.
    @Test("The disconnect rule is coupled to whether anything reads the database")
    func theDisconnectRuleIsCoupledToActivation() throws {
        let db = try #require(DataLifecycle.entry(.database))

        // HOISTED, and not for readability — patch 278b. `#expect`'s second
        // argument is `Comment?`, which a string LITERAL converts to and a
        // `String` value does not. `"a " + "b"` is a value, so writing the
        // sentence across two quoted pieces fails to compile with a diagnostic
        // that names the type and not the cause.
        let activated = "a store now reads from the database, so a disconnect "
            + "may no longer remove the whole folder — it holds the only copy "
            + "of notes, corrections and reviews that other categories promise "
            + "to keep. See ADR-0003 §12.27 and step 3.7."
        let shadow = "nothing reads the database, so its rows are a copy of "
            + "the files above and a disconnect must take them too"

        if Sub4Launch.migrationFailureBlocksTheApp {
            #expect(db.onStravaDisconnect != .removeEverything, "\(activated)")
        } else {
            #expect(db.onStravaDisconnect == .removeEverything, "\(shadow)")
        }
    }

    /// The literal cannot be computed — an entry cannot read the array it lives
    /// in — so it is held to the union instead. This is the test that would
    /// have caught the original defect: `weather` and `sessionNotes` started
    /// feeding the database at patches 265 and 271, and `[.device]` went on
    /// being the declared answer.
    ///
    /// `.device` is added here rather than taken from `.database`'s own entry,
    /// which would make this circular. It is in the set for `migration_run`.
    @Test("The database's lineage is the union of what feeds it")
    func databaseLineageIsTheUnionOfItsInputs() throws {
        let db = try #require(DataLifecycle.entry(.database))

        var expected: Set<DataSource> = [.device]
        for c in DataLifecycle.databaseContributors {
            let e = try #require(DataLifecycle.entry(c),
                                 "\(c.rawValue) is named as a contributor and has no entry")
            expected.formUnion(e.lineage)
        }

        let missing = expected.subtracting(db.lineage).map(\.rawValue).sorted()
        let extra = db.lineage.subtracting(expected).map(\.rawValue).sorted()
        #expect(db.lineage == expected,
                "the database's lineage is wrong — missing \(missing), unexpected \(extra)")
    }

    /// THE WEAKEST OF THE THREE, and recorded as such.
    ///
    /// It asserts the absence of two sentences, which is a test about prose —
    /// the thing `knownProblemsAreDisclosed` had to be corrected for once
    /// already. It earns its place on the same grounds as that test does in
    /// reverse: those two claims were read by a person deciding whether to
    /// disconnect, they were false for sixteen patches, and if they ever come
    /// back it should be because somebody deleted this test on purpose.
    @Test("The database no longer claims to be empty")
    func theDatabaseDoesNotClaimToBeEmpty() throws {
        let db = try #require(DataLifecycle.entry(.database))
        #expect(!db.whatItIs.localizedCaseInsensitiveContains("no training data"))
        #expect(!db.whatItIs.localizedCaseInsensitiveContains("empty schema"))
        #expect(db.lineage.contains(.strava),
                "the database holds 668 Strava activities and must say so")
    }

    // MARK: The summary line''',
    "the three database tests",
)

# ------------------------------- the two tests that were guarding this entry
#
# Both fail under this patch, and both are supposed to. They are the evidence
# for §12.27.3: the entry was not unguarded, it was guarded by tests of the
# wrong kind — each pinned the stale claim instead of coupling it to the thing
# that would falsify it.

edit(
    DT,
    r'''    /// It holds nothing yet and must not be described as holding anything. When
    /// 3.4 moves the stores into it, this test is what makes somebody rewrite
    /// the entry rather than leave the old sentence in place.
    @Test("The empty database says it is empty, and says what changes when it is not")
    func emptinessIsDisclosed() throws {
        let entry = try #require(DataLifecycle.entry(.database))
        #expect(entry.lineage == [.device],
                "the database claims data it does not hold yet")
        #expect(entry.gaps.contains { $0.contains("3.4") },
                "nothing records that this entry has to be rewritten at 3.4")
    }''',
    r'''    /// REPLACED IN 281, AND THE REPLACEMENT IS THE FINDING — ADR-0003 §12.27.3.
    ///
    /// This asserted `entry.lineage == [.device]` and that a gap named "3.4",
    /// under a comment saying it was "what makes somebody rewrite the entry
    /// rather than leave the old sentence in place".
    ///
    /// IT DID NOT DO THAT, AND IT COULD NOT HAVE. It pinned the stale claim.
    /// Step 3.4 ran across patches 265–280, the entry became false in every
    /// particular, and this test went on passing the whole way — because
    /// nothing about it was connected to whether the database held any rows. It
    /// would only ever have fired if somebody had already fixed the entry.
    ///
    /// A test that pins a description keeps the description. A test that pins a
    /// description to SOMETHING THAT MOVES keeps it true.
    /// `databaseLineageIsTheUnionOfItsInputs` is the second kind and lives in
    /// DataLifecycleTests beside the inventory it checks.
    ///
    /// What stays here is the obligation that is still genuinely open.
    @Test("The database still names the step that will make its disconnect rule wrong")
    func theRemainingObligationIsNamed() throws {
        let entry = try #require(DataLifecycle.entry(.database))
        #expect(entry.gaps.contains { $0.contains("3.7") },
                "nothing records that a disconnect must start deleting rows at 3.7")
        #expect(entry.lineage.contains(.strava),
                "the database holds Strava-derived rows and the entry must say so")
    }''',
    "DatabaseTests — the emptiness test is replaced",
)

edit(
    CT,
    r'''    /// THE TRAP THAT MAKES THE EXEMPTION ABOVE SAFE, and the reason it is a
    /// test rather than a line in an ADR.
    ///
    /// The database may be left out of the export only while it is empty. Its
    /// lineage is `[.device]` today because the file holds nothing that came
    /// from anywhere. The moment step 3.4 moves a category's data into it, that
    /// stops being true — and an export that omits the database then omits
    /// everything, which is the opposite of what "Export my data" means.
    ///
    /// This fails on the day that happens. A sentence in ADR-0003 §9.4 relies
    /// on somebody rereading ADR-0003 §9.4.
    @Test("The database may be left out of the export only while it is empty")
    func theDatabaseExemptionExpiresWhenItHoldsSomething() throws {
        let entry = try #require(DataLifecycle.entry(.database))
        guard entry.lineage != [.device] else { return }
        #expect(entry.isExportable,
                "the database now holds data from \(entry.lineage.map(\.rawValue).sorted()) and must be in the export")
    }''',
    r'''    /// THE TRAP THAT MAKES THE EXEMPTION ABOVE SAFE — RE-AIMED IN 281.
    ///
    /// It guarded on `lineage != [.device]`: the database may be left out of
    /// the export only while it is EMPTY. Patch 281 makes that guard fall
    /// through, and the assertion behind it — that the database must therefore
    /// be in the export — would fail.
    ///
    /// IT WOULD FAIL FOR THE WRONG REASON, which is why this is a re-aim and
    /// not a deletion. The export writes JSON out of the STORES, and the stores
    /// are still the originals; the database holds a copy of them. Omitting a
    /// copy omits nothing. The premise this test defends — "an export that
    /// omits the database omits everything" — becomes true not when the
    /// database holds rows, but when it holds the ONLY rows.
    ///
    /// So the guard moves to the marker for that: `migrationFailureBlocksTheApp`,
    /// flipped at step 3.7 by whoever makes the database authoritative. On that
    /// day this and `theDisconnectRuleIsCoupledToActivation` fail together,
    /// which is the correct pair — a database that cannot be exported and
    /// cannot be selectively deleted is not one the app may depend on.
    @Test("The database may be left out of the export only while nothing reads it")
    func theDatabaseExemptionExpiresWhenItBecomesAuthoritative() throws {
        let entry = try #require(DataLifecycle.entry(.database))

        guard Sub4Launch.migrationFailureBlocksTheApp else {
            // Still a copy. The export takes the same data from the stores, and
            // the manifest names this file in `excluded` with the reason.
            #expect(entry.isExportable == false,
                    "nothing reads the database, so the export takes the stores instead")
            return
        }

        #expect(entry.isExportable,
                "the database is now the only copy of your training and must be in the export")
    }''',
    "CoordinatorTests — the export exemption is re-aimed at activation",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.27 The inventory said it was empty — patch 281

### 12.27.1 What was actually declared

`DataLifecycle.swift`'s `.database` entry, at patch 280, on a phone holding 51
tables and roughly 212,297 rows:

- `whatItIs`: *"Today it holds no training data at all — only an empty schema."*
- `lineage: [.device]`
- `onStravaDisconnect: .keep(why: "it is empty…")`

Three statements, all false, and the third one load-bearing: the entry exempted
itself from a disconnect **on the strength of the first two**.

The entry predicted its own correction. Its gap read *"When step 3.4 moves the
stores into it, this entry's lineage, export rule and disconnect rule must all
be rewritten."* Step 3.4 ran across patches 265–280. Nothing rewrote it, because
nothing was watching.

### 12.27.2 The failure is a class, not an incident

`DataLifecycle.swift`'s header states the rule it broke: *"It describes what the
app does, not what it should do."* The file is scrupulous about this — several
categories are handled worse than their stated policy and each says so.

What it had no defence against was the opposite drift: a statement that was true
when written and became false while nobody was reading it. Recording a gap makes
a known shortfall visible; it does not make the arrival of the fix detectable.
**A prediction is not a trigger.**

This is the same shape as §12.25's two-answers-to-one-question: correct code,
correct at the time, with no mechanism to notice a change elsewhere. The answer
is the same in kind — couple the claim to the thing that would falsify it.

### 12.27.3 The entry was not unguarded. It was guarded by the wrong kind of test.

This is the part worth keeping. **Two tests already existed for exactly this
entry, written for exactly this eventuality, and both passed the whole way
through 3.4.**

`DatabaseTests.emptinessIsDisclosed` asserted `entry.lineage == [.device]` and
that a gap named "3.4", under a comment saying it was *"what makes somebody
rewrite the entry rather than leave the old sentence in place"*.

`DataLifecycleCoordinatorTests.theDatabaseExemptionExpiresWhenItHoldsSomething`
guarded on `lineage != [.device]` and was titled *"THE TRAP THAT MAKES THE
EXEMPTION ABOVE SAFE"*, closing with *"a sentence in ADR-0003 §9.4 relies on
somebody rereading ADR-0003 §9.4."*

Both were pinned to **the declared value**, not to reality. So the only way
either could fire was if somebody had *already* corrected the entry — at which
point the test's job was done by the person it was supposed to prompt. A test
that pins a description keeps the description; it does not keep it true.

The distinction is not subtle once stated, and it is easy to write the wrong
one while believing you have written the right one — both of these read, in
their own comments, as though they were traps. **The test for a trap is: name
the event that should spring it, and check that the assertion reads something
that changes when that event happens.** `lineage == [.device]` does not change
when the importer runs. `migrationFailureBlocksTheApp` does change when a store
starts reading from the database, and it changes *by a person's deliberate
act*, which is the second property a trap wants: it fires in front of somebody
who is already thinking about the thing.

Both tests are replaced in this patch rather than deleted, and both are
re-aimed at that flag.

**A footnote on the export one.** Left as written it would have failed under
this patch — for the wrong reason. The export writes JSON out of the stores,
and the stores are still the originals; the database holds a copy, and omitting
a copy omits nothing. Its premise — *"an export that omits the database omits
everything"* — becomes true when the database holds the ONLY rows, not when it
holds rows. A failing test whose premise is wrong is worse than no test, because
the fix it invites is to make the app satisfy it.

### 12.27.4 `.removeEverything` is right, and only while this is a copy

The softer fix was to reword the `.keep`. That leaves 212,297 Strava-derived
rows on the phone of somebody who has just read a receipt saying their Strava
data was removed. It is the same falsehood, better written.

While nothing reads the database, `.removeEverything` is correct on all three
axes that matter:

1. **Harmless.** No screen reads it. The migrator rebuilds an empty schema on
   the next launch in milliseconds.
2. **Honest.** Every row in there today is Strava-derived, weather, or authored
   *about* Strava data, and after a disconnect none of it should survive.
3. **It sweeps the snapshots.** `.snapshotDirectory("snapshots")` sits in the
   same entry and holds *"copies of everything above"* — legacy inputs captured
   before decode. It had survived every disconnect until now. Second retention
   hole, same entry, closed by the same edit.

It becomes **wrong** the day a kept category's data lives only in the database.
The entries above promise that session notes, corrections and review verdicts
survive a disconnect; a whole-folder delete would break all three.

### 12.27.5 The trigger, and why it is that flag

`Sub4Launch.migrationFailureBlocksTheApp` is already this project's declared
marker for the moment the database stops being a copy: *"IT MUST BECOME `true`
IN 3.3.3, the moment the first store reads its data from the database instead of
from JSON."* It is a stored constant specifically so that flipping it is a
deliberate act.

So the test reads it:

```swift
if Sub4Launch.migrationFailureBlocksTheApp {
    #expect(db.onStravaDisconnect != .removeEverything)
} else {
    #expect(db.onStravaDisconnect == .removeEverything)
}
```

**The act that makes the row-level disconnect necessary is the act that fails
the suite.** No calendar reminder, no item in a handoff that ages out — the
person activating the reads is the person told what they now owe, at the moment
they can least talk themselves out of it.

This is preferable to a date-based or patch-numbered check for the reason patch
272a established: a test that cites a patch number is policing bookkeeping. A
test that cites a behaviour is policing behaviour.

### 12.27.6 The lineage is held to a union

`lineage` has to stay a literal — an entry cannot read the array it lives in.
So `DataLifecycle.databaseContributors` lists the categories that write rows,
and `databaseLineageIsTheUnionOfItsInputs` holds the literal to the union of
their lineages plus `.device` for `migration_run`.

Two decisions inside that:

- **`.database` is not in its own contributor list.** It would make the
  assertion circular — the value under test would be one of its own inputs, and
  any superset would pass. `.device` is added explicitly instead.
- **`.trainingLoad` is not in it either**, because it stores no rows. The curve
  is computed; comparing it both ways is deferred to step 3.6 (§12.16).

The union at patch 281 is all six sources. That is not an artefact of being
generous — it is what "one database holds everything" means, and six sources on
the privacy pane is the correct disclosure rather than an embarrassing one.

### 12.27.7 The gap this patch opens rather than closes

A disconnect now removes the database folder while GRDB still holds the file
open. SQLite keeps working against the unlinked inode, so the rows survive until
the app is quit. Harmless while nothing reads them, and dishonest the moment
something does — so it is recorded as a gap against step 3.7 rather than fixed
here. Closing it means a real `close()` on `Sub4Launch.database`, which is a
change to a `private(set)` lifecycle and does not belong in a patch about prose.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.27",
)


def fail(msg):
    print("STOPPED — nothing was changed.")
    print("  " + msg)
    sys.exit(1)


buffers, applied = {}, []
for path, old, new, why in EDITS:
    if not path.exists():
        fail(f"missing: {path}")
    text = buffers.get(path, path.read_text())
    if new in text:
        fail(f"already applied? {path.name} — {why}")
    n = text.count(old)
    if n != 1:
        fail(f"{path.name} — {why}: expected one match, found {n}")
    buffers[path] = text.replace(old, new)
    applied.append((path, why))

if "--check" in sys.argv:
    print(f"All {len(applied)} anchors found. Nothing written (--check).")
    sys.exit(0)

for path, text in buffers.items():
    path.write_text(text)
for path, why in applied:
    print(f"  {path.relative_to(ROOT)} — {why}")
print(f"Done. {len(buffers)} files, {len(applied)} edits.")
