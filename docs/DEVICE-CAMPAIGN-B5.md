# Device campaign — D7 slice B5, weather and gear

| | |
|---|---|
| **Slice** | D7 B5 — weather and gear. Built 425–429, flipped at **430**, corrected at **431–432** |
| **Written at** | patch 432, 21 August 2026, **against the code as built and against this device's own figures** |
| **Groundwork** | `docs/D7-B5-GROUNDWORK.md` — §6's five decisions, all approved 21 August |
| **ADR** | §12.175–§12.182a |
| **Time** | about twenty-five minutes. **Part D needs a Release build. Part E moves files.** |
| **State** | **PARTS A AND B PASSED 21 August — thirteen of thirteen** (§10.1, §10.1a). Parts C–E outstanding: the weather cards, the Release cost, and whether the files can go. |

**THIS IS THE FIRST B-SLICE CAMPAIGN THAT IS NOT READ-ONLY.** Part E moves
`athlete.json` and `weather.json` aside to prove the app no longer needs them.
Read §3 before you start.

---

## 1. Question and risk

**The read-back already agrees, and that is exactly why this campaign exists.**
On 21 August at 13:34 it read `gear fields that differ: 0`,
`gear by kind: 6 shoes, 4 bikes, 1 of unknown kind`, `1 retired` carrying a
date, and `Gear facts recovered from the file at hydration: 0`.

**A read-back compares values. It cannot see a screen.** Three questions remain:

1. **Does gear still RENDER correctly?** The Progress tab's shoe section is the
   only place gear is drawn, and 429 changed how it draws — the wear bar is now
   absent for anything that is not a shoe. The section now reads a `shoes` array
   rebuilt from database rows rather than from `athlete.json`.
2. **Does weather still render?** 606 readings, drawn on every activity screen,
   and the store now serves rows.
3. **Can the files go?** That is what a slice being complete MEANS, and it is
   the only part of B5 no automated test can approach.

**The risk that would not show up anywhere else:** the values are right and the
screen is wrong — a shoe list in a different order, a wear bar missing where it
belongs, a weather card that renders zeros instead of disappearing.

---

## 2. Build and data identity

**Record before you start.**

| what | where | must read |
|---|---|---|
| **Source patch** | Settings → Version | **432 or higher** |
| **Configuration** | Settings → Version | `Debug` for parts A–C, **`Release` for part D** |
| device, iOS | Settings → General → About | write them down |
| migrations | The file → **⬆︎** | **21**, `Migrations` identical to `Expected`, ending `2026-08-21-gear-kind, 2026-08-21-gear-retired` |
| `Athlete store reads` | The file → **⬆︎** | **`the database`** — no `until slice B5` |
| `Weather store reads` | The file → **⬆︎** | **`the database`** |
| tables | Rows | 52 · `gear` **11** · `weather` **606** · `activity_gear_reference` **504** |
| the inventory | Read-back · weather and gear → **⬆︎** | **6 shoes, 4 bikes, 1 of unknown kind · 1 retired · 1 carrying a date** |

Preconditions: `Integrity: ok`, `Orphaned rows: 0`, `Foreign keys: on`,
`Protection: 7 of 7`.

---

## 3. Safety preconditions — READ THIS ONE

- **Part E moves two files.** `athlete.json` and `weather.json`. **Move, never
  delete.**
- **`athlete.json` IS THE ONLY COPY OF THE RETIRED-GEAR INFERENCE.** Strava
  publishes no retired list; `resolveRetiredGear` rebuilds it one fetch at a
  time, capped at ten per run, from activities naming gear the profile no longer
  holds. Losing the file means the app rediscovers it slowly, and only while
  those activities survive. **Never use the only copy of authored data for a
  destructive test** — so part E takes a snapshot first and the move is
  reversible in one step.
- **Take a protected snapshot before part E**, from Database health →
  **Protected snapshot**. Record its id.
- **Parts A–D are read-only.** Do not press Import, Restore, Verify or Fetch
  now. Backgrounding the app IS an import — that is fine and expected, and it is
  how the write-through runs; just do not press the button.
- **`Restore weather from the database` is at the top of the read-back section.
  Do not press it** in parts A–D. Part E is the only place a restore is wanted,
  and only after the files have been moved back.

---

## 4. Exact navigation

### Part A — the gear inventory, and what the app says it read · *steps 1–3*

1. **Settings → Version** — screenshot. **Settings → Sync & data → Database
   health → The file → ⬆︎** — share.
2. **Read-back · weather and gear → ⬆︎** — share.
3. **Rows — 52 tables → ⬆︎** — share.

### Part B — how gear renders · *steps 4–6*

4. **Progress tab → the shoes section.** Count the rows. Photograph the whole
   section. For each: name, kilometres, the colour, and whether it has a **bar**
   underneath.
5. **Compare against the Progress tab as you remember it before today.** The
   figures must not have moved — this is a caching change, not a scoring one.
6. Note anything with **no bar** and read what the row says instead of the wear
   word.

### Part C — how weather renders · *steps 7–9*

7. **Today** or **Week** → open a recent run's detail → the weather block on the
   summary card: temperature, **Felt**, **Wind** with its compass point,
   **Humidity**.
8. Open a second activity **from a different month** — the readings are per
   activity and a stale cache would show one month's weather everywhere.
9. **Find an activity with no weather** — one of the 93 without a reading (699
   activities, 606 readings). A strength session or an indoor ride is the
   likeliest. Confirm the weather figures are **absent**, not zeroed.

### Part D — what B5 costs, in Release · *steps 10–13*

10. Xcode: **⌘ <** → **Run** → **Info** → **Build Configuration: Release**,
    untick **Debug executable**. ⌘R once, then **⌘.**.
    **Do not `git checkout` the scheme until part E is finished** — RULE 14
    guards the repository, not your working copy.
11. **Settings → Version** — confirm **Release** and **432+**.
12. **Force-quit, relaunch from the icon, wait fifteen seconds** without leaving
    the app. **The file → ⬆︎** — share.
13. **Repeat step 12 once.**

### Part E — the files go · *steps 14–19*

14. **Database health → Protected snapshot → take one.** Record the id.
15. Move `athlete.json` and `weather.json` out of the app's container — through
    Xcode's device container download, or the Files app if the container is
    exposed. **Move, do not delete.**
16. **Force-quit and relaunch.**
17. **Progress → shoes**: the same six rows, the same figures.
    **An activity detail**: the same weather.
18. **Database health → Read-back · weather and gear → ⬆︎** — share. It reads
    the files for its app side, so this export is expected to be **loud**.
19. **Put both files back. Force-quit, relaunch, export the read-back again.**

---

## 5. Independent expected result

| rows | claim | the independent source |
|---|---|---|
| 1–6 | the eleven pieces of gear survived, classified | **`athlete.json` read directly** by `weatherGearSources()` — the seam, not the store (§12.181) |
| 7–9 | 606 readings survived | **`weather.json`, read directly**, same seam |
| 10–14 | the screens draw what the rows hold | **your memory of the app before today, and the pre-flip screenshots** — no diagnostic can answer this |
| 15–18 | the Release cost | **424's Release figures**: stall 0.562 / 0.641 s, `Detail store built` 0.323 / 0.397 s |
| 19–22 | the files are no longer needed | **the app itself, with the files gone.** The only test of a slice being complete |

---

## 6. App evidence source

| rows | where | the line |
|---|---|---|
| 1–3 | The file → ⬆︎ | `Athlete store reads`, `Weather store reads`, `Gear facts recovered from the file at hydration`, `Hydration at launch` |
| 4–6 | Read-back · weather and gear → ⬆︎ | `gear by kind`, `gear the database marks retired`, `gear carrying a retirement date`, `gear fields that differ` |
| 7–14 | Progress tab · activity detail | **no diagnostic — photographs and your eyes** |
| 15–18 | The file → ⬆︎ | `Launch:` and `Detail store built`, in Release |
| 19–22 | Read-back · weather and gear → ⬆︎ | `gear only in the app`, `readings only in the app`, and the `own read` sentence |

---

## 7. Pass / fail

| # | after | figure | passes | fails | meaning |
|---|---|---|---|---|---|
| 1 | 1 | `Athlete store reads` | **`the database`** | `…until slice B5` or `…nothing stored to hydrate from` | the flip did not land, or the gear table is empty |
| 2 | 1 | `Weather store reads` | `the database` | `the app's own files` | `.weather` is not in `hydratedFamilies` |
| 3 | 1 | **`Gear facts recovered from the file at hydration`** | **`0`** | any non-zero | **The 432 loop is still running** — the write-through is not carrying the recovered facts into the rows. §12.182.4. |
| 4 | 2 | `gear by kind` | **6 shoes, 4 bikes, 1 of unknown kind** | anything else | the classification moved. Report the new split |
| 5 | 2 | `gear the database marks retired` | **1** | 0 | the retirement was lost — and `athlete.json` is its only other copy |
| 6 | 2 | `gear carrying a retirement date` | **1** | 0 | `dateRetiredGear` found no activity naming it. Not fatal; report it |
| 7 | 2 | `gear fields that differ` | **0** | ≥ 1 | named per item as `<id> · <field>`. Report the list |
| 8 | 2 | `approved differences` | **2 (Shoe.primary, gear.retiredUTC)** | three or more | something rejoined the list, which no patch since 427 should have done |
| 9 | 3 | `gear` / `weather` | **11** / **606** | moved | an import ran between exports, or rows were lost |
| 10 | 4 | the shoes section | **six rows** | five, seven, or none | the `shoes` array is rebuilt from rows now; a wrong count means the split is wrong |
| 11 | 4 | each row's kilometres | unchanged from before today | any figure moved | **B5 is a caching change, not a scoring one.** A moved distance is the worst outcome available here |
| 12 | 4 | each row's **bar** | present on all six | any missing | all six are `kind == .shoe` on this device, so all six draw. A missing bar means a kind was misclassified |
| 13 | 4–6 | order and names | as before | reordered | `activeShoes` sorts by distance and that did not change |
| 14 | 7–9 | the weather block | present with real figures on 7 and 8; **absent** on 9 | `0 °C`, `0 km/h`, or the same reading on two different months | an absence drawn as a measurement, or a stale cache |
| 15 | 12 | `Configuration` | `Release` | `Debug` | part D measures nothing otherwise |
| 16 | 12 | `longest main-thread stall` | **record it** | — | **§12.174's threshold is 1.0 s.** At or above and B6a is promoted from scheduled work to the next patch |
| 17 | 12 | `Bootstrap read` | **record it** | — | 8 families now. Was 0.011–0.016 s in Release with 7 |
| 18 | 13 | the second launch | within a few tenths of the first | wildly different | one launch is an anecdote |
| 19 | 17 | shoes and weather, files gone | **identical to rows 10–14** | anything changed or missing | **the app still needs the files, and B5 is not complete** |
| 20 | 18 | `gear only in the app` | `0` | 11 | expected to be loud in a different way — see row 21 |
| 21 | 18 | the read-back's own-read sentence | says the app side **could not be read** | claims a clean read of nothing | **THE ROW THAT MATTERS IN PART E.** With the files gone the app side is empty, and an empty side reported as agreement is exactly §12.54.2. Zero compared to zero must not pass |
| 22 | 19 | after putting the files back | identical to part A's export | any difference | the move was not reversible, and the snapshot from step 14 is the way back |

**Rows 3, 11, 19 and 21 are the campaign.** Row 3 says the fix holds; row 11
says nothing was rescored; row 19 says the slice is complete; row 21 says the
diagnostic is still honest when its own side is gone.

---

## 8. Evidence capture

Five exports — `The file`, `Read-back · weather and gear`, `Rows` from part A;
`The file` twice from part D; `Read-back · weather and gear` twice more from
part E. Photographs of the shoes section and of both weather cards, plus the
no-weather activity **showing the gap**. The snapshot id from step 14. Times of
day.

**Redaction.** The exports carry ids, field names and counts. **The photographs
do not** — an activity detail shows the session name, the date and a map. They
are for your review; what reaches the ADR from rows 10–14 is a sentence.

---

## 9. Cleanup and rollback

- **Put both files back** (step 19) — this is not optional and it is the whole
  reason step 15 says *move*.
- **Scheme back to `Debug`**, `Debug executable` ticked, and
  `git checkout -- Sub4.xcodeproj/xcshareddata/xcschemes/Sub4.xcscheme`
  **only after the last export**. RULE 14 fails the build if a Release Run
  action is committed.
- **Reinstall the Debug build.**
- Confirm against §2: 52 tables, `gear` 11, `weather` 606,
  `activity_gear_reference` 504, and `Gear facts recovered` still 0.
- **If part E goes wrong**, the snapshot from step 14 is the way back, and the
  files you moved are the other way back. Do not press Restore unless both have
  failed.

---

## 10. Result

### 10.1 Part A — 21 August 2026, 13:34 and 13:46, patch 432. NINE OF NINE

| # | figure | read | |
|---|---|---|---|
| 1 | `Athlete store reads` | **`the database`** — no `until slice B5` | ✅ |
| 2 | `Weather store reads` | `the database` | ✅ |
| 3 | **`Gear facts recovered from the file at hydration`** | **`0`** | ✅ |
| 4 | `gear by kind` | **6 shoes, 4 bikes, 1 of unknown kind** | ✅ |
| 5 | `gear the database marks retired` | **1** | ✅ |
| 6 | `gear carrying a retirement date` | **1** | ✅ |
| 7 | `gear fields that differ` | **0** | ✅ |
| 8 | `approved differences` | **2 (Shoe.primary, gear.retiredUTC)** | ✅ |
| 9 | `gear` / `weather` / `activity_gear_reference` | **11 / 606 / 504** | ✅ |

Also: **21 migrations**, `Migrations` identical to `Expected`, ending
`2026-08-21-gear-kind, 2026-08-21-gear-retired`. `Integrity: ok`,
`Orphaned rows: 0`, `Foreign keys: on`, `Protection: 7 of 7`.
`Hydration at launch: … the activities, the weather, the gear`.
`Database bootstrap: 8 families`.

**AND THE TWO EXPORTS TWELVE MINUTES APART ARE IDENTICAL BELOW THE HEADER.**
Row 3 in particular: `Gear facts recovered` was 0 at 13:34 and 0 again at 13:46.
**A single zero could be a hydration that found nothing to do because the store
was empty; two are the loop staying closed.**

`migration_run` reads **256**, down from 257. **Not data loss** — it is
`MigrationLedger.prune` at its ceiling, and §12.153.10 records the same one-row
movement on 19 August for the same reason. `imported rows` follows it by one.

### 10.1a Part B — 21 August 2026, 13:47, patch 432. FOUR OF FOUR

| # | figure | read | |
|---|---|---|---|
| 10 | the shoes section | **six rows** | ✅ |
| 11 | each row's kilometres | **unchanged** | ✅ |
| 12 | each row's bar | **present on all six** | ✅ |
| 13 | order and names | by distance descending, names as before | ✅ |

```
Lowa ZEPHYR GTX                              534 km
Adidas GSG 9-7                               516 km
ASICS Novablast 5 TR (Green) Antwerpen       324 km
New Balance Fresh Foam X Hierro V9           248 km
ASICS Gel Cumulus Trail                      114 km
ASICS ASICS Novablast 5 TR (Oranje) Berlin   108 km
```

**ROW 11 HAS AN INDEPENDENT WITNESS, AND IT IS BETTER THAN MEMORY.** The
activity detail photographed on **20 August, before B5 flipped**, reads
`Shoe: ASICS ASICS Novablast 5 TR (Oranje) Berlin · 108 km`. The same pair reads
**108 km** here, from rows. A figure carried across the flip and checked against
a screenshot taken before it — which is exactly the independent expected result
§5 asks for, and it happened to already exist.

**AND THE SOURCE'S OWN COMMENT IS THE SECOND WITNESS.** `Shoe.Wear`'s self-test
note, written long before B5, says *"the highest pair is at 534 km, so amber is
66 km away and red is 266"*. The highest pair reads **534 km**. The thresholds
are 600 and 800, so **every bar is correctly untinted** — and the two states
above `.fine` remain unreachable on this athlete's data, which is why that
self-test exists at all.

Six rows and not eleven: the four bikes and the one retired item are drawn
nowhere, which is §11's first entry and the reason 429's wear guard cannot be
seen here.

### 10.2 Outstanding

**Parts C, D and E — rows 14 to 22.** The weather cards, the Release cost, and
whether the files can go.

Record each part below, and say plainly which rows were not exercised. **A
partial campaign is evidence for its rows only, never for the whole slice.**

---

## 11. What this campaign cannot cover

- **429's wear guard.** `ProgressTabView` renders `activeShoes`, which is the
  `shoes` array; **this device's six shoes are all `kind == .shoe`**, the four
  bikes are drawn nowhere, and the one unclassified item is retired and
  therefore also drawn nowhere. **The "no bar, and say why" path is unreachable
  here** — proved by test, not by eye. Named in advance rather than discovered
  half way through: 426's row 9 is the precedent.
- **A retired BIKE.** `fetchGear` returns no type, so one would arrive
  `unknown`. This device's single retired item is already unclassified, so the
  distinction cannot be seen.
- **Gear the source dropped.** `gear kept after the source dropped it` reads 0,
  which means the eleven in the file and the eleven in the database are the same
  eleven. The path exists and has nothing to exercise it.
- **`Shoe.primary`.** No column, by decision, and read by nothing — 429's
  uncapped grep found one write and zero reads. It cannot be checked and does not
  need to be.
- **Weather for an activity the app does not hold.** `readings only in the
  database` and `readings for an activity the app does not hold` both read 0.
- **Whether the Release figure is "good".** There is no target. Row 16 records a
  number and compares it against 1.0 s, which is a threshold for scheduling
  B6a, not a pass mark for B5.
