//
//  ShareSheet.swift
//  Sub4
//
//  UIActivityViewController, wrapped.
//
//  SwiftUI's ShareLink would do this in one line, but it needs its item at view
//  construction time. The notes CSV does not exist until the button is pressed
//  — writing it on every redraw of the settings screen would be absurd — so the
//  file is produced first and the sheet is presented with it afterwards. That
//  ordering needs the UIKit controller.
//

import SwiftUI
import UIKit

/// A file to share, in a form `.sheet(item:)` accepts.
///
/// The obvious move is `extension URL: Identifiable`. It is not worth it: a
/// retroactive conformance on a Foundation type breaks the day Foundation adds
/// its own, and the warning it emits is telling you exactly that. A four-line
/// wrapper owned by this app cannot collide with anything.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - One section's numbers, as a file — patch 392, ADR-0003 §12.136

/// **THE SAME CONTENT AS THE PASTE, SCOPED TO ONE SECTION.**
///
/// The Database screen is twenty-three sections and roughly four hundred lines
/// of paste. Reading one figure off it meant screenshotting several pages or
/// sending the lot; this is the third option. The lines handed in are the
/// section's OWN `diagnosticLines` — the same property `diagnosticsText`
/// appends — so a section read here and the same section read in the full file
/// cannot say different things. §12.43.
///
/// **THE REDACTION IS INHERITED, NOT RE-DECIDED.** §12.7's promise is made in
/// the footer the athlete taps: no session names, no places, no dates from the
/// history. Every block this carries already had to satisfy it to be in the
/// paste, so there is no new judgement here and no new surface to get wrong.
nonisolated struct SectionExport: Equatable, Sendable {

    let title: String
    let lines: [String]

    /// **THE STAMP IS NOT DECORATION — §12.79.** *A capture that names its own
    /// build is a capture that can still be read next week.* A section exported
    /// on its own has less context than the full file, not more, so it needs
    /// the build more rather than less.
    ///
    /// PURE, taking the stamp rather than reading `AppVersion` — so a test can
    /// drive it, and so this type stays `nonisolated`.
    func text(stamp: String) -> String {
        ([stamp, "", title] + lines).joined(separator: "\n")
    }

    /// `sub4-read-back-details-2026-08-17-p392.txt`.
    ///
    /// The section, the day and the build, in that order, because that is the
    /// order somebody scanning a Downloads folder reads them in.
    func filename(day: String, patch: String) -> String {
        "sub4-\(Self.slug(title))-\(day)-p\(patch).txt"
    }

    /// **A FILENAME IS NOT A TITLE.** `Read-back · details` carries a middle dot
    /// and a space; a file named with either is a file that needs quoting in
    /// every shell and mangles in half the transports it will meet. Letters and
    /// digits survive, everything else becomes one hyphen, and the ends are
    /// trimmed so no name starts or finishes with one.
    static func slug(_ title: String) -> String {
        var out = ""
        var pendingHyphen = false
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(ch)
            } else {
                pendingHyphen = true
            }
        }
        return out.isEmpty ? "section" : out
    }
}

@MainActor
extension SectionExport {

    /// The file, written where the system sheet can reach it.
    ///
    /// Same protection class as the full diagnostics file and for its reason —
    /// "it is only counts" is an argument about today's content, not about the
    /// file. Patch 190.
    func write() -> URL? {
        let name = filename(day: DayKey.key(), patch: AppVersion.patchLabel)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
        guard let data = text(stamp: AppVersion.stamp).data(using: .utf8)
        else { return nil }
        do {
            try data.write(to: url, options: FileProtection.options)
            return url
        } catch {
            return nil
        }
    }
}

/// A section header that can hand over its own numbers — patch 392.
///
/// **IT REPLACES A `Text`, SO IT COSTS NOTHING.** This screen's budget is
/// DEPTH — §12.76, paid three times — and a header is a slot of its own rather
/// than a child of the section's `@ViewBuilder` block. One `Text` becomes one
/// `HStack`; the content chain is untouched.
///
/// **THE LINES ARE A CLOSURE AND THAT IS LOAD-BEARING.** `diagnosticLines` on
/// the recording report sorts dictionaries over 199,848 samples' worth of
/// tallies. Passing the value would compute every section's block on every
/// layout pass of a screen that already has a runtime size problem; passing the
/// closure computes one, once, when somebody presses the button.
struct DiagnosticSectionHeader: View {

    let title: String

    /// **A STABLE KEY, NOT THE TITLE — patch 393.** One title on this screen is
    /// interpolated: `Rows — \(counts.count) tables`. Keying the expansion on
    /// the displayed text would collapse that section the moment a row count
    /// moved, which is a defect nobody would connect to a table count changing.
    ///
    /// No default. §12.95.4: a default argument is a call site that carries a
    /// value the caller never writes, and `key = title` would have been exactly
    /// the trap above with nothing at the call site to show it.
    let key: String

    /// **WHICH SECTIONS ARE OPEN, OWNED BY THE SCREEN AND DYING WITH IT.**
    /// Collapsed is the default and the state is deliberately NOT persisted:
    /// the sheet opens as an index every time. Bruno's call, 17 August.
    @Binding var expanded: Set<String>

    let lines: () -> [String]
    @Binding var shared: ShareItem?

    /// §12.15: a button that silently does nothing cannot be told from a button
    /// nobody wired up. The glyph is the whole report — there is no room for a
    /// sentence in a section header and no need for one.
    @State private var failed = false

    private var isOpen: Bool { expanded.contains(key) }

    var body: some View {
        HStack {
            // THE TITLE IS THE CONTROL. A chevron alone is a small target and
            // this screen has twenty-two of them; the whole label toggles, and
            // the share button beside it is `.borderless` so the two do not
            // merge into one tap target inside a `List` header.
            Button {
                if isOpen { expanded.remove(key) } else { expanded.insert(key) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isOpen ? "Collapse \(title)" : "Expand \(title)")
            Spacer()
            Button {
                let export = SectionExport(title: title, lines: lines())
                if let url = export.write() {
                    failed = false
                    shared = ShareItem(url: url)
                } else {
                    failed = true
                }
            } label: {
                Image(systemName: failed
                      ? "exclamationmark.triangle" : "square.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(failed ? Color.red : Color.accentColor)
            }
            // BORDERLESS, because a plain button inside a `List` header takes
            // the whole row as its tap target otherwise.
            .buttonStyle(.borderless)
            .accessibilityLabel("Export \(title)")
        }
    }
}
