#!/usr/bin/env python3
"""
Patch 286a — routes are a SERIES type, and `HKSampleQuery` refuses them.

286 gave the census named outcomes, and on its first run it said what 285 could
not: "Routes not measured — a route query returned an error." The workout fetch
had succeeded — that is a different message — so the failure is specifically the
per-workout route query.

`HKWorkoutRoute` is an `HKSeriesType`. Apple's documented way to read one is
`HKAnchoredObjectQuery`; `HKSampleQuery` rejects series types. The workout fetch
stays on `HKSampleQuery`, which is correct for it and demonstrably worked.

AND IT QUOTES HEALTHKIT NOW. The old helper threw the error away and returned
`nil`, so "a route query returned an error" was as much as the screen could
say. If this fix is wrong, the next report will carry HealthKit's own words
instead of mine.

A LETTER FIX-UP, and the first one since 284 made them visible: this ships
`AppVersion.swift` with `patch = 286` and `revision = "a"`. The phone will read
**286a**.

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


W = "Sub4/HealthWorkouts.swift"
TT = "Sub4CoreTests/HealthTypeTests.swift"

# ------------------------------------------------- the route query, corrected

edit(
    W,
    r'''        var out: Set<String> = []
        for w in found {
            let mine = HKQuery.predicateForObjects(from: w)
            guard let routes = await samples(of: HKSeriesType.workoutRoute(),
                                             matching: mine) else {
                return .failed("a route query returned an error.")
            }
            if !routes.isEmpty { out.insert(w.uuid.uuidString) }
        }
        return .measured(out)
    }''',
    r'''        var out: Set<String> = []
        for w in found {
            let mine = HKQuery.predicateForObjects(from: w)
            // `series(of:matching:)`, NOT `samples(of:matching:)` — 286a.
            // `HKWorkoutRoute` is an `HKSeriesType` and `HKSampleQuery`
            // rejects series types. 286 used the sample query here and the
            // census failed on every session; the workout fetch above is a
            // plain sample query and is correct, which is why only the second
            // message ever appeared.
            switch await series(of: HKSeriesType.workoutRoute(), matching: mine) {
            case .failure(let why):
                return .failed("the route query failed — \(why)")
            case .success(let routes):
                if !routes.isEmpty { out.insert(w.uuid.uuidString) }
            }
        }
        return .measured(out)
    }

    /// One `HKAnchoredObjectQuery`, awaited — the query kind series types
    /// require.
    ///
    /// IT KEEPS THE ERROR. `samples(of:matching:)` returns `[HKSample]?` and
    /// throws the reason away, which is why 286 could report only "a route
    /// query returned an error" in my words rather than HealthKit's. A
    /// diagnostic that has been handed a reason should not discard it —
    /// §12.32.4, one level further down.
    ///
    /// The continuation is guarded because an anchored query's handler can be
    /// called more than once and resuming twice would trap.
    @MainActor
    private func series(of type: HKSampleType,
                        matching predicate: NSPredicate) async -> Result<[HKSample], String> {
        await withCheckedContinuation { continuation in
            var resumed = false
            let q = HKAnchoredObjectQuery(type: type, predicate: predicate,
                                          anchor: nil,
                                          limit: HKObjectQueryNoLimit) { _, samples, _, _, error in
                guard !resumed else { return }
                resumed = true
                if let error {
                    continuation.resume(returning: .failure(error.localizedDescription))
                } else {
                    continuation.resume(returning: .success(samples ?? []))
                }
            }
            healthStore.execute(q)
        }
    }''',
    "the route query uses an anchored query and keeps the reason",
)

# ---------------------------------------------------------------------- test

edit(
    TT,
    r'''    /// The guard that makes the next one of these visible in one run rather''',
    r'''    /// A failure has to carry HealthKit's reason, not just the fact of it.
    /// 286 reported "a route query returned an error" because the helper threw
    /// the reason away; 286a keeps it, and this is what stops it being thrown
    /// away again.
    @Test("A failed census quotes the reason it was given")
    func aFailedCensusQuotesItsReason() {
        let line = HealthStore.RouteCensus.failed("the type is not supported").line
        #expect(line.contains("the type is not supported"))
    }

    /// The guard that makes the next one of these visible in one run rather''',
    "the failure must carry its reason",
)

# ----------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''### 12.32.5 The prompt string is a build setting, and stays one''',
    r'''### 12.32.5 And then the query itself was the wrong kind — patch 286a

With the type requested and the prompt updated, the census ran and said:
**"Routes not measured — a route query returned an error."**

`HKWorkoutRoute` is an `HKSeriesType`, and `HKSampleQuery` rejects series
types; Apple's documented way to read a route is `HKAnchoredObjectQuery`. The
workout fetch above it is a plain sample query, is correct, and worked — which
is why only the second of the two failure messages ever appeared.

**The named outcomes are what made this a five-minute diagnosis.** In 285 the
same defect produced a silent `nil` and an evening of not knowing whether it
was permissions, the type, the query or the store. In 286 it produced a
sentence that ruled out three of the four in one reading.

**What it did not produce was HealthKit's own words**, because
`samples(of:matching:)` returns `[HKSample]?` and discards the error. 286a's
`series(of:matching:)` returns a `Result` and carries the reason through to the
screen. The rule from §12.32.4 applies one level further down than it was
written: a diagnostic that has been handed a reason should not throw it away.

### 12.32.6 The prompt string is a build setting, and stays one''',
    "ADR §12.32.5, and the old .5 becomes .6",
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
