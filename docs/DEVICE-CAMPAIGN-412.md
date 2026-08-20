# Device campaign — patch 412, the other three families invert

| | |
|---|---|
| **Task** | Plan topic 1B — database-first mutations, the three families after the notes |
| **Patches under test** | 411 (the narrow writes), **412** (the order) |
| **Written at** | patch 412, 19 August 2026 |
| **ADR** | §12.156, §12.157 |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" |
| **Time** | about fifteen minutes, three force-quits |
| **Run AFTER** | `DEVICE-CAMPAIGN-1A-RESTORE.md`, which is a repair path |

409's campaign with three families in it. The mechanism is proven — that one
passed sixteen of sixteen — so this is about **each family's specifics**: a
control with no label, a sheet that writes two families at once, and a store
that cannot report a refusal.

---

## 1. Question and risk

**The question.** Do a commute decision, a moved session and a match decision
each reach SQLite **before** the control appears to take — and does clearing one
reach the rows, so it cannot come back at the next launch?

**Three risks, and the third is new:**

1. **The commit does not happen.** Same as 409's, three times over. The window
   is between the control taking and the fire-and-forget import committing.
2. **The clear resurrects.** The row outliving the file, and B2 hydrating the
   decision back. For a commute this returns a ride to the distance rule
   *silently*; for a match decision it re-attaches an activity the athlete
   detached.
3. **`Matcher` cannot report a refusal.** `setOverride` returns Void, so a
   refused commit shows up as **the control not sticking** and nothing else —
   no alert, no message. §12.19's disclosed gap, and §12.157.3.

---

## 2. Where everything is

### 2.1 The screens (all labels read from the source)

| family | where | the control |
|---|---|---|
| **Commute decision** | an activity's detail → the row headed **Commute** | a **bicycle glyph** — filled and tinted means *is a commute*, outline and dim means *is not*. It has no text label; the ⓘ beside it explains the rule |
| **Match decision** | the sheet titled **Fix match** | reached from **Today** (a session row), or **Change match** at the top right of an activity sheet, or **Change** / **Match…** on a session detail |
| **Moved session** | the sheet titled **Which session?** | choosing a session moves it to the activity's day; choosing the one the plan already holds *removes* the move (`putBack`) |

**The match picker writes TWO families.** Choosing a session in **Which
session?** can write a `correction` row (the move) while **Fix match** writes the
`match_decision` row. They are separate tables and separate rows; the campaign
reads both.

**One known defect is in the way** — §5.5's first entry: the picker offers
activities the matcher will refuse. **Do not use a walk or anything that is not
plan-eligible** as the override; that failure is older than this patch and would
muddy the reading.

### 2.2 The diagnostics

Database health is **Settings → Sync & data → Database health**. Tapping a
section title expands it; the **⬆︎** exports whether or not it is expanded.

| what | where |
|---|---|
| the authority | **Rows — 51 tables** → `correction`, `match_decision` |
| file vs database | **Read-back · authored** → the four subheadings |
| did it commit | **The app's own files** → ⬆︎ → `Authored writes reaching the database` |
| did it announce | **Import ledger** → ⬆︎ → the `authored:` count |

**`Authored writes reaching the database` is new at 412 and names families.**
Three readings: `no record written since this launch`, `yes`, or
`NO — commutes, moved sessions went to the file only`. It is **export-only**,
scoped to one launch, and reset by a relaunch.

### 2.3 The instrument

**Read-back · authored** builds its own stores over `commutes.json`,
`moves.json` and the stored decisions and reads them **directly**, so its two
sides are the files and the database — the pair 412 reorders. Under each of
**Commute decisions**, **Match decisions** and **Moved sessions**:

- **In each side** — `A vs B`, file versus rows
- **Only in the app** — red above zero: **the pre-412 signature**
- **Only in the database** — red above zero: the mirror did not land (designed)
- **Fields that differ** — red above zero

The screens themselves are not evidence: they read the hydrated stores.

---

## 3. Safety preconditions

- **Use an activity and a session you are willing to change**, and change them
  back. Every step here is reversible by hand and the campaign ends by undoing
  what it did.
- **Take the four "before" exports first** (§4 step 2).
- **Do not press Import or Restore** at any point.
- **Record `correction` and `match_decision` from the census before you start** —
  they are `C` and `M` below. On 19 August they were **3** and **8**.
- The `correction` count covers **both** commutes and moves, so read the
  read-back's per-family rows for the split.

---

## 4. Exact navigation

### Before

1. **Settings** → **Version** → **Source patch**. **It must read `412`.**
2. **Database health**, exporting each with **⬆︎**:
   - **Rows — 51 tables** → record `correction` = **C**, `match_decision` = **M**
   - **Read-back · authored** → expand → read all four families' rows
   - **The app's own files** → expect `no record written since this launch`
   - **Import ledger** → record the **`authored:`** count

### The commute

3. **Today** → a completed **ride** → its detail → the row headed **Commute**.
4. Tap the **bicycle glyph**. It should fill and tint (or empty and dim).
5. **Force-quit immediately** — no share sheet, no other screen.
6. Relaunch → the same activity → **the glyph must still show what you set.**
7. **Database health** → **Rows — 51 tables** → `correction` should be **C + 1**
   (or **C** if you turned an existing decision off — read the read-back's
   *Commute decisions · In each side* instead, it is the unambiguous one).

### The match decision and the move

8. **Today** → a session → open the match picker (**Fix match**) → choose a
   **plan-eligible** activity from a different day.
9. If the picker offers **Which session?**, choose the session, which writes the
   move as well.
10. **Force-quit immediately.**
11. Relaunch → the session should still show the match you chose.
12. **Database health** → **Rows — 51 tables** → `match_decision` = **M + 1**;
    **Read-back · authored** → **Match decisions** and **Moved sessions** rows.

### The line, in one launch

13. Without force-quitting, change one more commute decision, then
    **The app's own files** → **⬆︎**. **Expect `yes`.**

### Undo, and the resurrection check

14. Set the commute glyph back to what it was; clear the match override
    (**Change** → the original, or the picker's *put back*).
15. **Force-quit immediately.**
16. Relaunch → the glyph and the match must read as they did at step 2.
17. **Database health** → **Rows — 51 tables** → `correction` = **C**,
    `match_decision` = **M**; **Read-back · authored** back to the step-2 figures.

---

## 5. Pass / fail

| # | after step | figure | passes | fails | meaning |
|---|---|---|---|---|---|
| 1 | 2 | **The app's own files** line | `no record written since this launch` | `yes` | 412 did not land, or the line is not per-launch. |
| 2 | 4 | the glyph | changes | reverts, or an alert | An alert names a `StoreWriteError` — the commit refused. Report the text. |
| 3 | 6 | the glyph after relaunch | as you set it | reverts | **The core failure**: the control took, the database did not, and the force-quit is a real interruption. |
| 4 | 7 | **Commute decisions · In each side** | both sides moved together | `N+1 vs N` | The file took it and the rows did not — **the pre-412 signature**. |
| 5 | 7 | **Commute decisions · Only in the app** | `0` | `1` **(red)** | Row 4 named from the other end. |
| 6 | 11 | the session's match | as you chose | reverted | Same as row 3, for `Matcher` — and remember **a refusal here looks exactly like this**, with no alert. Row 8 is what tells them apart. |
| 7 | 12 | `match_decision` | **M + 1** | **M** | The decision never reached the rows. |
| 8 | 12 | **Match decisions · Only in the app** | `0` | `1` **(red)** | The blob took it and the table did not — distinguishes "refused" (row 6 with *nothing* written anywhere) from "committed but unmirrored". |
| 9 | 12 | **Moved sessions · In each side** | both sides moved | one side only | The move went to `moves.json` or to `correction` but not both. |
| 10 | 13 | **The app's own files** line | **`yes`** | `NO — …` | The named families went to the file only: the database was shut at write time. |
| 11 | 16 | the glyph and the match | as at step 2 | either has come back | **The resurrection.** A cleared decision returned at the next launch, which is the direction 412 exists for. |
| 12 | 17 | `correction` and `match_decision` | **C** and **M** | higher | The clears did not reach the rows. Row 11 follows from it. |
| 13 | throughout | **Import ledger** `authored:` | rises normally with saves | — | Informational: 412 does **not** change the announcement (§12.157.6), so this still climbs. It is 1C's subject, not a failure here. |

**Rows 3, 6 and 11 are the campaign.**

---

## 6. What this does not cover

- **A refusal from the real database.** The controls drop a table to reach that
  branch (§12.157.5); there is no safe way on a phone, and `correction`'s only
  CHECK is one the repository owns.
- **Telling a refusal from a shut database in `Matcher`, by eye.** Both look
  like the control not sticking. Row 8 separates them from the exports, which is
  the best the medium allows — §12.19.
- **A mirror failure on the phone.** The suite's controls 3 and 5 cover it.
- **A move without a match decision.** The only route to `moves.json` is the
  match picker, so the two are written together; the suite exercises the move
  alone.
- **The termination inside the transaction.** GRDB's, taken on trust.

---

## 7. RESULT — run 20 August 2026, 07:09–07:39, twelve of twelve

`C = 4`, `M = 8` at the start. Five census exports, two read-backs, three
force-quits.

| # | figure | reading | verdict |
|---|---|---|---|
| 1 | the line, before | `no record written since this launch` | pass — not stuck |
| 2 | the glyph | took | pass |
| 3 | the glyph after relaunch | held | pass |
| 4 | **Commute decisions · In each side** | 1 vs 1 → **3 vs 3** | pass |
| 5 | Only in the app | `0` | pass |
| 6 | the match after relaunch | held | pass |
| 7 | **`match_decision`** | 8 → **9** | pass |
| 8 | Match decisions · Only in the app | `0` | pass |
| 9 | **Moved sessions · In each side** | 2 vs 2 → **3 vs 3** | pass |
| 10 | the line, in-launch | **`yes`** | pass — the database is open at write time |
| 11 | after two force-quits | the state held both times | pass |
| 12 | **`correction` after a clear + force-quit** | 6 → **5** | **pass — the delete reached the rows** |
| 13 | ledger `authored:` | 43, moving normally | informational |

`unexplained differences: 0` throughout; `only in the database` and `fields that
differ` zero at every checkpoint.

**A bonus:** `Load` moved 99 → 105 TRIMP when a ride left the commutes and back
again when it returned — the decision propagating through the load model in both
directions.

### Two things the run taught the campaign

**§4 did not name a control that actually deletes.** Nothing in the first thirty
minutes removed a row: the glyph put back writes `isCommute = true`, and the
match put back rewrote the override (`match_decision` stayed at 9, which is how
we know). **`Back to Thursday 20 August` — `Correction.putBack` — is the one
device-reachable delete**, and without it row 12 would have been recorded as
uncovered. A campaign that tests a clear must name the control that deletes.

**A `correction` row was invisible for part of the run.** At 07:10 the census
said 4 and the read-back accounted for 3; by 07:28 both said 6. The readers
gained three while the table gained two, so a row that could not be seen became
visible, and **nothing reported either event**. Cause unproven — ADR §12.157.9
has the candidates. The fix is a residual line, and it is 413.
