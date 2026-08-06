#!/usr/bin/env python3
"""
Patch 286 — the route census could not have worked. HK-02, second time.

285 queried `HKSeriesType.workoutRoute()`. It is not in `HealthStore.typesRead`,
so the app has never asked permission to read routes — and HealthKit answers an
unrequested read with an empty result rather than an error, which is
indistinguishable from a device with no routes.

That is HK-02 exactly, described at length in `HealthTypeTests`' own header,
two screens above the query that repeated it.

  · the type joins `typesRead`, `typesReadDescribed` and `authVersion`
  · `routes(for:)` stops returning a bare `Set<String>?` and returns a reason
  · and it REFUSES TO QUERY a type that is not in `typesRead`, which is the
    guard that would have named this in one run

ONE MANUAL STEP, and the build stays red until it is done — see below. That is
by design: `usageDescriptionNamesEveryTypeRead` reads the prompt string out of
the built product, and the string lives in the target's build settings where no
patch can reach it.

  Xcode → Sub4 target → Build Settings → search "NSHealthShareUsageDescription"
  → set BOTH configurations to:

    Sub4 reads your steps, walking and running distance, cycling and swimming
    distance, workouts, workout routes, heart rate and resting heart rate. It
    uses them to show your full daily movement, to fill in details a recorded
    session is missing, and to track how your training load is building.

  (one line, no wrapping — the wrapping above is this comment's.)

No new files, so no ⌘Q.

Run from ~/Documents/Developer/sub4/Sub4/docs
Stops without changing anything if any anchor is missing or not unique.
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


S = "Sub4/HealthStore.swift"
W = "Sub4/HealthWorkouts.swift"
C = "Sub4/HealthCoverage.swift"
V = "Sub4/HealthCoverageView.swift"
TT = "Sub4CoreTests/HealthTypeTests.swift"

# --------------------------------------------------- the type joins the set

edit(
    S,
    r'''    var typesRead: [HKObjectType] {
        [stepType, walkRunType, restingType,
         workoutType, swimDistanceType, heartRateType, cyclingDistanceType]
    }''',
    r'''    var typesRead: [HKObjectType] {
        [stepType, walkRunType, restingType,
         workoutType, swimDistanceType, heartRateType, cyclingDistanceType,
         // Patch 286. Read by the coverage census — and read in 285 WITHOUT
         // being requested, which is HK-02 with a different type. HealthKit
         // answers an unrequested read with an empty result, so the census
         // reported nothing and looked like a phone with no routes.
         routeType]
    }

    /// The route attached to a workout. `HKSeriesType`, not a quantity: it is
    /// a series of locations and it is requested as its own object type.
    private var routeType: HKSeriesType { HKSeriesType.workoutRoute() }''',
    "workoutRoute joins typesRead",
)

edit(
    S,
    r'''    static let typesReadDescribed = [
        "Steps", "Walking and running distance", "Resting heart rate",
        "Workouts", "Swimming distance", "Heart rate", "Cycling distance"
    ]''',
    r'''    static let typesReadDescribed = [
        "Steps", "Walking and running distance", "Resting heart rate",
        "Workouts", "Swimming distance", "Heart rate", "Cycling distance",
        "Workout routes"
    ]''',
    "the described list gains routes",
)

edit(
    S,
    r'''    /// 3 adds workouts and swim distance. 4 adds heart rate. 5 adds cycling
    /// distance, which had been read without ever being asked for (HK-02).
    private static let authVersion = 5''',
    r'''    /// 3 adds workouts and swim distance. 4 adds heart rate. 5 adds cycling
    /// distance, which had been read without ever being asked for (HK-02).
    /// 6 adds workout routes, which had been read without ever being asked for
    /// — the same defect, at patch 285, in the same shape. The prompt will
    /// appear once more on a device that has already granted the other seven.
    private static let authVersion = 6''',
    "authVersion 6, so a granted install re-prompts",
)

# ---------------------------------------- routes() reports why, or refuses

edit(
    W,
    r'''    /// Which of these sessions Health holds a route for.
    ///
    /// RETURNS `nil` WHEN IT COULD NOT ASK — a denial, a timeout, a store that
    /// refused. An empty set means it asked and none of them has a route,
    /// which is a finding; `nil` means there is no finding. Handing back `[]`
    /// for both would let a permissions failure read as "these are all
    /// shells", which is the conclusion this census exists to reach honestly.
    ///
    /// One query to fetch the workouts by id, then one per workout for its
    /// route. `HKWorkoutRoute` has no way to name its own workout, so the
    /// per-workout predicate is the only correct join — matching routes to
    /// sessions by time would be a second matcher against the clock.
    @MainActor
    func routes(for workouts: [HealthWorkout]) async -> Set<String>? {
        guard isAvailable, hasRequestedAuthorization, hasUsageDescription else { return nil }
        guard !workouts.isEmpty else { return [] }''',
    r'''    /// Why the route census did or did not happen — patch 286.
    ///
    /// 285 returned `Set<String>?`, which was already better than `[]` for
    /// everything: a bare `nil` said "no finding" without saying why, and when
    /// it happened on the first live run nobody could tell which of four
    /// causes it was from the screen. One level up, `HealthCoverage.Reading`
    /// had already learned this lesson. This is the same answer.
    nonisolated enum RouteCensus: Equatable, Sendable {
        case measured(Set<String>)
        case unavailable
        case neverAsked
        case noUsageDescription
        /// The type is not in `typesRead`. HK-02's shape: HealthKit answers an
        /// unrequested read with an empty result, so this cannot be detected
        /// AFTER the query — only before it.
        case notRequested
        case failed(String)

        var ids: Set<String>? {
            if case .measured(let s) = self { return s }
            return nil
        }

        var line: String {
            switch self {
            case .measured:          "Routes were measured."
            case .unavailable:       "Routes not measured — HealthKit is not available."
            case .neverAsked:        "Routes not measured — the Health prompt has never been shown."
            case .noUsageDescription: "Routes not measured — the build has no Health usage description."
            case .notRequested:      "Routes not measured — the app never asked permission to read them (HK-02)."
            case .failed(let why):   "Routes not measured — \(why)"
            }
        }
    }

    /// Which of these sessions Health holds a route for.
    ///
    /// IT REFUSES TO QUERY A TYPE IT NEVER REQUESTED. That guard is the whole
    /// point of this patch: HealthKit answers an unrequested read with an
    /// empty result and no error, so the only moment the mistake is visible is
    /// before the query runs. Asking `typesRead` first turns a silent nothing
    /// into a sentence naming the cause.
    ///
    /// One query to fetch the workouts by id, then one per workout for its
    /// route. `HKWorkoutRoute` has no way to name its own workout, so the
    /// per-workout predicate is the only correct join — matching routes to
    /// sessions by time would be a second matcher against the clock.
    @MainActor
    func routes(for workouts: [HealthWorkout]) async -> RouteCensus {
        guard isAvailable else { return .unavailable }
        guard hasUsageDescription else { return .noUsageDescription }
        guard hasRequestedAuthorization else { return .neverAsked }

        let routeID = HKSeriesType.workoutRoute().identifier
        guard typesRead.contains(where: { $0.identifier == routeID }) else {
            return .notRequested
        }
        guard !workouts.isEmpty else { return .measured([]) }''',
    "routes returns a reason and refuses an unrequested type",
)

edit(
    W,
    r'''        let wanted = Array(workouts.prefix(Self.maxRouteCensus))
        let uuids = wanted.compactMap { UUID(uuidString: $0.id) }
        guard !uuids.isEmpty else { return [] }''',
    r'''        let wanted = Array(workouts.prefix(Self.maxRouteCensus))
        let uuids = wanted.compactMap { UUID(uuidString: $0.id) }
        guard !uuids.isEmpty else { return .measured([]) }''',
    "the empty case is measured, not silent",
)

edit(
    W,
    r'''        guard let found = await samples(of: .workoutType(), matching: byID) as? [HKWorkout] else {
            noteError("Health could not return the sessions to check for routes.")
            return nil
        }

        var out: Set<String> = []
        for w in found {
            let mine = HKQuery.predicateForObjects(from: w)
            guard let routes = await samples(of: HKSeriesType.workoutRoute(),
                                             matching: mine) else {
                noteError("Health could not be asked about routes.")
                return nil
            }
            if !routes.isEmpty { out.insert(w.uuid.uuidString) }
        }
        return out
    }''',
    r'''        guard let found = await samples(of: .workoutType(), matching: byID) as? [HKWorkout] else {
            return .failed("Health could not return the sessions to check.")
        }

        var out: Set<String> = []
        for w in found {
            let mine = HKQuery.predicateForObjects(from: w)
            guard let routes = await samples(of: HKSeriesType.workoutRoute(),
                                             matching: mine) else {
                return .failed("a route query returned an error.")
            }
            if !routes.isEmpty { out.insert(w.uuid.uuidString) }
        }
        return .measured(out)
    }''',
    "the failures name themselves instead of noting an error",
)

# ------------------------------------------------ the report carries the why

edit(
    C,
    r'''    struct Report: Equatable, Sendable {
        let reading: Reading
        let months: [Month]
        let thinness: Thinness
        let generated: String''',
    r'''    struct Report: Equatable, Sendable {
        let reading: Reading
        let months: [Month]
        let thinness: Thinness
        /// Why the route census did or did not run, in the census's own words.
        /// Empty when nothing asked. 285 printed "Routes were NOT measured"
        /// and could not say why, which is half an answer.
        let routeNote: String
        let generated: String''',
    "the report carries the route note",
)

edit(
    C,
    r'''    static func build(health: [HealthWorkout],
                      activities: [Activity],
                      months keys: [String],
                      reading: Reading,
                      generated: String) -> Report {''',
    r'''    static func build(health: [HealthWorkout],
                      activities: [Activity],
                      months keys: [String],
                      reading: Reading,
                      generated: String,
                      routeNote: String = "") -> Report {''',
    "build takes the note",
)

edit(
    C,
    r'''        return Report(reading: reading,
                      months: keys.compactMap { byMonth[$0] },
                      thinness: thin,
                      generated: generated)''',
    r'''        return Report(reading: reading,
                      months: keys.compactMap { byMonth[$0] },
                      thinness: thin,
                      routeNote: routeNote,
                      generated: generated)''',
    "the note reaches the report",
)

edit(
    C,
    r'''        if r.thinness.sessions > 0 && !r.thinness.routesRead {
            out.append("Routes were NOT measured on this run — the counts above "
                     + "say nothing about how many have one.")
        }''',
    r'''        if r.thinness.sessions > 0 && !r.thinness.routesRead {
            out.append(r.routeNote.isEmpty
                       ? "Routes were NOT measured on this run — the counts "
                       + "above say nothing about how many have one."
                       : r.routeNote + " The counts above say nothing about "
                       + "how many have one.")
        }''',
    "the paste says why",
)

# ------------------------------------------------------------------ the view

edit(
    V,
    r'''        let alone = found.filter(\.stravaAlone)
        if !alone.isEmpty, let routed = await health.routes(for: alone) {
            let ids = Set(alone.map(\.id))
            for i in found.indices where ids.contains(found[i].id) {
                found[i].hasRoute = routed.contains(found[i].id)
            }
        }''',
    r'''        let alone = found.filter(\.stravaAlone)
        var routeNote = ""
        if !alone.isEmpty {
            let census = await health.routes(for: alone)
            routeNote = census.line
            if let routed = census.ids {
                let ids = Set(alone.map(\.id))
                for i in found.indices where ids.contains(found[i].id) {
                    found[i].hasRoute = routed.contains(found[i].id)
                }
            }
        }''',
    "the view keeps the census's reason",
)

edit(
    V,
    r'''        report = HealthCoverage.build(health: found,
                                      activities: ActivityStore.shared.activities,
                                      months: keys,
                                      reading: outcome,
                                      generated: AppVersion.stamp)''',
    r'''        report = HealthCoverage.build(health: found,
                                      activities: ActivityStore.shared.activities,
                                      months: keys,
                                      reading: outcome,
                                      generated: AppVersion.stamp,
                                      routeNote: routeNote)''',
    "the note reaches the build",
)

edit(
    V,
    r'''                    LabeledContent("  of those, with a route",
                                   value: r.thinness.routesRead
                                   ? "\(r.thinness.withRoute)"
                                   : "not measured")''',
    r'''                    LabeledContent("  of those, with a route",
                                   value: r.thinness.routesRead
                                   ? "\(r.thinness.withRoute)"
                                   : "not measured")
                    if !r.thinness.routesRead && !r.routeNote.isEmpty {
                        Text(r.routeNote)
                            .font(.caption2).foregroundStyle(Color.accent4)
                    }''',
    "the screen says why",
)

# ----------------------------------------------------------- HealthTypeTests

edit(
    TT,
    r'''    /// The seven the app actually reads, named. If this list changes, the
    /// purpose string shown at the permission prompt has to change with it —
    /// that string is the user-facing half of the same claim.
    @Test("Exactly the seven documented types are requested")
    func requestedTypesAreTheDocumentedSeven() {
        let types = HealthStore.shared.typesRead
        #expect(types.count == 7, "requesting \(types.count) types, expected 7")

        let identifiers = Set(types.map(\.identifier))
        let expected: Set<String> = [
            HKQuantityTypeIdentifier.stepCount.rawValue,
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
            HKQuantityTypeIdentifier.restingHeartRate.rawValue,
            HKQuantityTypeIdentifier.distanceSwimming.rawValue,
            HKQuantityTypeIdentifier.heartRate.rawValue,
            HKQuantityTypeIdentifier.distanceCycling.rawValue,
            HKObjectType.workoutType().identifier
        ]''',
    r'''    /// The eight the app actually reads, named. If this list changes, the
    /// purpose string shown at the permission prompt has to change with it —
    /// that string is the user-facing half of the same claim.
    @Test("Exactly the eight documented types are requested")
    func requestedTypesAreTheDocumentedEight() {
        let types = HealthStore.shared.typesRead
        #expect(types.count == 8, "requesting \(types.count) types, expected 8")

        let identifiers = Set(types.map(\.identifier))
        let expected: Set<String> = [
            HKQuantityTypeIdentifier.stepCount.rawValue,
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
            HKQuantityTypeIdentifier.restingHeartRate.rawValue,
            HKQuantityTypeIdentifier.distanceSwimming.rawValue,
            HKQuantityTypeIdentifier.heartRate.rawValue,
            HKQuantityTypeIdentifier.distanceCycling.rawValue,
            HKObjectType.workoutType().identifier,
            // Patch 286. Queried by the coverage census since 285 and absent
            // from this set until now — HK-02, second occurrence.
            HKSeriesType.workoutRoute().identifier
        ]''',
    "the pinned set becomes eight",
)

edit(
    TT,
    r'''    /// The specific regression. Worth its own named test so a failure says what
    /// broke rather than "a set did not match".
    @Test("Cycling distance is requested, not just read")
    func cyclingDistanceIsRequested() {
        let ids = HealthStore.shared.typesRead.map(\.identifier)
        #expect(ids.contains(HKQuantityTypeIdentifier.distanceCycling.rawValue),
                "distanceCycling is read when enriching a ride and must be requested (HK-02)")
    }''',
    r'''    /// The specific regression. Worth its own named test so a failure says what
    /// broke rather than "a set did not match".
    @Test("Cycling distance is requested, not just read")
    func cyclingDistanceIsRequested() {
        let ids = HealthStore.shared.typesRead.map(\.identifier)
        #expect(ids.contains(HKQuantityTypeIdentifier.distanceCycling.rawValue),
                "distanceCycling is read when enriching a ride and must be requested (HK-02)")
    }

    /// THE SECOND OCCURRENCE OF THE SAME DEFECT, pinned the same way.
    ///
    /// Patch 285 added a route query and did not add the type. HealthKit
    /// answers an unrequested read with an empty result, so the census
    /// reported nothing and read as a phone with no routes — the identical
    /// failure the header of this file describes for cycling distance, two
    /// screens above the query that repeated it.
    @Test("Workout routes are requested, not just read")
    func workoutRoutesAreRequested() {
        let ids = HealthStore.shared.typesRead.map(\.identifier)
        #expect(ids.contains(HKSeriesType.workoutRoute().identifier),
                "the coverage census reads routes and must request them (HK-02, 285)")
    }

    /// The guard that makes the next one of these visible in one run rather
    /// than in a report nobody can interpret: the census asks `typesRead`
    /// before it queries, so an unrequested type is a named refusal instead of
    /// an empty answer.
    @Test("The census refuses to query a type that was never requested")
    func theCensusRefusesAnUnrequestedType() {
        let ids = HealthStore.shared.typesRead.map(\.identifier)
        let requested = ids.contains(HKSeriesType.workoutRoute().identifier)
        // With the type present the guard must not fire; this asserts the two
        // are wired to each other rather than agreeing by accident.
        #expect(requested, "the guard reads this same list")
        #expect(HealthStore.RouteCensus.notRequested.line
                    .localizedCaseInsensitiveContains("never asked permission"),
                "the refusal has to say what went wrong, not just that it did")
    }''',
    "routes are pinned, and the guard is named",
)

edit(
    TT,
    r'''        let subjects = ["step", "walking", "running", "cycling",
                        "swim", "workout", "heart rate", "resting"]''',
    r'''        let subjects = ["step", "walking", "running", "cycling",
                        "swim", "workout", "route", "heart rate", "resting"]''',
    "the prompt must name routes",
)

# ------------------------------------------------------------------------ ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.32 HK-02, a second time — patch 286

### 12.32.1 What happened

Patch 285 added a route census and queried `HKSeriesType.workoutRoute()`. The
type was not in `HealthStore.typesRead`, so the app had never asked permission
to read it. **HealthKit answers an unrequested read with an empty result and no
error**, which is indistinguishable from a phone that has no routes.

This is HK-02 — `distanceCycling` read in one file and absent from the request
in another — and `HealthTypeTests`' own header describes it in exactly these
words, two screens above the query that repeated it.

### 12.32.2 The design held, which is the only reason it was noticed

The census returned nothing and the report said **"Routes were NOT measured on
this run"** rather than "0 of 53 have a route".

That is `hasRoute: Bool?` and `Thinness.routesRead` doing what §12.31.3 built
them for, on their first live run. With the obvious `[]` in place of the
optional, this defect would have produced a plausible, quotable, entirely
fabricated finding — *"none of the 53 has a route"* — and it would have gone
into the plan as evidence.

**The measurement that did work is the one that mattered anyway.** 0 of 53 have
a heart-rate band wider than a single value: every session Strava alone wrote
holds one reading, not samples. 42 carry a distance, 11 carry nothing at all.
The thinness question is answered whichever way the route census comes back.

### 12.32.3 The guard: refuse to query what was never requested

`typesRead` gains the type, `typesReadDescribed` gains "Workout routes",
`authVersion` goes to 6 so an install that has already granted the other seven
is prompted once more, and `HealthTypeTests` pins all three.

But the pin only fires when somebody adds a *type*. It cannot fire when
somebody adds a *query* — which is what happened here, and what happened in
HK-02. So `routes(for:)` now asks `typesRead` before it queries and returns
`.notRequested` when the type is absent.

**That check has to be before the query, not after**, because after the query
there is nothing to see: an empty result is what success and this failure both
look like.

### 12.32.4 `Set<String>?` was half an answer

285 returned an optional to distinguish "no finding" from "no routes", which
was right and insufficient: when it happened, the screen could not say which of
four causes it was. `RouteCensus` names them — unavailable, never asked, no
usage description, not requested, failed — and the report carries the sentence
through to the paste.

The pattern is now three deep and should be recognisable as one thing:
`StoreLoad` (§12.15) for a file, `Reading` (§12.28.3) for the whole query,
`RouteCensus` here for one measure inside it. **A diagnostic that cannot say
why it has no answer will eventually be read as having one.**

### 12.32.5 The prompt string is a build setting, and stays one

`usageDescriptionNamesEveryTypeRead` reads
`INFOPLIST_KEY_NSHealthShareUsageDescription` out of the built product and
holds it to `typesRead`. It lives in the target's build settings, which no
patch reaches, so this patch ships red until the string names routes.

That is the intended behaviour rather than an inconvenience: PRIV-02 was a
prompt describing one type while seven were requested, and the only reason it
cannot recur is that the test refuses to pass until a human changes the string.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.32",
)


def fail(msg):
    print("STOPPED — nothing was changed.")
    print("  " + msg)
    sys.exit(1)


buffers, applied = {}, []
for path, old, new, why in EDITS:
    if not path.exists():
        fail(f"missing: {path}")
    text = buffers.get(path, path.read_text())
    if new in text:
        fail(f"already applied? {path.name} — {why}")
    n = text.count(old)
    if n != 1:
        fail(f"{path.name} — {why}: expected one match, found {n}")
    buffers[path] = text.replace(old, new)
    applied.append((path, why))

if "--check" in sys.argv:
    print(f"All {len(applied)} anchors found. Nothing written (--check).")
    sys.exit(0)

for path, text in buffers.items():
    path.write_text(text)
for path, why in applied:
    print(f"  {path.relative_to(ROOT)} — {why}")
print(f"Done. {len(buffers)} files, {len(applied)} edits.")
