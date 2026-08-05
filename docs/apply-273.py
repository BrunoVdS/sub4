#!/usr/bin/env python3
"""
Patch 273 — a store that could not be read must not look empty.

Four authored stores learn the difference between "there is no file" and "the
file is there and will not decode", and report it. This is the prerequisite for
274's reconciliation pass: that pass deletes database rows whose record is gone
from the store, and driven by a store that failed to read it would delete the
only intact copy.

`StoreRead.swift` and `StoreReadJournal.swift` ship whole in the zip. This
script wires them in.

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


N = "Sub4/NotesStore.swift"
P = "Sub4/ProposalStore.swift"
C = "Sub4/CommuteStore.swift"
M = "Sub4/Matcher.swift"
S = "Sub4/SettingsView.swift"
H = "Sub4/DatabaseHealthView.swift"

# ------------------------------------------------------------- NotesStore

edit(
    N,
    r'''    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        notes = (try? JSONDecoder.sub4.decode([String: Note].self, from: data)) ?? [:]
    }''',
    r'''    /// What the last read of `notes.json` found — patch 273, §12.20.
    ///
    /// The two `try?`s below used to make "there is no file" and "the file is
    /// there and will not decode" produce the identical state: an empty
    /// dictionary, no error, nothing anywhere saying which had happened. On
    /// the store that holds thirteen months of what the athlete thought after
    /// each session.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        let (value, outcome) = StoreRead.decode([String: Note].self, at: fileURL)
        // ONLY ON SUCCESS. A failed read leaves whatever was already in memory
        // rather than replacing it with an empty — which matters on a
        // re-entrant load and costs nothing on the first one.
        if let value { notes = value }
        lastLoad = outcome
    }''',
    "notes says how it read",
)

edit(
    N,
    r'''        fileURL = dir.appendingPathComponent("notes.json")
        load()
        migrateIfNeeded()''',
    r'''        fileURL = dir.appendingPathComponent("notes.json")
        load()
        // SINGLETON ONLY — patch 273. `init(directory:)` deliberately does not
        // record: a test store writing into the shared journal would leak into
        // whatever ran next, and this journal's whole job is to be believed.
        StoreReadJournal.shared.record("notes.json", lastLoad)
        migrateIfNeeded()''',
    "notes records its read",
)

# ---------------------------------------------------------- ProposalStore

edit(
    P,
    r'''    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        records = (try? JSONDecoder.sub4.decode([Record].self, from: data)) ?? []
    }''',
    r'''    /// What the last read of `proposals.json` found — patch 273, §12.20.
    ///
    /// THE ONE WITH THE MOST TO LOSE. A review costs a call to a model and
    /// cannot be reproduced by asking Strava again; §12.8.1 is the record of
    /// what that costs, from the day a reinstall took every past review and
    /// there was nowhere to get them back from.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        let (value, outcome) = StoreRead.decode([Record].self, at: fileURL)
        if let value { records = value }
        lastLoad = outcome
    }''',
    "proposals says how it read",
)

edit(
    P,
    r'''        fileURL = dir.appendingPathComponent("proposals.json")
        load()
        migrateIfNeeded()''',
    r'''        fileURL = dir.appendingPathComponent("proposals.json")
        load()
        StoreReadJournal.shared.record("proposals.json", lastLoad)
        migrateIfNeeded()''',
    "proposals records its read",
)

# ----------------------------------------------------------- CommuteStore

edit(
    C,
    r'''    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        decisions = (try? JSONDecoder.sub4.decode([String: CommuteDecision].self,
                                                  from: data)) ?? [:]
    }''',
    r'''    /// What the last read of `commutes.json` found — patch 273, §12.20.
    ///
    /// An unreadable file here reads as "you have not ruled on any ride", so
    /// every decision silently falls back to `commuteByDistance` — the very
    /// rule patch 251 exists to override.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        let (value, outcome) = StoreRead.decode([String: CommuteDecision].self,
                                                at: fileURL)
        if let value { decisions = value }
        lastLoad = outcome
    }''',
    "commutes says how it read",
)

edit(
    C,
    r'''        fileURL = dir.appendingPathComponent("commutes.json")
        load()
    }''',
    r'''        fileURL = dir.appendingPathComponent("commutes.json")
        load()
        StoreReadJournal.shared.record("commutes.json", lastLoad)
    }''',
    "commutes records its read",
)

# ---------------------------------------------------------------- Matcher

edit(
    M,
    r'''    private init() {
        defaults = .standard
        load()
    }''',
    r'''    private init() {
        defaults = .standard
        load()
        // SINGLETON ONLY — patch 273, the same rule as the three file stores.
        StoreReadJournal.shared.record(Self.decisionsKey, lastLoad)
    }''',
    "the matcher records its read",
)

edit(
    M,
    r'''    private func load() {
        if let data = defaults.data(forKey: Self.decisionsKey) {
            // A blob that will not decode is LEFT WHERE IT IS rather than
            // overwritten. There is nowhere to report it from here — see the
            // header on why this store has no journal — and destroying
            // authored data to tidy up a read is the trade §12.8.1 says never
            // to make.
            let list = (try? JSONDecoder.sub4.decode([MatchDecision].self, from: data)) ?? []
            decisions = Dictionary(list.map { ($0.sessionUid, $0) },
                                   uniquingKeysWith: { _, later in later })
            return
        }

        guard defaults.object(forKey: Self.legacyKey) != nil else { return }
        decisions = Self.migrate(defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:])
        persist()
        defaults.removeObject(forKey: Self.legacyKey)
    }''',
    r'''    /// What the last read of the blob found — patch 273, §12.20.
    ///
    /// AND A CORRECTION TO THE COMMENT THIS REPLACES, which said there was
    /// nowhere to report an undecodable blob from. That was true for one
    /// patch. This store still has no WRITE journal, for the reason in the
    /// header — `UserDefaults.set` has no failure to report — but a read that
    /// found something it could not use is a fact with somewhere to go.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        if let data = defaults.data(forKey: Self.decisionsKey) {
            // A blob that will not decode is LEFT WHERE IT IS rather than
            // overwritten: destroying authored data to tidy up a read is the
            // trade §12.8.1 says never to make. What changed in 273 is that
            // the fact is recorded rather than swallowed.
            guard let list = try? JSONDecoder.sub4.decode([MatchDecision].self,
                                                          from: data) else {
                lastLoad = .unreadable("the stored decisions did not decode")
                return
            }
            decisions = Dictionary(list.map { ($0.sessionUid, $0) },
                                   uniquingKeysWith: { _, later in later })
            lastLoad = .loaded
            return
        }

        guard defaults.object(forKey: Self.legacyKey) != nil else {
            lastLoad = .absent
            return
        }
        decisions = Self.migrate(defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:])
        persist()
        defaults.removeObject(forKey: Self.legacyKey)
        lastLoad = .loaded
    }''',
    "the matcher says how it read",
)

# ----------------------------------------------------------- SettingsView

edit(
    S,
    r'''            || StoreWriteJournal.shared.hasUnsaved
    }''',
    r'''            || StoreWriteJournal.shared.hasUnsaved
            // PATCH 273. The write journal says the app has more than it
            // saved; this one says it has LESS than it holds, which is the
            // worse of the two and had no way to be said at all.
            || StoreReadJournal.shared.hasUnreadable
    }''',
    "unread stores need attention",
)

edit(
    S,
    r'''            ForEach(StoreWriteJournal.shared.all) { unsaved in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(unsaved.store) — not saved")
                            .font(.caption.weight(.semibold))
                        Text(unsaved.line)
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                } icon: {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                }
                .foregroundStyle(.red)
            }''',
    r'''            ForEach(StoreWriteJournal.shared.all) { unsaved in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(unsaved.store) — not saved")
                            .font(.caption.weight(.semibold))
                        Text(unsaved.line)
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                } icon: {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                }
                .foregroundStyle(.red)
            }

            // PATCH 273, and the wording is the whole point. "Not saved" means
            // the app has more than the disk. This one means the app has LESS
            // than the disk — a file is there and could not be turned into
            // records, so a screen that looks empty is not describing an empty
            // store. Nothing is lost yet, and nothing may be deleted on the
            // strength of it.
            ForEach(StoreReadJournal.shared.all) { unread in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(unread.store) — could not be read")
                            .font(.caption.weight(.semibold))
                        Text(unread.line + ". What it holds is not shown, and "
                             + "nothing has been deleted.")
                            .font(.caption2).foregroundStyle(Color.dim)
                    }
                } icon: {
                    Image(systemName: "doc.badge.ellipsis")
                }
                .foregroundStyle(.red)
            }''',
    "the unreadable rows",
)

# ------------------------------------------------------ DatabaseHealthView

edit(
    H,
    r'''        lines.append(contentsOf: StoreWriteJournal.shared.diagnosticLines)''',
    r'''        lines.append(contentsOf: StoreWriteJournal.shared.diagnosticLines)
        // PATCH 273. UNCONDITIONAL, like the line above it and for 266c's
        // reason: "Unreadable stores: none" in a paste is evidence, and a
        // line that only appears when something is wrong cannot be
        // distinguished from a line nobody wired in.
        lines.append(contentsOf: StoreReadJournal.shared.diagnosticLines)''',
    "the paste carries the read journal",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.20 A store that could not be read must not look empty — patch 273

### 12.20.1 What the device showed, and what it proved

Patch 272 landed clean: 15 comparisons, all agreed, `match_decision` correctly
empty. Then the table counts were read, and `review` still held **1**, with
`review_evidence` 1, `proposal` 1, `proposal_change` 2, `proposal_watch` 2 —
the rehearsal record from patch 269, **deleted from `proposals.json` on 5
August and still in the database**.

The cause is general and was found by grep rather than by guess. Every `DELETE`
in the six importer files is a *replace-the-children-of-this-parent* delete:
zones, a review's evidence and proposal, a trace, a detail, an activity's gear
references. **Nothing anywhere reconciles a record that has disappeared from a
store.** So:

| the athlete does this | what the database does |
|---|---|
| *Back to automatic* on a match | keeps the `match_decision` row. Verifier: expected 0, found 1, **permanently** |
| deletes a note | keeps the `user_note` row. Same |
| deletes a review (patch 270) | keeps all five rows, and the verifier does not check reviews at all |

`ReviewDue` reads `ProposalStore` and not the database, so the 24 August date
is unaffected. What is left is a ghost that will sit beside the first real
review and look like a second one.

**Patch 270's delete button is the fourth control this project has found
reporting work it did not do.** It dismisses the sheet, says the review is
gone, and leaves half the record behind.

### 12.20.2 Why the obvious fix could not be built

The reconciliation pass is four `DELETE … WHERE key NOT IN (…)` statements. It
was not built, because of what the stores look like when they fail:

```swift
guard let data = try? Data(contentsOf: fileURL) else { return }
notes = (try? JSONDecoder.sub4.decode([String: Note].self, from: data)) ?? [:]
```

Two `try?`s, and **neither can tell "there is no file yet" from "the file is
there and will not decode"**. Both produce an empty store, with no error, no
row and no log. A reconciliation pass reading that state would delete every
note, every review and every match decision from the one copy that was still
intact — turning a corrupt file into permanent data loss, in the patch whose
purpose is to make the database trustworthy.

§12.9c already built a classifier that tells those conditions apart. It runs
from a button on the Database screen and **has never been in the launch path**.

### 12.20.3 Three outcomes, and only one of them is a refusal

`StoreLoad` is `.loaded`, `.absent` or `.unreadable`. `isTrustworthy` is true
for the first two.

**Absent is not a failure, and saying so is the point.** Every fresh install
has no `notes.json`; §12.9e found `proposals.json` legitimately missing on the
real device because no review had ever run. A journal that shouted about those
would be one the athlete learns to ignore, which is how the entry that mattered
would be missed.

**A zero-byte file is unreadable, not absent.** That is what an interrupted
write leaves behind — §12.9c's `truncated` condition at its limit — and calling
it "you have nothing" is the same mistake in miniature.

### 12.20.4 The gate fails closed

`StoreReadJournal.canReconcile(_:)` requires every named store to have
*reported* something believable. A store that never recorded an outcome is not
trustworthy.

That default is the whole design. Treating silence as success would make
forgetting to wire a store into the journal look exactly like wiring it in
correctly — and the failure would appear as rows quietly disappearing, months
later, with the control that did it reporting a clean run.

### 12.20.5 The read journal is not the write journal's mirror

`StoreWriteJournal` says *the app has more than it saved*. Everything it lists
is re-fetchable, so it is a warning, and a successful write clears it.

This one says *the app has LESS than it holds* — which is the worse of the two
and previously had no way to be said at all. Nothing clears it during a
session, because each store reads once at launch; the entry stands until the
next launch reads the file again.

Only the four AUTHORED stores are instrumented: `notes.json`,
`proposals.json`, `commutes.json`, `match.decisions`. The fetched stores are
deliberately left out — they can be asked for again, and 274 reconciles only
tables the athlete can delete from.

### 12.20.6 A comment that was true for one patch

`Matcher.load` carried *"there is nowhere to report it from here — see the
header on why this store has no journal"*. Written in 272, false in 273.
Corrected in place rather than deleted, because the distinction it was reaching
for survives: this store still has no WRITE journal, since `UserDefaults.set`
has no failure to report. A read that found something it could not use is a
different fact, and it has somewhere to go now.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.20",
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
