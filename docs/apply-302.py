#!/usr/bin/env python3
"""
Patch 302 — write-through, and the seam that was not there. D6b step 2.

The groundwork was wrong about the most important thing in it, and reading the
source is what said so.

§5.1 proposed raising a dirty flag in `StoreWriteJournal.attempt`, "which every
store already passes through". It does not. There are THREE write paths:

  1. StoreWriteJournal.attempt  — six stores
  2. StoreWrite.encode, thrown  — notes.json, commutes.json (the watched writes)
  3. UserDefaults.set           — match decisions, rejection receipts, skips

A flag in (1) would have missed NOTES and MATCH DECISIONS — the two things in
this app that cannot be re-fetched from anywhere.

SO THERE IS NO DIRTY FLAG. Not one that moved somewhere better — none. A dirty
flag fails silently; a whole-world run fails by being late; and the run costs
0.325 s. An optimisation with a silent failure mode, bought against a third of a
second, is not worth having.

  · One trigger: backgrounding, beside BackgroundRefresh.schedule().
  · Coalescing is one boolean — a trigger mid-run makes the run repeat once.
  · Failures go in StoreWriteJournal under sub4.sqlite, so Settings and the tab
    badge already show them.
  · AUTOMATIC RUNS DO NOT DELETE. reconcile is overridden to .skipped INSIDE
    writeThrough so a future trigger cannot forget. The cost — deletions not
    propagating until somebody presses Import — is on screen and in §12.46.3.

ONE NEW FILE EACH SIDE, so this needs a full quit and reopen:
  Sub4/DatabaseWriteThrough.swift
  Sub4CoreTests/DatabaseWriteThroughTests.swift

Files touched
  Sub4/ContentView.swift                    the trigger
  Sub4/DatabaseHealthView.swift             the section
  docs/D6B-WRITE-THROUGH-GROUNDWORK.md      §5.1 corrected, §5.2 answered
  docs/ADR-0003-database-contract.md        + §12.46
  Sub4/AppVersion.swift                     302

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


CONTENT = "Sub4/ContentView.swift"
VIEW = "Sub4/DatabaseHealthView.swift"
GW = "docs/D6B-WRITE-THROUGH-GROUNDWORK.md"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(CONTENT,
     "            if phase == .background { BackgroundRefresh.schedule() }",
     r'''            if phase == .background {
                BackgroundRefresh.schedule()
                // PATCH 302 — D6b. The one automatic trigger, deliberately.
                //
                // A whole-world run costs 0.325 s and copies everything, so a
                // missed trigger is LATE rather than a gap — which is why one
                // trigger is enough to start with, and why no dirty flag is
                // tracked. §12.46.
                //
                // The task may not finish if iOS suspends us first. That is
                // survivable: an interrupted run leaves a `running` row the
                // ledger already reports as "Interrupted runs", and the next
                // background does the work again.
                Task {
                    await DatabaseWriteThrough.shared
                        .run(reason: "the app went to the background")
                }
            }''',
     "the trigger, beside the one already there")

edit(VIEW,
     "    @State private var surveying = false",
     r'''    /// Patch 302. Observed rather than read once: it changes while this screen
    /// is open, on any backgrounding.
    @State private var writeThrough = DatabaseWriteThrough.shared''' + "\n    @State private var surveying = false",
     "the screen observes it")

edit(VIEW,
     "                    importSection(db)",
     "                    importSection(db)\n" + r'''                    // PATCH 302. Directly after the Import section, because it
                    // IS that import — fired without anybody pressing it. The
                    // screen reads in the order the two things relate: here is
                    // the button, and here is what happens when nobody presses
                    // it.
                    writeThroughSection''',
     "the section, after the button it automates")

edit(VIEW,
     "    @ViewBuilder\n    private var ledgerSection: some View {",
     r'''    /// PATCH 302 — D6b, §12.46.
    ///
    /// NO "LAST WRITTEN" FROM DISK. This reads only what has happened since
    /// launch, and says so in as many words. A persisted timestamp would be a
    /// second answer to a question `migration_run` already answers, and two
    /// answers is how §12.29's problem starts.
    @ViewBuilder
    private var writeThroughSection: some View {
        Section {
            if writeThrough.isRunning {
                HStack { ProgressView(); Text("Writing through…").font(.caption) }
            } else {
                Button("Write through now") {
                    Task { await writeThrough.run(reason: "asked for on this screen") }
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
                 + "the database until then. See ADR-0003 §12.46.")
                .font(.caption2)
        }
    }

''' + "    @ViewBuilder\n    private var ledgerSection: some View {",
     "the section itself")

edit(GW, r'''### 5.1 What fires it

Not per-store. `ActivityStore.ingest()` is where a sync finishes, but
`DetailStore` finishes later and independently in two separate `defer`s, and
notes and commutes are written by a person at any moment.

So: a **coalescing trigger** — something marks the database dirty, and one run
is scheduled that absorbs every mark arriving before it starts. `StoreWriteJournal.attempt`
is the natural place to raise the flag, since every store already passes through
it and it already knows the store's name.

Open: whether the flag lives on the journal or beside it. The journal's stated
job is "which stores are behind their memory", and "the database is behind the
files" is a different sentence about a different thing.

### 5.2 What a failed database write does

Reuse `StoreWriteJournal` with a store named for the database. Its contract —
*memory keeps what was fetched, the disagreement is recorded, a successful write
clears it, Settings shows it* — is the same sentence for the database as for a
file, and it is already built, already tested, and already on screen.

Rolling anything back is wrong for the same reason 266 gives: the data came off
the network a moment ago, and discarding it to buy consistency nobody asked for
shows the athlete less than the app has.

''', r'''### 5.1 What fires it

**ANSWERED AT 302, and this section was wrong about the most important thing in
it.** Kept rather than rewritten, because the correction is the finding.

It said `StoreWriteJournal.attempt` was where "every store already passes
through". It is not. There are three write paths — `attempt` (six stores),
`StoreWrite.encode` thrown (notes and commutes, the watched writes), and
`UserDefaults.set` (match decisions, rejection receipts, skip lists, the sync
cursor). A flag raised in the first would have missed notes and match decisions,
the two things in this app that cannot be re-fetched from anywhere.

**So there is no dirty flag.** Not one that moved somewhere better — none. A
dirty flag fails silently, a whole-world run fails by being late, and the run
costs 0.325 s. An optimisation with a silent failure mode, bought against a
third of a second, is not worth having. §12.46.2.

**The trigger:** backgrounding, in `ContentView`'s existing `onChange(of:
scenePhase)`. One, because a missed trigger is late rather than lost. More are
a later patch and each is one line.

Original text, for the record: *"a coalescing trigger — something marks the
database dirty… `StoreWriteJournal.attempt` is the natural place to raise the
flag, since every store already passes through it."*

### 5.2 What a failed database write does

**Answered at 302, as written.** `StoreWriteJournal` records it under
`Sub4Database.fileName`, so Settings shows it and the tab badge lights, with no
new surface. A successful run clears the entry, which is the journal's own rule.

Nothing rolls back, for the reason 266 gives.

One addition the original did not anticipate: **`.noDatabase` is not recorded
there.** The launch gate having no database is its own condition with its own
screen, and filing it in a list whose whole job is to be empty would put a
permanent row in it.

''', "\u00a75.1 corrected, \u00a75.2 answered")

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.46 Write-through, and the seam that was not there — D6b step 2, patch 302

The groundwork was wrong about the most important thing in it, and reading the
source is what said so.

### 12.46.1 Three write paths, not one

`D6B-WRITE-THROUGH-GROUNDWORK.md` §5.1 proposed raising a dirty flag in
`StoreWriteJournal.attempt`, *"which every store already passes through and
which already knows the store's name"*.

It does not. There are three:

| | path | stores |
|---|---|---|
| 1 | `StoreWriteJournal.attempt` | activities.json, constants.json, athlete.json, details/ and streams/, proposals.json, weather.json |
| 2 | `StoreWrite.encode`, thrown | notes.json, commutes.json — the WATCHED writes that roll back, §12.17 |
| 3 | `UserDefaults.set` | match decisions, rejection receipts, the detail store's skip lists, the sync cursor |

A flag raised in (1) covers six and misses **notes and match decisions** — the
two things in this app that cannot be re-fetched from anywhere. That is the
worst possible half to miss.

The claim was made from memory of a comment rather than from the call sites.
Patch 266's header says *"every store's `save()` goes through here"*, and it
meant every store 266 touched. Recorded because it is the same failure as
§12.40.5 — **prose describing a scope it never had, believed later by the person
who wrote it.**

### 12.46.2 So there is no dirty flag at all

Not "the flag moved somewhere better". There is none.

**The failure modes are not comparable.** A dirty flag fails SILENTLY: a store
that forgets to mark never reaches the database, and nothing says so — the
read-back would report its rows as missing data, which is §12.35.4's confusion
again. A whole-world run fails by being LATE: a missed trigger is picked up by
the next one, because the run does not depend on knowing what changed.

And the flag buys almost nothing. §12.42.3 measured a full run at **0.325 s**,
because the importer already skips a trace whose stored `fetchedUTC` matches.

> **A dirty flag is an optimisation with a silent failure mode, bought against a
> third of a second.**

That is the whole design decision, and it is why 302 has no `markDirty`, no
coalescing window and no timer. Coalescing is one boolean: a trigger arriving
mid-run makes the current run repeat once when it finishes.

#### 12.46.2.1 One trigger, on purpose

Backgrounding, in `ContentView`'s existing `onChange(of: scenePhase)` — beside
`BackgroundRefresh.schedule()`, which is already there for the same reason.

One is enough to start **because a missed trigger is late rather than lost.** If
the app is suspended before the task finishes, the ledger records a `running`
row and already reports it as "Interrupted runs", and the next backgrounding
does the work again. The design degrades into the state it was built to report.

More triggers — after a sync, on foreground after a long gap — are a later
patch, and each is one line. Adding them now would be adding untested paths to
the patch that first fires this unattended.

### 12.46.3 Automatic runs do not delete, and what that costs

`AppStores.current()` sets `reconcile` to `.run` whenever the four gated stores
read trustworthily, and reconciliation **deletes** rows the app no longer has.

Doing that by hand with the report on screen is one thing. Doing it unattended,
several times a day, is a different blast radius, and 302 is the patch that
makes it unattended. So `writeThrough` overrides it to `.skipped`, **inside the
function rather than at the call site**, so a future trigger cannot forget.

**The cost, owned rather than buried:** a note or a match decision deleted in the
app stays in the database until somebody presses Import. The three read-backs
would not notice — they report what the store has and the database does not,
never the reverse.

So this patch makes surplus rows in the database more likely, and nothing
currently detects them. That is D6c's question. It is written here so the next
person to find one knows it was a decision, not an accident, and the screen's
footer says it in plain words rather than leaving it to be discovered.

### 12.46.4 What is deliberately still open

- **The ledger.** Every automatic run opens and closes a `migration_run` row, so
  "the last import" now means "the last backgrounding" — which is arguably the
  right answer once write-through exists, and arguably makes manual and
  automatic runs indistinguishable in a list built to tell them apart.
  Groundwork §5.4, still open, deliberately not changed in the patch that first
  calls the import unattended.
- **The cold path.** Unmeasured since 297 and unchanged by this.
- **Deletions.** §12.46.3.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.46")

edit(VER, "    static let patch = 301", "    static let patch = 302", "302")


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

    for f in ["Sub4/DatabaseWriteThrough.swift",
              "Sub4CoreTests/DatabaseWriteThroughTests.swift"]:
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
    print("  1. TWO NEW FILES — quit Xcode entirely (\u2318Q) and reopen")
    print("  2. run the suite")
    print("  3. \u2318R, then background the app (swipe up), reopen it,")
    print("     and read Database \u2192 Write-through. `Runs since launch` should")
    print("     be 1 or more and `Last run` should carry a time and a count.")
    print("  4. then the three read-backs, which should be at zero WITHOUT")
    print("     pressing Import — that is the whole rung working.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
