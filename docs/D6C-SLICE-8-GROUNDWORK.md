# D6c slice 8 — the tab summaries: groundwork

Written 8 August 2026, after patch 328a, before any slice-8 code. Same shape as
`D6A-RECORDING-GROUNDWORK.md`, `D6B-WRITE-THROUGH-GROUNDWORK.md` and
`D6C-SHADOW-PARITY-GROUNDWORK.md` — and the difference between the last two is
the reason this exists. 294 landed clean the first time because its groundwork
had been checked against the source. 302 landed wrong because §5.1 of its
groundwork stated something from memory of a comment.

**Everything below was read out of the source in the session that wrote it.**
Line numbers are as of patch 328a and will drift; the claims will not.

Decisions already taken, 8 August: **both halves of every summary** (planned
and actual), and the read-back roll-up is a **separate patch**, not folded in.

---

## 1. What slice 8 is

The last slice of D6c's original eight. It asks: *would the Today / Week / Plan
/ Progress tabs print the same numbers if the app computed them from the
database?*

Slices 1–7 proved the **inputs**. This proves the **compositions** built on
them, which is the layer the athlete actually reads.

### 1.1 What is already covered, and must not be re-proved

| figure | covered by | patch |
|---|---|---|
| the activity list, order, day grouping | `ActivityParity` | 312 |
| daily and weekly distance, history bands | `VolumeParity` | 313 |
| CTL / ATL / TSB, the HR histogram, sRPE | `LoadParity` | 314–316 |
| details, splits, laps, reps | `DetailParity` | 320 |
| the matcher's per-day resolution, adherence | `MatchParity` | 321 |
| the plan — 260 sessions, 37 weeks, field for field | `PlanRoundTrip` | 323 |

**The Today tab is almost entirely already covered.** Its cards are
`matcher.day(key)` (slice 5) and the load card (slice 3). It needs no new
comparison and slice 8 should say so on the screen rather than silently
omitting it — §12.54.2's shape applied to a whole tab.

### 1.2 What is NOT covered — the actual subject of slice 8

- **`ProgressTabView.points`** — the `WeekPoint` series behind the chart:
  `plannedKm`, `plannedExact`, `actualKm`, `longestRunKm`, `done`, `total`.
  `longestRunKm` is computed nowhere else in the app.
- **`ProgressTabView.volumeRows`** — the four Run / Bike / Swim / Strength rows,
  each carrying `done`, `dueSoFar`, `total`.
- **The block totals** — `Sessions 10/208` on the Progress card.
- **`WeekView.totals`** — `runKm`, `minutes`, `recorded`. Its `done`/`total`
  half is `SessionTally` since 328 and is therefore a function of slice 5's
  output; the distance and minute walk is not, and counts EXTRAS as well as
  matched activities, which no other comparison does.

---

## 2. The extraction, which is most of the work

Same shape as `ActivityRoster` (310) and `MatchResolver` (321): the derivations
live inside `View` structs and read singletons, so a twin cannot call them with
alternative inputs. They must take their inputs explicitly, and **both sides
must call the one copy** — §12.43, which this project has now applied eleven
times and been bitten by at 328 for miscounting the sites.

### 2.1 The planned side is already pure — this is the good news

Read out of `PlanStore.swift`:

```
line 159   func plannedRunKm(week: Week) -> PlannedDistance
             → sessions(inWeek:).filter { $0.discipline == .run }
               then Self.plannedRunKm(s) per session
line 171   func sessions(inWeek week: Week) -> [Session]
             → plan.sessions.filter { $0.weekUid == week.uid }
line 211   func plannedVolume(throughDay day: String? = nil) -> PlanVolume
             → walks plan.sessions; skips logged weeks via weeksByUid,
               undated sessions, and Self.isOptional(s); calls accumulate
line 228   func accumulate(_ s: Session, into v: inout PlanVolume)
             → already non-private; body calls only static members
line 384   static func plannedRunKm(_ session: Session) -> PlannedDistance
```

**Every one of them is a pure function of `plan.sessions` and `weeksByUid`.**
Nothing touches the network, the disk or the clock. So the extraction is
"take the sessions and the weeks as parameters", not surgery.

The minimal shape, preserving every existing caller:

```swift
static func plannedVolume(sessions: [Session],
                          weeksByUid: [String: Week],
                          throughDay day: String? = nil) -> PlanVolume
static func plannedRunKm(sessions: [Session], inWeek week: Week) -> PlannedDistance
static func sessions(_ all: [Session], inWeek week: Week) -> [Session]
```

with the instance methods becoming one-line wrappers that pass `plan.sessions`
and `weeksByUid`.

**`accumulate` must become `static`.** Its body already calls only
`Self.plannedRunKm`, `Self.plannedHours` and `Self.plannedMetres`. **This
breaks one call site**: `PlanFocus.swift:224` and `:188`, which call it as an
instance method from an extension on `PlanStore` — they become
`Self.accumulate`. That is the whole blast radius, and it was checked by grep
rather than assumed. Nothing in `Sub4CoreTests/` calls `accumulate`.

### 2.2 The actual side needs no plan at all

`ProgressTabView.actualVolume` (line 378) walks `activities.activities` and
switches on discipline. `points`' `actualKm` and `longestRunKm` walk
`r.matches.compactMap(\.activity) + r.extras` filtered to `.run`.

Both are pure functions of `[Activity]` and `MatchResolver.Day`, and **both
sides of both already exist**: the roster from `ActivityRoster.settle` (slice
1) and the days from `MatchResolver.day(sessions:activities:decisions:dayKey:)`
(slice 5). `ShadowParity` already builds the database side of both to run
slices 1–5, so slice 8 adds no new database read.

### 2.3 Proposed shape

A `TabSummary` — `@MainActor`, like `MatchResolver` and `SessionTally`, because
`Match` and `Activity` are main-actor isolated.

```swift
@MainActor
enum TabSummary {
    struct WeekPoint: Equatable { … }          // the six figures above
    static func weekPoints(weeks: [Week], sessions: [Session],
                           days: [String: MatchResolver.Day],
                           todayKey: String) -> [WeekPoint]
    static func actualVolume(_ activities: [Activity]) -> PlanStore.PlanVolume
    static func weekActuals(_ day: MatchResolver.Day) -> (runKm: Double, minutes: Int, recorded: Int)
}
```

`ProgressTabView` and `WeekView` call it. The twin calls it with database-built
inputs. One implementation, two callers — and the existing suite is the proof
of no behaviour change, because every test touching those tabs exercises it.

---

## 3. The comparison, and what it can and cannot prove

### 3.1 The planned half is identical BY CONSTRUCTION

Slice 6b proved all 260 sessions and 37 weeks round-trip field for field, zero
differences, on the device. `plannedVolume` and `plannedRunKm` are pure
functions of those sessions. **Therefore the planned half cannot differ**, and
a report saying so is reporting the mechanism, not the data.

That is not a reason to omit it — groundwork §2 already settled that the first
run of every slice is expected to report zero, and the value is the mechanism
D7 switches onto. It IS a reason to say so on the screen, so a future reader
does not mistake a structural certainty for an empirical finding. Same
distinction the approved-difference list draws.

### 3.2 The negative control

Groundwork §2.1: a check whose answer is always "0 differences" cannot be told
from a check that is broken. Slice 8's controls:

1. **Tests that hand it two deliberately different inputs** — a week point with
   one activity removed, a volume row with a discipline reassigned.
2. **Three counts on screen** — weeks in the app, weeks in the database, weeks
   compared. A dead read stops them matching.
3. **`longestRunKm` is a maximum, not a sum**, which makes it the most
   sensitive figure in the slice: a single missing activity changes it only if
   that activity was the longest. Worth a test of exactly that case, because it
   is the one figure where a real difference could hide behind an agreeing sum.

### 3.3 The denominators to put on screen

Every one an exact product, as everywhere else:

- weeks compared × 6 figures per `WeekPoint`
- 4 volume rows × 3 figures (done, dueSoFar, total)
- the block tally: done, total, restExcluded, optionalExcluded
- and the two counts nothing else prints: **weeks begun** and **weeks in the
  plan** (34), so a chart that silently stopped at week 2 is visible

---

## 4. Where it runs

`ShadowParity`, as slice 8 of the roll-up — the same one press that runs slices
1–5. Decided by precedent, not by preference: every parity slice lives there,
and §12.57 put the result on a singleton so it survives sheet dismissal.

**NOT a read-back section.** The nine read-backs compare records; the five
parity slices compare derivations. Slice 8 is a derivation.

---

## 5. What this slice must not do

- **Not re-prove slices 1–5.** Day distances, week distances, CTL and the
  matcher are green and comparing them again would triple the run time and
  produce a second answer to a question already answered — §12.29.
- **Not touch `Matcher.adherence`'s wasteful shape.** 321 declined, 328
  declined, and this declines. It re-resolves each day per session; that is a
  performance defect with no correctness consequence and it is not slice 8's.
- **Not fold in the read-back roll-up.** Decided 8 August: separate patch.
  `ShadowParity`'s own header is the argument — *changing five things to fix
  one is how a slice patch stops being checkable*.

---

## 6. Suggested patch split

**329 — the extraction.** `TabSummary`, the `PlanStore` statics, `accumulate`
going static, `PlanFocus`'s two call sites, `ProgressTabView` and `WeekView`
calling through. **Behaviour-neutral**, and the existing suite is the proof.
Device check is one question: does the Progress tab still read
`Week 2 of 34 · 10/208 · 6/7 · 86%` and the chart still draw.

**330 — the twin.** `SummaryParity` plus its row in `ShadowParity` and
`DatabaseHealthView`.

Same split as 328/329 and for the same reason. If 329 changes a number on the
Progress tab, it is a bug in the extraction, and that is worth knowing on its
own before a comparison is layered on top.

---

## 7. What is still unknown

- **Whether `WeekView.totals`' minute and activity counts are worth twinning.**
  They count extras as well as matched activities, so they are not a function
  of anything slice 1–5 compares — but they are also not printed anywhere the
  athlete makes a decision from. Decide when the first draft exists.
- **Whether the block totals need their own denominator or fall out of the week
  points.** `Sessions 10/208` on the Progress card and `10 of 208` on shadow
  parity's adherence line are now the same number by two paths (verified on the
  device at 328a). If the twin computes it a third way, that is a third copy.
  **Prefer summing the week points.**
- **`ProgressTabView.points` skips weeks that have not begun** (`startKey <=
  todayKey`). The twin must apply the same cutoff from the same clock, or it
  will compare 34 weeks against 2. This is the single most likely way to get
  slice 8 wrong, and it is named here so it is not discovered halfway through.

Everything in §1, §2 and §4 was read out of the source and is settled.
