import SwiftUI
import AppKit
import FulcrumKit

/// Icon actions for the selected instance, top-right of the dashboard: open
/// tilt's web UI, reload the Tiltfile, enable/disable everything, tear the
/// project down. These same five actions back the sidebar's per-project
/// context menu (`SidebarView`) — both surfaces drive `InstanceActionCoordinator`
/// and `presentConfirmation(_:)` directly rather than each re-implementing
/// the action or its confirmation copy, so the two cannot drift apart.
///
/// Always rendered, even with nothing selected or running — every button
/// disables itself with an explanatory tooltip rather than the whole row
/// disappearing, the same "disable, don't hide" rule `ResourceRow` already
/// follows for its own trigger button.
struct InstanceToolbarView: View {
    let dashboard: DashboardModel
    let actionCoordinator: InstanceActionCoordinator

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(dashboard.selectedItem?.title ?? "No Project Selected")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                tiltfilePathLine
            }

            Spacer()

            actionButton(systemImage: "safari", tooltip: openTooltip, disabled: !canOpenBrowser, action: openInBrowser)
            actionButton(systemImage: "arrow.clockwise", tooltip: reloadTooltip, disabled: !canActOnInstance, action: reloadTiltfile)
            actionButton(systemImage: "play.circle", tooltip: enableAllTooltip, disabled: !canActOnInstance, action: enableAll)
            actionButton(systemImage: "pause.circle", tooltip: disableAllTooltip, disabled: !canActOnInstance, action: confirmAndDisableAll)
            actionButton(systemImage: "trash", tooltip: tiltDownTooltip, disabled: !canTiltDown, action: confirmAndTiltDown)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
        // `actionCoordinator.lastFailure` surfaces exactly once, via a single
        // `.alert` at `DashboardWindow` — the ancestor common to this view and
        // `SidebarView`, which drives the same coordinator's context-menu
        // actions. Binding a second `.alert` to the same `lastFailure` here
        // would double-present the same failure; see `DashboardWindow`'s
        // comment for the failure mode that caused.
    }

    /// The selected project's Tiltfile path, under its name.
    ///
    /// NOTHING is drawn when there is no path — no placeholder, no blank
    /// line. `DashboardModel.selectedTiltfilePath` returns `nil` rather than
    /// `""` for exactly this reason, so the header shrinks back to one line
    /// instead of reserving an empty gap or showing a stand-in that reads
    /// like a filename.
    ///
    /// TRUNCATED IN THE MIDDLE, not at the tail. These paths are long and
    /// their two informative ends are the project directory and the file
    /// name; tail truncation hides the filename, which is exactly what tells
    /// `~/Projects/app/Tiltfile` apart from `~/Projects/app/docs/e2e.Tiltfile`.
    ///
    /// COPYING IS A CONTEXT-MENU ITEM, not click-to-copy. Two reasons: the
    /// sidebar's per-project menu already has an item called "Copy Tiltfile
    /// Path", so this is the same verb in the same place users have already
    /// learned it; and a static label that silently copies on an ordinary
    /// click has no affordance saying it will, so the one thing the user
    /// cannot tell is whether anything happened — the same invisible-outcome
    /// problem this codebase keeps fixing. A right-click menu names the
    /// action before performing it.
    @ViewBuilder
    private var tiltfilePathLine: some View {
        if let path = dashboard.selectedTiltfilePath {
            Text(path)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
                .accessibilityLabel("Tiltfile path: \(path)")
                .contextMenu {
                    Button("Copy Tiltfile Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
        }
    }

    private var instance: TiltInstance? { dashboard.selectedInstance }
    private var projectName: String { dashboard.selectedItem?.title ?? "this project" }

    private var canOpenBrowser: Bool { instance != nil }

    private var canActOnInstance: Bool {
        guard actionCoordinator.isAvailable, let instance else { return false }
        return !actionCoordinator.isInFlight(on: instance)
    }

    private var canTiltDown: Bool {
        guard actionCoordinator.isAvailable, let path = dashboard.selectedItem?.tiltfilePath else { return false }
        return !actionCoordinator.isTiltDownInFlight(tiltfilePath: path)
    }

    private var openTooltip: String {
        canOpenBrowser ? "Open tilt's web UI" : notRunningReason
    }

    private var reloadTooltip: String { instanceActionTooltip("Reload Tiltfile") }
    private var enableAllTooltip: String { instanceActionTooltip("Enable all resources") }
    private var disableAllTooltip: String { instanceActionTooltip("Disable all resources") }

    private func instanceActionTooltip(_ description: String) -> String {
        guard actionCoordinator.isAvailable else { return InstanceActionCoordinator.unavailableReason }
        guard let instance else { return notRunningReason }
        return actionCoordinator.isInFlight(on: instance)
            ? "An action is already running for this project."
            : description
    }

    private var notRunningReason: String { "This project is not running." }

    private var tiltDownTooltip: String {
        guard actionCoordinator.isAvailable else { return InstanceActionCoordinator.unavailableReason }
        guard let path = dashboard.selectedItem?.tiltfilePath else {
            return "Tilt Down needs a resolved Tiltfile path, which isn't known for this project yet."
        }
        return actionCoordinator.isTiltDownInFlight(tiltfilePath: path)
            ? "Tilt Down is already running for this project."
            : "Tilt Down — delete resources"
    }

    private func openInBrowser() {
        guard let instance else { return }
        NSWorkspace.shared.open(instance.webURL)
    }

    private func reloadTiltfile() {
        guard let instance else { return }
        Task { await actionCoordinator.reloadTiltfile(on: instance) }
    }

    private func enableAll() {
        guard let instance else { return }
        Task { await actionCoordinator.enableAll(on: instance) }
    }

    private func confirmAndDisableAll() {
        guard let instance else { return }
        guard presentConfirmation(.disableAll(projectName: projectName)) else { return }
        Task { await actionCoordinator.disableAll(on: instance) }
    }

    private func confirmAndTiltDown() {
        guard let path = dashboard.selectedItem?.tiltfilePath else { return }
        guard presentConfirmation(.tiltDown(projectName: projectName)) else { return }
        Task { await actionCoordinator.down(tiltfilePath: path) }
    }

    @ViewBuilder
    private func actionButton(systemImage: String, tooltip: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(tooltip)
    }
}

/// Shows `confirmation`'s copy in a modal `NSAlert` and returns whether the
/// user confirmed. Shared by `InstanceToolbarView` and `SidebarView`'s
/// context menu — the one place a destructive instance-level action's
/// confirmation is actually presented, so the two surfaces cannot show two
/// different dialogs for the same action.
///
/// `NSAlert.runModal()` rather than a SwiftUI `.confirmationDialog` because
/// the sidebar's call site is a context-menu action, not a currently-visible
/// piece of view state a SwiftUI modifier could bind to — `runModal()` works
/// synchronously regardless of which view triggered it.
@MainActor
func presentConfirmation(_ confirmation: InstanceActionConfirmation) -> Bool {
    let alert = NSAlert()
    alert.messageText = confirmation.title
    alert.informativeText = confirmation.message
    alert.alertStyle = .warning
    alert.addButton(withTitle: confirmation.confirmButtonTitle)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

/// Reports a failed action that has no `Error` behind it — a Relink whose
/// entry vanished, a Remove that found no row. Deliberately the same modal
/// `NSAlert` shape as `presentConfirmation` above and
/// `OpenTiltfileCommand`'s own failure alert, and for the same reason: the
/// call sites are context-menu actions with no currently-visible view state
/// for a SwiftUI `.alert` to bind to, so an alert that only fires when some
/// view happens to be mounted would be "reported sometimes", which is
/// indistinguishable from a silent no-op when it matters.
@MainActor
func presentFailure(title: String, message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
