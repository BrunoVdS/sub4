#!/usr/bin/env python3
"""
Patch 285 — are the 53 thin? The census §12.28.5 deferred.

53 of 711 Health sessions were written by Strava alone. They are present and
they are countable, and whether they are a training record is still unmeasured.
A route census over all 711 is several hundred queries; over 53 it is 54.

TWO MEASURES, AND ONE OF THEM IS FREE
  · a route — one query per session, and only for these 53
  · a heart-rate BAND — `HKStatistics` already carries min and max beside the
    average this app was already reading. A summary Strava pushed back holds
    one value, so min equals max. A session the watch recorded holds samples,
    and they do not. `averageHeartRate` cannot tell those apart: both give a
    number.

`hasRoute` is `Bool?` on purpose. `nil` means nobody asked, which is not the
same as "no route" — the same distinction `Reading` makes one level up.

SCOPE CORRECTION, recorded because it was stated wrongly first. The 8 strength
sessions the app holds and Health does not CANNOT be censused here: there is no
Health record to look at. That is a session-matching question and belongs to
the unfiltered reconcile, not to this patch.

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


W = "Sub4/HealthWorkouts.swift"
C = "Sub4/HealthCoverage.swift"
V = "Sub4/HealthCoverageView.swift"
T = "Sub4CoreTests/HealthCoverageTests.swift"

# ------------------------------------------------ HealthWorkout — the fields

edit(
    W,
    r'''    /// Every app that wrote this session into Health. More than one is the
    /// NORMAL case here, not an anomaly — see `dedupe`.
    let sources: [String]''',
    r'''    /// Every app that wrote this session into Health. More than one is the
    /// NORMAL case here, not an anomaly — see `dedupe`.
    let sources: [String]

    /// The heart-rate band Health holds, from the same `HKStatistics` object
    /// the average already came from — so these cost nothing extra.
    ///
    /// THE THINNESS TEST — 285. A session Strava pushed back as a summary
    /// carries ONE heart-rate value, so min equals max. A session a watch
    /// recorded carries samples, and they do not. `averageHeartRate` cannot
    /// tell those apart, because both produce a number.
    let hrMin: Double?
    let hrMax: Double?

    /// Whether Health holds a route for this session.
    ///
    /// `nil` MEANS NOBODY ASKED, which is not the same as "no route" — the
    /// distinction `HealthCoverage.Reading` makes one level up, at field
    /// level. Filled only for the sessions the census actually queried.
    var hasRoute: Bool?

    /// More than one heart-rate value. `nonisolated` because the coverage
    /// report reads it, and that report is nonisolated end to end.
    nonisolated var hasVaryingHeartRate: Bool {
        guard let lo = hrMin, let hi = hrMax else { return false }
        return hi > lo
    }

    /// Written into Health by Strava and by nothing else.
    ///
    /// ONE DEFINITION, TWO READERS — the coverage report counts these and the
    /// census queries them, and a copy of this predicate in each place is how
    /// the two would come to disagree about which sessions they are talking
    /// about. Case-insensitive: the source name is the writer's own display
    /// name, seen as "Strava" and "Strava " on this store.
    nonisolated var stravaAlone: Bool {
        guard !sources.isEmpty else { return false }
        return sources.allSatisfy { $0.localizedCaseInsensitiveContains("strava") }
    }''',
    "the heart-rate band, the route flag and the one definition",
)

edit(
    W,
    r'''            distanceM: [a.distanceM, b.distanceM].compactMap { $0 }.max(),
            // Either copy will do — they describe the same session — but a
            // copy written by an app that only stored a total has none.
            averageHeartRate: a.averageHeartRate ?? b.averageHeartRate,
            sources: names,''',
    r'''            distanceM: [a.distanceM, b.distanceM].compactMap { $0 }.max(),
            // Either copy will do — they describe the same session — but a
            // copy written by an app that only stored a total has none.
            averageHeartRate: a.averageHeartRate ?? b.averageHeartRate,
            sources: names,
            // THE WIDER BAND, and it is the honest answer rather than the
            // convenient one: if the watch recorded samples and Strava pushed
            // back a summary of the same session, Health DOES hold varying
            // heart rate for it. The merged record is what Health knows.
            hrMin: [a.hrMin, b.hrMin].compactMap { $0 }.min(),
            hrMax: [a.hrMax, b.hrMax].compactMap { $0 }.max(),
            // A merged record keeps `base.id`, so a route hanging off the
            // OTHER copy would not be found by querying this one. Moot for the
            // census, which only looks at single-source sessions, and written
            // down because it stops being moot the day something censuses the
            // merged ones.
            hasRoute: a.hasRoute ?? b.hasRoute,''',
    "merged carries the band and the flag",
)

edit(
    W,
    r'''    nonisolated static func make(_ w: HKWorkout) -> HealthWorkout {
        let sport = discipline(for: w.workoutActivityType)
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: w.startDate)

        return HealthWorkout(''',
    r'''    nonisolated static func make(_ w: HKWorkout) -> HealthWorkout {
        let sport = discipline(for: w.workoutActivityType)
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: w.startDate)

        // ONE STATISTICS OBJECT, THREE FIGURES — 285. The average was already
        // being read here; min and max come off the same object for nothing,
        // and they are what tells a recorded session from a pushed summary.
        let hr = w.statistics(for: HKQuantityType(.heartRate))
        let bpm = HKUnit.count().unitDivided(by: .minute())

        return HealthWorkout(''',
    "the statistics object is read once",
)

edit(
    W,
    r'''            averageHeartRate: w.statistics(for: HKQuantityType(.heartRate))?
                .averageQuantity()?
                .doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
            sources: [w.sourceRevision.source.name],
            startMinuteOfDay: (comps.hour ?? 0) * 60 + (comps.minute ?? 0))''',
    r'''            averageHeartRate: hr?.averageQuantity()?.doubleValue(for: bpm),
            sources: [w.sourceRevision.source.name],
            hrMin: hr?.minimumQuantity()?.doubleValue(for: bpm),
            hrMax: hr?.maximumQuantity()?.doubleValue(for: bpm),
            hasRoute: nil,
            startMinuteOfDay: (comps.hour ?? 0) * 60 + (comps.minute ?? 0))''',
    "make fills the band",
)

# --------------------------------------------------------- the route census

edit(
    W,
    r'''    /// Above this many swims the enrichment stops — the totals stay correct,
    /// the later rows simply fall back to the duration field and say so.
    static var maxSwimEnrich: Int { 80 }''',
    r'''    /// Above this many swims the enrichment stops — the totals stay correct,
    /// the later rows simply fall back to the duration field and say so.
    static var maxSwimEnrich: Int { 80 }

    /// Above this many sessions the route census stops rather than running
    /// unbounded. It is one query each, and the set it is pointed at — the
    /// sessions Strava alone wrote — is 53 on this device. A cap is a promise
    /// that a diagnostic cannot become a stampede; the caller is told when it
    /// bites rather than being handed a quietly short answer.
    static var maxRouteCensus: Int { 250 }

    /// Which of these sessions Health holds a route for.
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
        guard !workouts.isEmpty else { return [] }

        let wanted = Array(workouts.prefix(Self.maxRouteCensus))
        let uuids = wanted.compactMap { UUID(uuidString: $0.id) }
        guard !uuids.isEmpty else { return [] }

        let byID = NSCompoundPredicate(orPredicateWithSubpredicates:
            uuids.map { HKQuery.predicateForObject(with: $0) })

        guard let found = await samples(of: .workoutType(), matching: byID) as? [HKWorkout] else {
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
    }

    /// One `HKSampleQuery`, awaited. `nil` on any error, and the continuation
    /// is guarded because HealthKit calling a handler twice would trap — the
    /// same guard the statistics queries in `HealthStore` already carry.
    @MainActor
    private func samples(of type: HKSampleType,
                         matching predicate: NSPredicate) async -> [HKSample]? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, result, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            // `healthStore`, not `store` — the latter is private to
            // HealthStore.swift and this is an extension in another file.
            healthStore.execute(q)
        }
    }''',
    "the route census",
)

# ------------------------------------------------------ the report gains it

edit(
    C,
    r'''    struct Report: Equatable, Sendable {
        let reading: Reading
        let months: [Month]
        let generated: String''',
    r'''    /// What state the sessions Strava alone wrote are actually in — 285.
    ///
    /// They do not disappear on a disconnect; an `HKWorkout` is Apple's once
    /// written. The question is whether they are a training record, and the
    /// answer is a count rather than an adjective.
    struct Thinness: Equatable, Sendable {
        /// FALSE MEANS NOBODY ASKED. Every count below is zero either way, and
        /// only one of the two zeros is a finding.
        var routesRead = false
        var sessions = 0
        var withRoute = 0
        var withVaryingHeartRate = 0
        var withDistance = 0
        /// No route, no varying heart rate, no distance. As thin as a record
        /// gets while still being a record.
        var shells = 0

        var line: String {
            guard sessions > 0 else { return "No sessions were written by Strava alone." }
            let route = routesRead ? "\(withRoute) have a route" : "routes not measured"
            return "\(sessions) written by Strava alone: \(route), "
                 + "\(withVaryingHeartRate) have heart-rate samples rather than one "
                 + "value, \(withDistance) have a distance. \(shells) have none of "
                 + "the three."
        }
    }

    struct Report: Equatable, Sendable {
        let reading: Reading
        let months: [Month]
        let thinness: Thinness
        let generated: String''',
    "the Thinness block",
)

edit(
    C,
    r'''        return Report(reading: reading,
                      months: keys.compactMap { byMonth[$0] },
                      generated: generated)''',
    r'''        // COMPUTED FROM THE SAME ARRAY, not passed in. The census fills
        // `hasRoute` on the workouts before this runs, so there is one place
        // that decides which sessions are Strava's alone — `stravaAlone` on
        // the workout itself — and this cannot come to disagree with the
        // census about which ones it measured.
        var thin = Thinness()
        let alone = health.filter { $0.stravaAlone && keys.contains(String($0.dayKey.prefix(7))) }
        thin.sessions = alone.count
        thin.routesRead = alone.contains { $0.hasRoute != nil }
        for w in alone {
            let route = w.hasRoute == true
            if route { thin.withRoute += 1 }
            if w.hasVaryingHeartRate { thin.withVaryingHeartRate += 1 }
            if w.distanceM != nil { thin.withDistance += 1 }
            if !route && !w.hasVaryingHeartRate && w.distanceM == nil { thin.shells += 1 }
        }

        return Report(reading: reading,
                      months: keys.compactMap { byMonth[$0] },
                      thinness: thin,
                      generated: generated)''',
    "thinness is computed from the workouts",
)

edit(
    C,
    r'''        out.append("")
        out.append("Days, not sessions: a day on both sides is counted as covered "''',
    r'''        out.append("")
        out.append(r.thinness.line)
        if r.thinness.sessions > 0 && !r.thinness.routesRead {
            out.append("Routes were NOT measured on this run — the counts above "
                     + "say nothing about how many have one.")
        }

        out.append("")
        out.append("Days, not sessions: a day on both sides is counted as covered "''',
    "the thinness line in the paste",
)

edit(
    C,
    r'''                 + "even if the two sessions on it differ. Routes are not measured "
                 + "— see HealthCoverage.swift.")''',
    r'''                 + "even if the two sessions on it differ. Routes are measured "
                 + "only for the sessions Strava alone wrote — see "
                 + "HealthCoverage.swift.")''',
    "the footnote stops saying routes are never measured",
)

# ------------------------------------------------------------------ the view

edit(
    V,
    r'''            } header: {
                Text("Who wrote it")
            } footer: {''',
    r'''                if r.thinness.sessions > 0 {
                    LabeledContent("  of those, with a route",
                                   value: r.thinness.routesRead
                                   ? "\(r.thinness.withRoute)"
                                   : "not measured")
                    LabeledContent("  with heart-rate samples, not one value",
                                   value: "\(r.thinness.withVaryingHeartRate)")
                    LabeledContent("  with a distance", value: "\(r.thinness.withDistance)")
                    LabeledContent("  with none of the three", value: "\(r.thinness.shells)")
                        .foregroundStyle(r.thinness.shells > 0 ? Color.accent4 : Color.ink)
                }
            } header: {
                Text("Who wrote it")
            } footer: {''',
    "the thinness rows",
)

edit(
    V,
    r'''        let outcome: HealthCoverage.Reading
        if let now = health.lastError, now != errorBefore { outcome = .failed(now) }
        else { outcome = .read }''',
    r'''        // THE CENSUS — 285. Only the sessions Strava alone wrote, which is 53
        // on this device against 711 in the window. `stravaAlone` is the one
        // definition of that set and the report counts the same property, so
        // the two cannot come to mean different things.
        let alone = found.filter(\.stravaAlone)
        if !alone.isEmpty, let routed = await health.routes(for: alone) {
            let ids = Set(alone.map(\.id))
            for i in found.indices where ids.contains(found[i].id) {
                found[i].hasRoute = routed.contains(found[i].id)
            }
        }

        let outcome: HealthCoverage.Reading
        if let now = health.lastError, now != errorBefore { outcome = .failed(now) }
        else { outcome = .read }''',
    "the view runs the census",
)

# ---------------------------------------------------------------------- tests

edit(
    T,
    r'''    private func workout(_ dayKey: String,
                         sport: Discipline? = .run,
                         distanceM: Double? = 10_000,
                         hr: Double? = 148,
                         sources: [String] = ["Bruno's Apple Watch"],
                         minute: Int = 7 * 60) -> HealthWorkout {
        let start = DayKey.date(dayKey) ?? Date(timeIntervalSince1970: 0)
        return HealthWorkout(id: UUID().uuidString,
                             start: start,
                             end: start.addingTimeInterval(3600),
                             dayKey: dayKey,
                             sport: sport,
                             rawType: "Running",
                             durationSeconds: 3600,
                             activeSeconds: nil,
                             distanceM: distanceM,
                             averageHeartRate: hr,
                             sources: sources,
                             startMinuteOfDay: minute)
    }''',
    r'''    private func workout(_ dayKey: String,
                         sport: Discipline? = .run,
                         distanceM: Double? = 10_000,
                         hr: Double? = 148,
                         sources: [String] = ["Bruno's Apple Watch"],
                         minute: Int = 7 * 60,
                         hrBand: (Double, Double)? = (96, 178),
                         hasRoute: Bool? = nil) -> HealthWorkout {
        let start = DayKey.date(dayKey) ?? Date(timeIntervalSince1970: 0)
        return HealthWorkout(id: UUID().uuidString,
                             start: start,
                             end: start.addingTimeInterval(3600),
                             dayKey: dayKey,
                             sport: sport,
                             rawType: "Running",
                             durationSeconds: 3600,
                             activeSeconds: nil,
                             distanceM: distanceM,
                             averageHeartRate: hr,
                             sources: sources,
                             hrMin: hrBand?.0,
                             hrMax: hrBand?.1,
                             hasRoute: hasRoute,
                             startMinuteOfDay: minute)
    }

    /// A summary pushed back by Strava: one heart-rate value, so the band is
    /// flat. This is what 285 exists to count.
    private func pushedSummary(_ dayKey: String,
                               distanceM: Double? = nil,
                               hasRoute: Bool? = false) -> HealthWorkout {
        workout(dayKey, distanceM: distanceM, hr: 141, sources: ["Strava"],
                hrBand: (141, 141), hasRoute: hasRoute)
    }''',
    "the fixtures carry a band and a route flag",
)

edit(
    T,
    r'''    // MARK: Thinness''',
    r'''    // MARK: Thinness of the Strava-alone set — 285

    @Test("A flat heart-rate band is one value, not samples")
    func aFlatBandIsNotSamples() {
        let summary = pushedSummary("2025-07-04")
        let recorded = workout("2025-07-05")
        #expect(!summary.hasVaryingHeartRate, "141 to 141 is one reading")
        #expect(recorded.hasVaryingHeartRate)
    }

    @Test("No heart rate at all is not varying heart rate")
    func noHeartRateIsNotVarying() {
        let w = workout("2025-07-04", hr: nil, hrBand: nil)
        #expect(!w.hasVaryingHeartRate)
    }

    @Test("Only sessions Strava alone wrote are censused")
    func onlyStravaAloneIsCensused() {
        let r = build([pushedSummary("2025-07-04"),
                       workout("2025-07-05", sources: ["Bruno's Apple Watch", "Strava"]),
                       workout("2025-07-06")], [])
        #expect(r.thinness.sessions == 1, "the co-written one is not Strava's alone")
    }

    /// THE ONE WITH TEETH, and the same shape as the reading guard one level
    /// up: a census that did not run must not read as a census that found
    /// nothing.
    @Test("Routes not asked about never read as routes not found")
    func routesNotAskedAboutAreNotRoutesNotFound() {
        let notAsked = build([pushedSummary("2025-07-04", hasRoute: nil)], [])
        #expect(notAsked.thinness.sessions == 1)
        #expect(notAsked.thinness.routesRead == false)
        #expect(notAsked.thinness.withRoute == 0)
        #expect(notAsked.thinness.line.contains("routes not measured"))
        // And the paste says so out loud rather than printing a bare zero.
        #expect(HealthCoverage.text(notAsked).contains("Routes were NOT measured"))

        let asked = build([pushedSummary("2025-07-04", hasRoute: false)], [])
        #expect(asked.thinness.routesRead)
        #expect(asked.thinness.withRoute == 0)
        #expect(!HealthCoverage.text(asked).contains("Routes were NOT measured"))
    }

    @Test("A shell is a session with none of the three")
    func aShellHasNoneOfTheThree() {
        let r = build([pushedSummary("2025-07-04", hasRoute: false)], [])
        #expect(r.thinness.shells == 1)
        #expect(r.thinness.withRoute == 0)
        #expect(r.thinness.withVaryingHeartRate == 0)
        #expect(r.thinness.withDistance == 0)
    }

    @Test("A Strava-written session that carries things is not a shell")
    func aFullSessionIsNotAShell() {
        let r = build([pushedSummary("2025-07-04", distanceM: 8_400, hasRoute: true)], [])
        #expect(r.thinness.withRoute == 1)
        #expect(r.thinness.withDistance == 1)
        #expect(r.thinness.shells == 0)
    }

    @Test("Merging keeps the wider heart-rate band")
    func mergingKeepsTheWiderBand() {
        let watch = workout("2025-07-04", sources: ["Bruno's Apple Watch"])
        let pushed = pushedSummary("2025-07-04", distanceM: 10_000)
        let merged = HealthWorkout.merged(watch, pushed)
        #expect(merged.hasVaryingHeartRate,
                "Health does hold samples for this session, from the watch copy")
        #expect(!merged.stravaAlone, "two writers is not Strava alone")
    }

    // MARK: Thinness''',
    "the 285 tests",
)

# ------------------------------------------------------------------------ ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.31 Are the 53 thin? — patch 285

### 12.31.1 The question left over from M0

53 of 711 Health sessions were written by Strava and by nothing else. §12.28.2
argued that the exposure is thinness rather than disappearance — an `HKWorkout`
is Apple's once written — and §12.28.5 then declined to measure it, because a
route census over all 711 sessions is several hundred queries for a diagnostic.

Over 53 it is 54. The set being bounded is what makes the census affordable,
and the set is only bounded because the writer breakdown existed first.

### 12.31.2 One of the two measures was already paid for

`make(_:)` was reading `w.statistics(for: .heartRate)?.averageQuantity()`.
The same object carries `minimumQuantity()` and `maximumQuantity()`, and **a
summary pushed back by Strava holds one heart-rate value, so its band is
flat.** A session a watch recorded holds samples, and its band is not.

`averageHeartRate` cannot tell those apart, because both produce a number —
which is why 282's report showed 87% "with a heart rate" and that figure said
less than it appeared to. The band costs nothing: same statistics object, two
more reads.

Routes are the measure that costs. One query per session, and `HKWorkoutRoute`
carries no reference to its own workout, so `predicateForObjects(from:)` is the
only correct join. Matching routes to sessions by time would be a second
matcher against the clock, which is the thing §12.28.4 already refused once.

### 12.31.3 `nil` means nobody asked

`HealthWorkout.hasRoute` is `Bool?`. `false` is a finding; `nil` is the absence
of one. `Thinness.routesRead` carries the same distinction up to the report,
and the paste says *"Routes were NOT measured on this run"* rather than
printing a bare zero.

This is `Reading` from §12.28.3 at field level, and `routes(for:)` returns
`Set<String>?` for the same reason: handing back `[]` on a denial would let a
permissions failure read as *"all 53 are shells"* — which is precisely the
conclusion this census exists to reach honestly or not at all.

### 12.31.4 One definition of the set

`stravaAlone` lives on `HealthWorkout`. The census queries that set and the
report counts that set, and a copy of the predicate in each place is how the
two would come to disagree about which sessions they were talking about —
while both kept reporting confidently.

It is `nonisolated`, and that is a claim rather than tidiness: `HealthCoverage`
is nonisolated end to end, this target defaults to `MainActor`, and a computed
property on a plain struct belongs to the main actor unless it says otherwise.

### 12.31.5 A cap that announces itself

`maxRouteCensus` is 250 against a real set of 53. A cap is a promise that a
diagnostic cannot become a stampede — and one that silently returns a short
answer is worse than no cap, because the report would read as complete. If it
ever bites, the count it reports is the count it measured, and the two are
different numbers on the screen.

### 12.31.6 The scope correction

The eight strength sessions the app holds and Health does not **cannot be
censused here.** There is no Health record to look at. That was stated as part
of this patch's job when it was proposed, and it is a session-matching question
— it belongs to the unfiltered reconcile, alongside the rest of §12.29.4.

Recorded rather than quietly dropped, because a stated scope that shrinks
without comment is how a plan comes to believe it covered something.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.31",
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
