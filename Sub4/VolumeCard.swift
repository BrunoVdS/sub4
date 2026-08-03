//
//  VolumeCard.swift
//  Sub4
//
//  Weekly volume, per discipline, on the calendar rather than on the plan.
//
//  WHY CALENDAR WEEKS AND NOT PLAN WEEKS
//  -------------------------------------
//  The first version indexed this chart by plan week, which meant that on
//  29 July — three days into a 34-week block — it drew exactly one bar, one
//  floating grey dot, and an x-axis whose only label was "0". It would have
//  stayed close to unreadable until roughly October.
//
//  The training did not start on 27 July; the PLAN did. There are seven months
//  of running behind that date and the question the chart answers — "is my
//  weekly volume going up" — is answered better by all of it than by the part
//  that happens to fall inside the block.
//
//  THE UNIT CHANGES WITH THE DISCIPLINE, AND THAT IS THE POINT
//  -----------------------------------------------------------
//  Run and swim are kilometres. Bike is HOURS.
//
//  This is not a preference. The plan never writes a cycling distance — it
//  writes "2.5 h Z2" and "60–75 min" — so a kilometre axis for the bike could
//  carry no planned reference line at all, and the chart would lose the one
//  thing it is for. `PlanStore.plannedHours` already exists and already feeds
//  the overview card, so on hours all three disciplines keep their grey
//  reference. Charting the bike in kilometres would have been the single option
//  that made this chart less useful than the version it replaces.
//
//  THE BIKE HAS TWO COLUMNS
//  ------------------------
//  Training volume and commute volume, side by side, both in hours because one
//  chart gets one y-axis and that rule does not bend for a second series.
//
//  Without it the bike chart is a row of zeros. Every ride in the last thirty
//  days is under the 10 km training threshold — 79 km of real riding, all of it
//  commuting — and a chart that renders that as "nothing happened" is wrong in
//  a way that a footnote cannot fix. The second column is the difference
//  between "you did not ride" and "you rode, and none of it was training".
//
//  BARS AND THE REFERENCE LINE SHARE AN X VALUE
//  --------------------------------------------
//  Single-column weeks plot at the MIDPOINT of the week, not its Monday. Swift
//  Charts offers `.value(_:_:unit:)` to centre a bar inside a calendar interval,
//  but it centres only the mark that asks for it — a bar using it and a line not
//  using it end up half a week apart, which on a 26-week axis is a visible lie
//  about which week was over plan. Plotting everything against an explicit
//  midpoint costs one property and removes the failure mode; the paired columns
//  straddle that midpoint by a fixed number of days.
//
//  A PLAN IS A SERIES, A TARGET IS A THRESHOLD
//  -------------------------------------------
//  The planned line stays recessive grey, per the convention at the top of
//  ProgressTabView: it is a second series and must not compete with the
//  recorded bars. That is a different thing from the single fixed marathon-pace
//  target on the pace chart, which is a threshold and is drawn forward.
//
//  OPTIONAL SESSIONS ARE EXCLUDED FROM THE PLANNED FIGURE
//  ------------------------------------------------------
//  `plannedRunKm(week:)` does not exclude them and for running that is harmless
//  — no run in this plan is optional. Half the BIKE work is "opt." Zwift, so
//  including it would put a reference line above every week the plan never
//  really asked for. This file goes through `PlanStore.isOptional`, matching
//  `plannedVolume` rather than `plannedRunKm(week:)`.
//

import SwiftUI
import Charts

// MARK: - What is being measured, and in what

/// Kilometres or hours, for whichever discipline is selected.
///
/// WHY THIS IS A SECOND AXIS RATHER THAN MORE CASES
/// ------------------------------------------------
/// Bike volume used to be hours and everything else kilometres, hard-coded per
/// discipline, because that is how the plan writes them. Both figures exist for
/// every activity though — Strava records distance and duration for all of them
/// — so the unit was never a property of the sport, only of the plan's
/// vocabulary. Making it its own axis removes that special case rather than
/// adding to it, and it means a ride can be read either way instead of being
/// permanently one.
///
/// WHY HOURS IS THE DEFAULT
/// ------------------------
/// By kilometres the bike dwarfs everything, because a bike covers ground four
/// times faster than a runner and the commute alone is 3,000 km a year. By hours
/// the same history reads as a broadly-spread endurance athlete. Both are true —
/// a 3 km swim genuinely is a small distance and a large hour — but only one of
/// them leaves the sport this app exists for visible.
///
/// THE FIGURES THAT USED TO BE IN THIS COMMENT ARE NOW COMPUTED.
/// They were measured once, in April 2026, hard-coded here and in four ⓘ
/// entries, and were still being quoted as "the last four months" in August
/// against a history that had since grown from four months to thirteen. A
/// percentage in a comment is a percentage nobody will remember to re-measure —
/// see `VolumeSeries.mix`, which the sheet now reads at the moment it opens.
enum VolumeUnit: String, CaseIterable, Identifiable {
    case hours, km

    var id: String { rawValue }

    /// What goes beside a figure.
    var short: String { self == .hours ? "h" : "km" }

    /// What goes in the card's header, and on the toggle.
    var label: String { self == .hours ? "hours" : "km" }

    var other: VolumeUnit { self == .hours ? .km : .hours }
}

enum VolumeUnitKey {
    static let selected = "volume.unit"
}

/// One selectable series. Everything that differs between disciplines lives
/// here, so adding Strength later is a case and no new view code.
enum VolumeMetric: String, CaseIterable, Identifiable {
    case run, bike, swim

    var id: String { rawValue }

    var discipline: Discipline {
        switch self {
        case .run:  .run
        case .bike: .bike
        case .swim: .swim
        }
    }

    var label: String { discipline.label }
    var symbol: String { discipline.symbol }
    var tint: Color { discipline.tint }

    /// What the TILE shows. Always one decimal.
    ///
    /// The block totals on the overview card round to whole kilometres because
    /// they are hundreds of them. A tile is a 30-day figure, where 15.8 km
    /// rounding to "16" hides a kilometre that is 6% of a light week — and
    /// makes the delta beneath it fail to add up against the figure above.
    var tileDecimals: Int { 1 }

    /// The smallest axis ceiling worth drawing. Without one, a window of zeros
    /// gets a 0…1 axis and three ticks describing nothing.
    func axisMinimum(_ u: VolumeUnit) -> Double {
        switch u {
        case .hours:
            switch self {
            case .run:  2
            case .bike: 2
            case .swim: 1
            }
        case .km:
            switch self {
            case .run:  10
            case .bike: 40
            case .swim: 2
            }
        }
    }

    /// Only the bike separates training from commuting — a run is a run.
    var hasCommute: Bool { self == .bike }

    /// What one activity contributes to TRAINING volume, in this metric's unit.
    ///
    /// Matches `ProgressTabView.actualVolume` exactly, including its
    /// asymmetries: the bike is gated on the training threshold, running and
    /// swimming are not, because a short swim is still swimming while a 3 km
    /// ride is transport.
    func recorded(_ a: Activity, _ u: VolumeUnit) -> Double {
        guard a.discipline == discipline else { return 0 }
        switch self {
        case .run, .swim: return VolumeMetric.amount(a, u)
        case .bike:       return a.isPlanEligible ? VolumeMetric.amount(a, u) : 0
        }
    }

    /// What one activity contributes to COMMUTE volume. Zero for everything
    /// except a ride under the training threshold.
    func commute(_ a: Activity, _ u: VolumeUnit) -> Double {
        guard hasCommute, a.discipline == .bike, !a.isPlanEligible else { return 0 }
        return VolumeMetric.amount(a, u)
    }

    /// One activity in one unit.
    ///
    /// The seconds are `DataCorrections.scoringSeconds`, which is what the load
    /// engine scores — so a week's volume and a week's load can never tell
    /// different stories about the same session, including the one hand-
    /// corrected swim.
    ///
    /// Note what this deliberately does NOT use: the Apple Health active time
    /// that fixes the swim PACE chart. Rest between pool sets is not swimming,
    /// which is why pace excludes it — but it is time spent training, which is
    /// what volume counts. Same session, two right answers, two questions.
    static func amount(_ a: Activity, _ u: VolumeUnit) -> Double {
        switch u {
        case .km:    a.km
        case .hours: Double(DataCorrections.scoringSeconds(a)) / 3600
        }
    }

    /// Whether an activity counts as a session for the marker's session count.
    ///
    /// Asked in kilometres regardless of the unit on screen, so the count does
    /// not change when the toggle moves. A session is a session.
    func isSession(_ a: Activity) -> Bool {
        a.discipline == discipline && recorded(a, .km) > 0
    }

    /// What one planned session prescribes, in the unit asked for.
    ///
    /// THE PLAN IS NOT WRITTEN IN ONE UNIT, AND NOTHING IS CONVERTED
    /// ------------------------------------------------------------
    /// Counted, not assumed: of the plan's 53 bike sessions, 51 state a time
    /// and the only 2 stating a distance are the 6 km and 4 km recovery spins.
    /// All 26 swims state metres and none state a time. Runs state kilometres,
    /// except a handful written in minutes, which `plannedRunKm` converts at the
    /// pace the plan itself prints and marks inexact.
    ///
    /// So asking for bike kilometres, or swim hours, returns zero — not because
    /// the week prescribed nothing but because the plan said it in the other
    /// unit. `counts` is what tells those two apart: it is 1 whenever this
    /// session belongs to this discipline at all, so the chart can see that a
    /// week had sessions yet no figure in the unit on screen, and suppress the
    /// reference line rather than draw it along the floor.
    ///
    /// A converted hour would be a guess wearing the same units as a
    /// measurement, and on a chart the two become indistinguishable.
    func planned(_ s: Session, _ u: VolumeUnit) -> (value: Double, exact: Bool, counts: Bool) {
        guard s.discipline == discipline, !PlanStore.isOptional(s)
        else { return (0, true, false) }
        switch u {
        case .km:
            switch self {
            case .run:
                let d = PlanStore.plannedRunKm(s)
                return (d.km, d.exact, true)
            case .bike:
                return (PlanStore.plannedDistanceKm(s).km, true, true)
            case .swim:
                return (PlanStore.plannedMetres(s) / 1000, true, true)
            }
        case .hours:
            // No cross-unit conversion anywhere. A run written as "18 km" has no
            // stated duration and returns zero, which is exactly why `counts`
            // exists — the run line is then suppressed rather than drawn wrong.
            return (PlanStore.plannedHours(s), true, true)
        }
    }
}

// MARK: - The total, and its segments

/// One band of the stacked total column, bottom to top.
///
/// THE ORDER WAS MEASURED, NOT CHOSEN
/// ----------------------------------
/// Stacked segments touch, and two colours that merely differ in a legend can be
/// indistinguishable when they share an edge. The obvious order — run, bike,
/// swim, commute, other — puts run green against bike cyan, which measure
/// **ΔE 10.9 for normal vision**, below the 15 floor. That is not a colourblind
/// edge case: it is hard to separate with full colour vision when the two fills
/// meet. They are fine in the existing legend only because they never touch
/// there.
///
/// Putting amber between them costs nothing and takes the worst adjacent pair to
/// ΔE 23.1 normal / 19.7 CVD. Every hue is one the app already uses for that
/// sport, so nothing was repainted and a colour still means the same thing on
/// every other screen.
///
/// COMMUTE IS A SHADE, NOT A HUE
/// -----------------------------
/// A commute IS a bike ride, so colour should follow that entity — but every
/// cyan close enough to still read as "bike" measured too close to the bike
/// tint to separate (best case ΔE 11.6), and every cyan far enough to separate
/// stopped reading as bike. So commute is the bike tint at 55%: same entity, the
/// distinction carried by weight rather than by hue, and it sits at the top of
/// the stack where its only neighbour is the colour it is derived from.
///
/// (The mock-up used a 45° hatch, which is the better answer and which Swift
/// Charts cannot fill a `BarMark` with. The validated separation does not depend
/// on it — the palette passes on hue alone.)
/// STRENGTH AND THE RESIDUAL ARE TWO THINGS, NOT ONE
/// --------------------------------------------------
/// They shared a band until patch 111, and the shared label — "Strength & other"
/// — was carrying the wrong noun. Measured over the thirty days to 31 Jul 2026:
/// walking 13.5 h, kayak 0.9 h, strength 0.4 h. The band was 97% walking under a
/// name that led with the 3%.
///
/// Strength is also the second most prescribed discipline in the plan — 56
/// sessions against run's 105, ahead of bike's 53 and swim's 26 — so it earns a
/// band of its own even while it reads near zero, which it will for the first
/// weeks of the block. A band that is currently thin is not the same as a band
/// that does not belong.
///
/// The residual keeps the honest plural: walks, the kayak, the row, and whatever
/// Strava sends next that the plan has no discipline for.
enum VolumeSegment: String, CaseIterable, Identifiable {
    /// Declaration order IS stack order, bottom-up. Amber (strength) still sits
    /// between the blue and the cyan for the reason given above; the residual
    /// goes on top, where its only neighbour is the commute.
    case run, swim, strength, bike, commute, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .run:      "Run"
        case .swim:     "Swim"
        case .strength: "Strength"
        case .bike:     "Bike"
        case .commute:  "Commute"
        case .other:    "Walk & other"
        }
    }

    var fill: Color {
        switch self {
        case .run:      Discipline.run.tint
        case .swim:     Discipline.swim.tint
        case .strength: Discipline.strength.tint
        case .other:    Color.residual
        case .bike:     Discipline.bike.tint
        // ONE NAME, TWO ENTIRELY DIFFERENT ANSWERS. On dark this is the bike
        // hue at 55% — a tint towards the background, which keeps its chroma.
        // On light that same move fails three checks at once, so the light
        // scheme gives the commute its own hue and loses the family
        // resemblance. See the header of Theme.swift for the measurements.
        case .commute: Discipline.commuteTint
        }
    }

    /// Which band an activity lands in.
    ///
    /// The split costs one arm, because `Activity.discipline` already made the
    /// distinction and this function was throwing it away: WeightTraining,
    /// Workout, Crossfit and HighIntensityIntervalTraining come back as
    /// `.strength`, while Walk, Kayaking and Rowing come back as `nil`. Only the
    /// `default` clause was merging them.
    ///
    /// In KILOMETRES the strength band never draws — a circuit has no distance —
    /// so the km chart keeps five bands and the legend hides the sixth by
    /// itself: both legends are built from `presentSegments`, which filters on a
    /// non-zero value rather than on the case list.
    static func of(_ a: Activity) -> VolumeSegment {
        switch a.discipline {
        case .some(.run):      return .run
        case .some(.swim):     return .swim
        case .some(.strength): return .strength
        case .some(.bike):     return a.isPlanEligible ? .bike : .commute
        default:               return .other
        }
    }
}

/// One week of the stacked total.
struct VolumeStackWeek: Identifiable {
    let start: Date
    /// Keyed by segment, in `VolumeSegment.allCases` order.
    let parts: [VolumeSegment: Double]

    var id: Date { start }
    var mid: Date { start.addingTimeInterval(3.5 * 86_400) }
    func value(_ s: VolumeSegment) -> Double { parts[s] ?? 0 }
    var total: Double { parts.values.reduce(0, +) }
}

/// Shares of the whole recorded history, by band and by unit.
struct VolumeMix {

    let hours: [VolumeSegment: Double]
    let km: [VolumeSegment: Double]
    let firstDayKey: String?

    var totalHours: Double { hours.values.reduce(0, +) }
    var totalKm: Double { km.values.reduce(0, +) }

    /// Whole percent. A share quoted to a decimal invites a precision the input
    /// does not have — one mis-scored ride moves it more than the decimal does.
    func hoursShare(_ s: VolumeSegment) -> Int { pct(hours[s] ?? 0, totalHours) }
    func kmShare(_ s: VolumeSegment) -> Int { pct(km[s] ?? 0, totalKm) }

    /// Run and bike hold two bands each once commutes and the residual are
    /// separated; a sentence about "the bike" means both.
    func hoursShare(_ list: [VolumeSegment]) -> Int {
        pct(list.reduce(0.0) { $0 + (hours[$1] ?? 0) }, totalHours)
    }

    func kmShare(_ list: [VolumeSegment]) -> Int {
        pct(list.reduce(0.0) { $0 + (km[$1] ?? 0) }, totalKm)
    }

    private func pct(_ part: Double, _ whole: Double) -> Int {
        guard whole > 0 else { return 0 }
        return Int((part / whole * 100).rounded())
    }

    /// "July 2025" — where the history starts, so the percentages are never
    /// quoted against an unnamed window. The last version said "the last four
    /// months" for six months after that stopped being true.
    var sinceLabel: String {
        guard let d = firstDayKey.flatMap(DayKey.date) else { return "the start" }
        return Self.monthYear.string(from: d)
    }

    private static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}

/// The rolling-30-day total, in both units, with the 30 days before it.
struct VolumeTotals {
    let km: Double
    let hours: Double
    let previousKm: Double
    let previousHours: Double

    func value(_ u: VolumeUnit) -> Double { u == .km ? km : hours }
    func previous(_ u: VolumeUnit) -> Double { u == .km ? previousKm : previousHours }
    func delta(_ u: VolumeUnit) -> Double { value(u) - previous(u) }
}

// MARK: - The series

struct VolumeWeek: Identifiable {
    /// Monday, 00:00, ISO.
    let start: Date
    let training: Double
    let commute: Double
    let planned: Double
    let plannedExact: Bool
    /// Non-optional sessions of this discipline the plan put in this week,
    /// whether or not they stated a figure in the unit on screen. A week with
    /// sessions but no figure is the plan speaking another unit, not a rest
    /// week — see `VolumeMetric.planned`.
    let plannedSessions: Int
    /// Set only where a plan week begins in this calendar week.
    let planWeekNo: Int?

    var id: Date { start }

    /// Where a single column and the reference line are drawn — see the note
    /// at the top of the file.
    var mid: Date { start.addingTimeInterval(3.5 * 86_400) }

    /// Paired columns straddle the midpoint. In days rather than points because
    /// the x-axis is a date scale; the visual separation therefore scales with
    /// the window instead of being right at 26 weeks and wrong at 52.
    func offset(_ days: Double) -> Date {
        start.addingTimeInterval((3.5 + days) * 86_400)
    }

    var total: Double { training + commute }
}

/// The rolling-30-day headline for one discipline.
///
/// Carries BOTH units rather than the selected one, because the tile shows the
/// selected figure large and the other small beneath it. The point of the
/// toggle is to compare the two readings; making you flip the card to see the
/// second number would defeat it.
struct VolumeMarker: Identifiable {
    let metric: VolumeMetric
    let trainingKm: Double
    let trainingHours: Double
    let commuteKm: Double
    let commuteHours: Double
    let sessions: Int
    /// The same figures over the 30 days before that, for the delta.
    let previousKm: Double
    let previousHours: Double

    var id: String { metric.rawValue }

    func training(_ u: VolumeUnit) -> Double { u == .km ? trainingKm : trainingHours }
    func commute(_ u: VolumeUnit) -> Double { u == .km ? commuteKm : commuteHours }
    func previous(_ u: VolumeUnit) -> Double { u == .km ? previousKm : previousHours }
    func delta(_ u: VolumeUnit) -> Double { training(u) - previous(u) }
}

enum VolumeSeries {

    /// Half a year on the card — enough to see a trend without the bars
    /// becoming hairlines. The expanded panel is wide enough for a full year.
    static let cardWeeks = 26
    static let expandedWeeks = 52

    /// Rolling, not calendar. A calendar month resets to near-zero every 1st
    /// and would read as a collapse for the first three days of it.
    static let markerDays = 30

    nonisolated static let calendar = Calendar(identifier: .iso8601)

    /// The Monday of the week containing `date`.
    nonisolated static func monday(of date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// Bucketed in one pass over the activities rather than one pass per week —
    /// at 52 weeks against a few thousand activities the naive version is a
    /// quarter of a million date comparisons per redraw.
    ///
    /// Buckets are keyed by the Monday's day-key STRING, not by its `Date`.
    /// Two Mondays computed by different routes are equal to the second only if
    /// nothing about the calendar moved between them; the string is equal when
    /// the day is the same, which is what is being asked.
    static func weeks(count: Int, metric: VolumeMetric, unit: VolumeUnit,
                      activities: [Activity], store: PlanStore) -> [VolumeWeek] {
        let thisMonday = monday(of: Date())
        guard count > 0,
              let first = calendar.date(byAdding: .weekOfYear,
                                        value: -(count - 1), to: thisMonday)
        else { return [] }

        var training: [String: Double] = [:]
        var commute: [String: Double] = [:]
        for a in activities where a.discipline == metric.discipline {
            guard let d = DayKey.date(a.dayKey) else { continue }
            let m = monday(of: d)
            guard m >= first, m <= thisMonday else { continue }
            let key = DayKey.key(m)
            training[key, default: 0] += metric.recorded(a, unit)
            commute[key, default: 0] += metric.commute(a, unit)
        }

        var planned: [String: (value: Double, exact: Bool, sessions: Int, no: Int?)] = [:]
        for w in store.planWeeks {
            guard let dayKey = w.startDate, let d = DayKey.date(dayKey) else { continue }
            var value = 0.0
            var exact = true
            var sessions = 0
            for s in store.sessions(inWeek: w) {
                let p = metric.planned(s, unit)
                value += p.value
                if !p.exact { exact = false }
                if p.counts { sessions += 1 }
            }
            planned[DayKey.key(monday(of: d))] = (value, exact, sessions, w.weekNo)
        }

        return (0..<count).compactMap { i in
            guard let m = calendar.date(byAdding: .weekOfYear, value: i, to: first)
            else { return nil }
            let key = DayKey.key(m)
            let p = planned[key]
            return VolumeWeek(start: m,
                              training: training[key] ?? 0,
                              commute: commute[key] ?? 0,
                              planned: p?.value ?? 0,
                              plannedExact: p?.exact ?? true,
                              plannedSessions: p?.sessions ?? 0,
                              planWeekNo: p?.no)
        }
    }

    /// One marker per discipline, always all three — a zero is information and
    /// hiding it would remove the only thing that says a month of swimming
    /// stopped.
    static func markers(_ activities: [Activity]) -> [VolumeMarker] {
        let now = Date()
        let cutoff = dayKey(now, minusDays: markerDays - 1)
        let priorEnd = dayKey(now, minusDays: markerDays)
        let priorStart = dayKey(now, minusDays: markerDays * 2 - 1)

        return VolumeMetric.allCases.map { metric in
            var tKm = 0.0, tH = 0.0, cKm = 0.0, cH = 0.0, pKm = 0.0, pH = 0.0
            var sessions = 0
            for a in activities where a.discipline == metric.discipline {
                if a.dayKey >= cutoff {
                    tKm += metric.recorded(a, .km);  tH += metric.recorded(a, .hours)
                    cKm += metric.commute(a, .km);   cH += metric.commute(a, .hours)
                    if metric.isSession(a) { sessions += 1 }
                } else if a.dayKey >= priorStart && a.dayKey <= priorEnd {
                    pKm += metric.recorded(a, .km);  pH += metric.recorded(a, .hours)
                }
            }
            return VolumeMarker(metric: metric,
                                trainingKm: tKm, trainingHours: tH,
                                commuteKm: cKm, commuteHours: cH,
                                sessions: sessions,
                                previousKm: pKm, previousHours: pH)
        }
    }

    /// Everything, in one unit, split into the six bands.
    ///
    /// No planned line here, in either unit, and the reason is worth stating
    /// once: in hours the plan's swim prescription is missing, in kilometres its
    /// bike prescription is. Either way a total reference would be short every
    /// week that contained the missing sport — and once summed, the measured
    /// part and the absent part are indistinguishable.
    static func stack(count: Int, unit: VolumeUnit,
                      activities: [Activity]) -> [VolumeStackWeek] {
        let thisMonday = monday(of: Date())
        guard count > 0,
              let first = calendar.date(byAdding: .weekOfYear,
                                        value: -(count - 1), to: thisMonday)
        else { return [] }

        var buckets: [String: [VolumeSegment: Double]] = [:]
        for a in activities {
            guard let d = DayKey.date(a.dayKey) else { continue }
            let m = monday(of: d)
            guard m >= first, m <= thisMonday else { continue }
            let v = VolumeMetric.amount(a, unit)
            guard v > 0 else { continue }
            buckets[DayKey.key(m), default: [:]][VolumeSegment.of(a), default: 0] += v
        }

        return (0..<count).compactMap { i in
            guard let m = calendar.date(byAdding: .weekOfYear, value: i, to: first)
            else { return nil }
            return VolumeStackWeek(start: m, parts: buckets[DayKey.key(m)] ?? [:])
        }
    }

    /// The whole ingested history, split by band, in both units.
    ///
    /// WHY THIS EXISTS AT ALL
    /// ----------------------
    /// Four ⓘ entries quoted shares of total volume — "the bike is 66% by
    /// kilometres", "swimming is 8% by hours" — measured by hand in April 2026
    /// and written into string literals. By August the ingest window had gone
    /// from four months to thirteen, three rides had been rejected, one swim
    /// ignored, and strength had been split out of the residual. Every one of
    /// those figures was wrong and none of them could announce it.
    ///
    /// Computed on demand instead. The sheet asks when it opens, which is a
    /// handful of milliseconds over ~650 activities and cannot go stale.
    static func mix(_ activities: [Activity]) -> VolumeMix {
        var hours: [VolumeSegment: Double] = [:]
        var km: [VolumeSegment: Double] = [:]
        var first: String?
        for a in activities {
            let seg = VolumeSegment.of(a)
            hours[seg, default: 0] += VolumeMetric.amount(a, .hours)
            km[seg, default: 0] += VolumeMetric.amount(a, .km)
            if first == nil || a.dayKey < first! { first = a.dayKey }
        }
        return VolumeMix(hours: hours, km: km, firstDayKey: first)
    }

    /// The rolling-30-day figure for everything, in both units.
    static func totals(_ activities: [Activity]) -> VolumeTotals {
        let now = Date()
        let cutoff = dayKey(now, minusDays: markerDays - 1)
        let priorEnd = dayKey(now, minusDays: markerDays)
        let priorStart = dayKey(now, minusDays: markerDays * 2 - 1)

        var km = 0.0, h = 0.0, pKm = 0.0, pH = 0.0
        for a in activities {
            if a.dayKey >= cutoff {
                km += VolumeMetric.amount(a, .km); h += VolumeMetric.amount(a, .hours)
            } else if a.dayKey >= priorStart && a.dayKey <= priorEnd {
                pKm += VolumeMetric.amount(a, .km); pH += VolumeMetric.amount(a, .hours)
            }
        }
        return VolumeTotals(km: km, hours: h, previousKm: pKm, previousHours: pH)
    }

    private static func dayKey(_ from: Date, minusDays n: Int) -> String {
        let d = calendar.date(byAdding: .day, value: -n, to: from) ?? from
        return DayKey.key(d)
    }

    static func num(_ v: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", v)
    }
}

// MARK: - The card

struct VolumeCard: View {

    private let store = PlanStore.shared
    @State private var activities = ActivityStore.shared

    /// Persisted rather than @State: leaving the Progress tab and coming back
    /// would otherwise snap the chart to Run every time, which makes the
    /// selector feel like it did not take.
    ///
    /// Shared with the pace card since patch 70 — see `DisciplineKey`.
    @AppStorage(DisciplineKey.selected) private var metricRaw = VolumeMetric.run.rawValue
    /// Its own key, not shared with Pace — a pace has no unit to choose.
    @AppStorage(VolumeUnitKey.selected) private var unitRaw = VolumeUnit.hours.rawValue

    private var metric: VolumeMetric {
        VolumeMetric(rawValue: metricRaw) ?? .run
    }
    /// Total is stored in the SAME key as the three disciplines, as the string
    /// `"all"`. `VolumeMetric(rawValue:)` then returns nil and falls back to run,
    /// which is exactly what Pace needs when you switch panels while Total is
    /// selected — there is no such thing as a total pace, and Run is the sane
    /// landing. No second key, and no state the two cards can disagree about.
    private var isTotal: Bool { metricRaw == VolumeSelection.total }
    private var unit: VolumeUnit { VolumeUnit(rawValue: unitRaw) ?? .hours }

    var body: some View {
        let m = metric
        let u = unit
        let weeks = VolumeSeries.weeks(count: VolumeSeries.cardWeeks, metric: m, unit: u,
                                       activities: activities.activities, store: store)
        let marks = VolumeSeries.markers(activities.activities)
        // Nothing recorded and nothing planned in six months, in any discipline,
        // is an empty chart with a legend under it. Asked in kilometres so the
        // gate cannot change with the toggle.
        if weeks.contains(where: { $0.total > 0 || $0.planned > 0 })
            || marks.contains(where: { $0.trainingKm > 0 || $0.commuteKm > 0 }) {
            // Opens on Weekly volume, switches to Pace in place — same
            // discipline on the other side, because they share one key.
            ExpandableCard(panels: PanelGroup.volumePace, opensOn: "volume") {
                VolumeChartCard(metric: m, unit: u, isTotal: isTotal,
                                markers: marks, weeks: weeks,
                                stackWeeks: isTotal
                                    ? VolumeSeries.stack(count: VolumeSeries.cardWeeks,
                                                         unit: u,
                                                         activities: activities.activities)
                                    : [],
                                totals: VolumeSeries.totals(activities.activities),
                                barWidth: 4, height: 150,
                                onSelect: { metricRaw = $0 },
                                onUnit: { unitRaw = $0.rawValue })
            }
        }
    }
}

struct VolumeExpanded: View {

    private let store = PlanStore.shared
    @State private var activities = ActivityStore.shared

    /// Same key as the card — and as the pace card — so the panel opens on
    /// whatever was selected, a change made inside it survives being closed,
    /// and switching to Pace lands on the same discipline.
    @AppStorage(DisciplineKey.selected) private var metricRaw = VolumeMetric.run.rawValue
    @AppStorage(VolumeUnitKey.selected) private var unitRaw = VolumeUnit.hours.rawValue

    private var metric: VolumeMetric { VolumeMetric(rawValue: metricRaw) ?? .run }
    private var isTotal: Bool { metricRaw == VolumeSelection.total }
    private var unit: VolumeUnit { VolumeUnit(rawValue: unitRaw) ?? .hours }

    var body: some View {
        VolumeChartCard(metric: metric, unit: unit, isTotal: isTotal,
                        markers: VolumeSeries.markers(activities.activities),
                        weeks: VolumeSeries.weeks(count: VolumeSeries.expandedWeeks,
                                                  metric: metric, unit: unit,
                                                  activities: activities.activities,
                                                  store: store),
                        stackWeeks: isTotal
                            ? VolumeSeries.stack(count: VolumeSeries.expandedWeeks,
                                                 unit: unit,
                                                 activities: activities.activities)
                            : [],
                        totals: VolumeSeries.totals(activities.activities),
                        barWidth: 5, height: nil,
                        onSelect: { metricRaw = $0 },
                        onUnit: { unitRaw = $0.rawValue },
                        chrome: false)
    }
}

/// The one string that is not a discipline.
enum VolumeSelection {
    static let total = "all"
}

// MARK: - The chart itself

struct VolumeChartCard: View {

    let metric: VolumeMetric
    let unit: VolumeUnit
    let isTotal: Bool
    let markers: [VolumeMarker]
    let weeks: [VolumeWeek]
    /// Empty unless Total is selected — the stack is only built when drawn.
    let stackWeeks: [VolumeStackWeek]
    let totals: VolumeTotals
    let barWidth: CGFloat
    /// nil means "take the height you are given" — the expanded panel.
    let height: CGFloat?
    /// Takes the raw key, because one of the four values is not a discipline.
    let onSelect: (String) -> Void
    let onUnit: (VolumeUnit) -> Void
    /// The card draws its own title and background; the expanded panel supplies
    /// both itself.
    var chrome = true

    /// The cursor, panel only.
    ///
    /// WHY THE CARD DOES NOT GET ONE
    /// ------------------------------
    /// Two reasons, and the second is the disqualifying one. At 26 weeks in a
    /// phone-width card a week is about eleven points across, which is pointable
    /// at but not precisely; and the card lives inside an `ExpandableCard`,
    /// whose whole job is to open the panel when you tap it. A selection
    /// gesture on the plot would eat that tap. So `.chartXSelection` is applied
    /// in `panelBody` and nowhere else — on the card this stays nil for the
    /// lifetime of the view and the cursor marks never draw.
    @State private var selected: Date?

    /// How far each paired column sits from the week's midpoint, in days.
    private let pairOffset = 1.9

    private var domain: ClosedRange<Double> {
        // The planned figures enter the scale only when the line is drawn.
        // A suppressed reference still has values in the weeks the plan wrote
        // in this unit, and letting those set the ceiling would leave headroom
        // above the bars for a line that is not there.
        //
        // Written as a loop, not a `flatMap` with a conditional array literal
        // inside it. That form is one of the shapes that sends the Swift type
        // checker exponential, and it did — see the note above `captions`.
        var values: [Double] = []
        let drawPlanned: Bool = hasPlanned
        for w in weeks {
            values.append(w.training)
            values.append(w.commute)
            if drawPlanned { values.append(w.planned) }
        }
        return ChartScale.domain(values, minimum: metric.axisMinimum(unit))
    }

    /// The Monday the block starts on, drawn once so the plan's beginning is
    /// visible without a second axis. nil when the window is entirely inside
    /// the plan, where a marker at the left edge says nothing.
    private var planStart: Date? {
        guard let i = weeks.firstIndex(where: { $0.planWeekNo != nil }), i > 0
        else { return nil }
        return weeks[i].start
    }

    /// The reference line is drawn only where the plan wrote THIS unit for every
    /// week that has sessions in it.
    ///
    /// The weaker test — "any week with a figure" — draws a line that falls to
    /// the floor on every week the plan stated in the other unit, which reads as
    /// "the plan asked for nothing that week". That is the precise failure the
    /// no-conversions rule exists to prevent, arriving by a different door.
    private var hasPlanned: Bool {
        weeks.contains { $0.planned > 0 }
            && weeks.allSatisfy { $0.plannedSessions == 0 || $0.planned > 0 }
    }

    /// True when the plan does prescribe this discipline, but not in the unit on
    /// screen — the case the caption has to explain rather than leave as a
    /// missing line nobody can account for.
    private var plannedIsInOtherUnit: Bool {
        !hasPlanned && weeks.contains { $0.plannedSessions > 0 }
    }

    private var hasCommute: Bool { metric.hasCommute && weeks.contains { $0.commute > 0 } }

    var body: some View {
        Group {
            if chrome { cardBody } else { panelBody }
        }
        .modifier(CardChrome(on: chrome))
    }

    /// Portrait. Everything stacked, because a phone in portrait has height and
    /// no width — the figures go above the plot and the legend below it.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                Text("WEEKLY VOLUME").font(.caption2.weight(.bold)).tracking(0.5)
                InfoButton(topic: .volume)
                Spacer()
                unitToggle
            }
            .foregroundStyle(Color.dim)

            totalRow
            tiles
            if isTotal { stackChart; stackLegend } else { chart; legend }
            captions
        }
    }

    // MARK: - Landscape
    //
    // WHY THE PANEL IS NOT THE CARD WITH MORE ROOM
    // ---------------------------------------------
    // Rotated, the screen has ~390 pt of height and ~840 pt of width. The card
    // layout spends that height on furniture stacked vertically — a toggle row,
    // a total row, three four-line tiles, a legend and a caption — roughly
    // 210 pt of it, leaving the plot about 140 pt. That is a *smaller* chart
    // than the portrait card gives, in the one orientation you rotate the phone
    // to get a bigger one.
    //
    // So the panel spends WIDTH instead: the four selectors and the unit toggle
    // sit on one line, the legend moves to its own column on the right, and
    // everything that is left over goes to the plot. The figures each lose one
    // line — the second unit moves inline next to the first, and the delta
    // joins the session count — and the window/baseline wording those lines
    // carried moves once into the footer, where it is stated for all four at
    // the same time instead of four times over.
    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelBand
            // Deliberately wider than a normal stack spacing. The plot has no
            // right-hand border, so at 12 pt the last bar and the first swatch
            // were two coloured rectangles with nothing between them and the
            // legend read as one more week of data.
            HStack(alignment: .top, spacing: 22) {
                Group {
                    if isTotal { stackChart } else { chart }
                }
                // Applied here rather than inside the two plots, which are
                // shared with the card. `chartXSelection` reaches the chart
                // through the same environment chain `chartYScale` uses, so
                // wrapping is enough and neither plot has to know.
                .chartXSelection(value: $selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                panelLegend
                    .frame(width: 120, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            panelFooter
        }
    }

    /// Total · Run · Bike · Swim · unit, on one line.
    private var panelBand: some View {
        HStack(alignment: .top, spacing: 8) {
            panelTotal
            ForEach(markers) { m in
                Button { onSelect(m.metric.rawValue) } label: { panelTile(m) }
                    .buttonStyle(.plain)
            }
            unitToggle
                .padding(.top, 12)
        }
    }

    private var panelTotal: some View {
        Button { onSelect(VolumeSelection.total) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "sum").font(.system(size: 8.5))
                    Text("TOTAL")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.3)
                }
                .foregroundStyle(isTotal ? Color.accent4 : Color.dim)

                panelFigure(VolumeSeries.num(totals.value(unit), 1),
                            VolumeSeries.num(totals.value(unit.other), 1))

                HStack(spacing: 4) {
                    Text("all sports")
                        .font(.system(size: 9)).foregroundStyle(Color.dim)
                    Text("·").font(.system(size: 9)).foregroundStyle(Color.dim)
                    Text(totalDeltaLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(totalDeltaColour)
                }
                .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelTileBackground(on: isTotal, tint: Color.accent4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func panelTile(_ m: VolumeMarker) -> some View {
        let on = !isTotal && m.metric == metric
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: m.metric.symbol).font(.system(size: 8.5))
                Text(m.metric.label.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.3)
            }
            .foregroundStyle(on ? m.metric.tint : Color.dim)

            panelFigure(VolumeSeries.num(m.training(unit), m.metric.tileDecimals),
                        VolumeSeries.num(m.training(unit.other), m.metric.tileDecimals))

            HStack(spacing: 4) {
                Text(meta(m))
                    .font(.system(size: 9)).foregroundStyle(Color.dim)
                Text("·").font(.system(size: 9)).foregroundStyle(Color.dim)
                Text(panelDeltaLabel(m))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(deltaColour(m))
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelTileBackground(on: on, tint: m.metric.tint))
        .contentShape(Rectangle())
    }

    /// Both units on one line. On the card these are two rows because there is
    /// no width for them; here there is, and the comparison the unit toggle
    /// exists for is easier to make side by side than stacked.
    private func panelFigure(_ value: String, _ other: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .bold)).monospacedDigit()
                .foregroundStyle(Color.ink)
            Text(unit.short).font(.system(size: 9)).foregroundStyle(Color.dim)
            Text("·").font(.system(size: 9)).foregroundStyle(Color.dim)
            Text(other).font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(Color.dim)
            Text(unit.other.short).font(.system(size: 9)).foregroundStyle(Color.dim)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    /// "vs prev 30 d" is dropped from every tile and stated once in the footer
    /// — four repetitions of the same baseline is three too many, and it is the
    /// part of the line that never changes.
    private func panelDeltaLabel(_ m: VolumeMarker) -> String {
        let d: Double = m.delta(unit)
        if abs(d) < Self.levelThreshold { return "level" }
        let sign: String = d > 0 ? "+" : "−"
        return sign + VolumeSeries.num(abs(d), m.metric.tileDecimals) + " " + unit.short
    }

    private func panelTileBackground(on: Bool, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(on ? tint.opacity(0.10) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(on ? tint : Color.line, lineWidth: 1))
    }

    /// A column, not a row, and with no fill behind it.
    ///
    /// Vertical because it sits beside a stacked column and reads in the same
    /// direction — top of the legend is top of the bar. No background because a
    /// second surface inside the panel would read as a second card; the legend
    /// is an annotation on the plot, not a thing of its own.
    @ViewBuilder
    private var panelLegend: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isTotal {
                ForEach(presentSegments.reversed()) { s in
                    legendRow(s.label, s.fill)
                }
            } else {
                legendRow("Recorded", metric.tint)
                if hasCommute { legendRow("Commute", metric.tint.opacity(0.32)) }
                if hasPlanned { legendRow("Planned", Color.dim) }
            }
            Spacer(minLength: 0)
        }
    }

    private func legendRow(_ name: String, _ colour: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(colour).frame(width: 10, height: 9)
            Text(name)
                .font(.system(size: 10)).foregroundStyle(Color.dim)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// The one line that used to be four: the window, the baseline every delta
    /// is measured against, and whatever the caption has to say — until you put
    /// a finger on the chart, at which point it becomes the week under it.
    ///
    /// WHY THE READOUT IS HERE AND NOT IN THE BAND
    /// --------------------------------------------
    /// The band's four figures are a SELECTOR. Its outline says which series
    /// the chart is drawing, and repainting its numbers as the cursor moves
    /// would make the one control on the panel flicker while you scrub — and
    /// leave you unable to tell a 30-day total from a week's. The footer is
    /// already the context line; a week's figures are context.
    @ViewBuilder
    private var panelFooter: some View {
        if selected != nil, let readout = cursorReadout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(readout.week)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ink)
                ForEach(readout.parts) { part in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(part.tint).frame(width: 8, height: 7)
                        Text(part.text)
                            .font(.system(size: 10)).foregroundStyle(Color.dim)
                    }
                }
                Spacer(minLength: 0)
                Button("Clear") { selected = nil }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .foregroundStyle(Color.dim)
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let text = panelCaption {
                    Text(text).font(.system(size: 9.5)).foregroundStyle(Color.dim)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Text("figures: rolling \(VolumeSeries.markerDays) days · Δ vs previous \(VolumeSeries.markerDays)")
                    .font(.system(size: 9)).foregroundStyle(Color.dim)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: The cursor
    //
    // `chartXSelection` hands back a Date anywhere in the plot, not one of ours,
    // so both lookups take the nearest week by midpoint rather than trying to
    // match. A week is seven days wide and the midpoints are seven days apart,
    // so "nearest" and "the one you are pointing at" are the same answer.

    private var cursorWeek: VolumeWeek? {
        guard let selected else { return nil }
        return weeks.min {
            abs($0.mid.timeIntervalSince(selected))
                < abs($1.mid.timeIntervalSince(selected))
        }
    }

    private var cursorStackWeek: VolumeStackWeek? {
        guard let selected else { return nil }
        return stackWeeks.min {
            abs($0.mid.timeIntervalSince(selected))
                < abs($1.mid.timeIntervalSince(selected))
        }
    }

    private struct ReadoutPart: Identifiable {
        let id: String
        let tint: Color
        let text: String
    }

    private struct Readout {
        let week: String
        let parts: [ReadoutPart]
    }

    /// A week with nothing in it still reports, and says so. Returning nil for
    /// an empty week would make the footer flick back to the caption mid-scrub,
    /// which reads as the cursor having fallen off the chart.
    private var cursorReadout: Readout? {
        let u: String = unit.short
        if isTotal {
            guard let w = cursorStackWeek else { return nil }
            var parts: [ReadoutPart] = [
                ReadoutPart(id: "total", tint: Color.ink,
                            text: VolumeSeries.num(w.total, 1) + " " + u)
            ]
            for s in VolumeSegment.allCases.reversed() where w.value(s) > 0 {
                parts.append(ReadoutPart(id: s.rawValue, tint: s.fill,
                                         text: s.label + " "
                                             + VolumeSeries.num(w.value(s), 1)))
            }
            if parts.count == 1 { parts = [emptyPart] }
            return Readout(week: label(of: w.start), parts: parts)
        }

        guard let w = cursorWeek else { return nil }
        var parts: [ReadoutPart] = []
        if w.training > 0 || (w.commute == 0 && w.planned == 0) {
            parts.append(ReadoutPart(id: "rec", tint: metric.tint,
                                     text: "Recorded "
                                         + VolumeSeries.num(w.training, 1) + " " + u))
        }
        if metric.hasCommute && w.commute > 0 {
            parts.append(ReadoutPart(id: "com", tint: metric.tint.opacity(0.32),
                                     text: "Commute "
                                         + VolumeSeries.num(w.commute, 1) + " " + u))
        }
        if hasPlanned && w.planned > 0 {
            parts.append(ReadoutPart(id: "plan", tint: Color.dim,
                                     text: "Planned "
                                         + VolumeSeries.num(w.planned, 1) + " " + u))
        }
        if parts.isEmpty { parts = [emptyPart] }
        return Readout(week: label(of: w.start), parts: parts)
    }

    private var emptyPart: ReadoutPart {
        ReadoutPart(id: "none", tint: Color.line, text: "nothing recorded")
    }

    /// "w/c 9 Mar" — the Monday, named as the start of a week rather than as a
    /// date, because the column is seven days and a bare "9 Mar" invites you to
    /// read it as one.
    private func label(of monday: Date) -> String {
        "w/c " + DayKey.short(monday)
    }

    private var panelCaption: String? {
        if isTotal { return totalCaption }
        if plannedIsInOtherUnit { return otherUnitCaption }
        return nil
    }

    /// Two words in a capsule. Not a `Picker` — a segmented picker at this size
    /// is taller than the header row it has to live in, and it would push the
    /// chart down by more than the control is worth.
    private var unitToggle: some View {
        HStack(spacing: 0) {
            ForEach(VolumeUnit.allCases) { u in
                let on = u == unit
                Button { onUnit(u) } label: {
                    Text(u.short)
                        .font(.system(size: 10, weight: on ? .bold : .regular))
                        .foregroundStyle(on ? Color.ink : Color.dim)
                        .frame(width: 26, height: 17)
                        .background(Capsule().fill(Color.ink.opacity(on ? 0.13 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1.5)
        .overlay(Capsule().stroke(Color.line, lineWidth: 1))
    }

    /// WHY EVERY STRING HERE IS BUILT OUTSIDE THE VIEW BUILDER
    /// -------------------------------------------------------
    /// Patch 76 first shipped these as `Text("…" + "…" + (cond ? "…" : ""))`
    /// inside the builder and the build failed with "the compiler is unable to
    /// type-check this expression in reasonable time". A long `+` chain is an
    /// overload-resolution problem — `+` has dozens of candidates and each term
    /// multiplies the search — and a ternary inside one multiplies it again,
    /// while a `some View` body gives the checker no annotation to anchor on.
    ///
    /// Assembling the String first, with `String` stated explicitly, collapses
    /// that to nothing. The rule for this file: no string arithmetic inside a
    /// ViewBuilder.
    /// WHAT SURVIVED THE PATCH 95 TRIM, AND WHY
    /// -----------------------------------------
    /// Three captions went in, one state line comes out. Each removal had the
    /// same test: does the sentence tell you a figure, or a rule?
    ///
    ///   totalCaption   opened by naming the unit (a state — kept) and then
    ///                  spent four lines explaining why there is no planned
    ///                  line. That is ⓘ *No planned line, either way*, verbatim.
    ///   otherUnitCaption
    ///                  "No planned line in km — the plan writes this one in
    ///                  hours" is actionable: it tells you which way to flip the
    ///                  toggle. The justification after it is ⓘ *The unit
    ///                  changes the answer*.
    ///   inexactCaption gone entirely. It is ⓘ *Converted figures* almost word
    ///                  for word, and the affected weeks already carry ≈ on
    ///                  screen — the mark IS the caption.
    @ViewBuilder
    private var captions: some View {
        if isTotal {
            caption(totalCaption)
        } else if plannedIsInOtherUnit {
            caption(otherUnitCaption)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2).foregroundStyle(Color.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A state, not an explanation: which unit the stack is drawn in, and that
    /// it holds everything.
    private var totalCaption: String {
        "Everything recorded, in " + unit.label + "."
    }

    private var otherUnitCaption: String {
        "No planned line in " + unit.label + " — the plan writes this one in "
            + unit.other.label + "."
    }

    // MARK: The three markers, which are also the selector
    //
    // Merged deliberately. A separate dropdown would have hidden two of the
    // three figures behind a tap, which is the opposite of what a marker is
    // for. The selected tile is outlined in its own tint; the other two stay
    // legible, because the comparison between disciplines is half the value.

    /// The fourth selector, and the only figure on the card that is always in
    /// both units at once.
    ///
    /// A full-width row rather than a fourth tile: four tiles on a phone leaves
    /// each one too narrow to hold a figure, a unit, a second unit and a delta.
    /// It also reads as a section header for the three beneath it, which is what
    /// it is.
    private var totalRow: some View {
        Button { onSelect(VolumeSelection.total) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(totalHeading)
                    .font(.system(size: 9, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(isTotal ? Color.accent4 : Color.dim)
                Text(VolumeSeries.num(totals.value(unit), 1))
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Color.ink)
                // Both readings, always. The whole point of the unit toggle is
                // that the two answers differ; making you flip the card to see
                // the second one would defeat it.
                Text(totalSecondary)
                    .font(.system(size: 10)).foregroundStyle(Color.dim)
                Spacer(minLength: 4)
                Text(totalDeltaLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(totalDeltaColour)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isTotal ? Color.accent4.opacity(0.08) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isTotal ? Color.accent4 : Color.line, lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var totalHeading: String {
        "TOTAL · \(VolumeSeries.markerDays) DAYS"
    }

    private var totalSecondary: String {
        let other: String = VolumeSeries.num(totals.value(unit.other), 1)
        return unit.short + " · " + other + " " + unit.other.short
    }

    private var totalDeltaLabel: String {
        let d: Double = totals.delta(unit)
        if abs(d) < Self.levelThreshold { return "level" }
        let sign: String = d > 0 ? "+" : "−"
        return sign + VolumeSeries.num(abs(d), 1) + " " + unit.short
    }

    /// DIRECTION IS NOT COLOURED HERE — patch 142.
    ///
    /// This read `d > 0 ? accent4 : slowerColor`: one variable painted in two
    /// oranges that measure ΔE 2.7 apart on dark. A reader with full colour
    /// vision cannot tell them apart, so the channel was spending attention and
    /// returning nothing.
    ///
    /// It is not replaced with a green/amber pair either — see the note under
    /// `deltaColour`. The sign already says which way. Ink says there is a
    /// change worth reading; dim says there is not.
    private var totalDeltaColour: Color {
        abs(totals.delta(unit)) < Self.levelThreshold ? Color.dim : Color.ink
    }

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ForEach(markers) { m in
                    Button { onSelect(m.metric.rawValue) } label: { tile(m) }
                        .buttonStyle(.plain)
                }
            }
            // "tap to switch the chart" dropped: the selected tile is outlined
            // in its own tint, which says it without a sentence, and the hint
            // has been true and unread since patch 60. The window is data.
            Text("rolling \(VolumeSeries.markerDays) days")
                .font(.system(size: 9)).foregroundStyle(Color.dim)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func tile(_ m: VolumeMarker) -> some View {
        // Nothing is outlined while Total is selected — the outline says "this
        // is what the chart is showing", and the chart is showing all of them.
        let on = !isTotal && m.metric == metric
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: m.metric.symbol)
                    .font(.system(size: 8.5))
                Text(m.metric.label.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.3)
            }
            .foregroundStyle(on ? m.metric.tint : Color.dim)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(VolumeSeries.num(m.training(unit), m.metric.tileDecimals))
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Color.ink)
                Text(unit.short)
                    .font(.system(size: 9)).foregroundStyle(Color.dim)
            }

            // The other unit, small. The whole point of the toggle is comparing
            // the two readings, so making you flip the card to see the second
            // number would defeat it.
            Text(otherUnitFigure(m))
                .font(.system(size: 9)).foregroundStyle(Color.dim)
                .lineLimit(1).minimumScaleFactor(0.8)

            Text(meta(m))
                .font(.system(size: 9)).foregroundStyle(Color.dim)
                .lineLimit(1).minimumScaleFactor(0.8)

            Text(deltaLabel(m))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(deltaColour(m))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? m.metric.tint.opacity(0.10) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(on ? m.metric.tint : Color.line, lineWidth: 1)))
        .contentShape(Rectangle())
    }

    /// The second line has to explain a zero, or the card looks broken.
    ///
    /// Every ride in the last thirty days is under the training threshold, so
    /// the bike reads 0.0 h beside 79 km of real riding. "+4.1 h commute" makes
    /// that legible; a bare zero does not.
    private func otherUnitFigure(_ m: VolumeMarker) -> String {
        let v: String = VolumeSeries.num(m.training(unit.other), m.metric.tileDecimals)
        return v + " " + unit.other.short
    }

    private func meta(_ m: VolumeMarker) -> String {
        if m.metric.hasCommute && m.commute(unit) > 0 {
            let v: String = VolumeSeries.num(m.commute(unit), 1)
            return "+ " + v + " " + unit.short + " commute"
        }
        if m.sessions == 0 { return "nothing recorded" }
        let plural: String = m.sessions == 1 ? "" : "s"
        return "\(m.sessions) session" + plural
    }

    private func deltaLabel(_ m: VolumeMarker) -> String {
        let d: Double = m.delta(unit)
        if abs(d) < Self.levelThreshold { return "level on prev 30 d" }
        let sign: String = d > 0 ? "+" : "−"
        let v: String = VolumeSeries.num(abs(d), m.metric.tileDecimals)
        return sign + v + " vs prev 30 d"
    }

    /// Below a tenth of a unit the two windows are the same number to the
    /// precision shown, and an arrow would be claiming a change the figure
    /// above it does not display.
    private static let levelThreshold = 0.05

    /// NEITHER DIRECTION IS A VERDICT, SO NEITHER GETS A COLOUR.
    ///
    /// The original note here said down is drawn warm rather than red, "not in a
    /// red that would call a deliberate rest month a failure" — which is right,
    /// and is the argument against colouring direction at all. Up was the
    /// metric's own tint and down was `slowerColor`, so the pair was already
    /// saying "up is the good one" in everything but name, and on dark the two
    /// were within ΔE 6 of each other on three of the four metrics anyway.
    ///
    /// The sign carries direction. This carries only whether there is one.
    private func deltaColour(_ m: VolumeMarker) -> Color {
        abs(m.delta(unit)) < Self.levelThreshold ? Color.dim : Color.ink
    }

    // MARK: The plot

    /// The whole window, whether or not every week in it holds something.
    ///
    /// WHY THIS IS STATED RATHER THAN LEFT TO SWIFT CHARTS
    /// ---------------------------------------------------
    /// Swift Charts builds the x domain from the marks that were actually
    /// emitted, and the two plots on this card emit differently. `chart` loops
    /// over every week and draws a BarMark for each, so an empty week still
    /// contributes an x value and the axis spans the full window. `stackChart`
    /// filters `value(seg) > 0` before drawing, so a week with nothing in it
    /// produces no mark in any of the six segments and never reaches the
    /// domain at all.
    ///
    /// The result, on the 52-week panel: Run drew Oct–Jul and Total drew
    /// Feb–Jul. Same constant, same data, different axis — switching selector
    /// moved the time span under you, and every bar changed width at the same
    /// time, which reads as "the weeks got bigger". It also made ⓘ's "the panel
    /// shows 52 weeks" false for one of the four selections.
    ///
    /// Both plots now take the domain from the week LIST rather than from what
    /// happened to be drawn. Empty weeks at the left are the honest answer:
    /// there is no data before January, and a chart that hides that by starting
    /// later is answering a different question.
    private var xDomain: ClosedRange<Date> {
        var starts: [Date] = []
        if isTotal {
            for w in stackWeeks { starts.append(w.start) }
        } else {
            for w in weeks { starts.append(w.start) }
        }
        guard let first = starts.min(), let last = starts.max(), first <= last
        else {
            let now = Date()
            return now...now.addingTimeInterval(7 * 86_400)
        }
        // The columns plot at each week's midpoint, so a full week of room at
        // the far end keeps the last bar off the axis edge.
        return first...last.addingTimeInterval(7 * 86_400)
    }

    private var chart: some View {
        Chart {
            ForEach(weeks) { w in
                if metric.hasCommute {
                    BarMark(x: .value("Week", w.offset(-pairOffset)),
                            y: .value("Training", w.training),
                            width: .fixed(barWidth))
                        .foregroundStyle(metric.tint)
                        .cornerRadius(2)
                    BarMark(x: .value("Week", w.offset(pairOffset)),
                            y: .value("Commute", w.commute),
                            width: .fixed(barWidth))
                        .foregroundStyle(metric.tint.opacity(0.32))
                        .cornerRadius(2)
                } else {
                    BarMark(x: .value("Week", w.mid),
                            y: .value("Recorded", w.training),
                            width: .fixed(barWidth * 1.6))
                        .foregroundStyle(metric.tint)
                        .cornerRadius(3)
                }
            }
            if let planStart {
                RuleMark(x: .value("Plan start", planStart))
                    .foregroundStyle(Color.line)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: 1) {
                        Text("plan").font(.system(size: 9)).foregroundStyle(Color.dim)
                    }
            }
            // Declared after the bars so it sits in front of them: where the
            // week came in over plan the reference has to stay readable across
            // the bar rather than behind it.
            if hasPlanned {
                ForEach(weeks.filter { $0.planned > 0 }) { w in
                    LineMark(x: .value("Week", w.mid),
                             y: .value("Planned", w.planned),
                             series: .value("Series", "planned"))
                        .foregroundStyle(Color.dim)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
            // IN FRONT, unlike the PMC panel's cursor, which sits behind its
            // curves. Bars are opaque and fill from the baseline, so a rule
            // behind them is a rule you cannot see on exactly the weeks worth
            // pointing at.
            if let c = cursorWeek {
                RuleMark(x: .value("Week", c.mid))
                    .foregroundStyle(Color.ink.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: chrome ? 5 : 8)) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.35))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? CGFloat.infinity : nil)
        // The "plan" annotation is drawn ABOVE the plot rectangle. Without this
        // it lands in the tiles' caption row and reads as a stray word after
        // "tap to switch the chart" — seen on the swim card at patch 75.
        .padding(.top, 11)
    }

    /// Everything, stacked, in one unit.
    ///
    /// Segments are declared bottom-up in `VolumeSegment.allCases` order, which
    /// is the order Swift Charts stacks them in. Each band is rounded rather
    /// than separated by a surface-coloured gap — Swift Charts has no inter-
    /// segment spacing — and the rounding is cosmetic only: the palette was
    /// validated on hue alone and does not depend on a gap to be readable.
    private var stackChart: some View {
        Chart {
            ForEach(VolumeSegment.allCases) { seg in
                ForEach(stackWeeks.filter { $0.value(seg) > 0 }) { w in
                    BarMark(x: .value("Week", w.mid),
                            y: .value("Volume", w.value(seg)),
                            width: .fixed(barWidth * 1.6))
                        .foregroundStyle(seg.fill)
                        .cornerRadius(1.5)
                }
            }
            if let planStart {
                RuleMark(x: .value("Plan start", planStart))
                    .foregroundStyle(Color.line)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let c = cursorStackWeek {
                RuleMark(x: .value("Week", c.mid))
                    .foregroundStyle(Color.ink.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: stackDomain)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.6))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: chrome ? 5 : 8)) { _ in
                AxisGridLine().foregroundStyle(Color.line.opacity(0.35))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? CGFloat.infinity : nil)
    }

    private var stackDomain: ClosedRange<Double> {
        let floor: Double = unit == .km ? 50 : 5
        var totalsPerWeek: [Double] = []
        for w in stackWeeks { totalsPerWeek.append(w.total) }
        return ChartScale.domain(totalsPerWeek, minimum: floor)
    }

    /// The bands that actually drew, in stack order top-down so the legend reads
    /// the way the column does when you look at it from the top. Filtering on a
    /// non-zero value is also what keeps the strength swatch off the kilometre
    /// chart, where a circuit contributes nothing.
    private var presentSegments: [VolumeSegment] {
        var present: [VolumeSegment] = []
        for s in VolumeSegment.allCases
        where stackWeeks.contains(where: { $0.value(s) > 0 }) {
            present.append(s)
        }
        return present
    }

    private var stackLegend: some View {
        HStack(spacing: 10) {
            ForEach(presentSegments.reversed()) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(s.fill).frame(width: 9, height: 8)
                    Text(s.label).font(.system(size: 9.5)).foregroundStyle(Color.dim)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch("Recorded", metric.tint)
            if hasCommute { swatch("Commute", metric.tint.opacity(0.32)) }
            if hasPlanned { swatch("Planned", Color.dim) }
            Spacer(minLength: 0)
        }
    }

    private func swatch(_ name: String, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(colour).frame(width: 10, height: 3)
            Text(name).font(.caption2).foregroundStyle(Color.dim)
        }
    }
}

/// `.cardStyle()` applied conditionally, without branching the view type at the
/// call site — a plain `if` there gives the two branches different identities
/// and SwiftUI rebuilds the chart from scratch on every toggle.
private struct CardChrome: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        Group {
            if on { content.cardStyle() } else { content }
        }
    }
}
