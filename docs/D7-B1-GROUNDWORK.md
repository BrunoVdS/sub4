# D7 slice B1 — the plan, the athlete and the constants

| | |
|---|---|
| **Written against** | patch 342, commit `9f7b7e1`, 10 August 2026 |
| **Decides** | how three stores stop reading files and start reading rows |
| **Depends on** | A3 §2.2 (settled), patch 342's `PersistenceMode` |
| **Status** | Groundwork. One decision is Bruno's and is marked. |

---

## 1. Why B1 first

It is the smallest slice that is a true test of the whole shape.

- Its repositories exist and pass: `PlanRepository` 298 comparisons,
  `PlanExtrasRepository` 71, `AthleteRepository` 27 — all at 0 unexplained on
  every device run since the wipe.
- **Nothing in it comes from Strava.** The plan is a bundled seed and the
  constants are authored, so B1 cannot fail for a source reason and any failure
  is a failure of the bootstrap shape itself.
- It touches no activity, no trace, no derived figure. If the bootstrap is
  wrong, B1 is where that is cheapest to discover.

---

## 2. The obstacle, and it is one word

The three stores are not the same shape.

| store | the state it holds | hydratable? |
|---|---|---|
| `ConstantsStore` | `private(set) var c = AthleteConstants()` | **yes** |
| `AthleteStore` | `private(set) var hrZones / ftp / shoes / bikes / retired` | **yes** |
| `PlanStore` | **`let plan: Plan`** | **no** |

`PlanStore` decodes the bundle in `private init()` and assigns a `let`. Its
header says why, and the reasoning was correct when it was written:

> *"Deliberately NOT @Observable: plan data never changes at runtime, so there
> is nothing to observe."*

D7 makes that false. The plan will come from a row rather than a resource, and
the row is written by an importer that runs after launch.

### 2.1 Three derived caches hang off that `let`

`init` builds `byDate` (sessions keyed by day), `weeksByUid`, and `focusCache`
is derived once at 239 for the same stated reason — *"the answer cannot change
and recomputing it per week would be 260 filters for a constant."*

**All three are derived from `plan` and none of them knows it.** Anything that
makes `plan` mutable without rebuilding all three produces a store whose index
describes a plan it no longer holds — a `byDate` for last week's sessions over
this week's plan. That is worse than either version alone, and no test would
see it, because each half is internally consistent.

### 2.2 And it has forty call sites

`PlanStore.shared` is touched in fifteen files — nine times in `ShadowParity`,
five in `FuelView`, four in `PlanView`, and in `TodayView`, `WeekView`,
`SettingsView`, `ProposalStore`, `TabSummary`, `WatchWorkout` and the rest.
Views call it freely and none of them passes it in.

---

## 3. Two ways, and the difference is what breaks

### Option A — `plan` becomes `var`, with one `hydrate`

```text
PlanStore.hydrate(from: PlanLoad)
  → assigns plan
  → rebuilds byDate
  → rebuilds weeksByUid
  → clears focusCache
```

Every call site is untouched. The singleton stays a singleton. The change is
about twenty lines.

**What it costs:** the store's stated invariant is gone, and the four things
that must move together are held together only by one function being correct.
That is exactly the shape §12.43 keeps finding — a rule with one caller looks
like part of that caller until something else must agree with it.

**The mitigation is a test, not care:** hydrate with a plan whose sessions fall
on different days, then assert `sessions(on:)`, `week(containing:)` and the
focus all describe the NEW plan. A test that only checked `plan` would pass
over a stale index.

### Option B — the bootstrap constructs the store

`static let shared` becomes `static private(set) var shared`, assigned once by
the bootstrap before `ContentView` exists. `PlanStore(plan:)` takes what it is
given and stays immutable per instance.

**What it costs:** a singleton that can be replaced is a singleton two things
can hold different copies of. `RootView` gates `ContentView` on
`launch.isFinished`, so the ordering works — but it works by where the
singleton is first touched, and "nothing reads it earlier" is a property
nothing enforces. `ShadowParity`, `ProposalStore` and `TabSummary` all reach
for `.shared` outside the view tree.

### Recommendation — Option A

The immutability is worth less than the ordering guarantee. Option B trades a
provable invariant (the store is always constructed) for an unprovable one
(nobody touches it early), and this project has been bitten by the second kind
twice — §12.57's `@State` results and §12.81's cache-derived counts were both
"true of the thing I am holding, false about the world".

Option A's hazard is real and it is testable. Option B's is real and is not.

**DECISION 1 for B1, and it is Bruno's:** Option A or Option B.

---

## 4. The bootstrap value

A3 §4. One `Sendable` value, assembled in one place, field count pinned by a
test the way `AppStores.fieldCount == 17` is today.

```text
DatabaseBootstrap
  plan:      PlanLoad
  extras:    PlanExtrasLoad
  athlete:   AthleteLoad
  fieldCount pinned
```

Three fields at B1, growing by slice. The argument is §12.45's, in the read
direction: `Sub4Import.run` took twenty parameters and a forgotten one was not
a compile error but a table that quietly stopped being imported. A forgotten
one here is a store that hydrates from nothing.

**It is assembled off the main actor and handed over**, exactly as
`ReadBacks` does — every repository `load` is already nonisolated and every
store is a main-actor singleton.

---

## 5. Where it runs

`Sub4Launch.begin()` already has the only correct moment: after the migration
succeeds, after `closeInterrupted`, after `persistence` is derived, and before
`state = .ready` lets `RootView` build `ContentView`.

```text
open → recover interrupted runs → derive persistence
     → IF shadow(B1) or databaseAuthoritative: assemble bootstrap, hydrate
     → state = .ready → RootView builds ContentView
```

Under `.legacyAuthoritative` nothing is assembled and nothing is hydrated —
the stores read their files exactly as today. That is what makes the slice
reversible by one constant.

---

## 6. The bundled plan is a seed and never a fallback

The plan document says this and it is the sharpest hazard in B1.

If `PlanRepository.load` returns `.failed`, the store must NOT fall back to
`Bundle.main/plan.json`. It looks harmless — the same file the importer seeded
from — and it is not: **the database may hold a different plan version from
the bundle**, and notes, match decisions and review changes are all written
against `plan_session.uid` values from the stored version. A silent fall back
to the bundle would resolve those uids against a plan nobody chose.

Under `.legacyAuthoritative` the bundle is the source and that is correct.
Under `shadow(B1)` or `databaseAuthoritative`, a failed plan read is a failed
launch, not a bundle read.

---

## 7. What proves it

**Automated.**

- Hydrating rebuilds all four things — `plan`, `byDate`, `weeksByUid`,
  `focusCache` — asserted with a plan whose sessions fall on different days.
- `DatabaseBootstrap.fieldCount` pinned.
- Under `.legacyAuthoritative` the bootstrap is never assembled.
- A `.failed` plan load does not produce a bundle read. **The negative control
  for §6**, and the one that matters most.
- `sliceUnderTest == "B1 plan and athlete"`.

**On the device.** The comparison is already built: Plan read-back **298
compared, 0 unexplained** and Plan extras **71 compared, 0 unexplained** are
what B1 must still report, and every figure on the Plan, Week and Today screens
must be unchanged — 223 days, ≈1261 km, 1223 run, peak week 32 at 54, week 3 of
34, 23 km planned.

**The negative control on the device:** with `sliceUnderTest` set, the plan is
hydrated from rows. Delete nothing and change nothing else; if any of those
figures moves, the repository and the bundle disagree and that is the finding.

---

## 8. What B1 also fixes

`PersistenceMode` has no line in the diagnostics paste. At 342 that was
acceptable — nothing consumed the value, and it is provable by construction.
From B1 it decides what three stores read, and a value that decides that must
be readable off the device. One unconditional line, naming the state and the
slice.

---

## 9. What B1 is not

No activity, detail, trace, weather, gear, note, commute, review or sync
change. No `RootView` change — the recovery screen is B9. No flag flip.

If B1 lands and the Plan tab is identical, the slice succeeded. That is the
same acceptance criterion B0 had, and it is the right one for every slice up
to B9.
