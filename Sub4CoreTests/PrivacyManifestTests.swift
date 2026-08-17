//
//  PrivacyManifestTests.swift
//  Sub4CoreTests
//
//  The privacy manifest, held to the app — patch 191, plan step 2.1.8.
//
//  WHY THIS EXISTS
//  ---------------
//  `PrivacyInfo.xcprivacy` is a plist in the bundle. Nothing compiles it, no
//  Swift file references it, and the only thing that reads it is App Review —
//  months after the change that made it wrong. It is the same shape of problem
//  as the Health purpose string in patch 182: a claim about the app, stored
//  somewhere the compiler cannot see.
//
//  So it is read back out of the built product, exactly like that string, and
//  held to the things it claims about.
//
//  THE ONE THAT MATTERS is `aShippedOpenGateRequiresDeclaredCollection`. The
//  manifest declares no collected data because in a distributed build no gate
//  can open and nothing is transmitted. The day someone ships a gate open, the
//  manifest becomes a false statement to Apple and to the user — and this test
//  is what says so, in the same commit rather than at review time.
//
//  PATCH 396 CHANGED WHAT HOLDS THAT UP. It used to be `ReleaseGate.permitted`
//  being `#if DEBUG` — a compile-time fact this suite could not see, because
//  the branch it needed did not exist in a test build. It is now
//  `BuildProvenance`, a value, and `ReleaseGateTests` drives BOTH sides of it:
//  `noGateIsPermittedInADistributedBuild` and
//  `aDistributedBuildIgnoresAStoredOpenGate`. See the note on the drift check
//  below, which no longer has to end in "and by review".
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct PrivacyManifestTests {

    /// The manifest as the built product carries it.
    ///
    /// `Bundle(for:)` rather than `Bundle.main` for the reason given in
    /// `HealthStore.hostBundle`: under the test runner, main is the runner.
    private func manifest() throws -> [String: Any] {
        let bundle = HealthStore.hostBundle
        let url = try #require(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                               "PrivacyInfo.xcprivacy is not in the app bundle — check that it is a member of the Sub4 target")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any], "the manifest is not a dictionary")
    }

    // MARK: It exists and parses

    /// The failure this catches is mundane and total: a manifest that is in the
    /// repository but not in the target ships nothing at all, and the app is
    /// rejected at upload with no clue as to why.
    @Test("The manifest is in the built bundle and parses")
    func manifestIsPresent() throws {
        let m = try manifest()
        #expect(m["NSPrivacyTracking"] != nil)
        #expect(m["NSPrivacyCollectedDataTypes"] != nil)
        #expect(m["NSPrivacyAccessedAPITypes"] != nil)
    }

    @Test("The app declares no tracking and no tracking domains")
    func noTracking() throws {
        let m = try manifest()
        let tracking = try #require(m["NSPrivacyTracking"] as? Bool)
        #expect(tracking == false)
        let domains = try #require(m["NSPrivacyTrackingDomains"] as? [String])
        #expect(domains.isEmpty, "tracking domains declared: \(domains)")
    }

    // MARK: The claim that depends on the gates

    /// THE DRIFT CHECK. The manifest says nothing is collected, which is true
    /// only because no gate can open in a Release build. `defaultOpen` is the
    /// property that would change that — a gate shipped open transmits on first
    /// launch, and the manifest would be lying to Apple and to the reader.
    ///
    /// If this fails, the fix is NOT to change the assertion. It is to add the
    /// data types listed in the comment at the foot of the manifest.
    ///
    /// WHAT THIS TEST SEES AND WHAT NOW SEES THE REST — patch 396. This half
    /// is `defaultOpen`: a gate open on first launch with no one having chosen
    /// it. The other half — a build permitting a gate it should not — used to
    /// be unreachable from any test, because `permitted` was `#if DEBUG` and
    /// the suite runs where that branch is true. This comment said so and
    /// added that the rest was "guarded by the comment in `ReleaseGates` and
    /// by review, which is weaker".
    ///
    /// **THAT WAS AN HONEST DESCRIPTION OF A HOLE, AND IT IS CLOSED.**
    /// `ReleaseGateTests.noGateIsPermittedInADistributedBuild` drives the
    /// branch directly, and `aDistributedBuildIgnoresAStoredOpenGate` covers
    /// the case that actually worries ADR-0002: a `gate.` key restored from a
    /// backup taken on the athlete's own phone. §12.140.
    @Test("A gate that ships open requires a declared collected data type")
    func aShippedOpenGateRequiresDeclaredCollection() throws {
        let m = try manifest()
        let collected = try #require(m["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        // CLOSURE, not `filter(\.defaultOpen)`. Passing a member of a
        // MainActor-isolated type as a function value strips the
        // isolation; this project has hit that three times.
        let shippedOpen = ReleaseGate.allCases.filter { $0.defaultOpen }

        if shippedOpen.isEmpty {
            #expect(collected.isEmpty,
                    "no gate ships open, so nothing is transmitted, but \(collected.count) data types are declared")
        } else {
            #expect(collected.isEmpty == false,
                    "these gates ship open and transmit: \(shippedOpen.map { $0.rawValue }) — the manifest must declare what they send")
        }
    }

    /// The same invariant from the other side, and the reason the first one is
    /// safe to write at all: every gate that transmits something says so, and
    /// `permitted` is what keeps them shut outside a debug build.
    @Test("Every gate that transmits describes what it sends")
    func everyTransmittingGateSaysWhat() {
        for gate in ReleaseGate.allCases {
            #expect(gate.transmits.isEmpty == false,
                    "\(gate.rawValue) is a transfer switch that does not say what it transmits")
        }
    }

    // MARK: Required-reason APIs

    /// Two categories, and the test asserts they are the two the app actually
    /// touches — not that the file is non-empty. An entry declared for an API
    /// the app does not use is as wrong as a missing one, in the direction that
    /// is harder to notice.
    @Test("The declared API categories are the ones the app uses")
    func declaredCategoriesAreTheOnesUsed() throws {
        let m = try manifest()
        let types = try #require(m["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let declared = Set(types.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })

        // UserDefaults: everywhere. File timestamps: `AppVersion.built` reads
        // the executable's modification date to show the build date.
        let used: Set<String> = [
            "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPICategoryFileTimestamp"
        ]
        #expect(declared == used,
                "missing: \(used.subtracting(declared)); declared but unused: \(declared.subtracting(used))")
    }

    /// Every category must carry at least one reason. An empty reasons array is
    /// accepted by the plist and rejected at upload.
    @Test("Every declared category carries a reason")
    func everyCategoryHasAReason() throws {
        let m = try manifest()
        let types = try #require(m["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        for entry in types {
            let name = entry["NSPrivacyAccessedAPIType"] as? String ?? "unnamed"
            let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            #expect(reasons.isEmpty == false, "\(name) declares no reason")
            for r in reasons {
                // The codes are of the form C617.1, CA92.1, DDA9.1 — letters and
                // digits, a dot, a digit. A typo here fails at upload, weeks after
                // the commit that introduced it.
                #expect(r.range(of: #"^[A-Z0-9]{4}\.\d+$"#, options: .regularExpression) != nil,
                        "\(name) declares a malformed reason code: \(r)")
            }
        }
    }

    /// `AppVersion.built` is the sole reason the file-timestamp category is
    /// declared. If it is ever removed, the declaration should go with it — an
    /// app declaring access it does not use is describing itself wrongly.
    @Test("The file-timestamp declaration still has a use behind it")
    func fileTimestampUseStillExists() {
        // Reads `attributesOfItem` on the executable. Non-nil here means the
        // call site is still present and working.
        #expect(AppVersion.built != nil,
                "AppVersion.built no longer reads a file timestamp — remove the manifest entry")
    }
}
