#!/usr/bin/env python3
"""
Patch 276a — the device said 2, not 23.

Patch 276 shipped with a sentence that is false: that the 23 activities with no
trace would all have read as failures. Two of them have a verdict. The other 21
were never asked, because `needsStreams` requires 500 m and a strength session
is 0 m.

Corrects the claim where it is written twice — the Swift header and the ADR —
and records the third state the table cannot hold.

No AppVersion bump: a fix-up inside 276, like 272a.

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


# ------------------------------------------------- the Swift header's claim

edit(
    "Sub4/Sub4Import+WorkQueue.swift",
    r'''//  Filing `noStreams` as `failed` would record a fault where the source simply
//  had no trace to give. On this device 668 activities carry a detail and 645
//  carry a trace, so 23 have none — indoor sessions and manual entries, and
//  every one of them would have read as a failure. `done` means the queue is
//  finished with the item, which is precisely true of both, and the
//  distinction between them survives in `state`.''',
    r'''//  Filing `noStreams` as `failed` would record a fault where the source simply
//  had no trace to give. `done` means the queue is finished with the item,
//  which is precisely true of both, and the distinction between them survives
//  in `state`.
//
//  THE FIRST RUN WROTE TWO ROWS, NOT TWENTY-THREE
//  ----------------------------------------------
//  668 activities carry a detail and 645 carry a trace, so 23 have none — and
//  this file's first version said all 23 would have read as failures. The
//  device said 2.
//
//  The other 21 were never asked. `needsStreams` requires
//  `a.distance >= minStreamDistance`, which is 500 m, and a strength session
//  is 0 m. So there is a THIRD state — not eligible, never attempted, never
//  will be — and `work_queue`'s four frozen states cannot express it: `done`
//  would claim work happened, `pending` would claim work is coming.
//
//  No row is the right answer, and the gap is real: 21 activities have no
//  trace and no verdict, and nothing anywhere says why. That belongs on the
//  health screen next to the count, not in this table.''',
    "the header's corrected claim",
)

# ------------------------------------------------------------------- the ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''On this device 668 activities carry a detail and 645 carry a trace, so **23
have none**. Filing those as failures would report a fault against twenty-three
indoor sessions and manual entries. `done` means the queue is finished with the
item, which is true of both, and the difference between them survives in
`state`.''',
    r'''Filing `noStreams` as a failure would report a fault where the source simply
had nothing to give. `done` means the queue is finished with the item, which is
true of both, and the difference between them survives in `state`.

*(This paragraph originally predicted 23 rows. See §12.23.7 — the device wrote
two.)*''',
    "the ADR's corrected claim",
)

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''### 12.23.7 The device said 2, and the difference is a third state — patch 276a

668 activities, 668 details, **645 traces**. Twenty-three have no trace, and
§12.23.2 said filing them as failures would report a fault against all
twenty-three. The first import wrote **two rows**.

**The other 21 were never asked.** `DetailStore.needsStreams` opens with
`a.distance >= minStreamDistance`, and `minStreamDistance` is 500 m. A strength
session is 0 m; so is a manually logged swim. Those activities are not in
`failed` and not in `noStreams` because nothing ever went and looked.

So there are three states and the table holds two:

| | in `work_queue` |
|---|---|
| asked, refused (404) | `detail` / `failed` |
| asked, nothing there | `stream` / `done` |
| **never asked — under 500 m** | **no row** |

`work_queue`'s states were frozen by migration 2 and cannot be added to. Of the
four, `done` would claim work happened and `pending` would claim work is
coming; neither is true. **No row is the honest answer** — but it leaves a gap
that is real and currently invisible: twenty-one activities have no trace, no
verdict, and nothing anywhere saying why.

That is a violation of the standard set on 5 August — *"every counter on the
health screen reads zero or has a decision beside it, so the next entry in any
of them is news."* `recording: 645` against `activity: 668` is a counter with
no decision beside it.

**And the number that would explain it has no caller.**
`DetailStore.backfillRemaining` is `pending.count`, written for a screen that
was never built. It is the second method found this week that compiled, was
correct, and did nothing — §12.8.4 recorded the first. Until something shows
it, "never asked" and "queued and not yet reached" are indistinguishable from
outside.

**The wider lesson, and it is the same one as §12.23.1.** That section already
records getting this patch's shape wrong by reading key names instead of the
store. The correction was written from `DetailStore` — and then a number was
predicted from arithmetic on two other counters rather than from the code that
produces it. Reading further would have found the 500 m line: it is nine lines
below the one that settled the earlier question.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.23.7",
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
