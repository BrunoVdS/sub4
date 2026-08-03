//
//  MergedExtraTests.swift
//  Sub4CoreTests
//
//  The daily merge from patch 177 — plan step 1.2.
//
//  WHY THIS ONE EARLY. It is the newest logic in the app, it was validated by
//  looking at a screenshot of one walking day, and it makes a claim that a
//  screenshot cannot check: that grouping is presentation only and never loses
//  or invents a part. Every assertion below is about the arithmetic and the
//  boundaries — which activities merge, which never do, and whether the totals
//  are the sums of what went in.
//
//  Everything under test is pure. No store, no network, no clock.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct MergedExtraTests {

    // MARK: Building activities
    //
    // ARGUMENTS IN DECLARATION ORDER, and that is not stylistic. Swift's
    // memberwise initialiser takes them in the order the properties are
    // declared, and this project has lost two builds to getting it wrong — once
    // with a diagnostic reading "unable to type-check this expression in
    // reasonable time", which points nowhere near the cause. One factory here
    // means one place to be right.

    private func walk(_ id: String,
                      at time: String,
                      km: Double,
                      minutes: Int,
                      hr: Double? = nil,
                      day: String = "2026-08-01",
                      sport: String = "Walk") -> Activity {
        Activity(id: id,
                 name: "\(time) \(sport)",
                 sportType: sport,
                 startLocal: "\(day)T\(time):00",
                 distance: km * 1000,
                 movingTime: minutes * 60,
                 elapsedTime: minutes * 60,
                 elevationGain: 10,
                 averageHeartrate: hr,
                 isTrainer: false,
                 maxHeartrate: nil,
                 gearId: nil,
                 maxSpeed: 2.5,
                 deviceWatts: nil,
                 averageWatts: nil,
                 startUTC: nil,
                 startLat: nil,
                 startLon: nil)
    }

    /// A 40 km ride: over `MatchRules.minRideKm`, so plan-eligible.
    private func trainingRide(_ id: String, at time: String) -> Activity {
        Activity(id: id,
                 name: "Long Ride",
                 sportType: "Ride",
                 startLocal: "2026-08-01T\(time):00",
                 distance: 40_000,
                 movingTime: 5400,
                 elapsedTime: 5600,
                 elevationGain: 120,
                 averageHeartrate: 132,
                 isTrainer: false,
                 maxHeartrate: nil,
                 gearId: nil,
                 maxSpeed: 12,
                 deviceWatts: nil,
                 averageWatts: nil,
                 startUTC: nil,
                 startLat: nil,
                 startLon: nil)
    }

    // MARK: What merges

    @Test("Two walks on one day become one entry")
    func twoWalksMerge() throws {
        let items = MergedExtra.group([
            walk("a", at: "09:00", km: 3, minutes: 40),
            walk("b", at: "18:00", km: 5, minutes: 60)
        ])
        #expect(items.count == 1)
        guard case .merged(let m) = try #require(items.first) else {
            Issue.record("expected a merged entry, got a single")
            return
        }
        #expect(m.parts.count == 2)
    }

    /// A lone walk is an activity, not a group of one. It keeps its own name and
    /// its own detail page — merging it would rename "Lunch Walk" to "Walks" and
    /// tell the reader nothing they did not already know.
    @Test("A single walk stays a single walk")
    func oneWalkStaysSingle() throws {
        let items = MergedExtra.group([walk("a", at: "09:00", km: 3, minutes: 40)])
        #expect(items.count == 1)
        guard case .single = try #require(items.first) else {
            Issue.record("a lone walk was merged into a group of one")
            return
        }
    }

    @Test("Different types on one day do not merge with each other")
    func differentTypesStayApart() {
        let items = MergedExtra.group([
            walk("a", at: "09:00", km: 3, minutes: 40),
            walk("b", at: "12:00", km: 4, minutes: 45),
            walk("c", at: "15:00", km: 6, minutes: 70, sport: "Hike"),
            walk("d", at: "17:00", km: 7, minutes: 80, sport: "Hike")
        ])
        // Two groups, one per sport type.
        #expect(items.count == 2)
        let merged = items.compactMap { item -> MergedExtra? in
            if case .merged(let m) = item { return m }
            return nil
        }
        #expect(merged.count == 2)
        #expect(Set(merged.map(\.sportType)) == ["Walk", "Hike"])
    }

    // MARK: What must never merge

    /// The boundary that matters most. `extras` includes plan-eligible
    /// activities that simply found no session — an unmatched 40 km training
    /// ride. Folding that into "Commutes" would file real training under a
    /// commute heading and hide it from the reader.
    @Test("A plan-eligible activity is never merged into the extras group")
    func planEligibleNeverMerges() {
        let items = MergedExtra.group([
            walk("c1", at: "08:00", km: 3.4, minutes: 12, sport: "Ride"),
            walk("c2", at: "17:00", km: 3.4, minutes: 12, sport: "Ride"),
            trainingRide("big", at: "10:00")
        ])
        // The two commutes merge; the training ride stays on its own.
        #expect(items.count == 2)

        let singles = items.compactMap { item -> Activity? in
            if case .single(let a) = item { return a }
            return nil
        }
        #expect(singles.count == 1)
        #expect(singles.first?.id == "big")
    }

    // MARK: Totals are sums, not estimates

    @Test("Distance and time are the sums of the parts")
    func totalsAreSums() throws {
        let items = MergedExtra.group([
            walk("a", at: "09:00", km: 3.2, minutes: 40),
            walk("b", at: "13:00", km: 4.8, minutes: 55),
            walk("c", at: "19:00", km: 2.0, minutes: 25)
        ])
        guard case .merged(let m) = try #require(items.first) else { return }
        #expect(abs(m.km - 10.0) < 0.0001)
        #expect(m.movingTime == (40 + 55 + 25) * 60)
        #expect(m.minutes == 120)
        #expect(m.parts.count == 3)
    }

    /// Weighted by moving time, and only over the parts that measured one. A
    /// simple mean would let a ten-minute stroll move a number that a
    /// ninety-minute walk earned.
    @Test("Average heart rate is weighted by time, ignoring parts without one")
    func heartRateIsTimeWeighted() throws {
        let items = MergedExtra.group([
            walk("a", at: "09:00", km: 3, minutes: 90, hr: 100),
            walk("b", at: "13:00", km: 1, minutes: 10, hr: 140),
            walk("c", at: "19:00", km: 2, minutes: 30, hr: nil)   // no HR at all
        ])
        guard case .merged(let m) = try #require(items.first) else { return }
        // (100×90 + 140×10) ÷ 100 = 104. The 30 minutes without a reading are
        // excluded from both the numerator and the denominator.
        let hr = try #require(m.averageHeartrate)
        #expect(abs(hr - 104) < 0.001)
    }

    @Test("Average heart rate is nil when no part measured one")
    func heartRateNilWhenAbsent() throws {
        let items = MergedExtra.group([
            walk("a", at: "09:00", km: 3, minutes: 40),
            walk("b", at: "13:00", km: 4, minutes: 50)
        ])
        guard case .merged(let m) = try #require(items.first) else { return }
        #expect(m.averageHeartrate == nil)
    }

    // MARK: Order and identity

    /// The list still reads chronologically: a group sits where its first part
    /// sat, rather than being appended after everything else.
    @Test("A merged group takes the position of its first part")
    func mergedGroupKeepsPosition() {
        let items = MergedExtra.group([
            walk("w1", at: "07:00", km: 2, minutes: 25),
            trainingRide("ride", at: "10:00"),
            walk("w2", at: "19:00", km: 3, minutes: 35)
        ])
        #expect(items.count == 2)
        // The walks merge and the group belongs at index 0, where w1 was.
        if case .merged = items[0] {} else {
            Issue.record("the merged group did not take its first part's place")
        }
        if case .single(let a) = items[1] { #expect(a.id == "ride") }
    }

    /// The id has to be stable across rebuilds or SwiftUI re-creates the sheet
    /// under the reader's finger, and it has to differ per day and per type or
    /// two groups collide in one list.
    @Test("The group id is stable, and unique per day and type")
    func idIsStableAndUnique() throws {
        let parts = [walk("a", at: "09:00", km: 3, minutes: 40),
                     walk("b", at: "18:00", km: 5, minutes: 60)]
        let first = MergedExtra(parts: parts)
        let again = MergedExtra(parts: parts)
        #expect(first.id == again.id)

        let otherDay = MergedExtra(parts: [
            walk("c", at: "09:00", km: 3, minutes: 40, day: "2026-08-02"),
            walk("d", at: "18:00", km: 5, minutes: 60, day: "2026-08-02")
        ])
        #expect(first.id != otherDay.id)

        let otherType = MergedExtra(parts: [
            walk("e", at: "09:00", km: 3, minutes: 40, sport: "Hike"),
            walk("f", at: "18:00", km: 5, minutes: 60, sport: "Hike")
        ])
        #expect(first.id != otherType.id)
    }

    // MARK: Labels

    /// First start to last END, not last start. First-to-last-start would end
    /// the day's walking at the moment the evening walk began.
    @Test("The time span runs to the end of the last part")
    func timeSpanEndsAtTheEnd() {
        let m = MergedExtra(parts: [
            walk("a", at: "09:00", km: 3, minutes: 40),
            walk("b", at: "18:00", km: 5, minutes: 60)
        ])
        #expect(m.timeSpan == "09:00 – 19:00")
    }

    @Test("Known types are named in the plural, unknown ones fall back")
    func titles() {
        #expect(MergedExtra(parts: [walk("a", at: "09:00", km: 1, minutes: 15),
                                    walk("b", at: "10:00", km: 1, minutes: 15)]).title
                == "Walks")

        let unknown = MergedExtra(parts: [
            walk("a", at: "09:00", km: 1, minutes: 15, sport: "Kitesurf"),
            walk("b", at: "10:00", km: 1, minutes: 15, sport: "Kitesurf")
        ])
        #expect(unknown.title.contains("Kitesurf"))
    }

    // MARK: Nothing is lost

    /// The property the whole feature rests on: grouping is presentation. Every
    /// activity that goes in comes out exactly once, whether merged or not.
    @Test("Grouping neither drops nor duplicates any activity")
    func groupingPreservesEveryActivity() {
        let input = [
            walk("w1", at: "07:00", km: 2, minutes: 25),
            walk("w2", at: "12:00", km: 3, minutes: 35),
            walk("w3", at: "19:00", km: 4, minutes: 45),
            walk("h1", at: "10:00", km: 8, minutes: 120, sport: "Hike"),
            walk("c1", at: "08:00", km: 3.4, minutes: 12, sport: "Ride"),
            walk("c2", at: "17:30", km: 3.4, minutes: 12, sport: "Ride"),
            trainingRide("big", at: "14:00")
        ]
        var seen: [String] = []
        for item in MergedExtra.group(input) {
            switch item {
            case .single(let a):  seen.append(a.id)
            case .merged(let m):  seen.append(contentsOf: m.parts.map(\.id))
            }
        }
        #expect(seen.count == input.count, "an activity was dropped or duplicated")
        #expect(Set(seen) == Set(input.map(\.id)))
    }

    @Test("An empty day produces nothing")
    func emptyInput() {
        #expect(MergedExtra.group([]).isEmpty)
    }
}
