#!/usr/bin/env python3
"""Validate a Sub4 evidence package, off the device — patch 445, ADR §12.201.

WHY IT IS A SEPARATE PROGRAM
----------------------------
The package exists because Xcode's container download silently omitted the
database, both payload folders and four stores — twice — while the app said
1,380 of 1,380 (§12.186). **A checker that shares code with the thing it checks
inherits its blind spots.** So this reads the package the way a stranger would:
from the filesystem, with the standard library, knowing only the manifest's
shape. It shares not one line with the app.

IT NEVER WRITES
---------------
Not to the package, not beside it, not a journal. SQLite is opened through a
`file:…?mode=ro` URI, and the presence of a journal sidecar is a FAILURE rather
than something to clean up — a validator that tidied its input would destroy the
evidence it was asked to check, and a package is often the only copy of the
state it describes.

WHAT IT CHECKS
--------------
Structure · manifest parse and version · every recorded file present, hashed and
sized · **completeness**: everything the snapshot says it copied is in the
package · declared absences really absent · the snapshot's own manifest agreeing
with the outer one · the database's integrity, foreign keys, migrations and row
counts read FROM THE COPY and compared with what was recorded · no journal
sidecars · path safety · and the pre/post fingerprint boundary.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import sys
from pathlib import Path

SCHEMA_VERSIONS = {1}
MANIFEST = "manifest.json"
REPORT = "support-report.txt"
SNAPSHOT_DIR = "snapshot"
DB_SIDECARS = ("-wal", "-shm", "-journal")


class Report:
    def __init__(self) -> None:
        self.problems: list[str] = []
        self.notes: list[str] = []
        self.checked = 0

    def fail(self, message: str) -> None:
        self.problems.append(message)

    def note(self, message: str) -> None:
        self.notes.append(message)

    def did(self, n: int = 1) -> None:
        self.checked += n


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def unsafe(relative: str) -> str | None:
    """A path a package may not contain."""
    if relative.startswith("/"):
        return "is absolute"
    parts = Path(relative).parts
    if ".." in parts:
        return "climbs out of the package"
    if not relative.strip():
        return "is empty"
    return None


# --- structure --------------------------------------------------------------

def check_structure(package: Path, r: Report) -> dict | None:
    if not package.is_dir():
        r.fail(f"{package} is not a directory")
        return None
    for name in (MANIFEST, REPORT, SNAPSHOT_DIR):
        if not (package / name).exists():
            r.fail(f"{name} is missing from the package")
    r.did(3)

    path = package / MANIFEST
    if not path.is_file():
        return None
    try:
        manifest = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        r.fail(f"{MANIFEST} does not parse: {e}")
        return None
    r.did()

    version = manifest.get("schemaVersion")
    if version not in SCHEMA_VERSIONS:
        r.fail(f"schemaVersion {version!r} is not one this validator knows "
               f"({sorted(SCHEMA_VERSIONS)}) — a package from another version is "
               "not machine-checkable here and must not be read as valid")
    r.did()

    identity = manifest.get("identity") or {}
    if identity.get("captureID") != package.name:
        r.fail(f"the package folder is {package.name!r} and the manifest says "
               f"{identity.get('captureID')!r}")
    r.did()

    snapshot = manifest.get("snapshot") or {}
    if manifest.get("snapshotID") != snapshot.get("id"):
        r.fail(f"snapshotID {manifest.get('snapshotID')!r} does not match the "
               f"snapshot manifest's own id {snapshot.get('id')!r}")
    r.did()
    return manifest


# --- the files it says it carries -------------------------------------------

def check_recorded_files(package: Path, manifest: dict, r: Report) -> None:
    seen: set[str] = set()
    for i, entry in enumerate(manifest.get("snapshotCopy") or []):
        relative = entry.get("path")
        if not isinstance(relative, str):
            r.fail(f"snapshotCopy[{i}] has no path")
            continue
        why = unsafe(relative)
        if why:
            r.fail(f"snapshotCopy[{i}] {relative!r} {why}")
            continue
        if relative in seen:
            r.fail(f"snapshotCopy[{i}] {relative!r} is listed twice")
        seen.add(relative)

        target = package / relative
        if not target.is_file():
            r.fail(f"{relative} is recorded and MISSING from the package")
            continue
        actual, size = sha256_of(target), target.stat().st_size
        if entry.get("sha256") != actual:
            r.fail(f"{relative} is STALE — recorded {str(entry.get('sha256'))[:12]}…, "
                   f"on disk {actual[:12]}…")
        if entry.get("bytes") != size:
            r.fail(f"{relative} is STALE — recorded {entry.get('bytes')} bytes, "
                   f"on disk {size}")
        r.did()


def check_completeness(package: Path, manifest: dict, r: Report) -> None:
    """**THE ONE THE `.xcappdata` FAILS.**

    Everything the snapshot recorded as copied must be in the package, and
    everything it recorded as absent must NOT be. A capture route that omits
    files without saying so passes every hash check ever written — because the
    files it dropped are not in the list it hashes.
    """
    snapshot = manifest.get("snapshot") or {}
    carried = {e.get("path") for e in (manifest.get("snapshotCopy") or [])}

    missing, resurrected = [], []
    for entry in snapshot.get("entries") or []:
        relative = entry.get("relativePath")
        if not isinstance(relative, str):
            continue
        expected = f"{SNAPSHOT_DIR}/{relative}"
        if entry.get("copied"):
            if expected not in carried:
                missing.append(relative)
            r.did()
        elif not entry.get("exists"):
            # A DECLARED ABSENCE. The file was not on the phone, so it may not
            # be in the package — and if it is, the package is describing a
            # different device.
            if (package / expected).exists():
                resurrected.append(relative)
            r.did()

    if missing:
        r.fail(f"{len(missing)} file(s) the snapshot says it copied are not in "
               f"the package: {', '.join(sorted(missing)[:6])}"
               + (" …" if len(missing) > 6 else ""))
    if resurrected:
        r.fail(f"{len(resurrected)} file(s) recorded as NOT PRESENT on the phone "
               f"are in the package anyway: {', '.join(sorted(resurrected)[:6])}")

    inner = package / SNAPSHOT_DIR / MANIFEST
    if not inner.is_file():
        r.fail(f"{SNAPSHOT_DIR}/{MANIFEST} is missing — the snapshot inside the "
               "package cannot describe itself without it")
        return
    try:
        carried_manifest = json.loads(inner.read_text())
    except (OSError, json.JSONDecodeError) as e:
        r.fail(f"{SNAPSHOT_DIR}/{MANIFEST} does not parse: {e}")
        return
    r.did()
    if carried_manifest.get("id") != snapshot.get("id"):
        r.fail("the snapshot manifest inside the package describes a different "
               f"snapshot ({carried_manifest.get('id')!r} vs {snapshot.get('id')!r})")
    if carried_manifest.get("entries") != snapshot.get("entries"):
        r.fail("the snapshot manifest inside the package does not match the one "
               "the outer manifest records")
    r.did()


# --- the database copy ------------------------------------------------------

def check_database(package: Path, manifest: dict, r: Report) -> None:
    recorded = manifest.get("database") or {}
    name = recorded.get("fileName")
    if not isinstance(name, str) or unsafe(name):
        r.fail("the manifest does not name a database copy safely")
        return
    target = package / name
    if not target.is_file():
        r.fail(f"{name} is recorded and MISSING from the package")
        return
    r.did()

    strays = [name + s for s in DB_SIDECARS if (package / (name + s)).exists()]
    if strays:
        r.fail(f"journal sidecars sit beside the database copy ({', '.join(strays)}), "
               "so its hash describes only part of it and its contents may be "
               "older than the last commit")
    r.did()

    actual, size = sha256_of(target), target.stat().st_size
    if recorded.get("sha256") != actual:
        r.fail(f"{name} is STALE — recorded {str(recorded.get('sha256'))[:12]}…, "
               f"on disk {actual[:12]}…")
    if recorded.get("bytes") != size:
        r.fail(f"{name} is STALE — recorded {recorded.get('bytes')} bytes, on disk {size}")
    r.did(2)

    if recorded.get("isSupportedRestoreArtifact"):
        r.fail("the manifest claims the diagnostic copy is a supported restore "
               "artifact. It is not, and Task 9 is where one gets built.")
    r.did()

    # READ-ONLY, and a missing journal is a failure above rather than something
    # to create here. `mode=ro` refuses to write even a hot journal.
    try:
        uri = "file:" + str(target).replace("?", "%3f").replace("#", "%23") + "?mode=ro"
        connection = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as e:
        r.fail(f"{name} could not be opened read-only: {e}")
        return
    # **EVERY READ IS GUARDED, AND THAT IS THE POINT OF THE WHOLE PROGRAM.**
    # A truncated copy raises `database disk image is malformed` on the first
    # PRAGMA. The first draft let that escape as a traceback — a validator that
    # CRASHES on damaged input cannot report on damaged input, which is the only
    # input it exists for. Caught by the low-space fixture on its first run.
    def ask(sql: str, what: str, default):
        try:
            return connection.execute(sql).fetchall()
        except sqlite3.Error as e:
            r.fail(f"{what}: {e}")
            return default

    try:
        rows = ask("PRAGMA quick_check", "the copy could not be integrity-checked", [])
        quick = rows[0][0] if rows else "unreadable"
        if quick != "ok":
            r.fail(f"the database copy fails its own integrity check: {quick}")
        if recorded.get("quickCheck") != quick:
            r.fail(f"the manifest recorded integrity {recorded.get('quickCheck')!r} "
                   f"and the copy answers {quick!r}")
        r.did(2)

        violations = len(ask("PRAGMA foreign_key_check",
                             "the copy's foreign keys could not be checked", []))
        if violations:
            r.fail(f"the database copy has {violations} foreign-key violations")
        if recorded.get("foreignKeyViolations") != violations:
            r.fail(f"the manifest recorded {recorded.get('foreignKeyViolations')} "
                   f"foreign-key violations and the copy has {violations}")
        r.did(2)

        migrations = [row[0] for row in ask(
            "SELECT identifier FROM grdb_migrations ORDER BY identifier",
            "the copy's migration table could not be read", [])]
        if recorded.get("migrations") != migrations:
            r.fail("the migrations in the copy are not the ones the manifest "
                   f"records ({len(migrations)} in the file, "
                   f"{len(recorded.get('migrations') or [])} recorded)")
        r.did()

        names = [row[0] for row in ask(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name",
            "the copy's table list could not be read", [])]
        counts = {}
        for table in names:
            rows = ask(f'SELECT COUNT(*) FROM "{table}"',
                       f"table {table} could not be counted", [])
            if rows:
                counts[table] = rows[0][0]
        r.did(len(names))

        # COUNTED FROM THE COPY, COMPARED WITH WHAT WAS RECORDED. A truncated
        # copy hashes, opens and answers `ok`; only the counts catch it.
        expected = recorded.get("tables") or {}
        for table in sorted(set(counts) | set(expected)):
            if counts.get(table) != expected.get(table):
                r.fail(f"table {table}: the manifest records "
                       f"{expected.get(table, 'no such table')} and the copy holds "
                       f"{counts.get(table, 'no such table')}")
    finally:
        connection.close()


# --- the boundary between the two captures ----------------------------------

def strip_time(fingerprint: dict) -> dict:
    return {k: v for k, v in fingerprint.items() if k != "takenUTC"}


def check_fingerprints(manifest: dict, r: Report) -> None:
    """The package's central claim: nothing moved while it was taken.

    Compared as data, without knowing how Swift encodes a reading — a validator
    that had to model the app's enums would break the day one gained a case,
    and would be checking its model rather than the package.
    """
    before, after = manifest.get("before"), manifest.get("after")
    if not isinstance(before, dict) or not isinstance(after, dict):
        r.fail("the manifest does not carry both fingerprints, so its claim "
               "that nothing moved rests on nothing")
        return
    r.did()
    if strip_time(before) != strip_time(after):
        differing = sorted({k for k in set(before) | set(after)
                            if k != "takenUTC" and before.get(k) != after.get(k)})
        r.fail("the two fingerprints disagree, so something changed while the "
               f"package was being written: {', '.join(differing)}")
    r.did()

    barrier = manifest.get("barrier") or {}
    not_watched = barrier.get("notWatched")
    if not not_watched:
        r.fail("the manifest does not say which locations went unwatched. "
               "'It did not fail' and 'it was not looking' are the same "
               "sentence without that list.")
    else:
        why = barrier.get("notWatchedWhy") or {}
        for name in not_watched:
            if not why.get(name):
                r.fail(f"{name} went unwatched and the manifest gives no reason")
    r.did()

    revisions = manifest.get("revisions") or {}
    if not revisions.get("available") and not revisions.get("why"):
        r.fail("no revision is cited and no reason is given for its absence")
    r.did()


# --- the runner -------------------------------------------------------------

def validate(package: Path) -> int:
    r = Report()
    manifest = check_structure(package, r)
    if manifest is not None:
        check_recorded_files(package, manifest, r)
        check_completeness(package, manifest, r)
        check_database(package, manifest, r)
        check_fingerprints(manifest, r)

    print(f"package: {package}")
    for note in r.notes:
        print(f"     · {note}")
    if r.problems:
        print(f"FAIL — {len(r.problems)} problem(s) after {r.checked} checks")
        for problem in r.problems:
            print(f"     - {problem}")
        return 1
    print(f"ok — {r.checked} checks, no problems")
    return 0


def main(argv: list[str]) -> int:
    packages = [Path(a) for a in argv[1:] if not a.startswith("-")]
    if not packages:
        print(__doc__)
        print("usage: validate-evidence-package.py <package directory…>")
        print()
        print("error: no package given — that is not a pass.", file=sys.stderr)
        return 2
    worst = 0
    for package in packages:
        worst = max(worst, validate(package))
        print()
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv))
