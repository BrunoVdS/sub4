# Sub4

A transparent marathon-training companion. It connects recorded activity to a
training plan, explains the evidence behind every figure it prints, and refuses
to state a number it cannot support.

Built for Operation Sub-4: a 34-week block starting 27 July 2026, targeting a
sub-4:00 marathon in March 2027.

*Current at patch 444, 22 August 2026. **`CLAUDE.md` §5 is this project's only statement
of current state**; this README says what the repository IS and points there for where the
work has got to. Exact live counts belong on the Database screen, and every patch decision
is in `docs/ADR-0003-database-contract.md` §12.*

## Requirements

| | |
|---|---|
| Xcode | 26.6 |
| iOS deployment target | 26.5 |
| Devices | iPhone and iPad (`TARGETED_DEVICE_FAMILY = "1,2"`) |
| Bundle identifier | `be.apatch.Sub4` |
| Dependencies | **GRDB 7.11.1**, pinned Exact Version, revision `b83108d1` |

GRDB is on the `Sub4` target only, as the static `GRDB` product; `GRDB-dynamic`
is deliberately not linked. Tests reach it through `@testable import Sub4`.
Xcode's Exact Version field pre-fills `1.0.0` — a 2017 tag Swift 6.3 refuses.
Type the version and press **Tab**, not Return.

## Building

```
open Sub4.xcodeproj
```

Select the shared **Sub4** scheme and build. There is no generated project — the
target uses an Xcode file-system-synchronized group, so `Sub4/` **is** the source
list. A file added to that folder is in the build; nothing has to be added to the
project.

That mechanism is why patches to this project are installed by unzipping into
`Sub4/Sub4/` and are never added through Xcode's *Add Files* dialog — doing so
creates a second, conflicting reference to a file the target already has. A
**new** file needs Xcode quit and reopened before the app target sees it; the
test target picks one up without.

## Testing

```
./scripts/test.sh          # xcodebuild test on the simulator
./scripts/preflight.sh     # test + Release build, before anything destructive
```

The test script prints and validates the current test/suite count. Run it from the command
line before every device build: ⌘R compiles the app target only, so test-target compile
errors accumulate invisibly.

`.github/workflows/ci.yml` runs weekly and on tags rather than on every push.
**It is not currently a check** — the free Actions allowance is spent until
1 September 2026, and exhaustion presents as an instant failure of every job.
Local verification is the source of truth until then.

## Secrets

None are stored in this repository, and none may be added to it.

| Secret | Where it lives | How it gets there |
|---|---|---|
| Strava client ID and secret | Keychain (`strava.credentials`) | Entered in Settings on the device |
| Strava OAuth tokens | Keychain (`strava.tokens`) | Written by the OAuth flow |
| Claude API key | Keychain (`claude.apiKey`) | Entered in Settings on the device |

A clean clone therefore builds and runs, but connects to nothing until those
values are entered on the device.

## Capabilities

HealthKit, Background Modes (background fetch and processing), and WeatherKit
are declared in `Sub4/Sub4.entitlements`. A development team with those
capabilities is required to run on a device; the simulator builds without
signing.

## Layout

```
Sub4.xcodeproj
CLAUDE.md              read this first — project state and the rules that cost time
Sub4/                  the entire application source
  plan.json            the bundled plan seed: 37 weeks, 260 sessions
  manual.html          the in-app manual (stale since patch 284 — see CLAUDE.md §5)
  Assets.xcassets
  Sub4.entitlements
Sub4CoreTests/         the complete automated test target
docs/                  ADRs, groundwork documents, handoffs
  ADR-0003-database-contract.md    the authoritative record; §12 is the running log
  PLAN-codebase-modernization-and-feature-delivery.md    execution sequence from current state
  PLAN-post-database-strava-project-restructure.md       restructure and product roadmap
  context/                          project knowledge carried over from Cowork
scripts/               test.sh, preflight.sh
tools/                 plan extraction from the source HTML
SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md
```

There is no CHANGELOG and there should not be one. `git log` plus ADR-0003 §12
already carry that history in more detail than a changelog would, and a third
place to write the same thing is how two answers to one question start.

## Where the project actually is

The persistence rewrite is a lettered ladder, D0 to D8. **D0 through D6c are complete, and
D7 is four slices in: the plan, the athlete, the authored data and — since patch 383 — the
activities are read from SQLite on every launch.** Details, traces, weather, gear, reviews
and the `UserDefaults`-backed state are still read from the legacy stores; those are D7's
remaining slices.

**Every JSON store is still written and still complete.** That is what makes each slice
reversible, and it is why the shadow-parity comparison reads `activities.json` directly
rather than asking the store it is checking.

**The verifier says how much of its own agreement is evidence, and since patch
389 so does the read-back roll-up.** Every comparison and every read-back row
names where its expectation came from, and whether that source is one the build
feeds from the database is derived by asking the stores rather than declared —
so a check that agrees because it is asking the database about itself cannot be
counted as proof. The Database screen prints the split for both.

**One document says what is true now: `CLAUDE.md` §5.** It carries the ladder, what reads
from where, the device evidence, the open items and the next steps, and
`scripts/check-invariants.py` RULE 6 fails the build if it falls more than twelve patches
behind `Sub4/AppVersion.swift`. ADR-0003 §12 has the reasoning behind every decision;
`docs/PLAN-codebase-modernization-and-feature-delivery.md` has the sequence from here
through Health, D8, restructure and feature delivery.

## Known release blockers

This app is **not** ready for public distribution.

1. Strava use must be reconciled with the API Policy effective 1 June 2026, or
   the source must move to Apple Health. Decided: it moves — see
   `docs/ADR-0002-strava-retirement.md` and `docs/context/strava-exit.md`. Not
   started; it cannot begin before D7's exit gate.
2. Authoritative runtime state is still spread across JSON files and UserDefaults
   with no transaction. This is what the D-ladder exists to fix, and it is not
   fixed until D7 flips the reads over. Failable saves landed at 264–270, so a
   note that fails to save now says so.
3. CI exists but is not a gate — see **Testing** above.
4. Privacy disclosures do not yet match the actual Health, AI, and weather
   data flows.

`SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md` is the original ordered plan
and has not been touched since 3 August; read it for the shape of the argument,
not for current state.

## History

Repository history begins at `peer-review-baseline-2026-08-03`. Before that tag
the repository tracked 15 files while the application itself — every view, every
store, the load engine, the parser — was untracked. The tag is the first commit
that contains the app.

Patch numbering is continuous and predates the tag; commit subjects carry it, and
the ADR and the groundwork documents cite it.
