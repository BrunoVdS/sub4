//
//  StoreRead.swift
//  Sub4
//
//  Whether a store was READ — D4 step 4, patch 273, ADR-0003 §12.20.
//
//  WHY THIS EXISTS, AND IT IS NOT SYMMETRY WITH `StoreWrite`
//  ---------------------------------------------------------
//  Every authored store in this app loads like this:
//
//      guard let data = try? Data(contentsOf: fileURL) else { return }
//      notes = (try? JSONDecoder.sub4.decode(...)) ?? [:]
//
//  Two `try?`s, and neither of them can tell "there is no file yet" from "the
//  file is there and will not decode". Both produce an empty store, and the
//  app then shows a blank Notes screen, a Progress tab with no reviews, and a
//  matcher with no corrections — with nothing anywhere saying that a file was
//  found and refused. §12.9c built a classifier that can tell those eight
//  conditions apart; it runs from a button on the Database screen and has
//  never been in the launch path.
//
//  A silent empty was survivable while the JSON files were the only copy: the
//  data was still on disk and a relaunch after a fix would find it. THE
//  RECONCILIATION PASS IS WHAT MAKES IT DANGEROUS. That pass — 274, and the
//  reason this patch exists at all — deletes database rows whose record is no
//  longer in the store. Driven by a store that failed to read, it would
//  delete every note, every review and every match decision from the one copy
//  that was still intact.
//
//  So the gate has to be a real answer and not an inference from a count.
//  `.absent` and `.loaded` are both legitimately empty. `.unreadable` is not,
//  and nothing may be deleted on its word.
//
//  ABSENT IS NOT A FAILURE, AND SAYING SO IS THE POINT
//  ---------------------------------------------------
//  Every fresh install has no `notes.json`. §12.9e's survey found
//  `proposals.json` missing on the real device and that was correct — no
//  review had ever run. A journal that shouted about those would be a journal
//  the athlete learns to ignore, which is how the one that mattered would be
//  missed.
//

import Foundation

/// What the last read of a store found.
nonisolated enum StoreLoad: Equatable, Sendable {

    /// The file was there and decoded.
    case loaded

    /// There is no file. A legitimate empty — the state of every fresh
    /// install, and of `proposals.json` until the first review runs.
    case absent

    /// The file is there and could not be turned into records. The reason is
    /// carried for the athlete's own screen and deliberately NOT for the
    /// diagnostic paste, because a file-system error can contain a path.
    case unreadable(String)

    /// Whether an empty store can be believed.
    ///
    /// THE ONE QUESTION 274 ASKS. `.absent` says the athlete has nothing;
    /// `.unreadable` says the app cannot tell. A reconciliation pass may act
    /// on the first and must refuse the second.
    var isTrustworthy: Bool {
        switch self {
        case .loaded, .absent: true
        case .unreadable:      false
        }
    }
}

nonisolated enum StoreRead {

    /// Reads and decodes one store file, saying which of the three happened.
    ///
    /// THE FILE-EXISTS CHECK IS DELIBERATE rather than an inspection of the
    /// error. `Data(contentsOf:)` reports a missing file as
    /// `NSFileReadNoSuchFileError`, which is true today and is a detail of a
    /// framework rather than a decision this app made. Asking whether the file
    /// is there says what we actually mean, and the race it technically opens
    /// resolves to `.unreadable` — the safe side, since nothing is deleted on
    /// that answer.
    static func decode<T: Decodable>(_ type: T.Type,
                                     at url: URL,
                                     decoder: JSONDecoder = JSONDecoder.sub4)
    -> (value: T?, outcome: StoreLoad) {

        guard FileManager.default.fileExists(atPath: url.path) else {
            return (nil, .absent)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return (nil, .unreadable("the file could not be read"))
        }

        // EMPTY IS UNREADABLE, NOT ABSENT. A zero-byte file is what an
        // interrupted write leaves behind — §12.9c's `truncated` condition at
        // its limit — and treating it as "you have nothing" is exactly the
        // mistake this type exists to stop.
        guard !data.isEmpty else {
            return (nil, .unreadable("the file is empty"))
        }

        do {
            return (try decoder.decode(T.self, from: data), .loaded)
        } catch {
            return (nil, .unreadable("the contents did not decode"))
        }
    }
}
