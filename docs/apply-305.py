#!/usr/bin/env python3
"""
Patch 305 — usually is not a mechanism.

302's trigger was `Task { await run(...) }` fired from the scene-phase change at
`.background`. An unstructured task suspends at its first `await` and has NO
claim on the process: iOS may suspend the app before it resumes, and the run
itself goes to `Task.detached(priority: .utility)`, which is exactly the work
the system drops first while winding an app down.

It probably worked most of the time. That is the problem with it. A trigger that
works most of the time makes a database that is usually current, and "usually
current" is indistinguishable from "current" until the day it matters.

§12.46.2.1 argued the trigger was sound because a missed run is LATE RATHER THAN
LOST. That argument is correct and was doing work it cannot do: it justifies
having FEW triggers, not having an UNRELIABLE one. Nothing in it says the app
will ever get around to the late run.

THE FIX IS AN ORDERING.

  · `beginBackgroundTask` is taken SYNCHRONOUSLY in the scene-phase callback,
    before any suspension point. An assertion requested after the first `await`
    is an assertion requested from code that may never run.
  · If the expiration handler fires, the run is abandoned mid-write and leaves
    a `running` row the ledger already reports as an interrupted run.
  · If iOS declines the assertion, nothing is attempted — not a failed write,
    and not recorded as one.

AND A SECOND TRIGGER, WHICH IS WHERE THE GUARANTEE LIVES: returning to the
foreground, gated on having come from `.background` so a notification banner
does not fire one. A background/foreground cycle now does two runs at 0.33 s
each, and the redundancy is the point — the first is best-effort, the second is
certain. `Runs since launch` rising by TWO per cycle is what a working pair
looks like.

NOT UNIT-TESTABLE, and said plainly rather than padded with a test that proves
something else: `UIApplication` and the scene lifecycle are not reachable from
the suite. The verification is on the device — background, return, and watch the
counter move by two.

Files touched
  Sub4/DatabaseWriteThrough.swift      the assertion, and a synchronous entry
  Sub4/ContentView.swift               both triggers
  docs/ADR-0003-database-contract.md   + §12.49
  Sub4/AppVersion.swift                305

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
CONTENT = "Sub4/ContentView.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(WT, "import Foundation",
     "import Foundation\nimport UIKit",
     "UIKit, for the assertion")

edit(WT, "    func run(reason: String) async {",
     r'''    /// The assertion held while a backgrounding run finishes. `.invalid` when
    /// none — see `runOnBackgrounding`.
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    /// THE TRIGGER, WITH THE TIME TO FINISH — patch 305.
    ///
    /// Synchronous on purpose. 302 called `Task { await run(…) }` straight from
    /// the scene-phase change; that task suspends at its first `await` and has
    /// no claim on the process, so iOS is free to suspend the app before it
    /// ever resumes. It usually completed, because the run is a third of a
    /// second. **Usually is not a mechanism.**
    ///
    /// `beginBackgroundTask` is taken here, BEFORE any suspension point, which
    /// is the only ordering that works: an assertion requested after the first
    /// `await` is an assertion requested from code that may never run.
    ///
    /// The expiration handler is UIKit's promise that it will tell us before it
    /// kills us. If it fires, the run is abandoned mid-flight and leaves a
    /// `running` row the ledger already reports as an interrupted run — which
    /// is the honest outcome and is why that row exists.
    func runOnBackgrounding() {
        guard assertion == .invalid else { return }

        assertion = UIApplication.shared
            .beginBackgroundTask(withName: "sub4.write-through") { [weak self] in
                // Documented to arrive on the main thread. `assumeIsolated`
                // rather than a new `Task`, because scheduling work at
                // expiration is scheduling work that will not run.
                MainActor.assumeIsolated { self?.releaseAssertion() }
            }
        guard assertion != .invalid else {
            // iOS declined. Not an error and not a failure to write — nothing
            // was attempted, and the catch-up on the way back will do it.
            return
        }

        Task {
            await run(reason: "the app went to the background")
            releaseAssertion()
        }
    }

    private func releaseAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

''' + "    func run(reason: String) async {",
     "the assertion, taken before any await")

edit(CONTENT, r'''        .onChange(of: scenePhase) { _, phase in
            // Ask for the next background wake on the way out. Submitting again
            // replaces the pending request rather than stacking a second one,
            // so this is safe to call on every backgrounding.
            if phase == .background {
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
            }
        }''', r'''        .onChange(of: scenePhase) { previous, phase in
            // Ask for the next background wake on the way out. Submitting again
            // replaces the pending request rather than stacking a second one,
            // so this is safe to call on every backgrounding.
            if phase == .background {
                BackgroundRefresh.schedule()
                // PATCH 305 — NOT `Task { … }`, and that is the whole fix.
                //
                // 302 wrote `Task { await run(...) }` here. An unstructured task
                // started at `.background` suspends at its first `await` and has
                // no claim on the process: iOS can suspend the app before it
                // resumes, and a detached `.utility` child is exactly what gets
                // dropped first. It usually worked. Usually is not a mechanism.
                //
                // `runOnBackgrounding()` takes a `beginBackgroundTask`
                // assertion SYNCHRONOUSLY, before any suspension point, and
                // releases it when the run is done. §12.49.
                DatabaseWriteThrough.shared.runOnBackgrounding()
            }
            // AND THE CATCH-UP. Coming back from the background is the moment
            // the app definitely has time, so it is where "a missed trigger is
            // late rather than lost" stops being a hope.
            //
            // `previous == .background` on purpose: Control Centre and
            // notification banners give `.inactive`, and returning from one of
            // those would otherwise fire a run every time a banner appeared.
            if previous == .background, phase == .active {
                Task {
                    await DatabaseWriteThrough.shared
                        .run(reason: "the app came back to the foreground")
                }
            }
        }
''', "both triggers")

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.49 Usually is not a mechanism — patch 305

302's trigger was:

```swift
if phase == .background {
    Task { await DatabaseWriteThrough.shared.run(reason: "…") }
}
```

It probably worked most of the time, and that is the problem with it.

### 12.49.1 What is actually wrong

An unstructured `Task` started at `.background` **suspends at its first `await`
and has no claim on the process.** iOS may suspend the app before it resumes.
The run itself is then handed to `Task.detached(priority: .utility)`, which is
precisely the class of work the system drops first when it is winding an app
down.

So the design was: *ask for a third of a second of work at the exact moment the
system has decided to stop giving us any, and hope the window is wide enough.*
Against a 0.33 s run it usually is.

**Usually is not a mechanism.** A trigger that works most of the time produces a
database that is usually current, and "usually current" is indistinguishable
from "current" until the day it matters — which is the same shape as every
diagnostic this file has had to correct.

Recorded plainly because it was mine, and because §12.46.2.1 argued the trigger
was sound on the grounds that a missed run is *late rather than lost*. That
argument is correct and it was doing work it could not do: it justifies having
**few** triggers, not having an **unreliable** one. Nothing in it says the app
will ever get around to the late run.

### 12.49.2 The fix is an ordering, not a bigger hammer

`beginBackgroundTask` is requested **synchronously in the scene-phase callback,
before any suspension point.** That ordering is the whole of it: an assertion
requested after the first `await` is an assertion requested from code that may
never run.

The expiration handler is UIKit's promise to warn before killing. If it fires,
the run is abandoned mid-write and leaves a `running` row that the ledger
already reports as an interrupted run — the honest outcome, and the reason
§12.46.2.1's "degrades into the state it was built to report" was the right
instinct even while the mechanism under it was not.

If iOS declines the assertion outright, nothing is attempted. That is not a
failed write and is not recorded as one.

### 12.49.3 And a second trigger, which is where the guarantee lives

**Returning to the foreground.** That is the moment the app definitely has time,
and it is what turns *late rather than lost* from an argument into a property.

Gated on `previous == .background`, because Control Centre and notification
banners produce `.inactive` — returning from a banner would otherwise fire a run
every time one appeared.

A background/foreground cycle therefore does **two** runs, and the redundancy is
deliberate rather than tolerated: the first is best-effort and the second is
certain, each costs 0.33 s, and the import has been idempotent since long before
anything depended on it. The observable signature is useful too —
`Runs since launch` rising by two per cycle is what a working pair looks like.

### 12.49.4 The gap this does not close, named rather than left

**`BackgroundRefresh.run()` mutates the stores and never writes through.**

It is a `BGAppRefreshTask`: it fetches activities from Strava, writes
`activities.json` and up to three details, and runs **without the scene being
built** — `Sub4App`'s own comment says so. So `Sub4Launch.shared.database` is
nil there, and a write-through from it would have to open its own connection,
which is the one thing `DatabaseHealthView` is careful not to do.

Today that is survivable: the next foreground `.active` catch-up picks up
whatever the background refresh wrote. It is the largest remaining staleness
window in D6b and it belongs to its own patch, alongside groundwork §5.4's
`trigger` column.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.49")

edit(VER, "    static let patch = 304", "    static let patch = 305", "305")


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
    print("  2. \u2318R, Database, note `Runs since launch`")
    print("  3. swipe to the home screen, wait two seconds, come back")
    print("     — it should be UP BY TWO. One for the backgrounding, one for")
    print("       the return. Two is the pair working; one means the")
    print("       assertion was declined and the catch-up saved it; zero")
    print("       means neither fired and I have the wrong lifecycle hook.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
