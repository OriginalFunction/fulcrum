import AppKit
import FulcrumKit

/// The one place `NSApp.setActivationPolicy` is called.
///
/// Fulcrum is `LSUIElement`, so it has no Dock icon or Cmd-Tab entry until it
/// puts a window on screen and switches to `.regular` — and it must switch
/// back to `.accessory` when the last one closes, or it silently stops being a
/// menu bar app for the rest of the session.
///
/// Which policy applies is decided by `WindowPresence` in `FulcrumKit`, where
/// it is testable without AppKit; see that type for why the decision must not
/// be made by asking a closing window whether it is still visible (it says
/// yes). This class is only the translation, plus the ordering rule below.
@MainActor
final class ActivationPolicyController {
    private var presence = WindowPresence()

    /// Called by a window controller's `show()` BEFORE it activates the app.
    /// Flipping the policy after `activate` — or not at all — is the
    /// documented cause of an accessory app's window landing in the Dock
    /// without coming forward; see the Apple forums thread linked from
    /// `DashboardWindowController.show()`.
    func windowDidOpen(_ window: WindowPresence.Window) {
        apply(presence.windowDidOpen(window))
    }

    /// Called from a window controller's `windowWillClose`. Safe to call
    /// there — unlike an `isVisible` check, this does not depend on when
    /// AppKit gets around to marking the window gone.
    func windowWillClose(_ window: WindowPresence.Window) {
        apply(presence.windowWillClose(window))
    }

    private func apply(_ policy: ActivationPolicy) {
        NSApp.setActivationPolicy(policy == .regular ? .regular : .accessory)
    }
}
