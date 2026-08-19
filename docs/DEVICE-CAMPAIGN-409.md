# Device campaign — patch 409, the inverted note mutation

| | |
|---|---|
| **Task** | Plan topic 1B — "database-first mutations, notes only" |
| **Patch under test** | **409a** — 409 plus the tri-state diagnostic (§12.153.9) |
| **Written at** | patch 409, revised at 409a, 19 August 2026 |
| **ADR** | §12.152 (the write), §12.153 (the order), §12.153.9 (the line) |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" |
| **Time** | about twelve minutes, two force-quits |

Every label, section title and row name below was read out of the SwiftUI source
while writing this. Where a figure exists **only in an export** and not as a row
on screen, it says so — that distinction has been got wrong twice.

---

## 1. Question and risk

**The question.** On the phone, does a note save reach `user_note` **before** the
editor closes — and is the database open at that moment at all?

**The risk, worst first:**

1. **The database is not open when `NotesStore` writes.** `NotesStore.shared` is
   built with `ContentView`, which `RootView` defers until the migration
   finishes, so it *should* be open. That is an argument about branch ordering,
   not a measurement. **Symptom if it is wrong: none.** Every note still saves,
   to the file, exactly as at 408. The suite cannot ask this — it hands each
   store a database by construction (§12.153.1).
2. **A real commit refuses where an in-memory one did not.** The suite's
   database is `Sub4Database.inMemory()` after one importer run; the phone's has
   694 activities and every foreign key populated.
3. **The delete resurrects.** The row outliving the file, and the next launch
   hydrating a deleted note back onto the screen. This is the direction `remove`
   was inverted for.

---

## 2. Where everything is

Four screens. Learn these once and the rest of the document is short.

### 2.1 The version

**Settings** tab → scroll to the section headed **Version** → row **Source
patch**.

### 2.2 The Database health screen

**Settings** tab → **Sync & data** (a disclosure row — tap to open it) →
button **Database health**. It opens as a sheet.

### 2.3 Inside Database health

The screen is a list of collapsed sections. **Tapping the title expands it**;
the **⬆︎** button to the right of the title exports that section's text and
**works whether or not the section is expanded**. Four sections matter here:

| section title | what to read | row / line |
|---|---|---|
| **The file** | is the database open at all | row **Prepared** |
| **Rows — N tables** | the authority | row **`user_note`** |
| **Read-back · authored** | file vs database | subheading **Notes**, five rows |
| **The app's own files** | did the last save reach SQLite | **export only** — see below |

**`Notes reaching the database` is NOT a row on the screen.** It is a line in
the text you get from the **⬆︎** beside **The app's own files**. Tap the arrow,
share the file to yourself, and read it — the line sits just after the write
journal's lines. Do not go looking for it in the list; it is not there.

**It has three readings, and it is scoped to ONE LAUNCH — 409a.** It reports
the last note written *in this run of the app*, and a relaunch resets it:

| reading | means |
|---|---|
| `no note written since this launch` | nothing has been saved or deleted yet. **Not a fault** |
| `yes` | the last one committed to SQLite before it was published |
| `NO — the last one went to the file only` | it went to the file with no database open |

**409 got this wrong and this campaign is what found it.** The line was a
two-valued flag, so a launch that had written nothing printed `yes` — identical
to a successful save. Step 8 below reads it after a force-quit, where nothing
has been written, so **the check could only ever pass.** That is why 409a
exists, and why the campaign now reads the line at three different moments
instead of one.

### 2.4 The Notes rows, which are the instrument

Under **Read-back · authored**, after the subheading **Notes**:

| row | reads | why it matters here |
|---|---|---|
| **In each side** | `A vs B` — **A is `notes.json` read straight off the disk, B is `user_note`** | the exact pair 409 reorders |
| **Only in the app** | count, turns **red** above zero | the file has a note the database does not |
| **Only in the database** | count, **red** above zero | the database has one the file does not |
| **Fields that differ** | count, **red** above zero | both sides hold it and disagree |
| **Carrying an RPE** | `x vs y` | the RPE reached the row, not just the note |

**Why this is real evidence and the note card is not.** `Read-back · authored`
builds its own `NotesStore(directory:)` and reads the file directly (356). The
note card reads `NotesStore.shared`, which B2 hydrates **from the database** —
so after a relaunch the card and the rows are the same reader twice and cannot
disagree. *When two app screens both read the same hydrated store, they are not
independent sources.*

### 2.5 The note itself

**Today** tab → tap a **completed** session (one with a matched activity) — the
activity detail opens → scroll to the note card.

- With no note it reads **Add a note**, with the caption *effort · how it felt*
- With one it reads **Note**, and shows the RPE pill and the text

Tapping either opens a sheet titled **Note**, with **Cancel** and **Save** in the
navigation bar and a **Delete** button below. **This is the only place in the app
a note can be written.**

If a save is refused you get an alert offering **Copy the text**, **Try again**
and **Keep editing** — see row 2 of §5.

---

## 3. Safety preconditions

**Never use the only copy of authored data for a destructive test.**

- **Pick a session whose card reads "Add a note".** A session already showing a
  **Note** card is out of scope — do not open, edit or delete it. The note this
  campaign creates is the only note it touches.
- **Take the three "before" exports (§4 step 2) first.** Without them every
  later figure is a number with nothing to compare against.
- **Do not press Import** at any point. An import rewrites the rows from the
  stores and would mask exactly what is being measured.
- Nothing here presses **Restore**, disconnects Strava, revokes anything or
  touches external state.

---

## 4. Exact navigation

### Before

1. **Settings** → **Version** → **Source patch**. **It must read `409a`.**
   *If it does not, stop* — a run against 409 or 408 proves nothing about this
   build, and on screen the three are indistinguishable.
2. **Settings** → **Sync & data** → **Database health**. Then, in order:
   - **The file** → tap the title → read **Prepared** → tap **⬆︎** → export
   - **Rows — 51 tables** → tap the title → scroll to **`user_note`** → **write
     the number down; it is `N`** → tap **⬆︎** → export
   - **Read-back · authored** → tap the title → read the five **Notes** rows →
     tap **⬆︎** → export
   - **The app's own files** → tap **⬆︎** → export. **Expect `no note written
     since this launch`** — this is the reading that proves the line is not
     stuck on `yes`.

### The save, and the force-quit

3. Close the sheet. **Today** tab → tap a **completed** session.
4. Scroll to the note card. **It must read "Add a note".** Tap it.
5. In the sheet titled **Note**: set **RPE** to `5`, pick any **feel**, type
   `409 campaign` in the text field.
6. Tap **Save**. The sheet should close with no alert.
7. **Force-quit immediately.** Swipe up from the bottom and hold, then flick
   Sub4 away. **Do not background the app first, do not open the share sheet,
   and do not visit another screen.**

   *This step is the campaign.* The force-quit before any background
   write-through can run is the only way to reproduce the window 1B is about;
   letting the app background itself would let the write-through import cover
   for a commit that never happened. **Opening a share sheet backgrounds the
   app**, which is why every export waits until after this step.

### After the force-quit — the durable evidence

8. Relaunch. **Settings** → **Sync & data** → **Database health**:
   - **Rows — 51 tables** → **`user_note`** → **⬆︎** → export
   - **Read-back · authored** → expand → the five **Notes** rows → **⬆︎** → export
   - **The app's own files** → **⬆︎** → export. **Expect `no note written since
     this launch` again** — the relaunch reset it, and that is the honest
     answer. It is *not* evidence about the save; steps 9–11 are.
9. **Today** → the same session → the note card should read **Note**, **RPE 5**,
   `409 campaign`.

### The edit — the line's only `yes`, and a case nothing has covered

10. Tap the **Note** card. Change the text to `409 campaign edited`. Tap **Save**.
    **Do not force-quit.**

    This is the only way to see the line say `yes`, because it is scoped to one
    launch. It also covers something no test and no earlier campaign has: **an
    edit of a note that came back from the database rather than one written in
    the same session** — the suite's controls all create and edit inside one
    process.
11. **Settings** → **Sync & data** → **Database health**:
    - **The app's own files** → **⬆︎** → export. **Expect `yes`.**
    - **Read-back · authored** → expand → the **Notes** rows → **⬆︎** → export

### The delete

12. **Today** → the same session → tap the **Note** card → **Delete** → confirm.
13. **Force-quit immediately** again.
14. Relaunch → **Today** → the same session → read the note card.
15. **Settings** → **Sync & data** → **Database health**:
    - **Read-back · authored** → expand → the **Notes** rows → **⬆︎** → export
    - **Rows — 51 tables** → **`user_note`** → **⬆︎** → export

---

## 5. Pass / fail

`N` is the `user_note` count from step 2.

| # | after step | where | figure | passes | fails | what the failure means |
|---|---|---|---|---|---|---|
| 1 | 2 | **The file** | **Prepared** | `at launch` | `by this screen` **(red)** | The gate did not open the database. **Stop.** Nothing about 409 can be tested until the launch does. |
| 2 | 2 | export of **The app's own files** | the line | `no note written since this launch` | `yes` | 409a did not land — the line is still the two-valued flag, and every later reading of it is worthless. Check **Source patch** reads `409a`. |
| 3 | 6 | the sheet | it closes | closes, no alert | an alert offering **Copy the text** / **Try again** / **Keep editing** | The commit was refused (risk 2). **Tap Copy the text first** — the sheet may hold the only copy of what you typed. The alert names what refused. |
| 4 | 8 | **Rows — 51 tables** | **`user_note`** | **N + 1** | **N** | **The core failure.** The editor closed on a note SQLite never took, and the force-quit is what a real interruption looks like. A raw `COUNT(*)`, so it is the least deniable reading on the phone. |
| 5 | 8 | **Read-back · authored** → **Notes** | **In each side** | `N+1 vs N+1` | `N+1 vs N` | Row 4 from the read-back rather than the census — the file took it, the database did not. **This is the pre-409 signature.** |
| 6 | 8 | same | **Only in the app** | `0` | `1` **(red)** | Rows 4–5 named from the other end. These three always fire together. |
| 7 | 8 | same | **Only in the database** | `0` | `1` **(red)** | The commit landed and the mirror did not. **Not a 409 failure** — this is the designed behaviour when `notes.json` cannot be written. Report it; it should come with an unsaved-store entry in **Settings**. |
| 8 | 8 | same | **Fields that differ** | `0` | ≥ `1` **(red)** | Both sides hold it and disagree — the mirror wrote a different version from the row. Nothing in 409 should produce this. |
| 9 | 8 | same | **Carrying an RPE** | `x vs x` (equal) | unequal **(red)** | The note reached the row without its RPE. Slice 3's sRPE depends on this. |
| 10 | 8 | export of **The app's own files** | the line | `no note written since this launch` | `yes` **or** `NO` | Either would mean the flag survived a relaunch, which it must not — it is per-launch by construction. A `NO` here is the more alarming of the two. |
| 11 | 9 | the note card | **Note**, RPE 5, `409 campaign` | shows it | reads **Add a note** | The note is gone after a relaunch — commit and mirror both missed. Worse than row 4 and it subsumes it. |
| 12 | 11 | export of **The app's own files** | the line | **`yes`** | `NO — the last one went to the file only` | **Risk 1, confirmed:** the database was shut when the note committed, so the save fell back to the file. Everything else may still look fine, which is exactly why this line exists. |
| 13 | 11 | **Read-back · authored** → **Notes** | **In each side** / **Fields that differ** | `N+1 vs N+1` / `0` | anything else | The **edit** did not reach both sides. This is the case nothing else covers — an edit of a note that came back from the database. |
| 14 | 14 | the note card | **Add a note** | reads it | reads **Note** | **The resurrection.** A note you deleted came back at the next launch. `remove` is still effectively file-first — the failure 409 exists to prevent. |
| 15 | 15 | **Rows — 51 tables** | **`user_note`** | `N` | `N + 1` | The delete did not reach the rows. Row 14 follows from it. |
| 16 | 15 | **Read-back · authored** → **Notes** | **In each side** | `N vs N` | `N vs N+1` | Row 15 from the read-back. |

**Rows 4, 12 and 14 are the campaign.** The rest tell you *where* it broke when
one of those three fires.

---

## 6. Evidence capture

**Seven exports**: four before (steps 2), three after the save (step 8), two
after the delete (step 13) — nine if you keep both census reads separate.

**Diff the pairs.** Two exports either side of one action is this project's best
device instrument and has been decisive three times — 401 (an identical pair
exposed a receipt that only ever existed on screen), 404, 405. A byte-identical
**Read-back · authored** pair either side of step 6 means the save did nothing
at all, which no single reading can tell you.

The exports carry store names, counts and file names only. **No note text
reaches them** — §12.7. `409 campaign` is typed into the app and stays there.

---

## 7. Cleanup and rollback

Steps 10–13 **are** the cleanup: the note created by this campaign is the note it
deletes, and rows 11–13 verify the deletion landed on both sides.

- **If it is abandoned part-way**, the note remains. Delete it by hand (step 10)
  and confirm `user_note` is back to `N`.
- **If row 1 or row 2 fails**, stop and change nothing. Both are findings about
  the launch, not about the note, and pressing on only leaves a file-only note to
  clean up afterwards.
- Nothing else needs undoing — no setting changed, no store restored, no
  external state touched.

---

## 8. What this does not cover

Stated, because a campaign that does not say what it missed reads as having
covered everything.

- **A termination *inside* the commit.** Step 7 kills the app between the commit
  and the mirror, which is the window 1B names. It cannot kill it *during* the
  SQLite transaction; that durability is GRDB's and is taken on trust.
- **A refusal from the real database.** Row 3 says what one looks like, and
  there is no safe way to provoke one on the phone — the editor clamps RPE to
  1–10, which is the constraint the suite's control violates directly. **The
  refusal path is the suite's, not the device's.**
- **A mirror failure on the phone.** Making `notes.json` unwritable means
  damaging the container. Controls 3 and 5 cover it in the suite; row 6 above is
  what it would look like if it happened by itself.
- **A note the athlete wrote before today.** §3 forbids using one, so the
  campaign creates its own. **Step 10 does now cover an edit of a note that came
  back from the database** — the case the suite cannot reach, since its controls
  create and edit inside one process — but the note being edited is one this
  campaign wrote minutes earlier, not one that has lived through an import.
- **A commit failing while the line still says `yes`.** The line reports the
  last write; it is not a running tally. Two saves where the first reached the
  database and the second did not will read `NO`, correctly — but two where the
  first missed and the second reached will read `yes`, and the earlier gap is
  visible only in the read-back's counts.
- **The other three authored stores.** 1B is notes only, by design. Commutes,
  match decisions and plan moves are still file-first.

---

## 9. If you are running 1A in the same sitting

`docs/DEVICE-CAMPAIGN-1A.md` is also written and unrun, and it uses the same
screen. **Run 1A first.** It presses **Restore the authored stores from the
database**, which is a repair path — doing it after this campaign would rewrite
the very rows 409 is being judged on, and its own expected result (`added 0`)
depends on the file and the database already agreeing.

---

## 10. RESULT — run 19 August 2026, 21:44–21:59, on 409a

**Sixteen of sixteen.** Subject: **Strength B · core only, 7 August**, a session
whose card read *Add a note*. `N = 7`. Twelve exports; the note text used was
`409` then `409 - campaign edited`.

| # | figure | reading | verdict |
|---|---|---|---|
| 1 | **Prepared** | `at launch` | pass |
| 2 | the line, before | `no note written since this launch` | pass — 409a landed |
| 3 | the sheet on Save | closed, no alert | pass |
| 4 | **`user_note`** after force-quit | **8** | **pass — the core row** |
| 5 | **In each side** | **8 vs 8** | pass |
| 6 | Only in the app | 0 | pass |
| 7 | Only in the database | 0 | pass |
| 8 | Fields that differ | 0 | pass |
| 9 | Carrying an RPE | 8 vs 8 | pass |
| 10 | the line, after relaunch | `no note written since this launch` | pass — per-launch confirmed |
| 11 | the note card | **Note**, RPE 5, `409` | pass |
| 12 | the line, after the edit | **`yes`** | **pass — risk 1 closed** |
| 13 | In each side / differ, after the edit | 8 vs 8 / 0 | pass — the edit reached both |
| 14 | the card after delete + relaunch | **Add a note** | **pass — no resurrection** |
| 15 | **`user_note`** after delete | **7** | pass |
| 16 | In each side after delete | 7 vs 7 | pass |

`note fields compared` tracked 35 → 40 → 35, which is the fifth field of the
eighth note arriving and leaving.

**One number needs its explanation recorded.** `migration_run` read **257 → 256
→ 257** across the three census exports. A ledger count going down is worth
stopping on, and this one is `MigrationLedger.prune` at its ceiling —
`keepAutomaticRuns = 200`, `keepAutomaticInterruptedRuns = 20`, plus what is
never pruned — with this campaign's two force-quits adding two interrupted runs.
Steady-state churn, not loss. ADR §12.153.10.

**Cleanup completed by the campaign itself** — the note it created is the note it
deleted, and rows 15–16 confirm both sides are back to 7.

