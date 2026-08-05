#!/usr/bin/env python3
"""
Patch 280 — which rides are commutes. D5 slice 4.

`commutes.json` reaches `correction`. The only source of the four that needed
no reshape: patch 251 gave `CommuteDecision` a `decided` date explicitly
because this table wanted one.

`Sub4Import+Correction.swift` ships whole in the zip.

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
    r'''        // Patch 278 — D5 slice 3. What a rule threw away.''',
    r'''        // Patch 280 — D5 slice 4. Which rides are commutes. `removed` is
        // this importer pruning its own FIELD, and it holds back entirely
        // while any decision is unaccounted for — see the guard.
        var correctionsSeen = 0
        var correctionsImported = 0
        var correctionsUpdated = 0
        var correctionsUnresolved = 0
        var correctionsIgnored = 0
        var correctionsRemoved = 0

        // Patch 278 — D5 slice 3. What a rule threw away.''',
    "the correction counters",
)

edit(
    I,
    r'''                    rejections: [RejectionReceipt] = [],''',
    r'''                    rejections: [RejectionReceipt] = [],
                    commutes: [CommuteDecision] = [],''',
    "run takes the commute decisions",
)

edit(
    I,
    r'''                try importRejections(d, receipts: rejections, now: now, into: &report)''',
    r'''                try importRejections(d, receipts: rejections, now: now, into: &report)

                // AFTER THE ACTIVITIES, like weather: the store is keyed by
                // Strava id and `correction.subjectID` holds the canonical one.
                // It takes `reconcile` because it prunes its own field, and
                // `commutes.json` is an authored store with a decode step —
                // §12.20's hazard is real on this path.
                try importCorrections(d, decisions: commutes,
                                      reconcile: reconcile, now: now,
                                      into: &report)''',
    "run imports the corrections",
)

# --------------------------------------------------------- SemanticVerifier

edit(
    V,
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],
                       syncState: SyncState? = nil,
                       workItems: [WorkItem] = [],
                       rejections: [RejectionReceipt] = [],''',
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],
                       syncState: SyncState? = nil,
                       workItems: [WorkItem] = [],
                       rejections: [RejectionReceipt] = [],
                       commutes: [CommuteDecision] = [],''',
    "verify takes the commute decisions",
)

edit(
    V,
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        syncState: SyncState? = nil,
                        workItems: [WorkItem] = [],
                        rejections: [RejectionReceipt] = [],''',
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        syncState: SyncState? = nil,
                        workItems: [WorkItem] = [],
                        rejections: [RejectionReceipt] = [],
                        commutes: [CommuteDecision] = [],''',
    "attempt takes the commute decisions",
)

edit(
    V,
    r'''                              rejections: rejections,''',
    r'''                              rejections: rejections, commutes: commutes,''',
    "attempt passes them on",
)

edit(
    V,
    r'''                    rejections: rejections,
                    matchDecisions: matchDecisions,''',
    r'''                    rejections: rejections, commutes: commutes,
                    matchDecisions: matchDecisions,''',
    "verify passes them down",
)

edit(
    V,
    r'''                                    rejections: [RejectionReceipt],
                                    matchDecisions: [MatchDecision],''',
    r'''                                    rejections: [RejectionReceipt],
                                    commutes: [CommuteDecision],
                                    matchDecisions: [MatchDecision],''',
    "countChecks takes the commute decisions",
)

edit(
    V,
    r'''            .compare("refused recordings", table: "rejection",
                     expected: rejections.count, found: try count(d, "rejection")),''',
    r'''            .compare("refused recordings", table: "rejection",
                     expected: rejections.count, found: try count(d, "rejection")),
            // FILTERED BY `storeIDs`, unlike the rejections directly above.
            // A correction is ABOUT an activity the database holds; a rejection
            // is about one it refuses. The two lines look alike and mean
            // opposite things.
            .compare("corrections", table: "correction",
                     expected: commutes.filter { storeIDs.contains($0.activityId) }.count,
                     found: try count(d, "correction")),''',
    "the correction comparison",
)

# ----------------------------------------------------- DatabaseHealthView

edit(
    H,
    r'''                    rejections: ActivityStore.shared.receipts,
                    reconcile: permission,''',
    r'''                    rejections: ActivityStore.shared.receipts,
                    commutes: Array(CommuteStore.shared.decisions.values),
                    reconcile: permission,''',
    "the import carries the commute decisions",
)

edit(
    H,
    r'''                rejections: ActivityStore.shared.receipts,
                matchDecisions: Array(Matcher.shared.decisions.values),''',
    r'''                rejections: ActivityStore.shared.receipts,
                commutes: Array(CommuteStore.shared.decisions.values),
                matchDecisions: Array(Matcher.shared.decisions.values),''',
    "the verify carries the commute decisions",
)

edit(
    H,
    r'''                        ["notes.json", "proposals.json", Matcher.decisionsKey])''',
    r'''                        ["notes.json", "proposals.json", "commutes.json",
                         Matcher.decisionsKey])''',
    "the gate covers commutes.json",
)

edit(
    H,
    r'''                // PATCH 278. The one row on this screen that describes''',
    r'''                // PATCH 280. Named "Commute decisions" and not
                // "Corrections", because that is what these rows ARE today —
                // `DataCorrections` will land in the same table later and this
                // row would then be lying about what it counts.
                LabeledContent("Commute decisions",
                               value: r.correctionsSeen == 0
                               ? "none"
                               : "\(r.correctionsImported) new, \(r.correctionsUpdated) refreshed")
                    .font(.caption)
                if r.correctionsUnresolved > 0 {
                    LabeledContent("  decision naming a missing ride",
                                   value: "\(r.correctionsUnresolved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.correctionsIgnored > 0 {
                    LabeledContent("  decision on an excluded recording",
                                   value: "\(r.correctionsIgnored)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.correctionsRemoved > 0 {
                    LabeledContent("  opinions withdrawn",
                                   value: "\(r.correctionsRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                // PATCH 278. The one row on this screen that describes''',
    "the commute-decision rows",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.26 Which rides are commutes — D5 slice 4, patch 280

### 12.26.1 The only source that needed no reshape

`match_decision` needed a date the store did not have (§12.19). `rejection`
needed six fields hidden inside a rendered sentence (§12.24). `commutes.json`
needed nothing, and patch 251's header says why:

> *"A DECISION CARRIES ITS DATE. Not decoration: the `correction` table in
> ADR-0003 §8 wants provenance for exactly this kind of row, and a decision
> with no timestamp cannot be reconciled against a later one."*

That was written seven weeks before this importer existed. **It is the only
place in this project where a store was built for a table that had not been
filled yet and turned out to fit on the first try** — and the reason it fit is
that somebody read §8 before designing the store rather than after.

### 12.26.2 `reason` is provenance here, not an argument

§8 makes the column NOT NULL because *"every correction in the app today
carries a written reason — 'chip time, official results' — and one that does
not is indistinguishable from a mistake."* Every correction *at that time* was
a `DataCorrections` entry, where the reason is the case for overriding a
recorded number.

A commute decision has no such case and needs none. §12.5's position is that
the commute **is** the athlete's decision — *"not Strava's and not a
threshold's"* — so the answer is not evidence for the correction, it is the
correction. `"The athlete's own answer, given on the ride."` states where it
came from, which is the only thing there is to say and is true of every row.

**What was deliberately not written there.** The richer version — *"the athlete
said commute; the distance rule said otherwise"* — is computable from
`Activity.commuteByDistance`, and would bake today's `MatchRules.minRideKm`
into a stored sentence. Change the threshold next year and every historic
reason becomes a claim about a rule that no longer exists.
`CommuteStore.overrides(in:)` computes that comparison live, which is where a
moving rule belongs.

### 12.26.3 The prune claims one field, and waits for a full accounting

`CommuteStore.clear(_:)` is reachable — *"I have no opinion"* is a real answer,
distinct from `false` — so rows go stale and this importer prunes.

Two limits, both load-bearing:

1. **It claims only `field = 'isCommute'`.** `DataCorrections` will land in
   this same table later and those rows are not ours to delete.
2. **It runs only when `correctionsUnresolved` and `correctionsIgnored` are
   both zero.** The keep-set is built from the ids that RESOLVED, so a decision
   the database cannot place cannot protect its own row. One unaccounted ride
   holds the whole prune back — including rows the resolved set would have
   spared. That is §12.20's hazard wearing different clothes, and the guard is
   the same answer: **do not delete on the strength of an incomplete reading.**

### 12.26.4 Filtered by `storeIDs`, and the line above it is not

The verifier's correction check filters by the activities the store holds. The
`rejection` check, one line above it, deliberately does not.

They look alike and mean opposite things: **a correction is about an activity
the database holds; a rejection is about one it refuses.** Filtering the second
would expect none of them; not filtering the first would expect corrections for
rides that are not there.

### 12.26.5 The row is named for what it holds today

`Commute decisions`, not `Corrections`. When `DataCorrections` reaches this
table the row will be counting two different things, and a label that already
said "Corrections" would quietly start being wrong instead of visibly needing a
change.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.26",
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
