# Device campaign — the B3/B4 evidence closeout

| | |
|---|---|
| **Task** | Plan topic 3, decomposition items 2 and 3 — "close evidence and behavior gaps left by B1–B4" |
| **Patches under test** | **419** (the athlete read-back), **420** (the ids), **421** (the launch instrument), and B4 as it has stood since 398 |
| **Written at** | patch 420, corrected at 421, 20 August 2026 |
| **ADR** | §12.164, §12.165, and §12.142 for what B4 already proved |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" |
| **Time** | about fifteen minutes, and **one part needs a Release build** |

Topic 3's item 1 — the independent athlete read-back — is code and is done
(419). **Items 2 and 3 are measurements only a device can take**, and this is
them. Item 4 needs no action: load parity stays classified deterministic-only
until B6, which 399 marked and 419 deliberately did not change.

---

## 1. Question and risk

**Three questions, three independent sources.**

1. **Can the athlete read-back now disagree?** Until 419 it compared SQLite with
   `ConstantsStore.shared` and `AthleteStore.shared` — both hydrated from SQLite
   since B1. Twenty-seven comparisons that could not have failed.
2. **What does an activity with a zero-length trace actually draw?**
   `RecordingRepository.all` deliberately returns a present, zero-length
   `ActivityStreams` for a `recording` row with no samples — **not nil.** Views
   test `isUsable` (`distanceM.count >= 8`), and several do it correctly, but no
   device path has exercised the state end to end. The risk is an empty chart, a
   map centred on nothing, or a crash.
3. **What does B4 cost in Release, and does it show?** `Detail store built` has
   only ever been measured in Debug — 0.872 to 1.233 s. §5.6 has owed a Release
   figure since B4 landed, and a construction timestamp is not the same thing as
   the app feeling responsive.

---

## 2. Where everything is

**Settings → Sync & data → Database health**, unless stated.

| what | where |
|---|---|
| the athlete read-back | section **Read-back · athlete** — rows, and **⬆︎** |
| **whether it read the files itself** | section **Read-back roll-up** — NOT the section above |
| the launch, measured | **The file** → row **Launch**, and the six readings in its **⬆︎** |
| the zero-trace ids | **Traces still to fetch** → **⬆︎** → under `asked, nothing there` |
| the build | **Settings → Version → Configuration** — `Debug` or `Release` |
| the cost | **The file** → **⬆︎** → `Detail store built` |

**`asked, nothing there` now names its activities — new at 420.** It used to
print a count only, which made this campaign's central step impossible to
perform. Strava ids are the one identifier a paste may carry (§12.7).

---

## 3. Safety preconditions

- **Read-only throughout.** No note is written, no decision made, no store
  restored. The only action is opening screens.
- **Do not press Import, Restore, or Fetch now.** A backfill would change the
  very buckets part 2 reads.
- **The Release build is a build, not a setting.** Run it from Xcode with the
  Release configuration; it does not change any data.

---

## 4. Exact navigation

### Part 1 — the athlete read-back can now disagree

1. **Database health** → **Read-back · athlete** → tap the title → read the rows
   → **⬆︎** → export.
1b. **Read-back roll-up** → **⬆︎** → export. **This is where the provenance
   line lives** — `ReadBackSource.mark` renders in the roll-up, not in the
   athlete section, and the first draft of this campaign said otherwise
   (§12.166.4). Find the `Athlete` row and read what follows the `·`.

### Part 2 — an activity with no trace

2. **Traces still to fetch** → **⬆︎** → export. Under `asked, nothing there`,
   **write down one id.** If it says `none to name`, this part cannot run today
   — record that and skip to part 3.
3. **Today** or **Week** → navigate to that activity and open its detail.
   (The id is Strava's; the activity is the one whose figures match.)
4. Scroll the whole screen slowly, top to bottom. Look at **HEART RATE**,
   **PROFILE** (all four tabs — HR, Pace, Elev, Grade) and **ROUTE**.
5. Rotate the phone to landscape on the profile panel, then back.

### Part 3 — the cost, in Release

6. Build and install a **Release** build from Xcode.
7. **Settings** → **Version** → confirm **Configuration** reads **Release**.
8. **Force-quit and relaunch.** Then wait — **at least fifteen seconds** —
   without leaving the app, and without pressing anything that starts a sync.
   The stall window is ten seconds long and a reading taken inside it is a
   floor, not an answer. **Do not switch to another app**: the window says so
   when it happens, and the reading is then worth nothing.
9. **Database health** → **The file** → **⬆︎** → export. Read the **Launch**
   row and the six readings under it, and `Detail store built`.
10. Repeat steps 8–9 once more, so there are two Release launches rather than
    one. A single launch cannot be told from an unlucky one.

---

## 5. Pass / fail

| # | after step | figure | passes | fails | meaning |
|---|---|---|---|---|---|
| 1 | 1 | **Read-back · athlete** provenance | names `constants.json and athlete.json, read directly` | says it read the stores | 419 did not land. Every count under it is the database against itself. |
| 2 | 1 | the comparison | agrees, with a non-zero denominator | differs | **A difference here is now real** and was unreachable before 419. Report the field. |
| 3 | 2 | `asked, nothing there` | names one or more ids, or `none to name` | a count with nothing under it | 420 did not land. |
| 4 | 4 | **HEART RATE** | absent, or a clear no-data state | an empty chart with axes and no line | A chart drawn over nothing reads as "your heart rate was zero". |
| 5 | 4 | **PROFILE**, all four tabs | absent, or a clear no-data state | empty axes, or a tab that draws a flat line at 0 | `isUsable` is `distanceM.count >= 8`; a zero-length trace must fail it in every tab, not three of four. |
| 6 | 4 | **ROUTE** | absent | a map centred on the ocean, or on 0,0 | The classic zero-coordinate failure. |
| 7 | 4–5 | the screen | draws, scrolls, rotates | **a crash** | §12.76's runtime stack overflow, or a force-unwrap on an empty series. **Stop and report the whole screen.** |
| 8 | 7 | **Configuration** | `Release` | `Debug` | Part 3 measures nothing otherwise. **This is why part 3 did not run on 20 August.** |
| 9 | 9 | `Detail store built` | **record it** | — | The owed figure. Debug has run 0.872–1.233 s; Release should be materially lower. There is no pass mark — the number is the result. |
| 10 | 9 | `stall window` | `closed — 10.0 s` | `still open` | You read it too early. Wait and export again; every stall figure above an open window is a floor. |
| 11 | 9 | `left the app during the window` | `no` | `YES` | The window is poisoned — the gaps include time the app was not scheduled. Relaunch and do not leave the app. |
| 12 | 9 | `first free main-thread turn` | **record it** | — | The earliest the app could have answered a touch. This is what "under 2 seconds by hand" was reaching for, to three decimal places. |
| 13 | 9 | `longest main-thread stall` | **record it** | — | **The figure a construction timestamp cannot give.** If it is close to `Detail store built`, that read is on the main actor and B4's plan did not hold. If it is small while `Detail store built` is large, the read is off the main actor and the cost is invisible to the user — which is the intended outcome. |
| 14 | 9 | `before our first line` | **record it** | `could not measure` | sysctl refused the process table; the pre-main figure is unavailable on this device and the rest still stands. |
| 15 | 10 | the second launch | figures within a few tenths of the first | wildly different | One launch is an anecdote. |

**Rows 4–7 are the campaign.** Rows 9, 12, 13 and 14 are measurements, not
tests — write the numbers down, they have no pass mark. Rows 10, 11 and 15 are
what says whether the measurements can be believed.

---

## 6. What this does not cover

- **An activity with no `recording` row at all**, as against one with a row and
  no samples. §12.142.6 records that the second is what 398 produced (26 of 694)
  and the first is what the code used to see. This campaign exercises the
  second; the first no longer occurs on this device.
- **Load parity.** Still classified deterministic-only, and 419 deliberately did
  not touch it — both varied inputs come from SQLite, so it proves `LoadSeries`
  is deterministic rather than that the migration carried anything. It is
  **marked, not rescued**, until B6 can give it an independent file-side input.
  Topic 3 item 4, and the prompt asks for exactly that classification.
- **Gear.** `activity_gear_reference` holds 503 rows and no read-back compares
  them. That is B5's, and 419's prompt says not to touch B5 gear behaviour.
- **Whether the Release figure is "good".** There is no target. §5.6 records
  0.443 s of files in Debug against 0.872–1.233 s of database, and 0.399 s of
  files in Release. The Release database figure is the missing fourth corner.

---

## 7. Result

**Part 1 and part 2 ran on 20 August 2026, 21:16–21:21, at patch 420.**

- **Row 1 could not be judged** — the campaign named the wrong section. Corrected
  at 421; take it from **Read-back roll-up**.
- **Row 2 passes**: 27 compared, 0 differing, `approved differences: 1
  (version)`. The denominator is real and the comparison could have failed.
- **Row 3 passes**: `asked, nothing there: 2` followed by
  `15225521352, 16415953236`. 420 landed.
- **Rows 4–7 were not exercised.** The activity opened has a full trace — a
  9.44 km run with a heart-rate series, a route and `56:12 traced` — so it is
  not one of the two. **The ids are named and still not locatable**: nothing in
  the app finds an activity by Strava id, which is the same unperformable step
  one level down.
- **Rows 8–15 did not run.** `Configuration` read `Debug`.

Figures recorded in passing at 420, Debug: `Bootstrap read: 0.036 s`,
`Detail store built: 0.880 s from the database — 699 details, 672 traces`,
`Protection: 7 of 7`, `activities with no trace: 27 of 699`.

*Parts 2 and 3 outstanding.* Fill in `DEVICE-CAMPAIGN-409.md` §10's shape.
