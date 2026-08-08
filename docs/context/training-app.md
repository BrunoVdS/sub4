# Sub4 iOS app — architecture, plan inventory, Strava findings, Xcode gotchas

*Origin: Cowork project memory `training-app.md`. State described is 2026-07-27 (base app
complete); the persistence work since then is in `sub4-database.md`. Exported 2026-08-07.*

Goal: personal iOS training app for the Operation Sub-4 marathon plan. Single user.
**This project builds the native Swift app; the HTML/PWA front-end is separate.**

**Core rule, part 1 — still absolute: NOTHING is logged manually in the app.**
**Core rule, part 2 — superseded:** "Strava is the sole source of truth for completed
sessions" held until 2026-07-31, when Apple Health became the intended source of truth.
See `strava-exit.md`. The code still reads Strava; the migration has not started.

## Status — base app complete, 2026-07-27

Five real tabs on device: **Today · Week · Commute · Plan · Progress**. 18 Swift files +
`plan.json` at that point.

Working: plan display, Strava sync with token refresh + 401 retry, Apple Health steps,
post-Ironman history from 2026-06-15, HR zones, shoe mileage, commute tracking, trend charts.

- **Strava API keys live in the iOS Keychain**, entered via Settings → Strava API keys.
  NOT in source — an edit can no longer wipe them. Client ID 267864.
- Scope is `activity:read_all,profile:read_all`. The profile scope is what unlocks
  `/athlete/zones` and gear distances on `/athlete`.
- **HealthKit IS allowed on a free Personal Team.** Push/iCloud/App Groups are gated;
  €99 buys only relief from the 7-day provisioning expiry.
- Bruno's HR zones (manual): Z1 ≤115, Z2 116–139, Z3 140–149, Z4 150–160, Z5 161+. FTP 270.
- Shoes: Novablast 5 TR (gear 29433600) ~340 km, Hierro V9 ~248 km. Retire around
  600–800 km → second pair due ~November.
- Benign console noise every debug run: RunningBoard "Client not entitled",
  elapsedCPUTimeForFrontBoard, usermanagerd persona, fopen errno 2. None from Sub4 —
  **the app logs nothing at all**, so the console cannot confirm success; check the UI.

## Unproven as of 2026-07-27

- **A Strava activity matching a planned session.** First test was 2026-07-28.
- **Hevy → Strava strength.** Zero WeightTraining activities in three months of history;
  56 of 260 sessions depend on it. Hevy's sync is toggled per workout on its save screen,
  not automatic. Fallback: record strength on the watch. See also `strava-exit.md` — whether
  Hevy writes to Apple Health may be the better path and is one of the six device checks.

## Backlog (as recorded 2026-07-27; the database work has since taken priority)

1. Validate the two unproven paths above.
2. €99 decision — the free provisioning expiry cycle is 7 days.
3. Per-km splits (`splits_metric`, detail endpoint, fetch lazily on open) — answers
   "did the last 4 km hold MP".
4. Background refresh so activities land before the app is opened.
5. Optional: real logging, so diagnosis stops depending on screenshots.
6. Optional: surface shoe wear somewhere more visible than Settings.

Strava rate limits are not a constraint: 100 reads/15 min, 1000/day; sync is 1–2 calls.

## Plan revision workflow

`plan.json` is bundled. If the plan changes: re-run `extract_plan.py` against the plan HTML,
drop the new `plan.json` into the source folder, rebuild. The extractor validates and exits
non-zero on failure. (Under Cowork these lived in `~/Documents/Triathlon/sub4-data/` —
consider moving the extractor into this repo as build tooling. See `docs/SWITCHOVER.md`.)

## Xcode gotchas (learned the hard way)

- Project: **`~/Documents/Developer/sub4/Sub4/Sub4.xcodeproj`** (the git repo root is
  `~/Documents/Developer/sub4/Sub4/`, so repo-relative it is `Sub4.xcodeproj`); source in `Sub4/`.
- **NEVER use Xcode's "Add Files".** Xcode 16+ uses synchronized folders — files written
  into the source folder appear automatically. Add Files creates a second reference →
  `Models 2.swift` → invalid redeclaration. Wrecked the project twice.
- **Open the `.xcodeproj`, not the folder.** Cost time twice.
- zsh errors on non-matching globs; use `find … -delete`.
- SwiftUI Preview canvas errors are cosmetic, never block ⌘R.
- **SwiftUI type-checker limit**: a large `Form`/`body` as one expression → "unable to
  type-check this expression in reasonable time". Split Sections into computed properties;
  store long strings as constants.
- **NSException cannot be caught by Swift do/catch.** Missing
  `NSHealthShareUsageDescription` → hard crash. Pre-flight with
  `Bundle.main.object(forInfoDictionaryKey:)`.
- **Persisted cursors defeat config changes.** Moving the ingest cutoff did nothing until
  `ActivityStore` recorded which cutoff produced its cache and auto-rebuilt on change.
- **iOS 26 deprecated every UIWindow initialiser except `init(windowScene:)`.**
- `DayKey`'s formatters are `nonisolated(unsafe)` — never mutate them, add a new formatter.
- **Swift Charts: `AxisContent` cannot be an existential.** Return `some AxisContent` from a
  function, not a property typed as the bare protocol.
- **`ProgressView` is SwiftUI's** — the progress tab is `ProgressTabView`.

## Verified plan inventory (trust these)

- 37 week cards = **34 plan weeks + 3 logged prologue weeks (P1–P3, undated by design)**
- **260 sessions**: run 105 (easy 53 / long 29 / MP 15 / threshold 8), bike 53,
  strength 56, swim 26, rest 20
- Wk 1 Monday = **2026-07-27**; race **2027-03-21**. Weeks strictly Mon–Sun.
  **Week 1 has no Monday session.**
- Detail objects `{total, tag, focus, blocks:[{d,t,x,u}]}` — identical for swim and strength.
- Exercise library: 20 movements, 477 instances.
- **Week stats keys are inconsistent** — some weeks "ride", others "rides", race week
  "shakeouts". Render generically or values get dropped.

## Strava data characteristics

- **Commute noise**: 2–3 rides of 3.2–4.2 km every weekday; real training rides >20 km →
  10 km threshold (verified working).
- Bruno does NOT use Strava's commute flag — flagged rides drop off the heatmap. The app
  defines a commute as any ride under the 10 km threshold, the same test that keeps them
  out of matching.
- **Duplicate uploads are real**: 2026-04-21, same ride twice from two devices
  (61.7 / 60.4 km).
- Access tokens last **6 hours**; refresh tokens rotate. A 400 on refresh means reconnect.

## App architecture

- `plan.json` bundled read-only; `PlanStore` not `@Observable`. `week(containing:)` matches
  by date range, not by session.
- `ActivityStore` pulls on launch, throttled 15 min, incremental via Strava's `after`.
  Cutoff 2026-06-15; `planStartDayKey` 2026-07-27 separates pre-plan days. 401 → force
  refresh → retry once.
- `AthleteStore` holds HR zones + gear, refreshed at most daily, cached to disk.
- **Everything after cutoff is stored** including walks/commutes — thresholds gate only
  *matching*.
- `Matcher`: day + discipline, nearest planned distance, explicit-distance sessions first.
  Rest days auto-complete. Overrides in UserDefaults. **Bias: never guess.**
- `HealthStore` guarded by `hasUsageDescription` + 8-second query timeout.
- Dates compared as `"yyyy-MM-dd"` strings, never `Date`.
- Charts: one y-axis each, actual in accent / plan as recessive grey reference, labels only
  where informative, zone colours always with Z-labels, charts hidden until there is enough
  data.
