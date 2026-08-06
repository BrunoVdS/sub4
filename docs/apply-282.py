#!/usr/bin/env python3
"""
Patch 282 — 4A M0. Does Apple Health actually hold the history?

ADR-0002 follow-up 3: "Measure Apple Health coverage back to 1 July 2025
BEFORE any purge." Nothing ever has. Every plan since assumes the answer.

THREE NEW FILES, so this needs ⌘Q and a reopen before it will build:
  Sub4/HealthCoverage.swift            the pure report, and the reading outcome
  Sub4/HealthCoverageView.swift        the screen
  Sub4CoreTests/HealthCoverageTests.swift

Everything else is anchored edits: one optional parameter on
`HealthStore.workouts`, the Settings entry point, and one word in
DataLifecycle's gap text that 281 left pointing at nothing.

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
S = "Sub4/SettingsView.swift"
L = "Sub4/DataLifecycle.swift"

# ------------------------------------------- HealthWorkouts — skip enrichment

edit(
    W,
    r'''    @MainActor
    func workouts(from start: Date, to end: Date) async -> [HealthWorkout] {
        guard isAvailable, hasRequestedAuthorization, hasUsageDescription else { return [] }''',
    r'''    /// `enrichSwims` added in 282, defaulted so every existing caller is
    /// unchanged. The coverage report calls this thirteen times — once per
    /// month, because a single thirteen-month query is one `workoutTimeout`
    /// away from returning `[]`, which that diagnostic would then have to
    /// report as "Health answered and has nothing". It counts sessions and
    /// days and never reads `activeSeconds`, so leaving enrichment on would
    /// buy several hundred sample queries for a field nobody there looks at.
    @MainActor
    func workouts(from start: Date, to end: Date,
                  enrichSwims: Bool = true) async -> [HealthWorkout] {
        guard isAvailable, hasRequestedAuthorization, hasUsageDescription else { return [] }''',
    "workouts takes enrichSwims",
)

edit(
    W,
    r'''        var enriched = 0
        for i in out.indices where out[i].sport == .swim && enriched < Self.maxSwimEnrich {''',
    r'''        var enriched = 0
        for i in out.indices where enrichSwims
            && out[i].sport == .swim && enriched < Self.maxSwimEnrich {''',
    "the enrichment loop honours it",
)

# ------------------------------------------------------------ SettingsView

edit(
    S,
    r'''    @State private var showHealthReconcile = false''',
    r'''    @State private var showHealthReconcile = false
    @State private var showHealthCoverage = false''',
    "the coverage sheet's state",
)

edit(
    S,
    r'''        .sheet(isPresented: $showHealthReconcile) { HealthReconcileView() }''',
    r'''        .sheet(isPresented: $showHealthReconcile) { HealthReconcileView() }
        .sheet(isPresented: $showHealthCoverage) { HealthCoverageView() }''',
    "the coverage sheet",
)

edit(
    S,
    r'''            Button("Compare with Strava") { showHealthReconcile = true }''',
    r'''            Button("Compare with Strava") { showHealthReconcile = true }

            // 4A M0 — ADR-0002 follow-up 3. Beside "Compare with Strava"
            // because they are the same question at two scales: that one asks
            // whether the two sides agree about a session, this one asks
            // whether Health holds the history at all. The second has to be
            // answered before any purge and never has been.
            Button("Health coverage") { showHealthCoverage = true }''',
    "the coverage button",
)

# ---------------------------------- DataLifecycle — 281 left a dangling word

edit(
    L,
    r'''                 + "the folder — the rule below is only correct while every row "''',
    r'''                 + "the folder — the disconnect rule is only correct while every row "''',
    "the gap stops pointing at something the reader cannot see",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.28 Does Health hold the history — 4A M0, patch 282

### 12.28.1 The question nobody had asked

ADR-0002 retired Strava and made Apple Health canonical in one decision, and
its third follow-up says: *"Measure Apple Health coverage back to 1 July 2025
**before** any purge."* Its consequences say why — *"the watch may not have
been worn, or workouts may have been written by Strava rather than to it"* —
and name the bulk-export bridge as the contingency if the answer is thin.

**Nothing has ever measured it.** Every plan written since, including the
cutover plan and the peer review folded into it, assumes the answer and
sequences Health ingestion as phase six of ten. It belongs first, because a
thin answer changes what the database currently holds from *a copy* into *the
only copy*, and that changes the priority of everything below it.

### 12.28.2 The risk is thinness, not disappearance

"Workouts written by Strava rather than to it" reads as though those sessions
would vanish on a disconnect. **They will not.** An `HKWorkout` belongs to
Apple the moment it is written; revoking an API token does not reach into the
Health store, and deleting the Strava app does not either.

The real exposure is that a session which exists in Health only because Strava
pushed a summary back carries a start, an end, a duration and often nothing
else — no route, no heart-rate samples, sometimes no distance. It counts as
present in every census and is not a training record.

So the report counts what is there **and what state it is in**, and reports the
writers by name. `HealthWorkout.sources` has carried
`w.sourceRevision.source.name` since the reconcile screen was built; every
session has known who wrote it all along and nothing had ever aggregated it.

### 12.28.3 It has to be able to say "I do not know"

`HealthStore.workouts(from:to:)` returns `[]` on a denial, a timeout and a
genuinely empty store alike, and its own comment says so: *"the caller cannot
tell a denial from an empty store anyway."* For every other caller that is the
right trade — a diagnostic that crashes is worse than one that says nothing
came back.

For this one it is fatal. A report that answers *"Health has nothing"* when the
truth is *"the query never ran"* would retire Strava on the strength of a
permissions bug, and the zeros would look exactly like an answer.

`HealthCoverage.Reading` is therefore the first field of the report, with five
cases — read, unavailable, neverAsked, noUsageDescription, failed — and
`isTrustworthy` is true for exactly one of them. **This is `StoreLoad` from
§12.15 wearing different clothes**, and deliberately so: same failure, same
shape of answer, and the two should be recognisable as the same idea.

`anUntrustworthyReadingNeverReadsAsAnEmptyStore` is the test with teeth. It
builds a report holding a stored activity and no Health workout — the exact
shape of a real shortfall — and asserts that the headline is the reading and
that `text()` stops before the table, so nobody can screenshot an empty grid
and call it a measurement.

### 12.28.4 Days, not sessions, and the second matcher that was not written

`HealthReconcile.build` already joins the two sides. It is filtered, on both
sides, to the sessions this app reasons about — and its comments explain a
real defect that came from filtering only one of them: 156 commute rides
landed in a bucket meaning *"Strava never received this"* when Strava had
received all of them.

Coverage is a different question and needs the commutes and the walks. Writing
a second matcher to answer it would put two joins in this codebase that
disagree, which is exactly what §12.16 refused for CTL.

**So this compares DAYS.** A day carries a `dayKey` on both sides, needs no
tolerance rule, no candidate selection and no `used` set, and cannot drift from
`build` because it is not doing what `build` does. The limit is stated on the
screen and in the paste rather than left to be discovered: a day present on
both sides counts as covered even if the two sessions on it are different
sessions. Where a day disagrees, *Compare with Strava* is the screen that
inspects it.

### 12.28.5 What is deliberately not measured

**Routes.** `HKWorkoutRoute` is one query per workout, and over thirteen months
that is several hundred round trips for a diagnostic. Thinness is measured here
by distance and heart rate, which arrive with the workout and cost nothing. A
route census is worth doing before the purge and is not this — recorded here
rather than skipped in silence, because a check the plan implied and did not
get is the kind of gap that closes itself in a summary.

### 12.28.6 One query per month

`workoutTimeout` is twelve seconds and the window is thirteen months. A single
query for the lot is one timeout away from `[]`, which is the false negative
this whole design exists to prevent. A month at a time is bounded, and the
months are the buckets the report wants anyway.

The trade is stated: dedupe runs per call, so a session starting on the last
night of a month is deduped within its own month only. Sessions do not span
months in practice, and the bucket is chosen by start date, so it cannot
double-count.

`enrichSwims: false` is this patch's one change to `workouts(from:to:)`. The
parameter is defaulted, so every existing caller is untouched.

### 12.28.7 It states the finding and stops

`headline` is not a verdict. ADR-0002 requires the shortfall — if there is one
— to be **accepted in writing** rather than discovered at the receipt, so the
report says how many training days the app holds that Health does not, and how
many sessions Strava alone wrote, and goes no further. Whether that is
acceptable is a decision, and decisions are not computed here.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.28",
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
