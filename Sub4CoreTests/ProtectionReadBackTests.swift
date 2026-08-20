//
//  ProtectionReadBackTests.swift
//  Sub4CoreTests
//
//  The measured protection class — patch 417, ADR-0003 §12.162, plan topic 2.
//
//  PLATFORM-INDEPENDENT ON PURPOSE, AND THAT IS A LIMIT NOT A VIRTUE.
//  ------------------------------------------------------------------
//  A simulator does not enforce data protection. Setting `.protectionKey` there
//  writes an attribute that means nothing, and the absence of one means nothing
//  either. So these tests prove the READER — that it tells four states apart
//  and never guesses — and they cannot prove the protection.
//
//  **The protection itself is the device's to answer**, which is what
//  `docs/DEVICE-CAMPAIGN-417.md` is for. Recorded here rather than left to be
//  inferred from a green suite, because a green suite over a security property
//  is exactly the thing this patch exists to stop.
//

import Testing
import Foundation
@testable import Sub4

@Suite("The protection attribute, as measured")
struct ProtectionReadBackTests {

    private func directory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("protection-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func file(in dir: URL, named: String = "thing.json") throws -> URL {
        let url = dir.appendingPathComponent(named)
        try Data("{}".utf8).write(to: url)
        return url
    }

    // MARK: The four states

    /// **THROUGH `classify`, NOT THROUGH THE FILE SYSTEM — and the reason is
    /// the finding.** On a simulator, `setAttributes([.protectionKey: …])` is a
    /// no-op: it stores nothing and fails at nothing, not even for a path that
    /// does not exist. Two of the reader's four answers are unreachable there,
    /// so driving the decision directly is the only way to exercise them at
    /// all. §12.162.3.
    @Test("The expected class reads as expected")
    func expectedIsExpected() {
        #expect(ProtectionReadBack.classify(FileProtection.attribute) == .asExpected)
    }

    @Test("Another class is NOT folded into 'no attribute'")
    func aDifferentClassIsItsOwnAnswer() {
        // `.complete` is the class this app deliberately does NOT use — it
        // breaks background writes while the phone is locked, which is
        // `FileProtection`'s own header. A file that has it is protected, and
        // wrongly, and that is a different finding from one protected by
        // nothing. §12.132.
        let reading = ProtectionReadBack.classify(FileProtectionType.complete)
        #expect(reading != .asExpected)
        #expect(reading != .noAttribute)
        if case .different(let what) = reading {
            #expect(!what.isEmpty, "a row saying 'wrong' must say what it is")
        } else {
            Issue.record("expected .different, got \(reading)")
        }
    }

    @Test("An item that cannot be inspected is not an item with no attribute")
    func inspectionFailureIsNotAbsence() throws {
        let dir = try directory()
        let missing = dir.appendingPathComponent("never-written.json")

        let reading = ProtectionReadBack.read(missing)
        if case .couldNotInspect = reading {
            // §12.15. "The attribute is not set" and "I could not look" send a
            // reader to different places, and an optional could not hold both.
        } else {
            Issue.record("expected .couldNotInspect, got \(reading)")
        }
        #expect(reading != .noAttribute)
        #expect(reading.line.contains("could not inspect"))
    }

    // MARK: The summary, and what it must not do

    @Test("The summary says how many of how many")
    func theSummaryCarriesItsDenominator() {
        let items = [
            ProtectionReadBack.Item(name: "a", reading: .asExpected),
            ProtectionReadBack.Item(name: "b", reading: .noAttribute),
            ProtectionReadBack.Item(name: "c", reading: .couldNotInspect("gone")),
        ]
        // A bare "protected" cannot be told from a list nobody read. §12.54.2.
        #expect(ProtectionReadBack.summary(items) == "1 of 3 at the expected class")
    }

    @Test("No reading carries a path")
    func noReadingCarriesAPath() throws {
        let dir = try directory()
        let missing = dir.appendingPathComponent("never-written.json")
        let item = ProtectionReadBack.Item(name: "notes.json",
                                           reading: ProtectionReadBack.read(missing))
        // §12.7, and 407's correction: a container path names the device's
        // user. The NAME is the app's; the path is the phone's.
        #expect(!item.line.contains(NSTemporaryDirectory()))
        #expect(!item.line.contains(dir.lastPathComponent))
    }

    // MARK: The write now reports

    /// **THE REFUSAL PATH CANNOT BE PROVOKED HERE, AND SAYING SO IS THE
    /// POINT.** On a simulator `setAttributes` with only `.protectionKey`
    /// succeeds for **a directory that does not exist**, so no fixture makes
    /// this return `.refused`. What is testable is that a refusal, when it
    /// happens, is counted and kept — and that is what `note` does.
    ///
    /// The write failing for real is `DEVICE-CAMPAIGN-417.md`'s row. A test
    /// that pretended otherwise would be §12.69's guard that cannot fail,
    /// wearing a green tick over a security property.
    @Test("A refusal is counted and its message kept")
    func aRefusalIsCountedAndKept() {
        FileProtection.resetFailures()
        #expect(FileProtection.failureCount == 0)
        #expect(FileProtection.lastError == nil)

        FileProtection.note(URL(fileURLWithPath: "/tmp/notes.json"),
                            CocoaError(.fileWriteNoPermission))
        FileProtection.note(URL(fileURLWithPath: "/tmp/moves.json"),
                            CocoaError(.fileWriteNoPermission))

        // A count beside its message is evidence; one slot was an anecdote —
        // forty failures and one reported read exactly like one failure.
        #expect(FileProtection.failureCount == 2)
        #expect(FileProtection.lastError?.contains("moves.json") == true)
        #expect(FileProtection.lastError?.contains("/tmp") == false, "§12.7")
        FileProtection.resetFailures()
    }

    @Test("A protection write reports what it did")
    func aWriteReportsWhatItDid() throws {
        FileProtection.resetFailures()
        let dir = try directory()
        // On a device this is the guarantee; on a simulator it is a no-op that
        // reports success, which is exactly why the row on the screen reads the
        // attribute back instead of trusting this.
        #expect(FileProtection.protect(directory: dir).didApply)
        #expect(FileProtection.failureCount == 0)
    }
}
