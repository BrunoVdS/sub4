#!/usr/bin/env python3
"""
Patch 306 — a transition that does not happen.

305's catch-up was gated `if previous == .background, phase == .active`.

SWIFTUI NEVER DELIVERS THAT TRANSITION. Going out is
`.active -> .inactive -> .background`; coming back is
`.background -> .inactive -> .active`. At the step where `phase` is `.active`,
`previous` is ALWAYS `.inactive`. The condition could not be true, and the half
of 305 that was meant to turn "late rather than lost" into a property never
fired once.

The device said one run where two were predicted, and the prediction is what
made that readable — it narrowed it to "one of the two did not run", which sent
me to the transition sequence rather than to the assertion.

THE FIX IS STATE, NOT A BETTER PREDICATE. `previous == .background` was trying
to observe "we have been away" through a mechanism that cannot express it.
`runOnBackgrounding` sets a flag; `runOnReturn` consumes it. Set BEFORE the
assertion is requested, because a declined assertion is exactly the case the
catch-up exists for.

AND THE LEDGER FOLLOWS EVERY RUN. While the Database screen was open, an
automatic run moved `Last run` and left the ledger showing whatever was current
when the screen opened — which is what made a working trigger look dead, for the
second time in four patches. Now keyed on `runs`, so any trigger added later
inherits it.

REQUIRES 305. If apply-305.py has not been run, the anchors here will not match
and this will refuse.

Files touched
  Sub4/ContentView.swift               the phase switch
  Sub4/DatabaseWriteThrough.swift      the flag, and runOnReturn
  Sub4/DatabaseHealthView.swift        the ledger follows every run
  docs/ADR-0003-database-contract.md   + §12.50
  Sub4/AppVersion.swift                306

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


CONTENT = "Sub4/ContentView.swift"
WT = "Sub4/DatabaseWriteThrough.swift"
VIEW = "Sub4/DatabaseHealthView.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(CONTENT, r'''        .onChange(of: scenePhase) { previous, phase in
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
        }''', r'''        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Ask for the next background wake on the way out. Submitting
                // again replaces the pending request rather than stacking a
                // second one, so this is safe to call on every backgrounding.
                BackgroundRefresh.schedule()
                DatabaseWriteThrough.shared.runOnBackgrounding()

            case .active:
                // THE CATCH-UP, AND 305 GATED IT ON A TRANSITION THAT DOES NOT
                // HAPPEN — patch 306.
                //
                // 305 wrote `if previous == .background, phase == .active`.
                // SwiftUI does not deliver that transition. Going out is
                // `.active → .inactive → .background`; coming back is
                // `.background → .inactive → .active`. At the step where
                // `phase` is `.active`, `previous` is ALWAYS `.inactive`, so
                // the condition could never be true and the catch-up never
                // fired once. §12.50.
                //
                // The state now lives where it is used: `runOnReturn` runs only
                // if `runOnBackgrounding` has been called since, which is the
                // fact the gate was reaching for.
                DatabaseWriteThrough.shared.runOnReturn()

            default:
                // `.inactive` is a banner, Control Centre, or the app switcher
                // on the way past. Nothing to do in either direction.
                break
            }
        }
''', "the phase switch, and .inactive is a no-op")
edit(WT, r'''    /// THE TRIGGER, WITH THE TIME TO FINISH — patch 305.''', r'''    /// Set on the way out, cleared by `runOnReturn`. This is the fact 305's
    /// `previous == .background` was reaching for and could not see — see
    /// `runOnReturn`.
    private var wentToBackground = false

    /// THE TRIGGER, WITH THE TIME TO FINISH — patch 305.
''', "the flag")
edit(WT, r'''    func runOnBackgrounding() {
        guard assertion == .invalid else { return }''', r'''    func runOnBackgrounding() {
        // BEFORE the assertion, and before the early return below. A declined
        // assertion is exactly the case the catch-up exists for, so the flag
        // must be set even when nothing is attempted here.
        wentToBackground = true

        guard assertion == .invalid else { return }
''', "set before the assertion is asked for")
edit(WT, r'''    private func releaseAssertion() {''', r'''    /// The catch-up, on the way back in.
    ///
    /// GUARDED ON HAVING BEEN AWAY, not on the phase transition. `.active`
    /// arrives from `.inactive` every time — after a notification banner, after
    /// Control Centre, after a glance at the app switcher — and running a
    /// write-through on each of those would be several a minute for nothing.
    ///
    /// This is where the guarantee lives. The backgrounding run is best-effort
    /// however good the assertion is; this one happens with the app awake and
    /// unhurried, which is what makes "a missed run is late rather than lost"
    /// a property rather than a hope. §12.50.
    func runOnReturn() {
        guard wentToBackground else { return }
        wentToBackground = false
        Task { await run(reason: "the app came back to the foreground") }
    }

    private func releaseAssertion() {
''', "runOnReturn")
edit(VIEW, r'''            .task { await load() }''', r'''            .task { await load() }
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
                    Task { await reloadLedger(db) }
                }
            }
''', "the ledger follows every run")

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.50 A transition that does not happen — patch 306

305 added a catch-up trigger gated like this:

```swift
if previous == .background, phase == .active { … }
```

**SwiftUI never delivers that transition.** Going out is
`.active → .inactive → .background`. Coming back is
`.background → .inactive → .active`. At the step where `phase` is `.active`,
`previous` is *always* `.inactive`.

So the condition could not be true, and the catch-up — the half of 305 that was
supposed to turn *late rather than lost* from an argument into a property —
never fired once.

### 12.50.1 What the device said, and what it took to read it

The test was: note `Runs since launch`, go to the home screen, come back. It
should have been **up by two**; it was up by one.

That reading was only possible because 305 wrote down what each number would
mean *before* the run — two is the pair working, one is the assertion declined,
zero is the wrong hook entirely. Without that, "1" is a number you can talk
yourself into.

It turned out to be a fourth case the list did not have: the backgrounding run
fired and the catch-up was unreachable. Worth noting that the written
predictions were still what made the result diagnosable — they narrowed it to
*one of the two did not run*, which is what sent me to the transition sequence
rather than to the assertion.

### 12.50.2 The fix is state, not a better predicate

`previous == .background` was trying to observe a fact — *we have been away* —
through a mechanism that cannot express it. The fact now lives where it is used:
`runOnBackgrounding` sets a flag, `runOnReturn` consumes it.

Set **before** the assertion is requested, and before the early return if one is
already held. A declined assertion is precisely the case the catch-up exists
for, so the flag must be set even when nothing is attempted on the way out.

`.inactive` stays a no-op in both directions. Firing on every `.active` would
mean a write-through after every notification banner, every Control Centre pull,
every glance at the app switcher — several a minute, for nothing.

### 12.50.3 The other reason this was hard to see

While the Database screen was open, an automatic run moved `Last run` and left
the Import ledger showing whatever was current when the screen opened.

303 fixed exactly this for the button and no further. An automatic run has no
call site to hang a reload on, so it kept the stale row — and the stale row is
what made a working trigger look dead, for the second time in four patches.

The screen now reloads the ledger whenever `runs` changes, whatever fired the
run. Keyed on the counter rather than on any particular trigger, so a trigger
added later inherits it.

**This is the third appearance of the same shape in this session** — §12.34,
§12.47.1, and now here. A screen holding two views of one event, where the
cheaper one updates and the expensive one does not, and the disagreement reads
as the system being broken rather than the screen being behind.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.50")

edit(VER, "    static let patch = 305", "    static let patch = 306", "306")


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
        print("   If apply-305.py has not been run yet, run that first.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. run the suite")
    print("  2. \u2318R, Database, note `Runs since launch`")
    print("  3. home screen, two seconds, come back — UP BY TWO now, and the")
    print("     ledger below should move with it without touching a button")
    return 0


if __name__ == "__main__":
    sys.exit(main())
