//
//  EvidencePackageShare.swift
//  Sub4
//
//  Handing over a copy of everything — patch 446, ADR-0003 §12.202.
//
//  ONE FILE, NOT A FOLDER
//  ----------------------
//  `UIActivityViewController` will take a directory, and what each destination
//  then does with it varies. A validator on a Mac wants **one artefact whose
//  hash can be quoted**, so the package is zipped first — through
//  `NSFileCoordinator`'s `.forUploading`, which is the API Apple provides for
//  exactly this and which no hand-rolled archiver here could match.
//
//  **THE ZIP IS PRODUCED INTO A TEMPORARY DIRECTORY, NEVER BESIDE THE
//  PACKAGE.** A `.zip` appearing inside `evidence/` would be swept into the
//  next capture's fingerprint, and — worse — into the next package.
//
//  WHAT THE WARNING HAS TO SAY
//  ---------------------------
//  This is the single most sensitive thing this app produces: every session
//  note, every route, every heart-rate trace and a copy of the database, in one
//  file. The app applies its protection class while the package sits on the
//  phone; **the moment it leaves, that is over**, and the only honest thing to
//  do is say so before the share sheet opens rather than in a footnote
//  afterwards.
//

import Foundation

nonisolated enum EvidencePackageShare {

    /// The sentences shown before anything is handed over. Held here rather
    /// than in the view so they can be asserted — a warning nobody can test is
    /// a warning that quietly loses a clause.
    static let warningTitle = "This is a copy of everything"

    static let warningLines = [
        "A package holds every session note you have written, every route, "
        + "every heart-rate trace, and a copy of the whole database.",
        "While it is on this phone it carries the same protection as the rest "
        + "of your data — it cannot be read before you first unlock.",
        "Once it leaves, that protection is over. Send it somewhere encrypted "
        + "that you control, and delete it from there when you are finished.",
        "Never send a package to an AI provider, and never post one anywhere."
    ]

    enum Failure: Equatable, Sendable, Error {
        case packageMissing(String)
        case couldNotZip(String)
        case couldNotStage(String)

        var line: String {
            switch self {
            case .packageMissing(let id): "REFUSED — there is no package called \(id)"
            case .couldNotZip(let why):   "FAILED — the package could not be packed: \(why)"
            case .couldNotStage(let why): "FAILED — the packed copy could not be kept: \(why)"
            }
        }
    }

    /// `sub4-evidence-<captureID>.zip`, in a temporary directory.
    static func fileName(for captureID: String) -> String {
        "sub4-evidence-\(captureID).zip"
    }

    /// - Parameter coordinate: injected so the failure paths can be driven
    ///   without a filesystem that refuses to co-operate (§12.69).
    static func zip(packageAt package: URL,
                    captureID: String,
                    into temporary: URL,
                    fm: FileManager = .default,
                    coordinate: (URL, (URL) throws -> Void) throws -> Void = Self.coordinateForUploading)
    -> Result<URL, Failure> {
        guard fm.fileExists(atPath: package.path) else {
            return .failure(.packageMissing(captureID))
        }
        let destination = temporary.appendingPathComponent(fileName(for: captureID))
        try? fm.removeItem(at: destination)

        var staged: Error?
        do {
            try coordinate(package) { zipped in
                do {
                    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
                    // COPIED INSIDE THE BLOCK. The coordinator's URL is valid
                    // only until it returns, and reading it afterwards is the
                    // classic way to ship a file that is sometimes there.
                    try fm.copyItem(at: zipped, to: destination)
                    // The same protection class the package itself carries, for
                    // as long as the copy is still on this phone.
                    FileProtection.protect(directory: destination, using: fm)
                } catch {
                    staged = error
                }
            }
        } catch {
            return .failure(.couldNotZip(String(describing: error)))
        }
        if let staged { return .failure(.couldNotStage(String(describing: staged))) }
        guard fm.fileExists(atPath: destination.path) else {
            return .failure(.couldNotZip("the coordinator produced nothing"))
        }
        return .success(destination)
    }

    /// The real one. `NSFileCoordinator` with `.forUploading` hands back a zip
    /// of the directory it was given.
    static func coordinateForUploading(_ url: URL,
                                       _ body: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading,
                                       error: &coordinatorError) { zipped in
            do { try body(zipped) } catch { thrown = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrown { throw thrown }
    }
}
