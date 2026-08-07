#!/usr/bin/env python3
"""
Patch 309 — both doors, the same rules.

Found by writing D6c's groundwork, which is what groundwork is for.

`ActivityStore` has two ways in and they did different things:

    ingest:  activities = dedup(...).sorted { $0.startLocal > $1.startLocal }
    load:    activities = decoded.filter { Self.isKept($0) }

Patch 123 made `isKept` run at both, and said why: a rule added after a row was
cached would otherwise never reach it. THAT ARGUMENT APPLIES TO `dedup` AND THE
SORT WITH EQUAL FORCE and was never extended to them.

Latent rather than live — nothing sets the duplicate constants at runtime, and
the file was written from an array that was already deduped and sorted. But it
blocks D6c: a shadow copy has to reproduce what the store holds, and that
cannot be done while what it holds depends on which door it came through.

MEASURED, NOT ASSUMED. "It should change nothing" is a prediction, and a
prediction with no instrument behind it is an assumption. Two counters say what
the load path actually had to correct, and Settings prints them — only when
non-zero, because a permanent "0" row stops being read.

`dedup` and `isDuplicate` become `static` and visible. That is the change that
lets 309 be tested at all: they were `private`, which is exactly why the two
doors could drift apart with nothing noticing.

ONE NEW TEST FILE, so this needs a full quit and reopen:
  Sub4CoreTests/ActivityStoreLoadTests.swift

Files touched
  Sub4/ActivityStore.swift                load, the counters, dedup visibility
  Sub4/SettingsView.swift                 the two rows, when non-zero
  docs/D6C-SHADOW-PARITY-GROUNDWORK.md    §2.1 answered
  docs/ADR-0003-database-contract.md      + §12.53
  Sub4/AppVersion.swift                   309

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


STORE = "Sub4/ActivityStore.swift"
SETTINGS = "Sub4/SettingsView.swift"
GW = "docs/D6C-SHADOW-PARITY-GROUNDWORK.md"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(STORE, r'''    private(set) var lateArrivals: Int = 0''', r'''    /// WHAT THE LOAD PATH HAD TO CORRECT — patch 309, §12.53.
    ///
    /// Both are expected to be zero on this device, because `activities.json`
    /// is written from an array that was already deduped and sorted. They exist
    /// because "expected to be zero" is a prediction, and a prediction with no
    /// instrument behind it is an assumption — §12.39.5, and §12.41.2 is what
    /// happens to a measurement nobody displays.
    ///
    /// In memory, cleared on relaunch, and that is right: they describe THIS
    /// launch's file, and a persisted copy would be a second answer to a
    /// question the current file already answers.
    private(set) var loadCollapsedDuplicates = 0

    /// Whether the file's order disagreed with the sort. Separate from the
    /// count above because they are different faults: one says the cached rows
    /// held a pair the current rule would collapse, the other says the file was
    /// written by something that did not sort.
    private(set) var loadArrivedUnsorted = false

    private(set) var lateArrivals: Int = 0''', "the two counters")
edit(STORE, r'''    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoded = (try? JSONDecoder().decode([Activity].self, from: data)) ?? []
        recordRejections(decoded)
        // `{ Self.isKept($0) }` and not `Self.isKept`. The predicate reads
        // MatchRules and DataCorrections, which are MainActor-isolated like
        // everything else in this target, and handing it to `filter` as a
        // function VALUE strips that isolation — "call to main actor-isolated
        // static method in a synchronous nonisolated context". A closure
        // literal written here inherits the isolation of the method it sits in,
        // so the same call is fine spelled out.
        activities = decoded.filter { Self.isKept($0) }
    }''', r'''    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoded = (try? JSONDecoder().decode([Activity].self, from: data)) ?? []
        recordRejections(decoded)
        // `{ Self.isKept($0) }` and not `Self.isKept`. The predicate reads
        // MatchRules and DataCorrections, which are MainActor-isolated like
        // everything else in this target, and handing it to `filter` as a
        // function VALUE strips that isolation — "call to main actor-isolated
        // static method in a synchronous nonisolated context". A closure
        // literal written here inherits the isolation of the method it sits in,
        // so the same call is fine spelled out.
        let kept = decoded.filter { Self.isKept($0) }

        // BOTH DOORS NOW APPLY THE SAME RULES — patch 309, ADR-0003 §12.53.
        //
        // Patch 123 made `isKept` run here as well as in `ingest`, and its
        // comment says why: a rule added after a row was cached would otherwise
        // never reach it. That argument applies to `dedup` and the sort just as
        // much, and it was never extended to them — so until now this door
        // filtered and the other door filtered, deduped and sorted.
        //
        // Invisible today, because the file was written from an array that was
        // already both. It bites the day `duplicateWindowMinutes` or
        // `duplicateDistanceTolerance` changes in code, the way `cutoffDayKey`
        // already has: cached pairs would keep the old outcome until the next
        // sync, and nothing would say so.
        //
        // It also blocks D6c. A shadow copy has to reproduce what this store
        // holds, and that cannot be done while what it holds depends on which
        // door it came through.
        //
        // MEASURED, NOT ASSUMED. The two counters below say what this cost on
        // the real file, and Settings prints them. "It should change nothing"
        // was the prediction; §12.53.2 is where the number goes.
        let sorted = kept.sorted { $0.startLocal > $1.startLocal }
        loadArrivedUnsorted = sorted.map(\.id) != kept.map(\.id)

        let settled = Self.dedup(kept).sorted { $0.startLocal > $1.startLocal }
        loadCollapsedDuplicates = kept.count - settled.count

        activities = settled
    }
''', "load applies the same rules as ingest")
edit(STORE, r'''    private func dedup(_ input: [Activity]) -> [Activity] {
        var kept: [Activity] = []
        for a in input.sorted(by: { $0.startLocal < $1.startLocal }) {
            if let i = kept.firstIndex(where: { isDuplicate($0, a) }) {
                if a.movingTime > kept[i].movingTime { kept[i] = a }
            } else {
                kept.append(a)
            }
        }
        return kept
    }''', r'''    /// STATIC AND VISIBLE — patch 309, and the visibility is the change.
    ///
    /// It was `private func`, which is why the two doors could drift apart
    /// without a test noticing: nothing outside this file could ask what it
    /// does. 309 changes what `load` does, and a behaviour change that cannot
    /// be tested is a behaviour change taken on trust.
    ///
    /// Still `@MainActor` by default isolation, because `isDuplicate` reads
    /// `MatchRules`, which is — see the note in `load` about `isKept`.
    ///
    /// ORDER-INDEPENDENT BY CONSTRUCTION. It sorts ascending before it walks,
    /// so the survivor of a near-duplicate pair does not depend on the order
    /// the caller happened to hand them over in. That is the property
    /// `bothDoorsAgree` pins, and the one a reimplementation would break
    /// silently — §12.52.3.
    static func dedup(_ input: [Activity]) -> [Activity] {
        var kept: [Activity] = []
        for a in input.sorted(by: { $0.startLocal < $1.startLocal }) {
            if let i = kept.firstIndex(where: { isDuplicate($0, a) }) {
                if a.movingTime > kept[i].movingTime { kept[i] = a }
            } else {
                kept.append(a)
            }
        }
        return kept
    }
''', "dedup is static and visible")
edit(STORE, r'''    private func isDuplicate(_ a: Activity, _ b: Activity) -> Bool {''', r'''    /// Static alongside `dedup`, for the same reason — patch 309.
    static func isDuplicate(_ a: Activity, _ b: Activity) -> Bool {
''', "and so is isDuplicate")
edit(STORE, r'''        activities = dedup(Array(byID.values)).sorted { $0.startLocal > $1.startLocal }''', r'''        activities = Self.dedup(Array(byID.values)).sorted { $0.startLocal > $1.startLocal }''', "ingest calls the static one")
edit(SETTINGS, r'''        if !DataCorrections.ignoredActivities.isEmpty {''', r'''        // PATCH 309. Beside "Ignored recordings" because it is the same kind of
        // fact: something the app dropped or changed while loading, which is
        // invisible unless it is said. Shown only when non-zero — a permanent
        // "0" row is a row that stops being read (§12.42.2).
        if activities.loadCollapsedDuplicates > 0 {
            LabeledContent("Collapsed as duplicates on load",
                           value: "\(activities.loadCollapsedDuplicates)")
            Text("Cached rows held a pair the current duplicate rule folds into "
                 + "one. They were collapsed when the file was read; the file "
                 + "itself is rewritten on the next sync.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if activities.loadArrivedUnsorted {
            LabeledContent("Cached file was out of order", value: "yes")
            Text("activities.json was not in newest-first order when it was "
                 + "read. Sorted on load. Worth knowing about, because nothing "
                 + "in the app should write it unsorted.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if !DataCorrections.ignoredActivities.isEmpty {
''', "the rows, when non-zero")
edit(GW, r'''The negative control is the harder half and it is not optional. Options, to
decide when the first one is built: a test that corrupts one side and asserts
the comparison catches it (cheap, and does not prove the on-device path); a
debug-only toggle that perturbs the database side (proves the real path, and is
a switch that must never ship enabled); or the approved-differences list in §5
doubling as one, since those are known non-zero counts the comparison must keep
reporting.

**Written down before anything is built, because a green tick that means nothing
is worse than no tick.**''', r'''**ANSWERED at 309: tests and denominators, no device switch.**

Three things can go wrong, and they need different answers.

**1. The comparison logic is broken** and calls everything equal.
→ A unit test that hands it two deliberately different lists, built from
genuinely different sources, and demands it reports them. Runs on every build.
This is the test button.

**2. It runs over nothing.** A read failed, came back empty, and comparing zero
against zero agrees perfectly.
→ Three counts on screen: how many the app held, how many the database held,
how many were compared. A dead read stops them matching.

**3. Both sides are secretly the same object** — the twin built from the store
by mistake, comparing the app to itself.
→ No runtime check catches this cleanly. It is caught by (1) constructing its
sides from different places, and by reading the code. Named so it is not
mistaken for covered.

**And one free continuous control:** the detail comparison has a permanent known
difference — the twelve zero-heart-rate details. If that ever reports **0**, the
comparison stopped looking. A number that must stay non-zero tests itself on
every run. It does nothing for slice 1, where nothing is expected to differ.

**Rejected: a debug toggle that perturbs the database on the device.** It would
be the strongest evidence, because it exercises the real path — and it is a
switch that can damage data and must never ship enabled. §12.46.3 declined
automatic deletion on blast-radius grounds and this is the same argument. (1)
and (2) together cover the realistic failures.

**A green tick that means nothing is worse than no tick.**
''', "\u00a72.1 answered")
edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.53 Both doors, the same rules — patch 309

Found by writing D6c's groundwork, which is what groundwork is for.

### 12.53.1 One rule was extended to both doors and two were not

`ActivityStore` has two ways in: `ingest`, from the network, and `load`, from
`activities.json`. They did different things.

    ingest:  activities = dedup(...).sorted { $0.startLocal > $1.startLocal }
    load:    activities = decoded.filter { Self.isKept($0) }

Patch 123 made `isKept` run at both, and its comment says exactly why:
`DataCorrections.ignoredActivities` changes, and a row already on disk *"would
have walked straight past a rule added after it was cached."*

**That argument applies to `dedup` and the sort with equal force, and was never
extended to them.** `duplicateWindowMinutes` and `duplicateDistanceTolerance`
are the same kind of tunable as the cutoff — and the cutoff has already moved
once, from 15 June to 1 January, as `MatchRules`' own comment records.

So the day either duplicate constant changes, cached pairs keep the old outcome
until the next sync, and nothing says so. Latent rather than live: nothing sets
those at runtime, and the file was written from an array that was already
deduped and sorted, so reading it back gives the same list.

### 12.53.2 It blocks D6c, which is why it is being fixed now rather than later

A shadow copy has to reproduce what the store holds. Until now **what the store
holds depended on which door it came through** — filtered after a launch,
filtered *and* deduped *and* sorted after a sync.

A twin cannot match a moving target. §4 of the D6c groundwork extracts these
rules into one value both sides call; that extraction is meaningless while the
rules are applied inconsistently on the side being copied.

### 12.53.3 Measured rather than assumed

"It should change nothing" was the prediction, and a prediction with no
instrument behind it is an assumption.

`loadCollapsedDuplicates` and `loadArrivedUnsorted` say what the load path
actually had to correct, and Settings prints them — **only when non-zero**,
because a permanent "0" row is a row that stops being read (§12.42.2).

They are separate numbers because they are separate faults: one says the cached
rows held a pair the current rule folds together, the other says something wrote
the file out of order. In memory rather than persisted, because they describe
this launch's file and the current file already answers the question.

§12.41.2 records what happens to a measurement nobody displays: `Report.seconds`
was computed and thrown away for forty patches, and it was the number D6b's
design turned on. `lateArrivals` in this same file is the next one — computed at
every ingest since patch 45 and displayed nowhere. Not this patch's job, named
here so it is not lost.

### 12.53.4 What the risk actually is

The change is one line of behaviour on a path that runs at every launch, on a
device with 672 activities and no backup of the in-memory list.

It is safe in the direction that matters: `dedup` and the sort are pure, they
cannot lose an activity the current rules would keep, and `activities.json` is
not rewritten by `load` — so a wrong outcome is corrected by the next launch
rather than persisted. The three read-backs are the check, and they compare
against the database, which the load path does not touch.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.53")
edit(VER, "    static let patch = 308", "    static let patch = 309", "309")


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

    t = ROOT / "Sub4CoreTests/ActivityStoreLoadTests.swift"
    print(f"{'ok      ' if t.exists() else 'MISSING '} Sub4CoreTests/ActivityStoreLoadTests.swift"
          f"  (copied from the zip)")
    if not t.exists():
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
    print("  1. ONE NEW TEST FILE — quit Xcode entirely (\u2318Q) and reopen")
    print("  2. run the suite")
    print("  3. \u2318R, then Settings \u2192 Sync & data. If BOTH new rows are absent,")
    print("     the load path had nothing to correct — the predicted result.")
    print("     If either appears, that is a real finding and the number is it.")
    print("  4. the three read-backs should be unmoved: this touches the store's")
    print("     load path and never the database.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
