#!/usr/bin/env python3
"""
Patch 308 — D6c groundwork.

Documentation only. No Swift beyond the version constant.

The design work for shadow parity, done before the code, in
docs/D6C-SHADOW-PARITY-GROUNDWORK.md. Two findings shaped it:

  1. THE FIRST COMPARISON IS EXPECTED TO FIND NOTHING. D6a proved both sides
     hold the same 672 activities with every field agreeing, and
     ActivityStore's five derivation rules are pure functions of [Activity].
     Same input, same function, same output — so a shared implementation makes
     the first parity check report zero BY CONSTRUCTION.

     That is not a reason to skip it. It is a reason to be honest about what it
     is for: D6c builds the mechanism D7 switches onto, and the comparison is
     how anybody knows the switch is safe.

  2. SO THE COMPARISON MUST BE ABLE TO FAIL. A check whose answer is always
     "0 differences" is indistinguishable from a broken one, and D7 gets
     flipped on the strength of it. Every diagnostic carries a denominator —
     §12.39.6.1's samplesWalked — and a NEGATIVE CONTROL, which is the harder
     half and is named as the rung's most important open question.

  3. And the first patch is not a comparison. The five rules are private to
     ActivityStore; a twin that reimplemented them would be §12.43's mistake
     with a silent failure instead of a loud one — `dedup` sorts ascending by
     startLocal and keeps whichever near-duplicate has more moving time, so a
     wrong sort direction produces a DIFFERENT SURVIVOR from the same input.
     Extract the rules, have both sides call the one copy.

Decisions taken with Bruno before writing: a parallel store compared rather
than calculations alone; activities/identity/order/day-grouping as the first
slice; and known differences listed as approved and counted apart.

Files touched
  docs/ADR-0003-database-contract.md   + §12.52
  Sub4/AppVersion.swift                308

NEW DOC, copied by hand from the zip — it is a document, no Xcode involvement:
  docs/D6C-SHADOW-PARITY-GROUNDWORK.md

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


ADR = "docs/ADR-0003-database-contract.md"
VER = "Sub4/AppVersion.swift"

edit(ADR,
     "## 12.10 The athlete profile, the zones and the resting series",
     r'''## 12.52 D6c groundwork, and a conclusion that changes what success looks like — patch 308

Documentation only. The design work for shadow parity, done before the code, and
it lives in `docs/D6C-SHADOW-PARITY-GROUNDWORK.md`. This section records the two
findings that shaped it.

### 12.52.1 The first comparison is expected to find nothing

D6a proved the two sides hold the same 672 activities with every field agreeing.
`ActivityStore`'s five derivation rules — `isKept`, `dedup`, the `startLocal`
sort, the day index, the zones — are **pure functions of `[Activity]`**.

Same input, same function, same output. So if both sides pass through the same
rules, the first parity comparison reports zero differences **by construction**,
and finds nothing because there is nothing left to find.

That is not a reason to skip it. It is a reason to be honest about what it is
for:

> D6c's value is not finding data differences — D6a ruled those out. It is
> building the mechanism that feeds the app from the database and proving it
> produces identical output, because that mechanism is what D7 switches onto.

Recorded because the alternative is running the rung, seeing green, and reading
it as evidence of something it never tested.

### 12.52.2 So the comparison has to be able to fail

A check whose answer is always "0 differences" is indistinguishable from a check
that is broken, and D7 gets flipped on the strength of it.

This project has the instrument already and it was built for exactly this
reason. The recording read-back reports 649 of 649 agreeing, and what makes that
readable as a **result** rather than an **absence** is the 1,412,819 comparisons
underneath it — §12.39.6.1.

So every D6c diagnostic carries a denominator, and — the harder half — a
**negative control**: some way to see the comparison report a difference known
to exist. Which control is open (groundwork §2.1) and is named there as the most
important unanswered question in the rung.

### 12.52.3 Extract the rules; do not reimplement them

The five rules are `private` to `ActivityStore`. A twin that reimplemented them
would be §12.43's mistake again — a second implementation of something that
already exists, which will eventually disagree with it.

There the disagreement was loud: 320 phantom `fetched` differences, visible on
the first run. **Here it would be silent** — two plausible activity lists
differing on one dedup survivor, with nothing able to say which is right.

`dedup` is the sharp edge. It sorts ascending by `startLocal`, then keeps
whichever of a near-duplicate pair has more moving time. Both halves are
order-dependent, so a reimplementation that got the sort direction wrong would
produce a *different survivor* from the same input — one activity, quietly
different, in a list of 672.

So the first patch of the rung is not a comparison at all. It extracts the rules
into one value both sides call, `ActivityStore` adopts it with no behaviour
change, and the existing 828 tests are the proof. Same move as 301, and for the
same reason: **before you can compare two things, one of them has to exist in a
comparable form.**

''' + "## 12.10 The athlete profile, the zones and the resting series",
     "\u00a712.52")

edit(VER, "    static let patch = 307", "    static let patch = 308", "308")


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

    doc = ROOT / "docs/D6C-SHADOW-PARITY-GROUNDWORK.md"
    print(f"{'ok      ' if doc.exists() else 'MISSING '} docs/D6C-SHADOW-PARITY-GROUNDWORK.md"
          f"  (copied from the zip, not written by this script)")
    if not doc.exists():
        failures += 1
        print("   → cp sub4-308/docs/D6C-SHADOW-PARITY-GROUNDWORK.md "
              "~/Documents/Developer/sub4/Sub4/docs/")

    if failures:
        print(f"\n{failures} item(s) failed — nothing written.")
        return 1
    if check:
        print("\n--check: nothing written.")
        return 0
    for path, text in writes.items():
        path.write_text(text, encoding="utf-8")
    print(f"\n{len(writes)} file(s) written.")
    print("\nNEXT")
    print("  1. run the suite — 828 in 82, nothing here touches Swift")
    print("  2. read docs/D6C-SHADOW-PARITY-GROUNDWORK.md, §2 first")
    print("  3. \u00a72.1's negative control is the open question. Nothing should")
    print("     be built until there is an answer, because it decides whether")
    print("     the whole rung's output can be believed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
