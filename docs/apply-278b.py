#!/usr/bin/env python3
"""
Patch 278b — a `#expect` message that was not a literal.

`#expect`'s second argument is `Comment?`, which is
`ExpressibleByStringInterpolation` — so an interpolated literal converts and a
`+` concatenation of two literals does not, because the result is a `String`.

The line is in `WorkQueueTests` and has been broken since 276. It surfaced only
now because ⌘R builds the app target and not the test target: 276 and 277 both
ran on the phone without the suite ever being compiled.

Numbered 278b for the session, not for the file it fixes.

No AppVersion bump.

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
    "Sub4CoreTests/WorkQueueTests.swift",
    r'''        #expect(Set(WorkState.allCases.map(\.rawValue))
                == Set(["pending", "running", "failed", "done"]),
                "WorkState drifted from what migration 2 froze: "
                + "\(WorkState.allCases.map(\.rawValue))")''',
    r'''        // ONE INTERPOLATED LITERAL, NOT TWO LITERALS ADDED TOGETHER.
        // `#expect`'s message is a `Comment?`, which is
        // `ExpressibleByStringInterpolation` — so this converts and `"a" + "b"`
        // does not, because a concatenation produces a `String` and a `String`
        // is not a literal. Worth a comment: the two read identically.
        let states = WorkState.allCases.map(\.rawValue)
        #expect(Set(states) == Set(["pending", "running", "failed", "done"]),
                "WorkState drifted from what migration 2 froze: \(states)")''',
    "the frozen-state message is a literal again",
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
