//
//  AppVersionTests.swift
//  Sub4CoreTests
//
//  The letter fix-ups show — patch 284, ADR-0003 §12.30.
//
//  THESE DID NOT EXIST AND THE GAP HAD A COST. `AppVersion` is the one thing on
//  the screen whose entire job is to say which source is running, and nothing
//  had ever asserted anything about it. 283a was installed, the phone read
//  "Source patch 283", and the number that exists to catch a patch not landing
//  could not tell a device with the fix-up from one without it.
//
//  `everyDisplayFormCarriesTheRevision` is the one that matters. It walks all
//  four printed forms, because a fifth caller reading `patch` directly is
//  exactly how this comes back — and the whole point is that there is one
//  answer, in one place, that everything displays.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct AppVersionTests {

    @Test("The label is the number, plus the letter when there is one")
    func theLabelIsTheNumberPlusTheLetter() {
        #expect(AppVersion.patchLabel.hasPrefix("\(AppVersion.patch)"))
        if let r = AppVersion.revision {
            #expect(AppVersion.patchLabel == "\(AppVersion.patch)\(r)")
        } else {
            #expect(AppVersion.patchLabel == "\(AppVersion.patch)")
        }
    }

    /// THE ONE THAT MATTERS. One answer, in one place, that everything prints.
    /// A caller that goes back to reading `patch` directly is how the screen
    /// starts lying again, and it will not be noticed — nothing looks stale.
    @Test("Every display form carries the revision")
    func everyDisplayFormCarriesTheRevision() {
        let label = AppVersion.patchLabel
        #expect(AppVersion.short.contains("patch \(label)"))
        #expect(AppVersion.full.contains("patch \(label)"))
        #expect(AppVersion.stamp.contains("patch \(label)"))
    }

    /// One lowercase letter, or nothing. "a1" and "A" would sort and read
    /// differently in every place this is printed, and a filename built from
    /// it — `NotesStore`'s CSV — would be the first to look wrong.
    @Test("A revision is a single lowercase letter, or absent")
    func aRevisionIsOneLowercaseLetter() {
        guard let r = AppVersion.revision else { return }
        #expect(r.count == 1, "a revision is one letter")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        #expect(r.unicodeScalars.allSatisfy { allowed.contains($0) },
                "a revision is lowercase a–z")
    }

    /// Not a style point. `patch` is an `Int` because things compare it —
    /// `>= 280` is a legitimate question and `"283a" >= "280"` is not the same
    /// question. The letter lives beside it for that reason, and if somebody
    /// ever folds them together this is what argues back.
    @Test("The patch number stays a number")
    func thePatchNumberStaysANumber() {
        #expect(AppVersion.patch > 0)
        #expect(AppVersion.patch >= 284, "this file shipped at 284")
    }
}
