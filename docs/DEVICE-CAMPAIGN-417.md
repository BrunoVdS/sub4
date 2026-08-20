# Device campaign — patch 417, the protection class as measured

| | |
|---|---|
| **Task** | Plan topic 2 — "verify storage protection instead of asserting it" |
| **Patch under test** | **417**. 418 brings the last two stores under the unclean-read guard. |
| **Written at** | patch 417, 20 August 2026 |
| **ADR** | §12.162 |
| **Contract** | `docs/PLAN-database-cutover-findings-and-ai-prompts.md`, "Manual test campaign contract" |
| **Time** | about ten minutes, one of them before you unlock the phone |
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

### Before you unlock — the only step with a time limit

1. **Restart the phone.** Do **not** unlock it.
2. While it is still at the passcode screen, note that Sub4's background refresh
   cannot run yet. **Nothing to capture here** — this step exists so step 3
   happens on a first-unlock boot, which is the state the class is named for.
3. Unlock, open Sub4, let it reach **Today**.

### The measurement

4. **Settings** → **Sync & data** → **Database health**.
5. **The file** → tap the title → read the **Protection** row.
6. Tap **⬆︎** → export.

### After a background cycle

7. Leave Sub4 (Home), wait ~30 seconds, come back.
8. **Database health** → **The file** → **⬆︎** → export.

---

## 5. Pass / fail

| # | after step | figure | passes | fails | meaning |
|---|---|---|---|---|---|
| 1 | 5 | **Protection** row | **`7 of 7 at the expected class`**, not red | fewer, red | At least one item is not protected as intended. Rows 3–5 say which. |
| 2 | 6 | `protection writes that failed this launch` | **`0`** | ≥ 1, with a message | The sweep could not set the attribute somewhere. **This line did not exist before 417** — the failure was swallowed by `try?`. Report the message. |
| 3 | 6 | *the database file*, *the database's folder* | `until first unlock` | anything else | The database holds every activity, note and decision. This is the row that matters most. |
| 4 | 6 | any item | not `NOT the expected class` | `NOT the expected class — complete` | **The interesting failure.** `.complete` would break background writes while the phone is locked — the app would quietly stop updating. Worse than no protection, and the reason the reader has four states rather than three. |
| 5 | 6 | *details/*, *streams/*, *snapshots/*, *notes.json* | `until first unlock` | `no protection attribute` | The sweep never reached it. `applyToExistingFiles` walks Application Support at every launch, so an item it missed is a real gap. |
| 6 | 6 | any item | not `could not inspect` | `could not inspect — …` | The item is missing or unreadable. For *details/* on a phone holding 698 detail files, that is a finding about the files, not about protection. |
| 7 | 8 | the whole export | identical to step 6 | any reading changed | Protection is set at write time and swept at launch; a backgrounding should move nothing. A change here means something is re-writing the class. |

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
- **The locked-phone write path.** `FileProtection`'s header argues that
  `.complete` would break background writes and
  `.completeUntilFirstUserAuthentication` does not. Step 1 puts the phone through
  a boot so the readings are taken on a first-unlock session, but proving a
  background write succeeds while locked needs a background refresh to land at a
  moment nobody controls. **Not covered, and not claimed.**
- **The two unguarded stores.** `AthleteStore` and `AthleteConstants` are still
  outside the unclean-read write contract and `UNPROTECTED_STORE_CEILING` is 2.
  That is **418**, and it is the suite's.

---

## 7. Result

*Not yet run.* Fill in `DEVICE-CAMPAIGN-409.md` §10's shape.
