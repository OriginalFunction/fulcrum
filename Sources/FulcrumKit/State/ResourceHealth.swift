import Foundation

/// Collapses tilt's two status channels into one displayable state.
///
/// Ordered worst-last so aggregate health is `max()`: this ordering is what the
/// menu bar icon is derived from.
public enum ResourceHealth: Int, Comparable, Sendable, CaseIterable {
    case disabled
    case ok
    case pending
    case building
    case error

    public static func < (lhs: ResourceHealth, rhs: ResourceHealth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Derives health from tilt's `updateStatus` and `runtimeStatus`.
    ///
    /// Disabled wins outright — a disabled resource's stale error is not something
    /// to alarm anyone about.
    static func derive(update: String?, runtime: String?, isDisabled: Bool) -> ResourceHealth {
        if isDisabled { return .disabled }
        if update == "error" || runtime == "error" { return .error }
        if update == "in_progress" { return .building }
        if update == "pending" || runtime == "pending" { return .pending }

        // "unknown", "none", and an absent status all mean tilt has not assessed
        // this resource yet. Reporting that as healthy would make the menu bar icon
        // claim all-clear about something it has not heard from.
        //
        // "not_applicable" is deliberately NOT in this set: it means the channel
        // genuinely does not apply — a local_resource with no runtime reports
        // runtimeStatus "not_applicable" forever, and treating that as pending
        // would leave the icon permanently amber.
        if update == "none" || runtime == "unknown" || runtime == "none" { return .pending }
        if update == nil && runtime == nil { return .pending }

        return .ok
    }
}

extension ResourceHealth {
    /// Words for a status chip's accessibility label, describing this health
    /// value on its own. Callers that must also describe the "no health value
    /// yet" state wrap this separately — see `SidebarItem.statusLabel`, which
    /// is the total mapping including that case.
    public var label: String {
        switch self {
        case .error: "error"
        case .building: "building"
        case .pending: "pending"
        case .ok: "healthy"
        case .disabled: "disabled"
        }
    }
}
