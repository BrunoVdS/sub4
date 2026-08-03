//
//  LifecycleLog.swift
//  Sub4
//
//  Where a receipt lives — patch 186.
//
//  WHY A RECEIPT CANNOT BE VIEW STATE
//  ----------------------------------
//  185 kept the delete receipt in `@State` on the privacy pane and presented it
//  as a sheet. It appeared and vanished again within a second, without being
//  touched — and the cause is the operation reporting on itself.
//
//  Deleting local data removes `appearance.selected`, `discipline.selected`,
//  `volume.unit` and `zones.window`. Those four are read through `@AppStorage`
//  by `SettingsView` and by half the cards in the app. Removing them invalidates
//  every one of those bindings at once, the Form rebuilds while the sheet is
//  still animating in, and the sheet — along with the `@State` holding the
//  receipt — goes with it.
//
//  No amount of care inside the view fixes that. The receipt has to outlive the
//  view that triggered it, so it lives here.
//
//  IT IS ALSO THE BETTER DESIGN
//  ----------------------------
//  A delete-my-data flow whose only evidence is a sheet you must read in the
//  four seconds after tapping is barely evidence. Kept here, the last receipt is
//  still there tomorrow, and the pane can offer it rather than insist on it.
//
//  DELIBERATELY NOT PERSISTED. Writing it to disk would mean a record of the
//  deletion surviving the deletion, which is the sort of thing this whole phase
//  exists to prevent. It lasts as long as the app runs, and no longer.
//

import Foundation

@Observable
final class LifecycleLog {

    static let shared = LifecycleLog()
    private init() {}

    /// A receipt waiting to be shown, wrapped so `sheet(item:)` can key on it.
    ///
    /// A fresh `id` per record, so recording twice presents twice rather than
    /// silently reusing the first sheet's identity.
    struct Pending: Identifiable {
        let id = UUID()
        let receipt: LifecycleReceipt
    }

    /// The most recent export or deletion, or nil if neither has run this
    /// session. Memory only — see the note above.
    private(set) var last: LifecycleReceipt?

    /// Set when something should be shown NOW. Read at the root of the app —
    /// see `ContentView` — because the privacy pane cannot present a sheet that
    /// survives its own delete.
    var pending: Pending?

    func record(_ receipt: LifecycleReceipt) {
        last = receipt
        pending = Pending(receipt: receipt)
    }

    /// Ask for the last receipt again, from the summary row.
    func showLast() {
        guard let r = last else { return }
        pending = Pending(receipt: r)
    }

    /// Only used when the pane is dismissed and the reader has finished with it.
    func clear() { last = nil; pending = nil }
}
