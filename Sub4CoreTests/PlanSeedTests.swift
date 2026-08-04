//
//  PlanSeedTests.swift
//  Sub4CoreTests
//
//  The bundled plan seed is frozen, and this is what freezing it means —
//  D0, patch 246, ADR-0003 §9.2 and §12.13.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  ADR-0003 §9.2 designated `Sub4/plan.json` as the only versioned seed and
//  recorded its size and SHA-256, with the reason written out: "so a future
//  divergence is detectable rather than arguable".
//
//  It was not detectable. The seed changed twice — patch 238 corrected the
//  cycling speeds, patch 242 rebuilt the weekly totals from
//  `PlanStore.plannedVolume` — and the ADR went on stating 243,194 bytes and
//  `e93bf5ea` for three weeks while the file on disk was 279,078 bytes and
//  `a4087101`. Nothing failed. The drift was found by an audit, which is the
//  slowest and least reliable way to find anything.
//
//  A recorded hash that nothing checks is a comment. This makes it a build
//  failure.
//
//  WHY THE TEST TARGET AND NOT THE APP
//  -----------------------------------
//  This project's own rule is that a step which cannot be seen on hardware has
//  not been verified. That rule is about BEHAVIOUR — what the app does with
//  real data on a real phone. The seed hash is not behaviour; it is an
//  invariant of the source tree, and the source tree is what a test target
//  examines. The phone cannot tell you whether the repository and the ADR
//  agree, because the phone only ever sees one of them.
//
//  WHEN THIS TEST FAILS
//  --------------------
//  Do not edit the constants to make it pass. That is the single failure mode
//  this file exists to prevent. Either the change to `plan.json` was intended —
//  in which case update `Frozen` AND ADR-0003 §9.2 AND `PlanCoverageTests`
//  in the same commit, with the reason in the message — or it was not, and the
//  seed has been overwritten by something that should not have touched it.
//

import Testing
import Foundation
import CryptoKit
@testable import Sub4

@Suite
@MainActor
struct PlanSeedTests {

    /// Recorded 5 August 2026 at patch 246, against the seed as corrected by
    /// patches 238 and 242. Mirrored in ADR-0003 §9.2 — the two must agree.
    enum Frozen {
        static let bytes = 279_078
        static let sha256 =
            "a4087101cad4f61e13755aa62dc1003ca09034b04072570dc198257a4809e502"

        /// The counts the shape freeze is actually about. A file can keep its
        /// size and hash only by keeping these, but a future reader wants to
        /// know what the numbers mean without decoding anything.
        static let weeks = 37
        static let sessions = 260
        static let exercises = 20

        /// The stale root copy, deleted from the source tree on 3 August 2026
        /// and retained in `sub4-backups/stale-root-duplicates-2026-08-03/`.
        /// Recorded so that if it ever reappears in the bundle it is
        /// recognised rather than investigated from scratch: no `fuel`, no
        /// `warmup`, `meta.source` differing by one character.
        static let supersededSHA256 =
            "7d83ee7d972dab651046a19f32c81b89640c89672c41c158d8d6627f28290393"
    }

    /// The bundled seed, as bytes. Nil means the test target has no host
    /// application, which is a different failure from the seed being wrong —
    /// see `PlanCoverageTests`' note on the same subject.
    private func seedData() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "plan", withExtension: "json"),
                               """
                                   plan.json is not in the app bundle — check Build \
                                   Phases → Copy Bundle Resources, and that \
                                   Sub4CoreTests has a host application
                                   """)
        return try Data(contentsOf: url)
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("The bundled seed is byte-for-byte the file ADR-0003 §9.2 records")
    func seedIsFrozen() throws {
        let data = try seedData()
        #expect(data.count == Frozen.bytes,
                """
                    plan.json is \(data.count) bytes, ADR-0003 §9.2 records \
                    \(Frozen.bytes). Read this file's header before changing either.
                    """)
        let digest = hex(data)
        #expect(digest == Frozen.sha256,
                """
                    plan.json hashes \(digest), ADR-0003 §9.2 records \
                    \(Frozen.sha256). Read this file's header before changing either.
                    """)
    }

    @Test("The superseded root copy is not what got bundled")
    func theStaleCopyIsNotTheOneShipping() throws {
        let digest = try hex(seedData())
        #expect(digest != Frozen.supersededSHA256,
                """
                    the bundle is carrying the pre-3-August root plan.json — the \
                    one with no fuel and no warm-up. Two files that look like the \
                    plan is how the wrong one gets loaded.
                    """)
    }

    @Test("The frozen shape is the shape the app decoded")
    func theShapeIsWhatWasFrozen() throws {
        let store = PlanStore.shared
        try #require(store.plan.sessions.isEmpty == false,
                     "plan.json did not load — set a host application on Sub4CoreTests")
        #expect(store.plan.weeks.count == Frozen.weeks)
        #expect(store.plan.sessions.count == Frozen.sessions)
        #expect(store.plan.exercises.count == Frozen.exercises)
    }

    @Test("Fuel and warm-up are present — the reason the root copy lost")
    func theBlocksTheRootCopyLackedArePresent() throws {
        let store = PlanStore.shared
        try #require(store.plan.sessions.isEmpty == false)
        // §9.2's stated ground for choosing the nested file. If these ever go
        // nil the bundle has reverted to a pre-238 shape, and the failure
        // above will normally have fired first — this one names why it matters.
        #expect(store.plan.fuel != nil,
                """
                    no fuel block — the bundled seed has reverted to a shape from \
                    before the extractor read sections 09 and 10
                    """)
        #expect(store.plan.warmup != nil,
                "no warm-up block — same cause as the fuel failure above")
    }

    @Test("Hashing is stable — the check itself is not the variable")
    func hashingIsDeterministic() throws {
        let data = try seedData()
        #expect(hex(data) == hex(data))
    }
}
