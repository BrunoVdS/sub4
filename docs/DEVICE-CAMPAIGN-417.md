# Device campaign — patch 417, the protection class as measured

| | |
|---|---|
| **Task** | Plan topic 2 — "verify storage protection instead of asserting it" |
| **Patch under test** | **417**. 418 brings the last two stores under the unclean-read guard. |
| **Written at** | patch 417, 20 August 2026 |
| **ADR** | §12.162 |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" |
| **Time** | about five minutes |
| **Device** | **mandatory, and a physical one** |

**The suite cannot do this and says so.** On a simulator
`setAttributes([.protectionKey: …])` stores nothing and fails at nothing — not
even for a directory that does not exist. Two of the reader's four answers and
one of the writer's two are unreachable there (§12.162.3). **Everything below is
the part only a real, locked phone can answer.**

---

## 1. Question and risk

**The question.** Are the app's files actually at
`.completeUntilFirstUserAuthentication` on this phone — measured, not asserted?

**The risk.** Until 417 the screen printed `Until first unlock` as a **string
literal** and `FileProtection.protect` swallowed its failure with `try?`. So:

1. **The attribute may never have applied** to some or all items, and nothing
   could have said so.
2. **A file at the wrong class is worse than one at none.** `.complete` breaks
   background writes while the phone is locked — the app would quietly stop
   updating — which is why this app chose `.completeUntilFirstUserAuthentication`
   and why row 4 exists.

---

## 2. Where everything is

**Settings → Sync & data → Database health → The file.**

| what | where |
|---|---|
| the summary | the row **Protection**, now `N of 7 at the expected class`, **red unless N = 7** |
| the seven readings | the **⬆︎** export of **The file**, one line each |
| failed writes | the same export, `protection writes that failed this launch: N` |

**The readings carry names, not paths** — *the database file*, *details/*,
*snapshots/*, *notes.json* — because a container path names the device's user
(§12.7).

Each reads one of four things:

| reading | means |
|---|---|
| `until first unlock` | the expected class |
| `NOT the expected class — <what>` | protected, wrongly. **The interesting failure** |
| `no protection attribute` | the sweep never reached this item |
| `could not inspect — <why>` | the item is missing or unreadable — **not the same as having no attribute** |

---

## 3. Safety preconditions

- **Read-only.** Nothing here writes a file, changes a class, or touches your
  data. The one write is the app's own sweep, which runs at every launch anyway.
- **Do not use a real file to test the failure states.** Rows 6 and 7 use a
  fixture, per the prompt: *"record 'no attribute' and inspection-failure
  rendering using a test fixture rather than weakening real user files."* Those
  two rows are the **suite's**, and §6 says so.
- **Do not change the protection class.** If a row reads `NOT the expected
  class`, that is the finding — report it, do not fix it by hand.

---

## 4. Exact navigation

### There is no before-unlock reading, and this document used to imply one

**Cut at the first run, 20 August.** The original step 1 was *"restart the phone,
do not unlock it"*, under a heading promising a reading. **There is nothing to
read.** The app cannot run before the first unlock — that is what the protection
class means — so no screen, no export and no observation exists in that window.

What would show it is something running **outside** the app: a background
refresh landing before first unlock, where the files are unreadable and the
write fails. Nobody can schedule that, and §6 already declines to claim it.

**What a restart IS worth, and the first run did it:** install, shut down, start
up, then read. `applyToExistingFiles` runs at every launch, so the readings then
describe a **complete sweep from cold** rather than a value left over from an
earlier session — and `protection writes that failed this launch` counts one
boot. Worth doing. Just do not expect to read anything before you unlock.

### The measurement

1. **Settings** → **Sync & data** → **Database health**.
2. **The file** → tap the title → read the **Protection** row.
3. Tap **⬆︎** → export.

### After a background cycle

4. Leave Sub4 (Home), wait ~30 seconds, come back.
5. **Database health** → **The file** → **⬆︎** → export.

---

## 5. Pass / fail

| # | after step | figure | passes | fails | meaning |
|---|---|---|---|---|---|
| 1 | 2 | **Protection** row | **`7 of 7 at the expected class`**, not red | fewer, red | At least one item is not protected as intended. Rows 3–5 say which. |
| 2 | 3 | `protection writes that failed this launch` | **`0`** | ≥ 1, with a message | The sweep could not set the attribute somewhere. **This line did not exist before 417** — the failure was swallowed by `try?`. Report the message. |
| 3 | 3 | *the database file*, *the database's folder* | `until first unlock` | anything else | The database holds every activity, note and decision. This is the row that matters most. |
| 4 | 3 | any item | not `NOT the expected class` | `NOT the expected class — complete` | **The interesting failure.** `.complete` would break background writes while the phone is locked — the app would quietly stop updating. Worse than no protection, and the reason the reader has four states rather than three. |
| 5 | 3 | *details/*, *streams/*, *snapshots/*, *notes.json* | `until first unlock` | `no protection attribute` | The sweep never reached it. `applyToExistingFiles` walks Application Support at every launch, so an item it missed is a real gap. |
| 6 | 3 | any item | not `could not inspect` | `could not inspect — …` | The item is missing or unreadable. For *details/* on a phone holding 698 detail files, that is a finding about the files, not about protection. |
| 7 | 5 | the whole export | identical to step 6 | any reading changed | Protection is set at write time and swept at launch; a backgrounding should move nothing. A change here means something is re-writing the class. |

**Rows 1, 3 and 4 are the campaign.**

---

## 6. What this does not cover

- **`no attribute` and `could not inspect` as RENDERINGS.** The prompt asks for
  those to be exercised with a fixture rather than by weakening a real file, and
  they are — `inspectionFailureIsNotAbsence` and the `classify` tests. On a
  healthy phone rows 5 and 6 should never fire, so this campaign observes their
  absence, not their appearance.
- **Whether the class actually protects anything.** That is iOS's guarantee,
  not this app's. The campaign proves the attribute is *set*; the encryption
  behind it is Apple's.
- **ANYTHING BEFORE THE FIRST UNLOCK.** The prompt asks for
  before-first-unlock behaviour *"where safe"*, and the answer found by running
  this is that **it is not observable from inside the app at all** — the app
  cannot run in that window, which is precisely what the class guarantees. It
  would take a background refresh landing there, which nobody can schedule.
  **Not covered, not claimable, and the step that pretended otherwise is gone.**
- **The locked-phone write path.** `FileProtection`'s header argues `.complete`
  would break background writes and `.completeUntilFirstUserAuthentication` does
  not. Proving that needs the same unschedulable window. Not covered.
- **The two unguarded stores.** `AthleteStore` and `AthleteConstants` are still
  outside the unclean-read write contract and `UNPROTECTED_STORE_CEILING` is 2.
  That is **418**, and it is the suite's.

---

## 7. RESULT — run 20 August 2026, 19:04–19:23, six of seven; the seventh needs no restart

**Installed, shut down, started up, then read** — so these are a complete
launch sweep from cold, not a leftover from an earlier session.

**Seven of seven at the expected class**, measured with `attributesOfItem`:

```
Protection: 7 of 7 at the expected class
  Application Support: until first unlock
  the database's folder: until first unlock
  the database file: until first unlock
  details/: until first unlock
  streams/: until first unlock
  snapshots/: until first unlock
  notes.json: until first unlock
  protection writes that failed this launch: 0
```

| # | figure | reading | verdict |
|---|---|---|---|
| 1 | **Protection** row | `7 of 7 at the expected class`, not red | pass |
| 2 | failed writes | **0** | pass — a line that did not exist before 417 |
| 3 | the database file and its folder | `until first unlock` | pass |
| 4 | any `NOT the expected class` | none | pass — the interesting failure did not fire |
| 5 | `details/`, `streams/`, `snapshots/`, `notes.json` | `until first unlock` | pass |
| 6 | any `could not inspect` | none | pass |
| 7 | the pair either side of a backgrounding | every reading identical | pass |

Row 7's two exports differ in **one field**: `Size`, 38,977,536 → 38,981,632 —
exactly one 4 KB page, a database write between them. **No protection reading
moved**, which is the claim.

### What running it corrected in this document

The original step 1 said *"restart the phone, do not unlock it"* under a heading
promising a reading. **There is nothing to read** — the app cannot run before
the first unlock, which is what the class means. The step was cut and §6 now
records the honest answer to the prompt's *"before-first-unlock behaviour where
safe"*: **it is not observable from inside the app at all.**

A campaign step that cannot be performed is worse than one that is missing: the
tester does it, sees nothing, and has no way to tell that from a pass.

### And 415's owed reading arrived in the same export

`2026-08-20-run-removal` in both **Migrations** and **Expected** — **19
migrations, 52 tables**. The additive migration applied cleanly to a 39 MB
database holding 257 ledger rows. 415's other line,
`removed by family, durably:`, lives in the **Import ledger** export and is
still uncaptured; all six families should read zero, since that device's only
two removals were pruned before 415 existed.
