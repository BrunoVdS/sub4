#!/usr/bin/env python3
"""Build synthetic evidence packages for the validator's selftest — patch 445.

**SYNTHETIC AND REDACTED, and the runbook asks for exactly that.** Not one byte
here came off a phone: two tiny JSON files, a four-row SQLite database, and a
manifest in the shape the app writes. A fixture cut from real data would put the
athlete's history in the repository to test a hash comparison.

They are BUILT rather than committed. A package contains a SQLite file, and a
committed binary whose hash has to stay in step with a JSON file beside it is a
fixture that rots the first time either is touched.

Each variant damages exactly one thing, so a failure names the check that caught
it rather than a pile.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sqlite3
import sys
from pathlib import Path

CAPTURE_ID = "2026-08-22-081500"
MIGRATIONS = ["2026-08-03-initial", "2026-08-04-domain"]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write(path: Path, data: bytes) -> tuple[str, int]:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return sha256_bytes(data), len(data)


def build_database(path: Path) -> dict:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    try:
        connection.execute("CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY)")
        for identifier in MIGRATIONS:
            connection.execute("INSERT INTO grdb_migrations VALUES (?)", (identifier,))
        connection.execute("CREATE TABLE account (id TEXT PRIMARY KEY)")
        connection.execute("INSERT INTO account VALUES ('the-account')")
        connection.execute(
            "CREATE TABLE activity (id TEXT PRIMARY KEY, accountID TEXT NOT NULL "
            "REFERENCES account(id))")
        connection.executemany("INSERT INTO activity VALUES (?, 'the-account')",
                               [("a-1",), ("a-2",)])
        connection.commit()
        connection.execute("PRAGMA journal_mode = DELETE")
        counts = {"account": 1, "activity": 2, "grdb_migrations": len(MIGRATIONS)}
    finally:
        connection.close()
    data = path.read_bytes()
    return {
        "fileName": path.name,
        "bytes": len(data),
        "sha256": sha256_bytes(data),
        "sourceJournalMode": "delete",
        "totalPageCount": 3,
        "copiedPageCount": 3,
        "quickCheck": "ok",
        "foreignKeyViolations": 0,
        "migrations": MIGRATIONS,
        "tables": counts,
        "takenUTC": "2026-08-22T08:15:00Z",
        "isSupportedRestoreArtifact": False,
    }


def fingerprint() -> dict:
    return {
        "takenUTC": "2026-08-22T08:15:00Z",
        "items": [
            {"path": "athlete.json", "kind": {"hashed": {"sha256": "a" * 64, "bytes": 23}}},
            {"path": "gone.json", "kind": {"absent": {}}},
        ],
        "tables": {"account": 1, "activity": 2},
        "migrations": MIGRATIONS,
        "quickCheck": "ok",
        "foreignKeyViolations": 0,
        "preferences": {"appearance.selected": "b" * 64},
    }


def build_good(root: Path) -> Path:
    package = root / CAPTURE_ID
    if package.exists():
        shutil.rmtree(package)
    package.mkdir(parents=True)

    files = {
        "athlete.json": b'{"zones":[],"shoes":[]}\n',
        "notes.json": b'{"notes":[]}\n',
        # The preference supplement — the snapshot is preference-inclusive, and
        # `missing-preference` is the variant that removes it.
        "preferences.json": b'{"appearance.selected":"light"}\n',
    }
    entries, copied = [], []
    for name, data in sorted(files.items()):
        digest, size = write(package / "snapshot" / name, data)
        entries.append({"declared": name, "relativePath": name, "exists": True,
                        "bytes": size, "modifiedUTC": "2026-08-22T08:14:00Z",
                        "sha256": digest, "copied": True, "error": None})
        copied.append({"path": f"snapshot/{name}", "sha256": digest, "bytes": size})

    # A DECLARED EMPTY DIRECTORY — recorded as copied with NO hash, which is
    # what LegacySnapshot does on purpose. The first package writer treated it
    # as a file and the device answered "the copy could not be read back".
    (package / "snapshot" / "streams").mkdir(parents=True, exist_ok=True)
    entries.append({"declared": "streams", "relativePath": "streams",
                    "exists": True, "bytes": 0, "modifiedUTC": None,
                    "sha256": None, "copied": True, "error": None})
    copied.append({"path": "snapshot/streams", "sha256": None, "bytes": 0})

    # A DECLARED ABSENCE — a retired format that cannot exist on this install.
    entries.append({"declared": "details.json", "relativePath": "details.json",
                    "exists": False, "bytes": None, "modifiedUTC": None,
                    "sha256": None, "copied": False, "error": None})
    entries.sort(key=lambda e: e["relativePath"])

    snapshot = {"id": CAPTURE_ID, "createdUTC": "2026-08-22T08:14:00Z",
                "appVersion": "patch 445 (fixture)", "entries": entries}
    inner = json.dumps(snapshot, indent=2, sort_keys=True).encode() + b"\n"
    digest, size = write(package / "snapshot" / "manifest.json", inner)
    copied.append({"path": "snapshot/manifest.json", "sha256": digest, "bytes": size})

    database = build_database(package / "database-diagnostic-copy.sqlite")
    shared = fingerprint()

    manifest = {
        "schemaVersion": 1,
        "identity": {"captureID": CAPTURE_ID, "capturedUTC": "2026-08-22T08:15:00Z",
                     "app": "1.0 (1) · patch 445", "patch": 445, "revision": None,
                     "configuration": "Debug", "provenance": "fixture"},
        "snapshotID": CAPTURE_ID,
        "snapshot": snapshot,
        "snapshotCopy": sorted(copied, key=lambda c: c["path"]),
        "database": database,
        "testArtifacts": [],
        "revisions": {"available": [],
                      "why": "content_revision exists as a table and nothing writes it."},
        "barrier": {
            "writersAskedToWait": ["backgroundRefresh", "activitySync"],
            "writersDetectedOnly": ["authoredNotes"],
            "turnedAwayDuringCapture": {},
            "notWatched": ["db", "snapshots", "evidence"],
            "notWatchedWhy": {"db": "a read alone can touch a WAL journal",
                              "snapshots": "the capture's own output",
                              "evidence": "the capture's own output"},
        },
        "before": shared,
        "after": json.loads(json.dumps(shared)),
    }
    manifest["after"]["takenUTC"] = "2026-08-22T08:15:09Z"
    (package / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    (package / "support-report.txt").write_text(
        "Sub4 evidence package (fixture)\nSnapshot 4 files copied\n")
    return package


def load(package: Path) -> dict:
    return json.loads((package / "manifest.json").read_text())


def save(package: Path, manifest: dict) -> None:
    (package / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def variant(root: Path, name: str, damage) -> Path:
    """One package, damaged in exactly one way."""
    good = build_good(root / ".template")
    target = root / name / CAPTURE_ID
    if target.parent.exists():
        shutil.rmtree(target.parent)
    target.parent.mkdir(parents=True)
    shutil.copytree(good, target)
    shutil.rmtree(root / ".template")
    damage(target)
    return target


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: make-evidence-package-fixture.py <directory>", file=sys.stderr)
        return 2
    root = Path(argv[1])
    root.mkdir(parents=True, exist_ok=True)

    build_good(root / "good")

    def drop_database(p: Path):
        (p / "database-diagnostic-copy.sqlite").unlink()

    def drop_preference(p: Path):
        (p / "snapshot" / "preferences.json").unlink()

    def partial_snapshot(p: Path):
        # THE `.xcappdata` SHAPE: the snapshot says it copied a file and the
        # package does not carry it. Every hash in the package still matches.
        m = load(p)
        m["snapshotCopy"] = [c for c in m["snapshotCopy"]
                             if not c["path"].endswith("notes.json")]
        save(p, m)
        (p / "snapshot" / "notes.json").unlink()

    def same_count_changed_file(p: Path):
        # Identical LENGTH, different bytes — the case a size check passes.
        target = p / "snapshot" / "athlete.json"
        data = target.read_bytes()
        target.write_bytes(b"X" + data[1:])

    def tampered_manifest(p: Path):
        m = load(p)
        m["database"]["sha256"] = "f" * 64
        save(p, m)

    def hot_wal(p: Path):
        (p / "database-diagnostic-copy.sqlite-wal").write_bytes(b"\x00" * 32)

    def unsafe_path(p: Path):
        m = load(p)
        m["snapshotCopy"].append({"path": "../escaped.json", "sha256": "c" * 64, "bytes": 1})
        save(p, m)

    def duplicate_path(p: Path):
        m = load(p)
        m["snapshotCopy"].append(dict(m["snapshotCopy"][0]))
        save(p, m)

    def moved_during_capture(p: Path):
        m = load(p)
        m["after"]["tables"]["activity"] = 3
        save(p, m)

    def restore_claim(p: Path):
        m = load(p)
        m["database"]["isSupportedRestoreArtifact"] = True
        save(p, m)

    def unwatched_unexplained(p: Path):
        m = load(p)
        m["barrier"]["notWatchedWhy"] = {}
        save(p, m)

    def bad_version(p: Path):
        m = load(p)
        m["schemaVersion"] = 99
        save(p, m)

    def resurrected_absence(p: Path):
        # A file the snapshot recorded as NOT PRESENT on the phone, in the
        # package anyway — so the package describes a different device.
        (p / "snapshot" / "details.json").write_bytes(b"{}\n")

    def truncated_database(p: Path):
        # What an interrupted or out-of-space copy leaves: a file that opens.
        target = p / "database-diagnostic-copy.sqlite"
        target.write_bytes(target.read_bytes()[: 4096])

    def wrong_capture_id(p: Path):
        m = load(p)
        m["identity"]["captureID"] = "2026-01-01-000000"
        save(p, m)

    def inner_manifest_disagrees(p: Path):
        inner = json.loads((p / "snapshot" / "manifest.json").read_text())
        inner["entries"][0]["sha256"] = "d" * 64
        (p / "snapshot" / "manifest.json").write_text(
            json.dumps(inner, indent=2, sort_keys=True) + "\n")
        # AND the outer record of that file is updated, so only the
        # inner-vs-outer comparison can catch it.
        data = (p / "snapshot" / "manifest.json").read_bytes()
        m = load(p)
        for entry in m["snapshotCopy"]:
            if entry["path"].endswith("snapshot/manifest.json"):
                entry["sha256"] = sha256_bytes(data)
                entry["bytes"] = len(data)
        save(p, m)

    def directory_became_a_file(p: Path):
        # The shape the package must carry, replaced by something else.
        (p / "snapshot" / "streams").rmdir()
        (p / "snapshot" / "streams").write_bytes(b"not a directory\n")

    for name, damage in [
        ("directory-became-a-file", directory_became_a_file),
        ("no-database", drop_database),
        ("missing-preference", drop_preference),
        ("partial-snapshot", partial_snapshot),
        ("same-count-changed-file", same_count_changed_file),
        ("tampered-manifest", tampered_manifest),
        ("hot-wal", hot_wal),
        ("unsafe-path", unsafe_path),
        ("duplicate-path", duplicate_path),
        ("moved-during-capture", moved_during_capture),
        ("restore-claim", restore_claim),
        ("unwatched-unexplained", unwatched_unexplained),
        ("bad-version", bad_version),
        ("resurrected-absence", resurrected_absence),
        ("truncated-database", truncated_database),
        ("wrong-capture-id", wrong_capture_id),
        ("inner-manifest-disagrees", inner_manifest_disagrees),
    ]:
        variant(root, name, damage)

    print(f"fixtures in {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
