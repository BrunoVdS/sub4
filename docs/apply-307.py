#!/usr/bin/env python3
"""
Patch 307 — the path that wrote to the stores and not to the database.

D6b's last staleness window, named in a code comment two hundred patches before
it mattered. From Sub4App's header, unchanged since 215:

    NOTE FOR BACKGROUND REFRESH: it does NOT go through RootView. A background
    wake runs BackgroundRefresh.run() without building the scene, so anything it
    eventually needs from the database has to open it itself. Nothing does
    today; 3.3.3 will have to.

This is that. A BGAppRefreshTask pulls new activities into activities.json and,
until now, left the database untouched until somebody next opened and closed the
app. Everything else in D6b fires from the scene; this is the one path that
changes the stores with no scene to fire from.

  · `Sub4Launch.begin()`, NOT `Sub4Database.open()`. The obvious move would put
    a second DatabaseQueue on one SQLite file, and §12 already records what that
    costs: "the first symptom is a busy timeout on a screen nobody suspects."
    The gate that already exists is the answer.

  · AND THAT CREATES A RACE, so this closes it. `begin()` had exactly one caller
    until now, and one caller cannot race itself. Its guard is followed by an
    await, so two callers could both pass it and both open. It now holds the
    in-flight Task and a second caller awaits the first.

    Reachable rather than observed — it needs a scene construction and a
    background wake in the same instant. Written down as a race this patch
    CREATED, so a future reader does not find a defensive Task handle with no
    explanation and decide it is superstition.

  · NOT WHEN CANCELLED. A cancelled task means iOS is about to kill us; 0.33 s
    of SQLite then buys an interrupted `running` row rather than a write. The
    foreground catch-up takes it.

No new tests, and said rather than padded: BGAppRefreshTask, the scene lifecycle
and the real database file are all outside the suite. The verification is a
ledger row from a background refresh, appearing without the app being opened.

Files touched
  Sub4/BackgroundRefresh.swift         the write-through
  Sub4/Sub4Launch.swift                one open, even with two callers
  docs/ADR-0003-database-contract.md   + §12.51
  Sub4/AppVersion.swift                307

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


BGR = "Sub4/BackgroundRefresh.swift"
LAUNCH = "Sub4/Sub4Launch.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(BGR, r'''        let found = ActivityStore.shared.count - before
        record(found: found, cancelled: Task.isCancelled, manual: manual)''', r'''        let found = ActivityStore.shared.count - before
        record(found: found, cancelled: Task.isCancelled, manual: manual)

        // THE WRITE-THROUGH THIS PATH NEVER HAD — patch 307, §12.51.
        //
        // `Sub4App`'s header has said since 215 that a background wake runs
        // this WITHOUT building the scene, so anything needing the database has
        // to open it itself, and that "nothing does today; 3.3.3 will have to."
        // This is that.
        //
        // Until now a background refresh could pull new activities into
        // `activities.json` and leave the database untouched until the next
        // time somebody opened and closed the app. That was the largest
        // staleness window left in D6b.
        //
        // NOT IF CANCELLED. A cancelled task means iOS is about to kill us;
        // starting a third of a second of SQLite then buys an interrupted
        // `running` row instead of a write. The foreground catch-up takes it,
        // which is what "late rather than lost" is for.
        guard !Task.isCancelled else { return }

        // IDEMPOTENT, AND THE ONLY WAY TO GET A CONNECTION HERE. With the scene
        // built this is a no-op and hands back the launch's own database; on a
        // process woken for the task there is no other, and this opens it
        // properly — migration included — rather than a second queue on the
        // same file.
        await Sub4Launch.shared.begin()
        await DatabaseWriteThrough.shared.run(
            reason: manual ? "a refresh asked for in Settings"
                           : "a background refresh from iOS")
''', "the write-through this path never had")
edit(LAUNCH, r'''    /// Idempotent: `RootView`'s `.task` can be re-entered when the scene is
    /// rebuilt, and re-migrating on every scene change would be wasted work at
    /// best and a second connection at worst.
    func begin() async {
        guard case .opening = state else { return }

        // OFF THE MAIN ACTOR. On an existing install this is a few
        // milliseconds — `DatabaseMigrator` reads `grdb_migrations` and finds
        // nothing to do. On a fresh install it creates thirty-one tables and
        // their indexes. Neither belongs on the thread that draws the first
        // frame, and the second one is measurably not free.
        let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
            do { return .opened(try Sub4Database.open()) }
            catch { return .threw(String(describing: error)) }
        }.value

        switch outcome {
        case .opened(let db):
            database = db
            state = .ready
        case .threw(let message):
            state = .failed(message)
        }
    }''', r'''    /// Held while the open is in flight, so a second caller waits for the
    /// first rather than starting its own — patch 307.
    ///
    /// `begin()` had exactly one caller until 307, and one caller cannot race
    /// itself. `BackgroundRefresh.run()` is the second, and the guard below has
    /// a suspension point after it: two callers could both pass `case .opening`
    /// and both open a `DatabaseQueue` on the same file, which is the one thing
    /// `DatabaseHealthView.load()` is careful not to do.
    ///
    /// Reachable rather than observed. Writing it down as a race that 307
    /// CREATED, not one that has happened.
    private var opening: Task<Void, Never>?

    /// Idempotent: `RootView`'s `.task` can be re-entered when the scene is
    /// rebuilt, and re-migrating on every scene change would be wasted work at
    /// best and a second connection at worst.
    func begin() async {
        // A second caller waits for the first and gets the same database,
        // rather than returning early to find `database` still nil.
        if let opening { return await opening.value }
        guard case .opening = state else { return }

        let work = Task { @MainActor in
            // OFF THE MAIN ACTOR. On an existing install this is a few
            // milliseconds — `DatabaseMigrator` reads `grdb_migrations` and
            // finds nothing to do. On a fresh install it creates thirty-one
            // tables and their indexes. Neither belongs on the thread that
            // draws the first frame, and the second one is measurably not free.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                do { return .opened(try Sub4Database.open()) }
                catch { return .threw(String(describing: error)) }
            }.value

            switch outcome {
            case .opened(let db):
                self.database = db
                self.state = .ready
            case .threw(let message):
                self.state = .failed(message)
            }
        }
        // Assigned with no suspension point between, so on the main actor this
        // and the line above are one step and a second caller cannot slip in.
        opening = work
        await work.value
    }
''', "one open, even with two callers")

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.51 The path that wrote to the stores and not to the database — patch 307

D6b's last staleness window, and it was named in a code comment two hundred
patches before it mattered.

### 12.51.1 What `Sub4App` predicted

From patch 215's header, unchanged since:

> **NOTE FOR BACKGROUND REFRESH:** it does NOT go through `RootView`. A
> background wake runs `BackgroundRefresh.run()` without building the scene, so
> anything it eventually needs from the database has to open it itself. Nothing
> does today; 3.3.3 will have to.

This is that. A `BGAppRefreshTask` fetches new activities from Strava, writes
`activities.json` and up to three details — and until now left the database
untouched until somebody next opened and closed the app.

Everything else in D6b fires from the scene. This is the one path that changes
the stores with no scene to fire from, which is exactly why it was the last one
left and the easiest to forget.

### 12.51.2 `Sub4Launch.begin()`, not a second connection

The obvious move is `try Sub4Database.open()`. It is wrong: with the scene alive
that is a second `DatabaseQueue` on one SQLite file, and §12 already records
what that costs — *"the first symptom of that is a busy timeout on a screen
nobody suspects."*

`Sub4Launch.begin()` is idempotent, opens off the main actor, and runs the
migration. With the scene built it is a no-op that hands back the launch's own
connection; on a process woken for the task there is no other connection and
this creates the right one. **The gate that already exists is the answer, and
reaching for a new one would have introduced the defect the old one prevents.**

### 12.51.3 A race this patch creates, written down as created

`begin()` had exactly one caller until now, and one caller cannot race itself.
Its guard is followed by a suspension point:

```swift
guard case .opening = state else { return }
let outcome = await Task.detached { … }.value      // ← both callers get here
```

With a second caller, two could pass the guard and both open a queue on the same
file. `begin()` now holds the in-flight `Task`, so a second caller **awaits the
first and gets the same database** rather than starting its own — or returning
early to find `database` still nil, which would have been the lazy fix and would
have made the background write-through report `.noDatabase` for no reason.

Reachable rather than observed. It needs a scene construction and a background
wake in the same instant, which is unlikely and not impossible. Recorded as a
race **created by this patch**, because the alternative is a future reader
finding a defensive `Task` handle with no explanation and deciding it is
superstition.

### 12.51.4 What it does not do, on purpose

**It does not run when the task was cancelled.** A cancelled `BGAppRefreshTask`
means iOS is about to stop us; starting a third of a second of SQLite then buys
an interrupted `running` row rather than a write. The foreground catch-up takes
it, which is the whole point of §12.50's second trigger.

**It does not reconcile**, like every automatic run — §12.46.3.

**It costs about half a second** of a roughly thirty-second budget: the
migration check on an existing install is a few milliseconds, the import is
0.33 s, and constructing the stores that have not been touched yet in a woken
process is a handful of file reads. Repeated overruns make iOS schedule the app
less often, so this is worth stating as a measurement to take rather than an
assumption to keep: **the background refresh's own timing is not instrumented,
and this patch does not change that.**

### 12.51.5 No new tests, said rather than padded

`BGAppRefreshTask`, the scene lifecycle and `Sub4Database.open()`'s real file
are all outside the suite. Second patch in three with nothing to add, and the
honest note is better than a test that exercises something adjacent and reads
like coverage.

The verification is the ledger: a row whose reason came from a background
refresh, appearing without the app having been opened.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.51")

edit(VER, "    static let patch = 306", "    static let patch = 307", "307")


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
    print("  1. run the suite — 828 in 82, nothing here is testable from it")
    print("  2. \u2318R, then Settings \u2192 Sync & data \u2192 the background-refresh")
    print("     'Check now' button. That runs the same code path with")
    print("     manual: true, so the ledger should gain a row saying so.")
    print("  3. the real proof is slower: leave the app closed, let iOS wake it")
    print("     on its own, and look for a ledger row you did not cause.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
