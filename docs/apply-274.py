#!/usr/bin/env python3
"""
Patch 274 — the reconciliation pass. D4's database half, done.

The importer has been additive-only since it was written. This wires in
`Sub4Import+Reconcile.swift` (which ships whole in the zip), teaches the
verifier to check reviews — it never has — and shows the result.

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


I = "Sub4/Sub4Import.swift"
V = "Sub4/SemanticVerifier.swift"
H = "Sub4/DatabaseHealthView.swift"

# ------------------------------------------------------- Sub4Import — report

edit(
    I,
    r'''        var unresolvedGear: [String: Int] = [:]
        var refusals: [Refusal] = []''',
    r'''        // PATCH 274 — the reconciliation pass. Everything above this line
        // counts things that arrived; these count things that LEFT, which the
        // importer had no way to express until now.
        //
        // `reconciled` carries the reason rather than a Bool so that "a store
        // could not be read" and "the caller did not ask" are different words
        // on the health screen. A single false would have made a forgotten
        // argument look exactly like the gate doing its job.
        var reconciled: Reconciliation = .skipped("not attempted")
        var notesRemoved = 0
        var matchDecisionsRemoved = 0
        /// One row, and four more go with it: `review_evidence` and `proposal`
        /// cascade from `review`, `proposal_change` and `proposal_watch` from
        /// `proposal`. Counted as reviews because that is the thing the
        /// athlete deleted.
        var reviewsRemoved = 0

        var removedTotal: Int {
            notesRemoved + matchDecisionsRemoved + reviewsRemoved
        }

        var unresolvedGear: [String: Int] = [:]
        var refusals: [Refusal] = []''',
    "the removal counters",
)

edit(
    I,
    r'''                    matchDecisions: [MatchDecision] = [],''',
    r'''                    matchDecisions: [MatchDecision] = [],
                    // PATCH 274. DEFAULTS TO NOT RECONCILING, and that is the
                    // safe direction: a forgotten argument leaves rows behind,
                    // which is the status quo and is visible on the health
                    // screen. A default that deleted would delete in the one
                    // call site nobody thought about.
                    //
                    // The gate is computed by the CALLER — `Sub4Import` is
                    // `nonisolated` end to end and `StoreReadJournal` is on
                    // the main actor. That is the right shape anyway: the
                    // decision to delete belongs to the screen that knows
                    // what was read.
                    reconcile: Reconciliation = .skipped("the caller did not ask"),''',
    "run takes permission",
)

edit(
    I,
    r'''        let clock = ContinuousClock()
        var report = Report()
        let now = iso8601(Date())''',
    r'''        let clock = ContinuousClock()
        var report = Report()
        report.reconciled = reconcile
        let now = iso8601(Date())''',
    "the report carries the decision",
)

edit(
    I,
    r'''                try importRecordings(d, streams: streams, now: now, into: &report)
                try importDetails(d, details: details, now: now, into: &report)
            }''',
    r'''                try importRecordings(d, streams: streams, now: now, into: &report)
                try importDetails(d, details: details, now: now, into: &report)

                // LAST, AND INSIDE THE SAME WRITE — patch 274.
                //
                // Last because everything above has already put the current
                // records in, so what is left over is genuinely left over.
                // Inside the write because a throw here must roll the whole
                // import back rather than leave a half-reconciled database.
                if reconcile.isRunning {
                    try reconcileAuthored(d, notes: notes, proposals: proposals,
                                          matchDecisions: matchDecisions,
                                          into: &report)
                }
            }''',
    "run reconciles last",
)

# --------------------------------------------------------- SemanticVerifier

edit(
    V,
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       matchDecisions: [MatchDecision] = [],''',
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],
                       matchDecisions: [MatchDecision] = [],''',
    "verify takes the reviews",
)

edit(
    V,
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        matchDecisions: [MatchDecision] = [],''',
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        matchDecisions: [MatchDecision] = [],''',
    "attempt takes the reviews",
)

edit(
    V,
    r'''            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, matchDecisions: matchDecisions,
                              weather: weather, zones: zones,
                              streams: streams, details: details)''',
    r'''            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, proposals: proposals,
                              matchDecisions: matchDecisions,
                              weather: weather, zones: zones,
                              streams: streams, details: details)''',
    "attempt passes them on",
)

edit(
    V,
    r'''                checks.append(contentsOf: try countChecks(
                    d, activities: activities, shoes: shoes, notes: notes,
                    matchDecisions: matchDecisions,''',
    r'''                checks.append(contentsOf: try countChecks(
                    d, activities: activities, shoes: shoes, notes: notes,
                    proposals: proposals,
                    matchDecisions: matchDecisions,''',
    "verify passes them down",
)

edit(
    V,
    r'''    private static func countChecks(_ d: Database,
                                    activities: [Activity],
                                    shoes: [AthleteStore.Shoe],
                                    notes: [NotesStore.Note],
                                    matchDecisions: [MatchDecision],''',
    r'''    private static func countChecks(_ d: Database,
                                    activities: [Activity],
                                    shoes: [AthleteStore.Shoe],
                                    notes: [NotesStore.Note],
                                    proposals: [ProposalStore.Record],
                                    matchDecisions: [MatchDecision],''',
    "countChecks takes the reviews",
)

edit(
    V,
    r'''            .compare("match decisions", table: "match_decision",
                     expected: expectedDecisions,
                     found: try count(d, "match_decision")),''',
    r'''            .compare("match decisions", table: "match_decision",
                     expected: expectedDecisions,
                     found: try count(d, "match_decision")),
            // PATCH 274, AND IT SHOULD HAVE BEEN HERE SINCE 263.
            //
            // The verifier has compared notes since the day it was written and
            // has never compared reviews — so when the rehearsal record was
            // deleted from `proposals.json` on 5 August and stayed in the
            // database, fourteen comparisons agreed and the run was marked
            // verified. The one store in this app that cannot be re-fetched is
            // the one nothing was checking.
            //
            // COUNTS THE PARENT ONLY. Its four children are reachable from it
            // and cascade with it; a count of `proposal_change` would be
            // asserting the shape of somebody's review rather than that the
            // review is there.
            .compare("reviews", table: "review",
                     expected: proposals.count, found: try count(d, "review")),''',
    "the reviews comparison",
)

# ----------------------------------------------------- DatabaseHealthView

edit(
    H,
    r'''            do {
                importReport = try Sub4Import.run(''',
    r'''            do {
                // PATCH 274 — THE GATE, asked here because this is the only
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
                        ["notes.json", "proposals.json", Matcher.decisionsKey])
                    ? .run
                    : .skipped("a store could not be read")

                importReport = try Sub4Import.run(''',
    "the import asks the gate",
)

edit(
    H,
    r'''                    proposals: ProposalStore.shared.records,
                    matchDecisions: Array(Matcher.shared.decisions.values),''',
    r'''                    proposals: ProposalStore.shared.records,
                    matchDecisions: Array(Matcher.shared.decisions.values),
                    reconcile: permission,''',
    "the import passes it",
)

edit(
    H,
    r'''                notes: Array(NotesStore.shared.notes.values),
                matchDecisions: Array(Matcher.shared.decisions.values),
                weather: Array(WeatherStore.shared.byActivity.values),''',
    r'''                notes: Array(NotesStore.shared.notes.values),
                proposals: ProposalStore.shared.records,
                matchDecisions: Array(Matcher.shared.decisions.values),
                weather: Array(WeatherStore.shared.byActivity.values),''',
    "the verify call compares reviews",
)

edit(
    H,
    r'''                // REFUSALS ARE SHOWN, NOT COUNTED AND HIDDEN. A silent
                // rejection is indistinguishable from a row that was never
                // there — §12.2.''',
    r'''                // PATCH 274. A pass that DELETES has to say so on the same
                // screen and with the same weight as one that adds — a silent
                // removal is the defect §12.2 names, from the other side.
                LabeledContent("Reconciled", value: r.reconciled.line)
                    .font(.caption)
                    .foregroundStyle(r.reconciled.isRunning ? Color.primary : Color.red)
                if r.notesRemoved > 0 {
                    LabeledContent("  notes removed", value: "\(r.notesRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.matchDecisionsRemoved > 0 {
                    LabeledContent("  match decisions removed",
                                   value: "\(r.matchDecisionsRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.reviewsRemoved > 0 {
                    // Named with its consequence. One review takes its
                    // evidence, its proposal, its changes and its watch items
                    // with it, and a row saying "1" while five vanish is a
                    // number that invites the wrong arithmetic.
                    LabeledContent("  reviews removed, with their proposals",
                                   value: "\(r.reviewsRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                // REFUSALS ARE SHOWN, NOT COUNTED AND HIDDEN. A silent
                // rejection is indistinguishable from a row that was never
                // there — §12.2.''',
    "the reconciliation rows",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.21 What the athlete deleted — D4's database half, 3 of 3, patch 274

§12.20.1 recorded the finding: the importer is additive-only, and the rehearsal
record deleted from `proposals.json` was still in the database. This is the
pass that removes it, and 273 is the reason it can be trusted to.

### 12.21.1 Three tables, and the list is short on purpose

`user_note` and `match_decision` by `planSessionUID`; `review` by `ranUTC`,
which takes `review_evidence`, `proposal`, `proposal_change` and
`proposal_watch` with it through foreign keys that already said
`ON DELETE CASCADE`.

**Nothing fetched is reconciled.** Activities, gear, weather, traces, details,
the plan and the profile are left alone, because for those an empty store means
a sync that has not run rather than a decision to remove something — and the
athlete cannot delete them one at a time in the first place. A pass that read
"Strava is unreachable" as "the athlete deleted 668 activities" would be the
worst defect this project has shipped.

### 12.21.2 The gate carries a reason, not a Bool

`Reconciliation` is `.run` or `.skipped(String)`. The health screen prints the
reason.

A Bool would have made **"a store could not be read"** and **"the caller did
not ask for it"** the same word — and those are opposite facts. The first is
the gate working. The second is a bug in the call site, and it would have been
invisible behind a screen reading *Reconciled: no* for months.

The default is `.skipped("the caller did not ask")`. **A forgotten argument
leaves rows behind**, which is the status quo, visible on the health screen and
now caught by the verifier. A default that deleted would delete in the one call
site nobody thought about.

The gate is computed by the caller: `Sub4Import` is `nonisolated` end to end
and `StoreReadJournal` is on the main actor. That constraint turns out to be
the right shape anyway — the decision to delete belongs to the screen that
knows what was read, not to the code doing the deleting.

### 12.21.3 A held-back decision is not a deletion

The pass keeps by the STORE's uids, not by what the import managed to write.
A match decision naming an activity that is not here is held back by §12.19.4
and writes no row — and its uid is still in the store, so the pass leaves the
existing row alone. Reading "no row was written" as "he deleted it" would let a
temporarily missing activity silently destroy a correction.

### 12.21.4 Row by row, which is not the obvious SQL

`DELETE … WHERE key NOT IN (…)` is one statement and shorter. It also cannot
express an empty keep-set without special-casing into `DELETE FROM …` — the
most dangerous statement in the file, written as a fallthrough — it binds one
parameter per record against a limit that is a build setting of SQLite rather
than a promise, and it cannot count what it removed. Fetching the keys and
deleting by id costs one extra read on tables holding single digits.

### 12.21.5 The verifier should have compared reviews since 263

It has compared notes since the day it was written. It has never compared
reviews. So on 5 August the rehearsal was deleted from the store, stayed in the
database, and the next run reported **fourteen comparisons, all agreed,
verified** — with the one store in this app that cannot be re-fetched being the
one nothing was checking.

It counts the parent only. The four children are reachable from it and cascade
with it; counting `proposal_change` would assert the shape of somebody's review
rather than that the review is there.

**This is the fifth control this project has found reporting work it did not
do**, and the second in two days: patch 270's delete button dismissed the sheet
and left half the record behind, and the verifier said everything agreed while
looking away from the table that disagreed.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.21",
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
