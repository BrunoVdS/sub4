//
//  LaunchTimingTests.swift
//  Sub4CoreTests
//
//  Patch 421, ADR-0003 §12.166. What the launch cost, measured.
//
//  THE MEASUREMENT IS SPLIT FROM THE CLOCK ON PURPOSE, and it is 417's lesson
//  (§12.162.3) applied before it had to be paid for again: a test that waits
//  for a real timer proves the timer fired, not that the arithmetic is right,
//  and it does it slowly and flakily. `StallWatch` takes gaps as numbers and
//  `LaunchTiming` formats readings as a value, so every state either can print
//  is reachable here. What only a device can produce is named at the bottom.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct LaunchTimingTests {

    // MARK: The stall arithmetic

    @Test("A timer firing exactly on time records no stall")
    func onTimeIsZero() {
        var w = StallWatch()
        for i in 0..<10 {
            w.tick(gap: 1.0 / 60, nominal: 1.0 / 60, at: Double(i + 1) / 60)
        }
        #expect(w.samples == 10)
        #expect(w.longest == 0)
        // NOTHING TO PLACE, and that is not the same as a place nobody
        // recorded — patch 424.
        #expect(w.longestBeganAt == nil)
    }

    @Test("The longest gap wins, not the last one")
    func theLongestGapWins() {
        var w = StallWatch()
        w.tick(gap: 0.020, nominal: 0.016, at: 0.020)
        w.tick(gap: 0.900, nominal: 0.016, at: 0.920)
        w.tick(gap: 0.017, nominal: 0.016, at: 0.937)
        #expect(w.samples == 3)
        // 0.900 - 0.016. The nominal interval is subtracted, so the figure is
        // time the main thread was NOT available rather than wall time.
        #expect(abs(w.longest - 0.884) < 0.0001)
    }

    @Test("A tick that beats its deadline does not make the stall negative")
    func earlyDoesNotGoNegative() {
        var w = StallWatch()
        w.tick(gap: 0.001, nominal: 0.016, at: 0.001)
        #expect(w.longest == 0)
        #expect(w.longestBeganAt == nil)
    }

    // MARK: WHERE the stall was — patch 424

    /// **THE GAP BEGAN WHERE IT BEGAN, NOT WHERE IT WAS NOTICED.**
    ///
    /// A timer only learns about a stall when it finally fires, which is at
    /// the END of it. Recording that instant would put every stall a full
    /// stall-length too late — and for the 1.05 s stall 423 found, a whole
    /// second is the difference between "inside the detail store's
    /// construction" and "after it". §12.171.
    @Test("The stall is placed at its start, not at the tick that noticed it")
    func theStallIsPlacedAtItsStart() throws {
        var w = StallWatch()
        w.tick(gap: 0.016, nominal: 0.016, at: 0.016)
        w.tick(gap: 1.050, nominal: 0.016, at: 1.066)
        let began = try #require(w.longestBeganAt)
        // 1.066 - 1.050. NOT 1.066, which is when the timer found out.
        #expect(abs(began - 0.016) < 0.0001)
    }

    @Test("A later, smaller stall does not move the recorded start")
    func aSmallerStallDoesNotMoveIt() throws {
        var w = StallWatch()
        w.tick(gap: 1.050, nominal: 0.016, at: 1.050)
        w.tick(gap: 0.200, nominal: 0.016, at: 5.000)
        #expect(abs(w.longest - 1.034) < 0.0001)
        let began = try #require(w.longestBeganAt)
        #expect(abs(began - 0.0) < 0.0001)
    }

    @Test("A start is never negative, however the arithmetic lands")
    func theStartIsNeverNegative() throws {
        var w = StallWatch()
        // A gap longer than the offset it ended at cannot happen on a real
        // clock; the clamp is what stops it printing a launch that began
        // before the app did.
        w.tick(gap: 2.0, nominal: 0.016, at: 1.0)
        let began = try #require(w.longestBeganAt)
        #expect(began == 0)
    }

    // MARK: The three states — §12.15

    /// `notYet` and `couldNotMeasure` are opposite facts and a reader acts
    /// differently on each. Neither may print as a number.
    @Test("Not yet and could not measure are different sentences")
    func theThreeStatesAreDistinguishable() {
        #expect(LaunchTiming.Reading.seconds(1.5).text == "1.500 s")
        #expect(LaunchTiming.Reading.notYet("the window closes at 10 s").text
                == "not yet — the window closes at 10 s")
        #expect(LaunchTiming.Reading.couldNotMeasure("sysctl refused").text
                == "could not measure — sysctl refused")
        #expect(LaunchTiming.Reading.notYet("x").value == nil)
        #expect(LaunchTiming.Reading.couldNotMeasure("x").value == nil)
        #expect(LaunchTiming.Reading.seconds(0).value == 0)
    }

    /// THE NEGATIVE CONTROL FOR THE WHOLE INSTRUMENT. A launch that cost
    /// nothing and a launch nobody could measure must not read alike.
    @Test("A zero reading and an unmeasurable one do not read alike")
    func zeroIsNotTheSameAsUnknown() {
        var fast = LaunchTiming()
        fast.beforeOurFirstLine = .seconds(0)
        var blind = LaunchTiming()
        blind.beforeOurFirstLine = .couldNotMeasure("sysctl refused")
        #expect(fast.diagnosticLines != blind.diagnosticLines)
        #expect(fast.diagnosticLines.contains { $0.contains("0.000 s") })
    }

    // MARK: The window

    @Test("An open window reports a floor, not a maximum")
    func anOpenWindowDoesNotClaimAMaximum() {
        var t = LaunchTiming()
        t.longestStall = .notYet("the window closes at 10 s")
        t.windowClosed = false
        t.windowSeconds = 4
        let lines = t.diagnosticLines
        #expect(lines.contains { $0.contains("still open") })
        #expect(t.line.contains("still measuring"))
        // The floor must never be printed as though it were the answer.
        #expect(!t.line.contains("longest stall"))
        #expect(!t.isComplete)
    }

    @Test("A closed window prints the stall and says the window closed")
    func aClosedWindowPrintsTheStall() {
        var t = LaunchTiming()
        t.longestStall = .seconds(0.88)
        t.windowClosed = true
        t.windowSeconds = 10
        #expect(t.line.contains("longest stall 0.880 s"))
        #expect(t.diagnosticLines.contains { $0.contains("closed — 10.0 s") })
    }

    /// The paste has to carry the offset, or the whole of 424 stops at the
    /// value type.
    @Test("The stall line names when the stall began")
    func theStallLineNamesWhenItBegan() throws {
        var t = LaunchTiming()
        t.longestStall = .seconds(1.046)
        t.longestStallBeganAt = 0.212
        t.stallSamples = 536
        let line = try #require(t.diagnosticLines.first {
            $0.contains("longest main-thread stall")
        })
        #expect(line.contains("1.046 s"))
        #expect(line.contains("536 samples"))
        #expect(line.contains("beginning 0.212 s after our first line"))
    }

    /// **A STALL OF NOTHING HAS NO BEGINNING, AND SAYS SO** — §12.15. Printed
    /// as `0.000 s` it would be indistinguishable from a stall at the instant
    /// of launch, which is the one place a launch stall is most likely to be.
    @Test("No stall says so rather than placing one at zero")
    func noStallSaysSo() throws {
        var t = LaunchTiming()
        t.longestStall = .seconds(0)
        t.longestStallBeganAt = nil
        let line = try #require(t.diagnosticLines.first {
            $0.contains("longest main-thread stall")
        })
        #expect(line.contains("no tick ran late"))
        #expect(!line.contains("beginning"))
    }

    /// A window the app left is not a stall measurement at all.
    @Test("Backgrounding poisons the stall figure and says so")
    func backgroundingIsNotAStall() {
        var t = LaunchTiming()
        t.longestStall = .seconds(6.0)
        t.windowClosed = true
        t.leftTheApp = true
        #expect(t.line.contains("backgrounded"))
        #expect(!t.line.contains("longest stall"))
        #expect(t.diagnosticLines.contains { $0.contains("YES") })
        #expect(!t.isComplete, "a poisoned window must not report as complete")
    }

    // MARK: Unconditional

    /// §12.54.2. Every figure prints on every launch, including the zeros —
    /// a row that vanishes cannot be told from one nobody wired in.
    @Test("Every reading prints even when nothing has been measured")
    func everyReadingPrintsUnconditionally() {
        let lines = LaunchTiming().diagnosticLines
        #expect(lines.count == 7)
        for needle in ["before our first line",
                       "our first line to the first view",
                       "first free main-thread turn",
                       "longest main-thread stall",
                       "stall window",
                       "left the app during the window"] {
            #expect(lines.contains { $0.contains(needle) },
                    "the launch paste lost: \(needle)")
        }
    }

    @Test("isComplete needs every figure and a clean window")
    func completeMeansComplete() {
        var t = LaunchTiming()
        t.beforeOurFirstLine = .seconds(0.4)
        t.firstLineToFirstView = .seconds(0.1)
        t.firstFreeTurn = .seconds(1.2)
        t.longestStall = .seconds(0.88)
        t.windowClosed = true
        #expect(t.isComplete)

        // Each of these on its own must withhold it.
        var open = t; open.windowClosed = false
        #expect(!open.isComplete)
        var left = t; left.leftTheApp = true
        #expect(!left.isComplete)
        var blind = t; blind.beforeOurFirstLine = .couldNotMeasure("sysctl refused")
        #expect(!blind.isComplete)
    }

    // MARK: The process table

    /// THE ONE READING THAT TOUCHES THE KERNEL. It can fail, and the failure
    /// has to be a sentence rather than a zero — but on any device or simulator
    /// that runs this suite it succeeds, so the assertion is a range.
    @Test("The process start time is readable and plausible")
    func theProcessStartIsReadable() throws {
        let reading = ProcessStart.secondsUntilNow()
        guard case .seconds(let seconds) = reading else {
            Issue.record("the process table could not be read: \(reading)")
            return
        }
        // The test process has been alive for some non-zero time and less than
        // the guard's ceiling.
        #expect(seconds > 0)
        #expect(seconds < 600)
    }
}

/// **ASK THE COLLECTOR, NOT ITS INGREDIENTS — §12.164.1.**
///
/// Every test above proves a part: the arithmetic, the three states, the
/// poisoned window. Reverting `LaunchClock` to a stub that measures nothing
/// would leave all of them green, which is exactly the hole 419 fell into ten
/// patches ago. These three ask `LaunchClock` itself whether it collected
/// anything, and each one fails if a different wire is cut.
///
/// SERIALIZED, because `LaunchClock` is process-wide state and 417's protection
/// suite was flaky for precisely that reason (§12.162).
@Suite(.serialized)
@MainActor
struct LaunchClockTests {

    @Test("The clock samples the process start time")
    func itSamplesTheProcessStart() {
        LaunchClock.appStarted()
        #expect(LaunchClock.timing.beforeOurFirstLine.value != nil,
                "appStarted did not sample the kernel's process start time")
    }

    @Test("The clock records the first view")
    func itRecordsTheFirstView() {
        LaunchClock.appStarted()
        LaunchClock.firstViewAppeared()
        #expect(LaunchClock.timing.firstLineToFirstView.value != nil,
                "firstViewAppeared did not reach the clock")
    }

    /// THE ONE THAT CATCHES A TIMER NOBODY STARTED. Cut `t.resume()`, or the
    /// call to `watchTheMainThread`, and this is the only assertion in the file
    /// that notices.
    @Test("The main-thread watch actually fires")
    func theWatchFires() async {
        LaunchClock.appStarted()
        // Several frames at 60 Hz. The timer cannot fire sooner and does not
        // need longer.
        try? await Task.sleep(for: .milliseconds(250))
        let t = LaunchClock.timing
        #expect(t.stallSamples > 0, "the 60 Hz watch never ticked")
        #expect(t.firstFreeTurn.value != nil,
                "the watch ticked without recording the first free turn")
    }
}

// WHAT ONLY A DEVICE CAN PRODUCE — §12.162.3's habit, written down here so the
// next reader does not go looking for it in the suite:
//
//   * a real `before our first line` for THE APP. The figure this suite reads
//     belongs to the test runner, whose start-up is nothing like the app's.
//   * a non-zero `longest main-thread stall`. Nothing in the suite blocks the
//     main queue for a frame, and a synthetic block would measure the block.
//   * the interaction between the two: whether the stall lands inside
//     `DetailStore`'s construction or somewhere nobody has looked.
//
// docs/DEVICE-CAMPAIGN-B34.md is where those are taken.
