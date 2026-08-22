//
//  LegacyFileTest.swift
//  Sub4
//
//  Can the app do without its legacy files? — patch 433, ADR-0003 §12.187.
//
//  WHY THIS EXISTS AT ALL
//  ----------------------
//  Every D7 slice ends with the same unanswered question: **the store now reads
//  rows, so is the file still load-bearing?** Every slice's groundwork has asked
//  for it and no slice has been able to run it.
//
//  §12.160.6 records three patches asking for a disposable device — 1A could
//  not show the restore REPAIRS, 414 could not show a scoped REMOVAL, 415 could
//  not show a removal recorded and surviving. **B5's row 19 is the fourth**, and
//  it is the one that decides whether a slice is COMPLETE rather than merely
//  correct.
//
//  AND THE ROUTE THAT WAS WRITTEN FOR IT IS UNSAFE — §12.186. Xcode's container
//  download omits the database, both payload folders and four stores, silently,
//  in both build configurations. Writing one back destroys everything it does
//  not contain.
//
//  So the app does it to itself, atomically, in one place, reversibly.
//
//  THE RULES THIS OBEYS
//  --------------------
//  1. **IT RENAMES. IT NEVER DELETES.** Files move into a subdirectory beside
//     them and come back from it. Nothing is written over and nothing is
//     removed. "Never use the only copy of authored data for a destructive
//     test" is the standing rule, and the way to obey it is not to be
//     destructive.
//  2. **THE HIDING SURVIVES A RELAUNCH.** The location is a directory on disk,
//     not a flag in memory, so `restore` works after a force-quit — which is
//     the whole point, since the test IS a force-quit.
//  3. **IT NEVER TOUCHES THE DATABASE OR THE PAYLOAD FOLDERS.** Only the named
//     files. `details/` and `streams/` are B4's and are 1,371 files; the
//     database is the thing being tested and hiding it would test nothing.
//  4. **A FILE WRITTEN WHILE HIDDEN IS KEPT.** `StoreLoad.absent` is
//     TRUSTWORTHY (§12.116's ladder), so a store whose file is hidden reads
//     nothing, decides that is legitimate, and **writes a fresh one on the next
//     save**. Restore therefore finds a live file where it wants to put the
//     original back. It moves that one aside as `.written-while-hidden` rather
//     than overwriting it, so both copies exist and neither is a guess.
//  5. **INTERNAL BUILDS ONLY**, through `BuildProvenance` and not `#if DEBUG` —
//     §12.140, RULE 9. A control that hides the athlete's data has no business
//     existing in a build that reached a stranger.
//

import Foundation

/// Moves the legacy files aside and back, so a slice can be asked whether it
/// still needs them.
nonisolated enum LegacyFileTest {

    /// Beside the files, not inside a temporary directory the system may
    /// reclaim. A test that loses what it hid is worse than no test.
    static let directoryName = "hidden-for-test"

    /// **B5's TWO, AND THE LIST IS DELIBERATELY SHORT.**
    ///
    /// `athlete.json` carries the gear and the zones; `weather.json` carries
    /// 606 readings. Both families were flipped at 430 and both are what row 19
    /// asks about.
    ///
    /// **NOT every legacy file.** Hiding seven at once answers "does the app
    /// work without its files", which is D8's question and not a slice's; when
    /// something then broke, nothing would say which file it wanted. B7 and B8
    /// each add their own name here, in their own patch, when their own slice
    /// flips.
    static let names = ["athlete.json", "weather.json"]

    /// Written for the paste and for the two buttons. Every case says what
    /// happened rather than returning a Bool somebody has to interpret.
    enum Outcome: Equatable, Sendable {
        /// `kept` names files the app WROTE while its own were hidden and
        /// which restore moved aside rather than overwrote. **Empty on the
        /// happy path and the whole point when it is not** — patch 433a.
        case moved([String], kept: [String] = [])
        case nothingToMove(String)
        case refused(String)

        var line: String {
            switch self {
            case .moved(let names, let kept):
                let base = names.isEmpty
                    ? "nothing moved"
                    : "moved \(names.sorted().joined(separator: ", "))"
                guard !kept.isEmpty else { return base }
                // **SAID, NOT SILENT.** The first device run of 433 restored
                // an `athlete.json` the app had rewritten while its own was
                // hidden, kept it correctly, and reported only "moved
                // athlete.json, weather.json". The preservation is the
                // interesting half and it said nothing. §12.15, §12.188.
                return base + " — AND KEPT "
                     + kept.sorted().joined(separator: ", ")
                     + ", written by the app while hidden"
            case .nothingToMove(let why): return "nothing to do — \(why)"
            case .refused(let why):       return "REFUSED — \(why)"
            }
        }
    }

    /// What is hidden right now. Read off the disk, so it is still right after
    /// a force-quit.
    static func hiddenNow(in container: URL) -> [String] {
        contents(of: container).filter { names.contains($0) }.sorted()
    }

    /// **FILES THE APP WROTE WHILE ITS OWN WERE HIDDEN — patch 433a.**
    ///
    /// `StoreLoad.absent` is trustworthy, so a store whose file is hidden reads
    /// nothing, decides that is legitimate and saves a fresh one. Restore keeps
    /// that write; **this is what makes the keeping visible.** On the first
    /// device run of 433 it happened to `athlete.json` inside sixty seconds and
    /// nothing said so — which weakened the very row the test exists for.
    static func writtenWhileHidden(in container: URL) -> [String] {
        contents(of: container)
            .filter { $0.hasSuffix(".written-while-hidden") }
            .sorted()
    }

    // MARK: - The inventory a support paste may carry — patch 439, §12.194

    /// One file inside `hidden-for-test/`, said in the four terms the runbook
    /// allows into redacted output: **path, hash, bytes, status.**
    ///
    /// **NEVER THE CONTENTS.** `athlete.json` names gear and `weather.json`
    /// names 606 readings taken at places and times; §12.7 governs what leaves
    /// this phone in a paste, and a hash is an identity rather than a
    /// disclosure.
    struct Artifact: Equatable, Sendable, Codable {
        /// Relative to Application Support, so it is a path a person can act on
        /// without being an absolute one that names the container UUID.
        let path: String
        let sha256: String
        let bytes: Int
        let status: Status

        enum Status: String, Equatable, Sendable, Codable {
            /// The original, moved aside by `hide`. **While this exists the
            /// live file does not, so this is the only copy.**
            case hiddenOriginal = "the only copy — the live file is hidden"
            /// Written by a store while its own file was hidden, kept by
            /// `restore` rather than overwritten (§12.188).
            case keptFromAnEarlierTest = "kept from an earlier test"
            /// A receipt written by `TestArtifactRemoval` — patch 441. The
            /// folder is the app's record of its own internal tests, so what it
            /// used to hold belongs in it.
            ///
            /// **IT NEEDED ITS OWN CASE, AND NOT FOR TIDINESS.** Without one it
            /// would classify as `unrecognised`, and `TestArtifactRemoval`
            /// refuses when the folder holds anything unrecognised — so the
            /// first successful removal would have left behind the exact file
            /// that made every later removal impossible. §12.196.3.
            case removalReceipt = "a receipt for a removal"
            /// Something else, in a directory only this file writes to. Named
            /// rather than skipped: a category that quietly drops what it does
            /// not recognise is §12.132.
            case unrecognised = "unrecognised — not written by this control"
        }

        var line: String { "\(path) · \(bytes) bytes · \(sha256) · \(status.rawValue)" }
    }

    /// Everything in `hidden-for-test/`, hashed. Empty when the directory does
    /// not exist, which is the ordinary state.
    static func inventory(in container: URL?) -> [Artifact] {
        guard let container else { return [] }
        let dir = container.appendingPathComponent(directoryName)
        let hidden = Set(names)
        return contents(of: container).sorted().map { name in
            let url = dir.appendingPathComponent(name)
            let data = (try? Data(contentsOf: url)) ?? Data()
            let status: Artifact.Status =
                hidden.contains(name) ? .hiddenOriginal
                : name.hasSuffix(".written-while-hidden") ? .keptFromAnEarlierTest
                : (name.hasPrefix(TestArtifactRemoval.receiptPrefix)
                   && name.hasSuffix(".json")) ? .removalReceipt
                : .unrecognised
            return Artifact(path: "\(directoryName)/\(name)",
                            sha256: LegacySnapshot.hex(data),
                            bytes: data.count,
                            status: status)
        }
    }

    /// **UNCONDITIONAL, AND IT CARRIES A DENOMINATOR.** A section that renders
    /// nothing when the folder is empty cannot be told from one nobody wired in
    /// — §12.54.2, and this folder is the athlete's own data.
    static func inventoryLines(in container: URL?) -> [String] {
        let found = inventory(in: container)
        guard !found.isEmpty else {
            return ["internal test artifacts: none — hidden-for-test/ is empty or absent"]
        }
        return ["internal test artifacts: \(found.count)"]
             + found.map { "  " + $0.line }
    }

    private static func contents(of container: URL) -> [String] {
        let dir = container.appendingPathComponent(directoryName)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// **UNCONDITIONAL, AND IT NAMES THE FILES.** A test that leaves data
    /// hidden and says nothing is a test that eats an athlete's history —
    /// §12.54.2 with something at stake.
    static func line(in container: URL?) -> String {
        guard let container else {
            return "Application Support is unreachable, so nothing could be checked"
        }
        let hidden = hiddenNow(in: container)
        let kept = writtenWhileHidden(in: container)
        var out = hidden.isEmpty
            ? "none — every legacy file is in its place"
            : "HIDDEN: \(hidden.joined(separator: ", ")) — put them back"
        // **UNCONDITIONAL ONCE IT EXISTS, AND IT OUTLIVES THE TEST.** A kept
        // copy is a fact about the container, not about the current hiding, so
        // it is reported whether or not anything is hidden now. Patch 433a.
        if !kept.isEmpty {
            out += " · kept from an earlier test: \(kept.joined(separator: ", "))"
        }
        return out
    }

    static func hide(in container: URL) -> Outcome {
        let fm = FileManager.default
        let dir = container.appendingPathComponent(directoryName)
        // REFUSE RATHER THAN MERGE. A second hide over a first would bury the
        // original under a file the app wrote while it was hidden.
        let already = hiddenNow(in: container)
        guard already.isEmpty else {
            return .refused("\(already.joined(separator: ", ")) already hidden — "
                          + "put them back first")
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .refused(String(describing: error))
        }

        var moved: [String] = []
        for name in names {
            let live = container.appendingPathComponent(name)
            guard fm.fileExists(atPath: live.path) else { continue }
            do {
                try fm.moveItem(at: live, to: dir.appendingPathComponent(name))
                moved.append(name)
            } catch {
                // PARTIAL IS REPORTED, NOT ROLLED BACK. Whatever moved is in a
                // directory this file can find again, and `restore` is the way
                // back; a rollback that also failed would leave two half-states
                // and no sentence describing either.
                return .refused("\(name): \(error) — \(moved.count) already moved, "
                              + "put them back")
            }
        }
        return moved.isEmpty
            ? .nothingToMove("neither file is present to begin with")
            : .moved(moved)
    }

    static func restore(in container: URL) -> Outcome {
        let fm = FileManager.default
        let dir = container.appendingPathComponent(directoryName)
        let hidden = hiddenNow(in: container)
        guard !hidden.isEmpty else {
            return .nothingToMove("nothing is hidden")
        }

        var moved: [String] = []
        var kept: [String] = []
        for name in hidden {
            let live = container.appendingPathComponent(name)
            let stored = dir.appendingPathComponent(name)
            do {
                // RULE 4 — see the header. The store wrote a fresh file while
                // its own was hidden, and both are kept. **Patch 433a REPORTS
                // it**: the first device run did exactly this and said nothing.
                if fm.fileExists(atPath: live.path) {
                    let keptName = "\(name).written-while-hidden"
                    try? fm.removeItem(at: dir.appendingPathComponent(keptName))
                    try fm.moveItem(at: live,
                                    to: dir.appendingPathComponent(keptName))
                    kept.append(keptName)
                }
                try fm.moveItem(at: stored, to: live)
                moved.append(name)
            } catch {
                return .refused("\(name): \(error) — \(moved.count) restored")
            }
        }
        return .moved(moved, kept: kept)
    }
}
