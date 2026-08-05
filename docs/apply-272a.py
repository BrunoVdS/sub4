#!/usr/bin/env python3
"""
Patch 272a — a gap with no reference is a complaint.

`gapsAreActionable` (DataLifecycleTests) requires every recorded gap to cite
the step or the finding that closes it. The second gap patch 272 added cites
neither: it names a patch number, which is where the change happened, not where
the decision is written down. The test is right and the text was wrong.

The reasoning lives in ADR-0003 §12.19.3, so the gap now says so.

No AppVersion bump — this is a fix-up inside 272, like 263a and 267a. The
script's own output is the receipt that it landed.

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


edit(
    "Sub4/DataLifecycle.swift",
    r'''                   "Decisions made before patch 272 carry the date of the "
                 + "migration rather than the date they were made — the old "
                 + "shape stored no timestamp and nothing else in the app "
                 + "remembers. `dateIsKnown` records which are which."],''',
    r'''                   "Decisions made before patch 272 carry the date of the "
                 + "migration rather than the date they were made — the old "
                 + "shape stored no timestamp and nothing else in the app "
                 + "remembers. `dateIsKnown` records which are which, and "
                 + "ADR-0003 §12.19.3 records why a plausible date was not "
                 + "invented instead. Closed by nothing: it is a permanent "
                 + "fact about a handful of rows, disclosed rather than "
                 + "fixed."],''',
    "the gap cites its finding",
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
