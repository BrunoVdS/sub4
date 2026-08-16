//
//  StoreWrite.swift
//  Sub4
//
//  A save that can fail, and says so — D4 step 1, patch 264.
//
//  WHAT THIS REPLACES
//  ------------------
//  Every store in this app writes like this:
//
//      guard let data = try? JSONEncoder.sub4.encode(notes) else { return }
//      try? data.write(to: fileURL, options: FileProtection.options)
//
//  Two `try?`s and a `return`. If the disk is full, if the file is protected
//  and the phone is locked, if the container is gone — nothing happens, nobody
//  is told, and the caller carries on. `NoteEditorView.commit()` then calls
//  `dismiss()` unconditionally, so the sheet closes, the note appears in the
//  list because it is in memory, and it is gone at the next launch.
//
//  THAT LAST PART IS THE REAL DEFECT. A save that visibly fails is annoying.
//  A save that succeeds, shows you the result, and loses it overnight is worse
//  than one that never happened, because you stop looking.
//
//  WHY NOTES FIRST
//  ---------------
//  Every other store in this app holds something that can be fetched again.
//  Activities, weather, traces, details, the athlete profile — all of it comes
//  back from Strava or from Open-Meteo on the next sync. `notes.json` holds
//  what the athlete WROTE. Nothing anywhere can reproduce it.
//
//  So the store that gets the first failable save is the one where a lost
//  write is permanent, and the escape hatch it offers — see
//  `NoteEditorView` — is "put the text somewhere you can paste it", not
//  "try again later".
//
//  THE STAGES ARE SEPARATE BECAUSE THE ADVICE IS
//  ---------------------------------------------
//  An encoding failure is a defect in this app and no amount of retrying will
//  fix it. A write failure is the phone: full disk, locked device, a container
//  that moved. One of those is worth a second attempt and the other is not,
//  and a single "could not save" cannot tell them apart.
//

import Foundation

/// A store write that did not happen.
nonisolated struct StoreWriteError: LocalizedError, Equatable {

    nonisolated enum Stage: String, Equatable {
        /// `JSONEncoder` refused the value. A defect here, not a condition —
        /// retrying runs the same code over the same value.
        case encoding
        /// The bytes existed and did not reach the disk. Full, locked, or
        /// gone. Worth another attempt.
        case writing
        /// **THE APP DECLINED — patch 372, §12.116.**
        ///
        /// The store's file could not be read at launch, so what is in memory
        /// is not known to be what is on disk, and writing it would destroy
        /// the copy nobody has finished reading. Nothing is broken and nothing
        /// was attempted; retrying this session runs the same refusal, because
        /// the read that failed happened once, at launch.
        ///
        /// 371 is what this case is made of: `weather.json` went from 602
        /// readings to one because a save believed a load that had failed.
        case refused

        var isWorthRetrying: Bool { self == .writing }
    }

    /// The file, by name. `notes.json`, not the full path — a container path
    /// on screen tells the athlete nothing and is different on every install.
    let store: String
    let stage: Stage
    /// What the system said. Kept whole for the diagnostic; not shown raw.
    let reason: String

    /// One sentence, in the terms the athlete would use, and it never says
    /// "try again" for a failure that retrying cannot fix.
    var errorDescription: String? {
        switch stage {
        case .encoding:
            "\(store) could not be prepared for saving. This is a fault in the app."
        case .writing:
            "\(store) could not be written. The phone may be out of space, or "
            + "locked in a way that blocks writing."
        case .refused:
            "\(store) could not be read when the app started, so it has not "
            + "been overwritten. Everything already saved is still there. "
            + "Restart the app to read it again."
        }
    }
}

// MARK: - Writing

nonisolated enum StoreWrite {

    /// Encode and write, saying which half failed.
    ///
    /// ATOMIC, so a failure part-way cannot leave a half-file behind —
    /// `FileProtection.options` carries `.atomic`, and that is why a failed
    /// save here is recoverable at all: the previous contents are still there.
    static func encode<T: Encodable>(_ value: T,
                                     to url: URL,
                                     store: String,
                                     encoder: JSONEncoder = .sub4) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw StoreWriteError(store: store, stage: .encoding,
                                  reason: String(describing: error))
        }
        do {
            try data.write(to: url, options: FileProtection.options)
        } catch {
            throw StoreWriteError(store: store, stage: .writing,
                                  reason: String(describing: error))
        }
    }
}
