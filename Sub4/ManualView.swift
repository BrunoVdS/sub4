//
//  ManualView.swift
//  Sub4
//
//  The manual, rendered from a bundled HTML file.
//
//  WHY A WEB VIEW RATHER THAN SWIFTUI
//  ----------------------------------
//  SwiftUI's Text renders a subset of Markdown — bold, italic, links — and
//  nothing else. The manual is seven tables, a code block, thirteen anchored
//  contents links and nine screenshots. Rebuilding that in SwiftUI would mean
//  hand-writing a Markdown renderer, and the result would still not give you a
//  working "jump to section" link.
//
//  So the Markdown stays the source of truth, `build_manual.py` converts it to
//  a single styled HTML file at build time, and this loads it. Anchors, tables
//  and images all work because a browser is doing what a browser does.
//
//  Screenshots live beside manual.html in the app bundle. loadFileURL is given
//  read access to the whole bundle directory so relative <img src> resolves;
//  any that are missing hide themselves rather than showing a broken icon.
//

import SwiftUI
import WebKit

struct ManualView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    missing
                } else {
                    ManualWebView(failed: $loadFailed)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .background(Color.bg)
            .navigationTitle("Manual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.accent4)
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.largeTitle).foregroundStyle(Color.dim)
            Text("Manual not bundled").font(.headline)
            Text("manual.html isn't in the app bundle. Drop it into the Sub4 "
                 + "source folder alongside plan.json and rebuild.")
                .font(.subheadline).foregroundStyle(Color.dim)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The web view

private struct ManualWebView: UIViewRepresentable {

    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // A non-persistent store means the manual is never served from a cache
        // that outlives the app build. WKWebView will happily hand back a
        // previously-loaded file:// page, so a rebuilt manual.html can sit in
        // the bundle while the old one is still on screen — a bug that reads as
        // "the patch didn't install". There is nothing here worth persisting.
        config.websiteDataStore = .nonPersistent()

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = UIColor(Color.bg)
        web.scrollView.backgroundColor = UIColor(Color.bg)
        // The page draws its own dark theme; letting iOS invert it as well
        // would produce grey-on-grey.
        web.overrideUserInterfaceStyle = .dark

        guard let url = Bundle.main.url(forResource: "manual", withExtension: "html") else {
            DispatchQueue.main.async { failed = true }
            return web
        }
        // Read access to the directory, not just the file — otherwise the
        // <img> tags for the screenshots are blocked.
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {

        /// The manual carries its own build number, stamped by build_manual.py.
        /// That answers "is this the newest manual", not "does it describe the
        /// app I am running" — and those drift apart the moment a patch ships
        /// Swift without HTML. So the app's own version is appended to the same
        /// line at load: one place, both numbers, mismatch visible.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let stamp = AppVersion.stamp
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("""
                (function () {
                  var p = document.querySelector('.build');
                  if (p) p.textContent += ' · \(stamp)';
                })();
                """)
        }

        /// Anchors and the local file stay inside. Anything on the web opens in
        /// Safari — a manual is no place to lose the back button.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            if url.isFileURL || url.absoluteString.hasPrefix("about:") {
                decisionHandler(.allow); return
            }
            if url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
}
