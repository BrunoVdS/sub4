#!/usr/bin/env python3
"""
Patch 297 — D6b groundwork, and the number it turns on.

One line of code. `Sub4Import.Report.seconds` has been computed from a
ContinuousClock around the write since the importer existed, and displayed
nowhere — so the measurement D6b's central choice depends on has been taken and
thrown away on every import for forty patches.

The rest is the groundwork document, written before any code the way
D6A-RECORDING-GROUNDWORK.md was, with the decision thresholds stated BEFORE the
measurement so the reading cannot be bent to fit a preference. §12.39.5 is the
working example — it was written to be falsifiable and §12.39.6 duly falsified
it.

The finding that changed the design: `Sub4Import.run` is ALREADY the
write-through. It takes every store's entire contents, upserts in one
transaction, and 294–296 proved it idempotent against the real corpus. D6b is
about triggering and failure, not about writing seventeen tables.

Files touched
  Sub4/DatabaseHealthView.swift          + the "Took" row
  docs/ADR-0003-database-contract.md     + §12.41
  Sub4/AppVersion.swift                  297

NEW FILE, copied by hand from the zip — no Xcode involvement, it is a document:
  docs/D6B-WRITE-THROUGH-GROUNDWORK.md

Run from ~/Documents/Developer/sub4/Sub4/docs
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


VIEW = "Sub4/DatabaseHealthView.swift"
ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

# ------------------------------------------------------------------ 1. the row

edit(
    VIEW,
    r'''                // REFUSALS ARE SHOWN, NOT COUNTED AND HIDDEN. A silent
                // rejection is indistinguishable from a row that was never
                // there — §12.2.
                LabeledContent("Refused") {''',
    r'''                // PATCH 297. Computed since the importer existed, from a
                // ContinuousClock around the write, and displayed nowhere —
                // so the one number D6b's design turns on has been taken and
                // thrown away on every run. §12.41.2.
                //
                // Three decimals because the interesting question is whether
                // this is under two seconds, and "1 s" cannot answer it.
                LabeledContent("Took",
                               value: String(format: "%.3f s", r.seconds))
                    .font(.caption).foregroundStyle(Color.dim)

                // REFUSALS ARE SHOWN, NOT COUNTED AND HIDDEN. A silent
                // rejection is indistinguishable from a row that was never
                // there — §12.2.
                LabeledContent("Refused") {''',
    "the import says how long it took",
)

# ------------------------------------------------------------------- 2. the ADR

edit(
    ADR,
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.41 D6b groundwork, and a number that was computed and thrown away — patch 297

The design work for write-through, done before the code, the way §12.38 was done
before §12.39. It lives in `docs/D6B-WRITE-THROUGH-GROUNDWORK.md`; this section
records the two findings that changed the shape of it.

### 12.41.1 The import is already the write-through

`Sub4Import.run` reads as a migration tool and is not one. Its call site hands
it **every store's entire contents** — activities, gear, notes, proposals, match
decisions, sync state, work items, rejections, commutes, weather, constants,
FTP, zones, plan, streams, details — and it writes them in one `db.queue.write`,
upserting rather than inserting, with a `migration_run` opened and closed around
it.

Its footer has always said *"Running it twice imports nothing twice"*, and as of
294–296 that is measured rather than claimed: 668 activities, 668 details, 645
recordings and 1,403,819 samples compared after a run, every disagreement named.

So D6b is **not** "write seventeen tables". It is "when does the thing that
already writes them run, and what happens when it fails" — a question about
triggering and failure, not about SQL.

That matters because the alternative has a measured cost. §12.35.2 found four
column renames in `activity` alone and a `gearId` that is not `activity.gearID`;
§12.38.2 found four more in `recording_sample`. Each was a chance to be wrong in
a way that looks like missing data, and each was caught because a comparison
existed and was run against the real corpus. Seventeen hand-written incremental
writers is seventeen fresh chances to take that risk, in code that runs
unattended and is checked by a button somebody presses when they remember.

### 12.41.2 `Report.seconds` has been computed and discarded for forty patches

`Sub4Import.Report.seconds` is set from a `ContinuousClock` measured around the
write. Nothing displays it. Nothing stores it — `migration_run` holds
`startedUTC` and `finishedUTC`, which gives second granularity for an operation
that may take one.

The whole of D6b's central choice turns on that number. Under two seconds and
the import can simply run after every sync; over ten and it needs a changed-set
before it can. The measurement has existed in memory on every import since the
importer was written, and has been thrown away every time.

This is a quieter cousin of §12.34 and §12.40.5. Those were prose that went
stale or was never true. This is a **measurement that was taken and not
surfaced** — which is harder to notice, because nothing is wrong on screen.
There is simply no row, and an absent row asks no questions.

Patch 297 adds it. One line of code, and it is the only code in the patch,
because the thresholds it will be read against are written down in the
groundwork **before** the reading — the same discipline as §12.39.5, which was
written to be falsifiable and duly got falsified in §12.39.6.

## 12.10 The athlete profile, the zones and the resting series''',
    "§12.41",
)

# --------------------------------------------------------------- 3. the version

edit(
    VER,
    r'''    static let patch = 296''',
    r'''    static let patch = 297''',
    "297",
)


# --------------------------------------------------------------------- machinery

def main():
    check = "--check" in sys.argv
    print(f"ROOT = {ROOT}")
    if not (ROOT / "Sub4.xcodeproj").exists():
        print("!! that is not the project root — expected Sub4.xcodeproj beside Sub4/")
        return 1

    failures = 0
    writes = {}
    for path, old, new, why in EDITS:
        if not path.exists():
            print(f"MISSING  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        text = writes.get(path, path.read_text(encoding="utf-8"))
        if new in text and old not in text:
            print(f"already  {path.relative_to(ROOT)}  ({why})")
            continue
        n = text.count(old)
        if n != 1:
            print(f"ANCHOR x{n}  {path.relative_to(ROOT)}  ({why})")
            failures += 1
            continue
        writes[path] = text.replace(old, new, 1)
        print(f"ok       {path.relative_to(ROOT)}  ({why})")

    doc = ROOT / "docs/D6B-WRITE-THROUGH-GROUNDWORK.md"
    print(f"{'ok      ' if doc.exists() else 'MISSING '} docs/D6B-WRITE-THROUGH-GROUNDWORK.md"
          f"  (copied from the zip, not written by this script)")
    if not doc.exists():
        print("   → cp sub4-297/docs/D6B-WRITE-THROUGH-GROUNDWORK.md "
              "~/Documents/Developer/sub4/Sub4/docs/")

    if failures:
        print(f"\n{failures} anchor(s) failed — nothing written.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. run the suite")
    print("  2. ⌘R, Settings → Database, press 'Import from the app's stores'")
    print("  3. read the 'Took' row — that number picks §4.3 of the groundwork")
    print("     under ~2 s  → fire the import after every sync")
    print("     2–10 s      → detached and coalesced")
    print("     over ~10 s  → it needs a changed-set first")
    return 0


if __name__ == "__main__":
    sys.exit(main())
