//
//  LoadThresholds.swift
//  Sub4
//
//  The numbers the load flags fire on, and the only ones in this app you can
//  change without a patch.
//
//  WHY THESE AND NOT THE OTHERS
//  ----------------------------
//  `Review.Thresholds` is fixed in source: RPE ceilings, adherence floors,
//  note coverage. Those are properties of how the review reasons, and moving
//  one would change what the review MEANS rather than what it is looking at.
//
//  These three are different. Every one of them is a population figure being
//  applied to one athlete, and the literature behind each is thinner than its
//  confident use suggests:
//
//  RAMP RATE. "Do not add more than 5 CTL per week" is folklore that hardened
//  into a rule. It comes from cycling populations at steady volume, and it is
//  plainly wrong for an athlete re-acquiring a base he already had — the first
//  four weeks back after a lay-off are recovery of fitness, not construction of
//  it, and the same +8 means something different in each case. Two levels here,
//  so the review can say "worth watching" without saying "too fast".
//
//  DEEP TSB. The source literature is explicit that race-day TSB targets are
//  folklore, and this app has refused to state one from the beginning. What is
//  defensible is a PATTERN: sustained deep negative freshness over consecutive
//  days is a different thing from one hard weekend, and the flag fires on the
//  run rather than the reading.
//
//  MONOTONY. Foster's 2.0 is the best-supported number of the three, and it is
//  still an association from one study population rather than a limit.
//
//  So they are editable, they show their defaults, and the review names the
//  figure it fired on. What is NOT editable is whether a flag fires at all
//  when the data is thin — see `ReviewLoad`. A threshold you can move is a
//  judgement; suppressing an unsupportable conclusion is not.
//

import Foundation
import Observation

@Observable
final class LoadThresholds {

    static let shared = LoadThresholds()

    /// CTL gained in seven days, above which the review says look at this.
    var rampWarn: Double { didSet { save(rampWarn, "load.rampWarn") } }
    /// The quieter level — mentioned, not warned about.
    var rampNote: Double { didSet { save(rampNote, "load.rampNote") } }

    /// TSB at or below this counts as deep.
    var tsbDeep: Double { didSet { save(tsbDeep, "load.tsbDeep") } }
    /// Consecutive deep days before it is a pattern rather than a weekend.
    var tsbDeepDays: Int { didSet { save(Double(tsbDeepDays), "load.tsbDeepDays") } }

    /// Foster's figure.
    var monotonyHigh: Double { didSet { save(monotonyHigh, "load.monotonyHigh") } }

    static let defaults = (rampWarn: 7.0, rampNote: 5.0,
                           tsbDeep: -25.0, tsbDeepDays: 5,
                           monotonyHigh: 2.0)

    var isDefault: Bool {
        rampWarn == Self.defaults.rampWarn
            && rampNote == Self.defaults.rampNote
            && tsbDeep == Self.defaults.tsbDeep
            && tsbDeepDays == Self.defaults.tsbDeepDays
            && monotonyHigh == Self.defaults.monotonyHigh
    }

    func reset() {
        rampWarn = Self.defaults.rampWarn
        rampNote = Self.defaults.rampNote
        tsbDeep = Self.defaults.tsbDeep
        tsbDeepDays = Self.defaults.tsbDeepDays
        monotonyHigh = Self.defaults.monotonyHigh
    }

    /// THE KEYS THIS TYPE WRITES, OWNED BY THE TYPE THAT WRITES THEM — patch 214.
    ///
    /// `DataLifecycle` used to list every preference key as a literal, and these
    /// five were in neither the inventory nor the hand-written array in
    /// `DataLifecycleCoordinatorTests` that is supposed to catch exactly that.
    /// Both lists were written the same day by the same person and both forgot
    /// this file, so the test named "Every UserDefaults key the app writes is
    /// covered by a category" passed while five written keys were covered by
    /// nothing. `Delete local data` left the athlete's tuned thresholds in
    /// place, and the receipt did not name them as survivors.
    ///
    /// Referencing this constant from the inventory means a sixth threshold is
    /// covered the moment it is added. Note this is the OPPOSITE of the rule for
    /// migrations, deliberately: a migration is history and must freeze its
    /// literals, while an inventory describes the present and should read live.
    nonisolated static let preferenceKeys = [
        "load.rampWarn", "load.rampNote",
        "load.tsbDeep", "load.tsbDeepDays",
        "load.monotonyHigh"
    ]

    /// Back to defaults WITHOUT writing them to disk.
    ///
    /// `DataLifecycleCoordinator.deleteEverything` removes the preference keys
    /// first and calls `dropAllInMemory()` afterwards. Plain `reset()` here
    /// would fire every `didSet` and write the defaults straight back into the
    /// keys the coordinator has just cleared — a delete that leaves five keys
    /// on disk holding default values, which is not what "deleted" means.
    func dropInMemory() {
        isPersisting = false
        reset()
        isPersisting = true
    }

    private var isPersisting = true

    private init() {
        let d = UserDefaults.standard
        func read(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) as? Double ?? fallback
        }
        rampWarn = read("load.rampWarn", Self.defaults.rampWarn)
        rampNote = read("load.rampNote", Self.defaults.rampNote)
        tsbDeep = read("load.tsbDeep", Self.defaults.tsbDeep)
        tsbDeepDays = Int(read("load.tsbDeepDays", Double(Self.defaults.tsbDeepDays)))
        monotonyHigh = read("load.monotonyHigh", Self.defaults.monotonyHigh)
    }

    private func save(_ v: Double, _ key: String) {
        guard isPersisting else { return }
        UserDefaults.standard.set(v, forKey: key)
    }
}
