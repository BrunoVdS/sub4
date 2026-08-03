//
//  WeatherReduceTests.swift
//  Sub4CoreTests
//
//  The overlap weighting, asserted — patch 193, plan step 2.4.
//
//  WHY THESE NUMBERS ARE HAND-CALCULATED
//  -------------------------------------
//  Every expectation below is worked out on paper in the comment above it. A
//  test that asserts whatever the implementation happens to return is a
//  regression detector and nothing more; these are meant to say what the right
//  answer IS, so that if the implementation changes the test can adjudicate.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct WeatherReduceTests {

    /// A session that straddles two hours very unevenly — five minutes of the
    /// first, fifty of the second. Not exotic: it is every run that starts at
    /// five to.
    ///
    /// 07:55 → 08:50. Overlap: 300 s in the 07:00 hour, 3000 s in the 08:00.
    /// Weighted mean of 12° and 18° = (12·300 + 18·3000) / 3300
    ///                              = (3600 + 54000) / 3300 = 17.45°
    ///
    /// WHAT THE OLD CODE ACTUALLY DID, corrected after this test caught the
    /// claim in the first version of this comment: it returned 18.0°, not 15.0°.
    /// The old filter kept samples after `start - 30min`, so for a 07:55 start
    /// the 07:00 hour was DROPPED and the flat mean had one value to average.
    /// Two errors were cancelling — an hour wrongly excluded, and the rest
    /// wrongly weighted — and the answer was accidentally close. The first
    /// version of this test asserted a 2.45° improvement that was really 0.55°,
    /// and was wrong about which mechanism produced it.
    @Test("An unevenly straddled hour is weighted by the minutes in it")
    func unevenStraddleIsWeighted() throws {
        let start = date("2026-03-14T07:55:00Z")
        let end   = date("2026-03-14T08:50:00Z")
        let samples = [
            hour("2026-03-14T07:00:00Z", temp: 12),
            hour("2026-03-14T08:00:00Z", temp: 18)
        ]
        let w = try #require(WeatherStore.reduce(samples, id: "a",
                                                 start: start, end: end,
                                                 source: .openMeteo))
        #expect(abs(w.tempC - 17.4545) < 0.01, "got \(w.tempC), expected 17.45")
        // And not the flat mean of the two overlapping hours, which is 15.0.
        #expect(abs(w.tempC - 15.0) > 2.0)
    }

    /// The symmetric case, as a control: half an hour either side must still
    /// average to the midpoint. A weighting that only produced different answers
    /// would be as suspicious as one that never did.
    @Test("An evenly straddled hour still averages to the middle")
    func evenStraddleIsUnchanged() throws {
        let start = date("2026-03-14T07:30:00Z")
        let end   = date("2026-03-14T08:30:00Z")
        let samples = [
            hour("2026-03-14T07:00:00Z", temp: 10),
            hour("2026-03-14T08:00:00Z", temp: 20)
        ]
        let w = try #require(WeatherStore.reduce(samples, id: "a",
                                                 start: start, end: end,
                                                 source: .openMeteo))
        #expect(abs(w.tempC - 15.0) < 0.01, "got \(w.tempC)")
    }

    /// Rain is a TOTAL, not a mean: the provider reports millimetres per hour,
    /// so an hour the session was in for five minutes should contribute a
    /// twelfth of its rainfall, not all of it.
    ///
    /// 07:55 → 08:50, 4 mm in the 07:00 hour and 1 mm in the 08:00.
    /// Weighted: 4·(300/3600) + 1·(3000/3600) = 0.333 + 0.833 = 1.167 mm
    ///
    /// AGAIN, THE OLD FIGURE WAS NOT WHAT I CLAIMED. It was 1.0 mm, not 5 mm —
    /// the 07:00 hour never reached the sum because the filter had already
    /// discarded it. The overstatement I described would have been real for a
    /// session starting at, say, 07:20, where both hours survived the filter and
    /// both were counted whole.
    @Test("Rainfall counts only the fraction of the hour actually run in")
    func rainIsScaledByOverlap() throws {
        let start = date("2026-03-14T07:55:00Z")
        let end   = date("2026-03-14T08:50:00Z")
        let samples = [
            hour("2026-03-14T07:00:00Z", temp: 12, rain: 4),
            hour("2026-03-14T08:00:00Z", temp: 12, rain: 1)
        ]
        let w = try #require(WeatherStore.reduce(samples, id: "a",
                                                 start: start, end: end,
                                                 source: .openMeteo))
        #expect(abs(w.precipitationMm - 1.1667) < 0.01, "got \(w.precipitationMm)")
        // Not the unweighted sum of both hours, which is what a naive total
        // over the overlapping hours would give.
        #expect(w.precipitationMm < 5.0, "both hours were counted whole")
    }

    /// A whole hour inside a longer session contributes its whole rainfall —
    /// the scaling must not shrink hours the athlete was out for all of.
    @Test("A fully occupied hour contributes all of its rain")
    func fullHourKeepsItsRain() throws {
        let start = date("2026-03-14T07:00:00Z")
        let end   = date("2026-03-14T09:00:00Z")
        let samples = [
            hour("2026-03-14T07:00:00Z", temp: 10, rain: 2),
            hour("2026-03-14T08:00:00Z", temp: 10, rain: 3)
        ]
        let w = try #require(WeatherStore.reduce(samples, id: "a",
                                                 start: start, end: end,
                                                 source: .openMeteo))
        #expect(abs(w.precipitationMm - 5.0) < 0.01, "got \(w.precipitationMm)")
    }

    /// THE HOUR THE OLD FILTER THREW AWAY. A session starting more than half an
    /// hour past the hour lost its opening hour entirely — the filter kept
    /// samples after `start - 30min`, and 07:00 is 55 minutes before 07:55.
    ///
    /// Here the discarded hour is the cold one, so its absence made the session
    /// look warmer than it was. With both hours present and weighted, the five
    /// cold minutes pull the figure down by half a degree — small, correct, and
    /// the difference between a number derived from the session and a number
    /// derived from part of it.
    @Test("The opening hour is included even when the session starts late in it")
    func lateStartStillCountsItsOpeningHour() throws {
        let start = date("2026-03-14T07:55:00Z")
        let end   = date("2026-03-14T08:50:00Z")
        let samples = [
            hour("2026-03-14T07:00:00Z", temp: 12),
            hour("2026-03-14T08:00:00Z", temp: 18)
        ]
        let w = try #require(WeatherStore.reduce(samples, id: "a",
                                                 start: start, end: end,
                                                 source: .openMeteo))
        #expect(w.samples == 2, "the opening hour was dropped again")
        #expect(w.tempC < 18.0, "with the 12° hour included the mean must fall below 18")
    }

    /// The condition shown on the card is the heaviest hour's, not the middle
    /// one's. For the 07:55 run the middle sample IS the five-minute hour, so
    /// the old choice could report the conditions of a period the athlete barely
    /// experienced.
    @Test("The condition comes from the hour most of the session was in")
    func conditionComesFromTheHeaviestHour() throws {
        let start = date("2026-03-14T07:55:00Z")
        let end   = date("2026-03-14T08:50:00Z")
        let samples = [
            hour("2026-03-14T07:00:00Z", temp: 12, condition: "Heavy Rain"),
            hour("2026-03-14T08:00:00Z", temp: 18, condition: "Clear")
        ]
        let w = try #require(WeatherStore.reduce(samples, id: "a",
                                                 start: start, end: end,
                                                 source: .openMeteo))
        #expect(w.conditionLabel == "Clear",
                "reported \(w.conditionLabel) for a session almost entirely in the clear hour")
    }

    /// Wind direction is a vector mean AND weighted. Two nearly opposite
    /// readings, one of which the athlete was barely in, must resolve towards
    /// the hour they actually ran in rather than to the midpoint between them.
    @Test("Wind direction leans to the hour actually run in")
    func windDirectionIsWeighted() throws {
        let start = date("2026-03-14T07:55:00Z")
        let end   = date("2026-03-14T08:50:00Z")
        let samples = [
            hour("2026-03-14T07:00:00Z", temp: 12, windFrom: 0),
            hour("2026-03-14T08:00:00Z", temp: 12, windFrom: 90)
        ]
        let w = try #require(WeatherStore.reduce(samples, id: "a",
                                                 start: start, end: end,
                                                 source: .openMeteo))
        // Ten times the weight on 90° pulls the mean well past halfway.
        #expect(w.windFromDegrees > 70, "got \(w.windFromDegrees), expected near 90")
        #expect(w.windFromDegrees <= 90.5)
    }

    /// A zero-length activity would divide by zero. It must produce a row
    /// rather than nil or a NaN — the fallback to equal weights is deliberate
    /// and this is what pins it.
    @Test("A zero-length session still produces a reading")
    func zeroLengthDoesNotDivideByZero() throws {
        let t = date("2026-03-14T08:00:00Z")
        let samples = [hour("2026-03-14T08:00:00Z", temp: 14)]
        let w = try #require(WeatherStore.reduce(samples, id: "a",
                                                 start: t, end: t,
                                                 source: .openMeteo))
        #expect(w.tempC.isNaN == false)
        #expect(abs(w.tempC - 14.0) < 0.01)
    }

    @Test("No samples produces no reading")
    func noSamplesIsNil() {
        let start = date("2026-03-14T07:00:00Z")
        let end   = date("2026-03-14T08:00:00Z")
        #expect(WeatherStore.reduce([], id: "a", start: start, end: end,
                                    source: .openMeteo) == nil)
    }

    // MARK: Fixtures

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    private func hour(_ iso: String, temp: Double, rain: Double = 0,
                      windFrom: Double = 180, condition: String = "Cloudy") -> HourSample {
        HourSample(date: date(iso), tempC: temp, feelsLikeC: temp,
                   humidity: 0.5, windKmh: 10, windFromDegrees: windFrom,
                   precipitationMm: rain, symbolName: "cloud",
                   conditionLabel: condition)
    }
}
