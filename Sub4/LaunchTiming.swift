//
//  LaunchTiming.swift
//  Sub4
//
//  WHAT THE LAUNCH COST, MEASURED — patch 421, ADR-0003 §12.166.
//
//  `Detail store built: 0.880 s` is a CONSTRUCTION timestamp. It says what one
//  read cost; it does not say when the app began answering. Topic 3 asked for
//  interaction evidence instead, and the campaign's answer was a person with a
//  stopwatch saying "under 2 seconds" — which is true, unfalsifiable at that
//  precision, and cannot be compared with the next reading.
//
//  FOUR FIGURES, AND THE FOURTH IS THE ONE THAT MATTERS.
//
//  1. `before our first line` — the kernel started the process, then dyld,
//     the runtime and SwiftUI ran before any code in this repository did.
//     Read from `kinfo_proc.p_starttime` via sysctl, SAMPLED IN `Sub4App.init`
//     and not when the screen is opened, or it would measure how long ago the
//     app was launched.
//  2. `our first line to the first view` — our own setup.
//  3. `first free main-thread turn` — the first moment a block queued at
//     startup actually ran. A touch event faces exactly this queue, so this is
//     the earliest the app could have answered one.
//  4. `longest main-thread stall` — the largest gap between consecutive fires
//     of a 60 Hz timer over the first ten seconds. A 0.9 s gap is 0.9 s in
//     which nothing rendered and nothing responded. **This is the number a
//     construction timestamp cannot give**, because a store built off the main
//     actor costs the same seconds and none of the responsiveness.
//
//  THREE STATES PER READING, NOT TWO — §12.15. `notYet` and `couldNotMeasure`
//  are opposite facts: the first says come back, the second says this device
//  will never tell you. Reading the screen four seconds into a ten-second
//  window is the ordinary case and it must not look like a fast launch.
//
//  AND THE WINDOW CAN BE POISONED. If the app is backgrounded while the timer
//  is running, the gaps include time the app was not scheduled at all — so the
//  stall figure is not a stall figure. It says so rather than reporting it.
//

import Foundation
import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// Seconds from the kernel starting this process until now.
///
/// `p_starttime` is a wall-clock `timeval`, so this compares against
/// `gettimeofday` rather than a monotonic clock — the two must come from the
/// same domain. Over a launch that is sound; it is why the value is sampled
/// once, early, and never recomputed.
nonisolated enum ProcessStart {

    /// Seconds, or a reason. NEVER an optional collapsed to zero — a launch
    /// that cost nothing and a launch nobody could measure are different
    /// answers (§12.15).
    enum Reading: Equatable, Sendable {
        case seconds(Double)
        case couldNotRead(String)
    }

    static func secondsUntilNow() -> Reading {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0 else {
            return .couldNotRead("sysctl refused the process table (errno \(errno))")
        }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else {
            return .couldNotRead("the kernel reported no start time")
        }
        var now = timeval()
        gettimeofday(&now, nil)
        let seconds = Double(now.tv_sec - started.tv_sec)
            + Double(now.tv_usec - started.tv_usec) / 1_000_000
        // A negative or absurd reading means the wall clock moved between the
        // two samples. Say that rather than print it.
        guard seconds >= 0, seconds < 600 else {
            return .couldNotRead(String(format: "implausible reading of %.3f s", seconds))
        }
        return .seconds(seconds)
    }
}


/// The largest gap between consecutive ticks, as arithmetic rather than as a
/// timer — so the suite can test the measurement without waiting for it.
nonisolated struct StallWatch: Equatable, Sendable {
    /// Seconds. The nominal interval is subtracted, so a timer firing exactly
    /// on time records zero.
    private(set) var longest: Double = 0
    private(set) var samples = 0

    /// `gap` is the observed interval between this tick and the previous one;
    /// `nominal` is what it should have been.
    mutating func tick(gap: Double, nominal: Double) {
        samples += 1
        let late = gap - nominal
        if late > longest { longest = late }
    }
}


/// What the launch cost, as a value. Pure, so every state it can print is
/// reachable from a test.
nonisolated struct LaunchTiming: Equatable, Sendable {

    /// THREE STATES. See the header.
    enum Reading: Equatable, Sendable {
        case seconds(Double)
        /// The event has not happened yet. Come back.
        case notYet(String)
        /// This device cannot answer. Do not come back.
        case couldNotMeasure(String)

        var text: String {
            switch self {
            case .seconds(let s): String(format: "%.3f s", s)
            case .notYet(let why): "not yet — \(why)"
            case .couldNotMeasure(let why): "could not measure — \(why)"
            }
        }

        var value: Double? {
            if case .seconds(let s) = self { return s }
            return nil
        }
    }

    var beforeOurFirstLine: Reading = .notYet("the app has not started")
    var firstLineToFirstView: Reading = .notYet("no view has appeared")
    var firstFreeTurn: Reading = .notYet("the main thread has not been free")
    var longestStall: Reading = .notYet("the window has not opened")
    var stallSamples = 0
    var windowSeconds: Double = 0
    var windowClosed = false
    var leftTheApp = false

    /// The one-line summary, for the row on the screen.
    ///
    /// It leads with responsiveness, not with construction: the question this
    /// exists to answer is *when could I have touched it*.
    var line: String {
        var parts = ["\(firstFreeTurn.text) to a free main thread"]
        if leftTheApp {
            parts.append("stall unknown — the app was backgrounded")
        } else if windowClosed {
            parts.append("longest stall \(longestStall.text)")
        } else {
            parts.append("still measuring")
        }
        return parts.joined(separator: " · ")
    }

    /// UNCONDITIONAL, every figure, on every launch — §12.54.2. A launch that
    /// cost nothing must still print, or a slow one cannot be told from a line
    /// nobody wired in.
    var diagnosticLines: [String] {
        var l = ["Launch: \(line)"]
        l.append("  before our first line: \(beforeOurFirstLine.text)")
        l.append("  our first line to the first view: \(firstLineToFirstView.text)")
        l.append("  first free main-thread turn: \(firstFreeTurn.text)")
        l.append("  longest main-thread stall: \(longestStall.text)"
                 + " over \(stallSamples) samples")
        l.append("  stall window: "
                 + (windowClosed
                    ? String(format: "closed — %.1f s", windowSeconds)
                    : String(format: "still open — %.1f s", windowSeconds)))
        // THE POISON LINE, AND IT IS NOT A FOOTNOTE. A backgrounded window
        // makes the stall figure a measurement of nothing.
        l.append("  left the app during the window: "
                 + (leftTheApp
                    ? "YES — the stall figure includes time the app was not "
                      + "running and means nothing"
                    : "no"))
        return l
    }

    /// True when every figure is a duration and nothing poisoned the window.
    /// The campaign reads this before it believes the numbers.
    var isComplete: Bool {
        beforeOurFirstLine.value != nil
            && firstLineToFirstView.value != nil
            && firstFreeTurn.value != nil
            && longestStall.value != nil
            && windowClosed
            && !leftTheApp
    }
}


/// The collector. One per process, started by `Sub4App.init`.
///
/// It is statics rather than a store because there is exactly one launch and it
/// has already happened by the time anything asks. Nothing here reads a file,
/// opens the database or writes anything.
@MainActor
enum LaunchClock {

    /// Ten seconds: long enough to include the first scroll and the detail
    /// store's construction, short enough that the timer is gone before the
    /// reader can open the screen twice.
    static let windowSeconds: Double = 10

    private static let nominal: Double = 1.0 / 60

    private static var preMain: ProcessStart.Reading?
    private static var firstLine: ContinuousClock.Instant?
    private static var firstView: ContinuousClock.Instant?
    private static var freeTurn: ContinuousClock.Instant?
    private static var lastTick: ContinuousClock.Instant?
    private static var watch = StallWatch()
    private static var closed = false
    private static var backgrounded = false
    private static var timer: DispatchSourceTimer?
    private static var observer: (any NSObjectProtocol)?

    /// Called from `Sub4App.init` — the first line of this app's own code.
    ///
    /// Sampling `preMain` HERE is the whole point: read at any later moment it
    /// would answer "how long ago was the app launched", which is a different
    /// question with the same units.
    static func appStarted() {
        guard firstLine == nil else { return }
        preMain = ProcessStart.secondsUntilNow()
        let now = ContinuousClock.now
        firstLine = now
        lastTick = now
        watchTheMainThread()
        watchForBackgrounding()
    }

    /// Called from the root view's `onAppear`.
    static func firstViewAppeared() {
        guard firstView == nil else { return }
        firstView = ContinuousClock.now
    }

    private static func watchForBackgrounding() {
        #if canImport(UIKit)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Only while the window is open. Backgrounding afterwards
                    // says nothing about the launch.
                    if !closed { backgrounded = true }
                }
            }
        #endif
    }

    /// A 60 Hz timer on the main queue. It cannot fire while the main thread is
    /// busy, which is exactly the property being measured.
    private static func watchTheMainThread() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + nominal, repeating: nominal, leeway: .milliseconds(1))
        t.setEventHandler {
            MainActor.assumeIsolated { tick() }
        }
        timer = t
        t.resume()
    }

    private static func tick() {
        let now = ContinuousClock.now
        guard let start = firstLine, let last = lastTick else { return }
        // THE FIRST TICK IS THE ONE THAT ANSWERS THE QUESTION. It could not run
        // until the main thread was free, so its own lateness IS the time to a
        // responsive app.
        if freeTurn == nil { freeTurn = now }
        watch.tick(gap: seconds(from: last, to: now), nominal: nominal)
        lastTick = now
        if seconds(from: start, to: now) >= windowSeconds {
            closed = true
            timer?.cancel()
            timer = nil
        }
    }

    private static func seconds(from a: ContinuousClock.Instant,
                                to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    /// What the screen and the paste read.
    static var timing: LaunchTiming {
        var t = LaunchTiming()
        switch preMain {
        case .seconds(let s): t.beforeOurFirstLine = .seconds(s)
        case .couldNotRead(let why): t.beforeOurFirstLine = .couldNotMeasure(why)
        case nil: t.beforeOurFirstLine = .couldNotMeasure("the clock was never started")
        }
        guard let start = firstLine else { return t }
        t.firstLineToFirstView = firstView.map { .seconds(seconds(from: start, to: $0)) }
            ?? .notYet("no view has appeared")
        t.firstFreeTurn = freeTurn.map { .seconds(seconds(from: start, to: $0)) }
            ?? .notYet("the main thread has not been free since the app started")
        t.stallSamples = watch.samples
        t.windowSeconds = min(seconds(from: start, to: .now), windowSeconds)
        t.windowClosed = closed
        t.leftTheApp = backgrounded
        // A stall figure taken from an open window is a floor, not a maximum.
        // That is `notYet`, not a number.
        t.longestStall = closed
            ? .seconds(watch.longest)
            : .notYet(String(format: "the window closes at %.0f s", windowSeconds))
        return t
    }
}
