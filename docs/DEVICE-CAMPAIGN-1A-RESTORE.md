# Device campaign — topic 1A, the authored restore path

| | |
|---|---|
| **Task** | Plan topic 1A — "finish the existing authored-store restore implementation" |
| **Patches under test** | 400, 402, 404, 405, 407 (406's migration rides along) |
| **Written at** | patch 409a, 19 August 2026 |
| **ADR** | §12.144, §12.146, §12.148, §12.149, §12.151 |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" |
| **Time** | about ten minutes, one force-quit |
| **Supersedes** | `docs/DEVICE-CAMPAIGN-1A.md`, written at 408 |

**This replaces the 408 document, and the reason is that running the 409
campaign taught three things it got wrong or could not have known:** which
section a given line actually appears in, that a share sheet backgrounds the
app, and that the read-back's `Only in the app` / `Only in the database` rows
are the sharpest instrument on the screen. Every label, section title and row
name below was read out of the SwiftUI source while writing this.

1A's prompt requires a campaign in as many words — *"Manual campaign required
because restore changes real authored files. Build it before completion."*

---

## 1. Question and risk

**The question.** Does the restore control, pressed on the phone against the
athlete's own four stores, (a) run at all, (b) reach the disk, (c) announce
nothing to the database, and (d) revert nothing?

**What only the device can answer.** Every restore test drives
`init(directory:)` or `UserDefaults(suiteName:)` into a throwaway location —
deliberately, because the singletons point at the real `notes.json`,
`commutes.json`, `moves.json` and the stored match decisions. So
`NotesStore.shared.restore(…)` and its three siblings are **the code path that
runs on the phone and the one path nothing in the suite executes.**

| failure | what it would look like |
|---|---|
| The control writes to memory, not to disk | receipts look right; the repair is gone at the next launch |
| A restore reverts a record edited since the last import | a note's text silently changes back |
| **A restore announces to the database** | `authored` climbs in the ledger, and a repair arrives carrying permission to delete — §12.149 |
| The section will not open | §12.76's runtime stack overflow: compiles clean, passes every test, only appears here |
| The receipts never reach the paste | two exports either side of a press are identical — §12.146, and this actually happened at 401 |

---

## 2. Where everything is

### 2.1 Getting there

**Settings** tab → **Sync & data** (a disclosure row — tap to open) → button
**Database health**. It opens as a sheet.

Inside, the screen is a list of collapsed sections. **Tapping a title expands
it**; the **⬆︎** button to the right of the title exports that section's text
and **works whether or not the section is expanded**.

### 2.2 The four places this campaign reads

| section title | what it gives | how |
|---|---|---|
| **Read-back · authored** | the control, the receipts, and the four stores' counts | rows **and** ⬆︎ |
| **Import ledger** | whether the restore announced | ⬆︎ — read the `authored:` line |
| **The app's own files** | whether the restore *committed* | ⬆︎ — read `Notes reaching the database` |
| **Rows — 51 tables** | the row counts, unchanged either side | ⬆︎ |

**Two of those are export-only.** `Notes reaching the database` and the
`authored:` trigger count are **not rows on the screen** — they exist only in
the text the ⬆︎ produces. Do not go looking for them in the list.

### 2.3 The control and its receipts

Inside **Read-back · authored**, at the top:

- the button **Restore the authored stores from the database**
- while it runs: **Restoring…** with a spinner
- afterwards, one row per store: **Restored** — `notes.json: added 0, already
  held 7`
- if a store's bytes could not be read: *The unreadable bytes were kept as …*
- if a store failed: a red line — `moves.json: NOT RESTORED — …`

### 2.4 The four Notes rows that decide it

Under the subheading **Notes** (and repeated under **Commute decisions**,
**Match decisions** and **Moved sessions**):

| row | reads | why it matters here |
|---|---|---|
| **In each side** | `A vs B` — **A is the file read straight off the disk, B is the database** | the pair a restore reconciles |
| **Only in the app** | count, **red** above zero | the file holds a record the database does not |
| **Only in the database** | count, **red** above zero | **the only state a restore can repair** |
| **Fields that differ** | count, **red** above zero | both hold it and disagree |

**This is what makes `added 0` meaningful rather than lucky.** §12.148.4 records
that every device run so far read `added 0` — which proves the control is safe
and reaches the disk, *not* that it repairs. **The precondition is now stated
and checked:** if `Only in the database` is 0 before the press, then `added 0`
is the **correct** answer, and the campaign proves the control is a no-op
exactly when it should be. Without that row, `added 0` and "the control did
nothing at all" are the same reading.

### 2.5 What NOT to press

**Read-back · weather and gear** has its own restore button. **Weather is B5's,
not 1A's** — leave it alone. Its receipt would appear under a different subject
(`Weather restore:`) and is out of scope here.

---

## 3. Safety preconditions

**"Never use the only copy of authored data for a destructive test."** This
campaign presses a control that writes all four authored files. That is the
point of it, and it is why the preconditions are the longest section.

- **The restore is additive by construction** — `StoreRestore.merge` keeps the
  record the store already holds and only adds ones it lacks. It cannot
  overwrite a note. Read §12.144 before running if you want the argument.
- **Take the four "before" exports first (§4 step 2).** Without them, the
  §12.146 check — did anything reach the paste — cannot be made at all.
- **Confirm `Only in the database` is 0 for all four stores** before pressing.
  If any is non-zero, **stop and report it**: that is a real disagreement
  between file and database, it is the state 1A exists for, and it deserves to
  be understood before a repair tool is pointed at it.
- **Do not press Import** at any point. An import rewrites the rows from the
  stores and would destroy the comparison.
- **Do not press Restore twice.** Once is the test; a second press proves
  nothing new and doubles the exposure.
- Nothing here disconnects Strava, revokes anything, or deletes a note.

---

## 4. Exact navigation

### Before

1. **Settings** → **Version** → **Source patch**. Record it. **It must be
   `409a` or later** — earlier builds lack the `Notes reaching the database`
   line that step 8 reads.
2. **Settings** → **Sync & data** → **Database health**. Then, in order:
   - **Read-back · authored** → tap the title to expand. **The section must
     open without the app dying** — that is row 1, and §12.76 has killed this
     screen twice. Read the four stores' rows. Tap **⬆︎** → export.
   - **Import ledger** → tap **⬆︎** → export. Note the **`authored:`** count.
   - **The app's own files** → tap **⬆︎** → export. Expect **`no note written
     since this launch`**.
   - **Rows — 51 tables** → tap **⬆︎** → export.

### The press

3. Back to **Read-back · authored**. Press **Restore the authored stores from
   the database**.
4. Read the **Restored** rows that appear. There should be **four**.

### After

5. **Read-back · authored** → tap **⬆︎** → export.
6. **Import ledger** → tap **⬆︎** → export.
7. **The app's own files** → tap **⬆︎** → export.
8. **Rows — 51 tables** → tap **⬆︎** → export.

### The relaunch — did it reach the disk

9. **Force-quit.** Swipe up from the bottom and hold, then flick Sub4 away.
10. Relaunch → **Settings** → **Sync & data** → **Database health** →
    **Read-back · authored** → expand → **⬆︎** → export.

    *This is the step that proves the repair is on the disk rather than in
    memory.* A restore that only wrote to memory looks identical to a good one
    until the process dies.

---

## 5. Pass / fail

Counts below are tonight's baseline — **notes 7, commutes 1, moves 2, match
decisions 8.** Substitute whatever step 2 actually reads.

| # | after step | where | figure | passes | fails | what the failure means |
|---|---|---|---|---|---|---|
| 1 | 2 | the screen | **Read-back · authored** expands | the rows draw | the app dies | §12.76's stack overflow. It compiles clean and passes 1,730 tests. **Stop** — this is a crash, not a data finding. |
| 2 | 2 | **Read-back · authored** | **Only in the database**, all four stores | `0` | ≥ `1` **(red)** | **Stop and report.** A genuine file-vs-database disagreement. It is what a restore is *for*, but it should be understood before the tool runs, and it changes what `added` should read in row 5. |
| 3 | 2 | export of **Read-back · authored** | the last line | `Authored restore: not run since this launch.` | anything else | A restore already ran this launch. Force-quit and start again — the receipts you are about to read would be stale. |
| 4 | 4 | the screen | **Restored** rows | **four** of them | fewer, or a red `NOT RESTORED` line | A store was skipped. `moves.json` and `match decisions` each need their own read to have run first; the red line says which. |
| 5 | 4 | the same rows | the four receipts | `added 0, already held 7 / 1 / 2 / 8` | `added` > 0 | Only wrong if row 2 read `0`. **`added 0` is the correct answer when the two sides already agree** — that is what row 2 established. |
| 6 | 5 | export of **Read-back · authored** | the last lines | `Authored restore:` followed by **four** indented receipts | still `not run since this launch.` | **§12.146 exactly, and it happened at 401**: the receipt lives only in view state, so the paste cannot tell a restore that ran from a button nobody pressed. RULE 11 exists because of this. |
| 7 | 6 | export of **Import ledger** | the **`authored:`** count | **unchanged** from step 2 | incremented | **§12.149.** The restore announced to the database, so a repair arrives carrying permission to reconcile — and an `.authored` trigger still permits it across every family. This is topic 1C's subject and the most consequential row here. |
| 8 | 7 | export of **The app's own files** | `Notes reaching the database` | **`no note written since this launch`** | `yes` | **New at 409a, and it is a real check.** A restore must not commit — the rows came *from* the database, so writing them back is the loop §12.144 forbids. `NotesStore.restore` calls `write()`, never `save()` or the commit; a `yes` here means that changed. |
| 9 | 8 | **Rows — 51 tables** | `user_note`, `correction`, `match_decision` | **unchanged** | any moved | The restore wrote to the database. It must only ever write files and `UserDefaults`. (`migration_run` moving by ±1 is normal — see §8.) |
| 10 | 5 | **Read-back · authored** | **In each side**, all four | unchanged from step 2 | changed | The restore altered what the file holds. With `added 0` it should have written the same bytes back. |
| 11 | 10 | export after the relaunch | the four stores' rows | identical to step 5 | changed | **The repair did not reach the disk.** The receipts were about memory. This is the failure the force-quit exists to catch. |
| 12 | 10 | same export | the last line | `Authored restore: not run since this launch.` | the receipts | The receipt survived a relaunch, so it is not per-launch state and cannot be trusted to describe *this* launch. |

**Rows 6, 7 and 8 are the campaign.** Row 5 is the one that looks like the
result and is the least informative of the four.

---

## 6. Evidence capture

**Nine exports**: four before (step 2), four after (steps 5–8), one after the
relaunch (step 10).

**Diff the pairs.** Two exports either side of one action is this project's best
device instrument and has been decisive three times — **401 is this exact
campaign's own history**: an identical pair either side of a press revealed a
receipt that only ever existed on screen. Rows 6 and 7 are both diffs.

Exports carry store names, counts and file names only. **No note text reaches
them** — §12.7.

---

## 7. Cleanup and rollback

**There is nothing to undo, and that is a property of the control rather than
luck.** The restore is additive; with `added 0` it wrote the same records back.
No setting changes, no row is written, no external state is touched.

- **If row 2 fails** (a real disagreement), stop before pressing. Report the
  counts. The repair may well be the right thing to do — but deliberately,
  with the disagreement understood, not as a side effect of a test.
- **If row 6 or 11 fails**, the code is wrong, not the data. Nothing needs
  cleaning up; the files hold what they held.
- **If a store reports `unreadable bytes were kept as …`**, a file could not be
  decoded and has been moved aside rather than overwritten (§12.144). **Do not
  delete that file** — it is the only copy of bytes nobody could read. Report
  the name.

---

## 8. What this does not cover

- **THAT THE RESTORE REPAIRS ANYTHING.** This is the honest limit and it has not
  moved since 408. Every device run reads `added 0`, which proves the control
  is safe, reaches the disk and announces nothing. **Proving it repairs needs
  the file and the database to disagree, and no route exists to make them
  disagree safely on a phone** — deleting a note removes it from both, and 409
  made notes database-first, which closes the gap further rather than opening
  one. That half is the suite's, and **a disposable device fixture is worth
  building before B9.**
- **A failing restore.** Rows 4 and 7 say what one looks like; nothing here
  provokes it. The failure paths are the suite's.
- **`proposals.json`.** B7's, and zero-versus-zero would prove nothing.
- **Weather and gear.** B5's, with their own control — §2.5.
- **`migration_run` moving by ±1** is not a finding. `MigrationLedger.prune`
  keeps the newest 200 automatic runs and 20 interruptions, so each launch
  inserts one and trims to the cap. §12.153.10.

---

## 9. Ordering

**Run this BEFORE any campaign that writes a note**, including
`docs/DEVICE-CAMPAIGN-409.md`. Restore is a repair path: running it afterwards
would rewrite the rows that campaign is judged on, and its own expected result
(`added 0`) depends on the file and the database already agreeing.

---

## 10. RESULT — run 19 August 2026, 22:23–22:28, on 409a

**Twelve of twelve.** Ten exports. `notes 7 · commutes 1 · moves 2 · match
decisions 8`.

| # | figure | reading | verdict |
|---|---|---|---|
| 1 | the section opens | drew, repeatedly | pass — §12.76 did not fire |
| 2 | **Only in the database**, all four | `0 / 0 / 0 / 0` | pass — **the precondition** |
| 3 | before-export's last line | `Authored restore: not run since this launch.` | pass |
| 4 | **Restored** rows | four, no red line | pass |
| 5 | the receipts | `added 0, already held 7 / 1 / 2 / 8` | pass |
| 6 | after-export | `Authored restore:` + **four** indented receipts | **pass — §12.146 closed** |
| 7 | ledger `authored:` | **45 → 45** | **pass — §12.149 closed** |
| 8 | `Notes reaching the database` | `no note written since this launch`, both sides | **pass — it did not commit** |
| 9 | `user_note` / `correction` / `match_decision` | `7 / 3 / 8`, unchanged | pass |
| 10 | **In each side**, all four | unchanged | pass |
| 11 | after the relaunch | all four identical to step 5 | pass — it reached the disk |
| 12 | after the relaunch, last line | `not run since this launch.` | pass — the receipt is per-launch |

**THREE PAIRS OF EXPORTS, AND TWO OF THEM ARE BYTE-IDENTICAL ON PURPOSE.**
The **Import ledger** either side of the press is identical to the character —
same `Last import` timestamp, `257 rows`, `authored: 45`, `runs that removed
rows: 2`. So is the **census**. The **read-back** pair differs by *exactly five
lines* — the `Authored restore:` header and its four receipts, lines 42–46. A
restore that touched data would have moved something in one of the other three
files; nothing moved.

**That is the sharpest form row 7 can take.** §12.149's concern is that a repair
arrives carrying permission to reconcile, and an `.authored` trigger still
permits it across every family (topic 1C). The ledger not moving by one
character is the answer.

**Also unchanged and worth recording:** `newest removal: 2026-08-15T15:25:27Z ·
authored · 1 row` — the restore removed nothing; `runs ever verified: 18`,
newest at patch 392 with `12 independent`, `runs opened since it: 119` (no
Verify pressed since 398, so §5.4's fall to 7 is still owed);
`interrupted, recovered at a later launch: 20`, at the retention cap.

### What this run did NOT establish

Unchanged from §8, and it is the whole reason 1A does not close D7: **every
receipt read `added 0`, which is now known to be the CORRECT answer** — row 2
proved the two sides already agreed — **but a control that repairs and a control
that no-ops are still the same reading here.** The repair half stays the
suite's until a disposable device fixture exists. Before B9.

### One finding, and it is not 1A's

`The app's own files` reads **`Detail and trace files: 0 detail files and 0
trace files, all readable`**. The files are not gone — `DetailStore.save` still
writes them. **Nobody counted them.** `fill()`'s database branch never touches
`tally`, so since 398 flipped B4 the tally has held its default and the line has
printed a clean verdict over a read that never happened. §12.15, §12.54.2, and
the same shape as 409a's vacuous `yes` — third instance in two days. See ADR
§12.154.3.
