# Device campaign — Task 0B, the starting-evidence package

| | |
|---|---|
| **Task** | Post-B5 runbook **Task 0B** — build and verify the complete starting-evidence package |
| **Written at** | patch 447, 22 August 2026, **against the code as built**: every label below is read from the source that draws it |
| **Built by** | 442 the barrier · 443 the database copy · 444 the package · 445 the off-device validator · 446 the control and the share · 447 the container measurement |
| **ADR** | §12.198–§12.203 |
| **Time** | about forty minutes, of which the captures are minutes and the reading is the rest |
| **Needs** | the phone, a Mac with this repository, and somewhere encrypted to put a package |
| **State** | **RUNNING — Parts A, B, C and F/G done, 22 August. §7** |

**THIS IS THE ONE THING NO TEST CAN PROVE.** 1,957 tests cover the writer, the
barrier, the copy and the validator. What they cannot do is take a package off
this phone, carry it to another machine, and have that machine agree — with
1,380 real files, a 39 MB database and a person holding the device.

---

## 1. Question and risk

**The question: can this app hand over a complete, self-checking copy of its own
state, and can a machine that has never seen the phone confirm it?**

That question exists because the obvious route lies. Xcode's *Download Container*
has now been measured three times (§12.186, §12.203). The most recent, on
22 August:

| | |
|---|---|
| `db/` · `details/` · `evidence/` · five stores | **absent** |
| `streams/` | **160 of 672 files** |
| the two snapshots inside it | **1380 of 1380 each, byte-for-byte** |

A route that reports success while dropping the database is not a route, and a
truncated `streams/` is worse than an absent one because every file in it hashes
correctly. **The package exists to replace it.**

**The risk in running this campaign** is that a package is a copy of everything —
every note, every route, every trace, the whole database — and the moment it
leaves the phone the app's protection is over. Step 12 is a warning you are
meant to read, not click past.

---

## 2. Before you start

| what | where | must read |
|---|---|---|
| Patch | **Settings → Manual & version** | **447 or later** |
| Configuration | same screen | record it — Debug or Release, either is fine here |
| Free space | Settings → General → iPhone Storage | **at least 150 MB free.** A package is roughly the snapshot plus the database — about 60 MB on this phone — and it takes a *fresh* snapshot first, which is another 20 MB before retention prunes |
| Task 0A | `docs/evidence/post-b5/task-0a.json` | accepted 22 August 08:18 UTC. This campaign starts from that state |

On the Mac, in the repository:

```bash
./scripts/selftest-evidence-package.sh
```

It must end `all evidence-package properties hold`. **Do this before the phone**,
not after — a validator you have not exercised is not a validator, and finding
that out with a package in your hand wastes the capture.

---

## 3. Safety preconditions — READ THIS ONE

- **NEVER install a `.xcappdata` with Xcode's Replace Container.** §12.186. On
  this phone it would delete the database, `details/`, five stores and 512
  traces and put nothing in their place.
- **A package is not a backup.** The file inside it is
  `database-diagnostic-copy.sqlite` and its manifest says
  `isSupportedRestoreArtifact: false`. Task 9 builds the backup.
- **Nothing here deletes, disconnects or revokes anything.** The one destructive
  control is `Delete <id>`, at the very end, on a package you have already
  validated — and the data it copied is untouched by it.
- **Do not send a package to an AI provider, and do not put one in the
  repository.** Only the redacted `support-report.txt` is casually shareable.
- If a step's label is not on screen exactly as written here, **stop and say
  so** rather than pressing the nearest thing.

---

## 4. Exact navigation

Every path below starts at **Settings → Sync & data → Database health**. Inside
that screen the section is **`Starting evidence`**, which sits between
**`The app's own files`** and **`Benchmark`**.

### Part A — where we are starting from · *steps 1–4*

1. **Settings → Manual & version** — screenshot. Record patch and
   `Configuration`.
2. **Database health → The file → ⬆︎** — share. *The baseline paste. Two lines
   in it are this campaign's starting state:*
   - `Evidence barrier: not held · 6 writers asked to wait, 4 detected only · no writer has been turned away this launch`
   - `Evidence packages: none on this phone`
3. **Database health → Rows — 52 tables → ⬆︎** — share. *The row counts the
   package's database copy will have to reproduce exactly.*
4. **Database health → Protected snapshot** — read `Last snapshot` and
   `Files copied`. Record both.

### Part B — the warning · *steps 5–7*

5. **Database health → Starting evidence → `Take an evidence package…`**
   **Nothing is captured by this press.** Photograph what appears.
6. Read the four lines under **`This is a copy of everything`**. They must say,
   between them: what is in a package · that it carries the app's protection
   while it is here · that **the protection is over once it leaves** · and that
   a package never goes to an AI provider.
7. Press **`Not now`**. The section must return to `Take an evidence package…`
   and **`Evidence packages`** must still read `none on this phone`.
   *A warning you cannot back out of is not a warning.*

### Part C — a capture you stop · *steps 8–10*

8. **`Take an evidence package…` → `Take it`**, and then **press `Stop`** as
   soon as it appears.
9. Read the line that replaces it. It must begin **`Stopped after`** and end
   **`Nothing was left behind.`** — not `FAILED`.
10. Press **`Done`**. **`Evidence packages`** must still read
    `none on this phone`.
    *A cancellation that left a half-package would be worse than no
    cancellation at all.*

### Part D — the capture, with the phone locked · *steps 11–14*

11. **`Take an evidence package…` → `Take it`**, then **lock the phone
    immediately** with the side button. Wait fifteen seconds. Unlock.
12. Read the result line. It should name a capture id and a count of files.
    *This is the file-protection row: the accepted class is `until first
    unlock`, so a capture that continues while the screen is locked is the
    correct behaviour and confirms the class. A capture that failed here would
    mean the class is stricter than the app claims.*
13. **Database health → The file → ⬆︎** — share.
14. **Rows — 52 tables → ⬆︎** — share. *So the counts can be compared with the
    copy's.*

### Part E — the barrier, observed · *steps 15–17*

**Do these three during a capture, not after.** The capture takes tens of
seconds on 699 activities; there is time.

**Stay on the Database screen.** It is a sheet over Settings, so anything under
`Sync & data` is behind it — and dismissing the sheet mid-capture loses the
result line. *(It does not lose the package: the work finishes and the package
appears in the list when you reopen the screen. But you would have to go looking
for it.)* The writer used below is on the same screen for exactly that reason.

15. Start another capture: **`Take an evidence package…` → `Take it`**.
16. **While it runs**, scroll up to **`Protected snapshot`** — already expanded
    from step 4 — and press **`Snapshot now`**. The line that appears must read,
    in these words:
    > An evidence capture is running. Try again when it has finished.

    *Taking a snapshot prunes older ones and writes receipts, so it moves the
    very folder the capture is reading. This is the writer most likely to
    collide in real use, because it is one button away.*
17. Let the capture finish, then **The file → ⬆︎** — share. The paste's
    `Evidence barrier:` line must now end with
    **`turned away this launch: snapshotRetention ×1`**.
    *A writer that turned back and said nothing would leave a contended capture
    looking uneventful.*

### Part F — off the phone · *steps 18–21*

18. In **`Starting evidence`**, tap the **capture id** in the list. It expands
    to `<id> — delete it?` with two buttons underneath.
19. Press **`Send <id>…`**. The share sheet opens on
    `sub4-evidence-<id>.zip`.
20. **AirDrop it to the Mac**, or Save to Files in an encrypted location you
    control. Record where it went.
21. **Do not put it in the repository.**

### Part G — the machine that has never seen the phone · *steps 22–25*

On the Mac, with the zip unpacked somewhere outside the repository:

22. ```bash
    unzip -q "sub4-evidence-<id>.zip" -d ~/evidence-check
    ```
23. ```bash
    python3 scripts/validate-evidence-package.py ~/evidence-check/<id>
    ```
    It must end **`ok — N checks, no problems`**.
24. Compare with the phone, by hand:
    - the capture id in the folder name against step 12's line
    - `support-report.txt`'s row counts against step 14's `Rows — 52 tables`
    - `support-report.txt`'s snapshot file count against step 4's `Files copied`
25. Read `support-report.txt` end to end. It is the half that is safe to paste —
    send it back with the results.

### Part H — the phone afterwards · *steps 26–28*

26. **Settings → Sync & data → `Refresh zones & gear`.** It must work now:
    `Last refresh` moves and `Returned` names zones and gear.
27. **Settings → Strava → `Check now`**, and **Database health →
    Traces still to fetch → `Fetch now`** if anything is outstanding. Both must
    run rather than refuse.
28. **The file → ⬆︎** — share. `Evidence barrier:` must read **`not held`**.
    *A barrier left up would stop the sync, the backfill and the background
    refresh for the rest of the launch.*

### Part I — clearing up · *steps 29–30*

29. Once the Mac has said `no problems`, tap the id → **`Delete <id>`** for
    every package you no longer need. The line must read
    `<id> removed. The data it copied is untouched.`
30. **The file → ⬆︎** — share. `Evidence packages:` back to
    `none on this phone`, and `Legacy files hidden for a test:` unchanged.

---

## 5. Pass / fail

| # | step | passes when | **a failure looks like** |
|---|---|---|---|
| 1 | 1 | patch **447+** | an older patch — `Starting evidence` does not exist before 446 |
| 2 | 2 | `Evidence barrier: not held · 6 writers asked to wait, 4 detected only` | a different count of writers — the vocabulary changed and this document is stale |
| 3 | 2 | `Evidence packages: none on this phone` | a package already there — fine, but record its id; step 7 and step 10 compare against this |
| 4 | 3–4 | row counts and `Files copied` recorded | — |
| 5 | 5 | pressing **`Take an evidence package…`** captures nothing | a capture starts on the first press — the warning is decoration and the design is broken |
| 6 | 6 | all four clauses present, including **the protection is over** and **never to an AI provider** | a missing clause — the warning has lost something and the test in `EvidencePackageShareTests` should have caught it |
| 7 | 7 | `Not now` returns to idle, still `none on this phone` | anything captured — see row 5 |
| 8 | 8–9 | the line begins **`Stopped after`** | it says `FAILED` — a person who changed their mind has not had a failure |
| 9 | 10 | still `none on this phone` | a package exists — **a half-written package is the worst outcome available**; record its id and stop |
| 10 | 11–12 | the capture completes with the phone locked | it fails while locked — the protection class is stricter than `until first unlock` and §5.6's protection row is wrong |
| 11 | 12 | the result names a capture id and a file count | `REFUSED — something changed while the capture was running` — the barrier did its job; something wrote underneath it. Read which, and retry |
| 12 | 13 | `Evidence packages: 1 on this phone · newest <id>` | still none — the capture reported success and wrote nothing |
| 13 | 16 | the refusal appears **verbatim** | a snapshot starts anyway — **the barrier is not held during a capture**, and a package could be taken over a folder being pruned underneath it |
| 14 | 17 | `turned away this launch: snapshotRetention ×1` | `no writer has been turned away` after a refusal was seen — the count is not being recorded |
| 15 | 19–20 | one `sub4-evidence-<id>.zip` reaches the Mac | the share sheet offers a folder — the zip step failed and was reported as success |
| 16 | 23 | **`ok — N checks, no problems`** | any `FAIL` line. **Send the whole output back**; each one names the check and the file |
| 17 | 23 | `N` is in the thousands, not tens | a two-figure check count over 1,380 files — the validator is examining almost nothing |
| 18 | 24 | ids, counts and the snapshot file count agree between phone and Mac | any disagreement — the package describes a different capture from the one you took |
| 19 | 26–27 | the refresh, the sync and the backfill all run | any still refusing — **the barrier is stuck up**, and that is worse than a failed capture |
| 20 | 28 | `Evidence barrier: not held` | `HELD since …` — same as row 19 |
| 21 | 29 | `<id> removed. The data it copied is untouched.` | a failure to remove — say so, and leave it alone |
| 22 | 30 | `none on this phone`, and the legacy-file line unchanged | the legacy-file line changed — the delete touched something it should not have |

---

## 6. What this campaign cannot cover

- **The low-space refusal.** `DiagnosticDatabaseCopy` refuses when the volume
  has less than 1.2× the database free, and there is no honest way to drive that
  on a phone with room on it. It is covered in the suite by injection
  (`itRefusesWhenThereIsNoRoom`), and the real reading is exercised separately
  (`theFreeSpaceReadingWorks`). **Recorded as a limitation rather than
  pretended.** §12.162.5: a campaign step that cannot be performed is worse than
  a missing one.
- **A partial copy.** The same: it is refused by counting both sides, and the
  branch cannot be reached without a broken SQLite. §12.199.4.
- **An unowned writer.** The barrier catches one by the fingerprints
  disagreeing, and row 11 is where that would surface — but nothing here can
  *make* an unknown writer run.
- **Whether the protection class survives off the phone.** It does not, and that
  is the whole point of step 6's warning. Where the package goes afterwards is
  not something the app can check.

---

## 7. Result

**Running — 22 August 2026. Five defects found, all by pressing rather than by
testing; five patches (448, 448a, 448b, 449) and the package validated off the
phone.**

### 7.1 Parts A and B — 15:12–15:18, patch 447. SEVEN OF SEVEN

Rows 1–7 all pass. Starting state: `Evidence barrier: not held · 6 writers asked
to wait, 4 detected only`, `Evidence packages: none on this phone`, snapshot
`2026-08-22-131445` **1380 of 1380**, census **52 tables, 221,153 rows**,
database **38,985,728 bytes**. The warning's four clauses all present, and
`Not now` captured nothing.

### 7.2 Part C — and it took three patches to make the row performable

**Row 8 failed three times before it could pass**, and each failure was a real
defect the suite was green through:

| what happened | why | patch |
|---|---|---|
| Stop looked dead; three captures completed | `cancel()` changed nothing on screen, so a working Stop and a dead one were identical | 448 |
| the backup could not be interrupted at all | the longest stage — 39 MB — had **no checkpoint**; the step size is the granularity of "can I stop" | 448 |
| Stop acknowledged and the capture finished anyway | **`Task.detached` does not inherit cancellation** — the checkpoint read a flag nobody could set | 448a |

**Passed at 15:52 on 448a**: `Stopped after the snapshot was taken. Nothing was
left behind.` with `none on this phone` after it. Rows 8, 9 and 10 pass.

### 7.3 Part F — Send closed the screen it was presented from

`.sheet` attached to a `Section` is presented from a row the `List` may recycle
— a rule `DatabaseHealthView` has carried since patch 332, in the file where the
mistake was made. Fixed at **448b**; the item is handed up to the screen.

### 7.4 Part G — THE ANSWER. 16:03, patch 448b

`2026-08-22-140313`, 60 MB, AirDropped and validated on the Mac:

```
ok — 2839 checks, no problems
```

| | |
|---|---|
| phone census, 15:14 | 52 tables, **221,153** rows |
| package copy, 16:03 | 53 tables, **221,174** rows |
| only in the copy | `grdb_migrations` = 21 |
| shared tables that differ | **none** |
| reconciliation | 221,153 + 21 = **221,174 exactly** |

Database copy **9,519 of 9,519 pages**, integrity `ok`, 0 foreign-key
violations, 21 migrations. Snapshot **1,380 of 1,380 copied, 0 failed**, 1,381
files carried. `differences between the two readings: 0`. All three unwatched
directories named with reasons.

Rows 15, 16, 17 and 18 pass. **Row 17's check count is 2,839, not tens.**

### 7.5 And a sixth, which is the first one's shape again

Zipping 60 MB ran on the main actor: the screen froze with nothing to say it was
working. **Work that cannot be seen has not been communicated.** Fixed at 449 —
packing and removing are detached now, behind a spinner with no button, because
`NSFileCoordinator` has no honest mid-way stop.

### 7.6 Still to run

**Part D** (the capture with the phone locked, rows 10–12), **Part E** (the live
barrier refusal, rows 13–14), **Part H** (the app resuming, rows 19–20) and
**Part I** (clearing up, rows 21–22).
