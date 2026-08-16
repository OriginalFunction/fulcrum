import SwiftUI
import FulcrumKit

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    let notificationPresenter: NotificationPresenter
    let notifications: NotificationCoordinator

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Menu bar icon", selection: $settings.iconMode) {
                ForEach(MenuBarIconMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Show failures in menu", selection: $settings.failuresInMenu) {
                ForEach(FailuresInMenu.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("JSON blocks", selection: $settings.jsonPresentation) {
                ForEach(JSONPresentation.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            // Scrollback against responsiveness, said out loud. The picker
            // alone would only offer four numbers and leave the user to work
            // out that a bigger one costs them something — which is the whole
            // reason the pane got slow enough to need this setting. The
            // footer states the mechanism once; the caption under it states
            // what the CURRENT choice actually costs, and both come from
            // `FulcrumKit` (`LogScrollback.detail`) where the numbers behind
            // them are documented against the measurements.
            Section {
                Picker("Log scrollback", selection: $settings.logScrollback) {
                    ForEach(LogScrollback.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(settings.logScrollback.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("How many lines the log pane keeps before it starts dropping the oldest. More scrollback to search back through costs responsiveness — the pane redoes work in proportion to how many lines it is holding, several times a second, so a bigger buffer makes the whole app slower for as long as the pane is open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Notifications", selection: $settings.notificationPolicy) {
                    ForEach(NotificationPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                // Turning the policy on is an explicit opt-in and therefore a
                // legitimate moment to settle the system permission — see
                // `NotificationCoordinator.policyDidChange()`.
                .onChange(of: settings.notificationPolicy) { notifications.policyDidChange() }

                // A picker that quietly does nothing because macOS is blocking
                // the app is this project's most repeated failure. The notice
                // is derived in `FulcrumKit` (`NotificationSettingsNotice`),
                // where it is actually testable; this view only renders it.
                if let notice = NotificationSettingsNotice.notice(
                    policy: settings.notificationPolicy,
                    authorization: notificationPresenter.authorization
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(notice.message, systemImage: notice.offersSystemSettings
                              ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.callout)
                            .foregroundStyle(notice.offersSystemSettings ? .primary : .secondary)
                        if notice.offersSystemSettings {
                            Button("Open Notification Settings…") {
                                NotificationSystemSettings.open()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // The permission can change while this pane is open — the user can
        // walk to System Settings and back without Fulcrum being told.
        .onAppear { notificationPresenter.refreshAuthorization() }
        // Carried since plan 1: Light/Dark/System applied to every other
        // surface but this one. Settings is a real SwiftUI `Settings` scene
        // (see `AppearanceMode.colorScheme`'s doc comment for why that means
        // this, not `DashboardWindowController`'s manual `NSWindow.appearance`
        // pattern, is the right fix here) — reading `settings.appearance`
        // directly in `body` means a change made while this pane is open
        // takes effect immediately, the same as every other setting on this
        // form.
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}
