# D6c — shadow parity: groundwork

Written 7 August 2026 at patch 308, before any code. Everything below was read
out of the source; nothing here needs re-deriving. Same shape as
`D6A-RECORDING-GROUNDWORK.md` and `D6B-WRITE-THROUGH-GROUNDWORK.md` — and the
difference between those two is instructive. 294 landed clean the first time
because its groundwork had been checked against the source. 302 landed wrong
because §5.1 of its groundwork stated something from memory of a comment.

**This document was checked against the source.** Where it states a rule, the
rule was read.

---

## 1. What D6c is, in one sentence each

**D6a asked:** do both sides hold the same records? Answered — 672 activities,
672 details, 649 recordings, 1,412,819 samples, every disagreement explained.

**D6b asked:** does the database stay current on its own? Answered — every path
that writes a store now reaches the database.

**D6c asks:** *if the app computed its screens from the database instead of the
files, would it produce the same numbers?*

That is not the same question as D6a's, and the plan says why: **compare
semantics, not counts** — equal counts can hide changed values or swapped
identities (§12.16, and the ghost-review lesson from 274).

---

## 2. The uncomfortable conclusion, stated first

Follow D6a's result through and something falls out that changes what success
looks like.

D6a proved the two sides hold the **same 672 activities with every field
agreeing**. If both sides then pass through the **same** derivation rules, the
output is identical by construction — not by luck, and not by anything D6c
discovers.

So the first comparison will almost certainly report **zero differences**, and
that is the *expected* result rather than a disappointing one.

**D6c's value is therefore not finding data differences. D6a ruled those out.**
Its value is:

> Build the mechanism that feeds the app from the database, and prove it
> produces identical output — because that mechanism is what D7 switches onto,
> and the comparison is how anybody knows the switch is safe.

### 2.1 Which means the comparison must be able to fail

A check whose answer is always "0 differences" is indistinguishable from a check
that is broken, and D7 would be flipped on the strength of it.

`samplesWalked` exists for exactly this reason (§12.39.6.1): the recording
read-back reported 649 of 649 agreeing, and the number that made that readable
as a *result* rather than an *absence* was the 1,412,819 comparisons underneath
it.

**Every D6c diagnostic must carry, on screen:**

- a **denominator** — how many things were actually compared, not how many
  agreed
- a **negative control** — some way to see the comparison report a difference
  that is known to exist

**ANSWERED at 309: tests and denominators, no device switch.**

Three things can go wrong, and they need different answers.

**1. The comparison logic is broken** and calls everything equal.
→ A unit test that hands it two deliberately different lists, built from
genuinely different sources, and demands it reports them. Runs on every build.
This is the test button.

**2. It runs over nothing.** A read failed, came back empty, and comparing zero
against zero agrees perfectly.
→ Three counts on screen: how many the app held, how many the database held,
how many were compared. A dead read stops them matching.

**3. Both sides are secretly the same object** — the twin built from the store
by mistake, comparing the app to itself.
→ No runtime check catches this cleanly. It is caught by (1) constructing its
sides from different places, and by reading the code. Named so it is not
mistaken for covered.

**And one free continuous control:** the detail comparison has a permanent known
difference — the twelve zero-heart-rate details. If that ever reports **0**, the
comparison stopped looking. A number that must stay non-zero tests itself on
every run. It does nothing for slice 1, where nothing is expected to differ.

**Rejected: a debug toggle that perturbs the database on the device.** It would
be the strongest evidence, because it exercises the real path — and it is a
switch that can damage data and must never ship enabled. §12.46.3 declined
automatic deletion on blast-radius grounds and this is the same argument. (1)
and (2) together cover the realistic failures.

**A green tick that means nothing is worse than no tick.**


---

## 3. What `ActivityStore` actually does

The activity list is not the rows. Five rules stand between them, and **all five
are `private` to `ActivityStore`**.

### 3.1 `isKept` — four filters, applied at BOTH doors

Read from the source. Applied in `ingest` (the network) and in `load`
(activities.json), for the reason patch 123 records: a rule added after a row
was cached would otherwise never reach it.

| rule | value |
|---|---|
| `a.dayKey >= MatchRules.cutoffDayKey` | `"2025-07-01"` |
| `a.movingTime >= MatchRules.minAnyActivitySeconds` | `120` |
| `!DataCorrections.isIgnored(a)` | two named sessions |
| `!a.selfContradictoryDistance` | distance/time > maxSpeed × factor |

### 3.2 `dedup` — order-dependent, keeps the longer

    for a in input.sorted(by: { $0.startLocal < $1.startLocal }) {
        if let i = kept.firstIndex(where: { isDuplicate($0, a) }) {
            if a.movingTime > kept[i].movingTime { kept[i] = a }
        } else { kept.append(a) }
    }

`isDuplicate` is: same `sportType`, same `dayKey`, starts within
`duplicateWindowMinutes` (10), and distances within
`duplicateDistanceTolerance` (±15%) of the larger — or both zero.

**Ascending by `startLocal`, then keep-the-longer.** Both halves matter: a
different input order can produce a different survivor.

### 3.3 The sort — `startLocal`, not `startUTC`

    activities = dedup(...).sorted { $0.startLocal > $1.startLocal }

`ActivityRepository.all` orders by `startUTC DESC`. §4.1 says `startUTC` is
authoritative for ORDER and `startLocal` for BELONGING, and the repository is
right to use it — but the STORE does not, and the twin must match the store.

### 3.4 `byDay` and `dayZones` — derived in the `didSet`

    byDay = Dictionary(grouping: activities, by: \.dayKey)
    dayZones = DayZones.from(activities: activities)

`dayKey` is `String(startLocal.prefix(10))`. `Dictionary(grouping:)` preserves
encounter order, so each day's bucket inherits the newest-first order — which
patch 168's comment says explicitly, because callers depend on it.

Derived in the `didSet` rather than computed on read, and the comment says why:
*"derived state maintained beside the thing it derives from cannot go stale."*

### 3.5 Who reads the result

`Matcher` (via `activities(on:)`), `DetailStore` (four call sites),
`HealthStore` and `HealthCoverageView`, `AthleteStore`, `InfoNote`,
`AppStores`, `DatabaseHealthView`. `dayZones` is read by `HealthStore` and
`WeekView`.

Twelve call sites across eight files. That is the surface a twin has to satisfy,
and it is small enough to enumerate — which is the good news in this document.

---

## 4. The first patch is not a comparison

**All five rules are pure functions of `[Activity]`.** Nothing in them touches
the network, the disk or the clock.

So the twin does not need to reimplement them, and **must not**. §12.43 cost
three patches to learn that a second implementation of something that already
exists will eventually disagree with it — and there the disagreement was loud
(320 phantom differences). Here it would be **silent**: two plausible-looking
activity lists differing on one dedup survivor, with no test able to say which
is right.

> **Do not reimplement the store's rules. Extract them, and have both sides call
> the one copy.**

### 4.1 Shape

A value — working name `ActivityRoster` — that takes `[Activity]` and produces
what the store exposes: the filtered, deduped, sorted list; the day index; the
zones.

- `ActivityStore` uses it. **No behaviour change**, and the existing 828 tests
  are the proof, because every one of them that touches the store exercises it.
- The twin is the same `ActivityRoster` built from `ActivityRepository.all(db)`.
- The comparison is roster against roster.

The two **cannot** have drifted, because there is only one implementation to
drift. That is the same argument 301 makes about `AppStores` and the same
argument §12.41.1 makes about not hand-writing seventeen writers.

### 4.2 What it deliberately does not include

Not the sync, not the cursor, not `lastError`, not the rejection receipts. Those
are about *fetching*, and D6c is about *deriving*. A twin that reproduced the
network layer would be D7 arriving early and by accident.

---

## 5. The approved differences

Decided: **a written list, counted apart from unexplained ones.** The gate is
"zero unexplained", not "zero" — and the two known entries are:

| difference | why it exists |
|---|---|
| `laps[*].averageHR` and `splits[*].averageHR` on 12 details | the importer's `positiveOrNil` on a zero heart rate. Intended, §12.37.5. |
| 1 detail and 1 recording present in the store only | `DataCorrections` refuses two sessions; `DetailStore` keeps them because it keys by Strava id and never sees an `Activity`. §12.42.2. |

This is 298's distinction applied a level up: **absent on purpose is not
absent**, and a red row that is permanently correct is a row that stops being
read.

**The list is a decision record, not a suppression list.** Each entry needs the
reason and the patch that made it. An entry nobody can justify is a bug that has
been given a hiding place, and the moment the list grows without a reason
attached is the moment this stops being a gate.

---

## 6. Slice order

Decided: **activities — identity, order, day grouping — first.** Everything else
derives from it, and a difference in weekly distance that is really an activity
difference would be chased in the wrong place.

Proposed order after that, to be revisited once the first one exists:

1. **activities** — identity, order, day grouping, zones ← first
2. **daily and weekly distance** — visible, checkable by eye against the app
3. **CTL and the PMC** — §12.16 deferred it here on purpose: *one `PMC` over two
   readers, not two builders*, which is §4's rule stated a year early
4. details, splits, laps, traces
5. notes, corrections, plan matching
6. zones, weather, gear
7. review payloads
8. the Today / Week / Plan / Progress summaries

The plan's own list is twelve areas across D5–D7 through autumn. **This is a
rung measured in weeks.**

---

## 7. Where it runs

Open. The Database screen already carries three read-back rows, a verifier, a
survey, a benchmark, an import and a write-through, and it is long. Twelve
parity comparisons would not fit it, and a screen nobody scrolls to the bottom
of is a screen whose bottom rows are not read — §12.40.1 measured that once
already.

Candidates: a screen of its own reached from the Database screen; one row that
runs all of them and reports a roll-up with detail behind it; or per-slice rows
added to the Database screen only while each is being worked on and folded into
the roll-up after.

To decide when the first slice is built and there is something real to lay out.

---

## 8. What is still unknown

- **Where it runs** — §7.
- **Which negative control** — §2.1. The most important open question in this
  document, because it decides whether the whole rung's output can be believed.
- **Whether a twin can satisfy `Matcher`** without pulling the plan and the
  match decisions in with it. `Matcher.day()` calls `activities(on:)`, and
  matching is slice 5. Not investigated yet, and named here so it is not
  discovered halfway through slice 1.

Everything in §3, §4 and §5 was read out of the source and is settled.
