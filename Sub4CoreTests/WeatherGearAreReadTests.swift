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

    /// **THE GAP CLOSED AT 430.** Kept as an inversion rather than deleted:
    /// it read `[.weather, .gear]` from 428 to 429 and reads empty now, and the
    /// day B6 declares a family without feeding it this fails and names it.
    @Test("Eleven families are declared and eleven are fed")
    func elevenReadElevenFed() {
        #expect(PersistenceAuthority.Family.allCases.count == 11)
        #expect(PersistenceAuthority.hydratedFamilies.count == 11)
        let unfed = Set(PersistenceAuthority.Family.allCases)
            .subtracting(PersistenceAuthority.hydratedFamilies)
        #expect(unfed.isEmpty, "B5 closed at 430 — a family declared and not fed is the next slice")
    }

    /// **430 IS THE FLIP**, and this is the assertion that says so.
    @Test("Both families are hydrated")
    func bothAreHydrated() {
        #expect(PersistenceAuthority.hydrates(.weather))
        #expect(PersistenceAuthority.hydrates(.gear))
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

/// **PATCH 434 — THE DISCLOSURE AND THE HYDRATION HAD NOTHING JOINING THEM.**
///
/// `sliceUnderTest` is the sentence the athlete reads on the Database screen as
/// `Reads from: …`. B5 flipped at 430 and that string was not extended until
/// 434, so for three patches the app said its weather and gear came from files
/// while `hydratedFamilies` had been feeding both from rows.
///
/// §12.127.5's shape — a sentence about what the app CURRENTLY DOES, stored as
/// a constant — and the reason it went unnoticed is that nothing compared the
/// two. This is that comparison, and it would have failed on the day of the flip.
@Suite
struct DisclosureMatchesHydrationTests {

    @Test("Every hydrated family has its slice named in what the app discloses")
    func everyHydratedFamilyIsDisclosed() throws {
        let sentence = try #require(PersistenceAuthority.sliceUnderTest)
        for family in PersistenceAuthority.hydratedFamilies.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            #expect(sentence.contains(family.slice),
                    "the app feeds \(family.rawValue) from the database and does not say so")
        }
    }

    /// The other direction: a slice named but fed by nothing would advertise a
    /// flip that has not happened. §12.129 — a join checked one way is
    /// unchecked the other.
    @Test("No slice is disclosed that nothing is fed from")
    func nothingIsDisclosedThatIsNotFed() throws {
        let sentence = try #require(PersistenceAuthority.sliceUnderTest)
        let fedSlices = Set(PersistenceAuthority.hydratedFamilies.map(\.slice))
        for slice in ["B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8"]
        where sentence.contains(slice) {
            #expect(fedSlices.contains(slice),
                    "the app claims \(slice) is under test and feeds no family from it")
        }
    }

    /// Exhaustive by construction — the switch cannot compile with a case
    /// missing — but the letters themselves are the ladder's and worth pinning
    /// so a rename is a decision rather than a typo.
    @Test("Every family belongs to a named slice")
    func everyFamilyHasASlice() {
        for family in PersistenceAuthority.Family.allCases {
            #expect(family.slice.hasPrefix("B"), "\(family.rawValue) has no slice")
        }
        #expect(PersistenceAuthority.Family.weather.slice == "B5")
        #expect(PersistenceAuthority.Family.gear.slice == "B5")
        #expect(PersistenceAuthority.Family.details.slice == "B4")
        #expect(PersistenceAuthority.Family.plan.slice == "B1")
    }
}
