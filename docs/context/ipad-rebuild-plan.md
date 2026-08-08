# Sub4 iPad rebuild — chosen approach

*Origin: Cowork project memory `ipad-rebuild-plan.md`, decided 2026-07-30. Exported
2026-08-07. Read with `ipad-readiness.md`.*

Bruno chose the **full split-view rebuild** over an adaptive retrofit or an iPad-specific
dashboard.

**Mockup: `sub4-data/ipad-rebuild-mockup.html`** (currently in `~/Documents/Triathlon/`) —
four screens at 1194×834 (iPad Pro 11″ landscape), built with real `plan.json` weeks 1–6 /
wk-01 sessions and `Theme.swift` colours verbatim. Activity metrics in it are illustrative;
plan-side numbers are real.

## Target structure

- **Sidebar 252pt** replaces the five `.tabItem`s: brand + race countdown, five nav rows, a
  contextual second group (current block / chart filter / jump-to), Strava status + Settings
  pinned bottom.
- **Three columns for browsing** (Today, Week, Plan): sidebar / list 352pt / detail flexible.
- **Two columns for analysis** (Progress, Commute): middle column collapses, charts get a
  2×2 grid at ~430pt each. Charts have nothing to drill into.
- Sheets become panes. Only Settings stays a sheet — it is modal by nature. Match picker
  becomes a popover.

## Blast radius

Presentation only. `PlanStore`, `Matcher`, `ActivityStore`, `AthleteStore`, `HealthStore`,
`Models` are **untouched** — that is the main argument for doing it.

- `ContentView` — replaced by `NavigationSplitView` + selection enum.
- `SessionDetailView` — no longer a sheet; driven by a shared selection binding; needs a real
  empty state.
- `TodayView` / `WeekView` / `PlanView` — split into list halves, lose their own
  `NavigationStack` (the split view owns navigation).
- `ProgressTabView` / `CommuteView` — the only place needing real chart work:
  `.frame(height:)` → aspect ratio, `.fixed()` bar width → `.ratio()`, axis `desiredCount`
  scales with width.
- `StravaAuth` — the `presentationAnchor` bug becomes reachable the moment two windows exist;
  must resolve from the *active* scene.
- `Theme` — add a layout-metrics namespace; the numbers are currently literals scattered
  across seven view files.

## Rules the rebuild must not break

- Sidebar visibility driven by **size class**, never a stored preference. A split view that
  cannot collapse is worse than tabs.
- The detail column needs a defined empty state — it is legitimately absent at compact width
  and legitimately empty on first launch.
- **Compact width (Slide Over / narrow Stage Manager) is the existing iPhone layout and is
  already correct.** The damage in the current build is at *wide*, never at narrow.

## Found while mocking up — worth acting on independently

- **`plan.json` weekly `km` jumps 90 → 260–300 at Week 11**: that is total km including long
  bike rides, not run km. On a phone chart it reads as a spike; at 430pt it flattens the
  whole run trend. **The Progress charts need a discipline filter before they need more
  width.**
- **The HR zone palette fails an adjacent-pair check.** Against the dark card surface, Z4
  `#f58c4d` vs Z5 `#f55a5a` = ΔE 11.0 in normal vision (floor is 15); Z2/Z3 = ΔE 7.3 under
  protanopia. The app's existing "never show a zone colour without its Z-label" rule is what
  rescues it — on iPad the zone chart roughly triples in area, so either keep that rule
  absolutely non-negotiable or re-step the ramp for monotonic lightness. HR zones are
  ordinal; a hue ramp is the wrong tool for ordinal data even when it is the conventional one.
- Weeks 7–9 are the vacation block at 25 km — without a visible marker the long-run line just
  looks like three missed weeks.

## Open decisions, in order

1. **Cross-device state** — the real product question, not the layout. See
   `ipad-readiness.md`. Two devices currently means two adherence numbers for the same week.
2. **Multi-window** — accept it (and fix the anchor) or restrict to a single scene.
3. **€99** — two devices means rebuilding from Xcode twice every seven days on free
   provisioning. Not an argument for paying; an argument for deciding the iPad question
   early rather than late.
