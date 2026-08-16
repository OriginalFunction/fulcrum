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

/// How many lines the log pane keeps before it starts dropping the oldest —
/// the user's own pick from a MEASURED cost curve, rather than a number this
/// app chooses on their behalf.
///
/// The pane's cost is `publications/sec x O(occupancy)`, and the publication
/// rate is nearly independent of how fast lines arrive (a coalescer that
/// publishes on a timer publishes on a timer). Occupancy is therefore the
/// only term a normal stream moves, and it is the one this preference sets a
/// ceiling on. Holding the arrival rate at 6 lines/sec — the developer's real
/// measured stream — with the buffer full and evicting throughout, and
/// varying nothing but capacity, `hangprobe` measures (two 2-minute runs per
/// capacity, on this tree):
///
/// | capacity | availability | interval selected | publications/sec |
/// |---|---|---|---|
/// | 500 | 100.1%, 100.1% | 150ms | 5.94 |
/// | 1,000 | 99.7%, 99.2% | 150ms | 5.94 |
/// | 2,500 | 99.1%, 99.4% | **500ms** | 1.98 |
/// | 5,000 | 90.9%, 90.2% | **500ms** | 1.98 |
///
/// READ THAT TABLE ACROSS, NOT DOWN. Availability alone separates only the
/// last row, and it flatters the middle two: 2,500 and 5,000 hold theirs by
/// selecting `LogPaneModel.floodedRefreshInterval`, publishing 1.98 times a
/// second instead of 5.94 — which is the pane running up to 500ms behind the
/// stream, permanently, because occupancy never falls. What the user is
/// really picking between is therefore three things and not two: how far back
/// they can scroll, whether the pane keeps up line-for-line, and (at 5,000
/// only) about 10 points of main-thread responsiveness. `detail` says all
/// three in plain words.
///
/// These absolutes are NOT comparable with the ones in
/// `occupancy-hypothesis.md`. That report's harness held an `NSLock`-backed
/// id-getter counter inside every figure it published and says so; this one
/// does not. The instrument, corpus, window size and arrival rate are
/// otherwise identical, and the SHAPE — flat, then a cliff — is the same in
/// both.
///
/// Every case below IS one of those four measured points. There is
/// deliberately no free-form number field and no option above 5,000: a
/// capacity nobody has measured is a capacity nobody can state the cost of,
/// and a field that accepts 50,000 invites a user to type it and then blame
/// the app.
public enum LogScrollback: String, CaseIterable, Sendable {
    case lines500
    /// The default — see `SettingsStore.logScrollback`.
    case lines1000
    case lines2500
    case lines5000

    /// What `LogPaneModel`/`LogBuffer` are actually built with.
    public var lineCount: Int {
        switch self {
        case .lines500: 500
        case .lines1000: 1_000
        case .lines2500: 2_500
        case .lines5000: 5_000
        }
    }

    public var title: String {
        switch self {
        case .lines500: "500 lines"
        case .lines1000: "1,000 lines"
        case .lines2500: "2,500 lines"
        case .lines5000: "5,000 lines"
        }
    }

    /// The trade-off this choice makes, in the user's own terms: roughly how
    /// far back it lets them scroll, and what it costs the pane. Rendered
    /// under the picker in `SettingsView` so the cost is stated rather than
    /// left to be inferred from a number of lines.
    ///
    /// The durations are that many lines at ~6 lines/sec, the rate a real
    /// 49-resource project was measured emitting. The responsiveness wording
    /// tracks the measured curve above; the "updates twice a second" clause
    /// appears on exactly the cases whose `lineCount` can reach
    /// `LogPaneModel.floodedOccupancy`, because those are the only ones that
    /// can ever select the slower publish interval.
    public var detail: String {
        switch self {
        case .lines500:
            "About a minute and a half of a busy stream. The pane stays fully responsive."
        case .lines1000:
            "About three minutes. The pane stays fully responsive."
        case .lines2500:
            "About seven minutes. Once the pane is this full it updates twice a second instead of six times, to stay responsive."
        case .lines5000:
            "About fourteen minutes. Scrolling and selecting get noticeably slower, and the pane updates twice a second instead of six times once it fills."
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
        self.logScrollback = Self.read(defaults, "logScrollback", default: .lines1000)
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

    /// How much scrollback the log pane keeps — see `LogScrollback` for the
    /// measured curve the four choices are read off.
    ///
    /// Defaults to `.lines1000`: the largest of the four choices that costs
    /// the user NEITHER of the two things the other options cost, which is a
    /// stronger claim than "the fastest one" and the reason it beats 500.
    ///
    /// * **No measurable responsiveness cost.** 99.7% and 99.2% across two
    ///   runs, against 90.9% and 90.2% for the 5,000 that shipped in v1.0.
    ///   500 measures 100.1% — 0.6 points better, for half the scrollback,
    ///   and inside a spread that has reached 1.5 points on a good day. Not a
    ///   trade a default should make on anyone's behalf.
    /// * **No imposed lag.** It is below `LogPaneModel.floodedOccupancy`, so a
    ///   pane at this capacity never selects the slower publish interval
    ///   however long it runs — measured at 5.94 publications/sec with the
    ///   buffer full, against 1.98 at 2,500. This is what actually separates
    ///   1,000 from 2,500, whose availability figures are indistinguishable:
    ///   2,500 buys its 99.4% by falling up to 500ms behind the stream,
    ///   permanently, because occupancy never falls once the buffer fills.
    ///   The whole reason this preference exists is that af1e601 imposed
    ///   exactly that lag on everyone; a default that quietly re-imposed it
    ///   would have missed the point. 2,500 and 5,000 both reach the
    ///   threshold and both say so in their `detail` copy — a user choosing
    ///   them chooses the lag knowingly, which is the entire difference.
    ///
    /// What it gives up against the shipped 5,000 is real and is stated in
    /// the UI: about three minutes of a busy stream instead of about
    /// fourteen, and `jumpToNextError()` cannot reach a failure that has been
    /// evicted. That is the trade this preference exists to hand over.
    ///
    /// Applied live, without a relaunch and without restarting the stream —
    /// see `LogPaneModel.setCapacity(_:)`.
    public var logScrollback: LogScrollback {
        didSet { defaults.set(logScrollback.rawValue, forKey: "logScrollback") }
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
