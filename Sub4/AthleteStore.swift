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
    /// Only kept when Strava reports it as measured rather than estimated: an
    /// estimated FTP is derived from ride data, so scoring rides against it
    /// would be scoring them against themselves. Nil until zones are fetched.
    private(set) var ftp: Int?
    private(set) var shoes: [Shoe] = []
    private(set) var lastFetch: Date?
    private(set) var lastError: String?

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
        guard ReleaseGates.isOpen(.stravaSync) else { return }
        guard let token = await StravaAuth.shared.validAccessToken() else { return }

        async let zones: [HRZone] = fetchZones(token: token)
        async let gear: [Shoe] = fetchGear(token: token)
        let (z, g) = await (zones, gear)

        // Keep whatever we already had if a call came back empty — better a
        // slightly stale zone than none at all.
        if !z.isEmpty { hrZones = z }
        if !g.isEmpty { shoes = g }

        if z.isEmpty && g.isEmpty {
            lastError = "No zone or gear data returned. If you connected before "
                      + "the profile scope was added, disconnect and reconnect."
        } else {
            lastError = nil
            lastFetch = Date()
            save()
        }
    }

    private func fetchZones(token: String) async -> [HRZone] {
        struct Response: Decodable {
            struct HR: Decodable {
                struct Z: Decodable { let min: Int; let max: Int }
                let zones: [Z]
            }
            let heart_rate: HR?
            let ftp: Int?
            let ftp_is_estimated: Bool?
        }
        guard let data = await get("https://www.strava.com/api/v3/athlete/zones",
                                  token: token),
              let r = try? JSONDecoder().decode(Response.self, from: data),
              let hr = r.heart_rate
        else { return [] }

        // Piggy-backed on the same response rather than a second request.
        if let f = r.ftp, f > 50, r.ftp_is_estimated != true {
            ftp = f
        }

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

    private func fetchGear(token: String) async -> [Shoe] {
        struct Athlete: Decodable {
            struct Gear: Decodable {
                let id: String
                let name: String?
                let distance: Double?
                let primary: Bool?
            }
            let shoes: [Gear]?
        }
        guard let data = await get("https://www.strava.com/api/v3/athlete", token: token),
              let a = try? JSONDecoder().decode(Athlete.self, from: data),
              let shoes = a.shoes
        else { return [] }

        return shoes.map {
            Shoe(id: $0.id,
                 name: $0.name ?? "Shoe",
                 distanceM: $0.distance ?? 0,
                 primary: $0.primary ?? false)
        }
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

    private struct Cache: Codable {
        var zones: [HRZone]
        var shoes: [Shoe]
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
        lastFetch = nil
        lastError = nil
    }

    private func save() {
        let c = Cache(zones: hrZones, shoes: shoes, fetched: lastFetch, ftp: ftp)
        try? JSONEncoder().encode(c).write(to: fileURL, options: FileProtection.options)
    }
}
