import Foundation

/// Whether macOS will let Fulcrum post a notification at all.
///
/// Deliberately three-valued rather than a `Bool`: "not asked yet" and
/// "asked and refused" demand opposite responses from the app. The first is
/// a prompt waiting to happen; the second is a dead channel that no amount
/// of in-app setting can revive, and which the Settings pane must therefore
/// say out loud (see `NotificationSettingsNotice`).
public enum NotificationAuthorization: String, Sendable, Equatable, CaseIterable {
    case notDetermined
    case denied
    case authorized
}

/// The seam between the notification *decision* (`FailureNotifier`,
/// `NotificationCoordinator` — both pure, both testable) and the one thing
/// that genuinely cannot live in `FulcrumKit`: `UserNotifications`.
///
/// `FulcrumKit` must not import AppKit/UserNotifications (the package builds
/// and tests without Xcode), and the app target has no test bundle. So every
/// rule about *when* to prompt, *when* to deliver and *where* a click lands
/// lives on this side of the protocol, and the app-side conformer
/// (`NotificationPresenter`) is kept as close to a straight translation of
/// these calls into `UNUserNotificationCenter` as possible.
///
/// `requestAuthorization` is completion-based rather than `async` on purpose:
/// the coordinator's queue-then-flush logic stays synchronous and
/// deterministic under test, instead of depending on when an unstructured
/// `Task` happens to resume.
@MainActor
public protocol NotificationDelivering: AnyObject {
    /// The last known authorization state. Cached by the conformer rather
    /// than queried per call — `UNUserNotificationCenter`'s own query is
    /// async, and delivery decisions have to be made synchronously.
    var authorization: NotificationAuthorization { get }

    /// Presents the system permission prompt, calling back with the answer.
    /// Only ever called by `NotificationCoordinator`, and only at the moments
    /// documented there — never at launch.
    func requestAuthorization(_ completion: @escaping @MainActor (NotificationAuthorization) -> Void)

    /// Posts one notification. Content and click payload are derived from the
    /// notification itself (`NotificationContent`, `NotificationTarget`) so
    /// the app side chooses neither.
    func deliver(_ notification: FailureNotification)
}
