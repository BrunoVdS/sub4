#!/usr/bin/env python3
"""
Patch 283 — name the days, and count both sides the same way.

Patch 282 measured Health coverage and left two blind spots in its own report:

  1. It counted HEALTH by discipline and the APP only in total, so the two
     columns could not be compared and the obvious question — does Health have
     my commutes? — had no answer on the screen.
  2. It reported "3 training days are in the app and not in Health" as a NUMBER.
     Acting on that means opening those days in the app, and a count sends the
     reader looking while a date sends them to the session.

Both are fixed here. No new files, so no ⌘Q.

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


C = "Sub4/HealthCoverage.swift"
V = "Sub4/HealthCoverageView.swift"
T = "Sub4CoreTests/HealthCoverageTests.swift"

# ------------------------------------------------------------ Month: fields

edit(
    C,
    r'''        // What the app holds
        var storedSessions = 0
        var storedDays = 0

        // Day-level presence, which needs no matcher
        var daysHealthOnly = 0
        var daysStoredOnly = 0

        /// Days on both sides. Not "sessions that agree" — see the header.
        var daysBoth: Int { days - daysHealthOnly }''',
    r'''        // What the app holds.
        //
        // COUNTED THE SAME WAY AS HEALTH SINCE 283. The first report counted
        // Health by discipline and the app only in total, so the two sides
        // could not be compared — and on the real data that mattered: Health
        // held 710 sessions to the app's 668, of which 131 were walks and
        // other types the app does not track, which means the app held more of
        // the tracked disciplines. The report had no way to say so.
        var storedSessions = 0
        var storedDays = 0
        var storedRuns = 0
        var storedRides = 0
        var storedSwims = 0
        var storedStrength = 0
        var storedOther = 0

        // Day-level presence, which needs no matcher.
        //
        // THE DATES THEMSELVES SINCE 283, not the counts. "3 training days are
        // in the app and not in Health" is a finding somebody has to act on,
        // and acting on it means opening those three days in the app. A count
        // sends the reader looking; a date sends them to the session.
        var datesHealthOnly: [String] = []
        var datesStoredOnly: [String] = []

        var daysHealthOnly: Int { datesHealthOnly.count }
        var daysStoredOnly: Int { datesStoredOnly.count }

        /// Days on both sides. Not "sessions that agree" — see the header.
        var daysBoth: Int { days - daysHealthOnly }''',
    "the stored discipline split and the dates",
)

# ------------------------------------------------------------ Month: totals

edit(
    C,
    r'''                t.storedSessions += m.storedSessions
                t.storedDays += m.storedDays
                t.daysHealthOnly += m.daysHealthOnly
                t.daysStoredOnly += m.daysStoredOnly
            }''',
    r'''                t.storedSessions += m.storedSessions
                t.storedDays += m.storedDays
                t.storedRuns += m.storedRuns; t.storedRides += m.storedRides
                t.storedSwims += m.storedSwims
                t.storedStrength += m.storedStrength
                t.storedOther += m.storedOther
                // CONCATENATED, not counted. `daysStoredOnly` is computed from
                // this now, so the total cannot drift from the months under it
                // — which is the failure the first version was one edit away
                // from, since it summed one field and set the other.
                t.datesHealthOnly += m.datesHealthOnly
                t.datesStoredOnly += m.datesStoredOnly
            }''',
    "the totals carry both",
)

# ---------------------------------------------------------- the stored side

edit(
    C,
    r'''        for a in activities {
            let key = String(a.dayKey.prefix(7))
            guard var m = byMonth[key] else { continue }
            m.storedSessions += 1
            byMonth[key] = m
            storedDays[key, default: []].insert(a.dayKey)
        }''',
    r'''        for a in activities {
            let key = String(a.dayKey.prefix(7))
            guard var m = byMonth[key] else { continue }
            m.storedSessions += 1
            // THE SAME SWITCH AS THE HEALTH SIDE, deliberately written out
            // rather than shared. `Activity.discipline` and `HealthWorkout
            // .sport` are both `Discipline?` today; they are computed from
            // different things — a Strava `sportType` string and an
            // `HKWorkoutActivityType` — and a shared helper would quietly
            // couple two mappings that are allowed to disagree.
            switch a.discipline {
            case .run:      m.storedRuns += 1
            case .bike:     m.storedRides += 1
            case .swim:     m.storedSwims += 1
            case .strength: m.storedStrength += 1
            default:        m.storedOther += 1
            }
            byMonth[key] = m
            storedDays[key, default: []].insert(a.dayKey)
        }''',
    "the app is counted by discipline",
)

edit(
    C,
    r'''            m.days = h.count
            m.storedDays = s.count
            m.daysHealthOnly = h.subtracting(s).count
            m.daysStoredOnly = s.subtracting(h).count''',
    r'''            m.days = h.count
            m.storedDays = s.count
            // SORTED, so two runs over unchanged data produce the same report
            // and a diff between them means the data moved.
            m.datesHealthOnly = h.subtracting(s).sorted()
            m.datesStoredOnly = s.subtracting(h).sorted()''',
    "the dates are kept, sorted",
)

# ----------------------------------------------------------------- the paste

edit(
    C,
    r'''        out.append(row(r.total))
        out.append("")
        out.append("Days, not sessions: a day on both sides is counted as covered "
                 + "even if the two sessions on it differ. Routes are not measured "
                 + "— see HealthCoverage.swift.")
        return out.joined(separator: "\n")''',
    r'''        out.append(row(r.total))

        // THE COMPARISON THE FIRST VERSION COULD NOT MAKE — 283.
        let t = r.total
        out.append("")
        out.append("discipline | health |    app")
        for (name, h, a) in [("run", t.runs, t.storedRuns),
                             ("ride", t.rides, t.storedRides),
                             ("swim", t.swims, t.storedSwims),
                             ("strength", t.strength, t.storedStrength),
                             ("other", t.other, t.storedOther)] {
            out.append("\(name)\(String(repeating: " ", count: max(0, 10 - name.count)))"
                     + " | \(pad(h, 6)) | \(pad(a, 6))")
        }

        // EVERY DATE, UNCAPPED. A report that says "3 days" and lists two of
        // them reads as complete. If this ever runs to hundreds of lines that
        // is the finding, not a formatting problem.
        if !t.datesStoredOnly.isEmpty {
            out.append("")
            out.append("Training days in the app and NOT in Health — "
                     + "\(t.datesStoredOnly.count). Each one is a day a "
                     + "disconnect would destroy with nothing to put in its place:")
            for d in t.datesStoredOnly { out.append("  " + d) }
        }
        if !t.datesHealthOnly.isEmpty {
            out.append("")
            out.append("Days in Health and not in the app — "
                     + "\(t.datesHealthOnly.count). Not a shortfall; Health "
                     + "knowing more is not a loss:")
            for d in t.datesHealthOnly { out.append("  " + d) }
        }

        out.append("")
        out.append("Days, not sessions: a day on both sides is counted as covered "
                 + "even if the two sessions on it differ. Routes are not measured "
                 + "— see HealthCoverage.swift.")
        return out.joined(separator: "\n")''',
    "the discipline table and the dates",
)

edit(
    C,
    r'''    private static func row(_ m: Month) -> String {
        func p(_ n: Int, _ w: Int) -> String {
            String(repeating: " ", count: max(0, w - "\(n)".count)) + "\(n)"
        }''',
    r'''    /// Right-aligned in `w` columns. Lifted out of `row` in 283 so the
    /// discipline table can use it too.
    private static func pad(_ n: Int, _ w: Int) -> String {
        String(repeating: " ", count: max(0, w - "\(n)".count)) + "\(n)"
    }

    private static func row(_ m: Month) -> String {
        func p(_ n: Int, _ w: Int) -> String { pad(n, w) }''',
    "the padding helper is shared",
)

# ------------------------------------------------------------------- the view

edit(
    V,
    r'''                LabeledContent("The app holds", value: "\(t.storedSessions)")
            }''',
    r'''                LabeledContent("The app holds", value: "\(t.storedSessions)")
                LabeledContent("  run / ride / swim / strength / other",
                               value: "\(t.storedRuns) / \(t.storedRides) / "
                                    + "\(t.storedSwims) / \(t.storedStrength) / "
                                    + "\(t.storedOther)")
            }''',
    "the app's discipline split on screen",
)

edit(
    V,
    r'''                LabeledContent("Days only in the app", value: "\(t.daysStoredOnly)")
                    .foregroundStyle(t.daysStoredOnly > 0 ? Color.red : Color.ink)''',
    r'''                LabeledContent("Days only in the app", value: "\(t.daysStoredOnly)")
                    .foregroundStyle(t.daysStoredOnly > 0 ? Color.red : Color.ink)
                // NAMED, NOT COUNTED — 283. The number is what you read; the
                // dates are what you act on. Capped on screen because a list
                // is not a view, and the remainder is SAID rather than
                // silently dropped — the paste has all of them.
                ForEach(Array(t.datesStoredOnly.prefix(20)), id: \.self) { d in
                    Text(d).font(.caption).foregroundStyle(Color.dim)
                }
                if t.datesStoredOnly.count > 20 {
                    Text("+ \(t.datesStoredOnly.count - 20) more — copy the report")
                        .font(.caption2).foregroundStyle(Color.dim)
                }''',
    "the dates on screen",
)

# ---------------------------------------------------------------------- tests

edit(
    T,
    r'''    // MARK: Who wrote it''',
    r'''    // MARK: Naming the days — 283

    /// THE POINT OF 283. "3 training days" is a number somebody has to act on,
    /// and acting on it means opening those days in the app.
    @Test("The days the app has and Health does not are named, not counted")
    func theMissingDaysAreNamed() {
        let r = build([workout("2025-07-04")],
                      [activity("2025-07-04"), activity("2025-07-19"),
                       activity("2025-07-11")])
        // SORTED, so two runs over unchanged data give the same report.
        #expect(r.total.datesStoredOnly == ["2025-07-11", "2025-07-19"])
        #expect(r.total.daysStoredOnly == 2, "the count is derived from the list")
    }

    @Test("The dates reach the paste, all of them")
    func theDatesReachThePaste() {
        let r = build([workout("2025-07-04")],
                      [activity("2025-07-04"), activity("2025-07-19")])
        let text = HealthCoverage.text(r)
        #expect(text.contains("2025-07-19"))
        #expect(text.contains("and NOT in Health"))
    }

    @Test("Days Health has and the app does not are named separately")
    func theExtraDaysAreNamedSeparately() {
        let r = build([workout("2025-07-04"), workout("2025-07-06")],
                      [activity("2025-07-04")])
        #expect(r.total.datesHealthOnly == ["2025-07-06"])
        #expect(r.total.datesStoredOnly.isEmpty)
    }

    /// The count is computed from the list, so a total that summed one and set
    /// the other cannot drift. That was one edit away from happening.
    @Test("Totals concatenate the dates rather than counting them twice")
    func totalsConcatenateTheDates() {
        let r = build([],
                      [activity("2025-07-04"), activity("2025-08-02")],
                      months: ["2025-07", "2025-08"])
        #expect(r.total.datesStoredOnly == ["2025-07-04", "2025-08-02"])
        #expect(r.total.daysStoredOnly == 2)
    }

    // MARK: Both sides counted the same way — 283

    /// The first report counted Health by discipline and the app only in
    /// total, so "does Health have my commutes?" had no answer on the screen.
    @Test("The app is counted by discipline, like Health")
    func theAppIsCountedByDiscipline() {
        let acts = [activity("2025-07-04"), activity("2025-07-05")]
        let r = build([], acts)
        let t = r.total
        #expect(t.storedSessions == 2)
        #expect(t.storedRuns == 2, "both fixtures are runs")
        #expect(t.storedRides == 0)
        #expect(t.storedRuns + t.storedRides + t.storedSwims
                + t.storedStrength + t.storedOther == t.storedSessions,
                "the split must account for every stored session")
    }

    @Test("The discipline comparison reaches the paste")
    func theDisciplineTableReachesThePaste() {
        let r = build([workout("2025-07-04")], [activity("2025-07-04")])
        let text = HealthCoverage.text(r)
        #expect(text.contains("discipline | health |"))
        #expect(text.contains("ride"))
    }

    // MARK: Who wrote it''',
    "the 283 tests",
)

# ------------------------------------------------------------------------ ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.29 What M0 measured, and the two blind spots in its own report — patch 283

### 12.29.1 The measurement

Run on the device at patch 282, over 2025-07-01 to 2026-08-06:

| | |
|---|---|
| Health sessions | **710** across **322** training days |
| by discipline | 113 run · 404 ride · 54 swim · 8 strength · 131 other |
| carrying a distance | 557 (78%) |
| carrying a heart rate | 619 (87%) |
| the app holds | **668** across **322** days |
| days in both | **319** |
| days only in Health | 3 |
| **days only in the app** | **3** — two in 2026-05, one in 2026-06 |
| sessions naming Strava as a writer | 102 |
| **sessions Strava alone wrote** | **53** (7.5%) |

**ADR-0002's central worry does not hold.** July 2025 — the first month of the
window, and the one the follow-up named — shows Health with 63 sessions across
28 days against the app's 52 across the same 28. Health has *more*, from the
start. **The bulk-export bridge comes off the critical path.**

The shortfall is three days, all of them recent. Recorded here as the finding;
ADR-0002 requires it to be accepted in writing rather than met at the receipt,
and that acceptance belongs in the cutover plan, not in this file.

### 12.29.2 Blind spot one: the two sides were not counted the same way

The report counted Health by discipline and the app only in total. On this data
that mattered immediately: 710 against 668 looks like Health holding more,
until you notice 131 of Health's are walks and other types the app does not
track. Take those out and Health holds 579 of the tracked disciplines against
the app's 668 — **the app holds more**, by tens of sessions, while day coverage
sits at 99%.

Which means those sessions land on days that are already covered. The obvious
candidate is commute rides: two legs a day, where Strava has both and the watch
or Health recorded one.

The report could not say any of that, and the fix is one field per discipline
on the stored side. The switch is **written out rather than shared** with the
Health side: `Activity.discipline` and `HealthWorkout.sport` are both
`Discipline?` today, but they are computed from a Strava `sportType` string and
an `HKWorkoutActivityType` respectively, and a shared helper would couple two
mappings that are allowed to disagree.

### 12.29.3 Blind spot two: a number nobody could act on

*"3 training days are in the app and not in Health"* is a finding whose only
possible next step is opening those three days in the app. The report gave a
count. **A count sends the reader looking; a date sends them to the session.**

So `Month` carries `datesStoredOnly` and `datesHealthOnly`, and the counts are
computed from them. That direction matters: the previous version summed
`daysStoredOnly` in `total` and set it in `build`, which is two places holding
one fact and one edit away from disagreeing — §12.25's defect in miniature.

**Uncapped in the paste.** A report that says "3 days" and lists two of them
reads as complete. If it ever runs to hundreds of lines, that is the finding
rather than a formatting problem. The on-screen list is capped at twenty
because a list is not a view, and the remainder is stated rather than dropped.

### 12.29.4 What this does not answer, and what does

Session-level agreement. Day coverage at 99% is consistent with tens of
sessions differing, and §12.29.2 says they probably do. That is **D6c shadow
parity's** question, and the tool for it already exists: `HealthReconcile
.build` matches sessions, and it is filtered on both sides to the ones the app
reasons about — which excludes commutes, which is exactly where the difference
will be.

Making that filter a parameter is not a second matcher; it is the same matcher
with the filter as an argument, so §12.28.4's objection does not apply to it.
That is the next piece of work, and it belongs before D6c rather than during.

**And the 53.** Whether a session Strava alone wrote carries a route or heart-
rate samples is still unmeasured. The set is bounded, so the census §12.28.5
deferred is now 53 queries rather than several hundred. It blocks a purge and
nothing else.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.29",
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
