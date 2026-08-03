# Sub4

A transparent marathon-training companion. It connects recorded activity to a
training plan, explains the evidence behind every figure it prints, and refuses
to state a number it cannot support.

Built for Operation Sub-4: a 34-week block starting 27 July 2026, targeting a
sub-4:00 marathon in March 2027.

## Requirements

| | |
|---|---|
| Xcode | 26.6 |
| iOS deployment target | 26.5 |
| Devices | iPhone and iPad (`TARGETED_DEVICE_FAMILY = "1,2"`) |
| Bundle identifier | `be.apatch.Sub4` |
| Dependencies | None yet. GRDB arrives with the database migration. |

## Building

```
open Sub4.xcodeproj
```

Select the shared **Sub4** scheme and build. There is no package resolution
step and no generated project — the target uses an Xcode
file-system-synchronized group, so `Sub4/` **is** the source list. A file added
to that folder is in the build; nothing has to be added to the project.

That mechanism is why patches to this project are installed by unzipping into
`Sub4/Sub4/` and are never added through Xcode's *Add Files* dialog — doing so
creates a second, conflicting reference to a file the target already has.

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
Sub4/                  the entire application — 86 Swift files, ~31,500 lines
  plan.json            the bundled plan seed: 37 weeks, 260 sessions
  Assets.xcassets
  Sub4.entitlements
SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md
```

## Known release blockers

This app is **not** ready for public distribution. The current state and the
ordered plan for resolving it are in
`SUB4_CURRENT_PEER_REVIEW_AND_REMEDIATION_PLAN.md`. In short:

1. Strava use must be reconciled with the API Policy effective 1 June 2026, or
   the source must move to Apple Health.
2. Authoritative runtime state is spread across JSON files and UserDefaults
   with no transaction. Notes and reviews can fail to save without saying so.
3. There is no automated test target and no CI.
4. Privacy disclosures do not yet match the actual Health, AI, and weather
   data flows.

Read that document before changing anything structural.

## History

Repository history begins at `peer-review-baseline-2026-08-03`. Before that tag
the repository tracked 15 files while the application itself — every view, every
store, the load engine, the parser — was untracked. The tag is the first commit
that contains the app.
