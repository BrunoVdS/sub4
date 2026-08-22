# Device campaign — Task 0A, the gear and weather provenance proof

| | |
|---|---|
| **Task** | Post-B5 runbook **Task 0A**, tranche 6 — the one manual campaign Task 0A requires |
| **Written at** | patch 440, 22 August 2026, **against the code as built**: every label below is read from the source that draws it |
| **Closes** | B5 campaign row 19's residual ambiguity — `docs/DEVICE-CAMPAIGN-B5.md` §10.1j and §10.1k |
| **ADR** | §12.187, §12.188, §12.194, and this campaign's result |
| **Time** | about twenty minutes |
| **State** | **NOT RUN** |

**THIS IS NOT A RERUN OF THE B5 CAMPAIGN.** That campaign is accepted at
twenty-two of twenty-two and nothing here repeats it. This asks one question it
could not answer.

---

## 1. The question, and why the B5 run left it open

**Row 19 of the B5 campaign moved `athlete.json` and `weather.json` aside, and
the app drew the same six shoes and the same weather card.** That is the result
the slice existed for — and there are two ways to disbelieve it:

1. **`AthleteStore` rewrote `athlete.json` while its own was hidden.** §12.188:
   `StoreLoad.absent` is trustworthy, so the store read nothing, decided that
   was legitimate, and saved a fresh file. 433a made the restore *report* the
   rewrite, and the device confirmed it at 16:22 — `kept from an earlier test:
   athlete.json.written-while-hidden`. So a sceptic can say the app read a file
   it had just written, not the database.
2. **Strava was reachable throughout.** Any refresh could have refilled the
   gear from the network, and nothing in the run proved one did not.

**This campaign removes both.** Strava is switched off first and its refusal
observed; the rendering is read **before anything touches the file side**; and
since patch 439 the app reports every file inside `hidden-for-test/` by **path,
hash and byte count**, so the original and any rewrite are told apart by their
bytes rather than by inference.

**What a pass means:** the gear and weather on the screen came out of SQLite,
with the legacy files physically out of reach and no network able to refill
them.

---

## 2. Build and data identity — record before you start

| what | where | write it down |
|---|---|---|
| Patch and configuration | **Settings → Manual & version** | must be **440 or later** |
| Which copy the app reads | the baseline paste, step 2 | `Athlete store reads:` and `Weather store reads:` must both say **the database** |
| The starting fingerprint | the baseline paste, step 2 | the `internal test artifacts:` block — **`none`** is the expected reading, or the leftover from 433a named with its hash |

---

## 3. Safety preconditions — READ THIS ONE

- **The control RENAMES. It never deletes.** `hidden-for-test/` is beside the
  files, the state is a directory so it survives a force-quit, and
  `Put the legacy files back` is the way home. The database, `details/` and
  `streams/` are never touched.
- **NEVER use Xcode's "Replace Container" on this app.** §12.186: the download
  omits the database, both payload folders and four stores, in either build
  configuration, and writing one back destroys what it does not contain.
- **Step 5 is a stop condition, not a formality.** If either live file will not
  read *before* anything is hidden, **stop and report** — hiding a file whose
  live copy is already broken makes the only good copy the hidden one.
- **Switch Strava back on at step 20.** The campaign ends with the phone as it
  started.
- Nothing here disconnects Strava, revokes anything, deletes a file or changes
  external state.

---

## 4. Exact navigation

### Part A — the starting state, with the files still in place · *steps 1–5*

1. **Settings → Manual & version** — screenshot. Record patch and
   `Configuration`.
2. **Settings → Sync & data → Database health → The file → ⬆︎** — share.
   *This is the baseline paste. It carries `Athlete store reads:`,
   `Weather store reads:`, `Gear facts recovered from the file at hydration:`,
   `Legacy files hidden for a test:` and the new `internal test artifacts:`
   block.*
3. **Database health → Read-back · weather and gear → ⬆︎** — share.
4. **Progress tab → the shoes section.** Photograph the whole section. Write
   down the number of rows and, for each, the name and the kilometres. **This
   is the comparison the rest of the campaign is against.**
5. **Database health → The app's own files → `Survey the app's files`.**
   Read the `athlete` and `weather` rows.
   **STOP IF** either says anything other than `readable`. Report what it says.

### Part B — Strava off, and its refusal observed · *steps 6–9*

6. **Settings → External data transfers** — the section at the top of Settings,
   above Strava. Switch **off**:
   - **Read activities from Strava**
   - **Background refresh**
   - **Connect to Strava**

   Photograph the section with all three off.
7. **Force-quit. Relaunch from the icon.** Settings → **External data
   transfers** — photograph again. *A gate is a preference; this proves it
   survived the relaunch rather than living in one screen's memory.*
8. **Settings → Sync & data → `Refresh zones & gear`** — it is below
   `Database health`, **not** in the Strava section.
   *(The first draft of this document said "Settings → Strava", which is wrong.
   The Strava section carries a STATIC notice — "Read activities from Strava is
   switched off. Data & privacy, above." — that renders whether or not anything
   was ever attempted. A line that reads the same in both states cannot
   discriminate between them, which is §12.15 and is exactly what this row is
   for.)*

   Read the two rows that appear after the press: **`Attempted`**, in orange
   with a timestamp, shown only when the press produced no data — and under it,
   in these words:
   > "Read activities from Strava" is switched off under Data & privacy, so
   > nothing was requested.

   **This is the proof that the one call that could refill the gear is
   refused.** Photograph both rows — a refused tap still happened, and
   `Attempted` is the only thing that says so.
9. **Database health → The file → ⬆︎** — share. *Second paste: the app with its
   files intact and its network shut.*

### Part C — hide, cold launch, and read the SCREENS first · *steps 10–14*

**The order in this part is the campaign.** Every file-side diagnostic is held
back until the rendering has been seen, because a survey or a read-back reads
the files and a reader could then argue the screen was drawn from that read.

10. **Database health → The app's own files → `Hide the legacy files`.**
    Read the outcome line under the button: it must name **both**
    `athlete.json` and `weather.json`. The row above it,
    **`Legacy files hidden for a test`**, must turn **red** and name both.
    Photograph both lines. **Do not press `Survey the app's files`.**
11. **Force-quit. Relaunch from the icon.**
12. **Progress tab → the shoes section.** Photograph. **Compare row for row
    against step 4** — same count, same names, same kilometres.
13. **Open an activity with weather** — Today or Week → a recent run → the
    weather block on the summary card. Photograph temperature, **Felt**,
    **Wind** with its compass point and **Humidity**.
14. **Only now: Database health → The file → ⬆︎** — share.
    *Third paste, and the one that carries the proof: `Athlete store reads:`,
    `Weather store reads:`, and the `internal test artifacts:` block naming
    both hidden files with their hashes and byte counts.*

### Part D — did a mirror come back, and who wrote it · *steps 15–16*

15. **Database health → The app's own files → `Survey the app's files`.**
    Read the `athlete` and `weather` rows.
    - **`not on this phone`** for both is the expected answer **with Strava
      off**, and it is itself a finding: on 21 August, with Strava reachable, a
      rewrite appeared inside sixty seconds.
    - **If a live file HAS reappeared**, photograph the row and note the time.
      Then repeat **The file → ⬆︎** and compare the `internal test artifacts:`
      hashes against step 14's. A hash that has not moved means the hidden
      original is untouched and the new file is a fresh write beside it.
16. **Settings → Manual & version** — screenshot, so the paste and the
    rendering are stamped to one build.

### Part E — restore, and prove the original bytes came back · *steps 17–20*

17. **Database health → The app's own files → `Put the legacy files back`.**
    The button changes label when something is hidden. Read the outcome line:
    if the app wrote anything while its files were hidden, it says
    **`AND KEPT <name>.written-while-hidden, written by the app while hidden`**.
    Photograph it.
18. **Force-quit. Relaunch. `Survey the app's files`** — both rows readable
    again.
19. **Database health → The file → ⬆︎** — share. *Fourth paste. The
    `internal test artifacts:` block now describes only what is left over, and
    `Legacy files hidden for a test` must read
    `none — every legacy file is in its place`.*
20. **Settings → External data transfers** — switch all three back **on**.
    Photograph. **Then Settings → Strava → `Refresh zones & gear`** and confirm
    it no longer refuses.

---

## 5. Pass / fail

| # | step | passes when | **a failure looks like** |
|---|---|---|---|
| 1 | 1 | patch **440+**, and `Configuration` is recorded | an older patch — the `internal test artifacts:` block does not exist before 439 and half this campaign cannot be performed |
| 2 | 2 | `Athlete store reads:` and `Weather store reads:` both say **the database** | either says *the files* — B5 is not flipped on this device and nothing below means anything |
| 3 | 2 | `Gear facts recovered from the file at hydration:` reads **0** | non-zero — 432's loop is running again, and the file is still feeding the store (§12.182) |
| 4 | 2 | the `internal test artifacts:` block is present and reads `none`, or names the 433a leftover with a hash | the line is absent — the build predates 439 |
| 5 | 3 | the read-back's gear and weather sections show **0 differ** | any difference — fix that before hiding anything |
| 6 | 4 | the shoes section photographed, rows counted | — |
| 7 | 5 | `athlete` and `weather` both **readable** | anything else — **STOP** |
| 8 | 6–7 | all three switches off, and still off after a relaunch | a switch back on after the relaunch — the gate is not persisting and the rest of the campaign proves nothing about the network |
| 9 | 8 | the refusal sentence appears **verbatim** under an orange `Attempted` row | the button does nothing visible, or only the Strava section's static notice is seen — then the refusal is unproven, which is the whole point of the step; report it as a failure of the campaign, not of B5 |
| 10 | 10 | the outcome line names **both** files; the row turns red | one file named — the other was already absent, which contradicts step 7. Stop and report |
| 11 | 12 | **the same shoe rows and the same kilometres as step 4** | fewer rows, different figures, or an empty section — **the gear was coming from the file** and B5 is not complete |
| 12 | 13 | the weather block renders with the same four figures | absent or zeroed weather — same conclusion for weather |
| 13 | 14 | `Athlete store reads:` still says **the database**, and `internal test artifacts:` names both hidden files with hashes and byte counts | the block does not name them, while `Legacy files hidden for a test` says they are hidden — the two disagree and one of them is wrong |
| 14 | 15 | `athlete` and `weather` read `not on this phone` | a live file is back — **not a failure**, a finding. Record its time and prove by hash that the hidden original is untouched |
| 15 | 17 | both files restored; anything the app wrote is reported as **KEPT** and not overwritten | the outcome line says `REFUSED` — read the reason and stop; the originals are still in `hidden-for-test/` and nothing is lost |
| 16 | 19 | `none — every legacy file is in its place` | anything still hidden — put it back before ending the session |
| 17 | 20 | the three switches on; `Refresh zones & gear` no longer refuses | still refusing — the gates did not go back on |

---

## 6. What this campaign cannot cover

- **It does not prove the app never needs the files.** It proves it does not
  need them *for gear and weather*, which is B5's scope. B7 and B8 own the rest.
- **It cannot distinguish "no mirror was written" from "no mirror was written
  yet".** Step 15 is one observation at one moment. What it can do — and 439 is
  what makes it possible — is prove by hash that a mirror which DID appear is a
  new file beside an untouched original.
- **It says nothing about the leftover copy's disposition.** Step 19's paste is
  the **preview**: exact path, hash and bytes. The scoped, receipted removal is
  Task 0A tranche 2b and needs a decision first.

---

## 7. Result

**Running — 22 August 2026, patch 440, Debug.** Parts A and B below.

### 7.1 Part A — 06:42–06:47. SIX OF SEVEN, and the seventh is step 4

Installed 06:30; `Source patch 440`, `Configuration: Debug`. **That also closes
the "Debug build on the phone" housekeeping item** that was due before Task 3.

| # | reading | verdict |
|---|---|---|
| 1 | patch **440**, built 22 Aug 06:30, **Debug** | pass |
| 2 | `Athlete store reads: the database` · `Weather store reads: the database` | pass |
| 3 | `Gear facts recovered from the file at hydration: 0` | pass |
| 4 | `internal test artifacts: 1` — `hidden-for-test/athlete.json.written-while-hidden · 1507 bytes · d8cc76b5f678622fc18f53e7cd2a2552d6dde122c3096721e2da2ebbebda1ad2 · kept from an earlier test` | pass — **439's first device reading, and the tranche 2b preview** |
| 5 | read-back: `reading fields that differ: 0`, `gear fields that differ: 0`, `unexplained differences: 0`; `gear by kind: 6 shoes, 4 bikes, 1 of unknown kind`; `gear carrying a retirement date: 1`; app side `from activities.json, read directly` | pass — identical to 21 August |
| 6 | the shoes photograph | **OUTSTANDING** |
| 7 | survey: `athlete: readable`, `weather: readable` | pass |

**The survey went further than the row asked.** It opened and classified all
1,371 payload files — `detail: 699 files, 699 readable, 0 at fault`,
`streams: 672 files, 672 readable, 0 at fault` — from a different reader than
the paste's `counted but not opened` line, and the two agree. The B4 mirror is
not merely present; it is readable file by file. `legacyDetails` and
`legacyStreams` absent.

**`Unreadable stores: none` does NOT substitute for step 5, and this is worth
recording.** That line describes stores that were *read* this launch, and since
B5 flipped, `AthleteStore` and `WeatherStore` hydrate from the database and may
never open their files. **A store that never read cannot report an unreadable
read**, so "none" there is consistent with `athlete.json` being missing, empty
or truncated. §12.155's shape, found while validating a campaign rather than
while writing one.

### 7.2 Part B — 06:48–06:53. TWO OF TWO

| # | reading | verdict |
|---|---|---|
| 8 | all three switches off at 06:48; still off at 06:51 after a force-quit and relaunch | pass |
| 9 | `Attempted 22 Aug 06:53` in orange, and beneath it, verbatim: *"Read activities from Strava" is switched off under Data & privacy, so nothing was requested.* | pass |

**THE PAIRING IS THE PROOF.** `Attempted` reads **06:53** while `Last refresh`
still reads **06:40** and `Zones held` still reads 5 — two rows a call that
quietly succeeded could not both satisfy. Before patch 232 this button returned
in silence, and that state was indistinguishable from this one.

`Next window: none pending` beside it: the background scheduler has nothing
queued either, so the refusal is not only for the press.

**And step 8's navigation was wrong in the first draft of this document.**
It said "Settings → Strava"; the button is in **Sync & data**. The Strava
section's line — *"Read activities from Strava is switched off. Data & privacy,
above."* — is a **static notice** that renders whether or not anything was ever
attempted, so reading it proves the gate is shut and nothing about a refusal.
**A campaign step that cannot fail is not a step** — §12.15 in an instruction
rather than in the code, and §12.162.5's family.

**Recorded, and helpful rather than a confound:** `Last refresh 22 Aug 06:40` —
a real Strava zones-and-gear refresh ran after the 06:30 install and before the
gates went off at 06:48. Both the database and `athlete.json` were freshly
reconciled from the source before Part A's baseline at 06:43.

**The leftover is untouched by any of this**: step 9's paste reports the same
1507 bytes and the same `d8cc76b5…` hash as step 2's.

**One measurement, recorded and NOT acted on.** Step 9's launch was clean —
`left the app during the window: no` — and read `first free main-thread turn:
0.024 s`, `longest main-thread stall: 1.078 s over 522 samples`. **That is
Debug.** B6a's 1.0 s trigger is on the **Release** stall, last measured
0.608 / 0.613 s at patch 432 (§12.184), so this does not move it.

### 7.3 Parts C–E

Not yet run. Part C begins once step 4 is in.
