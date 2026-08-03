//
//  TimeZoneTests.swift
//  Sub4CoreTests
//
//  Which clock a session was recorded on — patch 196, ADR-0003 §4.3 and §4.4.
//
//  WHY THESE EXIST BEFORE THE TRIP RATHER THAN AFTER IT
//  ---------------------------------------------------
//  Strava sends `timezone` and `utc_offset` on every activity and always has.
//  ADR-0002 retires Strava at Phase 4A and Apple Health carries neither field,
//  so an activity that arrives without its zone has lost it permanently — it
//  cannot be recovered from a coordinate, a name or a date. The Japan block
//  runs 6–30 September 2026. Everything here is written now because "now" is
//  the only time it can be.
//
//  THE ONE THAT MATTERS IS `summerRunAtHomeIsNotLabelledInWinter`.
//  The obvious implementation of the display rule compares the activity's
//  offset against the device's offset TODAY, and that version is wrong for
//  roughly half of every year in a country with daylight saving. It is the kind
//  of wrong that looks right on the day it is written and starts lying at the
//  end of October.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct TimeZoneParsingTests {

    /// Strava's field is a display string with the identifier stuck on the end.
    @Test("Strava's decorated zone string yields the identifier alone")
    func decoratedZoneIsParsed() {
        #expect(Activity.zoneIdentifier(from: "(GMT+09:00) Asia/Tokyo") == "Asia/Tokyo")
        #expect(Activity.zoneIdentifier(from: "(GMT+01:00) Europe/Brussels") == "Europe/Brussels")
        #expect(Activity.zoneIdentifier(from: "(GMT-05:00) America/New_York") == "America/New_York")
    }

    @Test("A bare identifier is accepted as it stands")
    func bareIdentifierIsAccepted() {
        #expect(Activity.zoneIdentifier(from: "Asia/Tokyo") == "Asia/Tokyo")
    }

    /// An identifier this device cannot resolve is worth nothing to the
    /// abbreviation lookup, and storing it would put something in the column
    /// that looks like information. NULL is the honest answer — ADR-0003 §6.
    @Test("An unresolvable identifier is discarded rather than stored")
    func unknownIdentifierIsDiscarded() {
        #expect(Activity.zoneIdentifier(from: "(GMT+09:00) Not/AZone") == nil)
        #expect(Activity.zoneIdentifier(from: "nonsense") == nil)
        #expect(Activity.zoneIdentifier(from: "") == nil)
        #expect(Activity.zoneIdentifier(from: nil) == nil)
    }

    @Test("The GMT fallback reads correctly either side of zero")
    func gmtLabelIsReadable() {
        #expect(Activity.gmtLabel(32_400) == "GMT+9")
        #expect(Activity.gmtLabel(-14_400) == "GMT-4")
        #expect(Activity.gmtLabel(0) == "GMT+0")
        // Kathmandu. The reason the minutes case is written rather than assumed
        // away — a great many zone implementations round it off.
        #expect(Activity.gmtLabel(20_700) == "GMT+5:45")
        // Chatham Islands.
        #expect(Activity.gmtLabel(45_900) == "GMT+12:45")
    }

    /// THE DECODING TRAP. Strava sends `utc_offset` as a JSON number with a
    /// decimal point — `32400.0`. Declaring it `Int` in the DTO does not fail
    /// gracefully: `Decodable` throws, and the throw takes the whole activity
    /// with it, so one field's type mistake silently drops sessions.
    @Test("A float utc_offset decodes and narrows to seconds")
    func floatOffsetDecodes() throws {
        let json = """
        {"id": 19580875358, "name": "Morning Run", "sport_type": "Run",
         "start_date_local": "2026-09-14T07:00:00Z", "start_date": "2026-09-13T22:00:00Z",
         "distance": 10000.0, "moving_time": 3000, "elapsed_time": 3100,
         "timezone": "(GMT+09:00) Asia/Tokyo", "utc_offset": 32400.0}
        """
        let dto = try JSONDecoder().decode(StravaActivityDTO.self, from: Data(json.utf8))
        let a = dto.toActivity()
        #expect(a.startOffsetSeconds == 32_400)
        #expect(a.timeZoneIdentifier == "Asia/Tokyo")
    }

    /// An activity from before this patch, or from a source that sends neither
    /// field, must decode with both nil rather than failing.
    @Test("An activity with no zone information still decodes")
    func missingZoneIsNotAFailure() throws {
        let json = """
        {"id": 1, "name": "Run", "sport_type": "Run",
         "start_date_local": "2026-06-01T07:00:00Z", "distance": 5000.0}
        """
        let dto = try JSONDecoder().decode(StravaActivityDTO.self, from: Data(json.utf8))
        let a = dto.toActivity()
        #expect(a.startOffsetSeconds == nil)
        #expect(a.timeZoneIdentifier == nil)
    }
}

// MARK: - The display rule

@Suite
struct TimeZoneDisplayTests {

    private let brussels = TimeZone(identifier: "Europe/Brussels")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func activity(startLocal: String, startUTC: String?,
                          zone: String?, offset: Int?) -> Activity {
        Activity(id: "A", name: "Morning Run", sportType: "Run",
                 startLocal: startLocal, distance: 10_000,
                 movingTime: 3_000, elapsedTime: 3_100,
                 elevationGain: nil, averageHeartrate: nil, isTrainer: nil,
                 maxHeartrate: nil, gearId: nil, maxSpeed: nil,
                 deviceWatts: nil, averageWatts: nil,
                 startUTC: startUTC, startLat: nil, startLon: nil,
                 timeZoneIdentifier: zone, startOffsetSeconds: offset)
    }

    /// A run at home reads as the time and nothing else. 650 of the 660
    /// activities on this device are this case, and a zone marker on all of
    /// them would be noise that hides the ten that matter.
    @Test("A run at home shows the time with no zone")
    func homeRunHasNoSuffix() {
        let a = activity(startLocal: "2026-06-14T07:00:00",
                         startUTC: "2026-06-14T05:00:00Z",
                         zone: "Europe/Brussels", offset: 7_200)
        #expect(a.timeLabel(forReaderIn: brussels) == "07:00")
        #expect(a.zoneSuffix(forReaderIn: brussels) == nil)
    }

    /// THE CASE THIS WAS BUILT FOR. 14 September 2026, a 07:00 run in Tokyo,
    /// read at home in Belgium.
    @Test("A Japan run keeps its own clock and says which")
    func japanRunIsLabelled() throws {
        let a = activity(startLocal: "2026-09-14T07:00:00",
                         startUTC: "2026-09-13T22:00:00Z",
                         zone: "Asia/Tokyo", offset: 32_400)
        let suffix = try #require(a.zoneSuffix(forReaderIn: brussels))
        // Either is correct and which one appears is an ICU detail this app does
        // not control — hence the fallback in `zoneAbbreviation`. What is being
        // asserted is that the label identifies +9 to a reader.
        #expect(["JST", "GMT+9"].contains(suffix), "got \(suffix)")
        #expect(a.timeLabel(forReaderIn: brussels).hasPrefix("07:00 "))
        // And NOT converted. A 07:00 Tokyo run rendered in Brussels time would
        // read 00:00, which is the failure ADR-0003 §4.2 exists to prevent.
        #expect(!a.timeLabel(forReaderIn: brussels).hasPrefix("00:00"))
    }

    /// Read while standing in Tokyo, the same run needs no marker — the reader
    /// and the run are on one clock.
    @Test("The same run needs no marker when the reader is in Japan too")
    func japanRunIsPlainInJapan() {
        let a = activity(startLocal: "2026-09-14T07:00:00",
                         startUTC: "2026-09-13T22:00:00Z",
                         zone: "Asia/Tokyo", offset: 32_400)
        #expect(a.timeLabel(forReaderIn: tokyo) == "07:00")
    }

    /// THE BUG THE OBVIOUS IMPLEMENTATION HAS.
    ///
    /// Comparing the stored offset against the device's offset *now* rather
    /// than at the activity's instant means a June run in Brussels — recorded
    /// at +2 — is compared against +1 once the clocks go back in October, comes
    /// out as different, and grows a "CEST" suffix it should never have. Every
    /// summer activity in the history would be labelled foreign all winter, and
    /// every winter one all summer: about half of everything, changing twice a
    /// year on its own with nothing on screen to explain it.
    @Test("A summer run at home is not labelled when read in winter")
    func summerRunAtHomeIsNotLabelledInWinter() {
        let june = activity(startLocal: "2026-06-14T07:00:00",
                            startUTC: "2026-06-14T05:00:00Z",
                            zone: "Europe/Brussels", offset: 7_200)
        let december = activity(startLocal: "2026-12-14T07:00:00",
                                startUTC: "2026-12-14T06:00:00Z",
                                zone: "Europe/Brussels", offset: 3_600)
        #expect(june.zoneSuffix(forReaderIn: brussels) == nil,
                "a June run at home was labelled as foreign")
        #expect(december.zoneSuffix(forReaderIn: brussels) == nil,
                "a December run at home was labelled as foreign")
    }

    /// The arithmetic behind the previous test, stated rather than implied — in
    /// the same spirit as the weather suite's non-negativity check. If Brussels
    /// ever stopped observing daylight saving these two would be equal and that
    /// test would pass for the wrong reason.
    @Test("Brussels really is on two different offsets across the year")
    func brusselsHasTwoOffsets() {
        let june = ISO8601DateFormatter().date(from: "2026-06-14T05:00:00Z")!
        let december = ISO8601DateFormatter().date(from: "2026-12-14T06:00:00Z")!
        #expect(brussels.secondsFromGMT(for: june) == 7_200)
        #expect(brussels.secondsFromGMT(for: december) == 3_600)
        #expect(brussels.secondsFromGMT(for: june) != brussels.secondsFromGMT(for: december),
                "the comparison-at-instant rule is protecting nothing here")
    }

    /// Compared by OFFSET, not by identifier. A run in Paris and a run in
    /// Brussels are on the same clock, and "CET" on one of them would be true
    /// and useless.
    @Test("A different country on the same clock gets no marker")
    func sameClockDifferentCountryIsPlain() {
        let a = activity(startLocal: "2026-06-14T07:00:00",
                         startUTC: "2026-06-14T05:00:00Z",
                         zone: "Europe/Paris", offset: 7_200)
        #expect(a.zoneSuffix(forReaderIn: brussels) == nil)
    }

    /// ADR-0003 §6, at the display layer. An offset of zero is Greenwich — a
    /// real place, and one this reader is not standing in — so it must produce
    /// a marker. An implementation using `0` as a stand-in for unknown would
    /// silently drop this case.
    @Test("An offset of zero is a place, not a missing value")
    func greenwichIsNotUnknown() throws {
        let a = activity(startLocal: "2026-01-14T07:00:00",
                         startUTC: "2026-01-14T07:00:00Z",
                         zone: "Atlantic/Reykjavik", offset: 0)
        let suffix = try #require(a.zoneSuffix(forReaderIn: brussels),
                                  "an offset of 0 was treated as no information")
        #expect(suffix.contains("0") || suffix == "GMT")
    }

    /// The 660 activities on the device today, until the backfill runs.
    @Test("An activity with no zone shows the time and claims nothing")
    func unknownZoneClaimsNothing() {
        let a = activity(startLocal: "2026-06-14T07:00:00",
                         startUTC: "2026-06-14T05:00:00Z",
                         zone: nil, offset: nil)
        #expect(a.zoneSuffix(forReaderIn: brussels) == nil)
        #expect(a.timeLabel(forReaderIn: brussels) == "07:00")
    }

    /// The offset is the authority — ADR-0003 §4.3. Where the two disagree, the
    /// stored number wins, because it was recorded at the instant and the
    /// identifier has to be re-evaluated against a zone database that may have
    /// changed since. Zone rules are amended by governments several times a
    /// year.
    @Test("The stored offset outranks the identifier")
    func offsetIsTheAuthority() {
        let instant = ISO8601DateFormatter().date(from: "2026-09-13T22:00:00Z")!
        let a = activity(startLocal: "2026-09-14T07:00:00",
                         startUTC: "2026-09-13T22:00:00Z",
                         zone: "Europe/Brussels", offset: 32_400)
        #expect(a.offsetSeconds(at: instant) == 32_400,
                "the identifier overrode the stored offset")
    }

    /// Without the instant there is nothing to compare against, and guessing is
    /// worse than saying nothing.
    @Test("An activity with no start instant claims no zone")
    func noInstantMeansNoClaim() {
        let a = activity(startLocal: "2026-09-14T07:00:00", startUTC: nil,
                         zone: "Asia/Tokyo", offset: 32_400)
        #expect(a.zoneSuffix(forReaderIn: brussels) == nil)
        #expect(a.timeLabel(forReaderIn: brussels) == "07:00")
    }

    /// ADR-0003 §4.2's second failure: `dayKey` derives from `startLocal`, so
    /// converting to home time would move a Tuesday run in Tokyo onto Monday
    /// and match it against the wrong prescription. Nothing in this patch
    /// touches `startLocal`, and this is what says so.
    @Test("The training day is unchanged by the zone")
    func dayKeyIsUntouched() {
        let a = activity(startLocal: "2026-09-15T07:00:00",
                         startUTC: "2026-09-14T22:00:00Z",
                         zone: "Asia/Tokyo", offset: 32_400)
        #expect(a.dayKey == "2026-09-15",
                "the training day followed the instant rather than the clock")
    }
}

// MARK: - The backfill

@Suite
struct ZoneBackfillTests {

    /// The rewind writes a preference key, and a preference key the inventory
    /// does not name survives "Delete local data". Same drift check that caught
    /// seventeen undeclared keys in patch 183.
    @Test("The zone backfill key is declared in the inventory")
    func backfillKeyIsDeclared() {
        #expect(DataLifecycle.preferenceKeys.contains(ActivityStore.zoneBackfillKey),
                "\(ActivityStore.zoneBackfillKey) is written by the app and appears in no category")
    }

    /// Its own key rather than a reused one. A rewind sharing another field's
    /// flag would find it already set, skip silently, and look done — which is
    /// the failure mode the speed backfill hit in patch 123 and had to be
    /// versioned out of.
    @Test("The zone backfill does not share a flag with another field")
    func backfillKeyIsItsOwn() {
        let others = ["strava.geoBackfill", "strava.powerBackfill", "strava.speedBackfill"]
        #expect(!others.contains(ActivityStore.zoneBackfillKey))
    }
}
