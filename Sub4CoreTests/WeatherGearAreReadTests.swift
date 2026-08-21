//
//  WeatherGearAreReadTests.swift
//  Sub4CoreTests
//
//  Patch 428, ADR-0003 §12.178, D7 slice B5 — the machinery, not the flip.
//
//  WHAT A SLICE IN FLIGHT LOOKS LIKE
//  ---------------------------------
//  Eleven families declared, nine fed. The bootstrap reads weather and gear on
//  every launch and nothing hydrates from them, which is exactly what 379/380
//  and 394/395 looked like: a family read before it is fed, so that the flip
//  can be one line and any failure it produces is attributable to it.
//
//  ONE FIELD, TWO FAMILIES, AND BOTH DECISIONS ARE TESTED HERE. The field
//  mirrors the READ — one `db.queue.read`, either it works for both or it fails
//  for both. The families mirror the HYDRATION, which has to be reversible by
//  half.
//

import Testing
import Foundation
import GRDB
@testable import Sub4

@Suite
struct WeatherGearAreReadTests {

    @Test("The eighth family is read and reaches the paste")
    func theEighthFamilyIsRead() throws {
        let db = try Sub4Database.inMemory()
        let b = DatabaseBootstrapReader.read(db)

        #expect(DatabaseBootstrap.fieldCount == 8)
        #expect(b.weatherGear.isTrustworthy,
                "a clean read of an empty database is trustworthy and empty")
        let lines = b.diagnosticLines
        #expect(lines.contains { $0.hasPrefix("  weather and gear:") },
                "the family is read and says nothing in the paste")
        #expect(lines.count == DatabaseBootstrap.diagnosticLineCount)
    }

    @Test("What it read is what the repository reads")
    func theReadIsTheRepositorys() throws {
        let db = try Sub4Database.inMemory()
        _ = try Sub4Import.run(into: db, activities: [], shoes: [
            AthleteStore.Shoe(id: "g1", name: "Pair", distanceM: 1000,
                              primary: false, kind: .shoe, retired: false)])

        let b = DatabaseBootstrapReader.read(db)
        #expect(b.weatherGear.gear?.count == 1)
        #expect(b.weatherGear.gear?.first?.kind == .shoe)
    }

    /// **THE GAP IS THE SLICE.** Named rather than counted: a bare
    /// `!isEmpty` would pass for any slice in flight and for a family somebody
    /// forgot to feed.
    @Test("Eleven families are declared and nine are fed")
    func elevenReadNineFed() {
        #expect(PersistenceAuthority.Family.allCases.count == 11)
        #expect(PersistenceAuthority.hydratedFamilies.count == 9)
        let unfed = Set(PersistenceAuthority.Family.allCases)
            .subtracting(PersistenceAuthority.hydratedFamilies)
        #expect(unfed == [.weather, .gear])
    }

    /// **428 IS THE MACHINERY AND NOT THE FLIP**, and this is the assertion
    /// that says so. 429 inverts it.
    @Test("Neither family is hydrated yet")
    func neitherIsHydratedYet() {
        #expect(!PersistenceAuthority.hydrates(.weather),
                "429 is the flip — if this fails, 428 did it by accident")
        #expect(!PersistenceAuthority.hydrates(.gear))
    }

    /// Two cases rather than one, so half of B5 can be rolled back. The
    /// groundwork's reason: weather is twelve columns, eleven compared and
    /// restorable, while gear only stopped being lossy at 425–427.
    @Test("Weather and gear are separate families")
    func theyAreTwoFamilies() {
        #expect(PersistenceAuthority.Family.weather
                != PersistenceAuthority.Family.gear)
        #expect(PersistenceAuthority.Family.allCases.contains(.weather))
        #expect(PersistenceAuthority.Family.allCases.contains(.gear))
    }

    /// One field, because one read fails as one thing. Two fields would report
    /// a single failure as two families — `fieldCount`'s rule, and `authored`'s
    /// precedent at 357.
    @Test("A failed read names one family, not two")
    func oneReadIsOneFamily() {
        let b = DatabaseBootstrap(
            plan: .unavailable, extras: .unavailable, athlete: .unavailable,
            authored: .unavailable, decisions: .unavailable,
            moves: .unavailable, activities: .unavailable,
            weatherGear: .failed("no such table: weather"))
        let faults = b.diagnosticLines.filter { $0.contains("no such table: weather") }
        #expect(faults.count == 1, "one read reported as more than one family")
        // And it is ONE line among the eight, not two.
        #expect(b.diagnosticLines.filter { $0.hasPrefix("  weather") }.count == 1)
    }
}
