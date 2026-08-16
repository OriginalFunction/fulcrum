import AppKit
import SwiftUI
import FulcrumKit

/// Owns the About window. Mirrors `DashboardWindowController`'s shape —
/// a real `NSWindow` we construct ourselves, not a SwiftUI `Window` scene
/// reached via the undocumented `openWindowWithID:` selector, which this
/// project has already found to return `true` and do nothing (see
/// `MenuBarController.openSettings`'s doc comment on `showSettingsWindow:`
/// for the same failure shape).
@MainActor
final class AboutWindowController: NSObject {
    /// Told when this window opens and closes so it, not this controller,
    /// decides the activation policy — the Dashboard window might still be
    /// open and needs its Dock presence to survive this window closing.
    private let activationPolicy: ActivationPolicyController
    private var window: NSWindow?

    init(activationPolicy: ActivationPolicyController) {
        self.activationPolicy = activationPolicy
        super.init()
    }

    /// Shows the window, creating it on first use. Subsequent calls focus
    /// the existing one rather than opening a second — same shape as
    /// `DashboardWindowController.show()`.
    ///
    /// Activation policy must flip to `.regular` *before* `activate`, same
    /// as `DashboardWindowController.show()` — flipping after (or not at
    /// all) is the documented cause of an accessory app's window landing in
    /// the Dock without actually coming forward. See
    /// https://developer.apple.com/forums/thread/756322.
    func show() {
        activationPolicy.windowDidOpen(.about)
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        created.title = "About Fulcrum"
        created.contentViewController = NSHostingController(rootView: AboutView())
        created.center()
        // Releasing on close would destroy this controller's only reference —
        // same reasoning as `DashboardWindowController`.
        created.isReleasedWhenClosed = false
        created.delegate = self

        window = created
        created.makeKeyAndOrderFront(nil)
    }
}

extension AboutWindowController: NSWindowDelegate {
    /// Announces the close rather than checking visibility: this window still
    /// reports `isVisible == true` at this point, and the Dashboard may or may
    /// not still be open. `ActivationPolicyController` owns that decision —
    /// see `WindowPresence` for the regression that came of asking AppKit.
    func windowWillClose(_ notification: Notification) {
        activationPolicy.windowWillClose(.about)
    }
}
