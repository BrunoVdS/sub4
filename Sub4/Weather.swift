//
//  Weather.swift
//  Sub4
//
//  What the air was doing while you were out in it.
//
//  WHY THIS EXISTS, AND WHY IT IS NOT DECORATION
//  ---------------------------------------------
//  The activity detail page already delivers a verdict — 26 points of "Off the
//  target" over a pace that missed. That verdict is computed from distance and
//  time and nothing else, which is the correct way to compute it and an
//  incomplete way to READ it. A 6:29 kilometre at 28 °C with 78% humidity and a
//  headwind is a different session from a 6:29 kilometre at 9 °C and still air,
//  and the app currently says the same thing about both.
//
//  So this is context for a judgement the app has already made. It is placed
//  next to the verdict for that reason and nowhere else in the app, because
//  nowhere else in the app is making that judgement.
//
//  WHAT IT DOES NOT DO
//  -------------------
//  It does not adjust anything. No pace correction, no "weather-adjusted
//  target", no asterisk on the load figure. Heat-adjustment models exist and
//  they are all fitted to populations rather than to one athlete; applying one
//  here would replace a measured number you can argue with by a modelled number
//  you cannot. The reader does the adjusting, with the numbers in front of them.
//
//  AN AVERAGE OVER THE SESSION, NOT THE CONDITIONS AT THE GUN
//  ----------------------------------------------------------
//  A long run is ninety minutes. Both providers answer in hourly samples, so a
//  session that starts at 07:50 and finishes at 09:20 touches three of them.
//  Quoting the first would describe the warm-up. Every figure below is the mean
//  across the samples the activity actually overlapped, and `samples` records
//  how many that was — one means the session fitted inside a single hour, not
//  that the data is thin.
//
//  TWO PROVIDERS, TRIED IN ORDER
//  -----------------------------
//  Apple Weather first, Open-Meteo when Apple cannot answer.
//
//  This is not hedging. WeatherKit needs the
//  `com.apple.developer.weatherkit` entitlement, the entitlement needs the
//  capability, and the capability needs an ACTIVE paid Apple Developer Program
//  membership — payment alone is not activation, and enrolment can sit in
//  review for days. Built against WeatherKit alone, the feature produced 571
//  requests and 0 successes. Built against Open-Meteo alone, it works today and
//  throws away a source that is about to become available.
//
//  So both. The fallback is not a downgrade either: Open-Meteo's history is
//  ERA5 reanalysis, the reference dataset national met services use to
//  reconstruct past conditions, which for "what was the air doing in Antwerp
//  last March" is arguably the better answer. Every stored reading records
//  WHICH provider produced it, and the card credits that provider — two sources
//  in one card with no way to tell them apart would be worse than one.
//
//  THE CIRCUIT BREAKER MATTERS MORE THAN IT LOOKS
//  ----------------------------------------------
//  Without one, every fetch pays a failing WeatherKit round trip before falling
//  through — 571 of them during a backfill, for nothing. After three
//  consecutive failures with no success, Apple is skipped for the rest of the
//  session. A relaunch tries again, which is exactly the behaviour wanted while
//  waiting on an enrolment: the day it activates, the next launch picks it up
//  with nothing to configure.
//
//  ONE REDUCER, TWO SOURCES
//  ------------------------
//  Both providers return `[HourSample]` and a single `reduce` turns those into
//  the stored value. The averaging is where a two-provider implementation would
//  quietly diverge — Apple's readings averaged one way and Open-Meteo's
//  another, with no test that would catch it — so it exists once.
//
//  ATTRIBUTION IS A CONDITION OF USE FOR BOTH.
//  Apple requires its mark and a link to its legal page. Open-Meteo is CC-BY
//  4.0 and asks for credit. `WeatherAttributionView` renders whichever applies
//  to the reading on screen.
//

import Foundation
import CoreLocation
import SwiftUI
import WeatherKit

// MARK: - What is stored

/// Who measured it. Stored per reading, shown on the card.
enum WeatherSource: String, Codable, Hashable {
    case appleWeather, openMeteo

    var label: String {
        switch self {
        case .appleWeather: "Apple Weather"
        case .openMeteo:    "Open-Meteo · ERA5"
        }
    }
}

/// One activity's conditions, reduced to the handful of figures worth printing.
///
/// A value type written to disk rather than a live query, because past weather
/// does not change. Once fetched, an activity's row is correct for ever and the
/// network is never asked again — which matters more than it sounds: 655
/// activities against a quota is a real number, and a view that re-queried on
/// every appearance would spend it on scrolling.
struct ActivityWeather: Codable, Hashable {

    let activityId: String
    /// Degrees Celsius, mean over the session.
    let tempC: Double
    /// What it felt like — humidity and wind folded in by the provider.
    let feelsLikeC: Double
    /// 0…1.
    let humidity: Double
    let windKmh: Double
    /// Degrees the wind came FROM, meteorological convention.
    let windFromDegrees: Double
    let precipitationMm: Double
    /// SF Symbol for the dominant condition.
    let symbolName: String
    /// Words for it — "Mostly Cloudy", "Rain".
    let conditionLabel: String
    /// How many hourly samples the session overlapped.
    let samples: Int
    let fetched: Date

    /// Optional only so the handful of rows written before patch 133 still
    /// decode. Those came from Open-Meteo — it was the only provider that ever
    /// successfully returned anything — so nil resolves there rather than to a
    /// vague "unknown source" the card would have to apologise for.
    var source: WeatherSource?

    var provider: WeatherSource { source ?? .openMeteo }

    /// The compass point the wind came from, which is what anybody actually
    /// wants. A bearing in degrees is precise and unreadable.
    var windFromLabel: String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let i = Int(((windFromDegrees.truncatingRemainder(dividingBy: 360) + 360)
                     .truncatingRemainder(dividingBy: 360)) / 22.5 + 0.5) % 16
        return points[i]
    }

    /// Printed only when it differs from the measured temperature by enough to
    /// be a fact rather than a rounding artefact.
    var feelsLikeIsDifferent: Bool { abs(feelsLikeC - tempC) >= 1.0 }

    /// The one line the card leads with, when there is something to say.
    ///
    /// DELIBERATELY NARROW. It fires on conditions that are known to change
    /// what a pace means, at thresholds that are widely used rather than fitted
    /// to this athlete's history — because with 655 activities and one runner
    /// there is not enough data to fit anything, and a threshold invented to
    /// match a few sessions is a threshold that will keep matching them.
    ///
    /// It says the conditions were hard. It does not say by how much.
    var note: String? {
        if tempC >= 25 && humidity >= 0.6 {
            return "Hot and humid — pace costs more here than the clock shows."
        }
        if tempC >= 25 { return "Hot." }
        if windKmh >= 30 { return "Strong wind — a headwind leg and a tailwind leg are not the same run." }
        if tempC <= 0 { return "Below freezing." }
        if precipitationMm >= 2 { return "Wet." }
        return nil
    }
}

// MARK: - The store

/// Fetch once, keep for ever. On demand by default, in bulk when asked.
///
/// NOTHING IS FETCHED SPECULATIVELY
/// -------------------------------
/// Opening an activity fetches that activity. Nothing else fetches anything —
/// no background drain, no prefetch while scrolling — because 655 calls spent
/// populating cards nobody asked to see is a bad trade at any quota. The one
/// exception is `backfill`, which is a button somebody pressed.
@Observable
@MainActor
final class WeatherStore {

    static let shared = WeatherStore()

    private(set) var byActivity: [String: ActivityWeather] = [:]
    /// Ids whose fetch failed this session.
    ///
    /// IN MEMORY ONLY, AND THAT IS A CORRECTION.
    /// The first version persisted this. It meant a run opened on a train, or
    /// opened once before either provider worked, was blank FOR EVER
    /// — the app had recorded "we tried" and never distinguished that from "and
    /// there is nothing to find". A transient network failure is not a fact
    /// about the weather in June.
    ///
    /// Session-scoped costs one retry per launch for activities that really do
    /// have no data, which is cheap: `canFetch` stops indoor sessions and rows
    /// without coordinates before the network is touched at all, so the retry
    /// set is small and it self-heals the moment the cause is fixed.
    private(set) var unavailable: Set<String> = []
    private(set) var inFlight: Set<String> = []

    private let fileURL: URL

    // MARK: Backfill
    //
    // WHY THIS EXISTS, HAVING ARGUED AGAINST IT
    // -----------------------------------------
    // The note at the top of this file said no queue: weather is wanted by one
    // screen showing one activity, so fetching on demand is the cheapest
    // correct policy. That argument was about not spending 655 calls on cards
    // nobody asked to see, and it still holds for anything AUTOMATIC.
    //
    // It does not hold for a button. Reading back through a season with a
    // network wait on every page is a different experience from browsing one
    // that is already complete, and the person pressing the button has asked
    // for exactly the thing the argument was protecting them from. So: opt-in,
    // once, visible progress, and nothing speculative.
    private(set) var backfillRunning = false
    private(set) var backfillDone = 0
    private(set) var backfillTotal = 0

    // MARK: The Apple circuit breaker
    //
    // Session state, never persisted. See the header: without this, a backfill
    // with no entitlement pays 571 failing round trips to Apple before falling
    // through to the provider that works. Three strikes and Apple is skipped
    // until the next launch — which is also how the app picks up an enrolment
    // the day it activates, with nothing to configure.
    private var appleFailures = 0
    private var appleSucceeded = false
    private var appleDisabled: Bool { !appleSucceeded && appleFailures >= 3 }

    /// What the last completed fetch used, for the diagnostics row in Settings.
    private(set) var lastSource: WeatherSource?

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("weather.json")
        // Patch 130 stopped persisting the failure set. Clear the old key so a
        // phone that ran 128 or 129 is not still carrying its verdicts.
        UserDefaults.standard.removeObject(forKey: "weather.unavailable")
        load()
    }

    func weather(for a: Activity) -> ActivityWeather? { byActivity[a.id] }

    /// Everything that has to be true before the network is worth touching.
    ///
    /// The order matters for cost, not correctness: the free checks come first
    /// so an indoor session or a pre-patch-128 cached row never reaches the
    /// service at all.
    func canFetch(_ a: Activity) -> Bool {
        // Patch 178, plan step 0.3 — first, because it is the only test here
        // that is about permission rather than about whether a lookup would be
        // useful. What crosses the wire is the athlete's start coordinate to
        // four decimal places, about eleven metres, plus the timestamp: enough
        // to say where somebody was and when. There is no consent screen for
        // that yet, and the coordinate itself is Strava-sourced. Both are
        // Phase 2's job; until then the switch is the answer.
        //
        // Gating `canFetch` covers both providers and the bulk backfill at
        // once, because every path runs through it.
        guard ReleaseGates.isOpen(.coordinateWeather) else { return false }
        guard a.isOutdoor else { return false }
        guard a.startDateUTC != nil else { return false }
        guard byActivity[a.id] == nil else { return false }
        guard !unavailable.contains(a.id) else { return false }
        return !inFlight.contains(a.id)
    }

    func fetchIfNeeded(_ a: Activity) async {
        guard canFetch(a),
              let start = a.startDateUTC,
              let lat = a.startLat, let lon = a.startLon else { return }

        inFlight.insert(a.id)
        defer { inFlight.remove(a.id) }

        // The window the session actually occupied, widened by a few minutes at
        // each end so a run that starts at 07:58 still picks up the 07:00 hour
        // it mostly ran in.
        let end = start.addingTimeInterval(Double(max(a.elapsedTime, 600)))
        let from = start.addingTimeInterval(-1800)
        let to = end.addingTimeInterval(1800)

        // Apple first, unless it has already proved unavailable this session.
        if !appleDisabled,
           let samples = try? await AppleWeather.hourly(lat: lat, lon: lon,
                                                        from: from, to: to),
           let w = Self.reduce(samples, id: a.id, start: start, end: end,
                               source: .appleWeather) {
            appleSucceeded = true
            appleFailures = 0
            store(w)
            return
        }
        if !appleSucceeded { appleFailures += 1 }

        if let samples = try? await OpenMeteo.hourly(lat: lat, lon: lon,
                                                     from: from, to: to),
           let w = Self.reduce(samples, id: a.id, start: start, end: end,
                               source: .openMeteo) {
            store(w)
            return
        }

        // Both refused. No error surfaced: a missing entitlement, a service
        // outage, and a coordinate in the middle of the ocean all land here, and
        // none is something the reader of a run from last March can act on. The
        // row is absent instead: a measurement the app cannot make is better
        // said by silence than by an apology in a box of dashes.
        markUnavailable(a.id)
    }

    private func store(_ w: ActivityWeather) {
        byActivity[w.activityId] = w
        lastSource = w.source
        save()
    }

    /// The averaging, in one place for both providers.
    ///
    /// `nonisolated static` because it touches nothing on the store and is
    /// called from an async context; keeping it free of `self` is what lets the
    /// two provider paths above stay two lines each.
    nonisolated static func reduce(_ samples: [HourSample], id: String,
                                   start: Date, end: Date,
                                   source: WeatherSource) -> ActivityWeather? {
        // Only the samples that overlap the session — patch 193, and this is a
        // CORRECTION, not a tidy-up.
        //
        // The old filter kept samples whose timestamp fell after `start - 30min`.
        // That is not an overlap test, it is a proximity test, and it dropped the
        // hour a session actually began in whenever the session started more
        // than half an hour past the hour. A run at 07:55 lost the 07:00 hour
        // entirely — five minutes of real running, reported as if it happened in
        // the 08:00 hour.
        //
        // The right test is whether the hour's own span intersects the session
        // at all: an hour counts if it has not ended before the session started
        // and did not begin after it finished. What varies then is the WEIGHT,
        // which is exactly what the block below computes.
        let inSession = samples.filter { h in
            h.date <= end && h.date.addingTimeInterval(3600) > start
        }
        let used = inSession.isEmpty ? Array(samples.prefix(1)) : inSession
        guard !used.isEmpty else { return nil }

        // WEIGHTED BY OVERLAP — patch 193, plan step 2.4.
        //
        // Every figure below used to be a flat mean over the hours the session
        // touched, which is wrong whenever a session straddles an hour unevenly.
        // A run from 07:55 to 08:50 touches two hours: five minutes of the first
        // and fifty of the second. A flat mean gives them equal say, so 12° at
        // 07:00 and 18° at 08:00 reported 15° for a session run almost entirely
        // at 18°. The error is largest exactly where it is most noticeable — a
        // dawn run in spring, when the temperature is climbing fastest.
        //
        // The weight is the seconds of the session that fell inside each hour.
        let weights = used.map { h -> Double in
            let hourStart = h.date
            let hourEnd = h.date.addingTimeInterval(3600)
            let from = max(hourStart, start)
            let to = min(hourEnd, end)
            return max(0, to.timeIntervalSince(from))
        }
        // A zero-length activity, or samples that turn out not to overlap at
        // all, would divide by zero. Falling back to equal weights keeps the old
        // behaviour for that case rather than returning nil — a rough figure is
        // better than no row, and `samples` records how many hours it came from.
        let total = weights.reduce(0, +)
        let w: [Double] = total > 0 ? weights : Array(repeating: 1, count: used.count)
        let n = total > 0 ? total : Double(used.count)

        func mean(_ value: (HourSample) -> Double) -> Double {
            zip(used, w).reduce(0.0) { $0 + value($1.0) * $1.1 } / n
        }

        let temp = mean(\.tempC)
        let feels = mean(\.feelsLikeC)
        let hum = mean(\.humidity)
        let wind = mean(\.windKmh)

        // RAIN IS A TOTAL, NOT A MEAN, and that is why it needs the weighting
        // more than anything else here. The provider reports millimetres per
        // hour; summing whole hours credited a session with all 4 mm of an hour
        // it was only outdoors for five minutes of. Scaling each hour by the
        // FRACTION of it the session occupied gives the rain that actually fell
        // on the athlete.
        let rain = zip(used, w).reduce(0.0) { $0 + $1.0.precipitationMm * ($1.1 / 3600) }

        // Wind direction is averaged as a VECTOR, not as a number. The
        // arithmetic mean of 350° and 10° is 180° — a southerly, when both
        // readings say northerly. Summing unit vectors and taking the angle back
        // out is the only average that survives the wrap at zero. Weighted too:
        // the hour the athlete was actually in should dominate the arrow.
        var vx = 0.0, vy = 0.0
        for (h, weight) in zip(used, w) {
            let r = h.windFromDegrees * .pi / 180
            vx += cos(r) * weight; vy += sin(r) * weight
        }
        var dir = atan2(vy, vx) * 180 / .pi
        if dir < 0 { dir += 360 }

        // The dominant condition is a single sample's, not the mean of an
        // enumeration — averaging "Cloudy" and "Rain" has no meaning. It is now
        // the HEAVIEST hour rather than the middle one: for that 07:55 run the
        // middle sample was the five-minute hour, so the card could report the
        // conditions of a period the athlete barely experienced.
        let mid = zip(used, w).max { $0.1 < $1.1 }?.0 ?? used[used.count / 2]

        return ActivityWeather(activityId: id,
                               tempC: temp,
                               feelsLikeC: feels,
                               humidity: hum,
                               windKmh: wind,
                               windFromDegrees: dir,
                               precipitationMm: rain,
                               symbolName: mid.symbolName,
                               conditionLabel: mid.conditionLabel,
                               samples: used.count,
                               fetched: Date(),
                               source: source)
    }

    private func markUnavailable(_ id: String) {
        unavailable.insert(id)
    }

    /// Clears this session's failures AND re-arms the Apple circuit breaker —
    /// the button to press immediately after the capability goes live, so the
    /// next fetch tries Apple again without waiting for a relaunch.
    func retryAll() {
        unavailable = []
        appleFailures = 0
    }

    /// How many activities could carry weather but do not yet. The number the
    /// backfill button is offering to work through.
    func pending(_ all: [Activity]) -> Int {
        all.filter { $0.isOutdoor && $0.startDateUTC != nil && byActivity[$0.id] == nil }.count
    }

    /// Every eligible activity, oldest first, one at a time.
    ///
    /// Serial with a small gap rather than a task group. WeatherKit publishes a
    /// monthly quota — 500,000 calls, so 571 is nothing — and no documented
    /// per-second rate, and 571 simultaneous requests is the kind of thing that
    /// discovers an undocumented one. At roughly six a second this finishes a
    /// full history in under two minutes and cannot be mistaken for an attack.
    func backfill(_ all: [Activity]) async {
        // `fetchIfNeeded` is gated and would refuse each one individually, so
        // this is not the enforcement — it is not spending ninety seconds
        // sleeping between 571 refusals and reporting a progress bar for it.
        guard ReleaseGates.isOpen(.coordinateWeather) else { return }
        guard !backfillRunning else { return }
        let queue = all
            .filter { $0.isOutdoor && $0.startDateUTC != nil && byActivity[$0.id] == nil }
            .sorted { $0.startLocal < $1.startLocal }
        backfillTotal = queue.count
        backfillDone = 0
        guard !queue.isEmpty else { return }

        backfillRunning = true
        defer { backfillRunning = false; save() }

        for a in queue {
            if Task.isCancelled { return }
            await fetchIfNeeded(a)
            backfillDone += 1
            try? await Task.sleep(for: .milliseconds(160))
        }
    }

    var storedCount: Int { byActivity.count }
    var failedCount: Int { unavailable.count }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL) else { return }
        byActivity = (try? JSONDecoder().decode([String: ActivityWeather].self,
                                                from: d)) ?? [:]
    }


    /// Drops everything held in memory WITHOUT writing to disk.
    ///
    /// The counterpart to `DataLifecycleCoordinator.deleteEverything`, and the
    /// reason it is not simply `resetCache`: reset saves an empty file, which
    /// after a delete recreates the very store that was just removed. Worse,
    /// leaving the in-memory copy alive means the next save resurrects the
    /// whole history from RAM — a delete that undoes itself the first time the
    /// app touches the store. Nothing here writes.
    func dropInMemory() {
        byActivity = [:]
        unavailable = []
        inFlight = []
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(byActivity) else { return }
        try? d.write(to: fileURL, options: FileProtection.options)
    }

    func resetCache() {
        byActivity = [:]
        unavailable = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Attribution
//
// WHICHEVER PROVIDER ACTUALLY ANSWERED.
// Apple requires its mark and a link to its legal page anywhere WeatherKit data
// is displayed; the mark is served from a URL handed out at runtime and comes in
// a light and a dark variant, which is why this reads the colour scheme. Open-
// Meteo is CC-BY 4.0 and asks for credit.
//
// Two sources in one card with no way to tell them apart would be worse than
// one source, so this takes the reading's own provenance rather than a global
// setting: scroll from a run fetched last week to one fetched today and the
// credit follows the data.

struct WeatherAttributionView: View {

    let source: WeatherSource

    @Environment(\.colorScheme) private var scheme
    @State private var apple: WeatherAttribution?

    var body: some View {
        Group {
            switch source {
            case .appleWeather:
                if let a = apple {
                    Link(destination: a.legalPageURL) {
                        AsyncImage(url: scheme == .dark ? a.combinedMarkDarkURL
                                                        : a.combinedMarkLightURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            credit("Apple Weather")
                        }
                        .frame(height: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Not a shortcut taken to avoid the image: this is what shows
                    // while the URL loads, and if the attribution request itself
                    // fails — a state in which dropping the credit entirely is
                    // the one outcome that is not allowed.
                    credit("Apple Weather")
                }
            case .openMeteo:
                Link(destination: URL(string: "https://open-meteo.com/")!) {
                    credit("Open-Meteo · ERA5")
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: source) {
            guard source == .appleWeather else { return }
            apple = try? await WeatherService.shared.attribution
        }
    }

    private func credit(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(Color.dim)
    }
}

// MARK: - The card

// The CONDITIONS card was deleted in patch 146.
//
// Its content is now the second metric row and the footer of the activity
// detail's single card — see `weatherRow` in ActivityDetailView. Nothing was
// lost: the same figures, the same provenance line, the same attribution,
// with two card headers and four sets of padding removed.
//
// The rule it established survives it and is worth keeping stated: a card that
// has no measurement renders NOTHING rather than a box of dashes, because a
// dash is a claim that a number should be there.



// MARK: - One hour, from either provider

/// The shape both providers are flattened into before averaging.
///
/// It carries the SF Symbol and the words rather than a raw code, because that
/// is the last point where the two sources still differ: Apple hands over a
/// symbol and a description, Open-Meteo hands over a WMO integer. Normalising
/// here means `WeatherStore.reduce` never has to know which one it is looking
/// at.
struct HourSample {
    let date: Date
    let tempC: Double
    let feelsLikeC: Double
    /// 0…1.
    let humidity: Double
    let windKmh: Double
    let windFromDegrees: Double
    let precipitationMm: Double
    let symbolName: String
    let conditionLabel: String
}

// MARK: - Apple Weather

enum AppleWeather {
    static func hourly(lat: Double, lon: Double,
                       from: Date, to: Date) async throws -> [HourSample] {
        let forecast = try await WeatherService.shared.weather(
            for: CLLocation(latitude: lat, longitude: lon),
            including: .hourly(startDate: from, endDate: to))
        return forecast.map { h in
            HourSample(date: h.date,
                       tempC: h.temperature.converted(to: .celsius).value,
                       feelsLikeC: h.apparentTemperature.converted(to: .celsius).value,
                       humidity: h.humidity,
                       windKmh: h.wind.speed.converted(to: .kilometersPerHour).value,
                       windFromDegrees: h.wind.direction.converted(to: .degrees).value,
                       precipitationMm: h.precipitationAmount.converted(to: .millimeters).value,
                       symbolName: h.symbolName,
                       conditionLabel: h.condition.description)
        }
    }
}

// MARK: - Open-Meteo

enum OpenMeteo {

    struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let apparent_temperature: [Double?]
            let relative_humidity_2m: [Double?]
            let precipitation: [Double?]
            let wind_speed_10m: [Double?]
            let wind_direction_10m: [Double?]
            let weather_code: [Int?]
        }
        let hourly: Hourly?
    }

    /// Beyond this age the archive has the data; inside it, the archive does not
    /// yet and the forecast endpoint's `past_days` does.
    ///
    /// Seven rather than five. ERA5's stated lag is about five days, and a
    /// constant set exactly at a stated lag fails whenever the publisher is a
    /// day late. Getting this wrong means the feature failing on precisely the
    /// run you tested it with — this morning's.
    private static let archiveLagDays = 7.0

    /// The most recent past the forecast endpoint serves.
    private static let maxPastDays = 92

    static func hourly(lat: Double, lon: Double,
                       from: Date, to: Date) async throws -> [HourSample] {
        let recent = Date().timeIntervalSince(from) / 86_400 < archiveLagDays
        if let s = try? await request(recent: recent, lat: lat, lon: lon,
                                      from: from, to: to), !s.isEmpty {
            return s
        }
        // One retry against the other endpoint. The boundary between them is a
        // publishing schedule, not a law, and a session landing on the seam
        // should not be the one activity in the history with no weather.
        return try await request(recent: !recent, lat: lat, lon: lon,
                                 from: from, to: to)
    }

    private static func request(recent: Bool, lat: Double, lon: Double,
                                from: Date, to: Date) async throws -> [HourSample] {
        var c = URLComponents(string: recent
                              ? "https://api.open-meteo.com/v1/forecast"
                              : "https://archive-api.open-meteo.com/v1/archive")!

        var items: [URLQueryItem] = [
            .init(name: "latitude", value: String(format: "%.4f", lat)),
            .init(name: "longitude", value: String(format: "%.4f", lon)),
            .init(name: "hourly", value: "temperature_2m,apparent_temperature,"
                  + "relative_humidity_2m,precipitation,wind_speed_10m,"
                  + "wind_direction_10m,weather_code"),
            // UTC throughout. The whole reason `startUTC` was added to Activity
            // is that a local wall-clock string cannot address an instant;
            // asking for local time would put the ambiguity straight back.
            .init(name: "timezone", value: "UTC"),
            .init(name: "wind_speed_unit", value: "kmh")
        ]

        if recent {
            let days = Int(ceil(Date().timeIntervalSince(from) / 86_400)) + 1
            items.append(.init(name: "past_days",
                               value: String(min(max(days, 1), maxPastDays))))
            items.append(.init(name: "forecast_days", value: "1"))
        } else {
            items.append(.init(name: "start_date", value: day(from)))
            items.append(.init(name: "end_date", value: day(to)))
        }
        c.queryItems = items

        let (data, response) = try await URLSession.shared.data(from: c.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let h = decoded.hourly else { return [] }

        var out: [HourSample] = []
        for (i, t) in h.time.enumerated() {
            guard let date = stamp(t),
                  date >= from.addingTimeInterval(-3600),
                  date <= to.addingTimeInterval(3600) else { continue }
            // A row with no temperature is a gap in the reanalysis, not a cold
            // day. Skipped rather than defaulted — a zero here would average
            // straight into the figure on the card.
            guard let temp = value(h.temperature_2m, i) else { continue }
            let code = (i < h.weather_code.count ? h.weather_code[i] : nil) ?? 0
            out.append(HourSample(
                date: date,
                tempC: temp,
                feelsLikeC: value(h.apparent_temperature, i) ?? temp,
                humidity: (value(h.relative_humidity_2m, i) ?? 0) / 100,
                windKmh: value(h.wind_speed_10m, i) ?? 0,
                windFromDegrees: value(h.wind_direction_10m, i) ?? 0,
                precipitationMm: value(h.precipitation, i) ?? 0,
                symbolName: WMO.symbol(code),
                conditionLabel: WMO.label(code)))
        }
        return out
    }

    private static func value(_ column: [Double?], _ i: Int) -> Double? {
        i < column.count ? column[i] : nil
    }

    private static func day(_ d: Date) -> String { dayFormatter.string(from: d) }
    private static func stamp(_ s: String) -> Date? { stampFormatter.date(from: s) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-08-01T09:00" — no zone suffix, because the request asked for UTC.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
}

// MARK: - WMO 4677

/// The present-weather code, as words and as a glyph.
///
/// Apple hands over both; Open-Meteo hands over an integer from the WMO table,
/// so the mapping lives here. Grouped rather than exhaustive: the table
/// distinguishes slight, moderate and dense drizzle, and nobody reading a run
/// from March needs three words for drizzle.
enum WMO {

    static func label(_ code: Int) -> String {
        switch code {
        case 0:          "Clear"
        case 1:          "Mainly clear"
        case 2:          "Partly cloudy"
        case 3:          "Overcast"
        case 45, 48:     "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57:     "Freezing drizzle"
        case 61, 63:     "Rain"
        case 65:         "Heavy rain"
        case 66, 67:     "Freezing rain"
        case 71, 73, 75: "Snow"
        case 77:         "Snow grains"
        case 80, 81:     "Rain showers"
        case 82:         "Heavy showers"
        case 85, 86:     "Snow showers"
        case 95:         "Thunderstorm"
        case 96, 99:     "Thunderstorm with hail"
        default:         "—"
        }
    }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0:          "sun.max"
        case 1:          "sun.min"
        case 2:          "cloud.sun"
        case 3:          "cloud"
        case 45, 48:     "cloud.fog"
        case 51, 53, 55: "cloud.drizzle"
        case 56, 57:     "cloud.sleet"
        case 61, 63:     "cloud.rain"
        case 65:         "cloud.heavyrain"
        case 66, 67:     "cloud.sleet"
        case 71, 73, 75: "cloud.snow"
        case 77:         "snowflake"
        case 80, 81:     "cloud.sun.rain"
        case 82:         "cloud.heavyrain"
        case 85, 86:     "cloud.snow"
        case 95:         "cloud.bolt.rain"
        case 96, 99:     "cloud.bolt.rain.fill"
        default:         "cloud"
        }
    }
}
