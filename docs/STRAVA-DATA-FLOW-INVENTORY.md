# Strava data-flow inventory

**Date:** 3 August 2026
**Source:** Sub4 at patch 177 — 86 Swift files, 31,488 lines
**Purpose:** remediation plan step 0.1.2. Every raw and derived Strava value, where it is stored, how long it is kept, what is computed from it, and who else receives it.
**Method:** exhaustive search of the target for URL construction, `UserDefaults`, Application Support paths, Keychain access and DTO field names, with file:line evidence for every claim.

This document is the evidence base for the classification in `ADR-0002`. It records what the app *does*, separately from what it *may* do — the two are kept apart on purpose so the compliance argument can be checked against the code rather than against a summary of it.

---

## 1. Network calls to Strava

Eight requests, all on `URLSession.shared` except the browser-presented OAuth authorize.

| # | Endpoint | Issued by | Triggered by |
|---|---|---|---|
| 1 | `GET /oauth/mobile/authorize` (browser) | `StravaAuth.connect()` `StravaAuth.swift:120‑166` | User taps Connect in Settings |
| 2 | `POST /oauth/token` (`authorization_code`) | `StravaAuth.exchange(code:)` `StravaAuth.swift:175‑182` | Completion of #1 |
| 3 | `POST /oauth/token` (`refresh_token`) | `StravaAuth.refresh()` `StravaAuth.swift:208‑216` | Any call within 120 s of token expiry, and forced once on a 401 |
| 4 | `GET /api/v3/athlete/activities` | `StravaClient.activities` `ActivityStore.swift:387‑423` | Launch, pull‑to‑refresh (Today and Progress), Settings *Check now*, cache rebuild, **and the `be.sub4.refresh` background task every ~2 h** |
| 5 | `GET /api/v3/activities/{id}` | `StravaClient.detail` `DetailStore.swift:414‑419` | Queued after every sync; 30 per foreground drain, 3 per background drain; jumped ahead when a detail sheet opens |
| 6 | `GET /api/v3/activities/{id}/streams` | `StravaClient.streams` `DetailStore.swift:423‑443` | Same queue as #5, for activities ≥ 500 m |
| 7 | `GET /api/v3/athlete/zones` | `AthleteStore.fetchZones` `AthleteStore.swift:212‑238` | Launch; throttled to 24 h — **except it fires unconditionally while FTP is nil** |
| 8 | `GET /api/v3/athlete` | `AthleteStore.fetchGear` `AthleteStore.swift:265‑286` | Launch, concurrent with #7 |

Scope requested: `activity:read_all,profile:read_all` (`StravaAuth.swift:89`).
Redirect URI: `sub4://localhost` (`StravaAuth.swift:84`).
Pagination ceiling: `while page <= 10` at 100 per page — a hard 1,000-activity limit (`ActivityStore.swift:394`).

**Requests continue without the user present.** #4, and therefore #5–#6, run from a background task scheduled roughly every two hours (`BackgroundRefresh.swift:74, 143, 146`).

---

## 2. What is ingested, and where it comes to rest

### 2.1 Activity summary → `Application Support/activities.json`

Decoded by `StravaActivityDTO` (`Activity.swift:320‑343`), converted at `Activity.swift:344‑372`, written whole and pretty-printed by `ActivityStore.save()` (`ActivityStore.swift:356‑360`).

Eighteen fields are retained: `id`, `name`, `sport_type`, `start_date_local`, `start_date` (UTC), `distance`, `moving_time`, `elapsed_time`, `total_elevation_gain`, `average_heartrate`, `max_heartrate`, `trainer`, `gear_id`, `device_watts`, `average_watts`, `max_speed`, and **`start_latlng` split into `startLat` / `startLon` — the precise GPS start coordinate of every activity**.

**Retention: indefinite.** Rows leave only by ingest-filter rejection (`ActivityStore.swift:299‑310`), a user-triggered `resetCache()` (`ActivityStore.swift:363‑374`), or a change to the ingest cutoff. Nothing expires by age. The store currently holds activities back to 1 July 2025 — thirteen months.

### 2.2 Activity detail → `Application Support/details/<id>.json`

`StravaDetailDTO` (`ActivityDetail.swift:226‑261`) → `toDetail()` (`:262‑293`), one file per activity (`DetailStore.swift:83, 363‑366`).

Retained: `calories`, **`description` (the athlete's free text)**, `average_cadence`, `average_watts`, `max_watts`, **`device_name` (hardware identifier)**, **`map.polyline` — the full encoded GPS route**, the `splits_metric` array (distance, moving time, elapsed time, elevation difference, average HR, split index), `best_efforts` (name, elapsed time), and `laps` (index, distance, moving time, average HR).

**Retention: indefinite.** Only `resetCache()` (`DetailStore.swift:389‑407`), reachable solely through `ActivityStore.resetCache()`.

### 2.3 Streams → `Application Support/streams/<id>.json`

`StravaStreamsDTO` (`ActivityStreams.swift:193‑205`) → `toStreams()` (`:217‑271`), downsampled to ~300 equal-distance bins (`:52, 224`).

Retained per activity: cumulative distance, heart rate, speed, altitude, grade, watts **only when meter-backed** (`:267`), and **latitude/longitude — a ~300-point GPS track**.

**Retention: indefinite** in normal operation. Wholesale deletion happens only on a schema-version bump (`DetailStore.swift:98‑107`), which then re-fetches.

### 2.4 Athlete → `Application Support/athlete.json`

Heart-rate zone boundaries, FTP (kept only when `> 50` and not Strava-estimated, `AthleteStore.swift:229‑231`), and shoes with id, name, lifetime distance and primary flag.

**Retention: indefinite, and there is no reset path for this file anywhere in the codebase.** It is overwritten on refresh; it is never deleted.

### 2.5 Derived stores that hold Strava-sourced values

| File | Strava-sourced content | Deletion path |
|---|---|---|
| `weather.json` | Keyed **by Strava activity id**; every row was fetched using that activity's Strava start coordinate | `resetCache()` exists at `Weather.swift:425‑428` but **no caller was found** |
| `constants.json` | `hrMaxObserved` derived from Strava `max_heartrate`, plus **`hrMaxObservedName` — the Strava activity's name** (`AthleteConstants.swift:252‑259`) | None |
| `proposals.json` | Each record stores **the entire evidence text that was sent to Anthropic**, including Strava-derived load figures (`ProposalStore.swift:44, 98`) | Single-record `remove()` only; deliberately no reset (`ProposalStore.swift:26‑27`) |

`LoadStore` persists nothing — PMC, TRIMP and monotony are in memory only (`LoadStore.swift:26‑33`). They are recomputed from the stores above, so the durable exposure is those stores rather than the curve.

### 2.6 UserDefaults

| Key | Content | Note |
|---|---|---|
| `strava.cursor`, `strava.lastSync`, `strava.cutoffUsed` | Sync state | Cleared by `resetCache()` |
| `strava.powerBackfill`, `strava.speedBackfill`, `strava.geoBackfill` | Migration version markers | — |
| **`strava.rejectedByRule`** | Per rejected activity: **date, name, distance, duration, average and max speed** | **Designed never to be pruned** (`ActivityStore.swift:129‑134`); survives `resetCache()` *and* the deletion of the activity itself |
| `detail.failed`, `detail.noStreams` | Strava activity ids | — |
| `match.overrides` | `sessionUid → activityId` | Strava ids as values |
| `bg.lastResult` | Embeds the count of new Strava activities and any Strava error text | Diagnostic |

### 2.7 Keychain

`strava.credentials` (client id and secret), `strava.tokens` (access, refresh, expiry), `claude.apiKey` — all `kSecAttrAccessibleAfterFirstUnlock` (`StravaAuth.swift:302`).

**`strava.credentials` has no deletion path.** `disconnect()` removes only `strava.tokens` (`StravaAuth.swift:168‑171`); the client id and secret survive a disconnect.

---

## 3. What is computed from it

Every headline number in the app is derived from Strava values.

| Output | Where | Strava inputs |
|---|---|---|
| TRIMP per session | `LoadEngine.load` `TrainingLoad.swift:270‑357` | HR stream, speed stream, distance stream, `average_heartrate`, `moving_time`, `average_watts`, `device_watts`, FTP |
| Fitness / fatigue / freshness (CTL, ATL, TSB) | `PMC.build` `PMC.swift:83‑116` | The TRIMP series above, in full |
| Monotony and strain | `Monotony.series` `Monotony.swift:89‑115` | Daily load, i.e. Strava-derived |
| Time in heart-rate zone | `ZoneTotals.build` `ZoneTime.swift:126‑179` | HR and speed streams, bucketed by **Strava's own zone boundaries** |
| Power load (TSS), power calibration factor | `PowerLoad.swift:159, 244`; `LoadStore.swift:111‑115` | `average_watts`, watts stream, **Strava FTP**, `moving_time` |
| Volume totals and the weekly stack | `VolumeCard.swift:198‑203, 513‑556` | `distance`, `moving_time`, `elapsed_time`, `sport_type` |
| HR max, and therefore the whole TRIMP span | `ConstantsStore.refreshFromSources` `AthleteConstants.swift:240‑297` | `max_heartrate` scanned over 365 days |
| Pace analysis and trends | `PaceCard.swift:121‑133, 239‑278` | `distance`, `moving_time`, `elevation_gain`, `sport_type` |
| Splits, closing/opening pace, best window | `ActivityDetail.swift:57‑198` | `splits_metric` |
| Intervals and reps | `IntervalSplits.swift:227` and speed-stream segmentation | `laps`, speed stream |
| Best efforts | `ActivityDetailExtras.swift:54‑58` | `best_efforts` |
| Shoe wear | `AthleteStore.swift:63‑135` | `shoes[].distance`, `gear_id` |
| Commute classification | `CommuteView.swift:24‑77` | `sport_type` + `distance` |
| Plan matching and adherence | `Matcher.swift:41‑120`, `Review.swift:215‑243` | `sport_type`, `distance`, `start_date_local` |

### 3.1 Where Strava and Apple Health are combined in one calculation

Four points, and they matter for §5.4:

1. **`ConstantsStore.refreshFromSources`** — Strava `max_heartrate` and HealthKit resting heart rate are passed into the same function and together define the TRIMP span every load figure uses (`AthleteConstants.swift:240‑297`, invoked `ActivityStore.swift:223‑225`).
2. **`LoadEngine.load(..., healthAverageHR:)`** — a HealthKit average heart rate is substituted for a Strava activity that has none, flagged `.healthHeartRate` (`TrainingLoad.swift:97, 337‑340`).
3. **`PaceSeries.sessions`** — HealthKit `activeSeconds` replaces Strava swim duration (`PaceCard.swift:267‑272`).
4. **`LoadStore.currentSignature()`** includes the HealthKit workout count, making the Health cache an input to the Strava-derived load series (`LoadStore.swift:86`).

---

## 4. Who else receives it

### 4.1 Anthropic — `https://api.anthropic.com/v1/messages`

Built by `ClaudeClient.structured` (`ClaudeClient.swift:107‑162`), triggered only by the user running a monthly review (`ProposalStore.swift:202‑219`). There is no automatic or background invocation.

The prompt is `ReviewRequest.prompt` (`ReviewProposal.swift:296‑336`), which opens with the whole of `Review.markdown()` (`Review.swift:474‑571`). Strava-derived content that leaves the device:

- Count and share of plan sessions matched to a Strava activity (`Review.swift:485‑486`)
- Recorded running kilometres per week (`Review.swift:257, 511‑518`)
- Planned versus done per discipline, where "done" means a Strava activity matched (`Review.swift:234‑243, 501‑505`)
- Measured pace per session and its deviation from the plan band, derived from `splits_metric` (`Review.swift:299, 532‑545`)
- **CTL ramp figures** — "CTL rose %.1f in the last seven days" (`ReviewLoad.swift:146‑162`)
- **Consecutive days of deep TSB** (`ReviewLoad.swift:171‑178`)
- **Counts of high-monotony weeks** (`ReviewLoad.swift:186‑194`)
- Recorded versus planned volume shortfalls (`Review.swift:417‑421`)
- The athlete's own session notes, verbatim, with RPE and feel (`Review.swift:547‑556`)

**Not sent:** no raw activity list, no coordinates, no polylines, no streams, no activity names, no activity ids, no gear, no device names, no Strava descriptions. The payload is the computed aggregate pack plus plan text plus note text.

That distinction was the design intent (`ClaudeClient.swift:9‑14`, `Review.swift:17‑20`) and it is worth stating plainly: what leaves the device is **derived** from Strava Data rather than raw. Section 5.5 of the policy covers "any data derived from Strava Data" explicitly; §5.3 and §5.10 are written in terms of Strava Data without a derived-data carve-out. The classification in `ADR-0002` treats derived figures as in scope.

**The exact text sent is then written to `proposals.json`** (`ProposalStore.swift:98, 122‑125`) and can be exported to a shareable markdown file (`:183‑193`).

### 4.2 Open-Meteo — `api.open-meteo.com`, `archive-api.open-meteo.com`

`OpenMeteo.request` (`Weather.swift:580‑651`). Sends **latitude and longitude to four decimal places (~11 m) plus the UTC timestamp and duration of the session** — taken directly from Strava's `start_latlng`, `start_date` and `elapsed_time` (`Weather.swift:274, 281‑285`). Unauthenticated, but a coordinate and a timestamp are inherently identifying.

Triggered when an activity detail sheet appears (`ActivityDetailView.swift:268`) — so simply opening an activity transmits where it started — or in bulk from the Settings backfill button (`SettingsView.swift:815`).

### 4.3 Apple WeatherKit

`AppleWeather.hourly` (`Weather.swift:531‑547`), tried first with a three-strike circuit breaker. Same Strava-sourced coordinate and timestamp inputs.

### 4.4 User-initiated export

`ShareSheet` (`ShareSheet.swift:28‑36`) fed by `Review.writeMarkdown()` (`Review.swift:580‑590`), `ProposalStore.writeMarkdown` (`ProposalStore.swift:183‑193`, includes the whole evidence pack) and `NotesStore.writeCSV` (`NotesStore.swift:313‑324`, plan and notes only).

### 4.5 Confirmed absent

An exhaustive search for URL construction across all 86 files found no analytics SDK, no crash reporter, no telemetry endpoint and no backend of the app author's own. The destinations above are the complete set.

---

## 5. Open items

1. **`WeatherStore.resetCache()` has no caller** (`Weather.swift:425‑428`). If confirmed, `weather.json` — keyed by Strava activity id — cannot be cleared from within the app.
2. **`strava.credentials` cannot be deleted.** No `Keychain.delete("strava.credentials")` exists.
3. **`strava.rejectedByRule` is permanent by design** and holds activity date, name, distance, duration and speeds after the activity itself is gone.
4. **`constants.json` holds a Strava activity name** with no deletion path.
5. **The client secret is sent in the body of every token request** (`StravaAuth.swift:178, 212`) — acknowledged in the file header as a deliberate trade-off for a personal app; it is not one that survives public distribution.
6. Approximately 4,800 lines of view code were not read line by line. The claims above about *network egress* and *persistence* rest on exhaustive greps and are complete; a view file could in principle compute a derived figure not listed in §3, but it cannot contain an unlisted destination or store.
7. Older patch-drop directories outside the target (`part3/`, `authfix/`, `hotfix3/`, `zonesgear/`, and others in the scratch workspace) contain near-duplicate copies of `StravaAuth.swift`, `ActivityStore.swift` and `AthleteStore.swift`. They are not built. If the compliance scope is "all source anywhere", they need separate disposal.
