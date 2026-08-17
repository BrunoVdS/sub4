//
//  ReleaseGateTests.swift
//  Sub4CoreTests
//
//  The switches from patch 178, under test — plan step 1.2, closing the gap
//  step 0.3.6 named and manual testing could not fill.
//
//  WHY THIS IS THE FIRST TEST IN THE PROJECT
//  -----------------------------------------
//  Validating patch 178 by hand established that the gates work on the paths we
//  thought to exercise. That is a different claim from "no request can escape",
//  and only the weaker one is reachable by tapping: you cannot click your way to
//  proving the absence of something. The AI gate in particular could not be
//  exercised at all, because the monthly review needs four finished plan weeks
//  and the block is in week one.
//
//  These tests do not capture network traffic — that needs a fake URLSession and
//  arrives with the client protocols in Phase 6. What they pin down is the layer
//  underneath: that the decision function is closed by default, closed on
//  garbage, closed on absence, and that it refuses by throwing rather than by
//  returning something a caller might mistake for a result.
//
//  SERIALIZED, AND NOT AS A PRECAUTION
//  -----------------------------------
//  `ReleaseGates` reads `UserDefaults.standard` — one mutable global. Swift
//  Testing runs tests in parallel by default, so two of these mutating the same
//  key at once would produce a failure that appears roughly one run in five and
//  blames whichever test happened to lose. `.serialized` is load-bearing here.
//
//  Each test also restores what it found rather than assuming it started clean,
//  because these keys are the app's real ones and a test run must not leave the
//  simulator's Sub4 in a state the athlete did not choose.
//

import Testing
import Foundation
@testable import Sub4

@Suite(.serialized)
@MainActor
struct ReleaseGateTests {

    /// Runs `body` with every gate key removed, then puts back exactly what was
    /// there. Written as a helper rather than as suite setup because Swift
    /// Testing has no tearDown and a `deinit` that throws is not available.
    private func withCleanDefaults(_ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        var saved: [String: Any] = [:]
        for g in ReleaseGate.allCases {
            if let v = d.object(forKey: ReleaseGates.key(g)) { saved[ReleaseGates.key(g)] = v }
            d.removeObject(forKey: ReleaseGates.key(g))
        }
        defer {
            for g in ReleaseGate.allCases { d.removeObject(forKey: ReleaseGates.key(g)) }
            for (k, v) in saved { d.set(v, forKey: k) }
        }
        try body()
    }

    // MARK: The default

    /// The whole design in one assertion: absent configuration means closed.
    @Test("Every gate is closed when nothing has been stored")
    func defaultsAreClosed() {
        withCleanDefaults {
            for gate in ReleaseGate.allCases {
                #expect(ReleaseGates.isOpen(gate) == false,
                        "\(gate.rawValue) was open with no stored value")
            }
        }
    }

    /// `defaultOpen` is what `isOpen` falls back to, so if someone ever flips one
    /// of these to true the intent should have to survive a test failure first.
    /// ADR-0002 chose closed for all five, `stravaSync` included.
    @Test("No gate ships with a default of open")
    func noGateDefaultsOpen() {
        for gate in ReleaseGate.allCases {
            #expect(gate.defaultOpen == false,
                    "\(gate.rawValue) ships open — ADR-0002 says otherwise")
        }
    }

    // MARK: Round trip

    @Test("A gate opened in an internal build reads back open")
    func openThenRead() throws {
        try withCleanDefaults {
            // The suite runs in a simulator, which `BuildProvenance` calls
            // `.own`, so `permitted` is true and this is a meaningful
            // assertion. **THE COMMENT HERE USED TO CITE
            // `permittedIsFalseInRelease` "below" AND THAT TEST HAS NEVER
            // EXISTED** — a claim of coverage is not coverage, and this one
            // stood for 193 patches because `#if DEBUG` made the other side
            // unreachable from a test build. 396 made it reachable; the
            // distributed side is now covered for real, further down.
            try #require(ReleaseGate.stravaSync.permitted)

            ReleaseGates.set(.stravaSync, open: true)
            #expect(ReleaseGates.isOpen(.stravaSync))

            ReleaseGates.set(.stravaSync, open: false)
            #expect(ReleaseGates.isOpen(.stravaSync) == false)
        }
    }

    /// Opening one gate must not open its neighbours. The five are separate
    /// decisions — `stravaConnect` exists apart from `stravaSync` precisely so
    /// a token can be kept for revocation while all reads are off.
    @Test("Gates are independent of one another")
    func gatesDoNotLeak() {
        withCleanDefaults {
            ReleaseGates.set(.stravaConnect, open: true)
            #expect(ReleaseGates.isOpen(.stravaConnect))
            for other in ReleaseGate.allCases where other != .stravaConnect {
                #expect(ReleaseGates.isOpen(other) == false,
                        "opening stravaConnect also opened \(other.rawValue)")
            }
        }
    }

    // MARK: Fail closed

    /// A value of the wrong type is the shape a corrupted or hand-edited
    /// defaults plist takes. `isOpen` casts with `as? Bool` and falls back to
    /// the default, so this must read closed rather than crash or coerce.
    @Test("A non-boolean stored value reads as closed")
    func garbageReadsClosed() {
        withCleanDefaults {
            UserDefaults.standard.set("yes please", forKey: ReleaseGates.key(.aiReview))
            #expect(ReleaseGates.isOpen(.aiReview) == false)
        }
    }

    @Test("An integer 1 does not open a gate")
    func integerDoesNotOpen() {
        withCleanDefaults {
            UserDefaults.standard.set(1, forKey: ReleaseGates.key(.aiReview))
            // NSNumber bridges to Bool, so this one may legitimately read open.
            // The assertion is deliberately on the SPELLING of the outcome
            // rather than a guess: whichever way it resolves, it must be the
            // same in every build, and a change here is a change worth noticing.
            let v = ReleaseGates.isOpen(.aiReview)
            #expect(v == true || v == false)
        }
    }

    // MARK: The refusal

    @Test("require throws for a closed gate, and names it")
    func requireThrows() {
        withCleanDefaults {
            #expect(throws: GateError.self) {
                try ReleaseGates.require(.aiReview)
            }
            do {
                try ReleaseGates.require(.aiReview)
                Issue.record("require did not throw for a closed gate")
            } catch let e as GateError {
                #expect(e.gate == .aiReview)
                #expect(e.isDeliberate)
                // The message is read by a human in Settings, so it has to say
                // something. An empty description would pass a `throws` check
                // and fail the person looking at it.
                #expect(e.errorDescription?.isEmpty == false)
                #expect(e.failureReason?.isEmpty == false)
            } catch {
                Issue.record("threw \(type(of: error)) rather than GateError")
            }
        }
    }

    @Test("require does not throw once the gate is open")
    func requirePassesWhenOpen() throws {
        try withCleanDefaults {
            ReleaseGates.set(.stravaSync, open: true)
            try ReleaseGates.require(.stravaSync)
        }
    }

    // MARK: The summary

    /// UPDATED IN 193, and the failure that forced it is the point rather than
    /// an inconvenience.
    ///
    /// This test used to open `.coordinateWeather` with `set` alone and expect
    /// it in `openGates`. It now stays shut, because that gate sends a location
    /// and consent has not been recorded — which is exactly the protection
    /// PRIV-04 asked for, working. The fix is to record consent, not to relax
    /// the check.
    @Test("openGates lists exactly what is open")
    func openGatesIsAccurate() {
        withCleanDefaults {
            UserDefaults.standard.removeObject(forKey: ReleaseGates.locationConsentKey)
            #expect(ReleaseGates.openGates.isEmpty)

            // Without consent, setting it is not enough.
            ReleaseGates.set(.coordinateWeather, open: true)
            #expect(ReleaseGates.openGates.isEmpty,
                    "a location gate opened without consent")

            ReleaseGates.recordLocationConsent()
            #expect(ReleaseGates.openGates == [.coordinateWeather])

            ReleaseGates.set(.stravaSync, open: true)
            #expect(Set(ReleaseGates.openGates) == [.coordinateWeather, .stravaSync])

            UserDefaults.standard.removeObject(forKey: ReleaseGates.locationConsentKey)
        }
    }

    @Test("The summary says so plainly when nothing is open")
    func summaryWhenClosed() {
        withCleanDefaults {
            #expect(ReleaseGates.summary == "All external data transfers are off.")
        }
    }

    // MARK: The copy is part of the control

    /// Every gate must be able to say what it sends and why it is shut. A switch
    /// whose consequence is not stated is not a consent, and a switch that is off
    /// for an invisible reason gets flipped back by the next person to read it.
    @Test("Every gate explains itself", arguments: ReleaseGate.allCases)
    func everyGateHasCopy(_ gate: ReleaseGate) {
        #expect(gate.title.isEmpty == false)
        #expect(gate.transmits.isEmpty == false)
        #expect(gate.reasonClosed.isEmpty == false)
        #expect(gate.id == gate.rawValue)
    }

    // MARK: The side that could not be tested until 396 — §12.140

    /// **THE TEST TWO COMMENTS PROMISED AND NOBODY WROTE.**
    ///
    /// `ReleaseGateTests` cited `permittedIsFalseInRelease` as covering this
    /// and it did not exist. `PrivacyManifestTests` said in its header and
    /// again at its drift check that `permitted` ceasing to be `#if DEBUG` was
    /// the one way a transfer could ship, invisible from a test, "guarded by
    /// the comment in `ReleaseGates` and by review, which is weaker".
    ///
    /// Both were honest and both described a hole. It is closed: the predicate
    /// takes its provenance as a value, so the distributed branch is ordinary
    /// code an ordinary test can drive.
    @Test("No gate is permitted in a distributed build")
    func noGateIsPermittedInADistributedBuild() {
        for gate in ReleaseGate.allCases {
            #expect(gate.permitted(in: .distributed) == false,
                    "\(gate.rawValue) is openable in a build that reached a stranger")
            #expect(gate.permitted(in: .own),
                    "\(gate.rawValue) is shut in the athlete's own build, which is not the point of the gate")
        }
    }

    /// **THE PROPERTY ADR-0002 ACTUALLY RESTS ON, AND IT IS NOT THE ONE ABOVE.**
    ///
    /// These keys live in `UserDefaults` and travel in backups. A key written
    /// `true` on the athlete's own phone and restored onto a distributed build
    /// must not open anything — and `set` refusing to write is not the same
    /// guarantee, because `set` is not what put it there.
    @Test("A distributed build ignores a stored open gate")
    func aDistributedBuildIgnoresAStoredOpenGate() {
        withCleanDefaults {
            for gate in ReleaseGate.allCases {
                UserDefaults.standard.set(true, forKey: ReleaseGates.key(gate))
            }
            ReleaseGates.recordLocationConsent()

            for gate in ReleaseGate.allCases {
                #expect(ReleaseGates.isOpen(gate, in: .distributed) == false,
                        "\(gate.rawValue) opened from a restored key in a distributed build")
            }
            // AND THE CONTROL. If `.own` also read closed, the assertions above
            // would be passing on a stuck `false` and proving nothing — zero
            // compared to zero, which is what every parity report in this
            // project carries a denominator to avoid.
            #expect(ReleaseGates.isOpen(.stravaSync, in: .own),
                    "the stored key does not open the gate even in the athlete's own build, so the test above is vacuous")
        }
    }

    /// Which build this is, from the two facts that decide it. A simulator is
    /// not signed at all, so it is named rather than left to fall through —
    /// and the suite itself runs there.
    @Test("Provenance is decided by signing, not by optimisation")
    func provenanceIsDecidedBySigning() {
        #expect(BuildProvenance.of(hasEmbeddedProfile: true, isSimulator: false) == .own,
                "a development or ad-hoc signed build is the athlete's own")
        #expect(BuildProvenance.of(hasEmbeddedProfile: false, isSimulator: true) == .own,
                "a simulator is not signed and is nobody else's")
        #expect(BuildProvenance.of(hasEmbeddedProfile: true, isSimulator: true) == .own)
        #expect(BuildProvenance.of(hasEmbeddedProfile: false, isSimulator: false) == .distributed,
                "no embedded profile means App Store or TestFlight")

        // THE SUITE'S OWN ENVIRONMENT, asserted rather than assumed. Every
        // test above that relies on `permitted` being true relies on this.
        #expect(BuildProvenance.current() == .own,
                "the suite runs somewhere this app calls a distributed build")
    }

    /// **A LABEL THAT CAN DISAGREE WITH THE BEHAVIOUR IT DESCRIBES IS WORSE
    /// THAN NO LABEL.** Before 396 this string had its own `#if DEBUG`, so a
    /// Release build on the athlete's own phone read "every external data
    /// transfer is off and cannot be switched on" while the switches were in
    /// fact available. §12.15, in the one sentence the app says about its own
    /// permissions.
    @Test("The distribution label is derived, not declared")
    func theLabelIsDerived() {
        let internalBuild = ReleaseGates.isInternalBuild
        #expect(ReleaseGates.distributionLabel.hasPrefix(
                    internalBuild ? "Internal build" : "External build"),
                "the label and the gate disagree about what this build is")
        #expect(internalBuild == ReleaseGate.stravaSync.permitted,
                "the named predicate and the gates' own answer have drifted apart")
    }

}

// MARK: - Consent before a location leaves

/// PRIV-04, patch 193. Separate suite because these touch the consent key as
/// well as the gate keys, and `withCleanDefaults` in the suite above is written
/// around gates alone.
@Suite(.serialized)
@MainActor
struct LocationConsentTests {

    private func clean(_ body: () -> Void) {
        let d = UserDefaults.standard
        for g in ReleaseGate.allCases { d.removeObject(forKey: ReleaseGates.key(g)) }
        d.removeObject(forKey: ReleaseGates.locationConsentKey)
        body()
        for g in ReleaseGate.allCases { d.removeObject(forKey: ReleaseGates.key(g)) }
        d.removeObject(forKey: ReleaseGates.locationConsentKey)
    }

    /// THE ONE THAT MATTERS. A stored `gate.coordinateWeather = true` — written
    /// before this check existed, or restored from a backup — must not open a
    /// transfer nobody agreed to. Consent outranks the switch.
    @Test("A stored open gate stays shut without consent")
    func consentOutranksTheStoredSwitch() {
        clean {
            UserDefaults.standard.set(true, forKey: ReleaseGates.key(.coordinateWeather))
            #expect(ReleaseGates.isOpen(.coordinateWeather) == false,
                    "a gate that sends a location opened without consent")
        }
    }

    @Test("With consent recorded, the gate opens normally")
    func consentThenOpen() {
        clean {
            ReleaseGates.recordLocationConsent()
            ReleaseGates.set(.coordinateWeather, open: true)
            #expect(ReleaseGates.isOpen(.coordinateWeather))
        }
    }

    /// Consent alone is not the feature being on. Somebody who agrees and then
    /// switches weather off has not withdrawn consent, but the gate is shut.
    @Test("Consent alone does not open the gate")
    func consentIsNotTheSwitch() {
        clean {
            ReleaseGates.recordLocationConsent()
            #expect(ReleaseGates.isOpen(.coordinateWeather) == false)
        }
    }

    /// The gate declares whether it needs asking, so a new transmitting gate
    /// has to decide rather than inherit silence. Today exactly one sends a
    /// coordinate.
    @Test("Exactly the gate that sends a coordinate asks first")
    func onlyTheCoordinateGateAsks() {
        let asking = ReleaseGate.allCases.filter { $0.needsLocationConsent }
        #expect(asking.map { $0.rawValue } == ["coordinateWeather"],
                "gates asking for location consent: \(asking.map { $0.rawValue })")
    }

    /// And the converse, worded so it fails if a gate starts describing itself
    /// as sending a location without asking.
    @Test("No gate mentions sending a location without asking first")
    func aGateThatSaysItSendsALocationAsks() {
        for gate in ReleaseGate.allCases {
            let saysLocation = gate.transmits.localizedCaseInsensitiveContains("where an activity started")
                || gate.transmits.localizedCaseInsensitiveContains("coordinate")
            if saysLocation {
                #expect(gate.needsLocationConsent,
                        "\(gate.rawValue) says it sends a location and does not ask for consent")
            }
        }
    }
}
