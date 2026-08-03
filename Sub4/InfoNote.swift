//
//  InfoNote.swift
//  Sub4
//
//  What the numbers on this chart actually are.
//
//  WHY A GLOSSARY AND NOT LONGER CAPTIONS
//  --------------------------------------
//  Every figure in this app already carries a caption, and the captions are at
//  their limit: they have to be readable in the two seconds a glance lasts. "42
//  and 7-day averages of daily training load" is as much as that space can hold,
//  and it does not answer "so what is a 33". The answer needs a paragraph, and a
//  paragraph on a card is a card nobody reads.
//
//  So the explanation moves behind an icon. It costs nothing when you do not
//  want it and it is one tap away when you do — which is the correct trade for
//  something you need twice and then never again.
//
//  THE CONTENT IS DATA
//  -------------------
//  `InfoEntry` values in arrays, not views. Four topics share one renderer, the
//  swatches are the same `SeriesSwatch` the legends and toggle pills use, and
//  adding a fifth topic is an array. The alternative — a bespoke view per chart
//  — guarantees that the day a colour or a threshold changes, some of these go
//  stale silently.
//
//  SCOPE: THE NOTE DESCRIBES WHAT IS ON SCREEN
//  -------------------------------------------
//  The card and the panel do not draw the same marks. The expanded fitness chart
//  shades high-monotony weeks and has a cursor; the card has neither. A note
//  that explains a band you cannot see is worse than no note, because you go
//  looking for it. Every entry therefore carries a scope, and the renderer is
//  told which side it is on.
//
//  TWO PRESENTATIONS, ONE VIEW
//  ---------------------------
//  On a card this is a sheet. Inside the expanded panel it CANNOT be: a sheet or
//  popover presented from in there presents in DEVICE coordinates, not in the
//  panel's rotated frame, so with the phone held sideways the note would arrive
//  at 90° to the chart it belongs to. That is the same trap ExpandableCard
//  documents for its close button. In the panel the note is a ZStack layer
//  inside the rotation, so it is pinned to the graph exactly as everything else
//  in there is.
//

import SwiftUI

// MARK: - The shape of an entry

/// Where an entry is worth showing. The card and the panel draw different marks.
enum InfoScope {
    case card, panel, both

    func applies(inPanel: Bool) -> Bool {
        switch self {
        case .both:  true
        case .card:  !inPanel
        case .panel: inPanel
        }
    }
}

/// A PILL'S COLOUR IS PART OF THE CLAIM
/// ------------------------------------
/// Patch 96 shipped a band reading "Red ≥ 800 km" painted in `.warn`, which is
/// the amber. The pill contradicted its own text — and a glossary that gets a
/// colour wrong is worse than one with no colour, because the sheet is where you
/// go to find out what a colour means.
///
/// `.critical` exists so the sheet can say the second threshold in the second
/// threshold's own hue. The tones now mirror the status palette the rest of the
/// app uses: dim, green, amber, red.
enum InfoTone {
    case neutral, good, warn, critical

    var colour: Color {
        switch self {
        case .neutral:  Color.dim
        case .good:     Color.ctlTint
        case .warn:     Color.slowerColor
        case .critical: Color.spentColor
        }
    }
}

/// One cut-off, as a pill. Used where a word stands for a range — "Fresh",
/// "Very even", "gap" — because the word alone is arbitrary without its number.
struct InfoBand: Identifiable {
    let label: String
    let tone: InfoTone
    var id: String { label }

    init(_ label: String, _ tone: InfoTone = .neutral) {
        self.label = label
        self.tone = tone
    }
}

struct InfoEntry: Identifiable {
    let group: String
    let term: String
    let unit: String?
    let what: String
    let formula: String?
    let bands: [InfoBand]
    let swatch: SeriesSwatch?
    let scope: InfoScope

    var id: String { "\(group)/\(term)" }

    init(_ group: String, _ term: String,
         unit: String? = nil,
         swatch: SeriesSwatch? = nil,
         scope: InfoScope = .both,
         what: String,
         formula: String? = nil,
         bands: [InfoBand] = []) {
        self.group = group
        self.term = term
        self.unit = unit
        self.what = what
        self.formula = formula
        self.bands = bands
        self.swatch = swatch
        self.scope = scope
    }
}

struct InfoGroup: Identifiable {
    let name: String
    let entries: [InfoEntry]
    var id: String { name }
}

// MARK: - The topics

enum InfoTopic: String, Identifiable {
    case fitness, loadPattern, volume, pace, zones, blockProgress, shoes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fitness:     "Fitness — what the numbers are"
        case .loadPattern: "Load pattern — what the numbers are"
        case .volume:      "Weekly volume — what the numbers are"
        case .pace:        "Pace — what the numbers are"
        case .zones:       "Time in zone — what the numbers are"
        case .blockProgress: "Block progress — what the numbers are"
        case .shoes:       "Shoes — what the numbers are"
        }
    }

    /// Groups in the order they should be read, already filtered to the side
    /// being shown and with empty groups dropped.
    ///
    /// The discipline is passed in rather than baked into the topic because it
    /// changes INSIDE the panel — the tile row is the selector — so a topic
    /// fixed at the time the panel group was built would go stale the moment
    /// you tapped Bike. The caller reads the shared key; see `InfoNote`.
    /// `discipline` is nil when Total is selected — there is no one discipline
    /// to describe, and silently falling back to Run would have the note explain
    /// running while the chart shows everything.
    func groups(inPanel: Bool, discipline: Discipline?) -> [InfoGroup] {
        var order: [String] = []
        var byName: [String: [InfoEntry]] = [:]
        for e in entries(discipline) where e.scope.applies(inPanel: inPanel) {
            if byName[e.group] == nil { order.append(e.group) }
            byName[e.group, default: []].append(e)
        }
        return order.map { InfoGroup(name: $0, entries: byName[$0] ?? []) }
    }

    func entries(_ d: Discipline?) -> [InfoEntry] {
        switch self {
        case .fitness:     Self.fitnessEntries
        case .loadPattern: Self.loadPatternEntries
        case .volume:      d.map { Self.volumeEntries($0) } ?? Self.totalEntries
        // Pace has no total — there is no such thing as a total pace, and the
        // panel falls back to Run, so the note follows it there.
        case .pace:        Self.paceEntries(d ?? .run)
        case .zones:       Self.zoneEntries
        case .blockProgress: Self.blockEntries
        case .shoes:       Self.shoeEntries
        }
    }

    /// One line, three ways. Used everywhere the sentence differs by discipline
    /// rather than the whole entry — which is most of Volume and Pace.
    private static func pick(_ d: Discipline,
                             run: String, bike: String, swim: String) -> String {
        switch d {
        case .bike: bike
        case .swim: swim
        default:    run
        }
    }

    // MARK: Fitness

    private static let onChart = "On the chart"
    private static let perDay = "How a day gets its number"
    private static let weekStrip = "The same strip on Week"

    private static let fitnessEntries: [InfoEntry] = [

        InfoEntry(onChart, "Fitness", unit: "CTL · TRIMP",
                  swatch: .line(Color.ctlTint),
                  what: "What your body has banked. It moves slowly on purpose — "
                      + "one hard week barely shifts it, and three quiet weeks "
                      + "drain it.",
                  formula: "42-day exponential average of daily load"),

        InfoEntry(onChart, "Fatigue", unit: "ATL · TRIMP",
                  swatch: .line(Color.atlTint),
                  what: "The same maths over a much shorter memory, so it follows "
                      + "the last few days almost directly.",
                  formula: "7-day exponential average of daily load"),

        InfoEntry(onChart, "Freshness", unit: "TSB",
                  swatch: .area,
                  what: "Not a third series — it is the gap between the two lines. "
                      + "Green above amber means fresh. Yesterday's figures, "
                      + "because today's session has not been recovered from yet — "
                      + "which is also why its change on Today reads a day behind "
                      + "the other two. See Why freshness moves a day late.",
                  formula: "yesterday's fitness − yesterday's fatigue",
                  bands: [InfoBand("Deep < −25", .warn), InfoBand("Loaded −25…−10"),
                          InfoBand("Steady −10…+10"), InfoBand("Fresh ≥ +10", .good)]),

        InfoEntry(onChart, "High monotony", unit: "shaded weeks",
                  swatch: .rule(Color.bandTint), scope: .panel,
                  what: "Weeks with no variation in them, carried over from Load "
                      + "pattern as a background band — a band has no scale, so it "
                      + "can sit behind curves measured in something else.",
                  formula: "7-day monotony at or above 2.0"),

        // The rule is drawn at 40% on the chart, and this swatch was drawn at
        // 100% — advertising a colour the plot never shows, and colliding with
        // the Fatigue line two rows up at ΔE 7.5. Matched to the mark in patch
        // 142, which fixes both: as rendered it measures 37.5 against Fatigue.
        InfoEntry(onChart, "Plan start", unit: "dashed line",
                  swatch: .rule(Color.accent4.opacity(0.4)),
                  what: "27 July 2026, where the marathon block begins. Everything "
                      + "to the left of it is the Ironman base draining away."),

        InfoEntry(onChart, "Cursor", scope: .panel,
                  what: "Drag across the chart to read any single day. Clear "
                      + "returns the readout to the latest one."),

        InfoEntry(perDay, "Load", unit: "TRIMP",
                  what: "One day's training in one number: minutes weighted by how "
                      + "hard your heart was working, so an easy hour and a hard "
                      + "hour are not the same day.",
                  formula: "Banister · Σ min × ΔHR × 0.64 × e^(1.92·ΔHR)"),

        InfoEntry(perDay, "Source", unit: "best available",
                  what: "Four rungs, best first. A ride with no heart rate is "
                      + "scored from power against your FTP instead of being lost.",
                  bands: [InfoBand("HR trace", .good), InfoBand("avg HR"),
                          InfoBand("power"), InfoBand("unscored", .warn)]),

        InfoEntry(perDay, "Day status",
                  what: "Rest is a real zero — nothing was scheduled and nothing "
                      + "happened. Gap is training that could not be scored. Never "
                      + "the same thing, and never shown as one.",
                  bands: [InfoBand("measured", .good), InfoBand("partial"),
                          InfoBand("rest"), InfoBand("gap", .warn)]),

        InfoEntry(perDay, "Filled in", unit: "imputed",
                  what: "A gap day is filled from the trailing week's average so "
                      + "the curve does not dip for a missing file. The footnote "
                      + "counts them, and above a fifth of the window the curve is "
                      + "withheld rather than drawn."),

        InfoEntry(perDay, "Ramp", unit: "CTL/week",
                  what: "How fast fitness is being added — the number a build is "
                      + "actually steered by, rather than something to eyeball off "
                      + "a slope.",
                  bands: [InfoBand("note at +5"), InfoBand("warn at +7", .warn)]),

        InfoEntry(perDay, "Change since yesterday", unit: "Today strip",
                  what: "The small figure under Fitness, Fatigue and Freshness on "
                      + "the Today card. A 42-day average barely moves, so the "
                      + "movement is the point: 30 says where you are, −0.7 says "
                      + "what a rest day did to it. One decimal where the figures "
                      + "above show none, because a day's change is a tenth to a "
                      + "point and a half and rounding it the same way would print "
                      + "+0 on a day that built."),

        InfoEntry(perDay, "No change under Load",
                  what: "The other three are averages, so day against day means "
                      + "something. A day's TRIMP against another day's is Monday "
                      + "rest against Tuesday intervals — a difference of ninety "
                      + "that describes the plan rather than you."),

        InfoEntry(perDay, "The colour on a change",
                  what: "A convention, not a verdict. Green marks the direction "
                      + "usually wanted — fitness up, fatigue DOWN, freshness up — "
                      + "and amber the other. Right through a build block and "
                      + "wrong through a taper, where losing fitness and gaining "
                      + "freshness is the plan working. The strip does not know "
                      + "which of the 34 weeks you are in. The sign is the fact.",
                  bands: [InfoBand("usual direction", .good),
                          InfoBand("the other way", .warn),
                          InfoBand("under 0.05 — level")]),

        InfoEntry(perDay, "Why freshness moves a day late",
                  what: "Freshness is yesterday's fitness minus yesterday's "
                      + "fatigue. So in that row the fitness and fatigue changes "
                      + "describe today, and the freshness change describes "
                      + "yesterday: the morning after a hard run, fatigue falls "
                      + "because today is rest, while freshness drops because "
                      + "yesterday is being paid for. Named rather than corrected "
                      + "— recomputing it same-day would make the change disagree "
                      + "with the figure above it."),

        InfoEntry(weekStrip, "What the figures are", unit: "end of week",
                  what: "A week has no single fitness figure — it has seven — so "
                      + "the numbers printed are where the curve ENDED UP, which "
                      + "for the week you are in is where it stands now. Load is "
                      + "the exception: that one is the week's total, every day "
                      + "added together, imputed days included."),

        InfoEntry(weekStrip, "The change", unit: "across the week",
                  what: "Measured against the day BEFORE the week opened, not "
                      + "against its own Monday — a week's movement includes what "
                      + "that Monday did. Under Fitness this figure is the ramp "
                      + "described above, which until this strip existed was "
                      + "defined in this note and shown nowhere. Guidance is "
                      + "written in roughly +3 to +5 CTL a week, making it the one "
                      + "number in the app directly comparable to something "
                      + "somebody else wrote down.",
                  formula: "last day of the week − day before it opened"),

        InfoEntry(weekStrip, "Fitness falling in a week you trained",
                  what: "Not a contradiction, and usually not an error. Fitness is "
                      + "an average: it rises only when the week's load lands above "
                      + "it and falls when it lands below. A week of 158 TRIMP is "
                      + "23 a day, and against a fitness of 31 that week drains "
                      + "rather than builds — which is what a restart week after a "
                      + "long break looks like by construction. Read the load "
                      + "figure beside it before assuming something is broken."),

        InfoEntry(weekStrip, "Freshness lags here too",
                  what: "The same day late as everywhere else — see Why freshness "
                      + "moves a day late. Both ends of a week's freshness change "
                      + "are yesterday's figures, so that column spans Saturday to "
                      + "Saturday while the two beside it span Sunday to Sunday. A "
                      + "day's offset on a seven-day gap, named here so it is not "
                      + "read as a rounding error."),

        InfoEntry(weekStrip, "The notes underneath", unit: "only when they apply",
                  what: "Two things that change how the totals should be read and "
                      + "are silent everywhere else on that card. Week still "
                      + "running means days are yet to come, so the total is not "
                      + "comparable to a finished week's. Days filled in counts "
                      + "days whose load was imputed rather than measured. Neither "
                      + "line appears when it does not apply, and the last day of "
                      + "a week does not count as still running."),
    ]

    // MARK: Load pattern

    private static let inCaption = "In the caption"
    private static let whyBreaks = "Why the line stops"

    private static let loadPatternEntries: [InfoEntry] = [

        InfoEntry(onChart, "Monotony", unit: "no unit",
                  swatch: .line(Color.ink.opacity(0.72)),
                  what: "How alike the last seven days were. Higher means every "
                      + "day looked like every other one. Rest days are what create "
                      + "the spread, so a week with no day off scores high even at "
                      + "a modest total — that is the mechanism, not a defect.",
                  formula: "mean ÷ SD of the 7 daily loads · population SD, ÷7",
                  bands: [InfoBand("Varied < 1.5", .good), InfoBand("Even 1.5–2.0"),
                          InfoBand("Very even ≥ 2.0", .warn)]),

        InfoEntry(onChart, "Foster 2.0", unit: "threshold",
                  swatch: .rule(Color.bandTint),
                  what: "Foster linked monotony at or above 2.0 with a rise in "
                      + "illness. It is a flag carried from the literature, not a "
                      + "verdict about you."),

        InfoEntry(onChart, "Weekly load", unit: "TRIMP",
                  swatch: .line(Color.accent4), scope: .panel,
                  what: "The seven days added up. Monotony alone cannot say whether "
                      + "an even week was even at 40 a day or at 120, and this is "
                      + "that half of the answer — stacked under it on the same "
                      + "dates rather than sharing its axis.",
                  formula: "sum of the 7 daily loads"),

        InfoEntry(inCaption, "Strain", unit: "TRIMP",
                  what: "Volume and evenness in one figure. It has no threshold on "
                      + "purpose: every published one is a population number, and "
                      + "strain scales with your own volume. So it is ranked "
                      + "against your own trailing history instead — this app says "
                      + "where today sits and never says \"too high\".",
                  formula: "weekly total load × monotony"),

        // Added in patch 95. The caption used to spell the window out — "13th
        // highest of the 43 days in the last 56 that carried one" — and patch 90
        // compressed it to "(13th of 43)" on the promise that the window moved
        // here. It had not. Two numbers with no stated basis is worse than the
        // long sentence was.
        InfoEntry(inCaption, "…of 43", unit: "8 weeks",
                  what: "The rank is taken over the last eight weeks, and the "
                      + "second number is how many of those days actually CARRIED "
                      + "a strain — not how many days were looked at. A week with "
                      + "no spread produces no monotony and therefore no strain, "
                      + "so those days drop out of the comparison rather than "
                      + "counting as a zero and flattering today's figure."),

        InfoEntry(inCaption, "Rest in window", unit: "n of 7",
                  what: "How many of the seven days had nothing eligible on them. "
                      + "The thing monotony is really counting."),

        // TWO CAUSES, NOT ONE. This used to be a single entry naming imputation,
        // which the card then asserted for every gap in the line — including on
        // a series with zero imputed days, where every gap was a rest week.
        InfoEntry(whyBreaks, "No spread to measure", unit: "rest weeks",
                  what: "Monotony is the week's average load divided by its spread. "
                      + "Seven days at the same load have no spread, so the division "
                      + "is undefined — not infinite, undefined — and there is "
                      + "nothing to plot. In practice this is seven days of nothing: "
                      + "a recovery block, or time off. It is not a fault in the "
                      + "data. It is the training, and the gap in the line is the "
                      + "honest drawing of it."),

        InfoEntry(whyBreaks, "A filled-in day", unit: "imputed",
                  what: "A day that could not be scored is filled in at the trailing "
                      + "average, which sits in the middle of the week. That shrinks "
                      + "the spread and pushes monotony up. Drawing through it would "
                      + "put a peak in this curve that describes the fill rather than "
                      + "the training — and a peak is exactly what your eye goes to "
                      + "here. So the line stops and restarts instead. The same day "
                      + "is perfectly acceptable to the fitness curve, which is an "
                      + "average and does not care about spread."),

        InfoEntry(whyBreaks, "The count under the chart",
                  what: "Both causes are counted, and counted apart, because they "
                      + "mean opposite things. \"With no spread\" is a rest week and "
                      + "needs nothing. \"With a filled-in day\" is missing data, and "
                      + "the figure to check it against is Days filled in, in the "
                      + "load diagnostics under Settings."),

        InfoEntry(whyBreaks, "Figures for an earlier week",
                  what: "When the current window cannot be drawn — for either reason "
                      + "above — the headline steps back to the last one that could, "
                      + "and gives that week's end date in amber. The alternative is "
                      + "quietly printing a number the chart has just declined to "
                      + "draw."),
    ]

    // MARK: Weekly volume

    private static let perWeek = "How a week is counted"

    /// Shared by the per-discipline sheet and the Total sheet, because the row
    /// of selectors is the same control on both — and because two copies of one
    /// description is how they end up disagreeing.
    private static let selectorEntry =
        InfoEntry(onChart, "The four figures", unit: "30 days",
                  what: "Total, run, bike and swim over the rolling 30 days, "
                      + "each in both units, each with the change against the 30 "
                      + "days before. They are also the selector: tap one and the "
                      + "chart switches to it. Merged deliberately — a dropdown "
                      + "would have hidden three of the four figures behind a "
                      + "tap. Rotated, they sit on one line and the window they "
                      + "share moves to the footer instead of being repeated "
                      + "four times.")

    private static let cursorEntry =
        InfoEntry(onChart, "Cursor", scope: .panel,
                  what: "Drag across the chart to read a single week. The "
                      + "footer becomes that week's figures, split the same way "
                      + "the column is; Clear puts the window line back. The "
                      + "four figures above do NOT change — they are the "
                      + "selector, and a control that repaints while you scrub "
                      + "is a control you cannot read.")

    /// Also shared. The stack and the per-discipline chart use the same two
    /// constants.
    private static let windowEntry =
        InfoEntry(perWeek, "Window", unit: "26 / 52 weeks",
                  what: "The card shows 26 weeks — far enough back to see the "
                      + "Ironman block. The panel shows 52.")

    /// Read at the moment the sheet opens, never stored.
    ///
    /// Same reason `zoneEntries` is a `var`: an entry that quotes YOUR numbers
    /// has to ask for them now. The volume shares were hard-coded in April 2026
    /// and were still claiming to describe "the last four months" in August,
    /// against a history that had grown to thirteen — see `VolumeSeries.mix`.
    private static var mix: VolumeMix {
        VolumeSeries.mix(ActivityStore.shared.activities)
    }

    /// "8% of everything recorded since July 2025" — assembled here rather than
    /// inline so the entry arrays stay literals and the numbers have one home.
    private static func share(_ percent: Int, _ since: String) -> String {
        "\(percent)% of everything recorded since \(since)"
    }

    private static func volumeEntries(_ d: Discipline) -> [InfoEntry] {
        let unit = d == .bike ? "hours" : "km"
        var out: [InfoEntry] = [

            InfoEntry(onChart, "Recorded", unit: unit,
                      swatch: .line(d.tint),
                      what: pick(d,
                        run: "Every run in the week, added up. No threshold — a "
                           + "2 km shakeout is still running.",
                        bike: "Training rides only, in hours rather than "
                            + "kilometres, because a ride's time is what it costs "
                            + "you. Anything under 10 km is a commute and is drawn "
                            + "beside this column, never inside it.",
                        swim: "Every swim in the week, added up. No threshold — a "
                            + "short technique session is still swimming.")),
        ]

        if d == .bike {
            out.append(
                InfoEntry(onChart, "Commute", unit: "hours",
                          swatch: .line(d.tint.opacity(0.32)),
                          what: "Rides under 10 km. Transport rather than "
                              + "training — kept visible because it is real time "
                              + "on the bike, and kept out of the training column "
                              + "because it would flatter every single week."))
        }

        out += [
            InfoEntry(onChart, "Planned", unit: "reference line",
                      swatch: .rule(Color.dim),
                      what: "What the plan asks for that week. "
                          + pick(d,
                            run: "No run in this plan is optional, so this is "
                               + "everything the week prescribes.",
                            bike: "Optional sessions are excluded. Half the bike "
                                + "work is \"opt.\" Zwift, and counting it would "
                                + "put a line above every week the plan never "
                                + "really asked for.",
                            swim: "Optional sessions are excluded.")),

            InfoEntry(onChart, "Plan start", unit: "vertical line",
                      swatch: .rule(Color.line),
                      what: "The Monday the marathon block begins, labelled "
                          + "\"plan\" above the plot. Drawn only when the window "
                          + "reaches back past it — at the left edge it would say "
                          + "nothing."),

            selectorEntry,
            cursorEntry,

            InfoEntry(perWeek, "The week", unit: "Mon–Sun",
                      what: "ISO weeks, Monday to Sunday. The column and the "
                          + "planned line are both drawn at the week's midpoint, "
                          + "because a bar that centres itself and a line that "
                          + "does not end up half a week apart."),

            windowEntry,

            InfoEntry(perWeek, "Converted figures",
                      what: "Sessions the plan writes in minutes rather than "
                          + "distance are converted at the pace the plan states, "
                          + "so those weeks' planned figures are estimates and the "
                          + "card says so underneath."),
        ]

        if d == .bike {
            out.append(
                InfoEntry(perWeek, "The 10 km line", unit: "threshold",
                          what: "Where a commute stops and a training ride starts. "
                              + "Measured rather than guessed: every commute in "
                              + "the history is 3.2–4.2 km and every training ride "
                              + "is over 20 km, so 10 separates them with a wide "
                              + "margin."))
        }
        return out
    }

    // MARK: Weekly volume — Total

    /// EVERY SWATCH HERE IS READ OFF `VolumeSegment`, NOT RE-STATED
    /// ------------------------------------------------------------
    /// Two of them used to be re-stated and both were wrong by patch 112. The
    /// commute swatch said `Discipline.bike.tint.opacity(0.55)`, which is the
    /// DARK formula written out by hand — on the light scheme the chart draws
    /// the commute in its own purple and the sheet was showing a colour that
    /// appears nowhere on screen. The plan-start rule was drawn in accent4 here
    /// and in `Color.line` there.
    ///
    /// A legend that describes a different chart than the one above it is worse
    /// than no legend. Sourcing the fills from the enum makes that class of bug
    /// impossible rather than merely fixed.
    private static var totalEntries: [InfoEntry] {
        let m = mix
        return [

        InfoEntry(onChart, "The stack", unit: "everything",
                  what: "One column per week, every activity in it, split by "
                      + "what it was. Read the whole column for how much the "
                      + "week held and the bands for what it was made of."),

        InfoEntry(onChart, "Run", swatch: .line(VolumeSegment.run.fill),
                  what: "Every run. No threshold — a 2 km shakeout counts."),

        InfoEntry(onChart, "Swim", swatch: .line(VolumeSegment.swim.fill),
                  what: "Every swim. In hours it is "
                      + share(m.hoursShare(.swim), m.sinceLabel)
                      + "; in kilometres, \(m.kmShare(.swim))%."),

        InfoEntry(onChart, "Strength", swatch: .line(VolumeSegment.strength.fill),
                  what: "Circuits and gym work — what Strava files as weight "
                      + "training, workout, CrossFit or HIIT. In kilometres this "
                      + "band never draws, because a circuit has no distance, "
                      + "and the legend drops it rather than show a colour with "
                      + "nothing under it."),

        InfoEntry(onChart, "Bike", swatch: .line(VolumeSegment.bike.fill),
                  what: "Training rides — 10 km and over."),

        InfoEntry(onChart, "Commute", swatch: .line(VolumeSegment.commute.fill),
                  what: "Rides under 10 km. Kept visible because it is real time "
                      + "on the bike, kept separate because it would flatter "
                      + "every week. Its colour is the one thing in this chart "
                      + "that differs by scheme: on dark it is the bike's own "
                      + "hue at half weight, because a commute is a bike ride "
                      + "and the colour should say so. On light that same fade "
                      + "stopped separating from the bike band where the two "
                      + "meet, so there it takes a hue of its own and loses the "
                      + "family resemblance."),

        InfoEntry(onChart, "Walk & other", swatch: .line(VolumeSegment.other.fill),
                  what: "Everything recorded that the plan has no discipline "
                      + "for — walks, the kayak, the row. Almost all of it is "
                      + "walking: over the thirty days to 31 July, 13.5 hours "
                      + "against 0.9 for the kayak. Real time on your feet, but "
                      + "not training, which is why it is its own band."),

        InfoEntry(onChart, "Plan start", unit: "vertical line",
                  swatch: .rule(Color.line),
                  what: "The Monday the marathon block begins. Unlabelled on the "
                      + "stack — the per-discipline chart writes \"plan\" above "
                      + "it, which there is no headroom for here. Drawn only "
                      + "when the window reaches back past it."),

        selectorEntry,
        cursorEntry,

        InfoEntry(perWeek, "Why strength reads near zero",
                  what: "Because the block has only just started. The plan asks "
                      + "for 56 strength sessions across the 34 weeks — more "
                      + "than the bike's 53 and the swim's 26, second only to "
                      + "running — and the first was 29 July. A thin band now is "
                      + "the plan working, not a gap in the data."),

        InfoEntry(perWeek, "The unit changes the answer",
                  what: "By kilometres, since " + m.sinceLabel + ", the bike is "
                      + "\(m.kmShare([.bike, .commute]))% of everything recorded "
                      + "and running is \(m.kmShare(.run))%. By hours the same "
                      + "history reads bike \(m.hoursShare([.bike, .commute]))%, "
                      + "walk and other \(m.hoursShare(.other))%, running "
                      + "\(m.hoursShare(.run))%, strength "
                      + "\(m.hoursShare(.strength))%. Both are true — a 3 km "
                      + "swim is a small distance and a large hour — so the "
                      + "toggle is not a preference, it is a second question."),

        InfoEntry(perWeek, "No planned line, either way",
                  what: "In hours the plan's swim prescription is missing; in "
                      + "kilometres its bike prescription is. Either way a "
                      + "planned total would be short every week that held the "
                      + "missing sport, and once added up the measured part and "
                      + "the absent part look identical."),

        InfoEntry(perWeek, "The week", unit: "Mon–Sun",
                  what: "ISO weeks, Monday to Sunday, each column drawn at its "
                      + "midpoint."),

        windowEntry,

        InfoEntry(perWeek, "Stack order",
                  what: "Run, Swim, Strength, Bike, Commute, Walk & other from "
                      + "the baseline up. Measured rather than chosen: the "
                      + "obvious order puts run green against bike cyan, which "
                      + "are hard to tell apart where two fills meet, and amber "
                      + "between them fixes it. The residual goes on top because "
                      + "gold against the commute is the pairing that measured "
                      + "best — grey, the usual choice for a leftovers band, "
                      + "failed there on both schemes."),
        ]
    }

    // MARK: Pace

    private static let perSession = "How a session is measured"

    private static func paceEntries(_ d: Discipline) -> [InfoEntry] {
        var out: [InfoEntry] = [

            InfoEntry(onChart, "Each session", unit: pick(d, run: "min/km",
                                                          bike: "km/h",
                                                          swim: "min/100 m"),
                      swatch: .line(d.tint.opacity(0.55)),
                      what: pick(d,
                        run: "One dot per run, in minutes per kilometre. Lower is "
                           + "faster, so improvement moves the cloud DOWN.",
                        bike: "One dot per training ride, in km/h. Higher is "
                            + "faster — the only series in the app where up is "
                            + "the good direction.",
                        swim: "One dot per swim, in minutes and seconds per "
                            + "100 m. Lower is faster.")),
        ]

        if d == .run {
            out.append(
                InfoEntry(onChart, "Target", unit: "5:41 min/km",
                          swatch: .rule(Color.fasterColor),
                          what: "Marathon pace for 4:00:00, dashed. Drawn in FRONT "
                              + "of the dots rather than behind them, because it "
                              + "is the thing they are being compared to, and in "
                              + "the cool hue because it is a goal rather than a "
                              + "description."))
        } else {
            out.append(
                InfoEntry(onChart, "Reference", unit: "your median",
                          swatch: .rule(Color.dim),
                          what: "The plan states no target for this discipline, so "
                              + "the line falls back to your own 90-day median. "
                              + "Recessive grey rather than the run's blue, on "
                              + "purpose: a baseline is a mirror, not a goal."))
        }

        out += [
            InfoEntry(onChart, "Trend", unit: "5-session median",
                      swatch: .line(d.tint), scope: .panel,
                      what: "The median of every five consecutive sessions, "
                          + "plotted at the middle one — a session window, not a "
                          + "calendar one, so a quiet fortnight does not thin the "
                          + "line out. A median rather than a mean, and flagged "
                          + "sessions left out of the pool: one 10:51 leg drags a "
                          + "five-session mean by more than a minute and invents "
                          + "a slump that never happened."),

            InfoEntry(onChart, "Flagged sessions", unit: "hollow dots",
                      swatch: .line(d.tint.opacity(0.8)),
                      what: pick(d,
                        run: "Off the bike — a run on a day that also carried a "
                           + "ride of 50 km or more. Real, kept, and not evidence "
                           + "about your running form.",
                        bike: "Hilly — above 10 m of climb per kilometre. The "
                            + "history splits cleanly: three rides at 14–18 m/km, "
                            + "everything else at 2.2–5.0.",
                        swim: "Unverified — the timing came from Strava rather "
                            + "than Apple Health, so the figure may include rest.")),

            InfoEntry(onChart, "Dot size", unit: "distance", scope: .panel,
                      what: "Bigger dot, longer session. On the card every dot is "
                          + "the same size; at panel width a 5 km recovery run and "
                          + "a 25 km long run are meaningfully different sessions "
                          + "and the area says so."),

            InfoEntry(onChart, "Cursor", scope: .panel,
                      what: "Drag across the chart to read a single session. "
                          + "The nearest one is RINGED as well as ruled — two "
                          + "sessions three days apart are a few points apart on "
                          + "this axis, and a vertical line alone would name a "
                          + "date without saying which dot it meant. The footer "
                          + "gives its pace, its distance and, for a flagged "
                          + "session, the flag: a clamped dot sits at the edge "
                          + "of the scale rather than at its own value, and the "
                          + "readout has to say so."),

            InfoEntry(perSession, "Which sessions count",
                      what: pick(d,
                        run: "Runs of 3 km or more. Below that the pace describes "
                           + "the warm-up rather than the run.",
                        bike: "Training rides only. Commutes are excluded "
                            + "entirely — they are slow by design and would drag "
                            + "the whole cloud down.",
                        swim: "Swims of 200 m or more.")),

            InfoEntry(perSession, "The clock",
                      unit: pick(d, run: "Strava", bike: "Strava", swim: "Apple Health"),
                      what: pick(d,
                        run: "Strava's moving time. The watch auto-pauses, so this "
                           + "is time spent running.",
                        bike: "Strava's moving time, so a coffee stop does not "
                            + "count against the average.",
                        swim: "Apple Health, NOT Strava. Strava counts rest as "
                            + "swimming on pool sets and loses you under the water "
                            + "on open water — it is wrong in both directions. "
                            + "Health holds the length samples, so active time is "
                            + "the union of the intervals you were actually "
                            + "moving. Measured on 30 April: 1:49/100 m active "
                            + "against Strava's 2:04.")),

            InfoEntry(perSession, "The three figures", unit: "90-day median",
                      what: "Median pace for run, bike and swim over 90 days, and "
                          + "the selector for the chart: tap one and the chart "
                          + "switches to it. Ninety rather than the volume card's "
                          + "thirty because a pace median needs sessions, and "
                          + "thirty days currently holds three runs and no swims "
                          + "at all. Rotated, they sit on one line with the "
                          + "reference figure beside them and the window they "
                          + "share moves to the footer."),

            InfoEntry(perSession, "Window", unit: "180 days",
                      what: "The card shows 180 days, or everything if that window "
                          + "holds fewer than eight sessions — three dots is worse "
                          + "than the history that exists. The panel shows all of "
                          + "it."),
        ]
        return out
    }

    // MARK: Time in zone

    private static let whatCounts = "What is counted"
    private static let howMeasured = "How the seconds are measured"

    /// A `var`, not a `let`, because the last entry carries YOUR zone bounds as
    /// bands. Every other topic in this file is a constant; this one reads
    /// `AthleteStore` at the moment the sheet opens, so editing a zone in
    /// Settings changes the glossary as well as the chart.
    ///
    /// The bounds used to be a third caption line on the card. They are a
    /// reference consulted once — the bars carry the zone NAMES, which is what
    /// you actually read the chart with — so a permanent line of five ranges
    /// under every render was three-quarters furniture.
    private static let oneSession = "On a single activity"

    private static var zoneEntries: [InfoEntry] { [

        InfoEntry(whatCounts, "The bars", unit: "hours",
                  what: "Time actually spent with your heart rate in each band, "
                      + "summed across every session in the window. Not sessions, "
                      + "and not a session's average — the real distribution, "
                      + "second by second."),

        InfoEntry(whatCounts, "What this replaced",
                  what: "Until patch 91 this card counted SESSIONS and put each "
                      + "one in the band its average fell in. A session of 40 "
                      + "minutes easy and 20 hard averages into Z3 and landed "
                      + "there whole, having spent no time in Z3 at all. Under a "
                      + "heading reading \"time in zone\" that was not a labelling "
                      + "problem, it was the wrong quantity."),

        InfoEntry(whatCounts, "Which sessions", unit: "plan disciplines",
                  what: "Eligible: runs, rides over 10 km, swims and strength — "
                      + "the disciplines the plan is written in. Commutes and "
                      + "walks are left out on purpose: this answers how your "
                      + "TRAINING intensity distributed, and a ride to work is "
                      + "not training. The fitness curve counts a wider set — "
                      + "anything over 10 km — so the two are deliberately not "
                      + "the same sessions."),

        InfoEntry(whatCounts, "Eligible is not the same as present",
                  unit: "the power gap",
                  what: "A distribution needs a heart-rate trace, and the largest "
                      + "block of training in this history does not have one: the "
                      + "long rides carrying a power meter and NO heart rate. "
                      + "They score perfectly well — watts convert to load — but "
                      + "watts carry no zones, so those hours reach the fitness "
                      + "curve and cannot reach these bars. Strength is absent "
                      + "for a different reason: a circuit covers no distance, "
                      + "and the trace is binned by distance. Both are structural "
                      + "rather than faults, which is why the line under the "
                      + "chart names what was left out instead of only counting "
                      + "it. An untraced RUN is the one worth chasing."),

        InfoEntry(whatCounts, "The window", unit: "30 / 90 days / all",
                  what: "Your choice, in the header. Ninety days is the default: "
                      + "thirty lets one big week dominate, and the whole history "
                      + "describes a block you have already left."),

        InfoEntry(howMeasured, "From the trace", unit: "1 bpm",
                  what: "Each cached heart-rate trace is walked once, and every "
                      + "sample's duration is added to the band its reading falls "
                      + "in. The traces are stored in equal-DISTANCE steps, so a "
                      + "step's duration is its width over its speed — the slow "
                      + "steps are the long ones. Counting samples instead would "
                      + "describe where the route was slow rather than where the "
                      + "clock went, which on a hilly run is a different answer."),

        InfoEntry(howMeasured, "Stopped time", unit: "excluded",
                  what: "Anything under 0.3 m/s is dropped — the stop at the "
                      + "lights, the wait at the crossing. Standing still is not "
                      + "time in a zone. So this total is BELOW your moving time "
                      + "for the same sessions, by design, and a session with long "
                      + "stops contributes less than its duration suggests."),

        InfoEntry(howMeasured, "Sessions not traced", unit: "counted, not spread",
                  what: "A session can still be scored without a trace — from a "
                      + "session average, or from power — and then it has a "
                      + "number but no shape. Spreading its whole duration into "
                      + "one band is exactly the error the old card made, so "
                      + "those sessions are left out and counted under the chart "
                      + "instead. Where there IS a trace the test is the same one "
                      + "the fitness curve applies: good enough to score, good "
                      + "enough to distribute."),

        InfoEntry(howMeasured, "The percentages",
                  what: "Share of the counted time, to the nearest whole point, "
                      + "assigned by largest remainder so they add to exactly 100. "
                      + "Rounding each one independently lands on 99 or 101 often "
                      + "enough that the first thing anyone does is add them up."),

        InfoEntry(howMeasured, "The bands", unit: "bpm",
                  what: "Your own zones, as Strava holds them. Editing them in "
                      + "Settings redraws the chart immediately — the seconds are "
                      + "stored against raw heart rates and only sorted into "
                      + "bands at the moment of drawing, so nothing has to be "
                      + "recomputed.",
                  bands: zoneBands),

        InfoEntry(oneSession, "The same bars, one session", unit: "activity page",
                  what: "The heart-rate card on an activity shows this exact "
                      + "distribution for that session alone, bucketed by the "
                      + "same rule — a bpm on a boundary lands in the same zone "
                      + "there as here, because both read one implementation. "
                      + "Labels there are TIME rather than share: one session "
                      + "has a duration you would say out loud, and a share of a "
                      + "number on the same card is arithmetic asked of you."),

        InfoEntry(oneSession, "Beside the chip, not instead of it",
                  what: "The chip above those bars names the zone the AVERAGE "
                      + "landed in, and the whole argument of this card is that "
                      + "an average is not a distribution — forty minutes easy "
                      + "and twenty hard average into Z3 having spent no time "
                      + "there. The chip is the one-line answer; the bars are "
                      + "the shape behind it."),

        InfoEntry(oneSession, "Why it adds up short", unit: "traced",
                  what: "The line under the bars says how much of the session "
                      + "was traced. Samples below walking speed are dropped by "
                      + "the integral — standing at a crossing is not time in a "
                      + "zone — so the traced total sits under the moving time, "
                      + "and further under the elapsed. Correct rather than a "
                      + "shortfall, and stated on the card because a sum that "
                      + "quietly misses its total reads as a bug."),

        InfoEntry(oneSession, "When the bars are absent",
                  what: "No usable trace, no bars — a strength circuit, a pool "
                      + "swim, a manual entry. The average-HR chip stays when an "
                      + "average exists, because a number without a shape is "
                      + "still a number; bars invented from it would be the "
                      + "session-counting mistake this card was rebuilt to "
                      + "kill."),
    ] }

    /// The athlete's own bounds, as pills. Empty before zones have been fetched,
    /// in which case the entry above still reads correctly on its own.
    private static var zoneBands: [InfoBand] {
        AthleteStore.shared.hrZones.map { InfoBand($0.label + " " + $0.range) }
    }

    // MARK: Block progress

    private static let whatCounted = "What is counted"
    private static let howRead = "How to read it"

    private static let blockEntries: [InfoEntry] = [

        InfoEntry(whatCounted, "Optional sessions", unit: "excluded",
                  what: "The plan marks some sessions \"opt.\" — about half the "
                      + "bike work is optional Zwift. None of it counts, in the "
                      + "distances or in the session tally. Counting it would "
                      + "make the block look larger than the commitment actually "
                      + "is, and adherence would fall every week you skipped "
                      + "something you were never asked to do."),

        InfoEntry(whatCounted, "The bike figure", unit: "commute out",
                  what: "Training rides only. Your commute is real cycling and it "
                      + "is counted on the Weekly volume card, but the plan does "
                      + "not prescribe it, so measuring plan progress against it "
                      + "would credit you for getting to work."),

        InfoEntry(whatCounted, "One unit per sport",
                  what: "Kilometres for running and swimming, HOURS for the bike, "
                      + "SESSIONS for strength — each in the unit the plan itself "
                      + "is written in. The plan never gives a cycling distance, "
                      + "so converting its hours into kilometres would mean "
                      + "inventing an average speed and then comparing your real "
                      + "riding against it."),

        InfoEntry(howRead, "Ahead of / behind plan", unit: "to date",
                  what: "Measured against what the plan has asked for SO FAR, not "
                      + "against the block total. \"12 km behind plan to date\" is "
                      + "something you can act on this week; \"14% of the block\" "
                      + "is only where you are in a 34-week arc."),

        InfoEntry(howRead, "≈ on a total",
                  what: "That sport's block total contains sessions the plan wrote "
                      + "as a duration rather than a distance. They are converted "
                      + "at the pace the plan states for that session, so the "
                      + "total is close but not exact — the same estimator the "
                      + "Weekly volume card uses."),

        InfoEntry(howRead, "The block", unit: "all 34 weeks",
                  what: "Sessions completed against every session the plan asks "
                      + "for, start to race. It moves slowly by design — one "
                      + "perfect week is three per cent — and it is the figure to "
                      + "read once a month, not once a day."),

        InfoEntry(howRead, "This week", unit: "adherence",
                  what: "The same count over the current week, dated so it cannot "
                      + "be confused with the block row above it. Adherence turns "
                      + "amber above 85%. Until patch 98 these two were one "
                      + "unlabelled row that summed every week begun so far — with "
                      + "one week elapsed the block figure and the week figure are "
                      + "identical, which is why nobody noticed."),
    ]

    // MARK: Shoes

    private static let theBar = "The bar"
    private static let theRange = "Why 600 and 800"

    private static var shoeEntries: [InfoEntry] { [

        InfoEntry(theBar, "Lifetime distance", unit: "km",
                  what: "Everything the shoe has run, as Strava holds it — not "
                      + "this block, and not since you started using the app. If "
                      + "a pair was in service before Strava knew about it, that "
                      + "mileage is not here and the bar reads young."),

        InfoEntry(theBar, "How full it is",
                  what: "Measured against 800 km, so a full bar is the top of the "
                      + "usual range rather than an arbitrary maximum. A pair that "
                      + "runs on past it keeps counting in kilometres while the "
                      + "bar stays full."),

        InfoEntry(theRange, "Amber, then red", unit: "600 · 800 km",
                  what: "Road shoes are usually retired somewhere between the two. "
                      + "Amber is not a deadline — it is the point at which the "
                      + "next pair is worth ordering rather than worth thinking "
                      + "about. Red is past the range the literature gives, which "
                      + "does not mean the shoe has failed; it means you are now "
                      + "running on judgement rather than on a number.",
                  bands: [InfoBand("Amber ≥ 600 km", .warn),
                          InfoBand("Red ≥ 800 km", .critical)]),

        InfoEntry(theRange, "Why the range is wide",
                  what: "It depends on the shoe, the surface and the runner — a "
                      + "light runner on tarmac in a firm foam gets far more out "
                      + "of a pair than the reverse. The numbers are a population "
                      + "convention, quoted here for the same reason Foster's 2.0 "
                      + "is: a flag from the literature, not a verdict about you."),

        InfoEntry(theRange, "Why this is on Progress",
                  what: "Wear is a training metric. The plan has over a thousand "
                      + "kilometres of running in it, and the crossing happens "
                      + "mid-block. Buried in a settings screen you would find out "
                      + "afterwards."),
    ] }
}

// MARK: - The list

struct InfoNote: View {

    let topic: InfoTopic
    /// Two columns and the panel's scope when true.
    var inPanel = false

    /// Read HERE rather than baked into the topic, so the note follows the tile
    /// row while the panel stays open. The chart and the note then answer the
    /// same question about the same discipline, which is the whole point of
    /// scoping the note to the view.
    @AppStorage(DisciplineKey.selected) private var disciplineRaw = Discipline.run.rawValue
    /// nil means Total. `Discipline` has no such case, and letting it fall back
    /// to run would print the running glossary over the everything chart.
    private var discipline: Discipline? {
        disciplineRaw == VolumeSelection.total ? nil
            : (Discipline(rawValue: disciplineRaw) ?? .run)
    }

    var body: some View {
        let gs = topic.groups(inPanel: inPanel, discipline: discipline)
        if inPanel {
            let (left, right) = split(gs)
            HStack(alignment: .top, spacing: 20) {
                column(left)
                column(right)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(gs) { g in group(g) }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func column(_ gs: [InfoGroup]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(gs) { g in group(g) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Balanced by ENTRY count, not by group count — the fitness topic is two
    /// groups of very different sizes and splitting on groups would leave one
    /// column half empty.
    private func split(_ gs: [InfoGroup]) -> ([InfoGroup], [InfoGroup]) {
        let total = gs.reduce(0) { $0 + $1.entries.count }
        var left: [InfoGroup] = [], right: [InfoGroup] = [], n = 0
        for g in gs {
            if n < (total + 1) / 2 { left.append(g); n += g.entries.count }
            else { right.append(g) }
        }
        // Everything landed on one side — one group, or one very large one.
        if right.isEmpty, left.count > 1 { right = [left.removeLast()] }
        return (left, right)
    }

    private func group(_ g: InfoGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(g.name.uppercased())
                .font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                .foregroundStyle(Color.dim)
                .padding(.top, 12).padding(.bottom, 6)
            ForEach(Array(g.entries.enumerated()), id: \.element.id) { i, e in
                if i > 0 { Divider().overlay(Color.line.opacity(0.75)) }
                entry(e)
            }
        }
    }

    private func entry(_ e: InfoEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Reserved whether or not there is a mark, so the text of an entry
            // that is drawn and one that is only computed line up.
            Group { if let s = e.swatch { s } }
                .frame(width: 14, alignment: .leading)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(e.term).font(.caption.weight(.semibold))
                    if let u = e.unit {
                        Text(u).font(.system(size: 10)).foregroundStyle(Color.dim)
                    }
                }
                Text(e.what)
                    .font(.caption2).foregroundStyle(Color.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                if let f = e.formula {
                    Text(f)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !e.bands.isEmpty { bands(e.bands) }
            }
        }
        .padding(.vertical, 7)
    }

    /// Two per row, wrapped by hand.
    ///
    /// A real flow layout would pack these tighter and it is not worth a
    /// `Layout` conformance: the widest set here is four pills, the narrowest
    /// container is a panel column at roughly half the panel's width, and two
    /// per row fits both without measuring anything. A single `HStack` does
    /// not — "Deep < −25 · Loaded −25…−10 · Steady −10…+10 · Fresh ≥ +10" is
    /// clipped on a card, and a clipped threshold is a wrong threshold.
    private func bands(_ all: [InfoBand]) -> some View {
        let rows = stride(from: 0, to: all.count, by: 2).map {
            Array(all[$0..<min($0 + 2, all.count)])
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row) { b in
                        Text(b.label)
                            .font(.system(size: 9))
                            .foregroundStyle(b.tone.colour)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().stroke(
                                b.tone == .neutral ? Color.line
                                    : b.tone.colour.opacity(0.5), lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - The icon, and the card presentation

/// The affordance. Sits in a card's header row immediately after the title —
/// never top-right, which on every card on this page is where the headline
/// number lives.
struct InfoButton: View {

    let topic: InfoTopic
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.dim)
                // A 12pt glyph is a 12pt target. This is the tappable area.
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
                // The frame above gives this view the frame's BOTTOM as its
                // baseline, which drops the icon a third of a line in the
                // baseline-aligned Pace header. Put the baseline back roughly
                // where the glyph's own is.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
        }
        .buttonStyle(.plain)
        // A Button inside a card consumes its own tap, so this does NOT also
        // trigger the card's expand gesture. It is the kind of thing that
        // regresses quietly, so it is on the test list.
        .sheet(isPresented: $open) {
            InfoSheet(topic: topic)
                .presentationDetents([.fraction(0.72), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.card)
        }
    }
}

/// The card-side presentation. A real sheet, because on Progress there is no
/// rotation to fight.
struct InfoSheet: View {

    let topic: InfoTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.dangerColor)
                }
                .buttonStyle(.plain)
                Text(topic.title).font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.top, 14)
            InfoNote(topic: topic)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.card)
    }
}

/// The panel-side presentation: a layer inside the rotation, never a sheet.
/// See the header of this file for what happens if that rule is broken.
struct InfoOverlay: View {

    let topic: InfoTopic
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(topic.title).font(.caption.weight(.semibold))
                Spacer()
                Text("tap to close").font(.system(size: 9)).foregroundStyle(Color.dim)
            }
            InfoNote(topic: topic, inPanel: true)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Nearly opaque rather than a blur: the chart underneath is thin bright
        // lines on near-black, and through any translucency they read as text
        // strikethrough.
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.card.opacity(0.985)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { open = false }
    }
}
