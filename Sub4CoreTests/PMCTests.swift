//
//  PMCTests.swift
//  Sub4CoreTests
//
//  The fitness curve, against arithmetic that can be checked by hand —
//  plan step 1.2.
//
//  WHY THIS ONE MATTERS MORE THAN IT LOOKS
//  ---------------------------------------
//  CTL, ATL and TSB are the three numbers the athlete actually trains by, and
//  they are exactly the kind of output nobody can eyeball. A curve that is ten
//  per cent wrong looks exactly like a curve that is right; there is no version
//  of "that number seems off" for a 42-day exponential average. So the only way
//  the maths stays honest through the refactoring in Phases 3, 5 and 6 is a
//  fixture that fails the moment it moves.
//
//  The values below are not copied from the implementation. They are what the
//  recurrence produces on inputs chosen so the answer can be derived on paper —
//  a constant load, a taper, an empty series — which is what makes them a check
//  rather than a snapshot of whatever the code happens to do today.
//
//  ONE MACRO PER EXPRESSION — the house rule this file was written twice to learn
//  ------------------------------------------------------------------------------
//  The first version of this file wrote things like
//
//      #expect(try #require(last.tsb) > 0)
//      let v = try #require(try #require(series.last).monotony)
//
//  which reads well and does not compile: "recursive expansion of macro
//  'require(_:_:sourceLocation:)'". `#expect` and `#require` are macros, and a
//  macro cannot be expanded inside the argument of another one. The nesting also
//  produced "no calls to throwing functions occur within 'try' expression",
//  because after expansion the `try` no longer sat where the throwing call was.
//
//  So every optional is unwrapped on its own line, and the assertion reads the
//  plain value. It is more lines and it is unambiguous, and a failure now points
//  at the unwrap that failed rather than at a compound expression.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct PMCTests {

    // MARK: Inputs

    /// A day with a load and no workouts behind it. `workouts` is empty
    /// throughout: nothing in `PMC.build` reads it, and constructing real
    /// `WorkoutLoad` values here would tie this fixture to a shape Phase 3 is
    /// going to change.
    private func day(_ index: Int, load: Double, state: DayState = .measured) -> DailyLoad {
        DailyLoad(dayKey: Self.key(index), load: load, state: state, workouts: [])
    }

    /// Sequential day keys from a fixed start. A literal date rather than
    /// `Date()`: a test whose input depends on the day it runs is a test that
    /// fails on a Tuesday in March for reasons nobody can reproduce.
    static func key(_ offset: Int) -> String {
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 1
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.date(from: c)!
        let d = cal.date(byAdding: .day, value: offset, to: start)!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: Shape

    @Test("An empty series produces no points")
    func emptyIn() {
        #expect(PMC.build([]).isEmpty)
    }

    @Test("One point comes out per day, in order")
    func onePointPerDay() {
        let days = (0..<10).map { day($0, load: 50) }
        let points = PMC.build(days)
        #expect(points.count == 10)
        #expect(points.map(\.dayKey) == days.map(\.dayKey))
    }

    /// There is no yesterday on the first day, so there is no freshness. A zero
    /// here would be a claim; nil is the absence of one.
    @Test("The first day has no TSB, and the second does")
    func firstDayHasNoFreshness() throws {
        let points = PMC.build([day(0, load: 60), day(1, load: 60)])
        #expect(points.first?.tsb == nil)
        let second = try #require(points.last)
        _ = try #require(second.tsb, "the second day should have a freshness figure")
    }

    // MARK: The recurrence

    /// Both averages converge on the mean daily load. This is the property the
    /// whole model rests on, and the one the walk-versus-training decision turns
    /// on: a habit of N per day pulls CTL to N, whatever the time constant.
    ///
    /// 400 days is roughly ten CTL time constants, so the remaining error is
    /// about e⁻¹⁰ — far below the tolerance used here.
    @Test("A constant load converges to that load")
    func constantLoadConverges() throws {
        let points = PMC.build((0..<400).map { day($0, load: 80) })
        let last = try #require(points.last)
        #expect(abs(last.ctl - 80) < 0.5, "CTL settled at \(last.ctl), expected 80")
        #expect(abs(last.atl - 80) < 0.5, "ATL settled at \(last.atl), expected 80")

        // Freshness is the difference between two averages of the same number.
        let tsb = try #require(last.tsb)
        #expect(abs(tsb) < 1.0, "freshness was \(tsb) on a flat series")
    }

    /// ATL has the shorter time constant, so it has to move further and faster
    /// on the way up. If these two ever swap, freshness inverts and the app
    /// starts calling a hard block "fresh".
    @Test("Fatigue rises faster than fitness, and freshness goes negative")
    func atlLeadsCtlOnTheWayUp() throws {
        let points = PMC.build((0..<14).map { day($0, load: 100) })
        let last = try #require(points.last)
        #expect(last.atl > last.ctl, "ATL \(last.atl) did not lead CTL \(last.ctl)")

        let tsb = try #require(last.tsb)
        #expect(tsb < 0, "two weeks of hard training produced freshness of \(tsb)")
    }

    /// And the reverse: stop, and fatigue falls away while fitness lingers. This
    /// is the taper, and it is the single most consequential behaviour in the
    /// model for a marathon plan.
    @Test("Rest sheds fatigue faster than fitness, and freshness turns positive")
    func tsbGoesPositiveOnTaper() throws {
        var days = (0..<60).map { day($0, load: 100) }
        days += (60..<74).map { day($0, load: 0, state: .rest) }
        let last = try #require(PMC.build(days).last)

        #expect(last.atl < last.ctl)

        let tsb = try #require(last.tsb)
        #expect(tsb > 0, "a fortnight of rest produced freshness of \(tsb)")

        // Fitness decays too, just slowly. It must not have vanished.
        #expect(last.ctl > 30, "CTL collapsed during a two-week taper: \(last.ctl)")
    }

    /// Monotonic in the input: more load can never mean less fitness. A cheap
    /// assertion that catches a sign error anywhere in the recurrence.
    @Test("More load never produces less fitness")
    func moreLoadMeansMoreFitness() throws {
        let light = try #require(PMC.build((0..<60).map { day($0, load: 40) }).last)
        let heavy = try #require(PMC.build((0..<60).map { day($0, load: 90) }).last)
        #expect(heavy.ctl > light.ctl)
        #expect(heavy.atl > light.atl)
    }

    // MARK: Warm-up honesty

    /// The curve is not readable before the average has filled, and the app says
    /// so rather than printing a number that looks like the others. The flag has
    /// to be set at the head of the series and clear afterwards.
    @Test("Early days are flagged as warm-up and later ones are not")
    func warmupIsFlagged() throws {
        let points = PMC.build((0..<120).map { day($0, load: 70) })

        let first = try #require(points.first)
        let last = try #require(points.last)
        #expect(first.isWarmup)
        #expect(last.isWarmup == false)

        // Contiguous: a warm-up flag that switched back on halfway through would
        // mean the two assertions above are passing by accident.
        let firstSettled = try #require(points.firstIndex { !$0.isWarmup })
        let lastWarm = try #require(points.lastIndex { $0.isWarmup })
        #expect(lastWarm < firstSettled,
                "warm-up resumed after settling: last warm \(lastWarm), first settled \(firstSettled)")
    }

    // MARK: Rest is a zero, a gap is not

    /// The distinction the whole engine is built to preserve. A rest day is a
    /// real zero and must lower the averages; a gap is a day whose training could
    /// not be scored, and treating it as zero would invent a rest week out of a
    /// missing heart-rate trace.
    @Test("A rest day is scored as zero and a gap is imputed instead")
    func restIsZeroGapIsImputed() throws {
        var withRest = (0..<30).map { day($0, load: 100) }
        withRest.append(day(30, load: 0, state: .rest))

        var withGap = (0..<30).map { day($0, load: 100) }
        withGap.append(day(30, load: 0, state: .gap))

        let rest = try #require(PMC.build(withRest).last)
        let gap = try #require(PMC.build(withGap).last)

        #expect(rest.imputed == false)
        #expect(gap.imputed, "a gap day was taken at face value as a zero")

        // The imputed day stands in with recent load, so it must not drag the
        // averages down the way a genuine rest day does.
        #expect(gap.atl > rest.atl,
                "a gap depressed fatigue as though nothing had happened")
    }

    // MARK: Monotony

    /// Seven identical days have zero standard deviation, and the ratio is then
    /// UNDEFINED rather than infinite. `MonotonyPoint.monotony` is optional for
    /// exactly this reason, and nil is the correct answer — the same distinction
    /// the load engine makes everywhere else between a measurement of zero and
    /// the absence of a measurement.
    ///
    /// An implementation returning `.infinity` would satisfy "did not crash" and
    /// then print an infinity on the Progress tab, so the assertion is on nil.
    @Test("A perfectly even week yields no monotony rather than an infinite one")
    func monotonyIsUndefinedOnAnEvenWeek() {
        let points = PMC.build((0..<20).map { day($0, load: 50) })
        let m = Monotony.series(points)
        #expect(m.isEmpty == false)
        for p in m {
            #expect(p.monotony == nil,
                    "an even week produced monotony \(String(describing: p.monotony))")
            if let v = p.monotony { #expect(v.isFinite) }
            if let s = p.strain { #expect(s.isFinite) }
        }
    }

    @Test("Monotony needs a full window before it says anything")
    func monotonyNeedsAWeek() {
        let short = PMC.build((0..<5).map { day($0, load: 50) })
        #expect(Monotony.series(short).isEmpty)
    }

    /// Monotony is mean ÷ spread, so a nearly-even week scores HIGH and a wildly
    /// varied one scores low. If this inverts, the warning fires on exactly the
    /// weeks it should stay quiet for — and it would still look plausible, which
    /// is why it needs a test rather than a glance.
    ///
    /// Both weeks have spread, so both figures exist; the even-week case above
    /// covers the nil path separately.
    @Test("A nearly-even week scores higher monotony than a varied one")
    func evenWeekIsMoreMonotonous() throws {
        let steady = PMC.build((0..<14).map { day($0, load: $0 % 2 == 0 ? 60 : 62) })
        let varied = PMC.build((0..<14).map { day($0, load: $0 % 3 == 0 ? 140 : 20) })

        let steadyLast = try #require(Monotony.series(steady).last)
        let variedLast = try #require(Monotony.series(varied).last)

        let s = try #require(steadyLast.monotony)
        let v = try #require(variedLast.monotony)
        #expect(s > v, "steady week scored \(s), varied week \(v)")
    }
}
