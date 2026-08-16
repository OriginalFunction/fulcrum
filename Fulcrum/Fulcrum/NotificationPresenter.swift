import AppKit
import FulcrumKit
import Observation
import UserNotifications
import os

/// File-scope rather than a `static let` on the presenter: a static on a
/// `@MainActor` type is itself main-actor-isolated and so unreachable from the
/// `nonisolated` delivery path below. `Logger` is `Sendable`.


private let notificationLogger = Logger(subsystem: "com.originalfunction.fulcrum", category: "Notifications")

/// The app-side half of `NotificationDelivering`: the one piece of the
/// notification feature that cannot live in `FulcrumKit`, because
/// `UserNotifications` cannot be imported there (the package builds and tests
/// without Xcode) and the app target has no test bundle.
///
/// Kept as close to a pure translation layer as possible for exactly that
/// reason — every decision worth testing (when to prompt, what to post, what
/// a click means, what Settings must say) lives in `NotificationCoordinator`,
/// `NotificationContent` and `NotificationSettingsNotice`. What remains here
/// is: ask `UNUserNotificationCenter`, tell `UNUserNotificationCenter`, and
/// hand clicks straight back to the coordinator.
@Observable
@MainActor
final class NotificationPresenter: NotificationDelivering {
    /// The last answer `UNUserNotificationCenter` gave. Read through
    /// `AuthorizationState`, which is `@Observable`, so the Settings pane's
    /// denial notice still updates the moment a refresh lands — including the
    /// refresh triggered by returning to Fulcrum after changing the permission
    /// in System Settings.
    ///
    /// The state lives there rather than here because "which of several
    /// overlapping reads is allowed to publish" is a decision worth testing,
    /// and `FulcrumKit` is where testable things go. See that type: an earlier
    /// `.denied` landing after a later `.authorized` used to leave this pane
    /// asserting a denial the user had just resolved.
    var authorization: NotificationAuthorization { authorizationState.authorization }

    @ObservationIgnored private lazy var authorizationState = AuthorizationState {
        await Self.currentAuthorization()
    }

    /// Every delivery goes through one chain, so two notifications about the
    /// same resource cannot land in the wrong order. They share a stable
    /// per-(port, resource) identifier — macOS updates one Notification Center
    /// entry in place — so an inverted failure/recovery pair does not merely
    /// look odd, it leaves the user reading the opposite of what happened.
    @ObservationIgnored private let deliveries = SerialAsyncQueue()

    /// Where a click goes. Set once by `AppDelegate` to
    /// `NotificationCoordinator.handleActivation` — this type does not decide
    /// what a click means, it only forwards the payload.
    @ObservationIgnored var onActivation: (@MainActor (NotificationTarget) -> Void)?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    /// `UNUserNotificationCenter.delegate` is `weak`, and this presenter is
    /// `@Observable` (so not an `NSObject` subclass). The forwarder is a
    /// separate object held strongly here rather than a conformance on
    /// `self`.
    @ObservationIgnored private lazy var forwarder = ActivationForwarder(presenter: self)


    /// Installs the delegate and reads the current permission WITHOUT asking
    /// for it. `notificationSettings()` is a query, not a request: it shows no
    /// prompt and creates no System Settings entry. Safe — and necessary — at
    /// launch, so the Settings pane can tell the truth about a denial the
    /// first time the user opens it.
    func start() {
        center.delegate = forwarder
        refreshAuthorization()
    }

    /// Re-reads the permission. Called at launch and whenever Fulcrum becomes
    /// active again, since the user may have just changed it in System
    /// Settings — the app is never notified of that.
    ///
    /// Fires and forgets, and so can overlap with itself: fixing a denial in
    /// System Settings means leaving Fulcrum and coming back, which is a burst
    /// of activations. `AuthorizationState` is what makes that safe — only the
    /// newest read publishes.
    func refreshAuthorization() {
        Task { await authorizationState.refresh() }
    }

    func requestAuthorization(_ completion: @escaping @MainActor (NotificationAuthorization) -> Void) {
        Task {
            // The `granted` flag alone is not the whole answer: an app that
            // was already denied gets `false` back with no prompt shown, and
            // an app already authorized gets `true` with no prompt either.
            // Re-reading settings afterwards is what distinguishes them.
            do {
                _ = try await Self.requestSystemAuthorization()
            } catch {
                notificationLogger.error("notification authorization request failed: \(String(describing: error), privacy: .public)")
            }
            // Completed with what THIS read saw, not with `authorization`: a
            // refresh racing this one could have superseded it, and the caller
            // decides whether to post the notification that raised the prompt.
            // It must answer for the prompt the user just responded to.
            completion(await authorizationState.refresh())
        }
    }

    func deliver(_ notification: FailureNotification) {
        // Only `Sendable` values (`NotificationContent`, a `[String: String]`)
        // cross into `post`. The request object itself is built on the far
        // side because `UNMutableNotificationContent` is not `Sendable`.
        //
        // Enqueued rather than given its own `Task`: independent tasks finish
        // in any order, and a failure and its recovery share one Notification
        // Center entry. See `SerialAsyncQueue`.
        let content = NotificationContent(notification)
        let userInfo = NotificationTarget(notification).userInfo
        deliveries.enqueue { await Self.post(content, userInfo: userInfo) }
    }

    /// `nonisolated`, and awaited rather than given a completion handler.
    /// This crashed the app in live testing when it was written the obvious
    /// way: `center.add(request) { error in … }` inside a `@MainActor` method
    /// infers a `@MainActor` completion closure, but `UNUserNotificationCenter`
    /// calls that block on its own dispatch queue
    /// (`UNUserNotificationServiceConnection.call-out`), so the very first
    /// delivered notification tripped `dispatch_assert_queue` and took the
    /// process down with a `SIGTRAP` — after the notification had been
    /// accepted, which is why the banner still appeared.
    private nonisolated static func post(_ rendered: NotificationContent, userInfo: [String: String]) async {
        let content = UNMutableNotificationContent()
        content.title = rendered.title
        content.body = rendered.body
        content.sound = .default
        // The only thing a click needs in order to land on the right row.
        content.userInfo = userInfo

        // `trigger: nil` delivers immediately. The identifier is stable per
        // (port, resource), so a recovery REPLACES its own failure entry in
        // Notification Center rather than stacking a contradiction next to it
        // — see `NotificationContent.identifier`.
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: rendered.identifier, content: content, trigger: nil)
            )
        } catch {
            notificationLogger.error("failed to post notification: \(String(describing: error), privacy: .public)")
        }
    }

    /// The permission, translated out of `UserNotifications` vocabulary. This
    /// is the whole of what `AuthorizationState` calls; it decides nothing
    /// about staleness, which is that type's job.
    private static func currentAuthorization() async -> NotificationAuthorization {
        // Hopped through a `nonisolated` helper because `UNNotificationSettings`
        // is not `Sendable` and so cannot cross back onto the main actor — the
        // plain `authorizationStatus` enum can, and it is all this needs.
        switch await Self.currentAuthorizationStatus() {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        // A status this SDK does not know about is not a licence to keep
        // prompting: treat it as settled-but-unusable rather than
        // `.notDetermined`, which would re-request on every failure.
        @unknown default: .denied
        }
    }

    /// Both of these re-fetch the singleton inside the `nonisolated` context
    /// rather than taking this object's `center` as a parameter:
    /// `UNUserNotificationCenter` is not `Sendable`, so handing the stored one
    /// across an isolation boundary is a Swift 6 error. `current()` is the
    /// same object either way.
    private nonisolated static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private nonisolated static func requestSystemAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Bridges `UNUserNotificationCenterDelegate` (an `NSObject` protocol)
    /// back to the presenter.
    private final class ActivationForwarder: NSObject, UNUserNotificationCenterDelegate {
        /// Unowned: `AppDelegate` owns the presenter for the app's whole
        /// lifetime, and the presenter owns this. A strong reference here
        /// would be a cycle.
        private unowned let presenter: NotificationPresenter

        init(presenter: NotificationPresenter) {
            self.presenter = presenter
        }

        /// Banners must show even while Fulcrum is frontmost. The default is
        /// to suppress them, which would mean a failure in a project the user
        /// is NOT looking at goes unannounced merely because the dashboard
        /// happens to be open on a different project. Whether the user is
        /// actually watching the failing instance is a decision
        /// `NotificationCoordinator` already made before anything got here.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .list, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            // Decoded here, on the delegate's own (nonisolated) side: neither
            // `UNNotificationResponse` nor a `userInfo` dictionary is
            // `Sendable`, but `NotificationTarget` is — so only the decoded
            // target crosses onto the main actor.
            let isDismissal = response.actionIdentifier == UNNotificationDismissActionIdentifier
            let target = NotificationTarget(userInfo: response.notification.request.content.userInfo)
            completionHandler()

            // A dismissal is not a click; only a real activation should yank
            // the dashboard to the front. An unreadable payload does nothing
            // at all rather than guessing a resource to focus.
            guard !isDismissal, let target else { return }
            Task { @MainActor [presenter] in presenter.onActivation?(target) }
        }
    }
}

/// Opens System Settings at the place a denied notification permission can
/// actually be changed — the pane the Settings toggle's denial notice offers.
/// Nothing inside the app can undo a denial, so a notice that did not lead
/// somewhere would be no better than the silent no-op it exists to replace.
enum NotificationSystemSettings {
    static func open() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        // The per-app deep link first; the Notifications pane itself as a
        // fallback, in case a future macOS stops honouring the `id` query.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
