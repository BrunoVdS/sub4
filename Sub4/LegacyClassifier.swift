//
//  LegacyClassifier.swift
//  Sub4
//
//  What is wrong with this file — step 3.4, patch 260, migration contract
//  items 2 and 4.
//
//  THE BEHAVIOUR THIS REPLACES
//  ---------------------------
//  `LegacyFixtureTests.todayEverythingBrokenLooksTheSame` has asserted since
//  patch 246 that an empty file, a whitespace file, a truncated file, a
//  corrupt file and a captive portal's HTML all fail in exactly the same way:
//  `try decode` throws, and nothing anywhere can tell them apart.
//
//  That test was written to be replaced, and its assertion is still TRUE —
//  all five still throw. What changes is that throwing is no longer the whole
//  answer. Its name became false before its `#expect` did, which is the more
//  interesting half of the story: a test can keep passing long after it has
//  stopped describing the system.
//
//  WHY THE DIFFERENCE IS WORTH THE CODE
//  ------------------------------------
//  Because the athlete does different things about them.
//
//  - `absent` — a fresh install. NOT A FAULT, contract item 2, and the single
//    most important line in this file. A migration that reports "notes.json is
//    missing" on a phone that has never had notes is a migration that cries
//    wolf on day one.
//  - `empty` / `whitespace` — a write interrupted before anything flushed.
//    Nothing was ever in it, so nothing was lost.
//  - `truncated` — a write interrupted PART WAY. Something was in it. This is
//    the one where a backup is worth restoring, and the project has seen it:
//    two reinstalls in one week.
//  - `corrupt` — full length, broken structure. Not a partial write, so a
//    backup restore is the wrong advice.
//  - `notJSON` — a captive portal's sign-in page written where a response was
//    expected. Looks like data until somebody opens it.
//  - `wrongContainer` — parses, but is an array where an object belongs. A
//    file from a different store, or a different version of this one.
//  - `undecodable` — parses, right container, and the typed decode refused.
//    The wrong date strategy lands here, which is contract item 4 becoming
//    visible instead of becoming a silent 1970.
//  - `identityMismatch` — patch 261, contract item 5. Decodes perfectly and
//    says two different things about who a record is.
//  - `duplicateIdentity` — the array stores' version of the same: two records,
//    one identity, no outer key to disagree with.
//
//  THE LAST TWO ARE A DIFFERENT KIND OF FAULT FROM THE OTHERS
//  ----------------------------------------------------------
//  Everything above them is a file that will not read. These two READ. The
//  bytes are fine, the types are fine, and the file is wrong anyway — which is
//  why `decoded` exists beside `isFault`, and why the quarantine that follows
//  holds records back rather than rejecting files.
//
//  A fault that fails loudly gets fixed. A fault that decodes cleanly gets
//  imported, and then the wrong note sits on the wrong day for as long as the
//  app lives.
//
//  Five outcomes collapsed into "it threw" is a screen that can only say
//  "something is wrong with your data". These are seven things a person can
//  act on.
//
//  THE STRUCTURAL PASS IS NONISOLATED; THE TYPED PASS CANNOT BE
//  -----------------------------------------------------------
//  `LegacyShape` works on bytes and knows nothing about the app's types, so it
//  is `nonisolated` and testable from anywhere. The typed decode is
//  `@MainActor`, because `Activity`, `NotesStore.Note`, `ProposalStore.Record`,
//  `ActivityWeather` and `ActivityDetail` all are — see the header of
//  `LegacyFixtureTests`, which worked this out first.
//
//  That is a correction to §12.9b, which claimed the reader would run
//  nonisolated. It cannot, and nine mirrors to make it so would be a far worse
//  trade than the one `AthleteFile` made for one private type.
//

import Foundation

// MARK: - What the bytes are, before anything types them

/// The structural verdict: everything that can be decided without knowing what
/// the file is supposed to contain.
nonisolated enum LegacyShape: Equatable {
    case absent
    case empty
    case whitespace
    case notJSON
    case truncated
    case corrupt
    case parsed(LegacyStore.Container)

    /// Bytes in, verdict out. No file system, no app types, no isolation.
    ///
    /// ORDER MATTERS AND IS NOT ARBITRARY. Each test is cheaper and more
    /// certain than the one after it, and an earlier answer is never wrong: a
    /// zero-byte file cannot also be truncated JSON.
    static func of(_ data: Data?) -> LegacyShape {
        guard let data else { return .absent }
        if data.isEmpty { return .empty }

        // Whitespace only. The same interrupted write as `.empty`, one buffer
        // later, and worth its own case because "the file exists and has
        // bytes" reads differently in a diagnostic.
        let bytes = [UInt8](data)
        guard let firstIndex = bytes.firstIndex(where: { !isSpace($0) }) else {
            return .whitespace
        }

        // Every one of the eleven inputs is an object or an array at the top
        // level. Anything else is not this app's file — the captive portal
        // case, which begins `<`.
        let opener = bytes[firstIndex]
        let expected: LegacyStore.Container
        switch opener {
        case UInt8(ascii: "{"): expected = .object
        case UInt8(ascii: "["): expected = .array
        default: return .notJSON
        }

        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            return .parsed(expected)
        }

        // It looks like JSON and is not. Truncated or corrupt, and the two
        // deserve different advice, so this does not guess from the error
        // message — Foundation's wording is not a contract — but from the
        // structure itself.
        return isUnterminated(bytes) ? .truncated : .corrupt
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// Whether the document simply stops: a bracket left open, or a string
    /// left unclosed.
    ///
    /// A BALANCE SCAN RATHER THAN A LOOK AT THE LAST CHARACTER. A 60% prefix
    /// of a JSON file can end on `}` — every nested object closes somewhere —
    /// and a classifier that read only the final byte would call that corrupt
    /// and tell the athlete not to restore the backup that would fix it.
    ///
    /// Quotes and escapes are tracked because a `{` inside a string is not a
    /// bracket, and text this app stores contains both: session notes are free
    /// prose and proposal evidence is Markdown.
    private static func isUnterminated(_ bytes: [UInt8]) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false

        for b in bytes {
            if escaped { escaped = false; continue }
            if inString {
                switch b {
                case UInt8(ascii: "\\"): escaped = true
                case UInt8(ascii: "\""): inString = false
                default: break
                }
                continue
            }
            switch b {
            case UInt8(ascii: "\""):           inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
            default: break
            }
        }
        return inString || depth > 0
    }
}

// MARK: - What the file is

/// One record that is filed under one name and claims another.
///
/// Both names are carried, and neither is called the right one. See
/// `LegacyClassifier.identity` for why that is a decision rather than an
/// omission.
nonisolated struct IdentityFault: Equatable, Hashable {
    /// The name the record is stored under — the dictionary key, or the file
    /// name for the two directory stores.
    let filedAs: String
    /// The name the record gives itself.
    let claims: String
    /// Which field it gave it in. `sessionUid` for notes, `activityId` for
    /// everything else — carried so a diagnostic can say where to look.
    let field: String

    /// For a list on screen. Says both names and takes no side.
    var line: String { "filed as \(filedAs) · \(field) says \(claims)" }
}

nonisolated enum LegacyCondition: Equatable {
    /// No file. A fresh install, or a store this athlete never used. NOT a
    /// fault — contract item 2.
    case absent
    case empty
    case whitespace
    case notJSON
    case truncated
    case corrupt
    case wrongContainer(expected: LegacyStore.Container, found: LegacyStore.Container)
    /// Parsed, right container, and the store's own decoder refused it. The
    /// reason is carried because "it did not decode" is the answer this whole
    /// file exists to stop giving.
    case undecodable(String)
    /// Decodes perfectly, and says two different things about who a record is
    /// — patch 261, contract item 5. The records at fault are named, because
    /// "this file has a problem" is not something anybody can act on and "the
    /// entry filed under w99-sun says it is w03-tue" is.
    case identityMismatch([IdentityFault])
    /// Decodes perfectly, and two records claim one identity. The array
    /// stores' version of the same fault: there is no outer key to disagree
    /// with, so the disagreement is between the rows.
    case duplicateIdentity([String])
    case readable

    /// Whether this needs somebody to do something.
    ///
    /// `absent` is deliberately not a fault and `readable` obviously is not.
    /// Everything else is, including `whitespace` — a file the app created and
    /// then wrote nothing into is a write that failed.
    var isFault: Bool {
        switch self {
        case .absent, .readable: false
        default: true
        }
    }

    /// Whether the file decoded. Both identity faults did — that is what makes
    /// them dangerous, and what separates "hold this back" from "this is
    /// broken".
    var decoded: Bool {
        switch self {
        case .readable, .identityMismatch, .duplicateIdentity: true
        default: false
        }
    }

    /// One line, in the terms the athlete would use. No file paths and no
    /// error domains — those belong in the diagnostic, not on the screen.
    var summary: String {
        switch self {
        case .absent:      "not on this phone"
        case .empty:       "the file is empty — a write that never started"
        case .whitespace:  "the file holds nothing but blank space"
        case .notJSON:     "this is not one of the app's files"
        case .truncated:   "the file stops part way — a write that was interrupted"
        case .corrupt:     "the file is complete and its structure is broken"
        case .wrongContainer(let expected, let found):
            "expected a JSON \(expected.rawValue) and found a \(found.rawValue)"
        case .undecodable: "the file reads as JSON but not as this store's data"
        case .identityMismatch(let faults):
            "\(faults.count) record\(faults.count == 1 ? "" : "s") filed under one name and claiming another"
        case .duplicateIdentity(let ids):
            "\(ids.count) identit\(ids.count == 1 ? "y" : "ies") claimed by more than one record"
        case .readable:    "readable"
        }
    }

    /// Whether restoring a backup is the right advice. Only `truncated` says
    /// yes: something was written and part of it survived. An empty file lost
    /// nothing, and a corrupt one is not a length problem.
    var suggestsRestore: Bool { self == .truncated }
}

// MARK: - Putting the two together

@MainActor
enum LegacyClassifier {

    /// The structural pass, then the typed one, then the identity one.
    ///
    /// A file that parses as the right container can still be unreadable —
    /// the wrong date strategy is exactly that — so `readable` is only ever
    /// returned by the store's own decoder succeeding. Nothing here infers
    /// success from the absence of a structural failure.
    ///
    /// And a file that decodes can still be wrong. That is the third pass, and
    /// the reason it is last: an identity fault is a DOMAIN fault, not a
    /// decoding one. The bytes are fine, the types are fine, and the file
    /// states one fact twice with two different answers.
    ///
    /// - Parameter named: the id carried by the FILE NAME, for the two stores
    ///   that are directories of `<id>.json`. Nil means the caller does not
    ///   know it — a fixture in a test, or bytes from somewhere other than
    ///   disk — and the check is skipped rather than guessed at.
    static func classify(_ data: Data?,
                         as store: LegacyStore,
                         named: String? = nil) -> LegacyCondition {
        switch LegacyShape.of(data) {
        case .absent:     return .absent
        case .empty:      return .empty
        case .whitespace: return .whitespace
        case .notJSON:    return .notJSON
        case .truncated:  return .truncated
        case .corrupt:    return .corrupt
        case .parsed(let found):
            guard found == store.container else {
                return .wrongContainer(expected: store.container, found: found)
            }
            guard let data else { return .absent }   // unreachable; .parsed implies bytes
            do {
                try decode(data, as: store)
            } catch {
                return .undecodable(String(describing: error))
            }
            return identity(of: data, as: store, named: named)
        }
    }

    // MARK: Identity — contract item 5

    /// NEITHER NAME WINS. That is the decision this function encodes, and it
    /// is the whole of contract item 5.
    ///
    /// The tempting fix is to prefer one: the outer key, because it is what
    /// the store looks the record up by, or the embedded id, because it
    /// travelled with the record. Both are guesses about which half of a
    /// contradiction is the true one, made by code that has no way to know.
    /// A note filed under `w99-sun` that says it belongs to `w03-tue` is
    /// either a note attached to the wrong session or a session renamed and
    /// half-written — and those want opposite repairs.
    ///
    /// So the record is held back and named, and a person decides. That costs
    /// one entry in a list. Picking wrong costs a note on the wrong day for as
    /// long as the app lives, silently.
    ///
    /// WORKS ON THE RAW JSON, NOT THE DECODED VALUES, because the decoded
    /// value has already lost the evidence: `[String: Note]` keeps the outer
    /// key and the embedded one, but `[Activity]` cannot tell you that two
    /// rows collided until you go looking, and a dictionary decode of a file
    /// with a repeated key silently keeps the last. The bytes still have all
    /// of it.
    static func identity(of data: Data,
                         as store: LegacyStore,
                         named: String?) -> LegacyCondition {
        let object = try? JSONSerialization.jsonObject(with: data)

        switch store.keying {

        case .singleObject:
            // Nothing claims an identity. `athlete.json` and `constants.json`
            // are the athlete's own figures.
            return .readable

        case .dictionaryKeyedByID(let field):
            guard let rows = object as? [String: Any] else { return .readable }
            var faults: [IdentityFault] = []
            for key in rows.keys.sorted() {
                guard let row = rows[key] as? [String: Any] else { continue }
                let embedded = row[field] as? String
                // A record that does not carry the field at all is NOT a
                // mismatch. It is a shape this store has held since before the
                // field existed, and calling it a contradiction would quarantine
                // history for being old.
                guard let embedded else { continue }
                if embedded != key {
                    faults.append(.init(filedAs: key, claims: embedded, field: field))
                }
            }
            return faults.isEmpty ? .readable : .identityMismatch(faults)

        case .arrayOfRecords(let idField):
            guard let rows = object as? [[String: Any]] else { return .readable }
            var counts: [String: Int] = [:]
            for row in rows {
                guard let id = row[idField] as? String else { continue }
                counts[id, default: 0] += 1
            }
            let repeated = counts.filter { $0.value > 1 }.keys.sorted()
            return repeated.isEmpty ? .readable : .duplicateIdentity(repeated)

        case .fileNamedByID(let field):
            // Skipped when the caller does not know the name. Not defaulted to
            // "matches" — there is simply no claim to check, which is a
            // different thing from a claim that holds.
            guard let named else { return .readable }
            guard let row = object as? [String: Any],
                  let embedded = row[field] as? String else { return .readable }
            return embedded == named
                ? .readable
                : .identityMismatch([.init(filedAs: named, claims: embedded, field: field)])
        }
    }

    /// The typed decode, one line per store.
    ///
    /// A SWITCH RATHER THAN A PROTOCOL, deliberately. Eleven stores with
    /// eleven different shapes — a dictionary here, an array there, a bare
    /// object elsewhere — and no useful common supertype. A protocol would
    /// buy an `associatedtype` dance and cost the one thing this switch gives
    /// for free: adding a case to `LegacyStore` stops the build here, at the
    /// exact place that has to know about it.
    static func decode(_ data: Data, as store: LegacyStore) throws {
        let d = store.decoder
        switch store {
        case .notes:         _ = try d.decode([String: NotesStore.Note].self, from: data)
        case .proposals:     _ = try d.decode([ProposalStore.Record].self, from: data)
        case .activities:    _ = try d.decode([Activity].self, from: data)
        case .athlete:       _ = try d.decode(AthleteFile.self, from: data)
        case .weather:       _ = try d.decode([String: ActivityWeather].self, from: data)
        case .detail:        _ = try d.decode(ActivityDetail.self, from: data)
        case .streams:       _ = try d.decode(ActivityStreams.self, from: data)
        case .constants:     _ = try d.decode(AthleteConstants.self, from: data)
        case .commutes:      _ = try d.decode([String: CommuteDecision].self, from: data)
        case .legacyDetails: _ = try d.decode([String: ActivityDetail].self, from: data)
        case .legacyStreams: _ = try d.decode([String: ActivityStreams].self, from: data)
        }
    }
}
