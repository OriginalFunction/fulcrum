import Foundation

/// Whether Fulcrum should currently appear in the Dock and Cmd-Tab.
///
/// Named in `FulcrumKit` rather than using `NSApplication.ActivationPolicy`
/// directly so the decision below can be made — and tested — without AppKit.
/// The app target translates it in exactly one place
/// (`ActivationPolicyController`).
public enum ActivationPolicy: Sendable, Equatable {
    /// A normal app: Dock icon, Cmd-Tab entry, main menu bar. What Fulcrum
    /// becomes while any of its own windows is on screen.
    case regular
    /// A menu bar app: no Dock icon, no Cmd-Tab entry. Fulcrum's resting
    /// state, and what it must return to once its last window closes.
    case accessory
}

/// Which of Fulcrum's own windows are open, and therefore which activation
/// policy the app should have.
///
/// This exists because the obvious implementation is wrong in a way that is
/// invisible from the call site. The first version asked AppKit —
/// `dashboardWindow.isVisible || aboutWindow.isVisible` — from inside
/// `windowWillClose`. But at `windowWillClose` time the closing window still
/// reports `isVisible == true`; it flips one run-loop turn later. The guard
/// therefore always saw a visible window and always returned early, so the app
/// never dropped back to `.accessory`: open the dashboard once, close it, and
/// the Dock icon and Cmd-Tab entry persisted for the rest of the session.
///
/// So this type never asks AppKit anything. It owns the set of open windows
/// and `windowWillClose` removes the closing window *before* deciding, which
/// makes the answer depend only on facts this type was told, not on when
/// AppKit happens to update a flag. Two consequences worth stating, both
/// tested:
///
/// - Closing one window while the other is genuinely still open keeps
///   `.regular`, which is the whole reason this decision was centralised
///   instead of each window controller flipping the policy itself.
/// - Closing *both* windows in the same run-loop turn (Cmd-W twice, or an app
///   terminate that closes them together) still ends at `.accessory`. A
///   deferred `isVisible` re-check — the other obvious fix — gets this case
///   wrong in the other direction unless every deferred check re-reads live
///   state, and it introduces a window in which a reopened window can race the
///   pending check. There is no timing here at all to get wrong.
public struct WindowPresence: Sendable, Equatable {
    /// The windows Fulcrum can put on screen itself. Deliberately an
    /// enumeration rather than window references: this type must stay free of
    /// AppKit, and identity is all the decision needs.
    ///
    /// The SwiftUI `Settings` scene is *not* here. Fulcrum does not own that
    /// window, cannot observe its close, and never flips the policy for it.
    public enum Window: String, Sendable, Hashable, CaseIterable {
        case dashboard
        case about
    }

    private var openWindows: Set<Window> = []

    public init() {}

    /// The policy implied by what is open right now. `.regular` while any
    /// window is open, `.accessory` when none is.
    public var policy: ActivationPolicy {
        openWindows.isEmpty ? .accessory : .regular
    }

    /// Records `window` as on screen and returns the policy that now applies.
    /// Idempotent: showing an already-open window (which is what a second
    /// "Open Dashboard" click does — it just focuses the existing one) records
    /// nothing new and cannot leave a phantom entry behind to strand the Dock
    /// icon later.
    @discardableResult
    public mutating func windowDidOpen(_ window: Window) -> ActivationPolicy {
        openWindows.insert(window)
        return policy
    }

    /// Records `window` as gone and returns the policy that now applies.
    ///
    /// The removal happens FIRST. That single ordering is the fix for the
    /// regression described on this type: the window whose close is being
    /// announced must not be counted as a reason to stay `.regular`.
    @discardableResult
    public mutating func windowWillClose(_ window: Window) -> ActivationPolicy {
        openWindows.remove(window)
        return policy
    }
}
