//
//  ExpandableCard.swift
//  Sub4
//
//  Tap a chart, turn the phone, see the whole thing.
//
//  THE PICTURE IS PINNED TO THE WORLD, NOT TO THE SCREEN
//  -----------------------------------------------------
//  The panel is always the wide picture. Turning the phone does not rotate the
//  graph — it rotates the phone around it. Same layout, same aspect, same marks
//  in the same places; the only thing that changes is that it becomes readable.
//
//  Getting there needs one correction, and the reason is not obvious. This app
//  DOES allow the interface to rotate, so a fixed +90° is applied on top of a
//  rotation the system has already performed: portrait shows the graph
//  sideways, you turn the phone, the interface turns as well, and the graph is
//  sideways again. Turned twice, never readable.
//
//  So the rotation is 90° only while the interface is portrait, and 0° once the
//  interface has turned — cancelling the system's rotation rather than adding
//  to it. The content box is built long-side-to-long-side in both cases, so the
//  panel occupies the same physical rectangle either way and nothing reflows.
//
//  The interface orientation is read from the geometry rather than from
//  UIDevice: `geo.size` is what the layout actually got, which is the thing
//  being corrected for. A device reporting face-up while lying on a table has
//  no bearing on it.
//
//  THE CLOSE BUTTON LIVES INSIDE THE ROTATION
//  ------------------------------------------
//  Not as an overlay on the cover. A rotation maps the content's top-left
//  somewhere else entirely, so anything positioned in device coordinates ends
//  up where the eye does not expect. Placed inside the rotated content, it is at
//  the visual top-left by construction, whichever way the maths goes.
//
//  EXPANDED MEANS MORE, NOT BIGGER
//  -------------------------------
//  Each card supplies its own expanded view rather than reusing the small one.
//  A magnifying glass over the same 120 days would be a worse version of
//  scrolling. The expanded fitness chart shows the whole series since January;
//  the expanded commute chart shows a year instead of a quarter.
//
//  A CARD OPENS A GROUP, NOT A PANEL
//  ---------------------------------
//  Fitness and Load pattern answer the same question about the same days, and
//  once you are in the wide picture the only way to get from one to the other is
//  close, scroll, tap. So a card no longer carries ONE expanded view — it
//  carries a GROUP of them plus which one its own tap should land on. The panel
//  header then switches between them in place.
//
//  Two consequences worth stating, because both were choices:
//
//  The switcher REPLACES the title rather than sitting under it. The panel is
//  rotated, so every row of chrome costs the picture its width, and a group of
//  two already names both panels — a title above a switcher would print the
//  current panel's name twice.
//
//  A group of ONE renders exactly as before: the title is a title, no switcher,
//  no behavioural change. That is what keeps Commute, and every other single
//  card, untouched by this.
//

import SwiftUI

/// One expanded view in a group, with the name it wears in the switcher.
///
/// Type-erased on purpose. A group is a heterogeneous list — fitness and load
/// pattern are different types — and a generic pair would only get us to two.
struct ExpandedPanel: Identifiable {
    let id: String
    let title: String
    /// The glossary this panel's info icon opens. nil means no icon — which is
    /// what keeps Commute and every other unannotated panel unchanged.
    let info: InfoTopic?
    let build: () -> AnyView

    init<V: View>(_ id: String, _ title: String,
                  info: InfoTopic? = nil,
                  @ViewBuilder _ build: @escaping () -> V) {
        self.id = id
        self.title = title
        self.info = info
        self.build = { AnyView(build()) }
    }
}

/// Which series each panel currently has switched off.
///
/// WHY THIS LEFT THE PANEL VIEWS
/// -----------------------------
/// It used to be `@State` inside PMCExpanded and LoadPatternExpanded, which is
/// correct right up to the moment you can switch between them: `.id(panel)` on
/// the content tears the old view down, and with it the toggles you set four
/// seconds ago. Switch back and everything is on again. Hoisting the sets here
/// makes them outlive the swap without outliving the panel.
///
/// A singleton, because exactly one panel is open at a time and the alternative
/// — threading a binding through every call site — buys nothing.
///
/// Still cleared every time a panel OPENS, which is the rule SeriesToggle
/// argues for: a chart missing a line for a reason you set last week is a chart
/// that looks broken.
@Observable
final class PanelToggles {

    static let shared = PanelToggles()
    private init() {}

    var hidden: [String: Set<String>] = [:]

    func set(_ panel: String) -> Set<String> { hidden[panel] ?? [] }

    func binding(_ panel: String) -> Binding<Set<String>> {
        Binding(get: { self.hidden[panel] ?? [] },
                set: { self.hidden[panel] = $0 })
    }

    func clear() { hidden.removeAll() }
}

struct ExpandableCard<Card: View>: View {

    /// Everything reachable from this card's panel. One entry is the old
    /// behaviour exactly.
    let panels: [ExpandedPanel]
    /// Which of them this card's own tap lands on. nil means the first.
    var opensOn: String? = nil
    @ViewBuilder var card: () -> Card

    @State private var open = false

    var body: some View {
        card()
            .contentShape(Rectangle())
            // A group can come back empty — Fitness withholds its panel inside
            // the warm-up, Load pattern below eight clean windows — and an
            // empty cover is a tap that opens a blank rectangle.
            .onTapGesture { if !panels.isEmpty { open = true } }
            // NO `.presentationBackground(.clear)` — patch 161, and this is the
            // fix for the panel vanishing on rotation.
            //
            // WHAT THE SCREEN RECORDING SHOWED. Turned to landscape, the panel
            // was not off-centre and not clipped: it was ABSENT, and so was the
            // scrim. The page underneath sat there undimmed. Turning back
            // brought both straight home, so the cover was still presented the
            // whole time — its content simply had no space to draw in.
            //
            // Nothing inside `RotatedScreen` can survive that. Patch 160's
            // orientation fix was answering the wrong question: a panel cannot
            // be centred in a host with no size.
            //
            // WHY THE TRANSPARENCY. This cover is presented from inside the
            // activity detail SHEET — a modal on a modal — and a transparent
            // presentation changes how UIKit builds that container. It is also
            // the only difference between here and the Progress tab, where the
            // same component has never once misbehaved because it is presented
            // from a tab rather than from a sheet.
            //
            // WHAT IT COSTS. The page no longer shows through. The scrim now
            // sits over the app's own background instead of over the card you
            // came from, which is a real loss of context and a small one — you
            // opened a panel that covers the screen, and the thing behind it was
            // dimmed to 28% anyway.
            .fullScreenCover(isPresented: $open) {
                RotatedScreen(panels: panels, opensOn: opensOn)
            }
    }
}

extension ExpandableCard {
    /// The single-panel form, byte-identical at the call site to what it was
    /// before groups existed. Every card that has no sibling still reads
    /// `ExpandableCard(title:) { … } expanded: { … }`.
    init<E: View>(title: String,
                  @ViewBuilder card: @escaping () -> Card,
                  @ViewBuilder expanded: @escaping () -> E) {
        self.init(panels: [ExpandedPanel(title, title, expanded)],
                  opensOn: nil,
                  card: card)
    }
}

/// The wide picture, floating in a panel, held still while the phone turns
/// around it.
///
/// Inset from every edge rather than bleeding to them. Edge-to-edge reads as
/// "the app changed screens"; a panel with a margin and a shadow reads as "this
/// opened on top of what you were looking at", which is what it is.
struct RotatedScreen: View {

    let panels: [ExpandedPanel]
    var opensOn: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String = ""
    /// Closed on every switch. The note follows the SELECTED panel, so leaving
    /// it open across a switch would swap the whole page of text under the
    /// reader's eyes without them asking for it.
    @State private var showInfo = false

    /// Margin between the panel and the safe area, on every side.
    ///
    /// A previous version read `geo.safeAreaInsets` from a reader that was
    /// itself ignoring the safe area, on the understanding that the proxy still
    /// reports what was ignored. It does not — it returned zero, so the panel
    /// sat under the Dynamic Island with the axis label level with the clock.
    /// The reader below deliberately does NOT ignore the safe area, so its own
    /// size is already the safe rectangle and no inset arithmetic is needed.
    private let gap: CGFloat = 26

    /// ORIENTATION COMES FROM THE ENVIRONMENT, NOT FROM A MEASUREMENT — patch 160.
    ///
    /// This used to read `geo.size.height >= geo.size.width` and that is the bug
    /// behind "the panel goes out of view when I turn the phone", including the
    /// part where it only sometimes happens.
    ///
    /// The failure is a single frame of disagreement. `geo.size` is a MEASUREMENT
    /// that arrives when the layout system gets round to it, and a
    /// `fullScreenCover` with a clear background does not always resize in the
    /// same pass as the interface rotation. If the interface has turned and geo
    /// has not yet caught up, the panel is still built portrait-shaped and still
    /// rotated 90° — a 388-wide box turned on its side inside an 838×419
    /// container. It does not clip; it leaves the screen. Then the next layout
    /// pass fixes it, or does not, which is exactly the "sometimes" and exactly
    /// why a fresh build makes it likelier: the first presentation after a launch
    /// is the one with the least cached layout to reuse.
    ///
    /// The size class is not a measurement. It is part of the trait collection
    /// SwiftUI hands down in the same transaction as the layout, so it cannot
    /// describe an orientation the layout has not adopted. On iPhone the mapping
    /// is exact: portrait is a regular vertical class, landscape a compact one.
    ///
    /// (This is not the `UIDevice` reading the old note rightly rejected — that
    /// is the accelerometer, which reports face-up on a table and knows nothing
    /// about the interface. This is the interface describing itself.)
    @Environment(\.verticalSizeClass) private var vClass

    private var interfaceIsPortrait: Bool { vClass != .compact }

    // A `trusted(_:)` fallback used to sit here — patch 161's belt-and-braces
    // that read the key window's safe rectangle whenever `geo` disagreed with
    // the size class about orientation. Deleted in patch 174: the vanishing
    // panel it guarded against turned out to be the LazyVStack tearing down the
    // cover's host (fixed in 163), after which the disagreement it detected
    // could no longer occur — while the `connectedScenes` walk it cost ran on
    // every layout pass of every panel. A guard against an impossible state is
    // not safety, it is a tax with a reassuring name.

    private var current: ExpandedPanel? {
        panels.first { $0.id == selectedID } ?? panels.first
    }

    var body: some View {
        ZStack {
            // The page's own colour first, because the cover is opaque since
            // patch 161 and a scrim alone would be a translucent grey over
            // whatever UIKit felt like painting.
            Color.bg.ignoresSafeArea()

            // The scrim over it. Tapping it closes the panel, the way any
            // floating thing should; the button stays for the people who look
            // for one.
            Color.scrim
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            GeometryReader { geo in
                // geo is still what supplies the SIZE — it is the only thing
                // that knows the safe rectangle. What it no longer supplies is
                // the ORIENTATION, which is the decision that fails badly rather
                // than slightly when it is a frame late.
                //
                // The two now degrade differently, and that is the point: a
                // stale size makes the panel a few points wrong for one frame,
                // where a stale orientation put it off the screen.
                let size = geo.size
                let w = max(size.width - gap * 2, 1)
                let h = max(size.height - gap * 2, 1)

                VStack(alignment: .leading, spacing: 14) {
                    header(showHint: interfaceIsPortrait)
                    ZStack {
                        if let c = current {
                            c.build()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                // Forces a fresh view on a switch. Without it
                                // SwiftUI tries to reuse the old panel's state
                                // against a different body and the chart
                                // animates between two unrelated series.
                                .id(c.id)
                        }
                        // INSIDE the rotation, deliberately. A sheet or popover
                        // presented from here would present in device
                        // coordinates and arrive at 90° to the chart it belongs
                        // to — the same reason the close button is not an
                        // overlay on the cover.
                        if showInfo, let t = current?.info {
                            InfoOverlay(topic: t, open: $showInfo)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(20)
                // Long side to long side in both cases, so the panel covers the
                // same physical rectangle whichever way the phone is held and
                // the chart never reflows.
                .frame(width: interfaceIsPortrait ? h : w,
                       height: interfaceIsPortrait ? w : h)
                // AFTER the frame, so it takes the panel's size, and BEFORE the
                // rotation, so it turns with the content rather than staying
                // squarely behind it.
                .background(panel)
                // Cancel the system's rotation rather than add to it.
                .rotationEffect(.degrees(interfaceIsPortrait ? 90 : 0))
                // CENTRED BY A CONTAINER, NOT BY ARITHMETIC.
                //
                // This was `.position(x: geo.size.width / 2, y: ...)`, which
                // computes the centre from the same measurement that can be
                // stale — so a late `geo` moved the panel as well as turning it
                // the wrong way, and the two faults compounded. A frame filling
                // the reader centres by construction: whatever size arrives, the
                // middle of it is the middle of it.
                .frame(width: size.width, height: size.height)
            }
        }
        .onAppear {
            selectedID = opensOn ?? panels.first?.id ?? ""
            // Every open starts with everything drawn. See PanelToggles.
            PanelToggles.shared.clear()
        }
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.card)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.line, lineWidth: 1))
            // Generous, because the page behind it is nearly the same colour.
            // Without real separation a dark panel on a dark page is just a
            // rectangle with a hairline.
            .shadow(color: Color.panelShadow, radius: 30, y: 10)
    }

    /// The hint is dropped once the interface has turned — by then it is
    /// telling you to do something you have done.
    private func header(showHint: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.dangerColor)
            }
            .buttonStyle(.plain)

            if panels.count > 1 {
                switcher
            } else {
                Text(current?.title ?? "")
                    .font(.subheadline.weight(.semibold))
            }

            if current?.info != nil {
                Button { showInfo.toggle() } label: {
                    Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(showInfo ? Color.accent4 : Color.dim)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            if showHint {
                Text("turn the phone")
                    .font(.caption2).foregroundStyle(Color.dim)
            }
        }
    }

    /// Deliberately the same shape as SeriesToggleBar's pills — one visual
    /// language for "this control changes what the chart shows", whether the
    /// thing changed is a series or the whole panel. The selected pill is
    /// filled rather than merely brighter, because unlike a toggle bar exactly
    /// one of these is always on.
    private var switcher: some View {
        HStack(spacing: 6) {
            ForEach(panels) { p in
                let on = p.id == (current?.id ?? "")
                Button {
                    selectedID = p.id
                    showInfo = false
                } label: {
                    Text(p.title)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.ink : Color.dim)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            Capsule().fill(Color.ink.opacity(on ? 0.12 : 0.02))
                                .overlay(Capsule().stroke(
                                    on ? Color.line : Color.line.opacity(0.5),
                                    lineWidth: 1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - The shared discipline

/// Which discipline the volume and pace cards are both showing.
///
/// ONE KEY, NOT TWO
/// ----------------
/// These used to be `volume.metric` and `pace.metric`, independently persisted,
/// which was defensible while the two cards were unrelated objects on a long
/// page. It stops being defensible the moment you can switch between them
/// inside one panel: you are looking at bike volume, you tap Pace, and you get
/// running. The switch is supposed to be "same question, other measure" and
/// instead it silently changes the subject.
///
/// So the selection belongs to the READER, not to the card. One key, written by
/// whichever tile row was tapped last, read by both.
///
/// The two enums stay separate — they differ in units, gates and formatting —
/// but their raw values are the same three strings, so one stored string
/// decodes into either. Consequence worth knowing: this is a new key, so the
/// first launch after this patch opens on Run regardless of what either card
/// was left on.
enum DisciplineKey {
    static let selected = "discipline.selected"
}

// MARK: - The groups

/// Panels that belong together, named in one place so the card and the strip
/// that both open them cannot drift apart.
enum PanelGroup {

    /// Fitness and Load pattern. Same days, same family of question — one is
    /// how much you are carrying, the other is what shape it arrived in.
    ///
    /// Built from what is ACTUALLY on the page. Both cards withhold themselves
    /// when their own series is not worth drawing, and a switcher offering a
    /// panel whose card refused to render is a control that opens an empty
    /// chart.
    static var load: [ExpandedPanel] {
        var out: [ExpandedPanel] = []
        if LoadStore.shared.pmc.caveat == nil {
            out.append(ExpandedPanel("fitness", "Fitness", info: .fitness) { PMCExpanded() })
        }
        if LoadPatternCard.hasEnoughWindows {
            out.append(ExpandedPanel("pattern", "Load pattern",
                                     info: .loadPattern) { LoadPatternExpanded() })
        }
        return out
    }

    /// The same group as seen from the Today strip, which opens whenever the
    /// day carries numbers rather than waiting for the curve to be trustworthy.
    /// Fitness is therefore always present — that is the behaviour the strip had
    /// before groups existed and there is no reason to take it away.
    static var loadFromStrip: [ExpandedPanel] {
        let g = load
        if g.contains(where: { $0.id == "fitness" }) { return g }
        return [ExpandedPanel("fitness", "Fitness", info: .fitness) { PMCExpanded() }] + g
    }

    /// Weekly volume and Pace. How much, and how fast — the same sessions
    /// counted two ways, which is exactly the pair you want to move between
    /// without closing anything.
    ///
    /// Deliberately NOT gated on either card's own data test, unlike `load`.
    /// Both gates are "is there anything at all, in any discipline", and both
    /// cost a full series rebuild — this property is read on every body pass of
    /// both cards, so gating here would double the work the page does per frame
    /// to guard a case that cannot occur: every session that produces a pace
    /// produced volume first.
    static var volumePace: [ExpandedPanel] {
        [ExpandedPanel("volume", "Weekly volume", info: .volume) { VolumeExpanded() },
         ExpandedPanel("pace", "Pace", info: .pace) { PaceExpanded() }]
    }
}
