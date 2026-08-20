//
//  AuthoredDatabase.swift
//  Sub4
//
//  Which database an authored store commits to, and whether the last write got
//  there — patch 412, ADR-0003 §12.157.
//
//  WHY THIS IS A FILE AND NOT FOUR NESTED ENUMS
//  --------------------------------------------
//  409 gave `NotesStore` a nested `NoteDatabase` and a nested `NoteCommit`, and
//  they were right for one store. 412 inverts the other three, and copying both
//  types into each would be four versions of one rule — §12.43, whose worst
//  instance was five copies of "done of total" disagreeing on two tabs for 230
//  patches. The stores differ in what they write and in how they report a
//  failure; they do not differ in *which database* or in *what the three
//  outcomes are*.
//
//  It also removes the singleton's name from the stores entirely, which is what
//  RULE 13 is watching for.
//

import Foundation

/// **WHICH DATABASE AN AUTHORED SAVE COMMITS TO — §12.153.1.**
///
/// The reasoning is 409's and it cost two failing tests to find. A save that
/// resolves `Sub4Launch.shared.database` at the write reaches a PROCESS-WIDE
/// singleton, so a store built by `init(directory:)` into a temporary folder
/// writes straight past its own directory into the app's own database. Two
/// suites call `Sub4Launch.shared.begin()`, which opens that database for every
/// test that runs after them, so it was not a hypothetical: it leaked on every
/// run, and two rollback tests caught it for a reason neither was written for.
///
/// **A seam is inert unless it is handed a database on purpose.**
nonisolated enum AuthoredDatabase: Sendable {

    /// The app's. Resolved AT THE WRITE, never at `init` — the authored stores
    /// are constructed with `ContentView`, and whether the launch has finished
    /// opening by then is `RootView`'s branch ordering, which is not something
    /// a store should depend on.
    case theLaunchs

    /// A seam with no database. The file (or `UserDefaults`) is authoritative
    /// and the pre-inversion contract holds unchanged — which is what every
    /// existing `init(directory:)` and `init(defaults:)` call site assumes.
    case none

    /// A seam with its own, for the controls. **A `Bool` could express *not the
    /// app's*; it could not express *this one instead*, and a path no test can
    /// reach has not been tested** — §12.69.
    case given(Sub4Database)

    @MainActor var live: Sub4Database? {
        switch self {
        case .theLaunchs:    Sub4Launch.shared.database
        case .none:          nil
        case .given(let db): db
        }
    }
}

/// **DID THE LAST AUTHORED WRITE REACH THE DATABASE — §12.153.9.**
///
/// Three states because two cannot carry the answer. 409 shipped this as a
/// `Bool` reset on every launch, so `false` — printed *"yes"* — was ALSO what a
/// launch said having written nothing, and the device campaign reads the line
/// after a force-quit where nothing has been written. **The row could only ever
/// pass.** §12.15: a diagnostic that cannot say why it has no answer will be
/// read as having one.
nonisolated enum AuthoredCommit: Equatable, Sendable {

    /// Nothing has been written in this launch. **Not a fault**, and the only
    /// honest thing to say before the athlete changes anything.
    case noneThisLaunch
    /// The last one committed to the database before it was published.
    case reached
    /// The last one went to the file with no database open. A real state before
    /// B9 — see any store's `commitToDatabase` for why it is not a refusal.
    case missed

    /// **ONE LINE FOR FOUR STORES, AND IT NAMES THE FAMILIES THAT MISSED.**
    ///
    /// Four lines would have been four ways of saying the same thing on the
    /// ordinary day — every store resolves the same `Sub4Launch.shared
    /// .database` — while collapsing them to a bare yes/no would lose the one
    /// case worth printing, which is *some* of them missing. §12.54.2: a count
    /// beside its denominator is evidence, a bare verdict is noise.
    ///
    /// It says nothing about a record — §12.7. Whether a commit happened is not
    /// a session, a place or a date.
    static func line(_ families: [(name: String, commit: AuthoredCommit)]) -> String {
        let missed = families.filter { $0.commit == .missed }.map(\.name)
        guard missed.isEmpty else {
            return "Authored writes reaching the database: NO — "
                 + missed.joined(separator: ", ") + " went to the file only"
        }
        guard families.contains(where: { $0.commit == .reached }) else {
            return "Authored writes reaching the database: "
                 + "no record written since this launch"
        }
        return "Authored writes reaching the database: yes"
    }
}
