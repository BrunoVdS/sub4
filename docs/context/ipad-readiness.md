# Sub4 on iPad — readiness audit

*Origin: Cowork project memory `ipad-readiness.md`, audit of 2026-07-30. Exported
2026-08-07. Read with `ipad-rebuild-plan.md` before iPad work.*

**Note on provenance:** this audit read a *reconstructed* source tree (the base zip plus 13
patch zips merged in mtime order), because the live Xcode project was not reachable from
Cowork — `project.pbxproj` and `Info.plist` could not be read. **Under Claude Code they can.
Verify the three "not verifiable" items below directly before acting on this file.**

## Verdict

It will **run** on iPad. It will **look** like a stretched iPhone app. No crash path found.

## Not verifiable from Cowork — check these first (now trivially readable)

- `TARGETED_DEVICE_FAMILY` / Supported Destinations. Xcode's iOS template defaults to
  iPhone+iPad; if iPad was unchecked it simply will not install.
- `UIRequiredDeviceCapabilities` — if `healthkit` was added there, the app becomes
  non-installable on some iPads. **The only true blocker candidate.**
- `UISupportedInterfaceOrientations~ipad` — all four are needed for Stage Manager /
  Split View.

## Real defects (iPad-specific, not present on iPhone)

- **`StravaAuth.swift:235-249`** — `presentationAnchor` picks
  `connectedScenes.compactMap{$0.keyWindow}.first`. `connectedScenes` is an unordered Set.
  With two Sub4 windows (Stage Manager / Split View) the OAuth sheet can open in the wrong
  window, or the session fails with `presentationContextInvalid` and login silently no-ops
  (`:117-121` resumes nil). Single-window iPad use is unaffected.
- **Charts use `.fixed()` bar widths** — `ProgressTabView.swift:152` (12pt),
  `CommuteView.swift:146` (14pt) — tuned for a ~330pt plot area. At iPad width the 12 weekly
  buckets read as scattered pins. Fixed heights 130-150pt (`ProgressTabView.swift:168,194,243`,
  `CommuteView.swift:176`) give ~9:1 letterboxes.
- **Nothing syncs between devices.** Keychain items have no `kSecAttrSynchronizable`
  (`StravaAuth.swift:258-266`) → API keys and tokens must be re-entered on iPad. Match
  overrides are `UserDefaults.standard` (`Matcher.swift:32,74`), activity cache is a local
  file (`ActivityStore.swift:36,172`) → adherence numbers can diverge between iPhone and
  iPad. **Untested: whether a second OAuth grant for the same Strava app invalidates the
  iPhone's refresh token.** If it does, the iPhone hits the 400-on-refresh path and silently
  disconnects.
- **Steps** — `HKHealthStore.isHealthDataAvailable()` returns true on iPadOS 17+, so no "not
  available" message appears. iPad has no pedometer; steps only show if iCloud Health sync
  carries iPhone samples across. If it does not, the Steps button in `TodayView.swift:233-245`
  is dead — tapping re-requests an already-granted permission and does nothing, while
  Settings reads "Access: granted / Days with steps: 0".

## Cosmetic

- No `horizontalSizeClass`, no `GeometryReader`, no readable-width cap anywhere. Every tab is
  `ScrollView { VStack }` + 16pt inset → cards ~1334pt wide in landscape.
- `ContentView.swift:12-27` uses the legacy `TabView` + `.tabItem` builder, not the `Tab`
  value type → no sidebar-adaptable behaviour on iPadOS 18+/26, and the tab bar renders at
  the *top*, so the `.padding(.bottom, 24)` throughout pads the wrong edge and
  `.navigationTitle` duplicates the tab label.
- Sheets become ~540×620 form sheets (6 call sites). Settings and MatchPicker tolerate it;
  `SessionDetailView` scrolls more than it should.

## Confirmed fine on iPad

NavigationStack + NavigationLink, `.navigationBarTitleDisplayMode(.inline)`, all toolbar
placements (`.topBarLeading` / `.topBarTrailing` / `.principal` / `.confirmationAction`),
`.refreshable`, `.contextMenu`, `ASWebAuthenticationSession` itself, string-based date
handling. Narrow Stage Manager / Slide Over maps to compact width — i.e. the layout the app
was designed for. Singletons are safe across windows (one process, `@Observable`
propagates). No location, camera, or CoreMotion dependency. Every force-unwrap checked and
guarded.
