import Foundation
import Observation

public enum MenuBarIconMode: String, CaseIterable, Sendable {
    case worstStateHealth
    case buildActivity
    case instanceCount
    case healthWithCounts

    public var title: String {
        switch self {
        case .worstStateHealth: "Worst-state health"
        case .buildActivity: "Build activity only"
        case .instanceCount: "Instance count"
        case .healthWithCounts: "Health + counts badge"
        }
    }
}

public enum FailuresInMenu: String, CaseIterable, Sendable {
    /// Shown only when something is failing.
    case auto
    case always
    case never

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

/// How aggressively `FailureNotifier` (Notifications/FailureNotifier.swift)
/// surfaces resource health transitions once a baseline is established.
/// `.off` suppresses delivery entirely but the notifier still tracks state
/// underneath, so switching back mid-session does not miss a transition that
/// happened while muted.
public enum NotificationPolicy: String, CaseIterable, Sendable {
    case off
    case failures
    case failuresAndRecoveries

    public var title: String {
        switch self {
        case .off: "Off"
        case .failures: "Failures only"
        case .failuresAndRecoveries: "Failures and recoveries"
        }
    }
}

public enum AppearanceMode: String, CaseIterable, Sendable {
    case light, dark, system

    public var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

public enum LogPaneAppearance: String, CaseIterable, Sendable {
    case followTheme, alwaysDark

    public var title: String {
        switch self {
        case .followTheme: "Follow theme"
        case .alwaysDark: "Always dark"
        }
    }
}

/// How a detected JSON block renders once expanded — `LogPaneView`'s own
/// concern entirely; `LogPaneModel` has no idea this type exists (see
/// `LogPaneModel.focusedBlockID`'s doc comment for why that separation is
/// what makes switching this setting mid-session lossless).
public enum JSONPresentation: String, CaseIterable, Sendable {
    /// The tree renders in place, inside the block's own row — Task 5's
    /// original presentation.
    case inline
    /// The tree renders in a side panel next to the log, which keeps
    /// flowing; the row itself stays collapsed to its summary line.
    case detailPane

    public var title: String {
        switch self {
        case .inline: "Inline"
        case .detailPane: "Detail pane"
        }
    }
}

/// User preferences, backed by `UserDefaults`.
@Observable
@MainActor
public final class SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.iconMode = Self.read(defaults, "iconMode", default: .worstStateHealth)
        self.failuresInMenu = Self.read(defaults, "failuresInMenu", default: .auto)
        self.notificationPolicy = Self.read(defaults, "notificationPolicy", default: .failures)
        self.appearance = Self.read(defaults, "appearance", default: .system)
        self.logPaneAppearance = Self.read(defaults, "logPaneAppearance", default: .followTheme)
        self.jsonPresentation = Self.read(defaults, "jsonPresentation", default: .inline)
        self.logPaneHeight = defaults.object(forKey: "logPaneHeight") != nil
            ? defaults.double(forKey: "logPaneHeight") : Self.defaultLogPaneHeight
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.alertsOnTop = defaults.bool(forKey: "alertsOnTop")
        self.showDisabled = defaults.bool(forKey: "showDisabled")
    }

    public var iconMode: MenuBarIconMode {
        didSet { defaults.set(iconMode.rawValue, forKey: "iconMode") }
    }

    public var failuresInMenu: FailuresInMenu {
        didSet { defaults.set(failuresInMenu.rawValue, forKey: "failuresInMenu") }
    }

    /// Governs `FailureNotifier`'s delivery — see `NotificationPolicy`.
    public var notificationPolicy: NotificationPolicy {
        didSet { defaults.set(notificationPolicy.rawValue, forKey: "notificationPolicy") }
    }

    public var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }

    public var logPaneAppearance: LogPaneAppearance {
        didSet { defaults.set(logPaneAppearance.rawValue, forKey: "logPaneAppearance") }
    }

    /// How an expanded JSON block renders — inline in its row, or in a side
    /// detail pane. See `JSONPresentation`'s doc comment.
    public var jsonPresentation: JSONPresentation {
        didSet { defaults.set(jsonPresentation.rawValue, forKey: "jsonPresentation") }
    }

    /// The log pane's height within the dashboard's `VSplitView`, in points.
    /// Persisted the same way every other split-position-shaped preference in
    /// this app would be, so dragging the divider survives a relaunch instead
    /// of resetting to a fixed default every time.
    public var logPaneHeight: Double {
        didSet { defaults.set(logPaneHeight, forKey: "logPaneHeight") }
    }

    /// `UserDefaults.double(forKey:)` returns `0` for a key that was never
    /// set, which would open a first launch with the log pane collapsed to
    /// nothing — indistinguishable from a user having dragged it there.
    /// Checked via `defaults.object(forKey:)` in `init` so an absent key
    /// falls back to this instead of that `0`.
    static let defaultLogPaneHeight: Double = 220

    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    /// The dashboard filter bar's "Alerts on top" toggle. This — not
    /// `DashboardModel.filter` — is the single source of truth: `filter` is
    /// a computed property that reads and writes this directly, on every
    /// access, so there is no separate copy that could drift out of step.
    /// Same plain-`Bool` pattern as `launchAtLogin`, since there is no
    /// "unrecognised value" case for a `Bool` to fall back from.
    public var alertsOnTop: Bool {
        didSet { defaults.set(alertsOnTop, forKey: "alertsOnTop") }
    }

    /// The dashboard filter bar's "Show disabled" toggle — see
    /// `alertsOnTop`'s doc comment for the source-of-truth relationship with
    /// `DashboardModel.filter`, which holds identically for this one.
    public var showDisabled: Bool {
        didSet { defaults.set(showDisabled, forKey: "showDisabled") }
    }

    /// An unrecognised stored value falls back to the default rather than crashing —
    /// preferences outlive the code that wrote them.
    private static func read<T: RawRepresentable>(
        _ defaults: UserDefaults, _ key: String, default fallback: T
    ) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else {
            return fallback
        }
        return value
    }
}
