//
//  ProtectionReadBack.swift
//  Sub4
//
//  What the file system actually says the protection class is — patch 417,
//  ADR-0003 §12.162, plan topic 2.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  The Database screen printed `Protection · Until first unlock` as a **string
//  literal**. It was not read from anything. `FileProtection.protect` swallowed
//  its failure with `try?`, so the attribute could have failed to apply on
//  every item and the row would have said the same thing in the same colour.
//
//  A security property that fails silently and is reported as successful is not
//  a guarantee — it is a sentence. The plan's own words, and §12.15's rule with
//  the stakes raised: a diagnostic that cannot say why it has no answer will be
//  read as having one, and this one could not say anything at all.
//
//  FOUR STATES, NOT THREE
//  ----------------------
//  The prompt asks for expected / no attribute / inspection failure. There is a
//  fourth and it is the one worth catching: **an attribute that is present and
//  is the wrong class.** Folding it into "no attribute" would report a file
//  protected as `.complete` — which breaks background writes — identically to
//  one protected as nothing at all, and folding it into "expected" would be a
//  lie. §12.132: when a classification is a binary complement, ask what a third
//  kind of member does to it.
//

import Foundation

/// What one item's protection attribute reads as.
nonisolated enum ProtectionReading: Equatable, Sendable {

    /// The attribute is present and is `FileProtection.attribute`.
    case asExpected

    /// Present, and something else. Carries what it actually is, because
    /// "wrong" without saying what is a row somebody has to come and ask about.
    case different(String)

    /// The item exists and carries no protection attribute at all. On a
    /// simulator this is the ordinary answer and means nothing; on a device it
    /// means the sweep never reached this item.
    case noAttribute

    /// The inspection itself failed — the item is missing, or unreadable.
    /// **Not the same as `noAttribute`**, and keeping them apart is the whole
    /// reason this is an enum and not an optional. §12.15.
    case couldNotInspect(String)

    var isExpected: Bool { self == .asExpected }

    /// One line, always sayable, and it never carries a path — §12.7. A
    /// container path names the device's user; the class name does not.
    var line: String {
        switch self {
        case .asExpected:              "until first unlock"
        case .different(let what):     "NOT the expected class — \(what)"
        case .noAttribute:             "no protection attribute"
        case .couldNotInspect(let why): "could not inspect — \(why)"
        }
    }
}

/// Reads the attribute off the file system, for the items the screen names.
nonisolated enum ProtectionReadBack {

    /// One item, named for a reader rather than by its path.
    nonisolated struct Item: Equatable, Sendable {
        let name: String
        let reading: ProtectionReading

        var line: String { "  \(name): \(reading.line)" }
    }

    /// **THE MEASUREMENT.** `FileManager.attributesOfItem` rather than the
    /// value the app asked for — those are the two things this patch exists to
    /// stop being the same sentence.
    static func read(_ url: URL, using fm: FileManager = .default) -> ProtectionReading {
        do {
            return classify(try fm.attributesOfItem(atPath: url.path)[.protectionKey])
        } catch {
            return .couldNotInspect(error.localizedDescription)
        }
    }

    /// **SPLIT FROM THE READ, AND THE SIMULATOR IS WHY — patch 417, §12.162.3.**
    ///
    /// On a simulator, `setAttributes([.protectionKey: …])` is a **complete
    /// no-op**: it does not store the attribute, and it does not fail — not
    /// even for a path that does not exist. So a test running there cannot
    /// produce `.asExpected` or `.different` through `FileManager` at all, and
    /// a reader tested only through `read` would have two of its four answers
    /// permanently unexercised.
    ///
    /// The decision is therefore a pure function of the value, and the tests
    /// drive it directly. **`read` is still tested** — for the two states a
    /// simulator can genuinely produce — and the rest is the device's, which is
    /// the honest division rather than a green suite over a security property.
    static func classify(_ value: Any?) -> ProtectionReading {
        guard let value else { return .noAttribute }
        guard let type = value as? FileProtectionType else {
            return .different(String(describing: value))
        }
        return type == FileProtection.attribute
            ? .asExpected
            : .different(type.rawValue)
    }

    /// The representative set the plan asks for: the database and its folder,
    /// the two per-activity directories, the snapshot folder, and one authored
    /// file.
    ///
    /// **NAMES, NOT PATHS**, for the same reason the receipts carry names —
    /// a paste must not carry a container path (§12.7, and 407's correction).
    ///
    /// An item that does not exist reads `could not inspect`, which is correct
    /// and is why the list is not filtered: a missing `details/` on a device
    /// that should have 698 files is a finding, and a filtered list would have
    /// shown nothing at all. §12.54.2.
    @MainActor
    static func everything(using fm: FileManager = .default) -> [Item] {
        var items: [Item] = []
        func add(_ name: String, _ url: URL?) {
            guard let url else {
                items.append(Item(name: name,
                                  reading: .couldNotInspect("the app could not "
                                                            + "work out where this is")))
                return
            }
            items.append(Item(name: name, reading: read(url, using: fm)))
        }

        let base = AppSupportItem.container
        add("Application Support", base)
        // The names the two owners already declare, rather than a second
        // spelling of "db" and "sub4.sqlite" in this file. §12.43.
        let dbDir = base?.appendingPathComponent(Sub4Database.directoryName,
                                                 isDirectory: true)
        add("the database's folder", dbDir)
        add("the database file",
            dbDir?.appendingPathComponent(Sub4Database.fileName))
        add("details/", base?.appendingPathComponent("details", isDirectory: true))
        add("streams/", base?.appendingPathComponent("streams", isDirectory: true))
        add("snapshots/",
            base?.appendingPathComponent(LegacySnapshot.directoryName,
                                         isDirectory: true))
        add("notes.json", base?.appendingPathComponent("notes.json"))
        return items
    }

    /// UNCONDITIONAL, and it says how many of how many — a bare "protected"
    /// cannot be told from a list nobody read.
    static func summary(_ items: [Item]) -> String {
        let good = items.filter { $0.reading.isExpected }.count
        return "\(good) of \(items.count) at the expected class"
    }
}
