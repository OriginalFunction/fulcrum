import AppKit
import SwiftUI
import FulcrumKit

/// Owns the dashboard's `NSWindow`.
///
/// Deliberately not a SwiftUI `Window` scene: reaching one from AppKit means the
/// undocumented `openWindowWithID:` selector, and `showSettingsWindow:` already
/// demonstrated on this project that such calls can return `true` and do nothing.
/// An `NSWindow` we construct is a thing we can reason about.
@MainActor
final class DashboardWindowController: NSObject {
    private let dashboard: DashboardModel
    private let settings: SettingsStore
    private let actionCoordinator: ResourceActionCoordinator
    private let instanceActionCoordinator: InstanceActionCoordinator
    /// The same `TiltLauncher` instance the status menu's Open Tiltfile
    /// command and the app menu's ⌘O use — passed down to `SidebarView` so
    /// "Start" on a Recent row reuses that one launch path rather than
    /// standing up a second one. See `OpenTiltfileCommand`.
    private let tiltLauncher: TiltLauncher
    /// Told when this window opens and closes, instead of this controller
    /// flipping the activation policy itself — the About window
    /// (`AboutWindowController`) might still be open and needs its own Dock
    /// presence to survive this window closing.
    private let activationPolicy: ActivationPolicyController
    private var window: NSWindow?

    init(
        dashboard: DashboardModel,
        settings: SettingsStore,
        actionCoordinator: ResourceActionCoordinator,
        instanceActionCoordinator: InstanceActionCoordinator,
        tiltLauncher: TiltLauncher,
        activationPolicy: ActivationPolicyController
    ) {
        self.dashboard = dashboard
        self.settings = settings
        self.actionCoordinator = actionCoordinator
        self.instanceActionCoordinator = instanceActionCoordinator
        self.tiltLauncher = tiltLauncher
        self.activationPolicy = activationPolicy
        super.init()
    }

    /// Shows the window, creating it on first use. Subsequent calls focus the
    /// existing one rather than opening a second.
    ///
    /// `Fulcrum` is `LSUIElement` (accessory) so it normally has no Dock icon and
    /// can't be reached with Cmd-Tab. While the dashboard is open that's a problem —
    /// switch to `.regular` so it shows up in both, and back to `.accessory` in
    /// `windowWillClose` so it disappears again once the window is gone.
    ///
    /// Policy must flip *before* `activate`: flipping it after — or not at all —
    /// is the documented cause of an accessory app's window landing in the Dock
    /// without actually coming forward. See
    /// https://developer.apple.com/forums/thread/756322.
    ///
    /// Also where the log pane's stream (re)starts. `window` is never `nil`'d
    /// out after creation (`isReleasedWhenClosed` is `false`), so re-showing
    /// after a close reuses the same `NSHostingController` — `LogPaneView`'s
    /// own `onChange(..., initial: true)` fired once, the first time that
    /// view was created, and will not fire again just because the window
    /// comes back. (Measured, not assumed: instrumenting a Release build
    /// showed no `onAppear`, no `onChange` and no `body` re-evaluation at all
    /// on the second `show()`.) Re-pointing the pane here, on every `show()`,
    /// is what makes closing (which stops it, in `windowWillClose`) and
    /// reopening actually symmetric.
    ///
    /// It goes through `dashboardWindowDidBecomeVisible()` rather than
    /// calling `logPane.follow(_:)` directly, so that the resource scope is
    /// cleared when the followed instance changed while the window was shut.
    /// Closing the window scoped to `ai-api`, having that instance disappear,
    /// then reopening would otherwise show an empty pane under a "Scoped to
    /// ai-api" chip — the same divergence a direct call already caused once
    /// on the reconcile path.
    ///
    /// NOT `followSelectedInstanceLogs()`, which this called until it was
    /// found to be the whole bug: that one guards on
    /// `LogPaneModel.isFollowingAnInstance`, which `windowWillClose` has just
    /// cleared, so every reopen early-returned and the pane stayed blank
    /// under its header row with no `tilt logs` child at all. See
    /// `dashboardWindowDidBecomeVisible()`'s doc comment.
    func show() {
        activationPolicy.windowDidOpen(.dashboard)
        NSApp.activate(ignoringOtherApps: true)
        dashboard.dashboardWindowDidBecomeVisible()

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = DashboardWindow(
            dashboard: dashboard,
            settings: settings,
            actionCoordinator: actionCoordinator,
            instanceActionCoordinator: instanceActionCoordinator,
            tiltLauncher: tiltLauncher
        )

        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        created.title = "Fulcrum"
        created.contentViewController = NSHostingController(rootView: root)
        // Assigning contentViewController discards the init's contentRect — AppKit
        // resizes to the hosting controller's fitting size. Set the size after, then
        // centre, or the window opens tiny and off-centre and the autosave persists it.
        created.setContentSize(NSSize(width: 900, height: 560))
        created.center()
        created.setFrameAutosaveName("FulcrumDashboard")
        // The app is an accessory (LSUIElement), so releasing on close would
        // destroy the controller's only reference and lose the saved frame.
        created.isReleasedWhenClosed = false
        // Fulcrum has exactly one dashboard window, so AppKit's default
        // `.automatic` tabbing is pure noise: it puts a tab bar with a single
        // "Fulcrum" tab above the content, and adds Show/Hide Tab Bar and a
        // permanently-disabled Show All Tabs to the View menu. Opting out
        // removes the bar and those menu items together.
        created.tabbingMode = .disallowed
        // `delegate` is `weak` — safe here only because `AppDelegate` holds this
        // controller for the app's entire lifetime, well past any window close.
        created.delegate = self

        window = created
        created.makeKeyAndOrderFront(nil)
        observeAppearance()
    }

    /// Whether the dashboard is the thing the user is actually looking at:
    /// on screen, key, and in an app that is frontmost. Used by
    /// `AppDelegate.isViewingInstance` to suppress a notification about a
    /// project the user is already watching.
    ///
    /// All three checks are needed. `window` survives a close
    /// (`isReleasedWhenClosed = false`), so a non-nil window proves nothing;
    /// and a key window in a background app is not being looked at either —
    /// Fulcrum is an accessory app whose dashboard spends most of its life
    /// behind an editor.
    var isFrontmost: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isVisible && window.isKeyWindow
    }

    /// Keeps the window's chrome in step with the appearance setting. Re-arms
    /// itself because `withObservationTracking` fires once per registration.
    private func observeAppearance() {
        withObservationTracking {
            let appearance = settings.appearance.nsAppearance
            window?.appearance = appearance
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAppearance() }
        }
    }
}

extension DashboardWindowController: NSWindowDelegate {
    /// Drops back to accessory once the dashboard window is gone, so Fulcrum
    /// disappears from the Dock and Cmd-Tab and goes back to being purely a
    /// menu bar app. `isReleasedWhenClosed` is `false`, so the window (and
    /// this delegate relationship, and `dashboard` itself) survive the close
    /// — only the policy flips.
    ///
    /// That survival is exactly why the log pane's stream needs stopping
    /// here explicitly: `dashboard.logPane` is not torn down by the window
    /// closing, and nothing else would notice a closed-but-not-destroyed
    /// window to stop its `tilt logs --follow` child on.
    ///
    /// Restarting it on the next open is `show()`'s job alone, via
    /// `dashboard.dashboardWindowDidBecomeVisible()`. It is emphatically NOT
    /// `LogPaneView`'s `onChange(..., initial: true)`: the hosted view is not
    /// recreated when a closed-but-alive window is shown again, so that fires
    /// exactly once in the app's whole lifetime. An earlier version of this
    /// comment claimed the opposite and the pane was blank on every reopen
    /// because of it.
    ///
    /// Activation policy itself is NOT set here directly (that was this
    /// method's whole body before the About window existed) —
    /// `ActivationPolicyController` drops to `.accessory` only once every
    /// window this app can show, About included, is closed. It is told the
    /// dashboard is going rather than being left to ask: this window still
    /// reports `isVisible == true` right here, which is exactly how the
    /// policy got stuck at `.regular` once already. See `WindowPresence`.
    func windowWillClose(_ notification: Notification) {
        activationPolicy.windowWillClose(.dashboard)
        dashboard.logPane.follow(nil)
    }
}
