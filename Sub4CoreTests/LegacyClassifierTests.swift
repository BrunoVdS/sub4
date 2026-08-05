//
//  LegacyClassifierTests.swift
//  Sub4CoreTests
//
//  Damage that says which damage — patch 260, migration contract items 2 and 4.
//
//  `LegacyFixtureTests.todayEverythingBrokenLooksTheSame` asserted that five
//  different failures were one failure. It was written to be replaced, and this
//  file is the replacement: the same five inputs, the same eleven stores, and
//  an assertion per cell that names the outcome rather than counting throws.
//
//  Read `LegacyClassifier`'s header for why each distinction earns its code.
//  The short version is that the athlete does different things about them, and
//  the one that matters most is the one that is NOT a fault at all.
//

import Testing
import Foundation
@testable import Sub4

// MARK: - The two enumerations must agree

@Suite
struct LegacyStoreCoverageTests {

    @Test("Every fixture input is a store the app declares, and the reverse")
    func theTwoEnumerationsAgree() {
        // `LegacyInput` is the corpus; `LegacyStore` is the app's declaration.
        // They share raw values on purpose, so this is a real bijection rather
        // than two lists somebody promised to keep in step.
        let inputs = Set(LegacyInput.allCases.map(\.rawValue))
        let stores = Set(LegacyStore.allCases.map(\.rawValue))
        // ONE literal, not two joined with `+`. `Comment` is
        // `ExpressibleByStringLiteral`, so a concatenation is a `String`
        // expression and will not convert — this project has hit that four
        // times now, which is three more than it should have.
        #expect(inputs == stores, """
            corpus only: \(inputs.subtracting(stores).sorted()) · \
            app only: \(stores.subtracting(inputs).sorted())
            """)
    }

    @Test("The app and the corpus name the same file for every store",
          arguments: LegacyStore.allCases)
    func thePathsAgree(_ store: LegacyStore) throws {
        let input = try #require(LegacyInput(rawValue: store.rawValue))
        // The corpus writes the path as it appears to a person —
        // `details/<id>.json`. The app writes the directory. Comparing the
        // first component of each is what makes them the same claim.
        let corpusHead = input.path.split(separator: "/").first.map(String.init)
        #expect(store.item.pathComponent == corpusHead)
    }

    @Test("The app and the corpus agree on which decoder wrote which file",
          arguments: LegacyStore.allCases)
    func theDateStrategiesAgree(_ store: LegacyStore) throws {
        // Contract item 4's whole content is this pairing. Two records of it
        // that could disagree is worse than one, so they are asserted equal.
        let input = try #require(LegacyInput(rawValue: store.rawValue))
        switch input.dates {
        case .iso8601:              #expect(store.dates == .iso8601)
        case .numericReferenceDate: #expect(store.dates == .numericReferenceDate)
        case .noneStored:           #expect(store.dates == .noneStored)
        }
    }

    @Test("The app and the corpus agree on the outer container",
          arguments: LegacyStore.allCases)
    func theContainersAgree(_ store: LegacyStore) throws {
        let input = try #require(LegacyInput(rawValue: store.rawValue))
        switch input.container {
        // A dictionary keyed by id is a JSON object. The corpus draws the
        // finer distinction because it decides which damage classes apply;
        // the app only needs to know what the outer bracket is.
        case .dictionaryKeyedByID, .object: #expect(store.container == .object)
        case .array:                        #expect(store.container == .array)
        }
    }
}

// MARK: - The structural pass, which needs no actor

@Suite
struct LegacyShapeTests {

    @Test("Nothing at all is absent, which is not a fault")
    func absentIsNotAFault() {
        #expect(LegacyShape.of(nil) == .absent)
        #expect(!LegacyCondition.absent.isFault)
        // Contract item 2, and the single most important assertion in this
        // file. A migration that reports "notes.json is missing" on a phone
        // that never had notes is a migration that cries wolf on day one.
    }

    @Test("Zero bytes and blank space are told apart")
    func emptyIsNotWhitespace() {
        #expect(LegacyShape.of(Data()) == .empty)
        #expect(LegacyShape.of(Data("   \n\t\n".utf8)) == .whitespace)
    }

    @Test("A sign-in page is not a broken file — it is somebody else's file")
    func htmlIsNotJSON() {
        let html = Data("<!DOCTYPE html><html><body>Sign in</body></html>".utf8)
        #expect(LegacyShape.of(html) == .notJSON)
    }

    @Test("A prefix that happens to end on a closing brace is still truncated")
    func theBalanceScanBeatsTheLastCharacter() {
        // The reason `isUnterminated` counts brackets instead of looking at
        // the final byte. This prefix ends on `}` and is plainly incomplete;
        // a last-character check would call it corrupt and tell the athlete
        // not to restore the backup that would fix it.
        let cut = Data("""
            {"a":{"x":1},"b":{"y":2}
            """.utf8)
        #expect(LegacyShape.of(cut) == .truncated)
    }

    @Test("A brace inside a note is not a bracket")
    func stringsAreNotScanned() {
        // Session notes are free prose and proposal evidence is Markdown, so
        // braces inside strings are not hypothetical. A scanner that counted
        // them would call a perfectly good file truncated.
        let json = Data("""
            {"note":"felt like {this} today"}
            """.utf8)
        #expect(LegacyShape.of(json) == .parsed(.object))
    }

    @Test("An escaped quote does not end the string")
    func escapesAreHonoured() {
        let json = Data("""
            {"note":"he said \\"fine\\" and left {"}
            """.utf8)
        #expect(LegacyShape.of(json) == .parsed(.object))
    }

    @Test("An array and an object are told apart")
    func containersAreRecognised() {
        #expect(LegacyShape.of(Data("[]".utf8)) == .parsed(.array))
        #expect(LegacyShape.of(Data("{}".utf8)) == .parsed(.object))
    }
}

// MARK: - The whole classification, store by store

/// `@MainActor` because the typed decode is — `Activity`, `NotesStore.Note`,
/// `ProposalStore.Record`, `ActivityWeather` and `ActivityDetail` are all
/// main-actor isolated, which `LegacyFixtureTests` worked out first.
@Suite
@MainActor
struct LegacyClassifierTests {

    private func store(_ input: LegacyInput) throws -> LegacyStore {
        try #require(LegacyStore(rawValue: input.rawValue))
    }

    private func classify(_ damage: LegacyDamage,
                          _ input: LegacyInput) throws -> LegacyCondition {
        LegacyClassifier.classify(damage.bytes(for: input), as: try store(input))
    }

    // MARK: The replacement for todayEverythingBrokenLooksTheSame

    @Test("A missing file is absent, not broken", arguments: LegacyInput.allCases)
    func absentIsRecognised(_ input: LegacyInput) throws {
        let condition = try classify(.absent, input)
        #expect(condition == .absent)
        #expect(!condition.isFault, "a fresh install reported a fault")
        #expect(!condition.suggestsRestore, "a fresh install was told to restore a backup")
    }

    @Test("An empty file is empty", arguments: LegacyInput.allCases)
    func emptyIsRecognised(_ input: LegacyInput) throws {
        #expect(try classify(.empty, input) == .empty)
    }

    @Test("A whitespace file is not an empty one", arguments: LegacyInput.allCases)
    func whitespaceIsRecognised(_ input: LegacyInput) throws {
        #expect(try classify(.whitespace, input) == .whitespace)
    }

    @Test("A truncated file is reported as truncated", arguments: LegacyInput.allCases)
    func truncationIsRecognised(_ input: LegacyInput) throws {
        let condition = try classify(.truncated, input)
        #expect(condition == .truncated, "\(input.rawValue) truncated read as \(condition)")
        // The one class where restoring a backup is the right advice: part of
        // a write survived, so there was something to lose.
        #expect(condition.suggestsRestore)
    }

    @Test("A corrupt file is not a truncated one", arguments: LegacyInput.allCases)
    func corruptionIsRecognised(_ input: LegacyInput) throws {
        let condition = try classify(.corrupt, input)
        #expect(condition == .corrupt, "\(input.rawValue) corrupt read as \(condition)")
        // Full length, broken structure. Telling somebody to restore a backup
        // here sends them after a problem they do not have.
        #expect(!condition.suggestsRestore)
    }

    @Test("A captive portal's page is recognised as not ours",
          arguments: LegacyInput.allCases)
    func htmlIsRecognised(_ input: LegacyInput) throws {
        #expect(try classify(.notJSON, input) == .notJSON)
    }

    @Test("The five failures are five answers, not one",
          arguments: LegacyInput.allCases)
    func theFiveAreDistinct(_ input: LegacyInput) throws {
        // The assertion `todayEverythingBrokenLooksTheSame` could not make.
        // Its `#expect` is still true — all five throw — and its NAME stopped
        // being true here.
        var seen: [LegacyCondition] = []
        for damage in [LegacyDamage.empty, .whitespace, .truncated, .corrupt, .notJSON] {
            seen.append(try classify(damage, input))
        }
        let distinct = Set(seen.map(\.summary)).count
        #expect(distinct == 5, """
            \(input.rawValue) collapsed \(seen.count) failures into \(distinct)
            """)
        // Computed into a local first: `#expect` decomposes into a `rethrows`
        // call, and a bare `allSatisfy` as the whole argument demands a `try`.
        let allFaults = seen.allSatisfy(\.isFault)
        #expect(allFaults)
    }

    // MARK: What still reads

    @Test("A valid file is readable", arguments: LegacyInput.allCases)
    func theValidFixtureIsReadable(_ input: LegacyInput) throws {
        let condition = try classify(.valid, input)
        #expect(condition == .readable, "\(input.rawValue) read as \(condition)")
        #expect(!condition.isFault)
    }

    @Test("The wrong date strategy is undecodable, not truncated",
          arguments: LegacyInput.allCases)
    func theWrongDateStrategyIsItsOwnAnswer(_ input: LegacyInput) throws {
        // Nil for the two stores that hold no `Date` — there is no other
        // strategy to write them with, which is the point of `.noneStored`.
        guard LegacyDamage.wrongDateEncoding.bytes(for: input) != nil else { return }
        let condition = try classify(.wrongDateEncoding, input)
        // Contract item 4 made visible. The file parses, the container is
        // right, and the store's own decoder is what refuses it — which is
        // the outcome that can be corrected. A decoder that succeeded here
        // would have produced a wrong date nothing downstream could detect.
        guard case .undecodable = condition else {
            Issue.record("\(input.rawValue) wrong-date read as \(condition)")
            return
        }
        #expect(condition.isFault)
    }

    @Test("An array where an object belongs is its own answer")
    func theWrongContainerIsRecognised() {
        // Not a corpus case — the corpus damages a file, and this is a file
        // from somewhere else entirely. Worth its own answer because "expected
        // an object, found an array" tells somebody exactly what happened and
        // "it did not decode" does not.
        let condition = LegacyClassifier.classify(Data("[]".utf8), as: .notes)
        #expect(condition == .wrongContainer(expected: .object, found: .array))
        #expect(condition.isFault)
    }

    // MARK: Contract item 5 — patch 261
    //
    // `aKeyMismatchIsStillInvisible` stood here in 260, asserting that the
    // outer key won and nothing noticed. It was recorded rather than hidden,
    // exactly as patch 246 recorded the `athlete.json` obstacle, and this is
    // the patch that inverts it.

    @Test("A record filed under one name and claiming another is caught",
          arguments: [LegacyInput.notes, .weather, .commutes,
                      .legacyDetails, .legacyStreams])
    func aKeyMismatchIsCaught(_ input: LegacyInput) throws {
        let condition = try classify(.keyMismatch, input)
        guard case .identityMismatch(let faults) = condition else {
            Issue.record("\(input.rawValue) key mismatch read as \(condition)")
            return
        }
        #expect(faults.count == 1)
        #expect(condition.isFault)
        // The distinction the quarantine rests on: this file DECODED. Nothing
        // is broken about it, which is exactly why it is dangerous — a fault
        // that fails loudly gets fixed, and one that reads cleanly gets
        // imported.
        #expect(condition.decoded)
        #expect(!condition.suggestsRestore)
    }

    @Test("Both names are carried, and neither is called the right one",
          arguments: [LegacyInput.notes, .weather, .commutes,
                      .legacyDetails, .legacyStreams])
    func neitherNameWins(_ input: LegacyInput) throws {
        let condition = try classify(.keyMismatch, input)
        guard case .identityMismatch(let faults) = condition,
              let fault = faults.first else {
            Issue.record("\(input.rawValue) key mismatch read as \(condition)")
            return
        }
        // The decision, asserted rather than described. Preferring the outer
        // key or the embedded id would both be guesses about which half of a
        // contradiction is true, made by code with no way to know.
        #expect(fault.filedAs != fault.claims)
        #expect(!fault.filedAs.isEmpty)
        #expect(!fault.claims.isEmpty)
        #expect(fault.line.contains(fault.filedAs))
        #expect(fault.line.contains(fault.claims))
    }

    @Test("The field the mismatch was found in is named",
          arguments: [LegacyInput.notes, .weather, .commutes,
                      .legacyDetails, .legacyStreams])
    func theFieldIsNamed(_ input: LegacyInput) throws {
        let condition = try classify(.keyMismatch, input)
        guard case .identityMismatch(let faults) = condition,
              let fault = faults.first else {
            Issue.record("\(input.rawValue) key mismatch read as \(condition)")
            return
        }
        // notes keys on `sessionUid` and everything else on `activityId` — the
        // reason `Keying` names the field per store instead of sniffing for
        // something id-shaped.
        #expect(fault.field == (input == .notes ? "sessionUid" : "activityId"))
    }

    @Test("Two records claiming one identity are caught",
          arguments: [LegacyInput.activities, .proposals])
    func aDuplicateIsCaught(_ input: LegacyInput) throws {
        let condition = try classify(.duplicate, input)
        guard case .duplicateIdentity(let ids) = condition else {
            Issue.record("\(input.rawValue) duplicate read as \(condition)")
            return
        }
        #expect(ids.count == 1)
        #expect(condition.isFault)
        #expect(condition.decoded)
    }

    @Test("A valid file has no identity fault", arguments: LegacyInput.allCases)
    func theValidFixtureHasNoIdentityFault(_ input: LegacyInput) throws {
        // The counterweight. A check that fired on good files would be worse
        // than no check: everything quarantined is nothing quarantined.
        #expect(try classify(.valid, input) == .readable)
    }

    // MARK: The two stores whose name is the file name

    @Test("A per-activity file whose name disagrees with its contents is caught",
          arguments: [LegacyInput.detail, .streams])
    func theFileNameIsAnIdentityToo(_ input: LegacyInput) throws {
        // `details/<id>.json` states the id twice — once in the name, once in
        // `activityId`. The same double statement as the dictionaries, one
        // level up, and it has never been checked either.
        let data = try #require(LegacyDamage.valid.bytes(for: input))
        let condition = LegacyClassifier.classify(data, as: try store(input),
                                                  named: "99999999")
        guard case .identityMismatch(let faults) = condition else {
            Issue.record("\(input.rawValue) named-file mismatch read as \(condition)")
            return
        }
        #expect(faults.first?.filedAs == "99999999")
        #expect(faults.first?.claims == "11111111")
    }

    @Test("A per-activity file whose name agrees is readable",
          arguments: [LegacyInput.detail, .streams])
    func theRightFileNameIsClean(_ input: LegacyInput) throws {
        let data = try #require(LegacyDamage.valid.bytes(for: input))
        let condition = LegacyClassifier.classify(data, as: try store(input),
                                                  named: "11111111")
        #expect(condition == .readable)
    }

    @Test("Not knowing the file name is not the same as it matching",
          arguments: [LegacyInput.detail, .streams])
    func anUnknownNameIsNotAPass(_ input: LegacyInput) throws {
        // `named: nil` skips the check rather than asserting agreement. There
        // is no claim to test, which is a different thing from a claim that
        // holds — and the fixtures in every other test in this file are read
        // exactly this way.
        let data = try #require(LegacyDamage.valid.bytes(for: input))
        #expect(LegacyClassifier.classify(data, as: try store(input)) == .readable)
    }

    // MARK: What the check must NOT do

    @Test("A record with no id field at all is not a mismatch")
    func amissingFieldIsNotAContradiction() {
        // A shape this store held before the field existed. Calling that a
        // contradiction would quarantine history for being old — and the
        // whole point of the migration is that thirteen months survive it.
        let data = Data("""
            {"w03-tue":{"text":"Legs fine.","created":"2026-08-01T06:12:00Z",\
            "edited":"2026-08-01T06:12:00Z"}}
            """.utf8)
        let condition = LegacyClassifier.identity(of: data, as: .notes, named: nil)
        #expect(condition == .readable)
    }

    @Test("Every mismatched record is listed, not just the first")
    func allFaultsAreNamed() {
        // A list that stops at one is a list that hides the rest, and the
        // athlete decides record by record.
        let data = Data("""
            {"w99-sun":{"sessionUid":"w03-tue","text":"a",\
            "created":"2026-08-01T06:12:00Z","edited":"2026-08-01T06:12:00Z"},\
            "w98-sat":{"sessionUid":"w02-mon","text":"b",\
            "created":"2026-08-01T06:12:00Z","edited":"2026-08-01T06:12:00Z"}}
            """.utf8)
        let condition = LegacyClassifier.identity(of: data, as: .notes, named: nil)
        guard case .identityMismatch(let faults) = condition else {
            Issue.record("read as \(condition)")
            return
        }
        #expect(faults.count == 2)
        // Sorted by the name they are filed under, so the list does not
        // reshuffle between launches — a dictionary has no order of its own.
        #expect(faults.map(\.filedAs) == ["w98-sat", "w99-sun"])
    }

    @Test("The athlete's own files have no identity to disagree with",
          arguments: [LegacyInput.athlete, .constants])
    func singleObjectStoresAreExempt(_ input: LegacyInput) throws {
        // `athlete.json` holds `shoes[].id`, which names a shoe and not a
        // record. A heuristic hunting for id-shaped keys would have found it.
        #expect(try classify(.valid, input) == .readable)
    }
}
