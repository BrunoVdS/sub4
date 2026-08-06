#!/usr/bin/env python3
"""
Patch 289a — two corrections to 289. Neither is in the repository.

1. `gearComesBackAsTheStoreID` set up the wrong world. It inserted a `gear` row
   with SQL and expected the importer to resolve against it — but the importer
   builds its external-id map from the SHOES it is given, not from the table.
   With `shoes: []` nothing resolved, `activity.gearID` stayed null, and the
   gear reached the reference table instead.

   THE REPOSITORY WAS RIGHT. `back.gearId` came back as "g12345678" — the
   assertion that failed was the one about the canonical column, and it failed
   because the test had not created the state it claimed to. Passing a real
   shoe makes the importer mint the gear row itself, which is the path that
   happens on the phone.

2. Swift 6 warning: "main actor-isolated conformance of 'Activity' to
   'Equatable' cannot be used in nonisolated context". `ActivityLoad` is
   `nonisolated` and carried `[Activity]`, whose synthesised `Equatable` is
   MainActor-isolated in this target. Nothing needs `ActivityLoad` to be
   `Equatable`, so it is dropped rather than worked around — this is an error
   in Swift 6 and a warning is a deadline, not an opinion.

A letter fix-up: ships `AppVersion.swift` with `patch = 289`, `revision = "a"`.

Run from ~/Documents/Developer/sub4/Sub4/docs
  --check   report and write nothing
"""

import os, sys, pathlib

ROOT = (pathlib.Path(os.environ["SUB4_ROOT"]).resolve()
        if os.environ.get("SUB4_ROOT")
        else pathlib.Path(__file__).resolve().parent.parent)
EDITS = []


def edit(path, old, new, why):
    EDITS.append((ROOT / path, old, new, why))


R = "Sub4/ActivityRepository.swift"
T = "Sub4CoreTests/ActivityRepositoryTests.swift"

edit(
    R,
    r'''/// What a read of the activity table produced.
nonisolated enum ActivityLoad: Equatable, Sendable {''',
    r'''/// What a read of the activity table produced.
///
/// NOT `Equatable` — 289a. `Activity`'s synthesised conformance is
/// MainActor-isolated in this target, so a `nonisolated` type carrying
/// `[Activity]` cannot use it: "this is an error in the Swift 6 language
/// mode". Nothing needs to compare two loads, so the conformance is dropped
/// rather than worked around. A warning with a version number on it is a
/// deadline, not an opinion.
nonisolated enum ActivityLoad: Sendable {''',
    "ActivityLoad drops Equatable",
)

edit(
    T,
    r'''    @Test("Gear comes back as the id the store uses, not the canonical one")
    func gearComesBackAsTheStoreID() throws {
        let db = try Sub4Database.inMemory()
        try db.queue.write { d in
            try d.execute(sql: """
                INSERT INTO account (id, label, createdUTC)
                VALUES ('local', 'This phone', '2026-08-06T00:00:00Z')
                """)
            try d.execute(sql: """
                INSERT INTO gear (id, accountID, sourceID, externalID, name, distanceM)
                VALUES ('gear-uuid', 'local', 'strava', 'g12345678', 'Vaporfly', 0)
                """)
        }
        _ = try Sub4Import.run(into: db, activities: [ride(gearId: "g12345678")],
                               shoes: [])

        let canonical = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT gearID FROM activity")
        }
        let back = try #require(ActivityRepository.all(db).activities?.first)

        #expect(canonical == "gear-uuid", "the column holds the canonical id")
        #expect(back.gearId == "g12345678", "and the reader must hand back Strava's")
    }''',
    r'''    /// THE SHOE HAS TO GO THROUGH THE IMPORTER — 289a, and the first version
    /// of this test is the finding. It inserted a `gear` row with SQL and
    /// expected the importer to resolve against it. The importer builds its
    /// external-id map from the SHOES it is handed, not from the table, so
    /// with `shoes: []` nothing resolved and the row took the fallback path.
    ///
    /// The repository was right either way — `gearId` came back — but the test
    /// was proving the fallback while claiming to prove the join.
    @Test("Gear comes back as the id the store uses, not the canonical one")
    func gearComesBackAsTheStoreID() throws {
        let db = try Sub4Database.inMemory()
        let shoe = AthleteStore.Shoe(id: "g12345678", name: "Vaporfly",
                                     distanceM: 412_000, primary: true)
        _ = try Sub4Import.run(into: db, activities: [ride(gearId: "g12345678")],
                               shoes: [shoe])

        let canonical = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT gearID FROM activity")
        }
        let external = try db.queue.read { d in
            try String.fetchOne(d, sql: "SELECT externalID FROM gear")
        }
        let back = try #require(ActivityRepository.all(db).activities?.first)

        #expect(canonical != nil, "the importer minted a gear row and linked it")
        #expect(canonical != "g12345678",
                "and the column holds the CANONICAL id, not Strava's")
        #expect(external == "g12345678")
        #expect(back.gearId == "g12345678", "the reader must hand back Strava's")
    }''',
    "the gear test goes through the importer",
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
