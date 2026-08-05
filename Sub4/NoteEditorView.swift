//
//  NoteEditorView.swift
//  Sub4
//
//  Writing a note about a session.
//
//  DESIGN CONSTRAINT: this gets used tired, on a phone, right after a run, or
//  not at all. Every field is optional and the sheet is usable with two taps
//  and no typing. The moment it feels like a form, the notes stop happening and
//  the monthly review has nothing to read.
//
//  So: RPE is a row of ten targets, not a stepper you hold. Feel is three
//  buttons. The text field is last because it is the one part that is genuinely
//  optional. Nothing is required, and clearing everything deletes the note
//  rather than storing a blank one.
//
//  RPE 1–10 is Borg CR10, the scale every training text uses. The anchors are
//  printed under the row because "7" means nothing on its own, and an
//  uncalibrated scale is worse than no scale — it produces numbers that trend
//  against nothing.
//

import SwiftUI

struct NoteEditorView: View {

    let session: Session

    @Environment(\.dismiss) private var dismiss
    @State private var store = NotesStore.shared

    @State private var rpe: Int?
    @State private var feel: NotesStore.Note.Feel?
    @State private var text: String = ""
    @State private var confirmDelete = false

    /// Patch 264. Non-nil means the last write did not happen — see
    /// `failureActions`.
    @State private var failure: StoreWriteError?

    @FocusState private var typing: Bool

    private let existing: NotesStore.Note?

    init(session: Session) {
        self.session = session
        let n = NotesStore.shared.note(for: session)
        self.existing = n
        _rpe  = State(initialValue: n?.rpe)
        _feel = State(initialValue: n?.feel)
        _text = State(initialValue: n?.text ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    prescription
                    rpeCard
                    feelCard
                    textCard
                    if existing != nil { deleteButton }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }.fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
        }
        .tint(.accent4)
        .confirmationDialog("Delete this note?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // Same rule as saving: the sheet closes only if the disk
                // agreed. A delete that silently did not happen would put the
                // note back at the next launch, which reads as the app
                // undoing a decision.
                do {
                    try store.remove(session: session)
                    dismiss()
                } catch let error as StoreWriteError {
                    failure = error
                } catch {
                    failure = StoreWriteError(store: "notes.json", stage: .writing,
                                              reason: String(describing: error))
                }
            }
        } message: {
            Text("Notes are not backed up anywhere. This cannot be undone.")
        }
        // Patch 264. `presenting:` rather than a bare flag, so the actions can
        // ask what KIND of failure this was — an encoding fault gets no "try
        // again", because retrying runs the same code over the same value.
        .alert("Not saved",
               isPresented: Binding(get: { failure != nil },
                                    set: { if !$0 { failure = nil } }),
               presenting: failure) { _ in
            failureActions
        } message: { error in
            Text(error.errorDescription ?? "The note could not be saved.")
        }
    }

    // MARK: What the plan asked
    //
    // Shown at the top and not editable. Both fields are judgements RELATIVE to
    // the prescription, so the prescription has to be on screen while you make
    // them — otherwise "harder than the target" is being answered from memory.

    private var prescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: session.discipline.symbol)
                    .font(.caption).foregroundStyle(session.tint)
                Text(session.kindLabel.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(session.tint)
                Spacer()
                if let d = session.date {
                    Text(d).font(.caption2).foregroundStyle(Color.dim)
                }
            }
            if let t = session.title {
                Text(t).font(.headline)
            }
            if let d = session.detail {
                Text(d).font(.subheadline).foregroundStyle(Color.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: RPE

    private var rpeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Effort").font(.subheadline.weight(.semibold))
                Spacer()
                if rpe != nil {
                    Button("Clear") { rpe = nil }
                        .font(.caption).foregroundStyle(Color.dim)
                }
            }

            HStack(spacing: 5) {
                ForEach(1...10, id: \.self) { v in
                    // Hoisted out of the modifier chain. Four inline ternaries
                    // in one chain is the shape that makes SwiftUI's type
                    // checker give up — see the header of SettingsView.swift.
                    let on = (rpe == v)
                    Button {
                        rpe = on ? nil : v
                    } label: {
                        Text("\(v)")
                            .font(.system(size: 15, weight: on ? .bold : .regular,
                                          design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(on ? session.tint.opacity(0.22) : Color.line.opacity(0.5))
                            .foregroundStyle(on ? session.tint : Color.dim)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(on ? session.tint : .clear, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(rpe.map { Self.anchor($0) } ?? "1 easy · 5 moderate · 7 hard · 10 all-out")
                .font(.caption)
                .foregroundStyle(rpe == nil ? Color.dim : session.tint)
                .animation(.none, value: rpe)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// Borg CR10 anchors, in the words a runner would use.
    private static func anchor(_ v: Int) -> String {
        switch v {
        case 1:  "1 — nothing at all, barely moving"
        case 2:  "2 — very easy, could do this all day"
        case 3:  "3 — easy, full conversation"
        case 4:  "4 — comfortable, talking in sentences"
        case 5:  "5 — moderate, breathing noticeably"
        case 6:  "6 — somewhat hard, short sentences"
        case 7:  "7 — hard, a few words at a time"
        case 8:  "8 — very hard, one word at a time"
        case 9:  "9 — near maximal, could not hold it much longer"
        default: "10 — all-out, nothing left"
        }
    }

    // MARK: Feel

    private var feelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Against the target").font(.subheadline.weight(.semibold))
                Spacer()
                if feel != nil {
                    Button("Clear") { feel = nil }
                        .font(.caption).foregroundStyle(Color.dim)
                }
            }

            HStack(spacing: 8) {
                ForEach(NotesStore.Note.Feel.allCases) { f in
                    let on = (feel == f)
                    Button {
                        feel = on ? nil : f
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: f.symbol).font(.system(size: 15, weight: .semibold))
                            Text(f.label).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(on ? session.tint.opacity(0.22) : Color.line.opacity(0.5))
                        .foregroundStyle(on ? session.tint : Color.dim)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(on ? session.tint : .clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Not how hard it was — whether it was harder or easier than what the plan asked for.")
                .font(.caption).foregroundStyle(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: Text

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What happened").font(.subheadline.weight(.semibold))

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Legs, weather, sleep, shoes — whatever explains the numbers above.")
                        .font(.subheadline).foregroundStyle(Color.dim.opacity(0.7))
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .focused($typing)
                    .font(.subheadline)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Label("Delete note", systemImage: "trash")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.dangerColor)
        .cardStyle()
    }

    /// DISMISSES ONLY AFTER THE WRITE — patch 264, D4 step 1.
    ///
    /// It used to call `save` and `dismiss` on consecutive lines with nothing
    /// between them, because `save` could not fail. Now that it can, the sheet
    /// closing IS the confirmation, and it may not be given until there is
    /// something to confirm.
    private func commit() {
        do {
            try store.save(session: session, rpe: rpe, feel: feel, text: text)
            dismiss()
        } catch let error as StoreWriteError {
            failure = error
        } catch {
            failure = StoreWriteError(store: "notes.json", stage: .writing,
                                      reason: String(describing: error))
        }
    }

    /// What to do when the note did not save.
    ///
    /// THREE ACTIONS, AND NONE OF THEM THROWS THE TEXT AWAY. There is no
    /// "discard" here and there will not be one: this sheet may hold the only
    /// copy of something the athlete wrote, and a single tap that destroys it
    /// is not a button, it is a trap.
    ///
    /// - **Copy the text** is the one that matters, and it is deliberately
    ///   first for a failure that retrying will not fix. Somewhere it can be
    ///   pasted beats anything this app can promise about its own disk.
    /// - **Try again** only appears when the stage was `writing`. An encoding
    ///   failure is a defect in the app, and offering to run the same code
    ///   over the same value again is a button that lies.
    /// - **Keep editing** dismisses the alert, not the sheet.
    @ViewBuilder
    private var failureActions: some View {
        Button("Copy the text") {
            UIPasteboard.general.string = pasteboardText
            // The alert closes and the sheet does not. The text is still on
            // screen and still in the clipboard, and nothing has been lost.
        }
        if failure?.stage.isWorthRetrying == true {
            Button("Try again") { commit() }
        }
        Button("Keep editing", role: .cancel) { }
    }

    /// Everything that was typed, in one block, so a paste into Messages or
    /// Notes carries the judgement as well as the words.
    private var pasteboardText: String {
        var parts: [String] = []
        if let rpe { parts.append("RPE \(rpe)") }
        if let feel { parts.append(feel.label) }
        // `title` is optional on `Session` — the eight logged prologue
        // sessions have none — so the uid stands in. It is not pretty and it
        // does identify the session, which is what a paste needs to do.
        let name = session.title ?? session.uid
        let header = parts.isEmpty ? name : "\(name) — \(parts.joined(separator: " · "))"
        return text.isEmpty ? header : "\(header)\n\n\(text)"
    }
}

// MARK: - The note affordance, everywhere
//
// One control, used by every session row in the app — Today, Week and Plan.
//
// It replaces a context-menu-only entry point, which was a mistake: a
// long-press is invisible. If the only way to write a note is a gesture nobody
// can see, notes do not get written, and the monthly review has nothing to
// read. The button states which is which at a glance — outline for "no note
// yet", filled accent for "there is one, tap to read or edit".
//
// Deliberately small and quiet. It appears beside every session including rest
// days, so it must not compete with the session itself for attention.

// `NoteButton` — a pencil that opened the editor from a list row — was deleted
// in patch 104. There is exactly one way into this editor now: the note card on
// the activity page. A control that exists in three places is three places to
// forget when the rule changes, which is what happened here.

/// The note's one-line gist, for a row that has space for it. Returns nothing
/// when there is no note, so callers can drop it in unconditionally.
struct NoteSummary: View {

    let session: Session

    @State private var notes = NotesStore.shared

    var body: some View {
        if let n = notes.note(for: session) {
            // Padding lives inside the `if`, so a session with no note
            // contributes nothing at all — no stray gap in the row.
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "text.quote")
                    .font(.system(size: 9)).foregroundStyle(Color.accent4)
                    .padding(.top, 2)
                Text(n.summary)
                    .font(.caption2).foregroundStyle(Color.dim)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(.top, 3)
            .padding(.leading, 21)
        }
    }
}
