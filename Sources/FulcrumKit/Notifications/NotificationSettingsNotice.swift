import Foundation

/// What the Settings pane must say underneath the notification policy picker
/// so the picker can never be a control that silently does nothing.
///
/// This app has shipped toggles that quietly no-op'd more than once. A user
/// who has denied Fulcrum in System Settings and then sets the policy to
/// "Failures only" has done everything right and will still receive nothing;
/// the only honest response is to say so in the pane and offer the door to
/// the place they can fix it.
public struct NotificationSettingsNotice: Equatable, Sendable {
    public let message: String
    /// Whether to show the "Open Notification Settings…" button. Only true
    /// when there is something in System Settings for the user to actually
    /// change — a not-yet-asked permission is not that.
    public let offersSystemSettings: Bool

    public init(message: String, offersSystemSettings: Bool) {
        self.message = message
        self.offersSystemSettings = offersSystemSettings
    }

    public static func notice(
        policy: NotificationPolicy, authorization: NotificationAuthorization
    ) -> NotificationSettingsNotice? {
        // Nothing is being suppressed against the user's wishes while the
        // policy is off — they turned it off themselves. Warning about an
        // unused permission is noise, and noise is what teaches people to
        // stop reading this pane.
        guard policy != .off else { return nil }

        switch authorization {
        case .authorized:
            return nil
        case .denied:
            return NotificationSettingsNotice(
                message: "macOS is blocking Fulcrum's notifications, so this setting has no effect. "
                       + "Allow them in System Settings to start receiving them.",
                offersSystemSettings: true
            )
        case .notDetermined:
            // No button: Fulcrum has never asked, so there is no Fulcrum entry
            // in System Settings > Notifications yet for the button to open.
            return NotificationSettingsNotice(
                message: "macOS will ask for permission the first time a resource fails.",
                offersSystemSettings: false
            )
        }
    }
}
