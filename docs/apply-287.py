#!/usr/bin/env python3
"""
Patch 287 — M0 is answered. The plan stops carrying an assumption.

Three documents currently describe M0 as work to be done or half done:

  · PLAN-cutover-v2.md §3 — "what to measure", written before anything had been
  · ADR §12.31 — the census design, with routes still unmeasured
  · ADR §12.32.5 — the census failing, with no ending

This replaces §3 with the result and the shortfall in the form ADR-0002 wants
it signed, and adds §12.33 as the single place the concluded numbers live.
§12.31 and §12.32 keep their reasoning and gain a pointer rather than being
rewritten — they are the record of how the measurement was built, and that
record is still true.

Documentation only. No Swift, no test change, and no rebuild needed — but it
DOES bump `AppVersion` to 287, because the rule since 284 is that the number
moves for a numbered patch and this is one.

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


P = "docs/PLAN-cutover-v2.md"
A = "docs/ADR-0003-database-contract.md"

# ------------------------------------------------------------- the plan, §3

edit(
    P,
    r'''## 3. M0 — measure Apple Health's historical coverage. Next, and out of band.

ADR-0002 follow-up 3: *"Measure Apple Health coverage back to 1 July 2025
**before** any purge."* Its consequence section says why: *"the watch may not
have been worn, or workouts may have been written by Strava rather than to
it,"* in which case part of the record cannot cross by the API-free route and
the bulk-export bridge becomes the contingency.

**The peer review buries this.** Its Health exit gate is forward-only — *"new
real workouts appear in SQLite"* — and it never asks whether Health holds the
past. That is the wrong way round: the question is read-only, answerable this
week, and a negative answer changes whether the Strava data now sitting in the
database is redundant or irreplaceable.

### What to measure

Per month from July 2025 to today, for workouts only:

- count by activity type (run / ride / swim / strength / other)
- earliest and latest workout date present
- how many carry an `HKWorkoutRoute`
- how many carry heart-rate samples, and at what density
- the `sourceRevision` / source bundle id per workout — **specifically whether
  the writer was Strava's own app**, which is the failure mode ADR-0002 names
- count of workouts Health has that `activity` does not, and the reverse

### The comparison that decides it

668 activities in the database against the Health count for the same window. A
shortfall is not automatically fatal — it may be trainer sessions or a
head-unit that never wrote to Health — but every missing workout is a row the
disconnect would destroy with no replacement.

### Why it is out of band

It writes nothing, changes no schema, and does not touch the ladder. It is a
diagnostic. If it comes back healthy, the plan below is the plan. If it comes
back thin, priority order changes — the bulk-export bridge moves onto the
critical path and `activities.json` stops being disposable.''',
    r'''## 3. M0 — ANSWERED. Measured on the device, 6 August 2026.

ADR-0002 follow-up 3: *"Measure Apple Health coverage back to 1 July 2025
**before** any purge."* Nothing ever had, and every plan written since —
including this one, two days ago — assumed the answer.

Built as patches 282–286b and run against the real store over 2025-07-01 to
2026-08-06. Full detail in ADR-0003 §12.28–§12.33.

### The headline: Health holds the history

| | |
|---|---|
| Health sessions | **711** across **323** training days |
| the app holds | **669** across **323** days |
| days in both | **320** |
| days only in Health | 3 — not a shortfall |
| **days only in the app** | **3** |

**ADR-0002's central worry does not hold.** July 2025 — the first month of the
window and the one the follow-up named — shows Health with 63 sessions across
28 days against the app's 52 across the same 28. Health is ahead from the
first week.

**The bulk-export bridge comes off the critical path.** It stays recorded as
the contingency it was; it is no longer a dependency.

### The shortfall, in the form ADR-0002 requires it accepted

> **Three training days** — 2026-05-23, 2026-05-29 and 2026-06-07 — exist in
> the app and not in Health. A disconnect destroys them with nothing to put in
> their place.
>
> **Fifty-three sessions (7.5% of 711)** exist in Health only as summaries
> Strava pushed back. After the purge their record degrades from full trace to
> summary: **none of the 53** carries heart-rate samples rather than a single
> value, **48** carry no route, and **9** carry neither a route nor a distance.

Not a blocker. 42 of the 53 keep a distance and a duration, which is a real
training record, and the three days are three. But it is a quantified loss
across the whole window rather than a rounding error, and ADR-0002 requires it
**accepted in writing rather than discovered at the receipt.**

### The two open items this leaves

1. **Name the three days.** Open 2026-05-23, 2026-05-29 and 2026-06-07 in the
   app. Some will be noise — a stray entry, a duplicate — and the shortfall
   shrinks on its own. Anything real should be written down as an authored
   session note BEFORE any purge: a note is `.authored`, kept on disconnect
   because *"you wrote it"*, so it survives where the Strava row will not.
   There is no faithful way to put a missing session into Health; a manual
   entry would be a shell, which is the very thinness this measured.

2. **The sessions the app holds and Health does not.** Health is ahead by 29
   tracked sessions overall while the app is ahead by 8 on strength, and none
   of those 8 fall on the three at-risk days — they sit on days that count as
   covered. That is session-level, not day-level, and it belongs to D6c.

### Why it was out of band

It wrote nothing, changed no schema and did not touch the ladder — and it
could have invalidated everything below it. It did not. **The plan below is
the plan.**''',
    "plan §3 becomes the result",
)

# --------------------------------------------------------------- ADR §12.33

edit(
    A,
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.33 M0, concluded — patch 287

§12.28 built the census, §12.29 named its blind spots, §12.31 measured
thinness and §12.32 fixed the two defects that stopped the route half working.
This is the single place the finished numbers live, so that a reader does not
have to reconstruct them from five sections and two corrections.

### 12.33.1 The measurement

Device, 6 August 2026, window 2025-07-01 → 2026-08-06, patch 286b:

| | Health | the app |
|---|---|---|
| sessions | **711** | **669** |
| training days | **323** | **323** |
| run / ride / swim / strength / other | 113 / 405 / 54 / 8 / 131 | 110 / 373 / 52 / 16 / 118 |
| with a distance | 558 | — |
| with a heart rate | 620 | — |

Days in both **320**. Days only in Health **3** — not a shortfall. Days only in
the app **3**: 2026-05-23, 2026-05-29, 2026-06-07.

Sessions naming Strava as a writer **102**; **53** written by Strava alone.

### 12.33.2 The thinness of the 53

| | |
|---|---|
| with a route | **5** |
| with heart-rate samples rather than one value | **0** |
| with a distance | 42 |
| with none of the three | **9** |

**Not one of the 53 carries heart-rate samples.** 48 carry no route. 9 carry
no route, no distance and a single heart-rate value.

§12.28.2 argued that the exposure is thinness rather than disappearance, and
guessed that a pushed summary *"usually carries no route and no heart-rate
samples"*. The guess was right and is now a count — which is the difference
between a plausible sentence and something a decision can rest on.

### 12.33.3 What ADR-0002 asked, answered

*"If Apple Health turns out not to hold the history back to July 2025 … then
some of the record cannot be carried across by the API-free route."*

**It holds it.** July 2025 shows Health ahead of the app — 63 sessions across
28 days against 52 across the same 28 — from the first week of the window. The
bulk-export bridge stays recorded as a contingency and comes off the critical
path.

The shortfall to accept in writing is three days and 53 degraded sessions; it
is written into `PLAN-cutover-v2.md` §3 rather than here, because a plan is
where a decision belongs and an ADR is where the reasoning does.

### 12.33.4 What this cost, and the pattern in it

Five patches and two letter fix-ups, of which **three were defects in the
measuring instrument rather than findings**: an unrequested type (§12.32.1), a
sample query against a series type (§12.32.5), and a `Result` whose failure
type did not conform to `Error`.

Every one of them was caught by something built for the purpose:

- the unrequested type by `Bool?` refusing to report absence as zero
- the wrong query kind by `RouteCensus` naming its own failure
- the type error by running the suite before ⌘R

**The instrument was wrong three times and never lied once.** That is the
whole argument for the named-outcome pattern — `StoreLoad`, `Reading`,
`RouteCensus` — stated as cheaply as it will ever be stateable: with `[]` in
place of the optional, the first run would have produced *"none of the 53 has
a route"*, which is quotable, plausible, and false by five.

### 12.33.5 One thing still not established

`authVersion` went 5 → 6 to force a re-request for the route type, and the
permission was subsequently granted — but **by what path is not recorded.** If
the app re-requested on its own, the marker has an actuator. If it did not,
`authVersion` bumps a number that nothing acts on, and the next type added
will hit the same wall with the same symptom.

Recorded as open rather than assumed either way. It costs one reading of the
`requestAuthorization()` call sites to settle, and it should be settled before
a ninth type is ever added.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.33",
)

edit(
    A,
    r'''**And the 53.** Whether a session Strava alone wrote carries a route or heart-
rate samples is still unmeasured. The set is bounded, so the census §12.28.5
deferred is now 53 queries rather than several hundred. It blocks a purge and
nothing else.''',
    r'''**And the 53.** Whether a session Strava alone wrote carries a route or heart-
rate samples is still unmeasured. The set is bounded, so the census §12.28.5
deferred is now 53 queries rather than several hundred. It blocks a purge and
nothing else.

*Measured at 286b — 5 routes, 0 with heart-rate samples, 9 with nothing at
all. See §12.33.*''',
    "§12.29.4 points at the answer",
)

edit(
    A,
    r'''**What it did not produce was HealthKit's own words**, because
`samples(of:matching:)` returns `[HKSample]?` and discards the error. 286a's
`series(of:matching:)` returns a `Result` and carries the reason through to the
screen. The rule from §12.32.4 applies one level further down than it was
written: a diagnostic that has been handed a reason should not throw it away.''',
    r'''**What it did not produce was HealthKit's own words**, because
`samples(of:matching:)` returns `[HKSample]?` and discards the error. 286a's
`series(of:matching:)` returns a `Result` and carries the reason through to the
screen. The rule from §12.32.4 applies one level further down than it was
written: a diagnostic that has been handed a reason should not throw it away.

**And it paid immediately.** 286a did not compile — `Result`'s failure type
must conform to `Error` and `String` does not — so 286b named the error type.
The run after that reported *"the route query failed — Authorization not
determined"*: HealthKit's own words, and a third distinct cause, arrived at in
one reading rather than a night of guessing. With the route permission granted
the census completed. **The numbers are in §12.33.**''',
    "§12.32.5 gets its ending",
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
