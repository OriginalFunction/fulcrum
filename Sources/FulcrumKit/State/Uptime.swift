import Foundation

/// Formats a duration as the resource table's uptime column: tilt's own
/// human scale, seconds up through days. Free-standing from `Resource` so a
/// ticking cell can call `format` once a second against the current time
/// without touching any other state — see `ResourceTableView`'s `UptimeCell`.
public enum Uptime {
    public static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        switch total {
        case ..<60:
            return "\(total)s"
        case ..<3_600:
            return "\(total / 60)m \(total % 60)s"
        case ..<86_400:
            return "\(total / 3_600)h \((total % 3_600) / 60)m"
        default:
            return "\(total / 86_400)d \((total % 86_400) / 3_600)h"
        }
    }
}
