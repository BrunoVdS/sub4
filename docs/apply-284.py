#!/usr/bin/env python3
"""
Patch 284 — the letter fix-ups show.

283a was installed and the phone read "Source patch 283". Not wrong exactly,
and not the truth either: the number whose whole job is to say which source is
running could not tell a device with the fix-up from one without it. That is
the same false negative as a stale number and harder to spot, because nothing
looks stale.

`AppVersion.swift` ships whole with a `revision` constant beside `patch` and a
`patchLabel` that joins them. THE RULE CHANGES with this patch: a letter
fix-up now ships `AppVersion.swift` too, with `patch` unchanged and `revision`
set to its letter.

ONE NEW FILE — Sub4CoreTests/AppVersionTests.swift — so this needs ⌘Q and a
reopen. `AppVersion` had no tests at all, which is why nothing objected.

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


S = "Sub4/SettingsView.swift"
H = "Sub4/DatabaseHealthView.swift"

# --------------------------------------------------------- the version rows

edit(
    S,
    r'''            LabeledContent("Source patch", value: "\(AppVersion.patch)")''',
    r'''            LabeledContent("Source patch", value: AppVersion.patchLabel)''',
    "the Settings row shows the letter",
)

edit(
    S,
    r'''        "App is Xcode's Version and Build. Source patch is bumped by every code "
        + "patch — if it reads lower than the patch you just installed, the "
        + "files did not reach the project folder. Built is read off the binary, "
        + "so nobody has to remember it."''',
    r'''        "App is Xcode's Version and Build. Source patch is bumped by every code "
        + "patch — if it reads lower than the patch you just installed, the "
        + "files did not reach the project folder. A trailing letter is a "
        + "fix-up on top of that patch, so 284a is 284 plus a correction. "
        + "Built is read off the binary, so nobody has to remember it."''',
    "the footer explains the letter",
)

# ------------------------------------------------- the provenance it stamps

edit(
    H,
    r'''        let version = "\(AppVersion.patch)"''',
    r'''        // `patchLabel` since 284: a snapshot taken under a fix-up should say
        // so. This string is the manifest's only record of what took it.
        let version = AppVersion.patchLabel''',
    "the snapshot manifest records the letter",
)

edit(
    H,
    r'''                    appVersion: "\(AppVersion.patch)",''',
    r'''                    appVersion: AppVersion.patchLabel,''',
    "the migration run records the letter",
)

edit(
    "Sub4/PlanFocus.swift",
    r'''        var lines = ["Sub4 plan volumes · patch \(AppVersion.patch)",''',
    r'''        var lines = ["Sub4 plan volumes · patch \(AppVersion.patchLabel)",''',
    "the volume export records the letter",
)

edit(
    "Sub4/NotesStore.swift",
    r'''        let name = "sub4-notes-\(Self.stamp.string(from: Date()))-p\(AppVersion.patch).csv"''',
    r'''        let name = "sub4-notes-\(Self.stamp.string(from: Date()))-p\(AppVersion.patchLabel).csv"''',
    "the notes CSV records the letter",
)

# -------------------------------------------------------------------- manual

edit(
    "Sub4/manual.html",
    r'''<td><code>AppVersion.patch</code>, a constant bumped by every code patch</td>''',
    r'''<td><code>AppVersion.patchLabel</code> — a constant bumped by every numbered patch, plus a letter for a fix-up on top of it</td>''',
    "the manual names the label",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.30 The fix-ups were invisible — patch 284

### 12.30.1 What went wrong, which is not what it looks like

283a was installed. The phone read **Source patch 283**.

Nothing was broken and no number was stale. The rule until now was that a
letter fix-up ships no `AppVersion.swift`, on the reasoning that a fix-up is
not a new patch and the number should not move. The reasoning is coherent and
the result is a screen that cannot answer the question it exists for: **is the
source on this device the source I think it is?** A device with 283a and a
device without it read identically.

That is the same false negative as a stale number — the case this file's own
header describes at length, from patches 39 through 44 — with one difference
that makes it worse: **a stale number looks stale.** This did not look like
anything.

### 12.30.2 Why `revision` is a second constant

`patch` is an `Int`, and it is compared. `>= 280` is a legitimate question
somewhere in this project's future and `"283a" >= "280"` is not the same
question. Folding a letter into it would change what every comparison means in
order to fix a display problem.

So the letter lives beside the number, `patchLabel` joins them, and everything
that prints a version reads the label. `AppVersionTests` walks all four printed
forms, because the way this returns is a fifth caller reading `patch`
directly.

### 12.30.3 The rule, in full

- a **numbered** patch ships `AppVersion.swift` with `patch` bumped and
  `revision` nil
- a **letter fix-up** ships `AppVersion.swift` with `patch` unchanged and
  `revision` set to its letter
- **every** patch of either kind ships the file, without exception

### 12.30.4 It stamps provenance, not just a screen

`AppVersion.patch` was written into four durable places: the snapshot
manifest, `migration_run.appVersion`, the plan-volume export and the notes CSV
filename. All four now carry the label.

That is the part worth the patch. A snapshot taken under 283a recorded itself
as taken under 283 — and a snapshot exists to be the thing you trust when
something has gone wrong, at which point "which source took this" stops being
cosmetic.

### 12.30.5 It had no tests, which is why nothing objected

`AppVersion` is the one value on the screen whose entire job is to say which
source is running, and nothing had ever asserted anything about it — not its
format, not that the display forms agree, not that a caller cannot drift.
`AppVersionTests` is the first coverage it has had, and the reason it exists
here rather than in a later cleanup is that this defect was invisible for
exactly as long as that was true.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.30",
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
