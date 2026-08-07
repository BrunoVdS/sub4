#!/usr/bin/env python3
"""
Patch 310 — the rules as a value, and a rule I had just written down.

D6c step 2. Three private methods become one type, and a hole 309 opened while
fixing a different one gets closed.

  · `ActivityRoster` — isKept, dedup and the sort in one place, with `settle`
    as the single call BOTH of ActivityStore's entrances make. 309 made them
    agree by writing the rules out twice; this makes disagreement unavailable.
    D6c's database side will call the same function rather than reimplement it,
    which is §12.43's lesson.

  · IT COUNTS WHAT IT DID. `Result` carries offered, dropped, collapsed and
    arrivedOutOfOrder. `offered` is the denominator: without it, "0 collapsed"
    and "nothing was examined" read identically.

  · AND THE ROW IS ALWAYS THERE NOW. 309 hid its counters when zero, reasoning
    from §12.42.2 that a permanent correct row stops being read. That is about
    a permanent ALARM; I applied it to a permanent COUNT. The device then showed
    neither row, and that means zero or it means nobody wired them in — a
    screenshot cannot tell.

    This project had already written the rule down twice, about this exact
    screen's paste:

      266c: a section that vanished when nothing was wrong would be
            indistinguishable from a check that never ran.
      273:  a line that only appears when something is wrong cannot be
            distinguished from a line nobody wired in.

    Both before 309. The counts also join the redacted paste, unconditionally.

ONE NEW FILE, so this needs a full quit and reopen:
  Sub4/ActivityRoster.swift

The test file keeps its old name on purpose — renaming means deleting a file,
and a delete in an apply script is a class of operation this workflow has never
needed. The suite inside is renamed.

Files touched
  Sub4/ActivityStore.swift             load, ingest, the rules move out
  Sub4/SettingsView.swift              one always-present row
  Sub4/DatabaseHealthView.swift        the counts join the paste
  Sub4CoreTests/ActivityStoreLoadTests.swift   rewritten, + four tests
  docs/ADR-0003-database-contract.md   + §12.54
  Sub4/AppVersion.swift                310

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
HEALTH = "Sub4/DatabaseHealthView.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(STORE, r'''    /// WHAT THE LOAD PATH HAD TO CORRECT — patch 309, §12.53.
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
''', r'''    /// WHAT THE LOAD PATH DID, AND WHAT IT COST — patch 310, §12.54.
    ///
    /// Nil until `load` has read a file. Nil is not zero: a device with no
    /// `activities.json` yet and a device whose file held nothing are different
    /// answers, and the summary below says which.
    ///
    /// In memory, cleared on relaunch, and that is right — it describes THIS
    /// launch's file, and the current file already answers the question.
    private(set) var loadRoster: ActivityRoster.Result?

    /// One row's worth, always sayable. See §12.54.2: 309 showed these numbers
    /// only when non-zero, which made a working counter and an unwired one look
    /// identical — the exact thing 266c and 273 wrote down about the paste.
    var loadSummary: String {
        loadRoster?.summary ?? "no cached file read"
    }

    /// For the redacted paste, unconditional.
    var loadDiagnosticLines: [String] {
        loadRoster?.diagnosticLines ?? ["Activity roster: no cached file read"]
    }

''', "loadRoster replaces the two counters")
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
    }''', r'''    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoded = (try? JSONDecoder().decode([Activity].self, from: data)) ?? []
        recordRejections(decoded)

        // ONE CALL, AND THE OTHER DOOR MAKES THE SAME ONE — patch 310.
        //
        // 309 made both doors apply the same rules by writing them out twice.
        // This makes it structural rather than remembered, which matters
        // because D6c needs the database side to produce the same list from the
        // same rules, and two implementations of one rule is the mistake §12.43
        // cost three patches to learn.
        //
        // `loadRoster` stays nil if the file is not there — the guard above
        // returns first. That is the difference between "no cached file" and
        // "a cached file holding nothing", and it is the sixth instance of
        // §12.15's shape on this screen.
        let settled = ActivityRoster.settle(decoded)
        loadRoster = settled
        activities = settled.activities
    }
''', "load calls settle")
edit(STORE, r'''        activities = Self.dedup(Array(byID.values)).sorted { $0.startLocal > $1.startLocal }''', r'''        // The same call `load` makes. Its counts are ignored here: a
        // dictionary's values have no order to be out of. §12.54.4.
        activities = ActivityRoster.settle(Array(byID.values)).activities''', "and so does ingest")
edit(STORE, r'''            if byID[a.id] == nil, epoch(of: a) < highWater, Self.isKept(a) { late += 1 }''', r'''            if byID[a.id] == nil, epoch(of: a) < highWater,
               ActivityRoster.isKept(a) { late += 1 }''', "isKept moved (1 of 2)")
edit(STORE, r'''            guard Self.isKept(a) else { byID.removeValue(forKey: a.id); continue }''', r'''            guard ActivityRoster.isKept(a) else {
                byID.removeValue(forKey: a.id); continue
            }''', "isKept moved (2 of 2)")
edit(STORE, r'''    /// THE ONE GATE, APPLIED WHEREVER AN ACTIVITY ARRIVES
    /// ---------------------------------------------------
    /// Two doors lead into `activities`: the network, through `ingest`, and
    /// activities.json, through `load`. The filter used to live in `ingest`
    /// only, which was fine while it was made of constants that never changed
    /// after a row was written — but `DataCorrections.ignoredActivities` does
    /// change, and a row already on disk would have walked straight past a rule
    /// added after it was cached. Applying the same predicate on load means a
    /// new entry takes effect on the next launch instead of needing a re-sync.
    ///
    /// Everything after the cutoff is kept — walks, commutes, the kayak. Only
    /// *matching* is filtered (`Activity.isPlanEligible`), so total movement
    /// volume stays honest.
    private static func isKept(_ a: Activity) -> Bool {
        guard a.dayKey >= MatchRules.cutoffDayKey else { return false }
        guard a.movingTime >= MatchRules.minAnyActivitySeconds else { return false }
        // Named, with the reason, in DataCorrections — and reported in
        // Settings, because a recording the app throws away without saying so
        // is indistinguishable from one it failed to fetch.
        guard !DataCorrections.isIgnored(a) else { return false }
        // The rule, not a list. See `Activity.selfContradictoryDistance` for the
        // three rides that produced it and why the threshold is 1.5×.
        guard !a.selfContradictoryDistance else { return false }
        return true
    }''', r'''    /// Moved to `ActivityRoster` at 310, along with `dedup` and the sort. Both
    /// of this store's entrances call `ActivityRoster.settle` now, so the rules
    /// cannot drift apart again — and D6c's database side calls the same one
    /// rather than reimplementing it. §12.54.
''', "the rule itself moved out")
edit(STORE, r'''    /// STATIC AND VISIBLE — patch 309, and the visibility is the change.
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


    /// Static alongside `dedup`, for the same reason — patch 309.
    static func isDuplicate(_ a: Activity, _ b: Activity) -> Bool {

        guard a.sportType == b.sportType, a.dayKey == b.dayKey else { return false }
        guard abs(a.startMinuteOfDay - b.startMinuteOfDay)
                <= MatchRules.duplicateWindowMinutes else { return false }
        let bigger = max(a.distance, b.distance)
        guard bigger > 0 else { return true }
        return abs(a.distance - b.distance) / bigger <= MatchRules.duplicateDistanceTolerance
    }''', r'''    /// `dedup` and `isDuplicate` moved to `ActivityRoster` at 310. They were
    /// `private` until 309 and static-but-here at 309; they belong with
    /// `isKept`, because the three of them together are what decides what the
    /// activity list is.
''', "and dedup with it")
edit(SETTINGS, r'''        // PATCH 309. Beside "Ignored recordings" because it is the same kind of
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

''', r'''        // ALWAYS PRESENT, INCLUDING ITS ZEROS — patch 310, §12.54.2.
        //
        // 309 showed these numbers only when non-zero, on the reasoning that a
        // permanent "0" row stops being read (§12.42.2). That reasoning is
        // about a permanent ALARM, and I applied it to a permanent COUNT.
        //
        // The difference matters: an absent row and an unwired row look
        // identical, which is the exact sentence 266c wrote about the
        // diagnostics paste and 273 repeated — *a line that only appears when
        // something is wrong cannot be distinguished from a line nobody wired
        // in.* Four hours later I did the opposite here.
        //
        // A count beside its denominator is evidence, not noise. That is what
        // `samplesWalked` does for the recording read-back.
        LabeledContent("Activities loaded", value: activities.loadSummary)
        if let r = activities.loadRoster, r.collapsed > 0 || r.arrivedOutOfOrder {
            Text("The cached file needed correcting on load. Duplicates are "
                 + "pairs the current rule folds into one; out of order means "
                 + "something wrote activities.json unsorted, which nothing in "
                 + "the app should do. The file is rewritten on the next sync.")
                .font(.caption).foregroundStyle(.secondary)
        }

''', "one always-present row")
edit(HEALTH, r'''        lines.append(contentsOf: StoreReadJournal.shared.diagnosticLines)''', r'''        lines.append(contentsOf: StoreReadJournal.shared.diagnosticLines)
        // PATCH 310. UNCONDITIONAL, for 266c's reason, which 309 briefly
        // forgot on the Settings screen — see §12.54.2. This is also the only
        // place the roster's numbers appear when they are all zero, which is
        // what makes "0 collapsed" evidence rather than an absence.
        lines.append(contentsOf: ActivityStore.shared.loadDiagnosticLines)
''', "the counts join the paste")
edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.54 The rules as a value, and a rule I had just written down — patch 310

D6c step 2. It moves three private methods into one type and closes a hole 309
opened while fixing a different one.

### 12.54.1 Three rules decide what the list IS

`ActivityStore` holds activities; what is in that list is decided by three
rules — which are kept, which pairs are one session uploaded twice, and what
order they are in. They lived as `private` methods on the store, which is
exactly the arrangement that let the two entrances drift apart for two hundred
patches (§12.53).

309 made both doors agree by writing the rules out twice. 310 makes disagreement
**unavailable**: `ActivityRoster.settle` is one call and both entrances make it.

That matters beyond tidiness. D6c compares what the app *computes* from two
sources, so the database side has to produce the same list from the same rules —
and a second implementation of a rule that already exists is the mistake §12.43
cost three patches to learn. **When two things must agree, do not reimplement.
Call.**

`settlingTwiceChangesNothing` pins idempotence, which is what makes it safe to
call from both doors and from a twin that may be fed either side's output.

### 12.54.2 A rule this file already contained, broken four hours after it was quoted

309 shipped its two counters *hidden when zero*, reasoning from §12.42.2 that a
permanently-correct row trains a reader to ignore it.

Then the device showed neither row, and the honest reading was: **that means
zero, or it means nobody wired them in, and a screenshot cannot tell.**

§12.42.2 is about a permanent **alarm**. I applied it to a permanent **count**,
and they are not the same thing. The distinction was already written down twice
in this project, in the diagnostics paste:

> *Patch 266c.* A section that simply vanished when nothing was wrong would be
> indistinguishable from a check that never ran.
>
> *Patch 273.* A line that only appears when something is wrong cannot be
> distinguished from a line nobody wired in.

Both about the same screen. Both written before 309. **A count beside its
denominator is evidence; a bare zero is noise; a missing zero is nothing at
all** — which is precisely why `samplesWalked` exists (§12.39.6.1), four days
earlier, in a patch of the same week.

So the fix is not "show a red 0". It is one always-present row stating the
positive with its denominator:

    Activities loaded    672 · 0 collapsed · in order

Absent now means broken. Present with zeros means checked and clean.

#### 12.54.2.1 What still cannot be proved, and what was done instead

Nothing here proves the pixel drew. This project has no UI tests and adding a
framework for one row would be the wrong trade.

Three things are done instead, each with its honest limit:

| | proves | does not prove |
|---|---|---|
| `Result` carries the counts, tested | the number is produced | that anything displays it |
| the row is unconditional | absence is now a symptom | that it rendered |
| the counts join the redacted paste | the value exists even at zero | that the paste was read |

The realistic failure being designed against is not *wrong*, it is
**indistinguishable from fine** — the same shape as `?? .distantPast`
(§12.42.1.1), where a fallback made a reader defect wear a data difference's
clothes.

### 12.54.3 `Result.offered` is the denominator, and it is the point

`dropped`, `collapsed` and `arrivedOutOfOrder` are all differences. `offered` is
how many were looked at.

Without it, "0 collapsed" and "nothing was examined" read identically — which is
§12.39.6.1's argument arriving one layer up. `nothingToCorrectStillSpeaks` is
the test for the boring case, and it is the case that runs on the device every
single day.

### 12.54.4 `arrivedOutOfOrder` means nothing at one of the two doors

`ingest` settles a dictionary's values, and a dictionary has no order to be out
of. `load` reads a file something wrote deliberately, and there it is a real
fact about the writer.

Both doors call the same function; only one reads that field, and `Result`'s
own comment says which and why. The alternative — two entry points differing by
one returned value — is how §12.53 started.

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.54")
edit(VER, "    static let patch = 309", "    static let patch = 310", "310")


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

    for g in ["Sub4/ActivityRoster.swift",
              "Sub4CoreTests/ActivityStoreLoadTests.swift"]:
        here = (ROOT / g).exists()
        print(f"{'ok      ' if here else 'MISSING '} {g}  (copied from the zip)")
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
    print("  1. ONE NEW FILE — quit Xcode entirely (\u2318Q) and reopen")
    print("  2. run the suite")
    print("  3. \u2318R, Settings \u2192 Sync & data. The row is now ALWAYS there:")
    print("     'Activities loaded  672 \u00b7 0 collapsed \u00b7 in order'.")
    print("     Absent means broken; present with zeros means checked and clean.")
    print("  4. Database health \u2192 Copy diagnostics: four 'Activity roster'")
    print("     lines, unconditional, even at zero.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
