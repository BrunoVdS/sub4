#!/usr/bin/env python3
"""
Patch 275 — where the sync has got to. D5 slice 1 of 6.

`strava.cursor` and `strava.lastSync` reach `sync_state`. Nothing moves: the
preference keys stay authoritative until D7. `Sub4Import+SyncState.swift` ships
whole in the zip; this wires it in.

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


A = "Sub4/ActivityStore.swift"
I = "Sub4/Sub4Import.swift"
V = "Sub4/SemanticVerifier.swift"
H = "Sub4/DatabaseHealthView.swift"

# ------------------------------------------------------------ ActivityStore

edit(
    A,
    r'''    private var cursor: TimeInterval = 0''',
    r'''    private var cursor: TimeInterval = 0

    /// What `sync_state` should say about this source — patch 275, D5.
    ///
    /// A COMPUTED VIEW RATHER THAN AN EXPOSED CURSOR. `cursor` stays private:
    /// the importer needs to READ where the sync has got to and nothing
    /// outside this file has any business setting it.
    ///
    /// `Sub4Import.sourceID` rather than the literal "strava", because
    /// `sync_state.sourceID` is a RESTRICTED foreign key — an id the schema
    /// has not seeded is refused, and two places spelling it separately is how
    /// that refusal arrives one day with no explanation.
    ///
    /// `lastResult` is `lastError` alone. `lastGateNotice` is deliberately
    /// excluded: §179 separated a deliberate refusal from an outage, and a
    /// closed gate means the sync did NOT run — which `lastSyncUTC` already
    /// says by not moving.
    var syncState: SyncState {
        SyncState(sourceID: Sub4Import.sourceID,
                  // Verbatim, via Swift's shortest round-tripping description.
                  // §8 types the column as opaque text on purpose; formatting
                  // an epoch into ISO-8601 here would be this app inventing a
                  // representation for a value it does not own.
                  cursor: "\(cursor)",
                  lastSync: lastSync,
                  lastResult: lastError)
    }''',
    "the store's sync position",
)

# ------------------------------------------------------- Sub4Import — report

edit(
    I,
    r'''        // PATCH 274 — the reconciliation pass. Everything above this line''',
    r'''        // Patch 275 — D5 slice 1. Where the sync has got to. `seen` is 0 or
        // 1 and exists for §12.10's reason: without it, "no position was
        // offered" and "a position was offered and refused" both render as a
        // blank row.
        var syncStateSeen = 0
        var syncStateImported = 0
        var syncStateUpdated = 0

        // PATCH 274 — the reconciliation pass. Everything above this line''',
    "the sync-state counters",
)

edit(
    I,
    r'''                    matchDecisions: [MatchDecision] = [],
                    // PATCH 274. DEFAULTS TO NOT RECONCILING, and that is the''',
    r'''                    matchDecisions: [MatchDecision] = [],
                    syncState: SyncState? = nil,
                    // PATCH 274. DEFAULTS TO NOT RECONCILING, and that is the''',
    "run takes the sync position",
)

edit(
    I,
    r'''                try importRecordings(d, streams: streams, now: now, into: &report)
                try importDetails(d, details: details, now: now, into: &report)''',
    r'''                try importRecordings(d, streams: streams, now: now, into: &report)
                try importDetails(d, details: details, now: now, into: &report)

                // BOOKKEEPING, NOT HISTORY — §8's group 9 header. Position in
                // the run is free: `sync_state` references `account` and
                // `source`, both of which exist before the activity loop.
                try importSyncState(d, state: syncState, now: now, into: &report)''',
    "run imports the sync position",
)

# --------------------------------------------------------- SemanticVerifier

edit(
    V,
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],''',
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],
                       syncState: SyncState? = nil,''',
    "verify takes the sync position",
)

edit(
    V,
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],''',
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        syncState: SyncState? = nil,''',
    "attempt takes the sync position",
)

edit(
    V,
    r'''            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, proposals: proposals,
                              matchDecisions: matchDecisions,''',
    r'''            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, proposals: proposals,
                              syncState: syncState,
                              matchDecisions: matchDecisions,''',
    "attempt passes it on",
)

edit(
    V,
    r'''                checks.append(try identityCheck(d, storeIDs: storeIDs))''',
    r'''                // A COUNT WOULD NOT BE ENOUGH HERE, which is why this is a
                // check of its own rather than a line in `countChecks`.
                // `sync_state` holds exactly one row per source; comparing 1
                // against 1 would agree while the cursor inside it was a week
                // out, and a cursor a week out is what D7 would resume from.
                if let syncState {
                    checks.append(try syncStateCheck(d, expected: syncState))
                }
                checks.append(try identityCheck(d, storeIDs: storeIDs))''',
    "verify checks the sync position",
)

edit(
    V,
    r'''    // MARK: 1 — Counts''',
    r'''    /// The cursor itself, not the number of rows holding one — patch 275.
    ///
    /// Compares the STRING both sides use, so this cannot pass by rounding.
    /// The store renders the `Double` once, in `ActivityStore.syncState`, and
    /// what lands in the column is that same rendering; if the two ever
    /// diverged, D7 would resume from a position nothing had checked.
    private static func syncStateCheck(_ d: Database,
                                       expected: SyncState) throws -> VerificationCheck {
        let found = try String.fetchOne(d, sql: """
            SELECT cursor FROM sync_state WHERE accountID = ? AND sourceID = ?
            """, arguments: [Sub4Import.accountID, expected.sourceID])

        let agrees = found == expected.cursor

        // THE VALUES GO IN `detail`, NOT IN `expected`/`found` — and that is a
        // privacy decision, not a formatting one. `diagnosticLines` prints
        // every check's expected and found into the redacted paste, and this
        // cursor is the start time of the athlete's most recent activity.
        // §12.7 promises that paste carries no dates from his history.
        // `detail` is documented as screen-only for exactly this case.
        return .init(name: "sync position",
                     table: "sync_state",
                     expected: "the store's cursor",
                     found: agrees ? "the same"
                          : (found == nil ? "no row" : "a different one"),
                     passed: agrees,
                     detail: agrees ? nil
                           : "store \(expected.cursor ?? "—") · "
                             + "database \(found ?? "none")")
    }

    // MARK: 1 — Counts''',
    "the sync-position check",
)

# ----------------------------------------------------- DatabaseHealthView

edit(
    H,
    r'''                    matchDecisions: Array(Matcher.shared.decisions.values),
                    reconcile: permission,''',
    r'''                    matchDecisions: Array(Matcher.shared.decisions.values),
                    syncState: ActivityStore.shared.syncState,
                    reconcile: permission,''',
    "the import carries the position",
)

edit(
    H,
    r'''                notes: Array(NotesStore.shared.notes.values),
                proposals: ProposalStore.shared.records,
                matchDecisions: Array(Matcher.shared.decisions.values),''',
    r'''                notes: Array(NotesStore.shared.notes.values),
                proposals: ProposalStore.shared.records,
                syncState: ActivityStore.shared.syncState,
                matchDecisions: Array(Matcher.shared.decisions.values),''',
    "the verify carries the position",
)

edit(
    H,
    r'''                // PATCH 274. A pass that DELETES has to say so on the same''',
    r'''                // PATCH 275. Its own row rather than a line inside Activities:
                // this is the only thing on this screen that says WHERE the
                // sync is, and at D7 it becomes the thing the sync reads.
                LabeledContent("Sync position",
                               value: r.syncStateSeen == 0
                               ? "not offered"
                               : "\(r.syncStateImported) new, \(r.syncStateUpdated) refreshed")
                    .font(.caption)

                // PATCH 274. A pass that DELETES has to say so on the same''',
    "the sync-position row",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.22 Where the sync has got to — D5 slice 1, patch 275

`strava.cursor` and `strava.lastSync` are two preference keys holding the
position of a sync that has run 668 activities through it. `sync_state` has had
a row waiting for them since the schema was written.

**Nothing moves.** The keys stay where they are and stay authoritative — D7 is
where the database starts being read. This copies, exactly as every other
importer does.

### 12.22.1 The column is opaque, so the epoch goes in verbatim

§8's own comment settles it: *"Strava's cursor is an epoch and Health's is an
anchor; a column typed to one of them would be a transport shape."*

So the `Double` is rendered by Swift's shortest round-tripping description and
stored as that string. Reformatting it to ISO-8601 would be more readable and
would be this app inventing a representation for a value it does not own — plan
step 3.6.3 asks for *"an exact source timestamp rather than something
reconstructed"*. `theCursorSurvivesTheRoundTripExactly` is the test that keeps
it honest.

### 12.22.2 The app's cursor stopped being a cursor in patch 249

Recorded here, where the value is copied, rather than only where it is
computed.

`ActivityStore.cursor` used to be the query bound: `after=` filtered by START
date, so any activity uploaded late was skipped **for ever**. 249 made the read
unconditional. The variable survives as a **high-water mark** — the instrument
for detecting the very problem it used to cause — so what lands in this column
is *the latest start we have seen*, not *where the next request begins*.

**The column name predates that change.** It is not renamed, because a
migration is history; it is explained instead. Anything reading `sync_state` at
D7 needs to know which of the two it is holding.

### 12.22.3 `lastResult` holds a problem, and NULL means there wasn't one

Writing `"ok"` on success would be inventing a word the app never said in order
to fill a column. *Whether a sync ran* is `lastSyncUTC`'s job — a non-null
timestamp with a null result is a clean sync, and both facts stay separable.

**`lastGateNotice` is deliberately excluded.** §179 separated a deliberate
refusal from an outage because a closed gate is not a broken connection, and a
closed gate means the sync did not run — which `lastSyncUTC` already says by not
moving. Folding the two into one column would put the distinction back where
179 took it out of.

### 12.22.4 The verifier compares the cursor, not the row count

`sync_state` holds exactly one row per source, so a count check would compare 1
against 1 and agree while the cursor inside it was a week out. **A cursor a week
out is what D7 would resume from**, and the activities in between would be
skipped — the 249 defect, arriving a second time through a different door.

So this check is its own layer: it reads the string back and compares it to the
string the store rendered. `theVerifierCatchesADriftedCursor` proves it can
fail, which is what makes it agreeing worth anything.

### 12.22.5 What D5 still has

`work_queue` (`detail.failed`, `detail.noStreams`, `weather.unavailable`),
`content_revision` (the store schema versions and the four backfill flags),
`rejection` (`strava.rejectedByRule` — prose where the table wants columns, so
`ActivityStore` needs reshaping exactly as `Matcher` did in §12.19),
`lifecycle_event` / `lifecycle_line` (export and disconnect receipts, which are
not in UserDefaults at all and currently persist nowhere), and
`review_evidence_source`.

**Four preference keys are staying.** `appearance.selected`,
`discipline.selected`, `volume.unit` and `zones.window` are display settings,
not data — they describe the reader, not the training. D5 is not "empty
UserDefaults"; it is "get the DATA out of UserDefaults".

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.22",
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
