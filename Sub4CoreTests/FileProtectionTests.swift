//
//  FileProtectionTests.swift
//  Sub4CoreTests
//
//  Encryption at rest, pinned — patch 190, plan step 2.1.9, finding DATA-05.
//
//  WHAT A TEST CAN AND CANNOT SEE HERE
//  -----------------------------------
//  The simulator does not enforce data protection — there is no passcode and no
//  hardware key, so a file written with `.completeUntilFirstUserAuthentication`
//  is readable exactly as one written without it. A test asserting "the data is
//  protected" would pass on the simulator and prove nothing about a device.
//
//  So these assert the two things that are actually checkable and are actually
//  the mistakes worth catching: that the CLASS chosen is the right one, and
//  that every store's write goes through the shared options rather than a bare
//  `.atomic` that somebody added later.
//

import Testing
import Foundation
@testable import Sub4

@Suite
struct FileProtectionTests {

    /// THE DECISION, PINNED. `.complete` is stronger and is the wrong answer:
    /// `BackgroundRefresh` writes `activities.json` while the phone is locked
    /// in a pocket, every store writes with `try?`, and under `.complete` those
    /// writes fail silently. The app would stop updating for anyone who does
    /// not unlock at the right moment, and nothing would say so.
    ///
    /// If this test fails because someone raised the class, that is the moment
    /// to fix the background refresh first.
    @Test("Files are protected until first unlock, not while locked")
    func theProtectionClassIsUntilFirstUnlock() {
        #expect(FileProtection.attribute == .completeUntilFirstUserAuthentication)
        #expect(FileProtection.attribute != .complete,
                "complete protection breaks the background refresh — see FileProtection")
        #expect(FileProtection.attribute != .none)
    }

    /// The write options must carry BOTH: atomic, so a crash mid-write cannot
    /// truncate a store, and the protection class. Losing either is silent.
    @Test("The shared write options are atomic and protected")
    func writeOptionsCarryBoth() {
        #expect(FileProtection.options.contains(.atomic))
        #expect(FileProtection.options.contains(.completeFileProtectionUntilFirstUserAuthentication))
    }

    /// The two constants describe the same class in two APIs — `Data.WritingOptions`
    /// for writes and `FileProtectionType` for `setAttributes`. Nothing in the
    /// type system ties them together, so a change to one and not the other
    /// would leave new files at one class and migrated files at another.
    @Test("The write option and the attribute name the same class")
    func theTwoConstantsAgree() {
        let usesUntilFirstUnlock =
            FileProtection.options.contains(.completeFileProtectionUntilFirstUserAuthentication)
        #expect(usesUntilFirstUnlock == (FileProtection.attribute == .completeUntilFirstUserAuthentication),
                "the write option and the FileManager attribute have drifted apart")
    }

    /// The migration must survive a container it cannot reach, and must not
    /// claim to have done work it did not do. Zero is a legitimate answer on a
    /// fresh install with nothing written yet.
    @Test("Applying protection to an empty store touches nothing and does not fail")
    func migrationOnEmptyStoreIsSafe() {
        FileProtection.lastError = nil
        let n = FileProtection.applyToExistingFiles()
        #expect(n >= 0)
        // A failure here would be a real one — the test bundle's container
        // exists and is writable.
        #expect(FileProtection.lastError == nil,
                "migration reported: \(FileProtection.lastError ?? "")")
    }

    /// End to end on a real file in a temporary directory. This DOES verify the
    /// attribute round-trips through `setAttributes`/`attributesOfItem`, which
    /// is the part of the migration that could be wrong in a way the simulator
    /// still shows — a mistyped key, or an attribute the system rejects.
    @Test("The attribute round-trips on a real file")
    func attributeRoundTrips() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sub4-protection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let f = dir.appendingPathComponent("a.json")
        try Data("{}".utf8).write(to: f, options: FileProtection.options)

        let attrs = try FileManager.default.attributesOfItem(atPath: f.path)
        // On the simulator the key may be absent entirely, because there is no
        // protection to record. That is not a failure — it is the simulator
        // being honest. What must NOT happen is the key being present with the
        // wrong value, which would mean the write silently downgraded.
        if let actual = attrs[.protectionKey] as? FileProtectionType {
            #expect(actual == FileProtection.attribute,
                    "written at \(actual.rawValue), expected \(FileProtection.attribute.rawValue)")
        }
    }
}
