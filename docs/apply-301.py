#!/usr/bin/env python3
"""
Patch 301 — everything the app holds, as one value. D6b step 1.

It writes nothing. It exists because of what the trigger design found.

`Sub4Import.run` takes twenty parameters and eighteen are defaulted.
`SemanticVerifier.attempt` takes fourteen, thirteen defaulted, sharing thirteen
expressions with the import. Both lists were assembled BY HAND inside
`DatabaseHealthView`, forty lines apart — and D6b's trigger would have been the
third copy, in code that runs unattended.

The hazard is the defaults, not the duplication. A forgotten argument is not a
compile error; it is a table that silently stops being imported, which a
read-back then reports as data missing from the database.

  · `AppStores` — one Sendable value, one field per store, `@MainActor
    current()` that reads them all. Sendable because D6b hands it to a
    detached task, and that is better found out in a patch that changes
    nothing.
  · `Sub4Import.run(into:stores:)` and `SemanticVerifier.attempt(_:stores:)` —
    OVERLOADS that forward field by field. Both granular signatures untouched,
    so no existing test moves.
  · Patch 274's reconcile gate moved with it, verbatim. `canReconcile` fails
    closed, so a name MISSING from its list makes reconciliation more likely to
    RUN, and reconciliation deletes. That is a delete hazard living in a view.

NO BEHAVIOUR CHANGE. The proof is that the three read-backs are unmoved at
672 / 672 / 649, and if the extraction dropped a table they say which.

ONE NEW FILE EACH SIDE, so this needs a full quit and reopen:
  Sub4/AppStores.swift
  Sub4CoreTests/AppStoresTests.swift

Files touched
  Sub4/DatabaseHealthView.swift        both call sites collapse
  docs/ADR-0003-database-contract.md   + §12.45
  Sub4/AppVersion.swift                301

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


VIEW = "Sub4/DatabaseHealthView.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(VIEW, r'''                // PATCH 274 — THE GATE, asked here because this is the only
                // place the answer is knowable: `Sub4Import` is `nonisolated`
                // end to end and `StoreReadJournal` is on the main actor.
                //
                // Every store the pass deletes on behalf of has to have been
                // READ. `canReconcile` fails closed on any that never
                // reported, so wiring a fourth table into the pass and
                // forgetting to name its store here refuses rather than
                // deletes.
                //
                // A LOCAL WITH A WRITTEN TYPE, not a ternary in the argument
                // list. Both branches are implicit-member expressions and the
                // reader of this line should not have to work out what type
                // they resolve to.
                let permission: Reconciliation =
                    StoreReadJournal.shared.canReconcile(
                        ["notes.json", "proposals.json", "commutes.json",
                         Matcher.decisionsKey])
                    ? .run
                    : .skipped("a store could not be read")

                importReport = try Sub4Import.run(
                    into: db,
                    activities: ActivityStore.shared.activities,
                    // ALL GEAR, not just shoes — patch 267. The `gear` table
                    // holds anything an activity can name, and a bike that is
                    // not in it is 287 activities naming gear the database does
                    // not hold.
                    shoes: AthleteStore.shared.allGear,
                    notes: Array(NotesStore.shared.notes.values),
                    proposals: ProposalStore.shared.records,
                    matchDecisions: Array(Matcher.shared.decisions.values),
                    syncState: ActivityStore.shared.syncState,
                    workItems: DetailStore.shared.workItems,
                    rejections: ActivityStore.shared.receipts,
                    commutes: Array(CommuteStore.shared.decisions.values),
                    reconcile: permission,
                    weather: Array(WeatherStore.shared.byActivity.values),
                    constants: ConstantsStore.shared.c,
                    ftpWatts: AthleteStore.shared.ftp,
                    zones: AthleteStore.shared.hrZones,
                    plan: PlanStore.shared.plan,
                    streams: Array(DetailStore.shared.streams.values),
                    details: Array(DetailStore.shared.details.values),
                    appVersion: AppVersion.patchLabel,
                    // The link between contract items 3 and 11: a run records
                    // which snapshot of its inputs was taken first, or records
                    // that none was.
                    snapshotID: snapshot?.id)''', r'''                // ONE VALUE, GATHERED IN ONE PLACE — patch 301, §12.45.
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
                    snapshotID: snapshot?.id)''', "the import gathers once")
edit(VIEW, r'''            let report = SemanticVerifier.attempt(
                db,
                activities: ActivityStore.shared.activities,
                shoes: AthleteStore.shared.allGear,
                notes: Array(NotesStore.shared.notes.values),
                proposals: ProposalStore.shared.records,
                syncState: ActivityStore.shared.syncState,
                workItems: DetailStore.shared.workItems,
                rejections: ActivityStore.shared.receipts,
                commutes: Array(CommuteStore.shared.decisions.values),
                matchDecisions: Array(Matcher.shared.decisions.values),
                weather: Array(WeatherStore.shared.byActivity.values),
                zones: AthleteStore.shared.hrZones,
                streams: Array(DetailStore.shared.streams.values),
                details: Array(DetailStore.shared.details.values))''', r'''            // The same gathered value the import uses — 301. The verifier
            // reads a subset of it on purpose; see the overload's comment.
            let report = SemanticVerifier.attempt(db, stores: AppStores.current())''', "the verifier uses the same value")
edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.45 Everything the app holds, as one value — D6b step 1, patch 301

The first patch of the write-through rung, and it writes nothing. It exists
because of what was found when the trigger was designed.

### 12.45.1 Eighteen defaulted parameters and two hand-written call sites

`Sub4Import.run` takes twenty parameters; eighteen have defaults.
`SemanticVerifier.attempt` takes fourteen; thirteen have defaults, and thirteen
of the expressions feeding it are the same ones the import gets. Both lists were
assembled by hand inside `DatabaseHealthView`, forty lines apart:

    ActivityStore.shared.activities          AthleteStore.shared.allGear
    Array(NotesStore.shared.notes.values)    ProposalStore.shared.records
    ActivityStore.shared.syncState           DetailStore.shared.workItems
    ActivityStore.shared.receipts            Array(CommuteStore.shared.decisions.values)
    Array(Matcher.shared.decisions.values)   Array(WeatherStore.shared.byActivity.values)
    AthleteStore.shared.hrZones              Array(DetailStore.shared.streams.values)
    Array(DetailStore.shared.details.values)

**D6b's trigger would have been the third copy**, in code that runs unattended.

The hazard is not the duplication. It is the defaults: a forgotten argument is
not a compile error, it is **a table that quietly stops being imported**, and
nothing on any screen says so. A read-back would report those rows as missing
from the database — which reads as a data problem rather than as a forgotten
line, and is exactly the confusion §12.35.4 keeps naming.

This is §12.41.1's argument arriving from a direction it did not anticipate.
That section said not to hand-write seventeen incremental writers because each
is a chance to be wrong. The single writer that already exists has seventeen
chances to be **called** wrong, and two of them were live.

### 12.45.2 What it is, and what it deliberately is not

`AppStores` is a `Sendable` value with one field per store and a
`@MainActor current()` that reads them all. `Sub4Import.run(into:stores:)` and
`SemanticVerifier.attempt(_:stores:)` are **overloads** that forward field by
field; both granular signatures are untouched, so every existing import test
still calls what it called.

It changes no behaviour. That is the point: the proof is that the three
read-backs are unmoved at 672 / 672 / 649, and if the extraction dropped a table
they say which.

`Sendable` is not decoration. D6b hands this to a detached task after a sync,
and whether the app's own data can cross an isolation boundary is better found
out in a patch that changes nothing than in the one that adds a trigger.

**Not "snapshot".** `LegacySnapshot` and `SnapshotManifest` already mean *a
protected copy of the input files taken before anything decodes them* —
contract item 3. A third meaning for that word in the same subsystem costs a
reader more than the name is worth.

### 12.45.3 The gate moved, because a missing name there deletes

Patch 274's reconcile permission was computed in the view from a hand-written
list of store names, and `canReconcile` fails **closed** on any store that never
reported.

Read the failure direction carefully. A name that is **present** and untrusted
refuses — that is the gate working. A name that is **missing from the list
entirely** is never checked, so `canReconcile` is more likely to return true,
so reconciliation runs, so rows are deleted. **A forgotten name there is a
delete hazard, not a skip hazard**, and it lived in a view forty lines from the
argument list it governed.

`AppStores.reconcileRequires` holds it now, verbatim, beside the fields it is
about, pinned by a test.

Making the list **derive** from the fields is the right end state and is a
separate patch. Mixing a permissions change into a mechanical extraction would
make both harder to check, and this one is checked by a read-back that has to
come out identical.

### 12.45.4 A count is not a proof, and the comment says so

`AppStores.fieldCount` is pinned at seventeen and `theFieldCountIsPinned`
asserts `Mirror` agrees. That does not prove the forwarding — it makes adding a
field something somebody has to acknowledge, which is the half that is cheap.

Three fields are proved to land end-to-end, and `reconcile` gets its own test
because it is the one that deletes: a forwarding that dropped it would default
to skipping, which is safe, and one that inverted it would not — and only one of
those is visible without looking.

Stated at its real strength rather than dressed up. The same honesty §12.39.6.1
applies to `samplesWalked`: a check that can only report success has not been
tested.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.45")
edit(VER, "    static let patch = 300", "    static let patch = 301", "301")


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

    for f in ["Sub4/AppStores.swift", "Sub4CoreTests/AppStoresTests.swift"]:
        here = (ROOT / f).exists()
        print(f"{'ok      ' if here else 'MISSING '} {f}  (copied from the zip)")
        if not here:
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
    print("  1. TWO NEW FILES — quit Xcode entirely (\u2318Q) and reopen before building")
    print("  2. run the suite")
    print("  3. \u2318R, Database, press Import, then all three read-backs")
    print("     — they must still read 672 / 672 / 649 with zero missing.")
    print("     A dropped table shows up there and says which.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
