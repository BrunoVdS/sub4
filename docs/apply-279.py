#!/usr/bin/env python3
"""
Patch 279 — the badge and the pane disagreed about what "unhealthy" means.

Patch 273 added `StoreReadJournal.hasUnreadable` to `SettingsView.needsAttention`
and not to `ContentView.settingsBadge`. A store the app could not read lit the
row inside Settings and not the badge whose job is to send somebody there.

Both expressions were correct. What was wrong was that there were two.
`AppHealth.swift` ships whole in the zip; this points both callers at it.

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


# ------------------------------------------------------------- ContentView

edit(
    "Sub4/ContentView.swift",
    r'''    private var settingsBadge: Int {
        // Patch 266 adds the third condition. It is an alarm and not a status
        // display — the same argument as the two above it — and a store that
        // cannot be written is exactly the kind of thing that otherwise shows
        // up as data quietly going missing at the next launch.
        let healthy = auth.isConnected
            && activities.lastError == nil
            && !StoreWriteJournal.shared.hasUnsaved
        return healthy ? 0 : 1
    }''',
    r'''    /// PATCH 279 — THE CONDITIONS LIVE IN `AppHealth` NOW, and the reason is
    /// that this expression and `SettingsView.needsAttention` were two answers
    /// to one question. 273 added the read journal to that one and not to this
    /// one, so a store the app could not read lit the row INSIDE Settings and
    /// not the badge that sends somebody there.
    ///
    /// Both were correct in isolation. What was wrong was that there were two.
    ///
    /// ONE OR ZERO, NEVER A COUNT. It is an alarm, not a status display — a
    /// reader with three problems does not need the number three, they need
    /// this tab.
    private var settingsBadge: Int {
        AppHealth.needsAttention(
            isConnected: auth.isConnected,
            syncError: activities.lastError,
            hasUnsavedStore: StoreWriteJournal.shared.hasUnsaved,
            hasUnreadableStore: StoreReadJournal.shared.hasUnreadable) ? 1 : 0
    }''',
    "the badge asks AppHealth",
)

# ------------------------------------------------------------ SettingsView

edit(
    "Sub4/SettingsView.swift",
    r'''    private var needsAttention: Bool {
        !auth.isConnected || activities.lastError != nil
            || StoreWriteJournal.shared.hasUnsaved
            // PATCH 273. The write journal says the app has more than it
            // saved; this one says it has LESS than it holds, which is the
            // worse of the two and had no way to be said at all.
            || StoreReadJournal.shared.hasUnreadable
    }''',
    r'''    /// PATCH 279. The same call the tab badge makes, so the pane and the
    /// badge cannot disagree about what is wrong — which they did between 273
    /// and 279.
    private var needsAttention: Bool {
        AppHealth.needsAttention(
            isConnected: auth.isConnected,
            syncError: activities.lastError,
            hasUnsavedStore: StoreWriteJournal.shared.hasUnsaved,
            hasUnreadableStore: StoreReadJournal.shared.hasUnreadable)
    }''',
    "the pane asks AppHealth",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.25 Two answers to one question — patch 279

`ContentView.settingsBadge` and `SettingsView.needsAttention` both answer "is
something wrong that the athlete can act on". **Patch 273 added
`StoreReadJournal.hasUnreadable` to the second and not the first.**

So a store the app could not read lit the row **inside** Settings and not the
badge whose entire job is to send somebody there. The badge's own comment
argues against that: *"if the token expires and nothing says so, every session
quietly renders as not-done and it reads as missed training rather than as a
broken sync. It is an alarm, not a status display, and it sits on the tab that
can fix it."* A store showing LESS than it holds is exactly that alarm, wired
to the quieter of the two places.

**A test would not have caught it.** Both expressions were correct in
isolation; what was wrong was that there were two. So the fix is a shape rather
than an assertion: one function, two callers, and a fifth condition can no
longer be added to one and forgotten in the other.

**It takes its inputs rather than reading the singletons.** Two reasons, and
the first is not stylistic: each caller observes its own `StravaAuth` and
`ActivityStore`, so reaching for `.shared` inside `AppHealth` would bypass
SwiftUI's observation and stop the badge updating when the state changed. The
second is that four `Bool` parameters are testable, and the two `private var`s
on two `View`s it replaces were not — `AppHealthTests` is the first coverage
this rule has ever had.

**Found from the device, again, and not from the code.** A red `1` appeared on
the Settings tab between two imports and cleared on its own — almost certainly
`activities.lastError` from a sync that failed and then succeeded, which is a
value held only in memory and recorded nowhere. Looking up what the badge
actually reads is what surfaced the divergence. The transient itself remains
untraceable by design; that is a separate gap and is not closed here.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.25",
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
