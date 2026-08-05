#!/usr/bin/env python3
"""
Patch 278 — what a rule threw away. D5 slice 3.

`strava.rejectedByRule` held a rendered sentence per refused recording.
`rejection` wants six columns. The store learns the shape, the import copies it.
`Sub4Import+Rejection.swift` ships whole in the zip.

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
L = "Sub4/DataLifecycle.swift"
T = "Sub4CoreTests/DataLifecycleCoordinatorTests.swift"

# ------------------------------------------------------------ ActivityStore

edit(
    A,
    r'''    private static let rejectedKey = "strava.rejectedByRule"''',
    r'''    /// The retired shape — `[activity id: rendered line]`. Read once by the
    /// migration in `loadRejections` and then removed. Still named in the
    /// inventory beside the new key, because a device that has not launched
    /// this build still holds it.
    nonisolated static let rejectedKey = "strava.rejectedByRule"

    /// The receipts, as records — patch 278. A `Data` blob, for the reason
    /// `match.decisions` is one: UserDefaults cannot hold a `Codable` any
    /// other way, and two parallel keys that must agree is a split brain by
    /// construction.
    nonisolated static let rejectionsKey = "strava.rejections"

    /// Asked of the type that WRITES them — the lesson
    /// `loadThresholdKeysAreCoveredAtTheirSource` exists for, applied at the
    /// moment a key changes rather than after a delete has missed one.
    nonisolated static let rejectionKeys = [rejectionsKey, rejectedKey]''',
    "the rejection keys",
)

edit(
    A,
    r'''    private(set) var rejected: [String] = []

    private func loadRejections() {
        let map = UserDefaults.standard
            .dictionary(forKey: Self.rejectedKey) as? [String: String] ?? [:]
        rejected = map.keys.sorted().compactMap { map[$0] }
    }

    private func recordRejections(_ candidates: [Activity]) {
        var map = UserDefaults.standard
            .dictionary(forKey: Self.rejectedKey) as? [String: String] ?? [:]
        var changed = false
        for a in candidates where a.selfContradictoryDistance {
            if map[a.id] == nil { map[a.id] = Self.rejectionLabel(a); changed = true }
        }
        guard changed else { return }
        UserDefaults.standard.set(map, forKey: Self.rejectedKey)
        rejected = map.keys.sorted().compactMap { map[$0] }
    }

    /// Everything needed to look the recording up in Strava and see for
    /// yourself: when, what it was called, and the two figures that disagree.
    private static func rejectionLabel(_ a: Activity) -> String {
        let kmh = (a.distance / Double(max(a.movingTime, 1))) * 3.6
        let maxKmh = (a.maxSpeed ?? 0) * 3.6
        let mins = a.movingTime / 60, secs = a.movingTime % 60
        return String(format: "%@ %@ — %.1f km in %d:%02d = %.0f km/h avg, max %.0f",
                      String(a.startLocal.prefix(10)), a.name,
                      a.km, mins, secs, kmh, maxKmh)
    }''',
    r'''    /// UNCHANGED FOR EVERY READER — patch 278 made this computed rather than
    /// stored, and `SettingsView` cannot tell. The lines are the same lines;
    /// what changed is that the app now knows what is inside them.
    var rejected: [String] { receipts.map(\.label) }

    /// The receipts themselves, as records — patch 278, §12.24.
    ///
    /// The rendered line held everything `rejection`'s columns want and none
    /// of it as a field. Parsing it back would be inventing structure out of
    /// prose, so the store learned the shape instead.
    private(set) var receipts: [RejectionReceipt] = []

    private func loadRejections() {
        if let data = UserDefaults.standard.data(forKey: Self.rejectionsKey) {
            // A blob that will not decode is LEFT WHERE IT IS rather than
            // overwritten — §12.8.1's rule, and these cannot be re-fetched:
            // the recording they describe is not in `activities.json` and the
            // cursor moved past it years ago.
            receipts = (try? JSONDecoder.sub4.decode([RejectionReceipt].self,
                                                     from: data)) ?? []
            return
        }

        guard UserDefaults.standard.object(forKey: Self.rejectedKey) != nil else { return }
        let legacy = UserDefaults.standard
            .dictionary(forKey: Self.rejectedKey) as? [String: String] ?? [:]
        receipts = RejectionReceipt.migrate(legacy)
        persistRejections()
        UserDefaults.standard.removeObject(forKey: Self.rejectedKey)
    }

    private func recordRejections(_ candidates: [Activity]) {
        var known = Set(receipts.map(\.activityId))
        var added = false
        for a in candidates where a.selfContradictoryDistance {
            guard !known.contains(a.id) else { continue }
            // A RECEIPT MADE NOW KNOWS EVERYTHING. The activity is in hand
            // here — it is the only moment it ever will be, because the next
            // save writes it out of `activities.json` for good.
            receipts.append(RejectionReceipt(a, rule: .selfContradictoryDistance))
            known.insert(a.id)
            added = true
        }
        guard added else { return }
        receipts.sort { $0.activityId < $1.activityId }
        persistRejections()
    }

    private func persistRejections() {
        // No failure to report: `UserDefaults.set` has no API for one. Same
        // position as `match.decisions`, and D5 is where it changes.
        guard let data = try? JSONEncoder.sub4.encode(receipts) else { return }
        UserDefaults.standard.set(data, forKey: Self.rejectionsKey)
    }''',
    "the receipts replace the lines",
)

# ------------------------------------------------------- Sub4Import — report

edit(
    I,
    r'''        // Patch 276 — D5 slice 2. What the app has stopped asking for.''',
    r'''        // Patch 278 — D5 slice 3. What a rule threw away. NEVER pruned:
        // nothing in the app removes a receipt short of Delete local data,
        // which removes the database in the same breath.
        var rejectionsSeen = 0
        var rejectionsImported = 0
        var rejectionsUpdated = 0

        // Patch 276 — D5 slice 2. What the app has stopped asking for.''',
    "the rejection counters",
)

edit(
    I,
    r'''                    workItems: [WorkItem] = [],''',
    r'''                    workItems: [WorkItem] = [],
                    rejections: [RejectionReceipt] = [],''',
    "run takes the receipts",
)

edit(
    I,
    r'''                try importWorkQueue(d, items: workItems, now: now, into: &report)''',
    r'''                try importWorkQueue(d, items: workItems, now: now, into: &report)

                // `rejection.sourceID` is a RESTRICTED foreign key and
                // `accountID` cascades, so both must exist — they do, from the
                // seed and from `ensureAccount`. It references no ACTIVITY,
                // deliberately: the receipt outlives the recording.
                try importRejections(d, receipts: rejections, now: now, into: &report)''',
    "run imports the receipts",
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
                       workItems: [WorkItem] = [],''',
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       proposals: [ProposalStore.Record] = [],
                       syncState: SyncState? = nil,
                       workItems: [WorkItem] = [],
                       rejections: [RejectionReceipt] = [],''',
    "verify takes the receipts",
)

edit(
    V,
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        syncState: SyncState? = nil,
                        workItems: [WorkItem] = [],''',
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        proposals: [ProposalStore.Record] = [],
                        syncState: SyncState? = nil,
                        workItems: [WorkItem] = [],
                        rejections: [RejectionReceipt] = [],''',
    "attempt takes the receipts",
)

edit(
    V,
    r'''                              syncState: syncState, workItems: workItems,''',
    r'''                              syncState: syncState, workItems: workItems,
                              rejections: rejections,''',
    "attempt passes them on",
)

edit(
    V,
    r'''                    proposals: proposals, workItems: workItems,''',
    r'''                    proposals: proposals, workItems: workItems,
                    rejections: rejections,''',
    "verify passes them down",
)

edit(
    V,
    r'''                                    workItems: [WorkItem],
                                    matchDecisions: [MatchDecision],''',
    r'''                                    workItems: [WorkItem],
                                    rejections: [RejectionReceipt],
                                    matchDecisions: [MatchDecision],''',
    "countChecks takes the receipts",
)

edit(
    V,
    r'''            .compare("stopped asking", table: "work_queue",
                     expected: workItems.count, found: try count(d, "work_queue")),''',
    r'''            .compare("stopped asking", table: "work_queue",
                     expected: workItems.count, found: try count(d, "work_queue")),
            // NOT filtered by `storeIDs`, unlike weather and the traces. A
            // rejection is ABOUT a recording the database deliberately does
            // not hold — expecting only the ones with an activity would expect
            // none of them.
            .compare("refused recordings", table: "rejection",
                     expected: rejections.count, found: try count(d, "rejection")),''',
    "the rejection comparison",
)

# ----------------------------------------------------- DatabaseHealthView

edit(
    H,
    r'''                    workItems: DetailStore.shared.workItems,
                    reconcile: permission,''',
    r'''                    workItems: DetailStore.shared.workItems,
                    rejections: ActivityStore.shared.receipts,
                    reconcile: permission,''',
    "the import carries the receipts",
)

edit(
    H,
    r'''                workItems: DetailStore.shared.workItems,
                matchDecisions: Array(Matcher.shared.decisions.values),''',
    r'''                workItems: DetailStore.shared.workItems,
                rejections: ActivityStore.shared.receipts,
                matchDecisions: Array(Matcher.shared.decisions.values),''',
    "the verify carries the receipts",
)

edit(
    H,
    r'''                // PATCH 277. THE COUNTER THAT HAD NO DECISION BESIDE IT.''',
    r'''                // PATCH 278. The one row on this screen that describes
                // recordings the database does not hold and never will — so it
                // sits with the counts rather than with the activities.
                LabeledContent("Refused recordings",
                               value: r.rejectionsSeen == 0
                               ? "none"
                               : "\(r.rejectionsImported) new, \(r.rejectionsUpdated) refreshed")
                    .font(.caption)

                // PATCH 277. THE COUNTER THAT HAD NO DECISION BESIDE IT.''',
    "the refused-recordings row",
)

# --------------------------------------------------------- the inventories

edit(
    L,
    r'''                      .preferences(["strava.cursor", "strava.lastSync",
                                    "strava.cutoffUsed", "strava.rejectedByRule",''',
    r'''                      // `strava.rejections` since patch 278 — the receipts
                      // as records. The retired key is still named because a
                      // device that has not launched this build still holds
                      // it, and a key nobody names is a key Delete local data
                      // cannot remove.
                      .preferences(["strava.cursor", "strava.lastSync",
                                    "strava.cutoffUsed", "strava.rejections",
                                    "strava.rejectedByRule",''',
    "the inventory names both keys",
)

edit(
    T,
    r'''            "strava.rejectedByRule", "strava.geoBackfill",''',
    r'''            "strava.rejections", "strava.rejectedByRule", "strava.geoBackfill",''',
    "the test list names both keys",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.24 What a rule threw away — D5 slice 3, patch 278

`ActivityStore.rejected`'s declaration already said why this table matters: *"A
rejected activity is not written to activities.json and the cursor moves past
it, so after one launch there is nothing left in the app that remembers it
existed. A rule that silently deletes data is worse than the data it deleted —
this is the receipt, and Settings prints it."*

It was stored as a rendered sentence:

```
2025-04-12 Evening Ride — 41.3 km in 22:14 = 111 km/h avg, max 19
```

Every column `rejection` wants is in there, and **none of it is a field**.

### 12.24.1 The store learns the shape; parsing was the wrong answer

Reading the four values back out of that sentence would be inventing structure
out of prose — and it would work, until a name contained an em dash. So this is
§12.19's shape again: the STORE gains a record, and the import becomes the easy
half.

`RejectionReceipt` carries the rule, the instant, the name, the day, the
distance, the elapsed seconds, and the rendered line kept verbatim.

**`ActivityStore.rejected` is now computed and every reader is unchanged.**
`SettingsView` prints the same lines it always did; what changed is that the app
knows what is inside them.

**The receipt is made at the only moment it can be.** `recordRejections` has
the `Activity` in hand — and that is the last time anything will, because the
next save writes it out of `activities.json` for good.

### 12.24.2 A migrated receipt says what it does not know

The retired shape stored no timestamp and no fields, so a receipt built from one
carries `dateIsKnown == false` and NULL for name, day, distance and duration.
Those four columns are nullable. The two that are not can both be supplied
honestly:

- **`rule`** — there has only ever been one, `selfContradictoryDistance`, so
  naming it is a fact rather than a guess. `oneRuleOnly` pins that: a second
  rule would make this migration wrong, and it cannot be re-run.
- **`noticedUTC`** — the migration instant, disclosed by `dateIsKnown`.

§12.19.3 refused to invent a plausible date; §12.23.4 accepted one. **This is
the first case, not the second** — §8 groups `rejection` with the authored
tables, and it outlives the activity it describes, so it is history rather than
bookkeeping.

### 12.24.3 It references no activity, and the verifier must not either

`rejection` has foreign keys to `account` and `source` and **none to
`activity`**, deliberately: the row is about a recording the database refuses to
hold.

That makes its count check different from weather's and the traces'. Those
filter by `storeIDs`, because a reading about an absent activity is the schema
correctly declining. Filtering here would expect **none of them**.

### 12.24.4 Nothing prunes this table, and that was checked rather than assumed

`resetCache()` clears activities, the cursor and the last sync — and not the
receipts. `dropInMemory()` clears them in memory without writing. Only
`DataLifecycleCoordinator.deleteEverything` removes the key, and that removes
the database in the same breath.

So a receipt never disappears from the store while its row survives, and
§12.21's reconciliation problem does not arise. Recorded because the opposite
was assumed while this patch was being designed, and reading `resetCache` is
what settled it — the third time in two patches that a claim was corrected by
reading the code that produces it.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.24",
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
