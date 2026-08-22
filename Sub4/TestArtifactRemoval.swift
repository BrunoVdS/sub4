//
//  TestArtifactRemoval.swift
//  Sub4
//
//  Clearing one internal-test leftover, with four refusals — patch 441,
//  ADR-0003 §12.196.
//
//  WHAT THIS IS FOR
//  ----------------
//  433's control renames the legacy files aside and back. When a store writes a
//  fresh file while its own is hidden, `restore` KEEPS that write rather than
//  overwriting the original (§12.188) — so the folder can be left holding
//  `athlete.json.written-while-hidden`. One is on Bruno's phone from 21 August.
//
//  The runbook's Task 0A asks for a scoped, app-owned removal of exactly that,
//  and it names the shape: **preview → confirm → remove → verify → receipt**,
//  refusing unless four things are true. This is that, and every one of the four
//  is a REFUSAL WITH A REASON rather than a silent no.
//
//  WHY IT IS NOT `try? fm.removeItem`
//  ----------------------------------
//  The file is a copy of the athlete's own data. Three standing rules bear on
//  it: never use the only copy of authored data for a destructive test; never
//  use Xcode's Replace Container (§12.186); and never delete without a receipt.
//  A one-line delete obeys none of them, and would have been indistinguishable
//  from one that removed the wrong file.
//
//  THE FOUR REFUSALS, AND WHY EACH ONE
//  -----------------------------------
//  1. **Nothing may be hidden.** While a test is running the live file is
//     ABSENT and the folder holds the only copy of it. Removing anything from
//     the folder in that state risks the original.
//  2. **The live counterpart must exist AND READ.** Not "exist" — read, through
//     `LegacyClassifier`, the same rule the survey row uses (§12.43). A live
//     `athlete.json` that is truncated makes the leftover the best copy on the
//     phone, and that is the moment not to delete it.
//  3. **The path must be on an allow-list built from the vocabulary**, never a
//     wildcard. `LegacyFileTest.names` decides what may be removed; anything
//     else in the folder is refused BY NAME. A `*.written-while-hidden` glob
//     would delete a file some future patch puts there for a different reason.
//  4. **A complete snapshot still on disk must hold a hashed copy of the live
//     counterpart.** Not "a snapshot exists" — one that copied and verified
//     THIS file. That is what makes the removal reversible from evidence rather
//     than from memory.
//
//  AND `remove` RE-EVALUATES ALL FOUR. It does not trust the preview it is
//  handed. A preview can be minutes old and a test can have started in between;
//  a confirmation is a permission, not a lock.
//

import Foundation

/// **MAIN-ACTOR, AND THE THREE VALUE TYPES BELOW ARE NOT.**
///
/// This reaches `LegacyClassifier`, which is the module default, so the enum
/// takes the default too rather than dragging a classifier off the actor for
/// the convenience of one caller (§12.43: call the rule where it lives). The
/// `Preview`, `Receipt` and `Refusal` it produces are values a view stores and
/// hands back later, so those ARE `nonisolated` — the split SE-0434 asks for.
enum TestArtifactRemoval {

    // MARK: Why it will not

    nonisolated enum Refusal: Equatable, Sendable, Error {
        case containerUnreachable
        case nothingToRemove
        case somethingIsHidden([String])
        case notAllowListed([String])
        case liveCounterpartMissing(String)
        case liveCounterpartUnreadable(String, String)
        case noVerifiedSnapshot(String)
        /// The removal ran and the file is still there. The worst outcome and
        /// the one a `try?` would have hidden.
        case stillPresentAfterRemoval(String)
        case couldNotRemove(String)

        var line: String {
            switch self {
            case .containerUnreachable:
                "Application Support is unreachable, so nothing could be checked"
            case .nothingToRemove:
                "nothing to remove — no file kept from an earlier test"
            case .somethingIsHidden(let names):
                "REFUSED — \(names.joined(separator: ", ")) is hidden right now, "
                + "so this folder holds the only copy. Put the files back first"
            case .notAllowListed(let names):
                "REFUSED — \(names.joined(separator: ", ")) is not a file this "
                + "control wrote, so it will not be removed by it"
            case .liveCounterpartMissing(let name):
                "REFUSED — \(name) is not on this phone, so the copy is the only one"
            case .liveCounterpartUnreadable(let name, let why):
                "REFUSED — \(name) \(why), so the copy may be the better one"
            case .noVerifiedSnapshot(let name):
                "REFUSED — no complete snapshot on this phone holds a verified "
                + "copy of \(name)"
            case .stillPresentAfterRemoval(let path):
                "FAILED — \(path) is still there after the removal"
            case .couldNotRemove(let why):
                "FAILED — \(why)"
            }
        }
    }

    // MARK: What it would do

    nonisolated struct Preview: Equatable, Sendable {
        /// The one file. Singular deliberately: a control that removes "all
        /// leftovers" is a wildcard wearing a plural.
        let target: LegacyFileTest.Artifact?
        /// The live file the target is a copy of.
        let counterpart: String?
        /// The snapshot that holds a verified copy of the counterpart.
        let snapshotID: String?
        let refusals: [Refusal]

        var canProceed: Bool { target != nil && refusals.isEmpty }

        /// **UNCONDITIONAL, AND IT ALWAYS SAYS WHY.** A preview that renders
        /// nothing when it cannot proceed is a preview that reads like a
        /// permission — §12.15 over a delete button.
        var lines: [String] {
            var out: [String] = []
            if let t = target {
                out.append("would remove: \(t.path)")
                out.append("  \(t.bytes) bytes · \(t.sha256)")
            }
            if let c = counterpart {
                out.append("  the live file it copies: \(c)")
            }
            if let s = snapshotID {
                out.append("  a complete snapshot holding \(counterpart ?? "it"): \(s)")
            }
            for r in refusals { out.append("  " + r.line) }
            if out.isEmpty { out.append(Refusal.nothingToRemove.line) }
            if target != nil && refusals.isEmpty {
                out.append("  every check passed — this will remove one file")
            }
            return out
        }
    }

    // MARK: What it did

    nonisolated struct Receipt: Equatable, Sendable {
        let path: String
        let sha256: String
        let bytes: Int
        /// The evidence that made it safe, named in the receipt so the record
        /// stands on its own — a receipt citing "a snapshot" is not a receipt.
        let snapshotID: String
        let removedUTC: String
        /// Read back AFTER the removal. §12.69: a removal that does not check
        /// is a removal that reports its own intention.
        let verifiedAbsent: Bool
        let appVersion: String

        var line: String {
            "removed \(path) · \(bytes) bytes · \(sha256) · "
            + "snapshot \(snapshotID) · \(removedUTC) · "
            + (verifiedAbsent ? "verified absent" : "STILL PRESENT")
        }
    }

    /// The receipt is written INTO the folder it cleaned, and that is
    /// deliberate — the folder is the app's record of its own internal tests,
    /// so what it used to hold belongs in it. `LifecycleLog` is memory-only by
    /// design (a record of a deletion must not outlive the deletion it
    /// describes), and this one has to be citable in a Task 0A manifest weeks
    /// later, so it needs somewhere durable that "Delete local data" still
    /// removes whole.
    nonisolated static let receiptPrefix = "removed-"

    // MARK: The allow-list

    /// **BUILT FROM THE VOCABULARY, NOT MATCHED WITH A GLOB.** Only a file this
    /// control could itself have written may be removed by it.
    nonisolated static var removableNames: Set<String> {
        Set(LegacyFileTest.names.map { "\($0).written-while-hidden" })
    }

    /// `athlete.json.written-while-hidden` → `athlete.json`, and nil for
    /// anything not on the allow-list.
    nonisolated static func counterpart(of artifactName: String) -> String? {
        LegacyFileTest.names.first { "\($0).written-while-hidden" == artifactName }
    }

    // MARK: Preview

    static func preview(in container: URL?,
                        fm: FileManager = .default) -> Preview {
        guard let container else {
            return Preview(target: nil, counterpart: nil, snapshotID: nil,
                           refusals: [.containerUnreachable])
        }

        let held = LegacyFileTest.inventory(in: container)
        let kept = held.filter { $0.status == .keptFromAnEarlierTest }
        let strangers = held.filter { $0.status == .unrecognised }

        var refusals: [Refusal] = []

        // REFUSAL 1 — nothing may be hidden.
        let hidden = LegacyFileTest.hiddenNow(in: container)
        if !hidden.isEmpty { refusals.append(.somethingIsHidden(hidden)) }

        // REFUSAL 3, first half — anything this control did not write is named
        // and left alone rather than swept up with the rest.
        if !strangers.isEmpty {
            refusals.append(.notAllowListed(strangers.map(\.path).sorted()))
        }

        guard let target = kept.first else {
            return Preview(target: nil, counterpart: nil, snapshotID: nil,
                           refusals: refusals.isEmpty ? [.nothingToRemove] : refusals)
        }

        // REFUSAL 3, second half.
        let artifactName = (target.path as NSString).lastPathComponent
        guard let live = counterpart(of: artifactName) else {
            refusals.append(.notAllowListed([target.path]))
            return Preview(target: target, counterpart: nil, snapshotID: nil,
                           refusals: refusals)
        }

        // REFUSAL 2 — exists AND reads, through the rule the survey uses.
        let liveURL = container.appendingPathComponent(live)
        let data = try? Data(contentsOf: liveURL)
        if data == nil {
            refusals.append(.liveCounterpartMissing(live))
        } else if let store = LegacyStore.allCases.first(where: {
            $0.item.pathComponent == live
        }) {
            let condition = LegacyClassifier.classify(data, as: store)
            if condition.isFault {
                refusals.append(.liveCounterpartUnreadable(live, condition.summary))
            }
        } else {
            // A name on the allow-list that no store declares. Cannot happen
            // today and is a refusal rather than a shrug if it ever does.
            refusals.append(.liveCounterpartUnreadable(
                live, "is not a file any store declares"))
        }

        // REFUSAL 4 — a complete snapshot, still on disk, that copied and
        // hashed THIS file.
        let snapshot = LegacySnapshot.manifests(base: container, fm: fm).first { m in
            m.isComplete && m.entries.contains { e in
                e.declared == live && e.exists && e.copied && e.sha256 != nil
            }
        }
        if snapshot == nil { refusals.append(.noVerifiedSnapshot(live)) }

        return Preview(target: target, counterpart: live,
                       snapshotID: snapshot?.id, refusals: refusals)
    }

    // MARK: Remove

    /// - Returns: the receipt, or the reason it did not happen.
    ///
    /// **IT RE-PREVIEWS.** The `Preview` handed in is what the reader agreed
    /// to; it is not evidence about the disk now. Both must agree — same path,
    /// same hash — or the answer is a refusal.
    @discardableResult
    static func remove(confirming agreed: Preview,
                       in container: URL?,
                       now: Date,
                       appVersion: String,
                       fm: FileManager = .default) -> Result<Receipt, Refusal> {
        let fresh = preview(in: container, fm: fm)
        guard let target = fresh.target, let snapshotID = fresh.snapshotID,
              fresh.refusals.isEmpty else {
            return .failure(fresh.refusals.first ?? .nothingToRemove)
        }
        // The reader agreed to a specific file. If the disk now holds a
        // different one, that agreement does not transfer.
        guard agreed.target == target else {
            return .failure(.notAllowListed([target.path]))
        }
        guard let container else { return .failure(.containerUnreachable) }

        let url = container
            .appendingPathComponent(LegacyFileTest.directoryName, isDirectory: true)
            .appendingPathComponent((target.path as NSString).lastPathComponent)
        do {
            try fm.removeItem(at: url)
        } catch {
            return .failure(.couldNotRemove(String(describing: error)))
        }

        let stillThere = fm.fileExists(atPath: url.path)
        let receipt = Receipt(path: target.path,
                              sha256: target.sha256,
                              bytes: target.bytes,
                              snapshotID: snapshotID,
                              removedUTC: iso8601(now),
                              verifiedAbsent: !stillThere,
                              appVersion: appVersion)
        write(receipt, in: container, now: now, fm: fm)
        guard !stillThere else {
            return .failure(.stillPresentAfterRemoval(target.path))
        }
        return .success(receipt)
    }

    /// **WRITTEN EVEN WHEN THE REMOVAL FAILED**, because a removal that was
    /// attempted and did not take is the one a reader most needs a record of.
    nonisolated private static func write(_ receipt: Receipt, in container: URL,
                              now: Date, fm: FileManager) {
        let dir = container.appendingPathComponent(LegacyFileTest.directoryName,
                                                   isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(receiptPrefix)\(stamp(now)).json"
        let body: [String: Any] = [
            "path": receipt.path,
            "sha256": receipt.sha256,
            "bytes": receipt.bytes,
            "snapshot": receipt.snapshotID,
            "removedUTC": receipt.removedUTC,
            "verifiedAbsent": receipt.verifiedAbsent,
            "app": receipt.appVersion
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Time, written out rather than shared

    /// `DayKey`'s formatters are the app's and are tuned for local days; these
    /// two are UTC and belong to a receipt. Local instances, so nothing here is
    /// a mutable global (`DayKey` already carries two under
    /// `nonisolated(unsafe)` and a third is not worth a timestamp).
    nonisolated static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }

    nonisolated static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
