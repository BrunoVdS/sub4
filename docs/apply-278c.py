#!/usr/bin/env python3
"""
Patch 278c — a migration that deletes the old copy whether or not the new one
landed.

Both key migrations written this session do the same thing:

    receipts = RejectionReceipt.migrate(legacy)
    persistRejections()                            // silently returns on failure
    UserDefaults.standard.removeObject(legacyKey)  // ...and the old copy is gone

An encode that fails leaves the records in memory for that launch and gone at
the next, with the only other copy already deleted. `Matcher` has had the same
shape since 272.

Encoding four scalars and an ISO-8601 date has no realistic failure — which is
the reasoning this project distrusts, and the consequence here is silent
permanent loss of authored data that cannot be re-fetched.

Two `Bool`s and two guards. No AppVersion bump.

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


# --------------------------------------------------------------- Matcher

edit(
    "Sub4/Matcher.swift",
    r'''        decisions = Self.migrate(defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:])
        persist()
        defaults.removeObject(forKey: Self.legacyKey)''',
    r'''        decisions = Self.migrate(defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:])
        // ONLY IF THE NEW COPY LANDED — patch 278c. Removing the old key after
        // a write that silently did nothing would leave the decisions in
        // memory for this launch and gone at the next, with nothing else
        // holding them. A migration may lose the OLD SHAPE; it may not lose
        // the data.
        guard persist() else { return }
        defaults.removeObject(forKey: Self.legacyKey)''',
    "the matcher keeps the old key until the new one lands",
)

edit(
    "Sub4/Matcher.swift",
    r'''    private func persist() {
        // SORTED, so the blob is stable between launches and a diff of a
        // backup shows a decision changing rather than a dictionary
        // reshuffling. `encode` on an array of four Sendable scalars has no
        // realistic failure, and there is nowhere to report one to.
        let list = decisions.values.sorted { $0.sessionUid < $1.sessionUid }
        guard let data = try? JSONEncoder.sub4.encode(list) else { return }
        defaults.set(data, forKey: Self.decisionsKey)
    }''',
    r'''    /// Returns whether the blob was written — patch 278c.
    ///
    /// SORTED, so the blob is stable between launches and a diff of a backup
    /// shows a decision changing rather than a dictionary reshuffling.
    ///
    /// The `Bool` has exactly one caller that reads it: the migration, which
    /// must not delete the old key on the strength of a write that did
    /// nothing. Every other caller discards it, because there is still nowhere
    /// to report a `UserDefaults` failure to — see the header.
    @discardableResult
    private func persist() -> Bool {
        let list = decisions.values.sorted { $0.sessionUid < $1.sessionUid }
        guard let data = try? JSONEncoder.sub4.encode(list) else { return false }
        defaults.set(data, forKey: Self.decisionsKey)
        return true
    }''',
    "the matcher's persist says whether it landed",
)

# --------------------------------------------------------- ActivityStore

edit(
    "Sub4/ActivityStore.swift",
    r'''        receipts = RejectionReceipt.migrate(legacy)
        persistRejections()
        UserDefaults.standard.removeObject(forKey: Self.rejectedKey)''',
    r'''        receipts = RejectionReceipt.migrate(legacy)
        // ONLY IF THE NEW COPY LANDED — patch 278c, the same rule as
        // `Matcher`. These receipts describe recordings that are not in
        // `activities.json` and that the cursor moved past years ago: if both
        // keys go, there is nothing anywhere that remembers them.
        guard persistRejections() else { return }
        UserDefaults.standard.removeObject(forKey: Self.rejectedKey)''',
    "the receipts keep the old key until the new one lands",
)

edit(
    "Sub4/ActivityStore.swift",
    r'''    private func persistRejections() {
        // No failure to report: `UserDefaults.set` has no API for one. Same
        // position as `match.decisions`, and D5 is where it changes.
        guard let data = try? JSONEncoder.sub4.encode(receipts) else { return }
        UserDefaults.standard.set(data, forKey: Self.rejectionsKey)
    }''',
    r'''    /// Returns whether the blob was written — patch 278c.
    ///
    /// No failure to REPORT: `UserDefaults.set` has no API for one, and that
    /// is unchanged. What the `Bool` buys is the one decision that depends on
    /// it — the migration must not delete the retired key unless the new one
    /// is on disk.
    @discardableResult
    private func persistRejections() -> Bool {
        guard let data = try? JSONEncoder.sub4.encode(receipts) else { return false }
        UserDefaults.standard.set(data, forKey: Self.rejectionsKey)
        return true
    }''',
    "persistRejections says whether it landed",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''### 12.24.6 A migration may lose the old shape; it may not lose the data — patch 278c

Both key migrations written in this session — `match.overrides` →
`match.decisions` in 272, `strava.rejectedByRule` → `strava.rejections` in 278 —
were written this way:

```swift
receipts = RejectionReceipt.migrate(legacy)
persistRejections()                            // silently returns on failure
UserDefaults.standard.removeObject(legacyKey)  // ...and the old copy is gone
```

An encode that fails leaves the records in memory for that launch and gone at
the next, with the only other copy already deleted.

**The reasoning that produced it is the reasoning to distrust.** Both `persist`
functions carried a comment saying encoding four scalars has no realistic
failure and there is nowhere to report one to. Both halves are true. Neither is
a reason to delete the fallback: the cost of keeping a retired key one launch
longer is a dead preference; the cost of the write not landing is authored data
with nowhere to come back from — §12.8.1, again.

`persist()` now returns a `Bool` and the migration is guarded on it. Exactly
one caller reads the value; every other discards it, which is §12.17.2's
position unchanged.

**Caught before the second one ran.** The match-decision migration had already
executed on the device with zero entries, so nothing was at risk. The rejection
migration had not — it was found while writing the instructions to install the
build that would have run it.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.24.6",
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
