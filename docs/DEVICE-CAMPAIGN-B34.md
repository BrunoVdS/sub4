# Device campaign — the B3/B4 evidence closeout

| | |
|---|---|
| **Task** | Plan topic 3, decomposition items 2 and 3 — "close evidence and behaviour gaps left by B1–B4" |
| **Under test** | **419** the athlete read-back · **420** the trace ids · **421** the launch instrument · **422** the dates · and **B4** as it has stood since 398 |
| **Written** | patch 420, rewritten whole at 422, 20 August 2026 |
| **ADR** | §12.164 (419), §12.165 (420), §12.166 (421), §12.167 (422), §12.142 for what B4 already proved |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" — all ten parts below |
| **Time** | twenty minutes. **Part 3 needs a Release build from Xcode.** |
| **State** | **Part 1 ran 20 August at patch 420 — one row was unjudgeable and is re-asked here. Parts 2 and 3 are outstanding.** §10 |

Topic 3 has four decomposition items. **Item 1 is code and is done** (419).
**Item 4 needs no action** — load parity stays classified deterministic-only
until B6, which 399 marked and 419 deliberately did not change. **Items 2 and 3
are measurements only a device can take, and this document is them.**

---

## 1. Question and risk

**Three questions. Each has a source the screen under test does not feed.**

### 1.1 Can the athlete read-back now disagree?

Until 419 it compared SQLite against `ConstantsStore.shared`,
`AthleteStore.shared.ftp` and `.hrZones` — all three hydrated from SQLite since
B1. **Twenty-seven comparisons that could not have failed**, printed as
agreement for seventy-three patches. 419 made the app side read `constants.json`
and `athlete.json` through 418's seams.

**The risk:** 419 did not land, or landed and fell back to the stores. Both
print a clean comparison. Only the provenance line separates them.

### 1.2 What does an activity with a zero-length trace actually draw?

`RecordingRepository.all` deliberately returns a **present, zero-length**
`ActivityStreams` for a `recording` row with no samples — *not* nil. Views test
`ActivityStreams.isUsable`, which is `distanceM.count >= 8`. Several do it
correctly. **No device path has exercised the state end to end**, and 398's
device run named this as the one uncovered case (§12.142.6).

**The risk:** an empty chart with axes and no line, a map centred on 0,0, a tab
that draws a flat line at zero, or a crash — §12.76's runtime stack overflow, or
a force-unwrap on an empty series. A chart drawn over nothing reads as *your
heart rate was zero*, which is worse than a missing panel.

### 1.3 What does B4 cost in Release, and does the cost show?

`Detail store built` has only ever been measured in Debug — 0.872 to 1.233 s,
and 0.880 s at 420. §5.6 has owed a Release figure since B4 landed.

**And a construction timestamp is not responsiveness.** A read of the same
length off the main actor costs the same seconds and none of the jank; a shorter
read on the main actor during the first frame costs less and hurts more. 421
added the instrument that separates them. B4's plan expected the large sample
reads to stay off the main actor — **nothing has ever checked that**, and this
is the check.

---

## 2. Build and data identity

**Record these before you start. A figure with no build attached is not
evidence.**

| what | where | expected today |
|---|---|---|
| **Source patch** | Settings → Version | **422** — lower means the files did not reach the project folder; stop |
| **Built** | Settings → Version | a timestamp from this build |
| **Configuration** | Settings → Version | `Debug` for parts 1–2, **`Release` for part 3** |
| **App** | Settings → Version | 1.0 (1) |
| device model, iOS version | Settings → General → About | **write them down** — the campaign has no other record of the hardware |
| timezone | the phone | Europe/Brussels |
| schema | Database health → **The file** → **⬆︎** | **19 migrations**, `Migrations:` identical to `Expected:` |
| tables | Database health → **Rows — N tables** | **52** |
| snapshot | Database health → **Import ledger** | `2026-08-16-211009` |
| dataset | **Import ledger** → last import | **699 activities, 672 traces, 699 details** |
| trace buckets | **Traces still to fetch** | 27 of 699 with no trace — 25 under 500 m, **2 asked-and-empty**, 0 unexplained |

`Integrity: ok`, `Orphaned rows: 0`, `Foreign keys: on` and
`Protection: 7 of 7` are the preconditions. **If any of them has moved, stop and
say so** — this campaign assumes a healthy file and proves nothing over a broken
one.

---

## 3. Safety preconditions

**This campaign is read-only. There is nothing to roll back.**

- **Nothing is written.** No note, no RPE, no match decision, no commute
  decision, no restore, no import. The only actions are opening screens,
  scrolling, rotating and pressing **⬆︎**.
- **Do not press Import, Restore, Fetch now, Verify or Take a snapshot.** A
  backfill would change the very buckets part 2 reads, and an import would move
  the ledger figures §2 just recorded.
- **`Read everything back` IS permitted and step 2 requires it.** `runRollUp`
  calls the nine `ReadBacks` functions and nothing else — it reads the database
  and the files, writes nothing and records no ledger row. It is the one button
  this campaign presses. **Verify is the one that writes**; do not confuse them.
- **No protected snapshot is required**, because nothing is mutated. The
  existing `2026-08-16-211009` stands as the fallback if something unexpected
  happens; do not overwrite it during this campaign.
- **The Release build is a build, not a setting.** It replaces the binary and
  leaves the database, the files and `UserDefaults` alone. Reinstalling in Debug
  afterwards is safe.
- **Rotating the phone is a test, not a risk.** If the app crashes on rotation
  that is row 7 and it is the finding, not an accident.

---

## 4. Exact navigation

Everything is **Settings → Sync & data → Database health** unless stated.
Sections are collapsed by default — **tap the section title to open it**, and
the **⬆︎** beside the title is the export.

### Part 1 — the athlete read-back can now disagree · *steps 1–2*

1. **Database health** → tap **Read-back · athlete** → read the rows → **⬆︎** →
   share the export.
2. Tap **Read-back roll-up**, then **press the `Read everything back` button
   at the top of that section** and wait for it to finish. Then **⬆︎** → share
   the export. Find the **Athlete** row and read what follows the ` · `.
   **The button is not optional.** The roll-up does not run itself: unpressed,
   the section reads `Not rolled up since this launch` and its export is that
   one sentence. Nine read-backs cost real time, which is why it is a press.
   **This is where the provenance line lives.** `ReadBackSource.mark` renders in
   the roll-up, not in the athlete section — the section above compares, this
   one says whether the comparison was independent. They are different questions
   and they are printed in different places.

### Part 2 — an activity with no trace · *steps 3–7*

3. Tap **Traces still to fetch** → **⬆︎** → share the export. Then **look at the
   screen**: the line under `asked, nothing there` reads `<id> · <date>` for
   each activity. **Write down both dates.**
   If it reads `none to name`, this part cannot run today — record that and go
   to part 3.
4. **Week** tab → navigate to the first of those dates → open that day's
   activity detail (tap the activity row).
5. **If the day holds more than one activity, open each of them.** The one under
   test is the one with **no route map and no heart-rate chart** — which is the
   property being tested, so it cannot be used to pick the activity in advance.
   The other identifiers are the distance and the moving time.
6. **Scroll the whole screen slowly, top to bottom.** Look at, in order:
   **HEART RATE** (the zone distribution), **KILOMETRE SPLITS** (both **Km** and
   **Laps**), **PROFILE** — **all four tabs, HR · Pace · Elev · Grade** — and
   **ROUTE**. Screenshot each panel that draws anything.
7. **Rotate the phone to landscape** while on the profile panel, wait for it to
   settle, then rotate back. Then repeat steps 4–7 for the second date.

### Part 3 — the cost, in Release · *steps 8–12*

8. In Xcode, set the run configuration to **Release** and build and install to
   the phone.
9. **Settings → Version** → confirm **Configuration** reads **Release** and
   **Source patch** reads **422**. If it says `Debug`, part 3 measures nothing —
   go back to step 8.
10. **Force-quit the app** (swipe up from the app switcher), then relaunch it by
    tapping the icon. **Then wait at least fifteen seconds without leaving the
    app**, and without pressing anything that starts a sync.
    The stall window is ten seconds long. A reading taken inside it is a floor,
    not an answer. **Do not switch to another app or lock the phone** — the app
    says when that happened, and the reading is then worth nothing.
11. **Database health** → **The file** → read the **Launch** row → **⬆︎** →
    share the export.
12. **Repeat steps 10–11 once more.** One launch is an anecdote.

---

## 5. Independent expected result — where each expectation comes from

**§12.7 of the contract: do not derive the expected answer from the same
database-fed store that supplies the screen being tested.**

| row | what is claimed | the independent source |
|---|---|---|
| 1–2 | the athlete's profile, zones and FTP survived the migration | **`constants.json` and `athlete.json` on disk**, read by `athleteSources()` through 418's seams — files the database does not write to and B1 does not feed |
| 3 | which activities were asked for and came back empty | **`DetailStore`'s work-queue verdicts** (`answeredEmpty`), which are `UserDefaults` and not part of B4's migration at all |
| 4–7 | what the app draws over a zero-length trace | **the SwiftUI source** — `ActivityStreams.isUsable` is `distanceM.count >= 8`, and `ActivityDetailRoute` and `ActivityDetailHR` guard on it. The expectation is the code's own rule; the device says whether it holds |
| 9 | what the read costs | **the Debug figures** — 0.872 / 0.930 / 0.880 s — as the comparison, and 0.443 s of files in Debug and 0.399 s in Release as the two other corners |
| 10–14 | when the app becomes responsive | **the kernel** (`kinfo_proc.p_starttime`) and **the main queue itself** — a 60 Hz timer that cannot fire while the main thread is busy. Neither reads a store |

**Rows 1–2 are the only rows on this campaign whose two sides could previously
not have disagreed.** That is the whole of item 1, and it is why the provenance
line matters more than the counts under it.

---

## 6. App evidence source — the exact lines

| # | screen | section | the line |
|---|---|---|---|
| 1 | Database health | **Read-back · athlete** | `Athlete read-back: N compared`, `fields that differ`, `months that differ`, `zones that differ`, `unexplained differences` |
| 2 | Database health | **Read-back roll-up**, **after pressing `Read everything back`** | the `Athlete` row, everything after ` · ` |
| 3 | Database health | **Traces still to fetch** | `asked, nothing there`, and **on screen** the `<id> · <date>` line beneath it |
| 4–7 | Activity detail | HEART RATE · KILOMETRE SPLITS · PROFILE · ROUTE | **there is no diagnostic** — these rows are screenshots and your own eyes |
| 8 | Settings → Version | — | **Configuration**, **Source patch** |
| 9 | Database health | **The file** → **⬆︎** | `Detail store built: N s from the database — 699 details, 672 traces` |
| 10–14 | Database health | **The file** → **⬆︎** | `Launch:` and the six lines under it |

**Rows 4–7 have no diagnostic and that is not an omission.** The question is
what a person sees, and no number the app prints can answer it.

---

## 7. Pass / fail

| # | after step | where | figure | passes | fails | what the failure means |
|---|---|---|---|---|---|---|
| 0 | 2 | **Read-back roll-up** | the section | nine rows, one per read-back | `Not rolled up since this launch` | **You did not press `Read everything back`.** The export is one sentence and rows 1 and 1b cannot be read. Press it and export again. |
| 1 | 2 | **Read-back roll-up** | the **Athlete** row's mark | `· own read: constants.json and athlete.json, read directly` | `· self-referential: …` | **419 did not land.** Every count in row 2 is the database compared against itself. |
| 1b | 2 | same | same | as above | `· COULD NOT READ ITS OWN SIDE: …` **(red)** | The seams failed to read the two files on this phone. **Not a 419 regression** — report the reason, it names the file. |
| 2 | 1 | **Read-back · athlete** | `compared` / `differ` | **27 compared**, `fields`, `months` and `zones that differ` all `0`, `unexplained differences: 0` | any non-zero difference | **A difference here is now real** and was unreachable before 419. Report which field. `approved differences: 1 (version)` is expected and is not a difference. |
| 3 | 3 | **Traces still to fetch** | `asked, nothing there` | `2`, and beneath it two `<id> · <date>` entries | a count with no dated entries under it | **422 did not land** and part 2 cannot be performed. Check **Source patch** reads 422. |
| 3b | 3 | same | `unexplained` | `0` | ≥ `1` **(red)** | An activity has no trace for a reason nothing in this app has a name for. Not this campaign's subject — **report it**, with the ids now printed beside it. |
| 4 | 6 | activity detail | **HEART RATE** | the panel is **absent**, or present with a clear no-data state | an empty chart with axes and no line, or `avg 0 · max 0` | A chart drawn over nothing reads as "your heart rate was zero". |
| 5 | 6 | activity detail | **PROFILE**, each of HR · Pace · Elev · Grade | absent, or a clear no-data state, **in all four** | empty axes, or a tab drawing a flat line at 0 | `isUsable` is one rule; a zero-length trace must fail it in every tab, **not three of four**. A single bad tab is the finding. |
| 6 | 6 | activity detail | **ROUTE** | **absent** | a map centred on 0,0, on the ocean, or on a single point | The classic zero-coordinate failure. |
| 7 | 6–7 | activity detail | the screen | draws, scrolls and rotates | **a crash** | §12.76's runtime stack overflow, or a force-unwrap on an empty series. **Stop, and report the whole screen and what you last touched.** |
| 7b | 6 | activity detail | **KILOMETRE SPLITS** | splits still draw — they come from `activity_split`, not from the trace | absent | Splits are a different family and a zero-length trace must not take them with it. |
| 8 | 9 | Settings → Version | **Configuration** | `Release` | `Debug` | **Part 3 measures nothing otherwise.** This is exactly why part 3 did not run on 20 August. |
| 9 | 11 | **The file** export | `Detail store built` | **record the number** | — | The figure §5.6 has owed since B4. Debug has run 0.872–1.233 s. There is no pass mark — the number *is* the result. |
| 10 | 11 | **The file** export | `stall window` | `closed — 10.0 s` | `still open — N s` | You read it too early. Wait and export again. **Every stall figure over an open window is a floor, not a maximum.** |
| 11 | 11 | **The file** export | `left the app during the window` | `no` | `YES` **(the line says so in capitals)** | The window is poisoned — the gaps include time the app was not scheduled at all. Relaunch, do not leave the app, and take it again. |
| 12 | 11 | **The file** export | `first free main-thread turn` | **record it** | `not yet — …` | This is what "under two seconds by hand" was reaching for, to three decimal places: the earliest the app could have answered a touch. A `not yet` means the watch never ticked — a 421 defect. |
| 13 | 11 | **The file** export | `longest main-thread stall` | **record it** | — | **The figure a construction timestamp cannot give.** Close to `Detail store built` → that read is on the main actor and **B4's plan did not hold**. Small while `Detail store built` is large → the read is off the main actor and the cost is invisible to the user, which is the intended outcome. |
| 14 | 11 | **The file** export | `before our first line` | **record it** | `could not measure — …` | sysctl refused the process table. The pre-main figure is unavailable on this device; every other row still stands. |
| 15 | 12 | both exports | rows 9 and 12–14 | within a few tenths of each other | wildly different | One launch is an anecdote. A large gap is itself the finding — say which launch was which. |

**Rows 1–8 are pass/fail. Rows 9 and 12–14 are measurements with no pass mark —
write the numbers down. Rows 10, 11 and 15 are what says whether the
measurements can be believed at all.**

---

## 8. Evidence capture

**Keep, and share:**

1. **Four exports** — `Read-back · athlete`, `Read-back roll-up`,
   `Traces still to fetch`, and `The file` **once per Release launch** (two of
   them).
2. **A photo or screenshot of the `<id> · <date>` line**, since the export does
   not carry the dates.
3. **Screenshots of every panel that drew anything** on the two traceless
   activities — and of the panels that did *not* draw, which is harder: capture
   the whole scrolled screen, so an absent panel is visible as absent.
4. **A screenshot of Settings → Version in Release**, as the identity for rows
   9–15.
5. **The times of day** each part was run.

**Redaction.** The exports already omit paths, names, places and dates; they
carry Strava ids and field names, which §12.7 permits. The **screenshots do
not** — an activity detail shows a route over a real map, the session name and
the date. **They are for Bruno's own review and are not pasted into the ADR.**
What reaches the ADR from rows 4–7 is a sentence describing what drew.

---

## 9. Cleanup and rollback

- **Nothing to roll back.** No store was written and no setting changed.
- **Reinstall the Debug build from Xcode** when part 3 is finished, so the next
  session's figures are comparable with the Debug history.
- **Confirm the app came back to where it started**: `Rows — 52 tables`,
  `activity 699`, and `Traces still to fetch: 0` with `27 of 699` and
  `unexplained: 0`. Compare against what §2 recorded at the start.
- **Do not press Verify or Import to "tidy up".** A verification run after a
  Release launch would write a ledger row that this campaign did not intend and
  §2's dataset fingerprint would stop matching.

---

## 10. Result

### 10.1 Part 1, run 20 August 2026, 21:16–21:21, at patch 420

- **Row 2 passes.** 27 compared · profile fields 7 · resting months 15 · zones 5
  · fields, months and zones that differ all 0 · `approved differences: 1
  (version)` · `unexplained differences: 0`. The denominator is real and the
  comparison could have failed.
- **Row 1 could not be judged.** The campaign's first draft named
  **Read-back · athlete** for the provenance line, which renders in
  **Read-back roll-up**. The right screen was exported and the row named did not
  exist on it. **Corrected at 421 (§12.166.4); re-ask it at step 2.**
- **Row 3 passed as far as 420 could take it**: `asked, nothing there: 2`
  followed by `15225521352, 16415953236`.

### 10.2 Part 2 did not run, and finding out why was the day's second lesson

**The activity opened has a full trace** — 9.44 km, a heart-rate series,
`56:12 traced`, a route and best efforts. It is not one of the two.

**The ids were named and could not be reached.** Nothing in this app finds an
activity by Strava id, and every screen lists by date — so a tester holding
`15225521352` had nowhere to tap. The same unperformable step one level down,
and the third instance in six patches (§12.162.5, §12.165, §12.167).

**422 is the fix**: the screen now carries the date beside each id, while the
export still carries ids only. Step 3 was rewritten to use it.

### 10.2a And step 2 was unperformable as first written — 20 August, 22:04

The first attempt at the corrected step returned
`Read-back roll-up: Not rolled up since this launch.` — the whole export.
**The roll-up is a button, and the step did not say to press it.**

Fourth instance in seven patches, and the second inside this one document.
§12.162.5's rule holds without amendment: *a campaign step that cannot be
performed is worse than a missing one.* Row 0 exists so the next reader sees the
sentence and knows what it means rather than reporting it as a failed read-back.

### 10.3 Part 3 did not run

`Configuration` read **Debug**. Rows 8–15 are outstanding, and the Release
`Detail store built` figure §5.6 has owed since B4 is still owed.

### 10.4 Figures recorded in passing, Debug, patch 420

`Bootstrap read: 0.036 s — 7 families` ·
`Detail store built: 0.880 s from the database — 699 details, 672 traces` ·
`Protection: 7 of 7 at the expected class`, 0 failed writes ·
`Integrity: ok`, `Orphaned rows: 0`, `Foreign keys: on` · 19 migrations ·
`activities with no trace: 27 of 699`, unexplained 0.

### 10.5 Outstanding

**Rows 0, 1, 1b, 3, 3b, 4–7, 7b and 8–15.** Run parts 1, 2 and 3 on
**patch 422**. Row 2 has passed and does not need re-running, though pressing
`Read everything back` re-runs it anyway at no cost.

---

## 11. What this campaign does not cover

- **An activity with no `recording` row at all**, as distinct from one with a row
  and no samples. §12.142.6 records that the second is what 398 produced and the
  first is what the code used to see. This campaign exercises the second; the
  first no longer occurs on this device, so **the guard against it is untested
  and stays untested.**
- **Load parity.** Still deterministic-only. Both varied inputs come from
  SQLite, so it proves `LoadSeries` is deterministic rather than that the
  migration carried anything. **Marked, not rescued**, until B6 can give it an
  independent file-side input — topic 3 item 4 asks for exactly that
  classification and no more.
- **Gear.** `activity_gear_reference` holds 503 rows and no read-back compares
  them. B5's, and 419's prompt says not to touch B5 gear behaviour.
- **Whether the Release figure is "good".** There is no target and this campaign
  does not invent one. §5.6 will hold four corners once row 9 lands: files in
  Debug 0.443 s, database in Debug 0.872–1.233 s, files in Release 0.399 s, and
  the database in Release.
- **A stall caused by anything other than launch.** The window is the first ten
  seconds. Jank while scrolling a long week, or during a sync, is not measured
  and would need its own instrument.
- **Any state a Debug build cannot reproduce.** Parts 1 and 2 are run in Debug
  by design — they are about correctness, not cost — so if a rendering defect in
  rows 4–7 only appears under Release optimisation, **this campaign will miss
  it.**
