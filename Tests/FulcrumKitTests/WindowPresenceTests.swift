import Foundation
import Testing
@testable import FulcrumKit

/// THE regression this type exists for. Shipped behaviour was: open the
/// dashboard once, close it, and Fulcrum kept its Dock icon and Cmd-Tab entry
/// for the rest of the session — it stopped being a menu bar app. The cause
/// was asking AppKit whether the closing window was visible from inside
/// `windowWillClose`, where it still answers `true`.
///
/// This fails against the pre-fix ordering (decide, then remove) and is the
/// mutation to reach for when changing `windowWillClose`.
@Test func closingTheOnlyOpenWindowReturnsTheAppToTheMenuBar() {
    var presence = WindowPresence()

    #expect(presence.windowDidOpen(.dashboard) == .regular)
    #expect(presence.windowWillClose(.dashboard) == .accessory)
    #expect(presence.policy == .accessory)
}

/// The reason the decision was centralised in the first place: the About
/// window closing must not pull the Dock icon out from under a dashboard that
/// is still on screen.
@Test func closingOneWindowWhileTheOtherIsOpenKeepsTheDockIcon() {
    var presence = WindowPresence()
    presence.windowDidOpen(.dashboard)
    presence.windowDidOpen(.about)

    #expect(presence.windowWillClose(.about) == .regular)
    #expect(presence.policy == .regular)
    // ...and the dashboard's own close, arriving later, still finishes the job.
    #expect(presence.windowWillClose(.dashboard) == .accessory)
}

/// Both directions of the pair, so a fix that merely special-cases one window
/// does not pass. Same as above with the roles swapped.
@Test func closingTheDashboardWhileAboutIsOpenAlsoKeepsTheDockIcon() {
    var presence = WindowPresence()
    presence.windowDidOpen(.about)
    presence.windowDidOpen(.dashboard)

    #expect(presence.windowWillClose(.dashboard) == .regular)
    #expect(presence.windowWillClose(.about) == .accessory)
}

/// Two closes in one run-loop turn — Cmd-W twice in quick succession, or a
/// terminate that closes both together. Neither window has had time to update
/// any AppKit visibility flag, so an implementation that consulted one would
/// leave the app `.regular` forever. This one only consults what it was told.
@Test func closingBothWindowsInTheSameTurnStillDropsToAccessory() {
    var presence = WindowPresence()
    presence.windowDidOpen(.dashboard)
    presence.windowDidOpen(.about)

    #expect(presence.windowWillClose(.dashboard) == .regular)
    #expect(presence.windowWillClose(.about) == .accessory)
}

/// A window reopening after a close must take the Dock icon back. The other
/// candidate fix — deferring the check a run-loop turn — has to reason about
/// this case racing the pending check; here it is just the next call.
@Test func reopeningAWindowTakesTheDockIconBack() {
    var presence = WindowPresence()
    presence.windowDidOpen(.dashboard)
    presence.windowWillClose(.dashboard)

    #expect(presence.windowDidOpen(.dashboard) == .regular)
    #expect(presence.windowWillClose(.dashboard) == .accessory)
}

/// `show()` on an already-open window only focuses it, and calls through here
/// again. A second open must not need a second close to undo it, or the Dock
/// icon strands exactly the way it did before.
@Test func showingAnAlreadyOpenWindowDoesNotNeedASecondCloseToUndo() {
    var presence = WindowPresence()
    presence.windowDidOpen(.dashboard)
    presence.windowDidOpen(.dashboard)
    presence.windowDidOpen(.dashboard)

    #expect(presence.windowWillClose(.dashboard) == .accessory)
}

/// Defensive: a close for a window this type never saw open (an AppKit
/// delegate callback arriving in an order we did not predict) must not be able
/// to strand the policy either way.
@Test func aCloseForAWindowThatWasNeverOpenedIsHarmless() {
    var presence = WindowPresence()
    #expect(presence.windowWillClose(.about) == .accessory)

    presence.windowDidOpen(.dashboard)
    #expect(presence.windowWillClose(.about) == .regular)
    #expect(presence.windowWillClose(.dashboard) == .accessory)
}

/// A fresh app has shown nothing, and `LSUIElement` already has it in the
/// menu bar — the resting state must read `.accessory`, not `.regular`.
@Test func anAppThatHasShownNothingIsAnAccessory() {
    #expect(WindowPresence().policy == .accessory)
}

/// Every window Fulcrum can show has to be able to hold the Dock icon on its
/// own; a case added later without a call site would otherwise sit here
/// untested. Driven off `CaseIterable` so adding one fails this until wired.
@Test func everyWindowKindHoldsTheDockIconOnItsOwn() {
    for window in WindowPresence.Window.allCases {
        var presence = WindowPresence()
        #expect(presence.windowDidOpen(window) == .regular, "\(window) did not take the Dock icon")
        #expect(presence.windowWillClose(window) == .accessory, "\(window) did not give the Dock icon back")
    }
}
