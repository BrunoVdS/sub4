#!/usr/bin/env python3
"""
Patch 292a — `Result<[String], String>` again. String does not conform to Error.

  RecordingRepository.swift:94:64: type 'String' does not conform to protocol 'Error'

THE SAME MISTAKE AS 286a, six patches later, and worth a line rather than a
silent fix: `Result` reads as a tidy way to return "this or a reason", and the
reason has to be an `Error`. Both times the fix was a two-line named type.

`RepositoryError` is `Sendable`, which `any Error` is not — the same argument
`HealthQueryError` records in 286b.

A LETTER FIX-UP: ships `AppVersion.swift` with `patch = 292`, `revision = "a"`.

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


R = "Sub4/RecordingRepository.swift"

edit(
    R,
    r'''nonisolated enum RecordingRepository {''',
    r'''/// A reason a read failed, as something `Result` will accept — 292a.
///
/// `Result<[String], String>` does not compile: the failure type must conform
/// to `Error`. A named type is also better than `any Error`, which is not
/// `Sendable` — the same argument `HealthStore.HealthQueryError` records at
/// 286b, where this exact mistake was made six patches earlier.
nonisolated struct RepositoryError: Error, Sendable, Equatable {
    let message: String
}

nonisolated enum RecordingRepository {''',
    "a named Sendable error type",
)

edit(
    R,
    r'''                    sourceID: String = Sub4Import.sourceID) -> Result<[String], String> {''',
    r'''                    sourceID: String = Sub4Import.sourceID) -> Result<[String], RepositoryError> {''',
    "ids returns it",
)

edit(
    R,
    r'''        } catch {
            return .failure(String(describing: error))
        }
    }

    /// One recording, by the id the STORE uses.''',
    r'''        } catch {
            return .failure(RepositoryError(message: String(describing: error)))
        }
    }

    /// One recording, by the id the STORE uses.''',
    "the failure is wrapped",
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
