//
//  FileProtection.swift
//  Sub4
//
//  Encryption at rest for everything this app writes — patch 190, plan step
//  2.1.9, finding DATA-05.
//
//  WHAT WAS WRONG
//  --------------
//  Every store wrote with `options: .atomic` and nothing else, which means the
//  default protection class — and on iOS the default for a file created by an
//  app is `NSFileProtectionCompleteUntilFirstUserAuthentication` only if the
//  app has never opted out, which is exactly the sort of "probably fine"
//  nobody should be relying on for thirteen months of GPS traces. Stated
//  plainly in the inventory as a gap on four categories since patch 180: the
//  route history is readable on a device that has been unlocked once.
//
//  WHY *UNTIL FIRST UNLOCK* AND NOT *COMPLETE*
//  -------------------------------------------
//  `.complete` is stronger: the file is unreadable whenever the screen is
//  locked. It is also wrong for this app, and choosing it would produce a
//  subtler bug than the one being fixed.
//
//  `BackgroundRefresh` wakes roughly every two hours and writes `activities.json`
//  and the per-activity files. Background tasks run while the phone is locked
//  and usually in a pocket. Under `.complete` those writes fail — silently,
//  because every store uses `try?` — and the app would quietly stop updating
//  for anyone who does not unlock their phone at the right moment. A privacy
//  measure that breaks the sync and reports nothing is worse than the exposure
//  it closes.
//
//  `.completeUntilFirstUserAuthentication` encrypts the file at rest, keeps it
//  unreadable until the phone has been unlocked once after boot, and stays
//  readable after that — including to background tasks. That is the protection
//  class Apple recommends for exactly this shape of app, and it is what the
//  gap in `DataLifecycle` is closed by.
//
//  MIGRATION IS NOT OPTIONAL
//  -------------------------
//  Setting the option on new writes protects nothing already on disk. A device
//  that has been running Sub4 for a year has every file at whatever class it
//  was created under. `applyToExistingFiles()` walks Application Support once
//  and sets the attribute on what is already there.
//

import Foundation

enum FileProtection {

    /// The class every file this app writes is created under.
    ///
    /// Pinned by test. Raising it to `.complete` would break the background
    /// refresh in a way that reports nothing — see the header before changing
    /// it, and if you do change it, change the background refresh first.
    nonisolated static let writingOption: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication

    /// The same class expressed for `FileManager`, for directories and for
    /// files already on disk.
    nonisolated static let attribute: FileProtectionType = .completeUntilFirstUserAuthentication

    /// Every write in the app goes through this rather than repeating
    /// `[.atomic, .completeFileProtection…]` at ten call sites, one of which
    /// would eventually be written without it.
    nonisolated static var options: Data.WritingOptions { [.atomic, writingOption] }

    /// Sets the protection class on a directory, so files created inside it
    /// inherit it. `details/` and `streams/` hold one file per activity and are
    /// created before anything is written into them.
    /// **IT RETURNED NOTHING AND SWALLOWED THE FAILURE UNTIL 417.**
    ///
    /// `try?` on a security attribute is the shape §12.20 keeps finding: the
    /// call cannot fail in any way a reader can see, so *"protection is in
    /// force"* became a sentence nobody could check. Nine call sites, none of
    /// which wanted to crash — which is why it swallowed, and why the answer is
    /// a value rather than a `throws`.
    ///
    /// `@discardableResult`, because most callers legitimately have nothing to
    /// do about it in the moment. **The failure is still recorded** — see
    /// `failures` — so ignoring the return does not lose the fact.
    @discardableResult
    nonisolated static func protect(directory url: URL,
                                    using fm: FileManager = .default) -> ProtectionWrite {
        do {
            try fm.setAttributes([.protectionKey: attribute],
                                 ofItemAtPath: url.path)
            return .applied
        } catch {
            note(url, error)
            return .refused(error.localizedDescription)
        }
    }

    /// Whether one attribute write landed.
    nonisolated enum ProtectionWrite: Equatable, Sendable {
        case applied
        case refused(String)

        var didApply: Bool { self == .applied }
    }

    /// **A COUNT AND THE NEWEST MESSAGE, NOT ONE SLOT — patch 417.**
    ///
    /// `lastError` held a single string, so a sweep that failed on forty files
    /// reported one of them and read exactly like a sweep that failed on one.
    /// A count beside its message is evidence; a bare message is an anecdote.
    /// §12.54.2.
    nonisolated(unsafe) static private(set) var failureCount = 0

    nonisolated static func note(_ url: URL, _ error: Error) {
        failureCount += 1
        lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
    }

    /// For tests, which must not inherit a count from whatever ran before them.
    nonisolated static func resetFailures() {
        failureCount = 0
        lastError = nil
    }

    /// Walks Application Support once and applies the class to everything
    /// already there.
    ///
    /// Idempotent and cheap — setting an attribute that is already set is a
    /// no-op — so it runs at every launch rather than being guarded by a
    /// version flag that could be wrong. The alternative, a `didMigrate` bool,
    /// is one more piece of state that can say yes when the answer is no.
    ///
    /// Returns how many items it touched, so the diagnostics row can say
    /// something true rather than the app claiming a protection it never
    /// applied.
    @discardableResult
    nonisolated static func applyToExistingFiles(using fm: FileManager = .default) -> Int {
        guard let base = AppSupportItem.container,
              let e = fm.enumerator(at: base, includingPropertiesForKeys: nil)
        else { return 0 }

        var touched = 0
        // PATCH 417 — the container's own attribute went through `try?` too,
        // so the one item whose class every file inside inherits was the one
        // item whose failure nothing recorded.
        protect(directory: base, using: fm)
        for case let url as URL in e {
            do {
                try fm.setAttributes([.protectionKey: attribute], ofItemAtPath: url.path)
                touched += 1
            } catch {
                // Deliberately not fatal and deliberately not silent-forever:
                // a file that refuses the attribute is reported through
                // `failures` below rather than pretending the sweep worked.
                note(url, error)
            }
        }
        return touched
    }

    /// The most recent failure, for the diagnostics row. Nil is the normal
    /// answer and is what the privacy pane relies on to say protection is in
    /// force.
    nonisolated(unsafe) static var lastError: String?
}
