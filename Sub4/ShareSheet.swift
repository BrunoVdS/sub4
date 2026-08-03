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
