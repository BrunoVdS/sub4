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

    /// Gear the athlete once had — patch 268.
    ///
    /// Strava's athlete response carries what you own NOW. A shoe you retired
    /// is gone from it, and so is every reference to the runs you did in it:
    /// `g15316986` named 51 activities here and was in neither list.
    ///
    /// `GET /gear/{id}` still returns it. This array is what that call fills,
    /// and it is a `Shoe` rather than a third kind because it IS one — a
    /// retired shoe's wear is the most meaningful wear there is, since it is
    /// the number that made it retired.
    ///
    /// NOT IN `activeShoes`, deliberately. It belongs in the history and not
    /// in the rack.
    private(set) var retired: [Shoe] = []

    /// Everything the athlete owns or once owned, for callers that only need a
    /// name for an id — the importer, the verifier, and `gear(id:)` below.
    var allGear: [Shoe] { shoes + bikes + retired }

    /// Stamps a kind on gear that has none, and leaves gear that has one alone.
    ///
    /// **IT MAY ONLY EVER FILL A GAP.** Overwriting a kind already set would
    /// make the array the authority over the item, and the two disagree in one
    /// real case: `retired` holds items whose kind is genuinely `.unknown` and
    /// may one day hold one resolved from a source that knew. Filling only
    /// `nil` is what makes this safe to run on every load.
    nonisolated static func kinded(_ list: [Shoe], _ kind: GearKind,
                                   retired: Bool) -> [Shoe] {
        list.map {
            var out = $0
            if out.kind == nil { out.kind = kind }
            if out.retired == nil { out.retired = retired }
            return out
        }
    }
    private(set) var lastFetch: Date?
    private(set) var lastError: String?

    /// Where this store's data came from — patch 344. See `PlanStore`'s.
    private(set) var servedFrom: StoreSource = .files

    /// **THE TWO HALVES OF `servedFrom`, AS VALUES** — patch 386, §12.130.
    ///
    /// `.partial(fromDatabase: "zones and FTP", fromFiles: "gear")` is a
    /// sentence for a person to read. A caller deciding whether a comparison
    /// can still disagree needs the halves separately, and taking them from
    /// the sentence would be parsing prose.
    ///
    /// DERIVED FROM `servedFrom` rather than written as constants — the
    /// opposite of `ActivityStore`'s two, and for the opposite reason: B5 makes
    /// this store whole, so both halves move together and one edit should carry
    /// them.
    var zonesServedFrom: StoreSource {
        switch servedFrom {
        case .database: .database
        case .partial:  .database
        case .files:    .files
        }
    }

    var gearServedFrom: StoreSource {
        switch servedFrom {
        case .database: .database
        case .partial:  .files
        case .files:    .files
        }
    }

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

    /// `nonisolated` — PATCH 317. Nested in an `@Observable final class`
    /// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so this type and its
    /// conformances inherit the main actor from the store around it — the same
    /// obstacle `AthleteFile` was written to work around at 259 for
    /// `AthleteStore.Cache`.
    ///
    /// `AthleteRepository` CONSTRUCTS these inside a database read, off the
    /// main actor. A mirror type was the other option and was rejected: `Cache`
    /// needed one because it is the shape of a FILE and the store is its only
    /// writer, while this is a plain value with three immutable Sendable
    /// fields that both sides of the read-back have to hold. Two declarations
    /// of it would be two things to keep in step for no gain — and §12.61's
    /// comparison exists precisely to catch things that have drifted apart.
    nonisolated struct HRZone: Codable, Hashable, Identifiable {
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
        ///
        /// `@MainActor` — PATCH 317a, and it is the SAME RULE as the note in
        /// `Sub4Import+Athlete`'s header, arriving from the other direction.
        /// `nonisolated` on this type reaches the members written in its own
        /// body; it does NOT reach `extension AthleteStore.HRZone` in
        /// `Theme.swift`, which takes the module default and is therefore
        /// main-actor isolated. `name` lives there. So marking the type
        /// nonisolated at 317 made this one line a nonisolated member reading
        /// a main-actor one.
        ///
        /// Marked rather than dragging `name` out to meet it. The line above
        /// this type says why the geometry — `index`, `min`, `max`, `label`,
        /// `range`, `contains` — has to be readable inside a database
        /// transaction. `name` and `color` are the editorial half: five words
        /// and five hues that exist for surfaces to draw, and nothing off the
        /// main actor has ever wanted either. The boundary is real, and this
        /// is where it falls.
        ///
        /// Fifth time this project has been caught by extensions not
        /// inheriting a type's isolation — 207, 219, 228, 317.
        @MainActor var titled: String { "\(label) \(name)" }

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

        /// **WHAT THIS GEAR IS — patch 425, D7 slice B5, §12.175.**
        ///
        /// The fact has always existed and has never been carried: this store
        /// keeps `shoes`, `bikes` and `retired` as three arrays, so the kind IS
        /// which array a `Shoe` sits in — and `allGear` flattens all three
        /// before anything downstream sees them. The importer is not
        /// discarding the kind; **it is never told.**
        ///
        /// **OPTIONAL, AND FOR THE `bikes` REASON.** A synthesised
        /// `init(from:)` does not use Swift default values, so a non-optional
        /// property here would make every `athlete.json` written before today
        /// fail to decode ENTIRELY — taking the zones, the FTP and the whole
        /// shoe history with it. That hazard is recorded against `bikes` and
        /// `retired` a few lines up and against `constants.json` in
        /// `LegacyFixtures`.
        ///
        /// **`nil` IS NOT `unknown`.** `nil` means a file written before this
        /// patch, whose kind is recoverable from which array it decodes into —
        /// and `loadFromCache` does exactly that. `unknown` means the kind was
        /// asked for and could not be had, which happens for real: `fetchGear`
        /// returns no type, so retired gear arrives untyped. §12.15.
        var kind: GearKind?

        /// **WHETHER THIS GEAR IS STILL HELD — patch 426, §12.176.**
        ///
        /// Flattened by the same line as `kind`: membership of `retired` is the
        /// fact, and `allGear` concatenates the three arrays before anything
        /// downstream can see which one an item came from. 425 carried the kind
        /// and left this behind.
        ///
        /// Optional for `kind`'s reason — a synthesised `init(from:)` ignores
        /// Swift defaults — and `nil` means the same thing: a file written
        /// before this patch, whose answer is recoverable from which key it
        /// decoded from.
        ///
        /// **IT IS STATED, NOT DERIVED.** `gear.retiredUTC` is computed from
        /// the activities naming this gear and can be unknown; this cannot.
        /// The two come apart, which is why the database has both.
        var retired: Bool?

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

        /// **THE THRESHOLDS ARE RUNNING-SHOE NUMBERS AND THIS IS WHERE THAT
        /// STOPS BEING IMPLICIT — patch 425.** 600 and 800 km describe a
        /// running shoe; on a bicycle they are meaningless, and on gear whose
        /// kind nobody knows they are a guess. `bikes` was made a separate
        /// array in patch 267 for exactly this reason, and the reason has never
        /// been readable from a `Shoe` itself.
        ///
        /// Callers that draw a wear bar ask THIS, not `wear`.
        ///
        /// **`?? .shoe` HERE IS A RENDERING DECISION AND NOT THE STORAGE ONE.**
        /// A pre-425 file has no kind, and every one of those items was drawn
        /// as a shoe yesterday; a patch that only carries a fact must not
        /// change what a screen does. `storedKind` answers the other question
        /// and answers it differently, on purpose — see below.
        nonisolated var wearIsMeaningful: Bool { (kind ?? .shoe) == .shoe }

        /// **WHAT THE DATABASE IS TOLD THIS IS, AND THE ONE PLACE THAT
        /// DECIDES — patch 427, §12.43.**
        ///
        /// `nil` means *not recorded*, and `unknown` is the database's word for
        /// exactly that. The importer and the round-trip comparison were each
        /// deciding it separately at 426/427 and **they disagreed**: the
        /// importer wrote `unknown` and the comparison expected `.shoe`, so a
        /// pre-425 file would have reported a difference on every item. Caught
        /// by the existing `WeatherGearRepositoryTests` fixtures, which is what
        /// they were for.
        ///
        /// Two defaults for one `nil` is defensible only because they answer
        /// two different questions. Both are named, and neither is inline.
        nonisolated var storedKind: GearKind { kind ?? .unknown }

        /// The storage answer for retirement. Both sides already agreed on
        /// `false`; this exists so they cannot stop agreeing.
        nonisolated var storedRetired: Bool { retired ?? false }

        /// Value-semantics helper for `kinded`. `id`, `name`, `distanceM` and
        /// `primary` are `let` and stay that way — only the kind was ever
        /// missing.
        /// `nonisolated` because `kinded` is, and SE-0434 covers a stored
        /// property's READ but not a method: `Shoe` is nested in a main-actor
        /// class, so every method it declares is main-actor by default. Sixth
        /// instance of that rule in this project — CLAUDE.md §2.
        nonisolated func withKind(_ k: GearKind) -> Shoe {
            var out = self
            out.kind = k
            return out
        }

        /// **WHAT A SCREEN SHOULD SAY ABOUT THIS ITEM.** Unconditional, and
        /// `unknown` says so rather than going quiet — §12.54.2.
        nonisolated var kindLabel: String {
            let base = (kind ?? .shoe).label
            return (retired ?? false) ? "\(base) · retired" : base
        }

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

    /// Internal since 344 — see `PlanStore.init` for why.
    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("athlete.json")
        load()
    }

    /// A store rooted somewhere else — patch 418.
    ///
    /// **THE GUARD ABOVE COULD NOT BE TESTED WITHOUT ONE.** A failable refusal
    /// cannot be trusted until something has watched it refuse, and the only
    /// honest way to make a read unclean is to put unreadable bytes where the
    /// store looks — which needs an instance that is not the singleton, because
    /// the singleton reads the athlete's own file.
    ///
    /// §5.5 asks for this seam for a second reason: `ReadBacks.athlete` is the
    /// last read-back comparing the database with itself, and it needs `AthleteStore(directory:)`
    /// to read the file directly. That is topic 3's, and this is the half of it
    /// that 418 needs anyway.
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("athlete.json")
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
        // AFTER the two lists are in place — patch 268 — because what counts
        // as missing is defined against them. Running it first would ask
        // Strava for every bike as well.
        await resolveRetiredGear(token: token)

        let gearCount = g.shoes.count + g.bikes.count
        let problems = Self.refreshProblems(zones: z.count, gear: gearCount)
        lastError = problems.isEmpty ? nil : problems.joined(separator: " ")
        // Retired gear is reported apart from the two lists, because it is not
        // evidence the athlete endpoint worked — it comes from a different
        // call — and folding it in would let a profile fetch that returned
        // nothing look like one that returned something.
        lastOutcome = retired.isEmpty
            ? "\(z.count) zones, \(gearCount) gear"
            : "\(z.count) zones, \(gearCount) gear, \(retired.count) retired"

        if !z.isEmpty || gearCount > 0 {
            lastFetch = Date()
            save()
        }
    }

    /// One message per thing that came back empty, so a partial failure reads
    /// as a partial failure. Pure and static because `refresh` cannot be run in
    /// a test — it needs a token and a network — and this is the part that was
    /// wrong.
    /// Gear named by an activity and held by neither list — patch 268.
    ///
    /// WHY THIS IS DRIVEN FROM THE ACTIVITIES rather than from a list Strava
    /// gives us: there is no such list. The athlete endpoint returns current
    /// gear only, so the only evidence a retired shoe ever existed is that 51
    /// activities name it. That is exactly the evidence
    /// `activity_gear_reference` was built to keep — §12.18 — and this is the
    /// first thing to read it back.
    ///
    /// CAPPED, and the cap is not politeness. An id that 404s stays missing
    /// and would be asked for again on every refresh; ten per run bounds that
    /// to ten wasted calls rather than one per unknown id for ever. In
    /// practice this list is empty after the first successful run.
    private func resolveRetiredGear(token: String, limit: Int = 10) async {
        let held = Set(allGear.map(\.id))
        let named = Set(ActivityStore.shared.activities.compactMap(\.gearId))
        let missing = named.subtracting(held).sorted().prefix(limit)
        guard !missing.isEmpty else { return }

        var found: [Shoe] = []
        for id in missing {
            if let shoe = await fetchGear(id: id, token: token) { found.append(shoe) }
        }
        // Appended, not replaced. A run that resolved two of three must not
        // drop the two it already had.
        guard !found.isEmpty else { return }
        retired += found
    }

    private func fetchGear(id: String, token: String) async -> Shoe? {
        struct DetailedGear: Decodable {
            let id: String
            let name: String?
            let distance: Double?
            let primary: Bool?
        }
        guard let data = await get("https://www.strava.com/api/v3/gear/\(id)",
                                   token: token),
              let g = try? JSONDecoder().decode(DetailedGear.self, from: data)
        else { return nil }
        return Shoe(id: g.id,
                    name: g.name ?? "Retired gear",
                    distanceM: g.distance ?? 0,
                    // A retired shoe is nobody's primary, whatever the API
                    // says about the day it was.
                    primary: false,
                    // **`unknown`, AND IT IS THE HONEST ANSWER — patch 425.**
                    // `DetailedGear` above decodes id, name, distance and
                    // primary; the endpoint returns no type, so a retired BIKE
                    // arrives here indistinguishable from a retired shoe.
                    // Guessing `.shoe` would put `Shoe.wear`'s 600/800 km
                    // running thresholds on a bicycle — and would be right most
                    // of the time, which is what makes it dangerous rather than
                    // merely wrong. §12.132's third bucket, printed.
                    kind: .unknown,
                    // **TRUE BY CONSTRUCTION.** `resolveRetiredGear` is the
                    // only caller and it asks only about ids that activities
                    // name and the profile no longer holds. Reaching this line
                    // IS the retirement.
                    retired: true)
    }

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
        //
        // **AND THE KIND IS DECIDED HERE, WHERE IT IS KNOWN** — patch 425. The
        // response has two lists and the list is the fact; every layer below
        // this one has only a flat array to look at.
        func gear(_ list: [Athlete.Gear]?, fallbackName: String,
                  kind: GearKind) -> [Shoe] {
            (list ?? []).map {
                Shoe(id: $0.id,
                     name: $0.name ?? fallbackName,
                     distanceM: $0.distance ?? 0,
                     primary: $0.primary ?? false,
                     kind: kind,
                     // Anything this endpoint lists is gear the athlete still
                     // holds. Retirement is the absence from this response and
                     // nothing else — there is no flag to read.
                     retired: false)
            }
        }
        return (shoes: gear(a.shoes, fallbackName: "Shoe", kind: .shoe),
                bikes: gear(a.bikes, fallbackName: "Bike", kind: .bike))
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
        /// Optional for the same reason as `bikes` above, and it will stay
        /// optional: every file written before patch 268 lacks the key.
        var retired: [Shoe]?
        var fetched: Date?
        var ftp: Int?
    }

    // MARK: Hydration — D7 slice B1, patch 344

    /// Zones and FTP from the database. GEAR IS NOT TOUCHED — it is B5.
    ///
    /// A HALF-HYDRATED STORE IS A STATE, NOT AN OVERSIGHT, and `servedFrom`
    /// below is what keeps it from being one. `AthleteRepository` reads the
    /// profile, the resting months and the zones; shoes, bikes and retired gear
    /// come from `WeatherGearRepository`, which the slice order puts at B5
    /// because gear distance is a Strava refresh rather than a store write
    /// (§12.68.4). The two halves share no invariant, so serving one from rows
    /// and one from the file is safe — but it must be READABLE, which is why
    /// this sets `.partial` and names both sides.
    ///
    /// `separate` IS APPLIED, exactly as on the way out of the cache. The store
    /// normalises what it holds regardless of where it came from, and
    /// `hydrationIsIdempotentOnSeparatedZones` asserts the property this relies
    /// on: applying it to already-separated zones changes nothing, so hydration
    /// cannot move the read-back's answer.
    ///
    /// IT DOES NOT WRITE — see `PlanStore.hydrate`.
    func hydrate(zones: [HRZone], ftp: Int?) {
        hrZones = Self.separate(zones)
        self.ftp = ftp
        // **PATCH 430 — THE SENTENCE STOPS NAMING A SLICE THAT HAS LANDED.**
        //
        // `hydrate(gear:)` runs after this one and upgrades `servedFrom` to
        // `.database`, so this value is only ever READ when the gear did not
        // arrive — and after the flip there are two reasons for that, not one.
        // Printing `until slice B5` on a device where B5 shipped and the gear
        // table is simply empty would send a reader to the ladder instead of to
        // the import. §12.15, and §12.127.5's rule that a sentence about what a
        // store currently HOLDS cannot be a constant.
        //
        // `DetailStore.fill` asks the authority the same way, for the same
        // reason.
        servedFrom = .partial(
            fromDatabase: "zones and FTP",
            fromFiles: PersistenceAuthority.hydrates(.gear)
                ? "gear, nothing stored to hydrate from"
                : "gear, until slice B5")
    }

    /// **THE HALF B1 DID NOT TAKE — patch 429, D7 slice B5.**
    ///
    /// Unreachable until the flip: `hydratedFamilies` does not name `.gear`,
    /// so the planner hands nil and this is never called. Written now so the
    /// flip is one line somewhere else, which is what made 346's four failures
    /// attributable. §12.103.
    ///
    /// **THE THREE ARRAYS ARE REBUILT FROM `kind` AND `isRetired`**, which is
    /// the whole of what 425–427 were for: before them a `gear` row could not
    /// say which array it belonged in, and this function could not have been
    /// written at all.
    ///
    /// **`primary` BECOMES FALSE FOR EVERYTHING, AND NOTHING READS IT.**
    /// `Shoe.primary` is set by the endpoint parse and consulted by no view,
    /// no calculation and no diagnostic — an uncapped grep at 429 found one
    /// write and zero reads. It is Strava's answer to "which pair is the
    /// default", it has no column by decision (patch 324's approved
    /// difference), and hydrating cannot invent one. Said out loud because a
    /// field that quietly changes value at a flip is exactly what a read-back
    /// is for, and this one is invisible to it.
    ///
    /// **ORDER: `.shoe` LAST.** Retirement outranks kind — a retired bike is
    /// retired first — and `.unknown` goes to `shoes` because that is where
    /// `allGear` has always put unclassified gear, with `wearIsMeaningful`
    /// stopping the wear bar rather than the array stopping it.
    ///
    /// IT DOES NOT WRITE — see `PlanStore.hydrate`.
    func hydrate(gear stored: [WeatherGearLoad.StoredGear]) {
        var s: [Shoe] = [], b: [Shoe] = [], r: [Shoe] = []
        for row in stored {
            let shoe = Shoe(id: row.externalID, name: row.name,
                            distanceM: row.distanceM, primary: false,
                            kind: row.kind, retired: row.isRetired)
            if row.isRetired { r.append(shoe) }
            else if row.kind == .bike { b.append(shoe) }
            else { s.append(shoe) }
        }
        shoes = s; bikes = b; retired = r
        // **WHOLE AT LAST.** B1 took the zones and the FTP and said so; this is
        // the sentence that had `until slice B5` in it for eighty-three
        // patches.
        servedFrom = .database
    }

    /// **WHAT THE LAST READ OF `athlete.json` FOUND — patch 418, §12.163.**
    ///
    /// This store and `AthleteConstants` were the two `UNPROTECTED_STORE_CEILING`
    /// held since 378. The read was `try? Data(contentsOf:)` and
    /// `try? JSONDecoder().decode(…)` with `else { return }`, so **a file
    /// nobody could decode left memory at its defaults and said nothing** — and
    /// the next `save()` wrote those defaults over it. §12.116's exact shape,
    /// in the store holding thirteen months of gear.
    private(set) var lastLoad: StoreLoad = .absent

    private func load() {
        // THE DECODER IS THE BARE ONE, DELIBERATELY. `AthleteFile` decodes this
        // file with `.deferredToDate` on the strength of `save()` using a bare
        // `JSONEncoder`, and `StoreRead.decode` defaults to `JSONDecoder.sub4`.
        // Passing the default here would have made every existing file
        // unreadable — which the new guard would then have correctly refused to
        // overwrite, turning a protection into a store that never writes again.
        let (value, outcome) = StoreRead.decode(Cache.self, at: fileURL,
                                                decoder: JSONDecoder())
        lastLoad = outcome
        guard let c = value else { return }
        // Also on the way OUT of the cache, so a file written before patch 81
        // is corrected without waiting for the next Strava fetch.
        hrZones = Self.separate(c.zones)
        // **THE KIND IS RECOVERED FROM THE ARRAY, NOT INVENTED — patch 425.**
        // A file written before this patch carries `kind: nil` on every item,
        // and the fact is not lost: it is in which key the item decoded from.
        // So the same rule applies on the way out of the cache as on the way
        // out of the endpoint, and no file needs rewriting for the database to
        // learn what it already knew. `kinded` leaves a kind that IS set alone.
        shoes = Self.kinded(c.shoes, .shoe, retired: false)
        // Absent in every file written before patch 267, which is the whole
        // reason the column is optional. Empty until the next refresh.
        bikes = Self.kinded(c.bikes ?? [], .bike, retired: false)
        // NOT `.shoe`. Retired gear is the one list whose kind was never known
        // — see `fetchGear` — so an item that arrived without one keeps
        // `.unknown` rather than being told what it was. The retirement,
        // though, is exactly what this array means.
        retired = Self.kinded(c.retired ?? [], .unknown, retired: true)
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
        retired = []
        lastFetch = nil
        lastError = nil
    }

    private func save() {
        let c = Cache(zones: hrZones, shoes: shoes,
                      bikes: bikes.isEmpty ? nil : bikes,
                      retired: retired.isEmpty ? nil : retired,
                      fetched: lastFetch, ftp: ftp)
        // A bare `JSONEncoder`, as it has always been — `AthleteFile` decodes
        // this file with `.deferredToDate` on the strength of it, and changing
        // the encoder here would break thirteen months of files on disk.
        // **THE 371 GUARD, ON THE LAST TWO STORES WITHOUT IT — patch 418.**
        //
        // Thrown INSIDE `attempt`, because this `save()` cannot throw to its
        // callers — they are Strava refreshes and gear edits, forty of them,
        // and §12.12.6 is why the journal exists rather than a decision at each
        // one. The refusal lands in "Unsaved stores" with its reason, which is
        // where a reader looks, and the file keeps the bytes nobody could read.
        StoreWriteJournal.shared.attempt("athlete.json") {
            guard lastLoad.isTrustworthy else {
                throw StoreWriteError(store: "athlete.json", stage: .refused,
                                      reason: "the store was not read cleanly at launch")
            }
            try StoreWrite.encode(c, to: fileURL, store: "athlete.json",
                                  encoder: JSONEncoder())
        }
        // ZONES AND FTP ARE RE-FETCHABLE AND THIS STILL FIRES. The rule is
        // "every store the app hydrates writes through", not "every store
        // whose data would be missed" — §12.93.5 already spent the second kind
        // of reasoning once, on the grounds that the fields at risk were nil,
        // and spending it twice is how a hole becomes permanent. A Strava
        // refresh happens at most daily, so the cost is one extra run a day
        // that the coalescer usually absorbs. Patch 348, §12.94.
        DatabaseWriteThrough.shared.noteAuthoredChange("the athlete cache was saved")
    }
}
