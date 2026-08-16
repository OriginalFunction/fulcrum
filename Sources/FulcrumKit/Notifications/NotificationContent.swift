import Foundation

/// The user-visible text of a delivered notification, plus the identifier the
/// system coalesces on.
public struct NotificationContent: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Stable per `(port, resource)`, and deliberately shared between the
    /// `.failed` and `.recovered` notifications for the same resource: posting
    /// with an identifier that already exists in Notification Center replaces
    /// that entry rather than stacking a second one, so a recovery clears the
    /// stale "failed" banner instead of leaving both on screen contradicting
    /// each other.
    public let identifier: String

    public init(_ notification: FailureNotification) {
        switch notification.kind {
        case .failed: title = "Resource failed"
        case .recovered: title = "Resource recovered"
        }
        // Both the resource AND the project, always. Fulcrum watches several
        // projects at once and duplicate resource names across them are
        // ordinary, so "web failed" alone would not tell the user which
        // project to go and look at — the notification has to be actionable
        // without opening anything.
        body = "\(notification.resourceName) — \(notification.instanceName)"
        identifier = "resource-health.\(notification.port).\(notification.resourceName)"
    }
}

/// What a notification click has to carry in order to land somewhere useful:
/// which resource, on which instance.
///
/// Round-trips through `UNNotificationContent.userInfo`, which is a plain
/// property list dictionary — hence `String` values throughout, port
/// included. A malformed or foreign payload yields `nil` rather than a
/// guessed target, since focusing the wrong resource is worse than doing
/// nothing.
public struct NotificationTarget: Equatable, Sendable {
    public let resourceName: String
    public let port: Int

    public init(resourceName: String, port: Int) {
        self.resourceName = resourceName
        self.port = port
    }

    public init(_ notification: FailureNotification) {
        self.init(resourceName: notification.resourceName, port: notification.port)
    }

    private static let resourceKey = "fulcrum.resourceName"
    private static let portKey = "fulcrum.port"

    public var userInfo: [String: String] {
        [Self.resourceKey: resourceName, Self.portKey: String(port)]
    }

    /// Both keys must be present and the port must parse. A payload from
    /// anything else — or one whose shape has changed across an app update
    /// while the old notification still sits in Notification Center — is
    /// refused rather than half-read.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let resourceName = userInfo[Self.resourceKey] as? String,
              let rawPort = userInfo[Self.portKey] as? String,
              let port = Int(rawPort) else { return nil }
        self.init(resourceName: resourceName, port: port)
    }
}
