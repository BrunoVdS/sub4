#!/usr/bin/env python3
"""
Patch 293 — the handoff caught up.

§5 said `ActivityRepository` was the next patch. It landed at 289, was proven
against 668 real activities at 290, and two more readers followed. A handoff
that describes work already done is worse than a stale one — it reads as
current.

Documentation only. Bumps `AppVersion` to 293 because the rule since 284 is
that a numbered patch moves the number.

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


H = "docs/HANDOFF-2026-08-06.md"

edit(
    H,
    r'''# Sub4 handoff — 6 August 2026, patch 288''',
    r'''# Sub4 handoff — 6 August 2026, patch 293''',
    "the title says where it is",
)

edit(
    H,
    r'''Supersedes `HANDOFF-2026-08-05-late.md` (patch 271). **733 tests in 71 suites,
green.** Working tree clean at 288 once committed.''',
    r'''Supersedes `HANDOFF-2026-08-05-late.md` (patch 271). **772 tests in 74 suites,
green.** Working tree clean at 293.

Amended at 293: §1, §5 and §8 were written at 288 and D6a finished after them.''',
    "the header says what changed",
)

edit(
    H,
    r'''| D6a repositories | **Next** |''',
    r'''| D6a repositories | **Done** — three readers, 289–292a |''',
    "D6a is done",
)

edit(
    H,
    r'''## 5. What the next patch should be

**D6a — `ActivityRepository`, read-only.**

Read-only because D6c shadow parity needs reads and D6b owns writes. Its error
outcome is the spine: a repository returning `[]` on a database failure is the
exact defect this project has now caught four times (§7). It needs the same
shape as `StoreLoad` / `Reading` / `RouteCensus`.

Everything else waits on it.''',
    r'''## 5. What the next patch should be

**The recording round trip, and its read-back row.**

D6a is otherwise done. Three readers landed after this handoff was written:

| patch | what | proven |
|---|---|---|
| 289 / 289a | `ActivityRepository` | 290 — **668 compared, 668 agreed** |
| 291 / 291a | `ActivityDetailRepository` | **668 compared, 655 agreed**, residue explained |
| 292 / 292a | `RecordingRepository` | comparison not yet written — **this is the next patch** |

The design is settled in `D6A-RECORDING-GROUNDWORK.md` §4 and does not need
re-deriving: walk every sample rather than checksumming, gate each recording on
the stored `sampleCount` so one missing sample does not report as thousands of
index differences, and name fields by stream and band —
`heartRate[3 of 1204]` — rather than by index, because `distanceM[47_812]`
names nothing anybody can act on.

**Then D6b write-through**, and the case for it is now a measured number rather
than an argument: the activity read-back reports four activities in the store
and not in the database, which is how stale the last import has become in two
days. It grows daily until D6b lands.

### What the detail read-back found, worth knowing before the next one

Two things, one of them a defect in the comparison rather than the reader:

- **`fetched`, 320 of 668** — `ISO8601DateFormatter` truncates and `sameSecond`
  rounded. 47.9%, which is how many timestamps carry a fraction of 0.5 or more.
  The proportion WAS the diagnosis. Fixed in 291a.
- **`laps[*].averageHR`, ~12 details** — the importer's `positiveOrNil`
  normalisation. Intended, reported, left alone.

Expect the recording comparison to surface its own equivalent: a stream shorter
than `distanceM` comes back padded with zeros and its original length is gone
(§12.38.4). That is a real loss, `aShortStreamIsPadded` already pins it, and it
should be recorded as a measurement rather than smoothed away.''',
    "§5 says what is actually next",
)

edit(
    H,
    r'''- **`authVersion` has one actuator and it is a person** — the Settings banner.
  Nothing re-requests automatically. Fine for a diagnostic; for a type the app
  depends on it is HK-02's shape, and §12.32.3's before-the-query guard is what
  catches it.''',
    r'''- **`authVersion` has one actuator and it is a person** — the Settings banner.
  Nothing re-requests automatically. Fine for a diagnostic; for a type the app
  depends on it is HK-02's shape, and §12.32.3's before-the-query guard is what
  catches it. Settled at 288; the banner's text is computed from
  `typesReadDescribed` now and cannot go stale again.
- **`Result` needs an `Error`, and I got that wrong twice** — 286a and 292a,
  six patches apart, both `Result<_, String>`. `HealthStore.HealthQueryError`
  and `RepositoryError` are the two named types that exist because of it.
  Reach for one rather than a third.''',
    "the two settled items",
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
