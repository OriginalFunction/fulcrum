import SwiftUI
import FulcrumKit

/// The strip along the bottom of the dashboard: aggregate counts across every
/// running instance on the left, the selected instance's own rollup
/// (`RESOURCES ×2 ⚙2 ✓45/49`, tilt's own header shape) on the right.
struct StatusStripView: View {
    let dashboard: DashboardModel

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(health: dashboard.worstHealth, label: dashboard.statusStripLabel, size: 8)
            Text(dashboard.statusSummary)
            Spacer()
            // The spec puts tilt's version here, but Fulcrum does not know it yet:
            // reading it needs `tilt version`, and the CLI wrapper is plan 3.
            // Showing `minimumTiltVersion` would be stating our floor as if it were
            // the running version, which is worse than showing nothing.
            if let summary = dashboard.selectedSummary {
                Text("RESOURCES")
                    .font(.caption2.weight(.semibold))
                GroupCounts(summary: summary)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}
