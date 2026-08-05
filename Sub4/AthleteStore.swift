//
//  AthleteStore.swift
//  Sub4
//
//  Account-level Strava data that changes rarely: heart-rate zones and gear.
//  Both need the `profile:read_all` scope, so both arrive together after one
//  reconnect. Cached to disk — a zone boundary changes maybe once a year.
//

import Foundation
import Observation

@Observable
final class AthleteStore {

    static let shared = AthleteStore()

    private(set) var hrZones: [HRZone] = []

    /// Functional threshold power, watts, as configured in Strava.
    ///
    /// Read from the DetailedAthlete — `/athlete` — which is where Strava
    /// keeps it. Until patch 235 this said it was "only kept when Strava
    /// reports it as measured rather than estimated", which described a check
    /// against a field that was not in the response being decoded. The check
    /// is gone rather than reworded: `/athlete` carries no such flag, and a
    /// comment claiming a distinction the data does not make is worse than no
    /// comment.
    ///
    /// Nil until the athlete is fetched, or if no FTP is set on the profile.
    private(set) var ftp: Int?
    private(set) var shoes: [Shoe] = []

    /// The athlete's bikes — patch 267.
    ///
    /// A SEPARATE ARRAY RATHER THAN A `kind` ON `Shoe`, and the reason is
    /// `Shoe.wear`: 600 km is "start thinking about it" for a running shoe and
    /// nothing at all for a bike. A shared type with a flag would put a
    /// meaningless threshold one `if` away from every caller. Two arrays make
    /// the wrong question unaskable.
    private(set) var bikes: [Shoe] = []

    /// Everything the athlete owns, for callers that only need a name for an
    /// id — the importer, the verifier, and `gear(id:)` below.
    var allGear: [Shoe] { shoes + bikes }
    private(set) var lastFetch: Date?
    private(set) var lastError: String?

    /// When the button was last PRESSED, as opposed to when data last arrived
    /// — patch 233.
    ///
    /// Session-scoped and deliberately separate from `lastFetch`. A refusal
    /// leaves `lastFetch` untouched, which is right — nothing arrived — but it
    /// also means a failed tap changes nothing on screen and reads as a dead
    /// button. This is the row that proves the tap registered.
    private(set) var lastAttempt: Date?

    /// What the last refresh actually did — patch 232.
    ///
    /// A refresh that fetches nothing and says nothing is indistinguishable
    /// from a button that is not wired up, which is exactly how this one read
    /// on the phone: tapped, no spinner, no error, no number moving. Set on
    /// every path including the ones that return early.
    private(set) var lastOutcome: String?

    private let fileURL: URL

    // MARK: Types

    struct HRZone: Codable, Hashable, Identifiable {
        let index: Int          // 1…5
        let min: Int
        let max: Int?           // nil = open-ended top zone

        var id: Int { index }
        var label: String { "Z\(index)" }

        var range: String {
            guard let max else { return "\(min)+" }
            // The bottom zone starts at zero, and "0–115 bpm" is a range whose
            // lower bound describes being dead. Every other zone states both
            // ends because both ends carry information.
            if index == 1 { return "≤\(max)" }
            return "\(min)–\(max)"
        }

        /// "Z2 Endurance" — the number and the word together, which is the form
        /// every surface now uses. The number alone is a coordinate you have to
        /// have memorised; the word alone loses the ordering.
        var titled: String { "\(label) \(name)" }

        func contains(_ bpm: Int) -> Bool {
            guard bpm >= min else { return false }
            guard let max else { return true }
            return bpm <= max
        }
    }

    struct Shoe: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        let distanceM: Double
        let primary: Bool

        var km: Double { distanceM / 1000 }

        /// Running shoes are usually retired somewhere in 600–800 km. The range
        /// is wide because it depends on the shoe, the surface and the runner —
        /// not because the figure is vague.
        ///
        /// BOTH ENDS ARE MARKED, not just the first. Amber at 600 says "start
        /// thinking about it"; red at 800 says "you are past the range the
        /// literature gives". One threshold made a 610 km shoe and an 850 km
        /// shoe look identical, and those are different decisions.
        static let attentionKm = 600.0
        static let spentKm = 800.0

        /// Full bar exactly at `spentKm`, with headroom above so a shoe that has
        /// run on does not silently pin at 100% and stop moving.
        var wearFraction: Double { min(km / Self.spentKm, 1.2) }

        var needsAttention: Bool { km >= Self.attentionKm }
        var isSpent: Bool { km >= Self.spentKm }

        /// One place decides which of the three states a shoe is in, so the
        /// tint, the word and the figure cannot drift apart. Equatable so the
        /// self-test below can compare states directly.
        enum Wear: Equatable { case fine, worn, spent }
        var wear: Wear { isSpent ? .spent : (needsAttention ? .worn : .fine) }

        // MARK: Self-test
        //
        // WHY THIS EXISTS AT ALL
        // ----------------------
        // Two of the three states cannot be seen on this athlete's data: the
        // highest pair is at 534 km, so amber is 66 km away and red is 266. The
        // first time either branch runs for real would also be the first time it
        // has ever run — which is exactly the situation this project keeps
        // deciding not to accept. Checked in the app rather than in a test target
        // this project does not have, the same as `LoadEngine.selfTest`.
        //
        // Boundaries are tested on BOTH sides, because ">=" and ">" are one
        // character apart and a shoe at exactly 600 is the case nobody tries.
        static func selfTest() -> [LoadEngine.Check] {
            func at(_ km: Double) -> Wear {
                Shoe(id: "t", name: "t", distanceM: km * 1000, primary: false).wear
            }
            func word(_ w: Wear) -> String {
                switch w {
                case .fine:  "fine"
                case .worn:  "worn"
                case .spent: "spent"
                }
            }
            func check(_ name: String, _ km: Double, _ expected: Wear)
            -> LoadEngine.Check {
                let got = at(km)
                return LoadEngine.Check(name: name,
                                        expected: word(expected),
                                        got: word(got),
                                        pass: got == expected)
            }
            return [
                check("Shoe 0 km", 0, .fine),
                check("Shoe 599 km", 599, .fine),
                check("Shoe 600 km", 600, .worn),
                check("Shoe 799 km", 799, .worn),
                check("Shoe 800 km", 800, .spent),
                check("Shoe 1200 km", 1200, .spent),
            ]
        }
    }

    // MARK: Init

    private init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("athlete.json")
        load()
    }

    // MARK: Zones

    /// Zone for a heart rate, or nil if zones haven't been fetched.
    func zone(forHR bpm: Double) -> HRZone? {
        guard !hrZones.isEmpty else { return nil }
        let v = Int(bpm.rounded())
        return hrZones.first { $0.contains(v) } ?? hrZones.last
    }

    var hasZones: Bool { !hrZones.isEmpty }

    /// Where the top zone starts. Used as a sanity check on the derived maximum
    /// heart rate — see `ConstantsStore.hrMaxContradictsZones`.
    var topZoneFloor: Int? { hrZones.max { $0.index < $1.index }?.min }

    // MARK: Gear

    func shoe(id: String?) -> Shoe? {
        guard let id else { return nil }
        return shoes.first { $0.id == id }
    }

    /// Any gear by id, shoe or bike — patch 267. `shoe(id:)` above is
    /// deliberately left alone: its callers want a shoe and would be wrong to
    /// be handed a bike.
    func gear(id: String?) -> Shoe? {
        guard let id else { return nil }
        return allGear.first { $0.id == id }
    }

    var activeShoes: [Shoe] {
        shoes.sorted { $0.km > $1.km }
    }

    // MARK: Fetch

    /// Refreshes at most once a day — this data barely moves.
    ///
    /// Except when the FTP is missing. It was added to this fetch in patch 28,
    /// so an upgraded install has a recent `lastFetch` and no FTP, and power
    /// scoring would stay dark for a day for no reason.
    @MainActor
    func refreshIfStale(maxAge: TimeInterval = 24 * 3600) async {
        if ftp == nil { await refresh(); return }
        if let last = lastFetch, Date().timeIntervalSince(last) < maxAge { return }
        await refresh()
    }

    @MainActor
    func refresh() async {
        // Patch 178, plan step 0.3. Both fetches are reads of Strava athlete
        // data — zones, FTP and gear — so they belong to the same switch as the
        // activity reads. Guarded here rather than in each fetch because these
        // two are the only callers and they always run as a pair.
        //
        // Note what this does NOT do: it does not clear `hrZones`, `ftp` or
        // `shoes`. The gate stops new reads; the values already held stay
        // readable, which is the "frozen, not extended" position ADR-0002 took.
        // FIRST, before every guard — patch 233. A tap that is refused still
        // happened, and the timestamp is the only thing that says so.
        lastAttempt = Date()

        // PATCH 232. Both guards used to return in silence. On the phone that
        // read as a dead button: tapped, nothing happened, nothing said why —
        // and the gate lives in UserDefaults, which a reinstall clears, so the
        // most likely reason was also the most invisible one.
        guard ReleaseGates.isOpen(.stravaSync) else {
            lastError = "\"Read activities from Strava\" is switched off under "
                      + "Data & privacy, so nothing was requested."
            lastOutcome = nil
            return
        }
        guard let token = await StravaAuth.shared.validAccessToken() else {
            lastError = "Not signed in to Strava. Reconnect under Settings → Strava."
            lastOutcome = nil
            return
        }

        async let zones: [HRZone] = fetchZones(token: token)
        async let gear: (shoes: [Shoe], bikes: [Shoe]) = fetchAthlete(token: token)
        let (z, g) = await (zones, gear)

        // Keep whatever we already had if a call came back empty — better a
        // slightly stale zone than none at all. Shoes and bikes are held to
        // that rule separately, for the reason the comment below gives about
        // zones: one list arriving empty must not clear the other.
        if !z.isEmpty { hrZones = z }
        if !g.shoes.isEmpty { shoes = g.shoes }
        if !g.bikes.isEmpty { bikes = g.bikes }

        // THE DEFECT THIS REPLACES. The old condition was `z.isEmpty &&
        // g.isEmpty`, so a refresh that returned six shoes and no zones cleared
        // the error, stamped `lastFetch` and reported success — the half that
        // worked concealed the half that did not. Strava holds five zones for
        // this account; the app held none and said nothing was wrong.
        // GEAR IS SHOES PLUS BIKES for the purposes of "did anything come
        // back" — patch 267a. Reporting only the shoes would put a cyclist's
        // successful refresh in the error line, which is the same shape as the
        // defect described above: one half concealing the other.
        let gearCount = g.shoes.count + g.bikes.count
        let problems = Self.refreshProblems(zones: z.count, gear: gearCount)
        lastError = problems.isEmpty ? nil : problems.joined(separator: " ")
        lastOutcome = "\(z.count) zones, \(gearCount) gear"

        if !z.isEmpty || gearCount > 0 {
            lastFetch = Date()
            save()
        }
    }

    /// One message per thing that came back empty, so a partial failure reads
    /// as a partial failure. Pure and static because `refresh` cannot be run in
    /// a test — it needs a token and a network — and this is the part that was
    /// wrong.
    nonisolated static func refreshProblems(zones: Int, gear: Int) -> [String] {
        var out: [String] = []
        if zones == 0 {
            out.append("Strava returned no heart-rate zones. If you connected "
                       + "before the profile scope was added, disconnect and "
                       + "reconnect.")
        }
        if gear == 0 {
            out.append("Strava returned no gear.")
        }
        return out
    }

    private func fetchZones(token: String) async -> [HRZone] {
        struct Response: Decodable {
            struct HR: Decodable {
                struct Z: Decodable { let min: Int; let max: Int }
                let zones: [Z]
            }
            let heart_rate: HR?
        }
        guard let data = await get("https://www.strava.com/api/v3/athlete/zones",
                                  token: token),
              let r = try? JSONDecoder().decode(Response.self, from: data),
              let hr = r.heart_rate
        else { return [] }

        // THE FTP READ USED TO BE HERE, AND IT COULD NEVER HAVE WORKED —
        // patch 235. `/athlete/zones` returns `{ heart_rate, power }` and
        // nothing else; there is no `ftp` field on it to piggy-back on, so
        // `r.ftp` was nil on every response Strava has ever sent. The decode
        // succeeded, the zones arrived, and the FTP silently did not.
        //
        // The cost was not a blank row. `PowerLoad.diagnose` printed "No FTP
        // on the Strava profile" and told the athlete to go and set one — for
        // a profile that has had 270 W set on it, not estimated, the whole
        // time. An app inventing a fact about the outside world and then
        // issuing instructions based on it.
        //
        // FTP lives on the DetailedAthlete, which `fetchAthlete` below already
        // requests for gear. It is read there now, from a response that
        // actually contains it.

        let raw = hr.zones.enumerated().map { i, z in
            // Strava sends -1 for the open-ended top zone.
            HRZone(index: i + 1, min: z.min, max: z.max < 0 ? nil : z.max)
        }
        return Self.separate(raw)
    }

    /// Lift each zone's floor clear of the one below it.
    ///
    /// Strava returns zones whose bounds TOUCH: zone 2's minimum is the same
    /// number as zone 1's maximum. Left alone that has two visible
    /// consequences. The footer on Progress printed
    /// "Z2 115–139 · Z3 139–149" — two zones claiming 139. And `contains`
    /// is inclusive at both ends, so 139 bpm matches Z2 and Z3 both, with
    /// `zone(forHR:)` silently resolving it by whichever comes first.
    ///
    /// Applied on the way in, so the cache and every reader see the same
    /// non-overlapping bounds. `max` is untouched — only the floor moves,
    /// so no heart rate changes zone except the boundary values, which were
    /// ambiguous anyway.
    static func separate(_ zones: [HRZone]) -> [HRZone] {
        var out: [HRZone] = []
        var previousMax: Int?
        for z in zones.sorted(by: { $0.index < $1.index }) {
            let floor: Int
            if let p = previousMax { floor = Swift.max(z.min, p + 1) } else { floor = z.min }
            out.append(HRZone(index: z.index, min: floor, max: z.max))
            previousMax = z.max
        }
        return out
    }

    /// Gear AND FTP — both live on the DetailedAthlete, and this was already
    /// asking for it. Renamed from `fetchGear` in patch 235 so the name stops
    /// under-describing what the response carries; a function called
    /// `fetchGear` is exactly why the FTP read ended up on the wrong endpoint.
    private func fetchAthlete(token: String) async -> (shoes: [Shoe], bikes: [Shoe]) {
        struct Athlete: Decodable {
            struct Gear: Decodable {
                let id: String
                let name: String?
                let distance: Double?
                let primary: Bool?
            }
            let shoes: [Gear]?
            /// PATCH 267, AND IT HAD ALWAYS BEEN IN THE RESPONSE. Strava's
            /// DetailedAthlete carries `bikes` beside `shoes`; this app
            /// decoded one of them for thirteen months, which is why 356
            /// activities named gear the profile did not hold.
            let bikes: [Gear]?
            let ftp: Int?
        }
        guard let data = await get("https://www.strava.com/api/v3/athlete", token: token),
              let a = try? JSONDecoder().decode(Athlete.self, from: data)
        else { return (shoes: [], bikes: []) }

        // Set even when the gear list is absent — they are two independent
        // facts in one response, and the old `guard let shoes` would have
        // thrown the FTP away along with an empty shoe rack.
        //
        // `> 50` is the only filter left. `ftp_is_estimated` was checked
        // against a field that was never in the response; on the
        // DetailedAthlete there is no such flag, and claiming to distinguish
        // measured from estimated here would be inventing the distinction
        // rather than reading it.
        if let f = a.ftp, f > 50 { ftp = f }

        // Two independent lists in one response, and each is allowed to be
        // absent on its own — the same reasoning as the FTP above. An athlete
        // with bikes and no shoes is a cyclist, not an error.
        func gear(_ list: [Athlete.Gear]?, fallbackName: String) -> [Shoe] {
            (list ?? []).map {
                Shoe(id: $0.id,
                     name: $0.name ?? fallbackName,
                     distanceM: $0.distance ?? 0,
                     primary: $0.primary ?? false)
            }
        }
        return (shoes: gear(a.shoes, fallbackName: "Shoe"),
                bikes: gear(a.bikes, fallbackName: "Bike"))
    }

    private func get(_ urlString: String, token: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    // MARK: Persistence

    /// INTERNAL SINCE PATCH 259, and it was never private for a reason.
    ///
    /// `LegacyFixtureTests` recorded in patch 246 that this being `private`
    /// meant `athlete.json` had no decodable type anywhere — not for the
    /// file-level decoders, not for the semantic verifier, not even for
    /// `@testable import`. Every other legacy input has a type you can hand a
    /// `Data`. This one had a store and nothing else.
    ///
    /// It stays main-actor isolated, because `AthleteStore` is, and the reader
    /// that decodes this file runs `nonisolated` inside a database write. That
    /// is what `AthleteFile` is for: a mirror with its own nonisolated shapes,
    /// held to this declaration field by field by
    /// `AthleteFileAgreementTests`. Making this internal is what lets that
    /// test exist at all — a mirror nothing can compare against is just a
    /// second guess.
    struct Cache: Codable {
        var zones: [HRZone]
        var shoes: [Shoe]
        /// OPTIONAL, AND THAT IS NOT TIDINESS — patch 267.
        ///
        /// A synthesised `init(from:)` does not use Swift default values, so a
        /// non-optional `bikes` would make every `athlete.json` written before
        /// today fail to decode ENTIRELY — taking the zones, the FTP and the
        /// shoe history with it. `LegacyFixtures` records that hazard against
        /// `constants.json`, which has three properties carrying exactly this
        /// trap.
        var bikes: [Shoe]?
        var fetched: Date?
        var ftp: Int?
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let c = try? JSONDecoder().decode(Cache.self, from: d) else { return }
        // Also on the way OUT of the cache, so a file written before patch 81
        // is corrected without waiting for the next Strava fetch.
        hrZones = Self.separate(c.zones)
        shoes = c.shoes
        // Absent in every file written before patch 267, which is the whole
        // reason the column is optional. Empty until the next refresh.
        bikes = c.bikes ?? []
        lastFetch = c.fetched
        ftp = c.ftp
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
        hrZones = []
        ftp = nil
        shoes = []
        bikes = []
        lastFetch = nil
        lastError = nil
    }

    private func save() {
        let c = Cache(zones: hrZones, shoes: shoes,
                      bikes: bikes.isEmpty ? nil : bikes,
                      fetched: lastFetch, ftp: ftp)
        // A bare `JSONEncoder`, as it has always been — `AthleteFile` decodes
        // this file with `.deferredToDate` on the strength of it, and changing
        // the encoder here would break thirteen months of files on disk.
        StoreWriteJournal.shared.attempt("athlete.json") {
            try StoreWrite.encode(c, to: fileURL, store: "athlete.json",
                                  encoder: JSONEncoder())
        }
    }
}
