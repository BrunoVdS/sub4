//
//  AthleteRefreshTests.swift
//  Sub4CoreTests
//
//  What "Refresh zones & gear" is allowed to call a success — patch 232.
//
//  THE DEFECT
//  ----------
//  `refresh()` reported a problem only when BOTH fetches came back empty:
//
//      if z.isEmpty && g.isEmpty { lastError = "No zone or gear data…" }
//      else { lastError = nil; lastFetch = Date(); save() }
//
//  So a refresh returning six shoes and no heart-rate zones cleared the error,
//  stamped the timestamp and reported success. The half that worked concealed
//  the half that did not.
//
//  That is not hypothetical. Strava holds five heart-rate zones for this
//  account — checked against the API directly — and the app held none, with
//  nothing on any screen saying so, while `hr_zone` imported as 0 rows.
//
//  `refresh` itself needs a token and a network and cannot run here. The part
//  that was wrong is the decision about what counts as a problem, so that part
//  is a pure function and this file is about it.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct AthleteRefreshTests {

    /// THE ONE THAT MATTERS. Gear arrived, zones did not, and that is a problem
    /// even though something came back.
    @Test("Gear without zones is reported, not silently accepted")
    func aPartialRefreshIsAProblem() {
        let problems = AthleteStore.refreshProblems(zones: 0, gear: 6)
        #expect(problems.count == 1)
        let mentionsZones = problems.first?.contains("heart-rate zones") ?? false
        #expect(mentionsZones, "the message does not say which half failed")
    }

    /// The mirror image, which the old condition also got wrong.
    @Test("Zones without gear is reported too")
    func theOtherHalfIsAlsoReported() {
        let problems = AthleteStore.refreshProblems(zones: 5, gear: 0)
        #expect(problems.count == 1)
        let mentionsGear = problems.first?.contains("gear") ?? false
        #expect(mentionsGear)
    }

    /// Both empty is two problems, not one. The old message collapsed them into
    /// a single sentence about "zone or gear data", which named neither.
    @Test("Both empty is reported as two separate problems")
    func bothEmptyNamesBoth() {
        let problems = AthleteStore.refreshProblems(zones: 0, gear: 0)
        #expect(problems.count == 2)
    }

    /// And a refresh that got everything says nothing, so the row stays quiet
    /// on the normal path.
    @Test("A complete refresh reports no problem")
    func aCompleteRefreshIsSilent() {
        #expect(AthleteStore.refreshProblems(zones: 5, gear: 6).isEmpty)
    }

    /// The scope hint is the actionable half of the zones message — it is the
    /// difference between "something went wrong" and "disconnect and
    /// reconnect". Asserted because it is the sentence that would get dropped
    /// in a tidy-up.
    @Test("The zones message says what to do about it")
    func theZonesMessageIsActionable() {
        let problems = AthleteStore.refreshProblems(zones: 0, gear: 1)
        let text = problems.joined(separator: " ")
        #expect(text.contains("disconnect and reconnect"))
    }
}
