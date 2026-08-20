# Device campaign — the zero-length trace, and what B4 costs in Release

| | |
|---|---|
| **Task** | Plan topic 3, decomposition items 2 and 3 — the two measurements only a device can take |
| **Under test** | **B4** as it has stood since 398 · **421** the launch instrument · **423** the way in · **424** the two origins |
| **Written** | patch 423, 20 August 2026 |
| **Supersedes** | parts 2 and 3 of `docs/DEVICE-CAMPAIGN-B34.md`, whose part 1 **passed on 20 August** and stays there as the record |
| **ADR** | §12.142.6 (what B4 left uncovered), §12.166 (the instrument), §12.169 (the way in) |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" — all ten parts below |
| **Time** | twenty minutes, **one Release build**, no Debug build needed |
| **Re-run at** | patch **424**, which adds rows 15a–15c — the two offsets that place the stall and the store's construction on one timeline (§12.171) |
| **State** | **Part A PASSED in Debug on 20 August — rows 2–8 and 9b; row 9 not applicable. Part B ran in DEBUG, so row 1 failed and the Release figures are still owed. §10** |

**Read this document alone.** It repeats what it needs from B34 rather than
pointing at it: a campaign that requires another campaign open beside it is a
campaign that gets half-run.

**ONE BUILD, IN RELEASE, FOR BOTH PARTS.** Part A is about what the app draws
and part B about what it costs, and neither needs Debug. Running part A in
Release also closes B34 §11's own gap — *a rendering defect that only appears
under Release optimisation would have been missed.*

---

## 1. Question and risk

### 1.1 What does the app draw over a trace of length zero?

`RecordingRepository.all` deliberately returns a **present, zero-length**
`ActivityStreams` for a `recording` row with no samples — **not nil**. Views
test `ActivityStreams.isUsable`, which is `distanceM.count >= 8`.

**No device path has ever exercised that state.** 398's device run named it as
the one uncovered case (§12.142.6): every activity driven by hand had a trace.
Twenty-seven of 699 have none, and **two of those were asked for and came back
empty** — the state under test. The other twenty-five are under 500 m and were
never asked, which is a different fact.

**The risk, in order of how badly each reads:**

1. **A chart drawn over nothing.** Axes, no line, and `avg 0 · max 0` beside
   them. That does not say *no data*; it says *your heart rate was zero*.
2. **A map centred on 0,0** — the classic zero-coordinate failure, an ocean
   south of Ghana.
3. **One tab of four getting it wrong.** `isUsable` is a single rule and four
   tabs consult it. Three correct and one drawing a flat line at zero is the
   most likely defect and the easiest to miss.
4. **A crash** — §12.76's runtime stack overflow, or a force-unwrap on an empty
   series. It would appear only here, and only on a device.

### 1.2 What does B4 cost in Release, and does the cost show?

`Detail store built` has only ever been measured in **Debug** — 0.872, 0.930 and
0.880 s from the database, against 0.443 s of files. §5.6 has owed a Release
figure since B4 landed, and the file side already has one: 0.399 s.

**And a construction timestamp is not responsiveness.** The same read off the
main actor costs the same seconds and none of the jank; a shorter read on the
main actor during the first frame costs less and hurts more. **B4's plan
expected the large sample reads to stay off the main actor, and nothing has ever
checked that.** 421 built the instrument that can: a 60 Hz timer on the main
queue cannot fire while the main thread is busy, so the largest gap between its
fires is time in which nothing rendered and nothing responded.

**The risk:** the Release figure is fine and the app still stalls, or the app is
responsive and the figure is large — either way the two numbers disagree, and
until now only one of them existed.

---

## 2. Build and data identity

**Record all of this before you start. A figure with no build attached is not
evidence.**

| what | where | must read |
|---|---|---|
| **Source patch** | Settings → Version | **423**. Lower means the files did not reach the project folder — **stop** |
| **Configuration** | Settings → Version | **Release**, for both parts |
| **Built** | Settings → Version | a timestamp from this build |
| **App** | Settings → Version | 1.0 (1) |
| **device model, iOS version** | Settings → General → About | **write them down** — nothing else records the hardware |
| timezone | — | Europe/Brussels |
| schema | Database health → **The file** → **⬆︎** | 19 migrations, `Migrations:` identical to `Expected:` |
| tables | Database health → **Rows — N tables** | 52 |
| snapshot | Database health → **Import ledger** | `2026-08-16-211009` |
| dataset | **Import ledger** → last import | 699 activities, 672 traces, 699 details |
| the two under test | **Traces still to fetch** | `asked, nothing there: 2` — **`15225521352 · 2025-07-24`** and **`16415953236 · 2025-11-10`** |

**Preconditions, all from The file:** `Integrity: ok` · `Orphaned rows: 0` ·
`Foreign keys: on` · `Protection: 7 of 7 at the expected class`.
**If any of these has moved, stop and say so** — this campaign assumes a healthy
file and proves nothing over a broken one.

---

## 3. Safety preconditions

**Nothing is written and there is nothing to roll back.** The only actions are
opening screens, scrolling, rotating and pressing **⬆︎**.

- **Do not press Import, Restore, Fetch now, Verify or Take a snapshot.** A
  backfill would change the very buckets §2 just recorded; Verify writes a
  ledger row; Restore writes to the authored stores.
- **Do not pull down on the Today tab.** `.refreshable` there calls
  `activities.sync()` — a real Strava sync. It is the one gesture on this
  campaign's path that reaches the network, and it is easy to trigger by
  scrolling up too far.
- **`Read everything back` is not needed here** and is not part of this
  campaign. It is harmless if pressed.
- **A cold launch starts no sync.** `sync()` runs only from pull-to-refresh, and
  `DatabaseWriteThrough.runOnReturn()` fires when the app comes back **from the
  background** — not on a fresh start after a force-quit. That is why part B
  says force-quit rather than switch away and back: **a return from background
  would put a write-through inside the measurement window.**
- **No protected snapshot is required**, because nothing is mutated.
  `2026-08-16-211009` stands as the fallback; do not overwrite it.
- **The Release build replaces the binary only.** The database, the files and
  `UserDefaults` are untouched. Reinstalling Debug afterwards is safe.
- **Rotating the phone is a test, not an accident.** A crash there is row 8 and
  it is the finding.

---

## 4. Exact navigation

Everything is **Settings → Sync & data → Database health** unless stated.
Sections are collapsed — **tap the section title to open it**; the **⬆︎** beside
a title is its export.

### Setup — and the second half of this is what makes the numbers real

1. **Switch the scheme to Release.** In Xcode:
   **Product → Scheme → Edit Scheme…** (**⌘ <**) → the **Run** action →
   the **Info** tab → **Build Configuration**: change `Debug` to **`Release`**.
   Close the sheet.
2. **⌘R once**, to build and install. Then **stop it in Xcode (⌘.)** as soon as
   it is on the phone.
   **DETACH BEFORE YOU MEASURE.** Launching from Xcode attaches the debugger,
   which adds real start-up cost and lands squarely inside the ten-second window
   part B measures. Every launch that counts must come from **tapping the icon
   on the phone**. (Unticking **Debug executable** in the same pane stops Xcode
   attaching at all, which works equally well.)
3. **Settings → Version.** Confirm **Configuration: Release** and **Source
   patch: 424**. Screenshot it. If it says `Debug`, the scheme change did not
   take — go back to step 1, because **part B measures nothing otherwise**, and
   that is exactly how the 20 August run was lost.

### Part A — the two activities with no trace · *steps 4–9*

4. **Database health** → tap **Traces still to fetch** → **⬆︎** → share the
   export. On the **screen**, read the line under `asked, nothing there`: it
   should show two `<id> · <date>` entries.
5. **Tap the first entry** (`15225521352 · 2025-07-24`). The activity's detail
   opens as a sheet. **This is the only way in** — the Week tab's grid starts at
   2026-01-01 and cannot reach 2025, and the Today tab would take 393
   day-steps.
6. **Scroll the whole screen slowly, top to bottom**, and screenshot it in
   overlapping pieces so that **an absent panel is visible as absent**. Look for,
   in this order:
   **the summary card** (distance, moving, pace, climb) · **KILOMETRE SPLITS**,
   both the **Km** and the **Laps** segment · **HEART RATE** with its zone
   distribution · **PROFILE**, and on it **each of the four tabs — HR, Pace,
   Elev, Grade** · **ROUTE** · **BEST EFFORTS** · the footer facts.
7. **On the PROFILE panel, try to drag across it.** If a panel that has no data
   still accepts a scrub, say so — that is where a force-unwrap on an empty
   series would fire.
8. **Rotate the phone to landscape**, wait for it to settle, rotate back.
9. Dismiss the sheet with **Done**, then **repeat steps 5–8 for the second
   entry** (`16415953236 · 2025-11-10`).

### Part B — what it costs, in Release · *steps 10–13*

10. **Force-quit the app** — swipe up from the app switcher. Then relaunch by
   **tapping the icon**.
11. **Wait at least fifteen seconds without leaving the app.** Do not switch
    apps, do not lock the phone, do not pull down on Today. The stall window is
    ten seconds long and a reading taken inside it is a floor, not an answer.
    Waiting on the Today tab without touching it is fine.
12. **Database health** → **The file** → read the **Launch** row on screen →
    **⬆︎** → share the export.
    **Do the subtraction while you are there** — row 15c. The stall's line now
    ends `beginning N s after our first line`, and `Detail store built` ends the
    same way with its own figure. **Whether the second falls inside the first's
    span is the answer this run exists for.**
13. **Repeat steps 10–12 once more**, so there are two Release launches. One
    launch is an anecdote.

---

## 5. Independent expected result — where each expectation comes from

**The contract's rule: do not derive the expected answer from the same
database-fed store that supplies the screen being tested.**

| rows | what is claimed | the independent source |
|---|---|---|
| 1–3 | which two activities came back empty | **`DetailStore`'s work-queue verdicts** (`answeredEmpty`) — a `UserDefaults` set, not part of B4's migration, and not fed by the database |
| 4–9 | what the app draws over a zero-length trace | **the SwiftUI source itself.** `ActivityStreams.isUsable` is `distanceM.count >= 8`; `ActivityDetailRoute` and `ActivityDetailHR` guard on it. **The expectation is the code's own rule and the device says whether it holds** — which is the only shape available, because no diagnostic can report what a person sees |
| 4–9 (splits) | splits survive an absent trace | **`activity_split`** — a different table and a different family, 8 206 rows, which the trace's absence must not touch |
| 10 | what the read costs in Release | **the three Debug figures** (0.872 / 0.930 / 0.880 s) and **the file side in Release** (0.399 s) as the other corners of the same square |
| 11–15 | when the app becomes responsive | **the kernel** (`kinfo_proc.p_starttime`) and **the main queue itself** — a 60 Hz timer that cannot fire while the main thread is busy. Neither reads a store, and neither can be fooled by a fast construction |

---

## 6. App evidence source — the exact lines

| rows | screen | section | the line |
|---|---|---|---|
| 1–3 | Database health | **Traces still to fetch** | `asked, nothing there`, and **on screen** the `<id> · <date>` entries beneath it |
| 4–9 | Activity detail | HEART RATE · KILOMETRE SPLITS · PROFILE · ROUTE | **there is no diagnostic.** These rows are screenshots and your own eyes |
| 10 | Database health | **The file** → **⬆︎** | `Detail store built: N s from the database — 699 details, 672 traces` |
| 11–15 | Database health | **The file** → **⬆︎** | `Launch:` and the six lines under it |
| identity | Settings → Version | — | Configuration, Source patch, Built |

**Rows 4–9 having no diagnostic is not an omission.** The question is what a
person sees, and no number the app prints can answer it. That is also why they
cannot be re-checked from an export later: **if the screenshots are not taken,
the rows were not run.**

---

## 7. Pass / fail

| # | after step | where | figure | passes | fails | what the failure means |
|---|---|---|---|---|---|---|
| 1 | 3 | Settings → Version | **Configuration** | `Release` | `Debug` | **Part B measures nothing.** This is exactly why part 3 of B34 did not run. |
| 2 | 4 | Traces still to fetch | `asked, nothing there` | `2`, with two `<id> · <date>` entries under it | a count with nothing under it, or ids with no dates | 422/423 did not land. Check **Source patch** reads 423. |
| 3 | 4 | Traces still to fetch | `unexplained` | `0`, with `none to name` under it | ≥ 1 **(red)** | An activity has no trace for a reason nothing in this app has a name for. **Not this campaign's subject — report it**, with the ids now printed beside it. |
| 4 | 5 | Traces still to fetch | tapping an entry | the activity's detail opens | nothing happens | **423 did not land.** Part A stops here. |
| 4b | 5 | Traces still to fetch | the entry's text | `<id> · <date>` | `— not in the activity list` | The roster no longer holds an activity the verdict set still names (§12.169.2). **A real state and it is not supposed to occur today** — report it and stop. |
| 5 | 6 | activity detail | **HEART RATE** | the panel is **absent**, or present with a clear no-data state | an empty chart with axes and no line, or `avg 0 · max 0`, or a zone list at all zeros | A chart drawn over nothing reads as "your heart rate was zero". **The worst of the failures, because it looks like data.** |
| 6 | 6 | activity detail | **PROFILE** — HR, Pace, Elev, Grade | absent, or a clear no-data state, **in all four tabs** | empty axes, or a tab drawing a flat line at 0 | `isUsable` is one rule and four tabs consult it. **Three correct and one wrong is the likeliest defect here** — check all four, do not assume from the first. |
| 7 | 6 | activity detail | **ROUTE** | **absent** | a map centred on 0,0, on the ocean, or on one point | The classic zero-coordinate failure. |
| 8 | 6–8 | activity detail | the screen | draws, scrolls, rotates, dismisses | **a crash** | §12.76's runtime stack overflow, or a force-unwrap on an empty series. **Stop. Report the whole screen and what you last touched.** |
| 9 | 6 | activity detail | **KILOMETRE SPLITS**, Km and Laps | the splits still draw | absent, or empty | Splits come from `activity_split`, a different family. **A missing trace must not take them with it.** |
| 9b | 6 | activity detail | the summary card | distance, moving, pace and climb all present | any of them blank | The summary comes from `activity`, not from the trace. Same argument as row 9, one table further out. |
| 10 | 12 | The file export | `Detail store built` | **record the number** | — | The figure §5.6 has owed since B4. Debug has run 0.872–1.233 s. **There is no pass mark — the number is the result.** |
| 11 | 12 | The file export | `stall window` | `closed — 10.0 s` | `still open — N s` | You read it too early. Wait and export again. **Every stall figure over an open window is a floor, not a maximum.** |
| 12 | 12 | The file export | `left the app during the window` | `no` | `YES` | The window is poisoned — the gaps include time the app was not scheduled at all, and a "stall" of several seconds is really a trip to the home screen. Relaunch and take it again. |
| 13 | 12 | The file export | `first free main-thread turn` | **record it** | `not yet — …` | The earliest the app could have answered a touch — what "under two seconds by hand" was reaching for, to three decimals. A `not yet` means the 60 Hz watch never ticked, which is a 421 defect. |
| 14 | 12 | The file export | `longest main-thread stall` | **record it** | — | **The figure a construction timestamp cannot give.** Close to `Detail store built` → **that read is on the main actor and B4's plan did not hold.** Small while `Detail store built` is large → the read is off the main actor and the cost is invisible to the user, which is the intended outcome. |
| 15 | 12 | The file export | `before our first line` | **record it** | `could not measure — …` | sysctl refused the process table. The pre-main figure is unavailable on this device; every other row still stands. |
| 15a | 12 | The file export | `longest main-thread stall … beginning N s` | **record N** | `— no tick ran late` | New at 424. A launch with no stall at all is a legitimate answer and reads differently from one placed at zero (§12.171.2). |
| 15b | 12 | The file export | `Detail store built … beginning M s` | **record M** | `and nothing recorded when it began` | New at 424. The clock was never started, which on a running app cannot happen — report it as a 424 defect. |
| **15c** | 12 | **both offsets together** | **is M inside the stall's span?** | **the arithmetic is the answer, not a pass mark** | — | **THE ROW THIS BUILD EXISTS FOR.** The stall runs from N to N + (its duration). If **M falls inside that span**, `DetailStore`'s construction is the stall and §12.170.1's inference is confirmed. If **M falls after it**, the stall is something else and 423's reading was over-read. If **M is far larger than the window** (hundreds of seconds), the store was not built at launch at all — it was built by the Database screen you just opened, and the stall belongs to something that never touched it. |
| 16 | 13 | both exports | rows 10 and 13–15 | within a few tenths of each other | wildly different | One launch is an anecdote. **A large gap is itself a finding** — say which launch was which. |

**Rows 1–9b are pass/fail. Rows 10 and 13–15b are measurements with no pass
mark — write the numbers down. Rows 11, 12 and 16 are what say whether the
measurements can be believed at all. Row 15c is a subtraction you can do on the
spot, and it is why this run is worth taking.**

---

## 8. Evidence capture

**Keep, and share:**

1. **Three exports** — `Traces still to fetch` once, and `The file` **once per
   Release launch** (two of them).
2. **A photo or screenshot of the `<id> · <date>` line.** The export carries ids
   only, by design (§12.7), so the dates exist nowhere else.
3. **Screenshots of both activity details, scrolled in overlapping pieces.** An
   absent panel is only visible in a shot that shows what is above and below the
   gap. **These rows cannot be reconstructed later from anything else.**
4. **A screenshot of Settings → Version in Release** — the identity for rows 10
   to 16.
5. **The time of day** each part was run, and **which launch was first**.

**Redaction.** The exports omit paths, names, places and dates and carry Strava
ids and field names, which §12.7 permits. **The screenshots do not** — an
activity detail shows the session name, the date and, when there is one, a route
over a real map. **They are for Bruno's own review and are not pasted into the
ADR.** What reaches the ADR from rows 5–9b is a sentence describing what drew.

---

## 9. Cleanup and rollback

- **Nothing to roll back.** No store was written, no setting changed, no gate
  moved.
- **Put the scheme back to Debug** when part B is finished — Product → Scheme →
  Edit Scheme… → Run → Info → **Build Configuration: Debug** — and reinstall, so
  the next session's figures stay comparable with the Debug history and nobody
  later mistakes a Release install for the working build.
- **Confirm the app came back to where it started**, against what §2 recorded:
  `Rows — 52 tables`, `activity 699`, `Traces still to fetch: 0`,
  `activities with no trace: 27 of 699`, `unexplained: 0`, and the same
  **Last import** timestamp in the ledger.
- **Do not press Verify or Import to "tidy up".** A verification run after a
  Release launch writes a ledger row this campaign did not intend, and §2's
  fingerprint would stop matching.

---

## 10. Result

**Run 20 August 2026, 22:38–22:42, patch 423 — IN DEBUG, not Release.**

### 10.1 Row 1 FAILED, and it changes what part B means

`Configuration` read **Debug**. Every figure below is a Debug figure and
**§5.6's owed Release `Detail store built` is still owed.** Rows 10 and 13–15
have Debug readings recorded here and their Release readings outstanding.

### 10.2 Part A — the two activities with no trace. Rows 2–8 and 9b PASS

| row | reading | |
|---|---|---|
| 2 | `asked, nothing there: 2`, and on screen `15225521352 · 2025-07-24 ›` and `16415953236 · 2025-11-10 ›`, each with a chevron | ✅ |
| 3 | `unexplained: 0`, `none to name` beneath it | ✅ |
| 4 | both entries opened their activity's detail | ✅ **423 works** |
| 4b | neither said `— not in the activity list` | ✅ |
| 5 | **HEART RATE absent.** In its place: *"No recorded profile for this one — entered by hand, or recorded without GPS."* | ✅ |
| 6 | **PROFILE absent — the whole panel, so all four tabs.** Same explanatory row | ✅ |
| 7 | **ROUTE absent.** No map, no 0,0 | ✅ |
| 8 | both drew, scrolled, rotated to landscape and back, dismissed. **No crash** | ✅ |
| 9b | the summary card is complete on both — distance, moving, **speed** (a Ride, so speed rather than pace) and climb | ✅ |

**The app does not draw a chart over nothing.** It replaces the panels with one
sentence that says why, which is §12.15's shape in the UI rather than in a
diagnostic. The uncovered case §12.142.6 named after 398's device run is now
covered, and it passed.

**The two activities are swims logged as commute rides** — `Zwemmen ·
Hazewinkel`, 1.5 km in 32:00, and `Zwemmen · Wezenberg`, 2.6 km in 1:10:00,
both `Climb 0 m`. That is what an activity Strava had no stream for turns out to
be: **entered by hand.** Worth writing down, because it explains the bucket
rather than merely counting it.

### 10.2a ROW 9 COULD NOT DISCRIMINATE, AND THAT IS THE CAMPAIGN'S FAULT

Row 9 asked whether **KILOMETRE SPLITS** still draw when the trace is absent,
on the argument that splits come from `activity_split` and must not be taken
down with the trace. **The splits are absent on both activities — and that
proves nothing**, because a hand-entered activity has no splits either. The row
conflated *the trace is missing* with *the activity has splits*, and these two
have neither.

**Not a failure and not a pass. Not applicable.** The question row 9 was written
to ask is still open and cannot be asked here: it needs an activity **with**
splits and **without** a trace, and this device does not appear to have one.
Same family as 409's control 4, which did not discriminate the order it was
written for and said so. §12.15 applied to a test rather than to a screen.

### 10.3 Part B — two launches, in Debug. Rows 11, 12 and 16 PASS

| row | launch 1 | launch 2 | |
|---|---|---|---|
| 10 | `Detail store built: 0.700 s` | `0.683 s` | Debug. **The Release figure is still owed.** |
| 11 | `stall window: closed — 10.0 s` | same | ✅ |
| 12 | `left the app during the window: no` | same | ✅ |
| 13 | `first free main-thread turn: 0.022 s` | `0.032 s` | recorded |
| 14 | **`longest main-thread stall: 1.053 s`** over 536 samples | **`1.046 s`** over 536 samples | recorded — **and this is the finding** |
| 15 | `before our first line: 0.046 s` | `0.021 s` | recorded |
| 16 | the two launches agree — stalls 7 ms apart | | ✅ |

Also: `Bootstrap read: 0.023 s` and `0.026 s`.

### 10.4 THE FINDING — the app paints in 22 ms and then freezes for a second

`first free main-thread turn: 0.022 s` and `longest main-thread stall: 1.05 s`
are both true and describe opposite experiences. The app becomes responsive
almost immediately and then, still inside the first ten seconds, stops answering
for a full second.

**The stall EXCEEDS the store's construction by about a third of a second,
twice** — 1.053 against 0.700, and 1.046 against 0.683. §12.166's rubric said
*close to `Detail store built` → that read is on the main actor and B4's plan
did not hold*. It is not close; it is larger.

The path is short and it is in the source. `TodayView` has
`.task { load.recomputeIfNeeded() }`; `LoadStore.recomputeIfNeeded` is
`@MainActor`; its first act reads `DetailStore.shared.streamCount`, **and
reading `DetailStore.shared` is what constructs it.** One main-actor task builds
the store and then walks 699 activities to rebuild the load series, back to
back, immediately after first paint.

**That is arithmetic plus one call path, and it is still inference.** The
instrument reports the largest gap, not when it began. §12.170.2 says what would
settle it. **Do not act on this as though it were attributed.**

### 10.5 Outstanding

- **Row 1 and the Release readings of rows 10 and 13–15.** Build Release, and
  run part B again. Part A does not need repeating unless you want the
  Release-optimisation coverage §11 mentions.
- **Row 9 cannot be run on this device** and is recorded as not applicable.
- **Rows 15a–15c are new at 424 and settle the attribution.** They need the same
  run, so the Release build answers row 1, the Release figures and the cause of
  the stall together — which is the whole reason 424 was built before anything
  was changed. §12.171.

---

## 11. What this campaign does not cover

- **An activity with no `recording` row at all**, as distinct from one with a
  row and no samples. §12.142.6 records that the second is what 398 produced and
  the first is what the code used to see before it. This campaign exercises the
  second; **the first no longer occurs on this device, so the guard against it
  stays untested** and cannot be tested here at any price.
- **The twenty-five activities under 500 m.** They were never asked for, so they
  are a different bucket and a different question — and they have no `recording`
  row at all, which is the case above.
- **Load parity**, still classified deterministic-only until B6 — topic 3 item 4
  asks for exactly that classification and no more.
- **Gear.** `activity_gear_reference` holds 503 rows and no read-back compares
  them. B5's.
- **Whether the Release figure is "good".** There is no target and this campaign
  does not invent one. §5.6 will hold four corners once row 10 lands: files in
  Debug 0.443 s, database in Debug 0.872–1.233 s, files in Release 0.399 s, and
  the database in Release.
- **Jank outside the first ten seconds.** The window is the launch. Scrolling a
  long week, opening a heavy activity, or a sync in progress are not measured
  and would each need their own instrument.
- **A launch with a sync running.** Deliberately excluded — a cold launch starts
  no sync, and part B says force-quit precisely so that nothing else is inside
  the window. **What a launch costs while catching up with Strava is a different
  measurement and this is not it.**
- **The athlete read-back and the roll-up.** They passed at 422 and are recorded
  in `docs/DEVICE-CAMPAIGN-B34.md` §10.1a — including the roll-up's
  self-referential count reaching zero. Nothing here re-asks them.
