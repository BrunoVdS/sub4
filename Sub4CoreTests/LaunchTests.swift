//
//  LaunchTests.swift
//  Sub4CoreTests
//
//  The launch gate — patch 215, plan step 3.3.1.
//
//  WHAT CAN AND CANNOT BE CHECKED HERE, STATED PLAINLY
//  ---------------------------------------------------
//  The claim 3.3.1 makes is about CONSTRUCTION ORDER inside SwiftUI: that
//  `ContentView()` — and therefore every store's `private init()` and its
//  synchronous file read — does not happen until the migration has finished.
//  That is a property of `ViewBuilder` not building the arm it does not take,
//  and no unit test in this bundle can observe it. The check for that is on the
//  device: the database folder exists on a first launch where Settings was
//  never opened.
//
//  What IS checkable is the policy and the error surface, and both are here.
//  A test file that pretended to verify the ordering would be worse than one
//  that says it cannot.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct LaunchTests {

    /// THE TRAP FOR 3.3.3.
    ///
    /// Failing open is right only while nothing reads the database. The moment
    /// a store takes its data from SQLite instead of JSON, carrying on after a
    /// failed migration means showing an empty training history that looks
    /// exactly like a real one — the worst failure this app has available.
    ///
    /// This test does not stop that happening. It makes the flip deliberate:
    /// whoever changes the constant has to change this line too, and read why.
    ///
    /// PATCH 346a — AND THE INSTRUCTION BELOW USED TO BE WRONG IN A WAY THAT
    /// MATTERS. It said "flip this in 3.3.3, when the first store reads from
    /// the database". At 346 three stores read from the database and this flag
    /// must NOT move: A3 §2.2 settled that every D7 slice keeps a selectable
    /// legacy path, and the app fails closed only at B9, after all eight, with
    /// a recovery screen that does not exist yet. Following the old sentence
    /// today would block the app on a failed migration with nowhere to say so.
    ///
    /// Third copy of that sentence to be corrected: 342 fixed `Sub4Launch`'s
    /// header, 346 fixed `DataLifecycleTests`, this is the last.
    @Test("Migration failure does not block the app — and the condition that changes it")
    func theFailurePolicyIsStatedRatherThanImplied() {
        #expect(Sub4Launch.migrationFailureBlocksTheApp == false,
                "flip this at B9, when the database holds the only current copy")
    }

    /// Adding a case to a `LocalizedError` and forgetting its description gives
    /// a screen that says "The operation couldn't be completed", which is the
    /// least useful sentence in the system.
    @Test("Every database error says something specific")
    func everyDatabaseErrorDescribesItself() {
        let errors: [Sub4DatabaseError] = [
            .applicationSupportUnavailable,
            .couldNotCreateDirectory("no permission"),
            .launchFailed("SQLITE_CORRUPT")
        ]
        for e in errors {
            let text = e.errorDescription ?? ""
            #expect(!text.isEmpty, "\(e) has no description")
            #expect(text.count > 20, "\(e) describes itself too vaguely: \(text)")
        }
    }

    /// The launch failure carries the underlying message through rather than
    /// replacing it. A health screen that says only "it failed" sends the
    /// reader back to a console they no longer have.
    @Test("A launch failure keeps the reason it was given")
    func theLaunchFailureCarriesItsCause() {
        let e = Sub4DatabaseError.launchFailed("disk I/O error in PRAGMA foreign_keys")
        let text = e.errorDescription ?? ""
        let carriesCause = text.contains("disk I/O error")
        #expect(carriesCause, "the message was replaced rather than carried: \(text)")
    }
}
