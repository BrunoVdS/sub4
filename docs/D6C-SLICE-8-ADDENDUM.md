# D6c slice 8 — addendum after 329

Written 8 August 2026 after 329c landed and was verified on the device. Read
`D6C-SLICE-8-GROUNDWORK.md` first — it is still correct. This adds only what
329 taught, and one thing 330 should fix while it is in the neighbourhood.

---

## 1. `Matcher.day` returns a TUPLE. Use `Matcher.resolved`.

`Matcher.day(_:)` returns `(matches: [Match], extras: [Activity])`, not
`MatchResolver.Day`. 329 assumed otherwise and lost a build — twice in one
file's worth of errors, because `ProgressTabView` had the same call one file
later and the compiler stopped before reaching it.

`Matcher.resolved(_ dayKey:) -> MatchResolver.Day` exists since 329b and is the
one conversion. 330 does not need it — the twin builds `MatchResolver.Day`
directly from the database — but anything reaching for the app side does.

## 2. The `day:` closure is the twin's seam

    TabSummary.weekPoints(weeks: [Week],
                          sessions: [Session],
                          todayKey: String,
                          day: (String) -> MatchResolver.Day) -> [WeekPoint]

The app passes `{ matcher.resolved($0) }`. **330 passes a closure backed by the
database's days**, and must answer a question the closure cannot: *which keys
was it asked for that it did not have?*

A closure returning an empty `Day` for a missing key is indistinguishable from
a day with nothing in it — §12.15 in a lambda. So the twin's closure should
record every key it was asked for, and the report should carry
`daysAskedFor` / `daysTheDatabaseHad` as two figures, not one. That is the
denominator this slice would otherwise lack, because every other count in it is
per-WEEK and a missing DAY would not move any of them by much.

## 3. `todayKey` must be captured once and handed to both sides

Groundwork §7 said the cutoff is the likeliest way to get this wrong. 329 made
`todayKey` a parameter so it can be. **330 must actually do it**: read
`DayKey.key()` once, into a local, and pass that same string to both
`weekPoints` calls. Reading it twice — once per side — is a race that shows up
only when the comparison straddles midnight, which is exactly when nobody is
looking.

## 4. Fix `Plan: unchanged` while you are on that screen

The import panel's Plan row reads `unchanged` in two different situations:

- the bundled plan is byte-identical to a version already stored, **and**
- the bundled plan is new but its `contentHash` already exists because
  something imported it earlier in the same launch

329a hit the second. The row said `unchanged` while the plan HAD changed, and
the only reason that was diagnosable was that shadow parity reported zero
session differences — i.e. a different screen answered the question this one
was asked. §12.15's shape, on a row that is one string away from being useful.

Suggested: `unchanged`, `new version N activated`, and
`already imported this launch` as three distinct answers. Cheap, and it is on
the exact screen 330 is editing anyway.

## 5. Two things 329 left open, neither blocking

- **The plan HTML is stale on week stats.** `tools/marathon_plan_sub_4hr.html`
  disagrees with `Sub4/plan.json` on 33 of 37 weeks' headline km/h, because
  patch 240 wrote the app's figures into the JSON and never into the HTML.
  §12.74.1. Fixing it means running `PlanFocus.volumeExport` and pasting 37
  rows back. Until then **never regenerate plan.json without splicing** —
  sessions only, weeks preserved.
- **`PlanSeedTests` freezes bytes, SHA-256 and session count.** Any patch that
  touches `plan.json` must update those three constants AND ADR §9.2 in the
  same patch. 329c did; the suite made sure of it.

## 6. A build symptom worth recognising

⌘R in Xcode racing `./scripts/test.sh` produced a **type error**
(`cannot convert '[(matches:extras:)]' to '[MatchResolver.Day]'`) on source
that was provably correct and had compiled green minutes earlier. CLAUDE.md
lists the DerivedData collision under its other face,
`invalid reuse after initialization failure`.

**A type error that contradicts the file on disk is a stale module, not a bug.**
Check the source, then
`rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex`, then re-run
with Xcode idle.
