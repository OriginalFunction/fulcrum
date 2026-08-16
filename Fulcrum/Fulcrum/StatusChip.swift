import SwiftUI
import FulcrumKit

/// A square status indicator, following tilt's own visual language rather than
/// Docker's round dots.
///
/// `health == nil` renders distinctly from every real health value (see
/// `Theme.unknown`). The label is supplied by the caller rather than derived
/// here: what `nil` health *means* — "not running", "connecting", "an
/// aggregate with nothing running" — depends on context this view does not
/// have, and that mapping lives in `FulcrumKit` where it is testable. See
/// `SidebarItem.statusLabel`, `Resource.statusLabel`, and
/// `DashboardModel.statusStripLabel`.
struct StatusChip: View {
    let health: ResourceHealth?
    let label: String
    var size: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(health.map(Theme.color(for:)) ?? Theme.unknown)
            .frame(width: size, height: size)
            .accessibilityLabel(label)
    }
}
