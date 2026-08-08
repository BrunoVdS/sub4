# Sub4 on Mac — readiness audit

*Origin: Cowork project memory `mac-readiness.md`, audit of 2026-07-30. Exported 2026-08-07.
Read before any Mac work.*

Audited the same reconstructed 18-file source as `ipad-readiness.md`. **The live Xcode
project was not reachable from Cowork** — `project.pbxproj` and `Info.plist` unreadable.
Under Claude Code they can be read; re-check anything below marked unverifiable.
Bruno's Mac is Apple Silicon.

## Verdict

Not ready. Unlike iPad (runs, looks stretched), **no Mac path works today without a project
change**, and the HealthKit steps feature is dead on every Mac path regardless.

## The three paths

- **Designed for iPad ("My Mac (Designed for iPad)" destination)** — cheapest. Apple
  documents Xcode running iOS apps natively on Apple silicon. Unconfirmed for a free Personal
  Team: the only evidence is a 2021 forum report of "apps validated by [free provisioning]
  are not allowed to be installed from this source". **Test this first — it is a 2-minute
  check and it decides everything.**
- **Mac Catalyst** — needs the destination added to the target. Personal Team can sign and
  run Mac Catalyst locally (DTS: paid account not required). Blocker: **the HealthKit
  capability does not exist for Mac Catalyst** (entitlement is iOS/watchOS/visionOS only), so
  the target's current HealthKit capability must be conditioned or the Catalyst build will not
  provision.
- **Native macOS target** — most work. `import UIKit` (`StravaAuth.swift:290`) does not
  compile; `UIApplication.shared.connectedScenes` does not exist; `ASPresentationAnchor`
  becomes `NSWindow`. Not worth it for a single-user app.

## HealthKit is dead on Mac — all paths

`import HealthKit` **compiles** for Catalyst and links under Designed-for-iPad, but there is
no HealthKit store on macOS: `isHealthDataAvailable()` returns false. The code already guards
on `isAvailable`, so **no crash** — the Steps card just stays empty forever with no
explanation. Same silent-dead-button shape as the iPad finding, but here it is certain rather
than conditional.

## Real defects on Mac (beyond the iPad list)

- **The `presentationAnchor` scene-picking bug becomes routine, not an edge case.**
  `Sub4App.swift` uses a bare `WindowGroup`, so on Mac ⌘N opens additional windows by
  default. `StravaAuth.swift:236-248` picks from the unordered `connectedScenes` Set → OAuth
  sheet in the wrong window or a silent no-op login. On iPad this needed Stage Manager; on
  Mac it needs one keystroke.
- **Keychain**: fine on Catalyst / Designed-for-iPad (both use the data-protection keychain by
  default; `kSecUseDataProtectionKeychain` is ignored there). A native macOS target would need
  it set explicitly or `kSecAttrAccessibleAfterFirstUnlock` goes through a shim. Separate
  risk: `Keychain.save` (`StravaAuth.swift:257-267`) discards the `SecItemAdd` status
  entirely — an ad-hoc "Sign to Run Locally" build has no App ID and would fail with -34018
  **silently**, looking like "keys will not save".
- **Charts get worse, not just wider.** `.fixed(12)` / `.fixed(14)` bar widths
  (`ProgressTabView.swift:152`, `CommuteView.swift:146`) and 130-150pt fixed heights were
  tuned for ~330pt. A Mac window is resizable to any width — there is no single "iPad size"
  to tune for. No `maxWidth` readable cap anywhere.
- **Third divergent data store.** `applicationSupportDirectory` cache
  (`ActivityStore.swift:32`, `AthleteStore.swift:64`), `UserDefaults.standard` overrides,
  non-synchronizable Keychain → Mac would be a third island. Still untested whether a second
  OAuth grant invalidates the iPhone's refresh token.
- `sub4://localhost` custom scheme needs `CFBundleURLTypes` to survive into the Mac build —
  was unverifiable without `Info.plist`.

## Confirmed fine on Mac

`ASWebAuthenticationSession` itself, Swift Charts, `TabView` / `.tabItem`,
`.preferredColorScheme(.dark)`, `.refreshable`, NavigationStack, sheets, string-based dates,
`UIApplication.shared.connectedScenes` (exists on Catalyst). No location/camera/CoreMotion.

## Note on expiry

macOS does not require a provisioning profile for third-party code (TN3125), so a Mac build
with no restricted entitlements has nothing to expire — potentially better than the iPhone's
7-day cycle. Unverified: whether an expired 7-day Personal Team profile blocks launch once
`keychain-access-groups` is claimed.

## The PWA is not the fallback

`triathlon.apatch.be` still served the one.com "under construction" placeholder as of
2026-07-30 — nothing deployed. The build spec's D1 ("PWA first, native later") is the path
that would make Mac trivial, but it does not exist — and `strava-exit.md` records that D1
inverts anyway, because HealthKit is native-only.
