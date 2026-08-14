//
//  BootstrapFixtures.swift
//  Sub4CoreTests
//
//  The two authored families, as a fixture — patch 357b, D7 slice B2.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  357 gave `DatabaseBootstrap` two more fields, which gave its synthesised
//  memberwise initialiser two more parameters, which broke thirteen test call
//  sites that construct a bootstrap by hand. Every one of them is a B1 test
//  and none of them has an opinion about notes or match decisions.
//
//  THE TEMPTING FIX IS THE WRONG ONE. Writing an explicit initialiser on
//  `DatabaseBootstrap` with `authored: AuthoredLoad = .unavailable` would have
//  fixed all thirteen with one line and no edits. It would also have made
//  `DatabaseBootstrapReader.read` — the ONE production construction — able to
//  drop a family silently and still compile, and the paste would have said
//  "The database is not open" about a database that was open, for ever.
//
//  That is §12.95.4 exactly: a default argument is a call site carrying a value
//  the caller never writes, and no grep for the value finds it. 346a is what it
//  cost the last time — five `PlanStore.shared` call sites hid inside one for
//  four patches, and the tests passed throughout because two plans happened to
//  agree.
//
//  So the production initialiser still demands all five, and the convenience
//  lives HERE, in the test target, where production cannot reach it.
//
//  `nonisolated` ON EACH MEMBER, DELIBERATELY. `SWIFT_DEFAULT_ACTOR_ISOLATION`
//  is `MainActor` and an extension does not inherit its type's isolation —
//  354a's lesson, learned on `Plan.empty`. Both suites that use these are plain
//  structs, so a MainActor-isolated fixture would fail to compile in exactly
//  the places it is needed.
//

import Foundation
@testable import Sub4

extension AuthoredLoad {

    /// A clean read of a database in which the athlete has written nothing.
    ///
    /// **NOT `.unavailable`.** The difference is §12.15's, and it is the whole
    /// reason 357 split `wasReadCleanly` from `holdsContent`: this says the
    /// read succeeded and found nothing, which is a legitimate permanent state
    /// and NOT a fault. `.unavailable` says the read did not happen, which
    /// makes `wasReadCleanly` false and turns every B1 test that uses it into a
    /// test about a broken database.
    ///
    /// The one place `.unavailable` IS correct is
    /// `DatabaseBootstrapTests.aFailureIsVisiblePerFamily`, which asserts that
    /// all five families say so — and it passes it literally, for that reason.
    nonisolated static let noneWritten =
        AuthoredLoad.loaded(notes: [], commutes: [], skipped: 0)
}

extension MatchDecisionLoad {

    /// A clean read of `match_decision` holding nothing — which is this
    /// device's real state today, and has been since the table was created in
    /// 274. See `MatchDecisionLoad.holdsContent`.
    nonisolated static let noneRecorded =
        MatchDecisionLoad.loaded(decisions: [], skipped: 0)
}
