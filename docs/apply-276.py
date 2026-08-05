#!/usr/bin/env python3
"""
Patch 276 — what the app has stopped asking for. D5 slice 2.

`detail.failed` and `detail.noStreams` reach `work_queue`. No store reshape was
needed after all — see the header of `Sub4Import+WorkQueue.swift`, which ships
whole in the zip.

Also corrects one falsehood in the data inventory: `weather.unavailable` is
named there as storage the app keeps, and the app deletes it on every launch.

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


D = "Sub4/DetailStore.swift"
I = "Sub4/Sub4Import.swift"
V = "Sub4/SemanticVerifier.swift"
H = "Sub4/DatabaseHealthView.swift"
L = "Sub4/DataLifecycle.swift"
T = "Sub4CoreTests/DataLifecycleCoordinatorTests.swift"

# ------------------------------------------------------------- DetailStore

edit(
    D,
    r'''    private var noStreams: Set<String> = []''',
    r'''    private var noStreams: Set<String> = []

    /// The two sets as `work_queue` rows — patch 276, D5 slice 2.
    ///
    /// A COMPUTED VIEW, and both sets stay private. The importer needs to READ
    /// what the app has stopped asking for; nothing outside this file has any
    /// business adding to it, because an id written here is never fetched
    /// again.
    ///
    /// THE STATES ARE NOT THE SAME and that is the whole content of this
    /// property. `failed` is a 404 — the fetch did not produce the thing it
    /// went for. `noStreams` is a 200 with nothing in it — the fetch SUCCEEDED
    /// and the honest answer was that there is no trace. Filing the second as
    /// a failure would report a fault against 23 activities on this device
    /// that are simply indoor sessions and manual entries.
    ///
    /// Sorted, so the import does not reshuffle rows between runs for no
    /// reason.
    var workItems: [WorkItem] {
        failed.sorted().map {
            WorkItem(kind: .detail, subjectID: $0, state: .failed,
                     attempts: 1,
                     lastError: "the source refused this recording")
        }
        + noStreams.sorted().map {
            WorkItem(kind: .stream, subjectID: $0, state: .done,
                     attempts: 1, lastError: nil)
        }
    }''',
    "the store's work items",
)

# ------------------------------------------------------- Sub4Import — report

edit(
    I,
    r'''        // Patch 275 — D5 slice 1. Where the sync has got to.''',
    r'''        // Patch 276 — D5 slice 2. What the app has stopped asking for.
        // `removed` is this importer pruning its own kinds, which is NOT what
        // §12.21's reconciliation does: it owns `detail` and `stream`
        // entirely and gets the complete set every run.
        var workItemsSeen = 0
        var workItemsImported = 0
        var workItemsUpdated = 0
        var workItemsRemoved = 0

        // Patch 275 — D5 slice 1. Where the sync has got to.''',
    "the work-queue counters",
)

edit(
    I,
    r'''                    syncState: SyncState? = nil,''',
    r'''                    syncState: SyncState? = nil,
                    workItems: [WorkItem] = [],''',
    "run takes the work items",
)

edit(
    I,
    r'''                try importSyncState(d, state: syncState, now: now, into: &report)''',
    r'''                try importSyncState(d, state: syncState, now: now, into: &report)

                // Group 9 as well, and it references nothing — `work_queue`
                // has no foreign keys at all, because the subject of a piece
                // of work may be an id the database has never held.
                try importWorkQueue(d, items: workItems, now: now, into: &report)''',
    "run imports the work items",
)

# --------------------------------------------------------- SemanticVerifier

edit(
    V,
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],
                       syncState: SyncState? = nil,''',
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],
                       syncState: SyncState? = nil,
                       workItems: [WorkItem] = [],''',
    "verify takes the work items",
)

edit(
    V,
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        syncState: SyncState? = nil,''',
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        syncState: SyncState? = nil,
                        workItems: [WorkItem] = [],''',
    "attempt takes the work items",
)

edit(
    V,
    r'''            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, proposals: proposals,
                              syncState: syncState,''',
    r'''            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, proposals: proposals,
                              syncState: syncState, workItems: workItems,''',
    "attempt passes them on",
)

edit(
    V,
    r'''                checks.append(contentsOf: try countChecks(
                    d, activities: activities, shoes: shoes, notes: notes,
                    proposals: proposals,''',
    r'''                checks.append(contentsOf: try countChecks(
                    d, activities: activities, shoes: shoes, notes: notes,
                    proposals: proposals, workItems: workItems,''',
    "verify passes them down",
)

edit(
    V,
    r'''                                    proposals: [ProposalStore.Record],
                                    matchDecisions: [MatchDecision],''',
    r'''                                    proposals: [ProposalStore.Record],
                                    workItems: [WorkItem],
                                    matchDecisions: [MatchDecision],''',
    "countChecks takes the work items",
)

edit(
    V,
    r'''            .compare("reviews", table: "review",
                     expected: proposals.count, found: try count(d, "review")),''',
    r'''            .compare("reviews", table: "review",
                     expected: proposals.count, found: try count(d, "review")),
            // A COUNT IS ENOUGH HERE, unlike the sync position. Every row is
            // one id the app will never ask about again, so the number of them
            // IS the fact — and the importer prunes, so a stale row shows up
            // as a disagreement rather than being quietly tolerated.
            .compare("stopped asking", table: "work_queue",
                     expected: workItems.count, found: try count(d, "work_queue")),''',
    "the work-queue comparison",
)

# ----------------------------------------------------- DatabaseHealthView

edit(
    H,
    r'''                    syncState: ActivityStore.shared.syncState,
                    reconcile: permission,''',
    r'''                    syncState: ActivityStore.shared.syncState,
                    workItems: DetailStore.shared.workItems,
                    reconcile: permission,''',
    "the import carries the work items",
)

edit(
    H,
    r'''                syncState: ActivityStore.shared.syncState,
                matchDecisions: Array(Matcher.shared.decisions.values),''',
    r'''                syncState: ActivityStore.shared.syncState,
                workItems: DetailStore.shared.workItems,
                matchDecisions: Array(Matcher.shared.decisions.values),''',
    "the verify carries the work items",
)

edit(
    H,
    r'''                // PATCH 275. Its own row rather than a line inside Activities:''',
    r'''                // PATCH 276. Named for what it MEANS rather than for its
                // table: every row is a recording the app has decided not to
                // ask about again, and "work queue" would suggest something
                // still waiting to happen.
                LabeledContent("Stopped asking",
                               value: r.workItemsSeen == 0
                               ? "nothing"
                               : "\(r.workItemsImported) new, \(r.workItemsUpdated) refreshed")
                    .font(.caption)
                if r.workItemsRemoved > 0 {
                    LabeledContent("  no longer skipped",
                                   value: "\(r.workItemsRemoved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }

                // PATCH 275. Its own row rather than a line inside Activities:''',
    "the stopped-asking rows",
)

# ------------------------------- DataLifecycle — a key the app does not write

edit(
    L,
    r'''            storage: [.applicationSupport(.file("weather.json")),
                      .preferences(["weather.unavailable"])],''',
    r'''            // PATCH 276. `weather.unavailable` REMOVED from this list, and
            // that is a correction rather than a change: patch 130 stopped
            // persisting the failure set, and `WeatherStore.init` deletes the
            // key on every launch so a phone that ran 128 or 129 is not still
            // carrying its verdicts. The inventory named it as storage this
            // app keeps — a falsehood in the one document whose entire job is
            // to be true about where data lives.
            storage: [.applicationSupport(.file("weather.json"))],''',
    "the weather key the app deletes",
)

edit(
    T,
    r'''            // WeatherStore
            "weather.unavailable",
''',
    r'''            // WeatherStore writes no preference key. `weather.unavailable`
            // was listed here until patch 276 and the app has deleted it on
            // every launch since 130 — so this list asserted coverage of a key
            // nothing writes, which is the opposite of what the test is for.
''',
    "the test stops asserting a dead key",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.23 What the app has stopped asking for — D5 slice 2, patch 276

### 12.23.1 Neither set is a retry queue, and that changed the patch

`detail.failed` and `detail.noStreams` look like a retry queue from their names
and from the table they were headed for. `DetailStore` says otherwise:

- **`failed`** — ids Strava answered **404** for, deleted or private. The
  declaration's own words: *"Never retried automatically — otherwise a single
  dead id burns a queue slot on every launch, forever."*
- **`noStreams`** — 200 with nothing usable, or a 404 on the streams call. A
  manual entry, or an indoor session with no distance track.

**Both are terminal verdicts, not work waiting to happen.** A transient
failure — a timeout, a 429, a closed gate — is never persisted at all: it
returns `.transient` or `.stop` and the id goes back into an in-memory queue
rebuilt from scratch every launch.

So there is no attempt count to carry and no backoff to preserve. **A note
earlier in this session said `DetailStore` would need reshaping first, the way
`Matcher` did in §12.19, and that it would take two patches. It was wrong** —
written from the key names and the column names before the store was read. One
patch, no reshape.

### 12.23.2 `noStreams` is `done`, not `failed`

| store | kind | state |
|---|---|---|
| `detail.failed` | `detail` | `failed` — the fetch did not produce what it went for |
| `detail.noStreams` | `stream` | `done` — the fetch SUCCEEDED and there was nothing there |

On this device 668 activities carry a detail and 645 carry a trace, so **23
have none**. Filing those as failures would report a fault against twenty-three
indoor sessions and manual entries. `done` means the queue is finished with the
item, which is true of both, and the difference between them survives in
`state`.

### 12.23.3 `attempts` is 1, and 1 is a floor

An id reaches either set by being asked for at least once — that is the only
way in. The app has never counted, so 1 is the minimum known to be true rather
than a number invented to fill a column. Recorded because a reader would
otherwise take it for a measurement.

### 12.23.4 `createdUTC` is when the database learned, not when the fetch happened

Neither set records a time and nothing else in the app remembers. §12.19.3
refused to invent a date for a match decision; **this is the case where the
same trade goes the other way**, and §8's own group 9 header is the licence:
*"Bookkeeping, not history. Everything here can be thrown away and rebuilt by
re-syncing."* The column says when the ROW was created, which is exactly what
is being recorded, and losing the real time costs a re-fetch rather than a
fact.

### 12.23.5 This importer prunes, and §12.21 refused to

It owns `detail` and `stream` entirely and receives the complete set every run,
so an id no longer present has genuinely been forgotten — by `resetCache`, or
by a schema bump clearing the cache. Those rows are deleted.

Safe here for two reasons that did **not** hold for notes:

1. The source is a `UserDefaults` string array with **no decode step**, so
   "empty" cannot mean "unreadable" the way a corrupt `notes.json` can. The
   failure mode §12.20 was built to catch does not exist on this path.
2. The whole table is rebuildable by re-syncing, so the worst case is a
   re-fetch rather than a loss.

A row with a NULL subject is left alone: this importer claims only rows it
could have written.

### 12.23.6 A key the inventory claimed and the app deletes

`weather.unavailable` was listed in `DataLifecycle` as preference storage under
the weather category, and asserted in `everyPreferenceKeyIsCovered` as a key
the app writes.

**The app has deleted it on every launch since patch 130**, which stopped
persisting the weather failure set — `WeatherStore.init` removes the key so a
phone that ran 128 or 129 is not still carrying its verdicts.

Both are corrected. Worth its own subsection because of where it was: the data
inventory is the one document in this project whose entire job is to be true
about where data lives, and it named a key this app exists to remove.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.23",
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
