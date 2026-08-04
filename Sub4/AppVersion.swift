//
//  AppVersion.swift
//  Sub4
//
//  What is actually running on this phone.
//
//  WHY THREE NUMBERS AND NOT ONE
//  -----------------------------
//  "Which build is this?" is three different questions, and one number cannot
//  answer all of them. Each layer below is owned by someone different and fails
//  in a different way, so having all three means at least one is always right.
//
//    version   CFBundleShortVersionString — set by hand in Xcode's General tab.
//              Semantic and deliberate: it says what the app IS. Its weakness is
//              that it only changes when somebody remembers to change it, which
//              over a 34-week project means it will sit at 1.0 for months.
//
//    patch     A constant in this file, bumped with every source patch shipped
//              into the project folder. Its weakness is that it is only correct
//              if the patch containing it was actually installed — which is
//              exactly what makes it useful: if this number is older than you
//              expect, the patch did NOT land. Three manual builds once shipped
//              under one zip name and the oldest kept winning; this is the
//              number that would have caught it in one glance.
//
//    built     Read off the executable on disk. Nobody maintains it and nobody
//              can forget it. Caveat, stated plainly: this is the file's
//              modification date, which is the link time for a locally built
//              app — accurate in this workflow, but it is not a guarantee, and
//              a Run Script build phase writing a real timestamp into
//              Info.plist would be. For a personal app this is the right
//              trade: zero project configuration, no discipline required.
//
//  Together: `version` says what it is, `patch` says which source is in it, and
//  `built` says when — with no way for all three to be wrong at once.
//

import Foundation

enum AppVersion {

    /// Bumped with every source patch. If this reads lower than the patch you
    /// just installed, the files did not reach the project folder.
    ///
    /// THIS FILE SHIPS IN EVERY PATCH ZIP, WITHOUT EXCEPTION. It was left out
    /// of 39 through 44 — six patches that installed correctly while this
    /// number sat at 38. That is the exact false negative it exists to
    /// prevent, and it is worse than having no number at all: a stale reading
    /// here normally means nothing landed, so it argues for re-installing
    /// patches that are already in place.
    static let patch = 226

    /// From Xcode's General tab — Version.
    static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// From Xcode's General tab — Build.
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    /// Link time of the binary. See the caveat in the header.
    static var built: Date? {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default
                .attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.modificationDate] as? Date) ?? (attrs[.creationDate] as? Date)
    }

    static var builtLabel: String {
        guard let d = built else { return "unknown" }
        return dateFormatter.string(from: d)
    }

    #if DEBUG
    static let configuration = "Debug"
    #else
    static let configuration = "Release"
    #endif

    /// "1.0 (3) · patch 10" — the one-line form for a settings row.
    static var short: String { "\(marketing) (\(build)) · patch \(patch)" }

    /// Everything, for an export header or a bug report. Deliberately one line
    /// per fact rather than a dense string: this gets pasted into a message and
    /// read by someone who is not looking at the code.
    static var full: String {
        """
        Sub4 \(marketing) (\(build)) · patch \(patch)
        Built \(builtLabel) · \(configuration)
        """
    }

    /// Compact single-line stamp for the top of a generated file.
    static var stamp: String {
        "Sub4 \(marketing) (\(build)) · patch \(patch) · built \(builtLabel)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM yyyy HH:mm"
        return f
    }()
}
