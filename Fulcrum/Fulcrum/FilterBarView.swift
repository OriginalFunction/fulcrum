import SwiftUI
import FulcrumKit

/// The controls above the resource table: name search, then the two
/// visibility toggles — tilt's own control order, left to right.
struct FilterBarView: View {
    @Bindable var dashboard: DashboardModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textSecondary)
                TextField("Filter resources", text: $dashboard.filter.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .frame(maxWidth: 220)

            Toggle("Alerts on top", isOn: $dashboard.filter.alertsOnTop)
                .toggleStyle(.checkbox)

            Toggle("Show disabled", isOn: $dashboard.filter.showDisabled)
                .toggleStyle(.checkbox)

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}
