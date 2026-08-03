//
//  DisconnectTests.swift
//  Sub4CoreTests
//
//  What disconnecting Strava does, asserted — patch 187, plan step 2.1.5.
//
//  THESE DO NOT RUN THE DISCONNECT, for the same reason the coordinator tests
//  do not run the delete: it operates on the real Application Support directory
//  of the hosting process. What is asserted is the RULE SET — that every
//  category declares one, that the rules agree with the lineage the same
//  inventory records, that nothing authored is removed, and that every field a
//  rule says it clears has code behind it.
//
//  That last one matters more than it looks. `clearsFields` names fields inside
//  a file that survives, and no generic walker can act on it — a handler is
//  dispatched by category. A category declaring `clearsFields` with no handler
//  would silently keep the data it promised to clear.
//

import Testing
import Foundation
@testable import Sub4

@Suite
@MainActor
struct DisconnectTests {

    // MARK: Every category has an answer

    /// Non-optional in the type, so this cannot fail by omission — it fails when
    /// a `keep` gives no reason, which is the same thing said to a reader.
    @Test("Every category explains what a disconnect does to it",
          arguments: DataCategory.allCases)
    func everyCategoryHasARule(_ c: DataCategory) throws {
        let e = try #require(DataLifecycle.entry(c))
        #expect(e.onStravaDisconnect.label.isEmpty == false)
        if case .keep(let why) = e.onStravaDisconnect {
            #expect(why.isEmpty == false, "\(c.rawValue) is kept for no stated reason")
        }
    }

    // MARK: The rules agree with the lineage

    /// The invariant that makes a disconnect trustworthy: if a disconnect
    /// removes a category, that category must actually have come from Strava.
    /// Removing something with no Strava lineage would be destroying the user's
    /// own data under cover of a privacy action.
    @Test("Nothing is removed unless it carries Strava lineage")
    func onlyStravaLineageIsRemoved() {
        for e in DataLifecycle.entries where e.onStravaDisconnect.removesAnything {
            #expect(e.isStravaDerived,
                    "\(e.category.rawValue) is altered by a Strava disconnect but has no Strava lineage")
        }
    }

    /// The converse, and the one that would have caught the original bug: a
    /// category the app declares as Strava-derived cannot simply be kept
    /// without a reason that admits why. Three entries claimed "Removed with
    /// the Strava disconnect" for three patches while nothing removed them.
    @Test("A Strava-derived category is either altered or says why it survives")
    func stravaDerivedIsAlteredOrExplained() {
        for e in DataLifecycle.stravaDerived {
            if e.onStravaDisconnect.removesAnything { continue }
            guard case .keep(let why) = e.onStravaDisconnect else { continue }
            // Not a wording check — a check that the reason engages with the
            // fact that this category holds Strava data, rather than waving.
            let engages = why.localizedCaseInsensitiveContains("strava")
                || why.localizedCaseInsensitiveContains("your")
                || why.localizedCaseInsensitiveContains("you ")
                || why.localizedCaseInsensitiveContains("nothing is stored")
            #expect(engages,
                    "\(e.category.rawValue) is Strava-derived and kept, and the reason does not say why: \(why)")
        }
    }

    /// Your notes and your corrections must survive. This is the difference
    /// between a disconnect and a delete, and it is the promise a person is
    /// relying on when they tap it.
    @Test("Nothing you authored is removed", arguments: [
        DataCategory.sessionNotes, .matchDecisions, .appSettings
    ])
    func authoredDataSurvives(_ c: DataCategory) throws {
        let e = try #require(DataLifecycle.entry(c))
        #expect(e.onStravaDisconnect.removesAnything == false,
                "\(c.rawValue) is authored by the user and must survive a disconnect")
    }

    /// Health is a separate permission revoked in Apple's own Settings, and the
    /// plan ships inside the app. Neither is a Strava disconnect's business.
    @Test("Health and the bundled plan are untouched", arguments: [
        DataCategory.healthMetrics, .trainingPlan
    ])
    func foreignCategoriesAreUntouched(_ c: DataCategory) throws {
        let e = try #require(DataLifecycle.entry(c))
        #expect(e.onStravaDisconnect.removesAnything == false)
    }

    // MARK: Partial rules are coherent

    /// A rule cannot remove a file the category does not claim to hold. If it
    /// could, the inventory would be describing one thing and the disconnect
    /// removing another — the exact drift this design exists to prevent.
    @Test("Every file a rule removes is declared in that category's storage")
    func removedFilesAreDeclared() {
        for e in DataLifecycle.entries {
            guard case .partial(_, let files, let keychain, _) = e.onStravaDisconnect else { continue }
            for f in files {
                let declared = e.storage.contains { s in
                    if case .applicationSupport(let i) = s { return i == f }
                    return false
                }
                #expect(declared,
                        "\(e.category.rawValue) removes \(f.displayName), which it does not declare holding")
            }
            for k in keychain {
                let declared = e.storage.contains { s in
                    if case .keychain(let i) = s { return i == k }
                    return false
                }
                #expect(declared,
                        "\(e.category.rawValue) removes Keychain item \(k), which it does not declare holding")
            }
        }
    }

    /// The handler check. `clearFields` dispatches on category; a category that
    /// declares fields and is not in that switch hits `assertionFailure` at
    /// runtime, in a release build silently does nothing, and the app keeps
    /// data it told the user it had cleared.
    ///
    /// This list is the switch, written out. The two must be changed together,
    /// which is the whole point.
    @Test("Every category that clears fields has a handler")
    func everyClearedFieldHasAHandler() {
        let handled: Set<DataCategory> = [.athleteProfile]
        for e in DataLifecycle.entries {
            guard case .partial(_, _, _, let fields) = e.onStravaDisconnect,
                  !fields.isEmpty else { continue }
            #expect(handled.contains(e.category),
                    "\(e.category.rawValue) declares clearsFields \(fields) with no handler in clearFields(_:for:)")
        }
    }

    /// The specific fields, pinned. These three are the ones read off Strava
    /// activity data — and `hrMaxObservedName` is the NAME of an activity, which
    /// is the one a reader would most object to finding after a disconnect.
    @Test("The Strava-derived constants are the ones cleared")
    func theRightConstantsAreCleared() throws {
        let e = try #require(DataLifecycle.entry(.athleteProfile))
        guard case .partial(let keeps, let files, _, let fields) = e.onStravaDisconnect else {
            Issue.record("athleteProfile no longer declares a partial disconnect")
            return
        }
        #expect(Set(fields) == ["hrMaxObserved", "hrMaxObservedOn", "hrMaxObservedName"],
                "cleared fields are \(fields)")
        #expect(files.contains(.file("athlete.json")),
                "athlete.json holds zones, FTP and shoes, all fetched from Strava")
        #expect(files.contains(.file("constants.json")) == false,
                "constants.json holds figures you typed and must not be removed wholesale")
        #expect(keeps.isEmpty == false)
    }

    /// The decision taken at 2.1.5: sign-in tokens go, application keys stay,
    /// so reconnecting is one tap. Pinned because it is a judgement rather than
    /// a necessity, and a future change to it should be deliberate.
    @Test("Sign-in tokens are removed and the application keys are kept")
    func tokensGoAndAppKeysStay() throws {
        let e = try #require(DataLifecycle.entry(.credentials))
        guard case .partial(_, _, let keychain, _) = e.onStravaDisconnect else {
            Issue.record("credentials no longer declares a partial disconnect")
            return
        }
        #expect(keychain == ["strava.tokens"], "removes \(keychain)")
        #expect(keychain.contains("strava.credentials") == false,
                "the application keys are kept so reconnecting does not need the developer page")
        #expect(keychain.contains("claude.apiKey") == false,
                "the Anthropic key has nothing to do with Strava")
    }

    // MARK: The receipt

    /// After a disconnect the retained lines are things kept ON PURPOSE. Calling
    /// them "not this app's to delete" — the wording the delete receipt uses —
    /// would read as a failure to remove them.
    @Test("A disconnect receipt describes what it kept as kept")
    func disconnectSummaryReadsAsKept() {
        let r = LifecycleReceipt(operation: .disconnectStrava, lines: [
            ReceiptLine(what: "activities.json", categories: [.activitySummaries],
                        outcome: .removed(bytes: 1_000)),
            ReceiptLine(what: "Your session notes", categories: [.sessionNotes],
                        outcome: .notOurs("Kept — you wrote it"))
        ])
        #expect(r.summary.localizedCaseInsensitiveContains("kept"))
        #expect(r.summary.localizedCaseInsensitiveContains("not this app") == false,
                "summary was: \(r.summary)")
    }
}
