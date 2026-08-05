//
//  StoreWriteAlert.swift
//  Sub4
//
//  What a failed save looks like, once — D4, patch 265.
//
//  WHY THIS IS A MODIFIER AND NOT A COPY IN EVERY VIEW
//  ---------------------------------------------------
//  Patch 264 gave `NoteEditorView` a bespoke failure alert, and it earned one:
//  a note is text, the text may exist nowhere else, and the first action there
//  is "Copy the text" — a whole escape hatch that only makes sense for prose.
//
//  Everything else the athlete decides is small and repeatable. A commute
//  toggle is one bit; a threshold is a number he can type again. Those need the
//  same two sentences every time — what did not happen, and is it worth another
//  go — and writing them six times would guarantee six wordings.
//
//  THE ACTIONS DEPEND ON THE STAGE, NOT ON THE CALLER
//  --------------------------------------------------
//  `Try again` appears only when the failure was a WRITE. An encoding failure
//  is a defect in this app and retrying runs the same code over the same value;
//  a button offering it is a button that lies. That rule lives here so no
//  caller can get it wrong, which is the other half of why this is one place.
//
//  WHAT IT DELIBERATELY DOES NOT DO
//  --------------------------------
//  It does not undo anything. The stores roll their own memory back when a
//  write throws — §12.17 — so by the time this alert appears the app already
//  agrees with the disk, and a toggle has already snapped back to where it was.
//  An alert that also tried to repair state would be a second opinion about
//  what happened, and the two would disagree the first time one of them changed.
//

import SwiftUI

extension View {

    /// Presents a store-write failure, with a retry when retrying could help.
    ///
    /// - Parameters:
    ///   - error: cleared when the alert is dismissed, so the binding is the
    ///     whole of the presentation state. No separate `isPresented` to keep
    ///     in step with it — two flags for one condition is how an alert comes
    ///     to fire with nothing in it.
    ///   - retry: run when the athlete taps *Try again*. Omit it and no retry
    ///     is offered at all, whatever the stage — a caller that cannot repeat
    ///     the action must not be made to look as though it can.
    func storeWriteFailure(_ error: Binding<StoreWriteError?>,
                           retry: (() -> Void)? = nil) -> some View {
        alert("Not saved",
              isPresented: Binding(get: { error.wrappedValue != nil },
                                   set: { if !$0 { error.wrappedValue = nil } }),
              presenting: error.wrappedValue) { failure in
            if let retry, failure.stage.isWorthRetrying {
                Button("Try again") { retry() }
            }
            Button("OK", role: .cancel) { }
        } message: { failure in
            Text(failure.errorDescription ?? "The change could not be saved.")
        }
    }
}
