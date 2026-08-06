#!/usr/bin/env python3
"""
Patch 286b — `Result`'s failure type has to conform to `Error`. `String` does
not, and 286a would not compile.

  HealthWorkouts.swift:313:67  type 'String' does not conform to protocol 'Error'
  HealthWorkouts.swift:322:53  cannot infer contextual base in reference to member 'failure'

The intent was right and the type was wrong. `HealthQueryError` is a named
`Error` carrying the message, which is also better than `any Error` would have
been: it is `Sendable`, so it can cross the continuation without argument.

WHY THE SUITE CAUGHT THIS AND I DID NOT. The preflight in this workflow checks
anchors and balanced braces; it does not type-check Swift, and nothing in this
container can. `xcodebuild test` is the compiler, and running it before ⌘R is
the rule that exists for exactly this — a build error in a file the app target
compiles would have surfaced either way, but only the suite says so in words.

A LETTER FIX-UP: ships `AppVersion.swift` with `patch = 286`, `revision = "b"`.

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

edit(
    W,
    r'''            switch await series(of: HKSeriesType.workoutRoute(), matching: mine) {
            case .failure(let why):
                return .failed("the route query failed — \(why)")''',
    r'''            switch await series(of: HKSeriesType.workoutRoute(), matching: mine) {
            case .failure(let why):
                return .failed("the route query failed — \(why.message)")''',
    "the call site reads the message",
)

edit(
    W,
    r'''    @MainActor
    private func series(of type: HKSampleType,
                        matching predicate: NSPredicate) async -> Result<[HKSample], String> {
        await withCheckedContinuation { continuation in
            var resumed = false
            let q = HKAnchoredObjectQuery(type: type, predicate: predicate,
                                          anchor: nil,
                                          limit: HKObjectQueryNoLimit) { _, samples, _, _, error in
                guard !resumed else { return }
                resumed = true
                if let error {
                    continuation.resume(returning: .failure(error.localizedDescription))''',
    r'''    /// What HealthKit said, as something `Result` will accept — 286b.
    ///
    /// `Result<[HKSample], String>` does not compile: the failure type must
    /// conform to `Error`. A named error is also better than `any Error` here,
    /// because it is `Sendable` and therefore crosses the continuation without
    /// argument — `any Error` is not.
    nonisolated struct HealthQueryError: Error, Sendable, Equatable {
        let message: String
    }

    @MainActor
    private func series(of type: HKSampleType,
                        matching predicate: NSPredicate) async -> Result<[HKSample], HealthQueryError> {
        await withCheckedContinuation { continuation in
            var resumed = false
            let q = HKAnchoredObjectQuery(type: type, predicate: predicate,
                                          anchor: nil,
                                          limit: HKObjectQueryNoLimit) { _, samples, _, _, error in
                guard !resumed else { return }
                resumed = true
                if let error {
                    continuation.resume(
                        returning: .failure(HealthQueryError(
                            message: error.localizedDescription)))''',
    "a named Sendable error type",
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
