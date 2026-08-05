//
//  CommuteTests.swift
//  Sub4CoreTests
//
//  What makes a ride a commute — patch 251.
//
//  Patch 250 read Strava's own flag and lasted one patch. ADR-0002 retires
//  Strava, and since patch 249 the sync overwrites every `Activity` row on every
//  run — so an authored field on that row would survive until the next launch
//  and no longer. The answer lives in `CommuteStore`, and this file tests the
//  pair: a pure default that knows only the distance, and an override that wins.
//
//  THE STORE IS A SINGLETON, so these tests share it. Every test uses ids of its
//  own and clears them at the end rather than assuming a clean slate: Swift
//  Testing runs in parallel, and an assumption about order here is a test that
//  passes alone and fails in a run.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct CommuteTests {

    private func ride(_ km: Double, id: String) -> Activity {
        Activity(id: id,
                 name: "Morning Ride",
                 sportType: "Ride",
                 startLocal: "2026-08-04T07:26:16",
                 distance: km * 1000,
                 movingTime: 900,
                 elapsedTime: 900,
                 elevationGain: nil,
                 averageHeartrate: nil,
                 isTrainer: nil,
                 maxHeartrate: nil,
                 gearId: nil,
                 maxSpeed: nil,
                 deviceWatts: nil,
                 averageWatts: nil,
                 startUTC: nil,
                 startLat: nil,
                 startLon: nil)
    }

    private func forget(_ ids: String...) {
        ids.forEach { CommuteStore.shared.clear($0) }
    }

    // MARK: The default — pure, and knows only the distance

    @Test("With nobody asked, the distance decides — either side of the line")
    func theDistanceRuleIsTheDefault() {
        #expect(ride(9.99, id: "d1").commuteByDistance)
        #expect(ride(10.01, id: "d2").commuteByDistance == false)
        // 16 July 2026 was 9,985.9 m — a commute by fourteen metres, and the
        // reason there is a toggle at all.
        #expect(ride(9.9859, id: "d3").commuteByDistance)
    }

    @Test("The default reads the threshold rather than copying it")
    func theThresholdIsNotDuplicated() {
        #expect(ride(MatchRules.minRideKm - 0.001, id: "t1").commuteByDistance)
        #expect(ride(MatchRules.minRideKm, id: "t2").commuteByDistance == false)
    }

    @Test("Only bike rides are commutes")
    func nothingElseIsACommute() {
        let run = Activity(id: "r1", name: "Morning Run", sportType: "Run",
                           startLocal: "2026-08-04T07:00:00",
                           distance: 3000, movingTime: 900, elapsedTime: 900,
                           elevationGain: nil, averageHeartrate: nil,
                           isTrainer: nil, maxHeartrate: nil, gearId: nil,
                           maxSpeed: nil, deviceWatts: nil, averageWatts: nil,
                           startUTC: nil, startLat: nil, startLon: nil)
        #expect(run.commuteByDistance == false)
        CommuteStore.shared.set(true, for: "r1")
        defer { forget("r1") }
        // Even with an answer on file. The question is about bike sessions
        // competing with planned rides, and a 3 km run is not one.
        #expect(run.isCommuteRide == false)
    }

    // MARK: The override — wins in both directions

    @Test("A long ride marked as a commute is a commute")
    func theAnswerWinsUpwards() {
        let r = ride(42, id: "o1")
        #expect(r.isCommuteRide == false, "precondition: the rule says training")
        CommuteStore.shared.set(true, for: "o1")
        defer { forget("o1") }
        #expect(r.isCommuteRide)
        #expect(r.extraLabel == "Ride · commute")
        #expect(r.isPlanEligible == false, "a commute cannot satisfy a planned session")
    }

    @Test("A short ride marked as training is training")
    func theAnswerWinsDownwards() {
        // The change from patch 250, which kept a distance floor underneath so
        // an unticked Strava box could not promote a 3 km hop. An answer given
        // HERE is the athlete's, not a side-effect of another app's default, so
        // it wins in both directions.
        let r = ride(3.4, id: "o2")
        #expect(r.isCommuteRide, "precondition: the rule says commute")
        CommuteStore.shared.set(false, for: "o2")
        defer { forget("o2") }
        #expect(r.isCommuteRide == false)
        #expect(r.isPlanEligible)
    }

    @Test("Clearing an answer is not the same as answering no")
    func clearingReturnsItToTheRule() {
        let r = ride(3.4, id: "o3")
        CommuteStore.shared.set(false, for: "o3")
        #expect(r.isCommuteRide == false)
        CommuteStore.shared.clear("o3")
        // Back to the rule, which for 3.4 km says commute. If `clear` merely
        // wrote `false` this would still read false, and the athlete would have
        // no way back to the default.
        #expect(r.isCommuteRide)
        #expect(CommuteStore.shared.decision(for: "o3") == nil)
    }

    @Test("An answer carries the moment it was given")
    func decisionsAreDated() throws {
        let when = Date(timeIntervalSince1970: 1_785_900_000)
        CommuteStore.shared.set(true, for: "o4", now: when)
        defer { forget("o4") }
        let d = try #require(CommuteStore.shared.decisions["o4"])
        #expect(d.decided == when)
        #expect(d.activityId == "o4")
    }

    @Test("Only the answers that disagree with the rule are interesting")
    func overridesAreTheDisagreements() {
        let agreeing = ride(3.4, id: "o5")     // rule says commute, answer agrees
        let disagreeing = ride(3.4, id: "o6")  // rule says commute, answer differs
        CommuteStore.shared.set(true, for: "o5")
        CommuteStore.shared.set(false, for: "o6")
        defer { forget("o5", "o6") }

        let out = CommuteStore.shared.overrides(in: [agreeing, disagreeing])
        #expect(out.map(\.activityId) == ["o6"],
                "an answer that restates the default is not an override")
    }

    // MARK: What it does to the rest of the app

    @Test("A group of commutes is headed Commutes")
    func mergedCommutesAreNamed() throws {
        let items = MergedExtra.group([ride(2.79, id: "m1"),
                                       ride(6.09, id: "m2"),
                                       ride(4.44, id: "m3")])
        let merged = items.compactMap { item -> MergedExtra? in
            if case .merged(let m) = item { return m }
            return nil
        }
        let group = try #require(merged.first)
        #expect(group.title == "Commutes")
        #expect(group.countLabel == "3 commutes")
    }

    @Test("Training rides never reach the merged row at all")
    func trainingRidesDoNotMerge() {
        let items = MergedExtra.group([ride(42, id: "m4"), ride(38, id: "m5")])
        let merged = items.contains { if case .merged = $0 { return true }; return false }
        #expect(merged == false, "two training rides were folded into one row")
        #expect(items.count == 2)
    }

    @Test("Marking two long rides as commutes sends them into the group")
    func markedLongRidesMerge() throws {
        // The consequence of routing `isPlanEligible` through `isCommuteRide`:
        // the heading is right because the classification is, rather than by
        // luck of the distance.
        CommuteStore.shared.set(true, for: "m6")
        CommuteStore.shared.set(true, for: "m7")
        defer { forget("m6", "m7") }

        let items = MergedExtra.group([ride(42, id: "m6"), ride(38, id: "m7")])
        let merged = items.compactMap { item -> MergedExtra? in
            if case .merged(let m) = item { return m }
            return nil
        }
        let group = try #require(merged.first)
        #expect(group.title == "Commutes")
    }

    // MARK: How the extras row reads — patch 252

    @Test("A lone commute is titled Commute, like a group of them")
    func aSingleCommuteIsNamedTheSameWay() {
        // The inconsistency this fixes: one commute was titled "Morning Ride"
        // and three were titled "Commutes", and the difference was how many
        // happened to fall on one day.
        let r = ride(3.9, id: "x1")
        #expect(r.extraTitle == "Commute")
        // The caption must not repeat the title, so it says when instead.
        #expect(r.extraCaption.contains("commute") == false)
    }

    @Test("Anything that is not a commute keeps its own name")
    func othersKeepTheirNames() {
        let training = ride(42, id: "x2")
        #expect(training.extraTitle == "Morning Ride")
        #expect(training.extraCaption == training.extraLabel)
    }

    @Test("Marking a long ride a commute retitles its row")
    func theTitleFollowsTheAnswer() {
        let r = ride(42, id: "x3")
        #expect(r.extraTitle == "Morning Ride")
        CommuteStore.shared.set(true, for: "x3")
        defer { forget("x3") }
        #expect(r.extraTitle == "Commute")
    }

    // MARK: Splitting a group — patch 253

    @Test("Taking one ride out of the commutes leaves the rest merged")
    func onePartSplitsOut() throws {
        // 4 August: three short rides. Mark the middle one as training and it
        // becomes plan-eligible, which is exactly the test `MergedExtra.group`
        // already applies — so it leaves the group with no extra machinery.
        CommuteStore.shared.set(false, for: "s2")
        defer { forget("s2") }

        let items = MergedExtra.group([ride(2.79, id: "s1"),
                                       ride(6.09, id: "s2"),
                                       ride(4.44, id: "s3")])
        let merged = items.compactMap { item -> MergedExtra? in
            if case .merged(let m) = item { return m }
            return nil
        }
        let group = try #require(merged.first)
        #expect(group.parts.count == 2)
        #expect(group.parts.map(\.id).contains("s2") == false)
        #expect(group.countLabel == "2 commutes")
        // And the one taken out is still on the day, on its own.
        #expect(items.count == 2)
    }

    @Test("Taking one of two out leaves no group at all")
    func aGroupOfOneIsNotAGroup() {
        CommuteStore.shared.set(false, for: "s5")
        defer { forget("s5") }

        let items = MergedExtra.group([ride(2.79, id: "s4"), ride(6.09, id: "s5")])
        let merged = items.contains { if case .merged = $0 { return true }; return false }
        // A single walk is an activity, not a group of one — the same rule that
        // has always applied, reached from the other direction.
        #expect(merged == false)
        #expect(items.count == 2)
    }

    @Test("Every ride taken out means no commutes left")
    func allPartsCanLeave() {
        CommuteStore.shared.set(false, for: "s6")
        CommuteStore.shared.set(false, for: "s7")
        defer { forget("s6", "s7") }

        let rides = [ride(2.79, id: "s6"), ride(6.09, id: "s7")]
        #expect(rides.filter(\.isCommuteRide).isEmpty)
        // Which is what Today's Commute cell keys off: no commutes, no cell.
        #expect(rides.allSatisfy(\.isPlanEligible))
    }

    // MARK: Training rides group too — patch 254

    @Test("Two training rides on one day are one row, headed Rides")
    func trainingRidesGroupWithEachOther() throws {
        // Until 254 the merge excluded every plan-eligible row, so two
        // unmatched training rides on one day were two rows saying one thing.
        let items = MergedExtra.group([ride(42, id: "g1"), ride(38, id: "g2")])
        let merged = items.compactMap { item -> MergedExtra? in
            if case .merged(let m) = item { return m }
            return nil
        }
        let group = try #require(merged.first)
        #expect(group.parts.count == 2)
        #expect(group.title == "Rides")
        #expect(group.countLabel == "2 rides")
    }

    @Test("Commutes and training rides never land in the same row")
    func theTwoKindsDoNotMix() throws {
        // The reason the old rule existed: a 40 km training ride folded into
        // the commutes would be filed under a commute heading. Keying the
        // bucket on commute-ness keeps them apart without stopping either from
        // grouping with its own kind.
        let items = MergedExtra.group([ride(2.79, id: "g3"),   // commute
                                       ride(4.44, id: "g4"),   // commute
                                       ride(42, id: "g5"),     // training
                                       ride(38, id: "g6")])    // training
        let merged = items.compactMap { item -> MergedExtra? in
            if case .merged(let m) = item { return m }
            return nil
        }
        #expect(merged.count == 2, "expected a Commutes row and a Rides row")
        let titles = Set(merged.map(\.title))
        #expect(titles == ["Commutes", "Rides"])
        for group in merged {
            let kinds = Set(group.parts.map(\.isCommuteRide))
            #expect(kinds.count == 1, "a row mixed commutes with training")
        }
    }

    @Test("A group sits where its first part sat")
    func orderIsPreserved() {
        // Chronology survives the new key: the commutes start first, so the
        // Commutes row comes first.
        let items = MergedExtra.group([ride(2.79, id: "g7"),
                                       ride(42, id: "g8"),
                                       ride(4.44, id: "g9"),
                                       ride(38, id: "g10")])
        let titles = items.compactMap { item -> String? in
            if case .merged(let m) = item { return m.title }
            return nil
        }
        #expect(titles == ["Commutes", "Rides"])
    }

    @Test("Marking a ride moves it between the two groups")
    func aRideChangesGroups() throws {
        let rides = [ride(2.79, id: "g11"), ride(4.44, id: "g12"), ride(6.09, id: "g13")]
        func titles() -> [String] {
            MergedExtra.group(rides).compactMap { item in
                if case .merged(let m) = item { return "\(m.title) \(m.parts.count)" }
                return nil
            }
        }
        #expect(titles() == ["Commutes 3"])

        CommuteStore.shared.set(false, for: "g12")
        defer { forget("g12") }
        // One out of three: two commutes still merge, and the loner is a single
        // row rather than a group of one.
        #expect(titles() == ["Commutes 2"])

        CommuteStore.shared.set(false, for: "g13")
        defer { forget("g13") }
        #expect(titles() == ["Rides 2"], "the two taken out should group as Rides")
    }

    // MARK: Nothing left pointing at Strava

    @Test("A ride with a commute field in its JSON decodes, and ignores it")
    func stravasFlagIsNoLongerRead() throws {
        // Strava still sends it. The app is leaving, and reading it would
        // reintroduce a source of truth this patch exists to remove — so the
        // field is decoded past, not decoded.
        let json = """
            [{"id":19608576674,"name":"Morning Ride","sport_type":"Ride",
              "start_date_local":"2026-08-04T07:26:16Z","distance":42000,
              "moving_time":5000,"elapsed_time":5000,"commute":true}]
            """
        let decoded = try JSONDecoder().decode([StravaActivityDTO].self,
                                               from: Data(json.utf8))
        let a = try #require(decoded.first?.toActivity())
        #expect(a.isCommuteRide == false,
                "Strava's flag reached the classification, which patch 251 removed")
    }
}
