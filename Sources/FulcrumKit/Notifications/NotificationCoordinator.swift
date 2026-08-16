import Foundation

/// Turns `FailureNotifier`'s decisions into actual deliveries, and a click on
/// a delivered notification back into the dashboard's existing focus route.
///
/// Everything about delivery that can be decided without `UserNotifications`
/// lives here, because `FulcrumKit` is the only target with a test bundle.
/// The app-side conformer of `NotificationDelivering` is deliberately a thin
/// translation layer with no policy of its own.
///
/// ## When the permission prompt appears
/// Never at launch. A prompt the user cannot connect to something they just
/// did is the classic way to get denied, and denial cannot be undone from
/// inside the app — only from System Settings, which most people never visit.
/// So the prompt happens at exactly two moments, both of which the user can
/// explain to themselves:
///
/// 1. **The first time a notification would genuinely be posted right now** —
///    a resource just turned red and Fulcrum has something to say. This is
///    the primary trigger, and the only one most users will ever hit: the
///    policy already defaults to `.failures`, so "turn it on" is not a step
///    a default install performs.
/// 2. **An explicit off → on flip in Settings**, which is as unambiguous an
///    opt-in gesture as exists.
///
/// A notification that raised the prompt is held in `queuedPendingAuthorization`
/// rather than dropped, and posted if the answer is yes — otherwise the one
/// failure that justified asking would be the one failure never shown.
///
/// ## The instance the user is already looking at
/// Suppressed, narrowly: only when the dashboard is frontmost AND showing the
/// instance that failed (`isViewingInstance`). Interrupting someone to tell
/// them about a row they are watching turn red is noise, and noise is what
/// gets a notification channel muted for good. The bar is deliberately "the
/// user is looking at this project right now", not "the app is running" or
/// "a window is open somewhere" — Fulcrum is an accessory app whose dashboard
/// spends most of its life behind an editor.
///
/// The trade-off, accepted: the notifier's baseline still advances for a
/// suppressed transition, so that failure will not be announced later if the
/// user looks away while it is still red. That is the correct reading — they
/// already saw it — and the dashboard keeps showing it red regardless.
@MainActor
public final class NotificationCoordinator {
    private let settings: SettingsStore
    private let delivering: NotificationDelivering
    private let isViewingInstance: @MainActor (Int) -> Bool
    private let focusResource: @MainActor (_ resourceName: String, _ port: Int) -> Void
    private let notifier: FailureNotifier

    /// Notifications that arrived while the permission prompt was still
    /// unanswered. Flushed on a grant, discarded on a refusal.
    private var queuedPendingAuthorization: [FailureNotification] = []
    /// Guards against stacking a second prompt while one is on screen — a
    /// burst of failures on one watch tick, or further ticks arriving while
    /// the user reads the dialog, must not each raise their own request.
    private var isAwaitingAuthorization = false

    public init(
        settings: SettingsStore,
        delivering: NotificationDelivering,
        isViewingInstance: @escaping @MainActor (Int) -> Bool = { _ in false },
        focusResource: @escaping @MainActor (_ resourceName: String, _ port: Int) -> Void
    ) {
        self.settings = settings
        self.delivering = delivering
        self.isViewingInstance = isViewingInstance
        self.focusResource = focusResource
        self.notifier = FailureNotifier(policy: settings.notificationPolicy)
    }

    /// One instance's resources, as of this watch tick. Called from
    /// `InstanceSupervisor.onResourcesUpdated` — the app's existing
    /// observation path — so nothing polls tilt a second time.
    public func observe(resources: [Resource], forPort port: Int, instanceName: String) {
        // Re-read rather than cache: the policy can change in Settings at any
        // moment, and the notifier keeps its baseline across the change.
        notifier.policy = settings.notificationPolicy
        let newsworthy = notifier.observe(resources: resources, forPort: port, instanceName: instanceName)

        // Suppression is decided BEFORE authorization, not after: otherwise
        // watching a project break would raise a permission prompt for a
        // notification that was never going to be posted anyway.
        let deliverable = newsworthy.filter { !isViewingInstance($0.port) }
        guard !deliverable.isEmpty else { return }

        switch delivering.authorization {
        case .authorized:
            deliverable.forEach(delivering.deliver)
        case .denied:
            // Nothing to do here, and nothing this app can do about it — the
            // Settings pane is where that is said out loud, via
            // `NotificationSettingsNotice`. Silently dropping it *here* while
            // saying nothing *there* is the failure mode that keeps recurring.
            break
        case .notDetermined:
            queuedPendingAuthorization.append(contentsOf: deliverable)
            requestAuthorizationOnce()
        }
    }

    /// Call when the user changes the notification policy in Settings. Turning
    /// it on from off is an explicit opt-in, and the best moment to settle the
    /// permission — better than ambushing them with the prompt later, during
    /// whatever they were doing when a build happened to break.
    public func policyDidChange() {
        notifier.policy = settings.notificationPolicy
        guard settings.notificationPolicy != .off else { return }
        guard delivering.authorization == .notDetermined else { return }
        requestAuthorizationOnce()
    }

    /// A click on a delivered notification. Routes through the same
    /// `focusResource` closure `MenuBarController`'s failure rows use — which
    /// is `DashboardModel.focus(resource:onInstanceWithPort:)` plus opening
    /// the window. There is exactly one "take me to this resource" concept in
    /// this app; a second one has already caused a real bug here.
    public func handleActivation(_ target: NotificationTarget) {
        focusResource(target.resourceName, target.port)
    }

    private func requestAuthorizationOnce() {
        guard !isAwaitingAuthorization else { return }
        isAwaitingAuthorization = true
        delivering.requestAuthorization { [weak self] answer in
            guard let self else { return }
            isAwaitingAuthorization = false
            let queued = queuedPendingAuthorization
            queuedPendingAuthorization = []
            guard answer == .authorized else { return }
            queued.forEach(delivering.deliver)
        }
    }
}
