#!/usr/bin/env python3
"""
Patch 303 — two rows about one event.

302 was correct and looked broken, twice, for the same reason: a screen showing
two answers to one question with one of them wrong.

  1. "Write through now" appeared to do nothing. It did — `Last run` moved
     10:39:24 → 10:42:32 and `Runs since launch` went 3 → 4. What did not move
     was the Import ledger beside it, still showing the run that was current
     when the screen was last opened. `runImport` has always ended with
     `reloadLedger`; the write-through button did not.

     The symptom pointed at the wrong component: a stale READER made a working
     WRITER look dead.

  2. Every automatic run passed a nil snapshot id, and the ledger renders a
     missing snapshot in RED. From 302 onward the newest row would be red after
     every backgrounding, permanently, for a condition that is not a problem —
     §12.42.2's shape, written one patch earlier and committed in the next.

     Fixed by recording `LegacySnapshot.latest()?.id`, which is accurate and not
     convenient: an automatic run takes no snapshot, but one exists and it is
     the one that preceded the run. nil still means nil where none was ever
     taken — inventing one would claim a protected copy that does not exist.

Files touched
  Sub4/DatabaseWriteThrough.swift          the snapshot id
  Sub4/DatabaseHealthView.swift            the ledger reload, the footer
  Sub4CoreTests/DatabaseWriteThroughTests.swift  + three ledger tests
  docs/ADR-0003-database-contract.md       + §12.47
  Sub4/AppVersion.swift                    303

No new files. No restart needed.

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


WT = "Sub4/DatabaseWriteThrough.swift"
VIEW = "Sub4/DatabaseHealthView.swift"
TESTS = "Sub4CoreTests/DatabaseWriteThroughTests.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(WT, r'''            let outcome = await Task.detached(priority: .utility) {
                Self.writeThrough(db, stores: stores, appVersion: version)
            }.value''', r'''            let outcome = await Task.detached(priority: .utility) {
                // THE SNAPSHOT ID, AND IT IS NOT A FUDGE — patch 303.
                //
                // Contract item 11 asks every run to record which snapshot of
                // its inputs was taken first. An automatic run does not take
                // one, but one EXISTS, and it is genuinely the snapshot that
                // preceded this run — so recording it is accurate rather than
                // convenient.
                //
                // 302 passed nil, and the ledger renders a missing snapshot in
                // RED. Every backgrounding therefore left the newest ledger row
                // flagged for a problem it did not have, which is §12.42.2's
                // shape: a red row that is correct by rule, wrong in meaning,
                // and constant enough to train somebody to ignore the colour.
                //
                // File I/O, so it belongs inside this closure and not on the
                // main actor that called it.
                Self.writeThrough(db, stores: stores, appVersion: version,
                                  snapshotID: LegacySnapshot.latest()?.id)
            }.value''', "the snapshot that preceded the run")
edit(WT, r'''    nonisolated static func writeThrough(_ db: Sub4Database,
                                         stores: AppStores,
                                         appVersion: String) -> Outcome {''', r'''    nonisolated static func writeThrough(_ db: Sub4Database,
                                         stores: AppStores,
                                         appVersion: String,
                                         snapshotID: String? = nil) -> Outcome {''', "writeThrough takes a snapshot id")
edit(WT, r'''            return .wrote(try Sub4Import.run(into: db, stores: s,
                                             appVersion: appVersion), atUTC: at)''', r'''            return .wrote(try Sub4Import.run(into: db, stores: s,
                                             appVersion: appVersion,
                                             snapshotID: snapshotID), atUTC: at)''', "and forwards it")

edit(VIEW, r'''                    writeThroughSection''', "                    writeThroughSection(db)",
     "the section needs the connection")
edit(VIEW, r'''    private var writeThroughSection: some View {''', "    private func writeThroughSection(_ db: Sub4Database) -> some View {",
     "so its button can reload the ledger")
edit(VIEW, r'''                Button("Write through now") {
                    Task { await writeThrough.run(reason: "asked for on this screen") }
                }''', r'''                Button("Write through now") {
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
                }''', "the ledger reload 302 left out")
edit(VIEW, r'''                 + "the database until then. See ADR-0003 §12.46.")''', r'''                 + "the database until then. See ADR-0003 §12.46.\n\n"
                 + "The two figures above are for THIS LAUNCH only. The "
                 + "durable record is the import ledger below: after a "
                 + "write-through it is that run.")''', "the footer says which figure answers what")

edit(VIEW, r'''    /// What the last import did, and how it ended — patch 255.
    ///
    /// AFTER the import section, because it is the record of the button above
    /// it. The state is the row that matters: everything else on this screen
    /// says what the database CONTAINS, and this says whether anything has
    /// checked it.
    /// PATCH 302 — D6b, §12.46.''', r'''    /// PATCH 302 — D6b, §12.46.''', "302 stranded 255's comment")

edit(VIEW, r'''    @ViewBuilder
    private var ledgerSection: some View {''', r'''    /// What the last import did, and how it ended — patch 255.
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
    private var ledgerSection: some View {''', "and this is where it belongs")

edit(TESTS, r'''        #expect(DatabaseWriteThrough.Outcome.noDatabase
                != .failed("disk full", atUTC: "2026-08-07T12:00:00Z"),
                "one is the launch gate, the other is the write")
    }
}''', r'''        #expect(DatabaseWriteThrough.Outcome.noDatabase
                != .failed("disk full", atUTC: "2026-08-07T12:00:00Z"),
                "one is the launch gate, the other is the write")
    }

    // MARK: The ledger link — patch 303

    /// Contract item 11 asks every run to record which snapshot of its inputs
    /// was taken first. An automatic run takes none, but one EXISTS, and it is
    /// the snapshot that preceded this run — so recording it is accurate.
    ///
    /// 302 passed nil, and the ledger renders a missing snapshot in RED. Every
    /// backgrounding left the newest row flagged for a problem it did not have.
    @Test("An automatic run records the snapshot that preceded it")
    func theSnapshotReachesTheLedger() throws {
        let db = try Sub4Database.inMemory()
        _ = DatabaseWriteThrough.writeThrough(db, stores: stores([ride()]),
                                              appVersion: "303-test",
                                              snapshotID: "2026-08-05-202320")
        let run = try #require(try MigrationLedger.latest(db))
        #expect(run.snapshotID == "2026-08-05-202320")
        #expect(run.appVersion == "303-test")
    }

    /// AND NIL IS STILL NIL. On a device where no snapshot has ever been taken
    /// there is nothing to record, and inventing one would be worse than the
    /// red row — it would say a protected copy exists when none does.
    @Test("No snapshot anywhere is recorded as no snapshot")
    func noSnapshotStaysNone() throws {
        let db = try Sub4Database.inMemory()
        _ = DatabaseWriteThrough.writeThrough(db, stores: stores([ride()]),
                                              appVersion: "303-test")
        let run = try #require(try MigrationLedger.latest(db))
        #expect(run.snapshotID == nil)
    }

    /// Every run reaches the ledger, so the ledger — not the in-memory counter
    /// — is what answers "did this happen while I was not looking".
    @Test("Every write-through leaves a ledger row")
    func everyRunIsRecorded() throws {
        let db = try Sub4Database.inMemory()
        let s = stores([ride()])
        _ = DatabaseWriteThrough.writeThrough(db, stores: s, appVersion: "303-test")
        _ = DatabaseWriteThrough.writeThrough(db, stores: s, appVersion: "303-test")
        #expect(try MigrationLedger.all(db).count == 2)
    }
}''', "three ledger tests")

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.47 Two rows about one event — patch 303

302 was correct and looked broken. Both reasons are the same mistake in
different clothes: **a screen showing two answers to one question, one of them
wrong.**

### 12.47.1 The button that appeared to do nothing

Pressing "Write through now" twice left the Import ledger unmoved, and the
reasonable reading was that the button did nothing.

It did. `Last run` went 10:39:24 → 10:42:32 and `Runs since launch` went 3 → 4.
What did not move was the ledger row beside it, still showing 10:37:26 — the run
that was current the last time the screen was opened.

`runImport` has always ended with `await reloadLedger(db)`. The write-through
button did not, so two rows on one screen described the same event five minutes
apart. §12.34's shape: the older row was not wrong when it was written, and
nothing on screen said how old it was.

Three lines. The interesting part is that **the symptom pointed at the wrong
component.** A stale reader made a working writer look dead, and the first
instinct — mine included — was to doubt the trigger.

### 12.47.2 A red row that was correct and meant nothing

`ledgerSection` renders a missing `snapshotID` in **red**, which was right while
imports were rare and hand-pressed: a run with no protected copy of its inputs
is contract item 3 unmet, and worth shouting about.

302 passed `nil` for every automatic run. So from 302 onward the newest ledger
row would be red after every single backgrounding, permanently, for a condition
that is not a problem.

That is §12.42.2 again, one screen over — a red row that is correct by rule,
wrong in meaning, and frequent enough to train a reader out of believing the
colour. The last patch wrote §12.42.2 and the next one committed it.

**The fix is not to soften the colour.** An automatic run does not TAKE a
snapshot, but one exists, and it is genuinely the snapshot that preceded the
run. Recording `LegacySnapshot.latest()?.id` is accurate rather than convenient,
and it keeps contract item 11's link — *which snapshot of its inputs was taken
first* — true for automatic runs instead of quietly exempting them.

`nil` still means `nil`: on a device where no snapshot has ever been taken there
is nothing to record, and inventing one would be worse than the red row, because
it would claim a protected copy exists when none does. `noSnapshotStaysNone`
pins that.

### 12.47.3 What the in-memory figures can and cannot say

`Last run` and `Runs since launch` are held in memory on purpose — the question
they answer is *is this thing firing at all*, which is about now.

They cannot answer *did it fire while I was not looking*. After a relaunch the
section reads "Not run since this launch", which is true and is indistinguishable
from the trigger being broken.

The ledger already holds the durable answer, it is directly below, and after any
write-through it IS the newest row. So the footer now says which figure answers
which question rather than leaving a reader to work out that the two sections are
related. No second timestamp was added: two durable answers to one question is
the thing this section is about.

### 12.47.4 Still open, and now nameable

Manual and automatic runs are distinguishable in the ledger only by accident —
manual ones carry the snapshot the screen was holding, automatic ones carry the
latest on disk, and both are populated. `note` is already spent on the counts.

Telling them apart properly wants a `trigger` column on `migration_run`, which
is a migration and belongs in its own patch. Groundwork §5.4, still open, and
this is the second patch to decline it for the same reason: not in the one that
is fixing what the last one broke.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.47")

edit(VER, "    static let patch = 302", "    static let patch = 303", "303")


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

    if failures:
        print(f"\n{failures} anchor(s) failed — nothing written.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. run the suite")
    print("  2. \u2318R, Database, press 'Write through now'")
    print("     — the ledger below should now move WITH it, say patch 303,")
    print("       and carry a snapshot id rather than a red 'none taken'")
    print("  3. then background the app, reopen, and check the ledger again:")
    print("     a newer row means the trigger works and D6b's gate is met")
    return 0


if __name__ == "__main__":
    sys.exit(main())
