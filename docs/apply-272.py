#!/usr/bin/env python3
"""
Patch 272 — the match decision reaches its table. D4's database half, 1 of 3.

`Matcher` ships whole (it is small and was read end to end). This script edits
the eight files around it: the importer, the verifier, the health screen, the
progress tab, the lifecycle inventory, its test, and the ADR.

Run from ~/Documents/Developer/sub4/Sub4/docs
Stops without changing anything if any anchor is missing or not unique.
  --check   report and write nothing
"""

import os, sys, pathlib

# SUB4_ROOT exists for the PREFLIGHT — patch 272. Every anchor in every one of
# these scripts has so far been verified by the athlete running it, which makes
# him the compiler's first reader as well as its last. Setting SUB4_ROOT lets
# the script be piped to `python3 - --check` against the repository from
# anywhere, with no file written and nothing installed, so a missing anchor is
# found before the zip is built rather than after it is unzipped.
ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


I = "Sub4/Sub4Import.swift"
A = "Sub4/Sub4Import+Authored.swift"
R = "Sub4/Sub4Import+Recording.swift"
V = "Sub4/SemanticVerifier.swift"
H = "Sub4/DatabaseHealthView.swift"
P = "Sub4/ProgressTabView.swift"
L = "Sub4/DataLifecycle.swift"
T = "Sub4CoreTests/DataLifecycleCoordinatorTests.swift"

# ------------------------------------------------------- Sub4Import — report

edit(
    I,
    r'''        // Patch 226. `weatherUnmatched` is NOT a refusal: the schema is''',
    r'''        // Patch 272 — D4's database half, first of three. The athlete's
        // match overrides, which have lived in UserDefaults since the app's
        // first week and had nowhere in the database until now.
        var matchDecisionsSeen = 0
        var matchDecisionsImported = 0
        var matchDecisionsUpdated = 0
        /// A decision naming a recording the app excludes on purpose — the
        /// same shape as `weatherIgnored`, and never counted as seen: "seen"
        /// is work attempted, and this was declined at the door.
        var matchDecisionsIgnored = 0
        /// A decision naming an activity the database does not have, and
        /// nobody knows why.
        ///
        /// HELD BACK RATHER THAN WRITTEN WITH A NULL. The column allows NULL
        /// and it would be the easy thing to write — but NULL already means
        /// "the athlete said nothing satisfied this session". Reusing it here
        /// would make the database state something he never said. Anything
        /// above zero is news, exactly like `weatherUnmatched`.
        var matchDecisionsUnresolved = 0

        // Patch 226. `weatherUnmatched` is NOT a refusal: the schema is''',
    "the match-decision counters",
)

edit(
    I,
    r'''                    proposals: [ProposalStore.Record] = [],''',
    r'''                    proposals: [ProposalStore.Record] = [],
                    matchDecisions: [MatchDecision] = [],''',
    "run takes the decisions",
)

edit(
    I,
    r'''                try importProposals(d, records: proposals, now: now, into: &report)''',
    r'''                try importProposals(d, records: proposals, now: now, into: &report)

                // AFTER THE ACTIVITIES, and here the order is load-bearing
                // rather than tidy — the same dependency weather has. A
                // decision names a STRAVA activity id and `match_decision`
                // references the canonical one, so it resolves through
                // `activity_alias`, which the activity loop above writes.
                try importMatchDecisions(d, decisions: matchDecisions,
                                         now: now, into: &report)''',
    "run imports them",
)

# ------------------------------------------------- Recording — widen a helper

edit(
    R,
    r'''    private nonisolated static func canonicalActivity(_ d: Database,''',
    r'''    /// NOT private since patch 272 — `Sub4Import+Authored` needs the same
    /// resolution for a match decision, and a third copy of a three-line query
    /// is how three copies become four.
    nonisolated static func canonicalActivity(_ d: Database,''',
    "canonicalActivity is shared",
)

# --------------------------------------------------- Authored — the importer

edit(
    A,
    r'''    /// `what` is for reading; `newDetail` is for applying. A skip has no''',
    r'''    // MARK: Match decisions

    /// Where the athlete overrode the matcher — patch 272, ADR-0003 §12.19.
    ///
    /// AUTHORED, LIKE THE TWO ABOVE, and that is why it lives in this file
    /// rather than beside the activities. An override cannot be re-fetched
    /// from anywhere: it is a judgement about which recording satisfied which
    /// planned session, made by the only person who was there.
    ///
    /// THREE OUTCOMES THAT ARE NOT THE SAME THING:
    ///
    ///   named and resolved     the row carries the canonical activity
    ///   explicitly nothing     the row carries NULL — the athlete said no
    ///                          recording satisfied this session
    ///   named and not found    NO ROW, and a counter. See `Report`.
    nonisolated static func importMatchDecisions(
        _ d: Database,
        decisions: [MatchDecision],
        now: String,
        into report: inout Report
    ) throws {
        for decision in decisions {
            // BEFORE IT IS COUNTED AS SEEN — patch 257's rule, applied to a
            // third store. An override of an excluded recording is the
            // exclusion working, not a gap in the import.
            if let external = decision.activityId,
               DataCorrections.isIgnored(id: external) {
                report.matchDecisionsIgnored += 1
                continue
            }

            report.matchDecisionsSeen += 1

            var activityID: String?
            if let external = decision.activityId {
                guard let canonical = try canonicalActivity(d, externalID: external) else {
                    report.matchDecisionsUnresolved += 1
                    continue
                }
                activityID = canonical
            }

            let existing = try String.fetchOne(d, sql: """
                SELECT id FROM match_decision
                WHERE accountID = ? AND planSessionUID = ?
                """, arguments: [accountID, decision.sessionUid])

            do {
                try d.inSavepoint {
                    if let id = existing {
                        try d.execute(sql: """
                            UPDATE match_decision
                            SET activityID = ?, decidedUTC = ?
                            WHERE id = ?
                            """, arguments: [activityID,
                                             iso8601(decision.decided), id])
                    } else {
                        try d.execute(sql: """
                            INSERT INTO match_decision
                              (id, accountID, planSessionUID, activityID, decidedUTC)
                            VALUES (?, ?, ?, ?, ?)
                            """, arguments: [UUID().uuidString, accountID,
                                             decision.sessionUid, activityID,
                                             iso8601(decision.decided)])
                    }
                    return .commit
                }
                if existing != nil { report.matchDecisionsUpdated += 1 }
                else { report.matchDecisionsImported += 1 }
            } catch {
                // The session uid, for the same reason a note's refusal
                // carries it: that is the handle the athlete has on this.
                report.refusals.append(
                    .init(externalID: "match \(decision.sessionUid)",
                          reason: String(describing: error)))
            }
        }
    }

    /// `what` is for reading; `newDetail` is for applying. A skip has no''',
    "importMatchDecisions",
)

# --------------------------------------------------------- SemanticVerifier

edit(
    V,
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],''',
    r'''    static func verify(_ db: Sub4Database,
                       activities: [Activity],
                       shoes: [AthleteStore.Shoe] = [],
                       notes: [NotesStore.Note] = [],
                       matchDecisions: [MatchDecision] = [],''',
    "verify takes the decisions",
)

edit(
    V,
    r'''                checks.append(contentsOf: try countChecks(
                    d, activities: activities, shoes: shoes, notes: notes,
                    weather: weather, zones: zones, streams: streams,
                    details: details, storeIDs: storeIDs))''',
    r'''                checks.append(contentsOf: try countChecks(
                    d, activities: activities, shoes: shoes, notes: notes,
                    matchDecisions: matchDecisions,
                    weather: weather, zones: zones, streams: streams,
                    details: details, storeIDs: storeIDs))''',
    "verify passes them down",
)

edit(
    V,
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],''',
    r'''    static func attempt(_ db: Sub4Database,
                        activities: [Activity],
                        shoes: [AthleteStore.Shoe] = [],
                        notes: [NotesStore.Note] = [],
                        matchDecisions: [MatchDecision] = [],''',
    "attempt takes the decisions",
)

edit(
    V,
    r'''            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, weather: weather, zones: zones,
                              streams: streams, details: details)''',
    r'''            return try verify(db, activities: activities, shoes: shoes,
                              notes: notes, matchDecisions: matchDecisions,
                              weather: weather, zones: zones,
                              streams: streams, details: details)''',
    "attempt passes them on",
)

edit(
    V,
    r'''    private static func countChecks(_ d: Database,
                                    activities: [Activity],
                                    shoes: [AthleteStore.Shoe],
                                    notes: [NotesStore.Note],''',
    r'''    private static func countChecks(_ d: Database,
                                    activities: [Activity],
                                    shoes: [AthleteStore.Shoe],
                                    notes: [NotesStore.Note],
                                    matchDecisions: [MatchDecision],''',
    "countChecks takes the decisions",
)

edit(
    V,
    r'''        let expectedWeather = weather.filter { storeIDs.contains($0.activityId) }.count''',
    r'''        // PATCH 272, and the subtle one. A decision naming an activity the
        // store does not have is held back by the importer rather than written
        // with a NULL — so it must not be expected here either, or every
        // device carrying a stale override would report a permanent
        // disagreement the athlete could do nothing about. "Explicitly
        // nothing" IS expected: it is a row, with a NULL in it.
        let expectedDecisions = matchDecisions.filter {
            guard let id = $0.activityId else { return true }
            return storeIDs.contains(id)
        }.count

        let expectedWeather = weather.filter { storeIDs.contains($0.activityId) }.count''',
    "the expected decision count",
)

edit(
    V,
    r'''            .compare("notes", table: "user_note",
                     expected: notes.count, found: try count(d, "user_note")),''',
    r'''            .compare("notes", table: "user_note",
                     expected: notes.count, found: try count(d, "user_note")),
            .compare("match decisions", table: "match_decision",
                     expected: expectedDecisions,
                     found: try count(d, "match_decision")),''',
    "the match_decision comparison",
)

# ----------------------------------------------------- DatabaseHealthView

edit(
    H,
    r'''                LabeledContent("Reviews",
                               value: "\(r.reviewsImported) new, \(r.reviewsUpdated) refreshed")
                    .font(.caption)''',
    r'''                LabeledContent("Reviews",
                               value: "\(r.reviewsImported) new, \(r.reviewsUpdated) refreshed")
                    .font(.caption)
                // PATCH 272 — the third thing on this screen that cannot be
                // re-fetched from anywhere, so it gets a row of its own rather
                // than being folded into a total it would vanish inside.
                LabeledContent("Match decisions",
                               value: "\(r.matchDecisionsImported) new, \(r.matchDecisionsUpdated) refreshed")
                    .font(.caption)
                if r.matchDecisionsUnresolved > 0 {
                    // NEWS, unlike the two greyed rows below it. A decision
                    // naming an activity that is not here was held back, so
                    // the athlete's correction is not in the database and
                    // nothing else on this screen would say so.
                    LabeledContent("  decision naming a missing activity",
                                   value: "\(r.matchDecisionsUnresolved)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }
                if r.matchDecisionsIgnored > 0 {
                    LabeledContent("  decision on an excluded recording",
                                   value: "\(r.matchDecisionsIgnored)")
                        .font(.caption2).foregroundStyle(Color.dim)
                }''',
    "the match-decision rows",
)

edit(
    H,
    r'''                    proposals: ProposalStore.shared.records,''',
    r'''                    proposals: ProposalStore.shared.records,
                    matchDecisions: Array(Matcher.shared.decisions.values),''',
    "the import call site",
)

edit(
    H,
    r'''                notes: Array(NotesStore.shared.notes.values),
                weather: Array(WeatherStore.shared.byActivity.values),
                zones: AthleteStore.shared.hrZones,''',
    r'''                notes: Array(NotesStore.shared.notes.values),
                matchDecisions: Array(Matcher.shared.decisions.values),
                weather: Array(WeatherStore.shared.byActivity.values),
                zones: AthleteStore.shared.hrZones,''',
    "the verify call site",
)

# ------------------------------------------------------- ProgressTabView

edit(
    P,
    r'''        .task(id: "\(notes.count)·\(activities.count)·\(matcher.overrides.count)") {''',
    r'''        .task(id: "\(notes.count)·\(activities.count)·\(matcher.decisions.count)") {''',
    "the rebuild key",
)

# --------------------------------------------------------- DataLifecycle

edit(
    L,
    r'''            storage: [.preferences(["match.overrides"]),''',
    r'''            // ASKED OF THE STORE, like `LoadThresholds` above and for the
            // reason that test records: this patch CHANGES a key, which is
            // exactly when a literal here and the code that writes it come
            // apart. `Matcher.preferenceKeys` holds two — `match.decisions`,
            // the record shape with the date `match_decision.decidedUTC`
            // requires, and the retired `match.overrides`, still named because
            // a device that has not launched this build still holds it and a
            // key nobody names is a key "Delete local data" cannot remove.
            storage: [.preferences(Matcher.preferenceKeys),''',
    "the storage keys",
)

edit(
    L,
    r'''                   "The match overrides are still in UserDefaults rather than in "
                 + "a transaction (step 3.5.4). `commutes.json` is a file for "
                 + "the same reason notes are: it is the athlete's, and a new "
                 + "preference key would be one more thing D5 has to move."],''',
    r'''                   "The match decisions are still in UserDefaults rather than in "
                 + "a transaction (step 3.5.4), which is also why they are the "
                 + "one authored store with no failable save: UserDefaults has "
                 + "no API to ask whether the write landed. They reach "
                 + "`match_decision` at import since patch 272; D5 makes the "
                 + "row the original rather than the copy.",
                   "Decisions made before patch 272 carry the date of the "
                 + "migration rather than the date they were made — the old "
                 + "shape stored no timestamp and nothing else in the app "
                 + "remembers. `dateIsKnown` records which are which."],''',
    "the gap text",
)

# ------------------------------------------------------------------ the test

edit(
    T,
    r'''            // Matcher
            "match.overrides",''',
    r'''            // Matcher — `match.decisions` since patch 272. Both are listed:
            // the old key still exists on any device that has not launched
            // this build, and the inventory is what "Delete local data" reads.
            "match.decisions", "match.overrides",''',
    "the preference key list",
)

# ---------------------------------------------------------------------- ADR

edit(
    "docs/ADR-0003-database-contract.md",
    r'''## 12.10 The athlete profile, the zones and the resting series''',
    r'''## 12.19 The match decision — D4's database half, 1 of 3, patch 272

`match_decision`, `correction` and `rejection` have existed since the schema
was written and nothing has ever written to them. This is the first.

### 12.19.1 The store did not hold what the table needs

`Matcher.overrides` was `[session uid: activity id]` in UserDefaults, with `""`
for "explicitly nothing". `match_decision.decidedUTC` is NOT NULL, and the
store had no timestamp anywhere — so this is not an import that was waiting to
be written, it is a store that had to learn a fact first.

`CommuteStore` reached the same conclusion in patch 251 and its header says so
in as many words: *"A decision carries its date. Not decoration: the
`correction` table in ADR-0003 §8 wants provenance for exactly this kind of
row, and a decision with no timestamp cannot be reconciled against a later
one."* This is that argument applied to the older of the two stores.

**`""` becomes a real absence.** The empty string existed because a
`[String: String]` in UserDefaults has nowhere to put one.
`match_decision.activityID` is nullable, so both sides can now say it properly.

### 12.19.2 It stays in UserDefaults, and that is the decision

The obvious move is to follow `commutes.json` into Application Support. It is
the wrong move here, and the reason is the ladder: D5 takes what is left in
UserDefaults into typed rows, D7 makes the database authoritative, D8 removes
the JSON writers. **A new JSON store two rungs before the JSON stores are
retired is building something already scheduled for demolition** — and it would
cost the whole legacy-fixture sweep (`LegacyStore`, `LegacyInput`, the
classifier, the reader, the snapshot inventory) to carry a file for three
patches.

**The honest cost, stated rather than skipped.** A `UserDefaults.set` has no
failure to report, so this is the one authored store with no failable-save
path. §12.17's rule is that a write with somebody watching must not report
success it did not have; there is no API to ask UserDefaults whether it
succeeded, so the rule cannot be applied here and is not pretended at. It
becomes applicable at D5, in a transaction. `DataLifecycle`'s gap list now says
this rather than the older, vaguer version.

### 12.19.3 The migration invents a date and admits it

Decisions already on the phone have no timestamp anywhere. The migration stamps
them with the instant it ran and sets `dateIsKnown` to false.

The alternative was to use the planned session's date, which is *plausible* and
is a different fact wearing this one's clothes — the session happened on the
12th; the athlete may have corrected the match in March. This project has
refused that trade twice before (§12.10.3's provenance column, §12.12.5's
apportionment) and refuses it again.

`match_decision` has no column for the distinction, so it lives in the store
and in the import's counters rather than in the table. **That is the right
place for it**: the table records what was decided, and `dateIsKnown` is a fact
about our knowledge of the record, not about the decision.

### 12.19.4 Three outcomes, and one of them writes nothing

| What the store holds | What the table gets |
|---|---|
| an activity id that resolves | the row, with the canonical id |
| explicitly nothing | the row, with NULL |
| an activity id that does not resolve | **no row**, and `matchDecisionsUnresolved` |
| an activity `DataCorrections` excludes | no row, and `matchDecisionsIgnored` |

The third line is the one worth arguing. Writing it with a NULL is easy and the
column allows it — but NULL already means *the athlete said nothing satisfied
this session*, so reusing it would make the database state something he never
said. A held-back row leaves the database silent and a counter loud, which is
the trade §12.9d made when neither name could win.

The fourth is patch 257's rule applied to a third store: an override of an
excluded recording is the exclusion working, and it is never counted as *seen*,
because "seen" means work attempted.

**The verifier had to learn the same rule.** `expectedDecisions` filters by
`storeIDs` exactly as weather does — otherwise a device carrying one stale
override would report a permanent disagreement it could do nothing about, and a
verifier with a known-benign failure is a verifier nobody reads.

## 12.10 The athlete profile, the zones and the resting series''',
    "ADR §12.19",
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
