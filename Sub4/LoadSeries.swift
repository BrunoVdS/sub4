//
//  LoadSeries.swift
//  Sub4
//
//  Every day from the cutoff to today, with a load on it — extracted from
//  `LoadStore.recompute` at patch 314. D6c slice 3, part one. ADR-0003 §12.58.
//
//  WHY THIS IS A FUNCTION NOW AND WAS EIGHT SINGLETON READS BEFORE
//  ---------------------------------------------------------------
//  `LoadStore.recompute` walked four hundred days and, inside the walk, reached
//  into `ActivityStore`, `DetailStore`, `ConstantsStore`, `AthleteStore`,
//  `NotesStore`, `PlanStore`, `Matcher` and `HealthStore`. That was fine while
//  there was one caller and one set of stores.
//
//  D6c slice 3 needs the SAME series built from the database's activities and
//  traces. A second implementation of a four-hundred-day walk over a
//  four-rung scoring engine is the mistake §12.43 cost three patches to learn,
//  and here it would be silent: two plausible fitness curves differing on a
//  handful of days, with nothing able to say which is right.
//
//  > **A derivation with one caller looks like part of that caller. It stops
//  > being that the moment something else must agree with it.**
//
//  Third time in five patches — `isKept` and `dedup` at 310, `byDay` at 312,
//  `recordedByWeek` at 313. This is the biggest of the four, because thirteen
//  files read what it produces.
//
//  AND IT IS TESTABLE FOR THE FIRST TIME
//  -------------------------------------
//  `recompute` has never had a unit test, and could not have one: it read eight
//  singletons, so a test would have had to stand all eight up. `PMC.build` has
//  twelve tests because it was already a pure function of its input. This is
//  now the same shape, and `LoadSeriesTests` is what that buys.
//
//  WHAT IT STILL DOES NOT DECIDE
//  -----------------------------
//  It does not compute the power factor, the sRPE mapping, or which heart rate
//  Apple Health has. Those are gathered by the caller and handed in, because
//  each needs stores this has no business knowing about — and because slice 3's
//  whole method is to hold them identical on both sides while the activities
//  and traces vary.
//

import Foundation

@MainActor
enum LoadSeries {

    /// Everything a day's load depends on besides the activities themselves.
    ///
    /// A BAG OF ARGUMENTS, NOT A VALUE. It is not `Equatable` and is not meant
    /// to be compared; it exists so `build` has no hidden inputs, which is the
    /// property that makes a twin possible at all.
    ///
    /// `hrRest` is a closure rather than a dictionary because the rule behind
    /// it — that month, then the nearest month within three, then the override
    /// — lives in `ConstantsStore` and belongs there. Copying it here to get a
    /// flat dictionary would be the exact mistake this file exists to avoid.
    struct Inputs {
        var hrMax: Int?
        /// By day key. Nil means genuinely unknown for that day, and nothing
        /// should be computed from it.
        var hrRest: (String) -> Int?
        /// The sex coefficient in the TRIMP exponent.
        var w: Double
        var ftp: Int?
        /// Measured once per rebuild from rides carrying both a heart rate and
        /// a meter. Nil until there are enough of them.
        var powerFactor: PowerFactor?
        /// sRPE by activity id — carried into the row, never summed into the
        /// day. See the note at the top of `TrainingLoad.swift`.
        var srpe: [String: Double] = [:]
        /// Apple Health's average heart rate by activity id, where Strava has
        /// none. THE ONE INPUT NO DATABASE WILL EVER HOLD — it is a cache of
        /// somebody else's store, which is why slice 3 holds it identical on
        /// both sides rather than pretending it could vary.
        var healthAverageHR: [String: Double] = [:]
        /// Traces by activity id.
        var streams: [String: ActivityStreams] = [:]
    }

    /// The runaway guard, moved with the loop it protects.
    ///
    /// It exists because an unparseable day key used to leave `key` unchanged,
    /// which appended the same day three thousand times — duplicate `ForEach`
    /// ids and a day counted three thousand times in every total. `build` fails
    /// closed the same way it always did.
    static let maximumDays = 3_000

    /// EVERY DAY, INCLUDING THE EMPTY ONES.
    ///
    /// The fitness curve is an exponential moving average, and an average is
    /// only defined if the series has no holes. A rest day is a real zero and
    /// has to be present as one; the single most common way a home-rolled
    /// fitness curve goes wrong is treating "no row" as "no load" and quietly
    /// shortening the window.
    ///
    /// And a zero is not a gap. Four states, and the distinction is the whole
    /// point of the type:
    ///
    ///   `measured`  every eligible activity produced a number
    ///   `partial`   something happened that could not be scored — a floor
    ///   `rest`      nothing eligible happened. A true zero, and it belongs
    ///   `gap`       things happened and none of them scored. NOT a zero
    static func build(from: String,
                      to: String,
                      byDay: [String: [Activity]],
                      inputs: Inputs) -> [DailyLoad] {

        var out: [DailyLoad] = []
        var key = from
        var guardCount = 0

        while key <= to, guardCount < maximumDays {
            guardCount += 1

            let eligible = (byDay[key] ?? []).filter(\.isLoadEligible)
            let hrRest = inputs.hrRest(key)

            var loads: [WorkoutLoad] = []
            for a in eligible {
                loads.append(LoadEngine.load(for: a,
                                             streams: inputs.streams[a.id],
                                             hrMax: inputs.hrMax,
                                             hrRest: hrRest,
                                             w: inputs.w,
                                             srpe: inputs.srpe[a.id],
                                             ftp: inputs.ftp,
                                             powerFactor: inputs.powerFactor,
                                             healthAverageHR: inputs.healthAverageHR[a.id]))
            }

            let scored = loads.filter(\.isScored)
            let state: DayState
            if loads.isEmpty                    { state = .rest }
            else if scored.isEmpty              { state = .gap }
            else if scored.count == loads.count { state = .measured }
            else                                { state = .partial }

            // ONLY THE SCORED TRIMPS ARE SUMMED, and the state carries the
            // rest. A day's total that quietly included a zero from something
            // nothing could score would read identically to a lighter day.
            out.append(DailyLoad(dayKey: key,
                                 load: scored.reduce(0) { $0 + $1.trimp },
                                 state: state,
                                 workouts: loads))

            guard let next = nextDay(key), next > key else { break }
            key = next
        }
        return out
    }

    /// The next ISO day, or nil if the key cannot be parsed. `nil` is what
    /// makes `build` stop rather than repeat itself.
    static func nextDay(_ key: String) -> String? {
        guard let d = DayKey.date(key),
              let n = Calendar(identifier: .iso8601)
                  .date(byAdding: .day, value: 1, to: d) else { return nil }
        return DayKey.key(n)
    }
}
