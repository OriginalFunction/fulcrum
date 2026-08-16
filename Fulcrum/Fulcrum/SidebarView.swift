import SwiftUI
import AppKit
import FulcrumKit

/// Projects, running ones first, then ones we have seen before.
///
/// Both section headers are always shown, even when empty, so they do not
/// appear and disappear as projects start and stop.
struct SidebarView: View {
    @Bindable var dashboard: DashboardModel
    /// Backs the context menu's Reload Tiltfile/Enable All/Disable All/Tilt
    /// Down items — the same `InstanceActionCoordinator` instance the
    /// dashboard's toolbar (`InstanceToolbarView`) drives, so an action's
    /// behaviour and its confirmation copy (`presentConfirmation(_:)`) can
    /// never drift between the two entry points.
    let instanceActionCoordinator: InstanceActionCoordinator
    /// Backs "Start" on a Recent row — the same `TiltLauncher` instance the
    /// status menu's Open Tiltfile command and the app menu's ⌘O use, so
    /// there is exactly one launch path. See `OpenTiltfileCommand`.
    let tiltLauncher: TiltLauncher

    /// The item currently being renamed, driving the rename sheet. `nil`
    /// when no sheet is showing.
    @State private var renameTarget: SidebarItem?

    var body: some View {
        List(selection: $dashboard.selectedSidebarID) {
            ForEach(dashboard.sections, id: \.section) { group in
                Section(group.section.title) {
                    if group.items.isEmpty {
                        Text(emptyText(for: group.section))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(group.items) { item in
                            row(item)
                                .tag(item.id)
                                .contextMenu { contextMenu(for: item) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $renameTarget) { item in
            RenameSheet(
                item: item,
                currentAlias: item.tiltfilePath.flatMap { dashboard.alias(forTiltfilePath: $0) },
                onSave: { newAlias in
                    guard let path = item.tiltfilePath else { return }
                    dashboard.setAlias(newAlias, forTiltfilePath: path)
                }
            )
        }
        // A failed context-menu action (Reload, Enable/Disable All, Tilt
        // Down) surfaces via the single `.alert` at `DashboardWindow`, the
        // ancestor common to this view and `InstanceToolbarView` — both
        // drive the same `instanceActionCoordinator`. See `DashboardWindow`'s
        // comment: binding a second `.alert` to the same `lastFailure` here
        // would double-present the same failure instead.
    }

    /// The status chip keeps its meaning (health, or "no signal" grey for a
    /// stopped project); the broken marker is an ADDITIONAL glyph rather than
    /// a replacement for it. Replacing the chip would make a broken running
    /// instance lose its health colour, and would leave the two facts — "not
    /// running" and "its Tiltfile is gone" — competing for one slot when they
    /// are independent and can both be true.
    ///
    /// Only `.broken` gets it. A `.unlinked` row (no path ever recorded)
    /// renders exactly like any other stopped row, because nothing is wrong
    /// with it — see `TiltfileLinkState`.
    private func row(_ item: SidebarItem) -> some View {
        HStack(spacing: 8) {
            StatusChip(health: item.health, label: item.statusLabel)
            Text(item.title)
                .foregroundStyle(item.isRunning ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if item.isBroken {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(Theme.broken)
                    // Never `?? ""`: an indicator whose tooltip is empty is a
                    // marker the user cannot interpret. `brokenReason` is
                    // non-nil for exactly the states this branch renders, and
                    // the fallback names the way out rather than going blank.
                    .help(item.brokenReason ?? "This project's Tiltfile is missing. Use Relink… to point it at the file's new location.")
                    .accessibilityLabel("Tiltfile missing")
            }
            Spacer()
        }
    }

    private func emptyText(for section: SidebarSection) -> String {
        switch section {
        case .running: "Nothing running"
        case .recent: "No history yet"
        }
    }

    /// Rename…, Open in Browser, Reveal Tiltfile in Finder, Copy Tiltfile
    /// Path, then the Task 13 instance actions, then Tilt Down — the order
    /// the spec calls for. Every item that needs a Tiltfile path or a live
    /// instance this row doesn't have is disabled with a tooltip explaining
    /// why, rather than omitted.
    @ViewBuilder
    private func contextMenu(for item: SidebarItem) -> some View {
        Button("Start") { restart(item) }
            .disabled(!item.canRestart)
            .help(item.restartUnavailableReason ?? "Start this project again")

        Button("Relink…") { relink(item) }
            .disabled(!item.canRelink)
            .help(item.relinkUnavailableReason ?? "Point this project at its Tiltfile's new location")

        Button("Remove from Recent") { removeFromRecent(item) }
            .disabled(!item.canRemoveFromRecent)
            .help(item.removeFromRecentUnavailableReason ?? "Forget this project")

        Divider()

        Button("Rename…") { renameTarget = item }
            .disabled(item.tiltfilePath == nil)
            .help(item.tiltfilePath == nil ? tiltfileUnknownReason : "")

        Button("Open in Browser") { openInBrowser(item) }
            .disabled(!item.isRunning)
            .help(item.isRunning ? "" : "This project is not running.")

        Button("Reveal Tiltfile in Finder") { revealInFinder(item) }
            .disabled(item.tiltfilePath == nil)
            .help(item.tiltfilePath == nil ? tiltfileUnknownReason : "")

        Button("Copy Tiltfile Path") { copyTiltfilePath(item) }
            .disabled(item.tiltfilePath == nil)
            .help(item.tiltfilePath == nil ? tiltfileUnknownReason : "")

        Divider()

        Button("Reload Tiltfile") { reloadTiltfile(item) }
            .disabled(!canActOnInstance(item))
            .help(instanceActionReason(item, description: "Reload Tiltfile"))
        Button("Enable All") { enableAll(item) }
            .disabled(!canActOnInstance(item))
            .help(instanceActionReason(item, description: "Enable all resources"))
        Button("Disable All") { confirmAndDisableAll(item) }
            .disabled(!canActOnInstance(item))
            .help(instanceActionReason(item, description: "Disable all resources"))

        Divider()

        Button("Tilt Down") { confirmAndTiltDown(item) }
            .disabled(!canTiltDown(item))
            .help(tiltDownReason(item))
    }

    private var tiltfileUnknownReason: String {
        "This project's Tiltfile path isn't known yet — it resolves shortly after tilt starts."
    }

    private func canActOnInstance(_ item: SidebarItem) -> Bool {
        guard instanceActionCoordinator.isAvailable, item.isRunning,
              let instance = dashboard.instance(forPort: item.port) else { return false }
        return !instanceActionCoordinator.isInFlight(on: instance)
    }

    /// Mirrors `InstanceToolbarView.instanceActionTooltip(_:)` — same three
    /// reasons a Reload/Enable All/Disable All item can be disabled (tilt not
    /// located, project not running, an action already in flight), same
    /// wording, so the tooltip reads identically no matter which of the two
    /// surfaces the user is looking at. A disabled item with no `.help` text
    /// is this project's recurring failure mode; this exists so these three
    /// items never regress into that.
    private func instanceActionReason(_ item: SidebarItem, description: String) -> String {
        guard instanceActionCoordinator.isAvailable else { return InstanceActionCoordinator.unavailableReason }
        guard item.isRunning, let instance = dashboard.instance(forPort: item.port) else {
            return "This project is not running."
        }
        return instanceActionCoordinator.isInFlight(on: instance)
            ? "An action is already running for this project."
            : description
    }

    private func canTiltDown(_ item: SidebarItem) -> Bool {
        guard instanceActionCoordinator.isAvailable, let path = item.tiltfilePath else { return false }
        return !instanceActionCoordinator.isTiltDownInFlight(tiltfilePath: path)
    }

    private func tiltDownReason(_ item: SidebarItem) -> String {
        guard instanceActionCoordinator.isAvailable else { return InstanceActionCoordinator.unavailableReason }
        guard item.tiltfilePath != nil else { return tiltfileUnknownReason }
        return canTiltDown(item) ? "Tilt Down — delete resources" : "Tilt Down is already running for this project."
    }

    private func openInBrowser(_ item: SidebarItem) {
        guard let instance = dashboard.instance(forPort: item.port) else { return }
        NSWorkspace.shared.open(instance.webURL)
    }

    private func revealInFinder(_ item: SidebarItem) {
        guard let path = item.tiltfilePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyTiltfilePath(_ item: SidebarItem) {
        guard let path = item.tiltfilePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func reloadTiltfile(_ item: SidebarItem) {
        guard let instance = dashboard.instance(forPort: item.port) else { return }
        Task { await instanceActionCoordinator.reloadTiltfile(on: instance) }
    }

    private func enableAll(_ item: SidebarItem) {
        guard let instance = dashboard.instance(forPort: item.port) else { return }
        Task { await instanceActionCoordinator.enableAll(on: instance) }
    }

    private func confirmAndDisableAll(_ item: SidebarItem) {
        guard let instance = dashboard.instance(forPort: item.port) else { return }
        guard presentConfirmation(.disableAll(projectName: item.title)) else { return }
        Task { await instanceActionCoordinator.disableAll(on: instance) }
    }

    private func confirmAndTiltDown(_ item: SidebarItem) {
        guard let path = item.tiltfilePath else { return }
        guard presentConfirmation(.tiltDown(projectName: item.title)) else { return }
        Task { await instanceActionCoordinator.down(tiltfilePath: path) }
    }

    /// Points a Recent entry at its Tiltfile's new location.
    ///
    /// Reuses `OpenTiltfileCommand.presentOpenPanel()` — the same panel ⌘O
    /// and the status menu show, with the same `Tiltfile`/`*.Tiltfile`
    /// filtering and the same remembered directory — rather than a second
    /// `NSOpenPanel` with its own rules, so "which files count as a Tiltfile"
    /// is answered in exactly one place.
    ///
    /// Every path out of here is visible. Cancelling changes nothing and says
    /// nothing (the user asked for nothing). Choosing a file either updates
    /// the entry or reports why it could not — a picker that takes a choice
    /// and quietly discards it is precisely the failure this project keeps
    /// reproducing.
    private func relink(_ item: SidebarItem) {
        guard let url = OpenTiltfileCommand.presentOpenPanel() else { return }
        let outcome = dashboard.relink(item: item, toTiltfilePath: url.path)
        if let message = outcome.failureMessage {
            presentFailure(title: "Couldn't Relink Project", message: message)
        }
    }

    /// Forgets a Recent entry, and says so if the row somehow survives. No
    /// confirmation: `RecentsStore` is a cache of convenience — a removed
    /// project comes straight back the next time Fulcrum sees it running —
    /// so a modal here would be friction guarding nothing.
    private func removeFromRecent(_ item: SidebarItem) {
        guard dashboard.removeFromRecent(item: item) else {
            presentFailure(
                title: "Couldn't Remove Project",
                message: "“\(item.title)” is no longer in the Recent list."
            )
            return
        }
    }

    /// Reuses `OpenTiltfileCommand.launch(tiltfilePath:using:)` — Task 3's
    /// launch path and its `TiltLaunchError` alert — rather than a second
    /// call into `TiltLauncher` with its own failure handling.
    private func restart(_ item: SidebarItem) {
        guard let path = item.tiltfilePath else { return }
        Task { await OpenTiltfileCommand.launch(tiltfilePath: path, using: tiltLauncher) }
    }
}

/// A small sheet prefilled with the project's current name (its alias, if
/// one is set, else its resolved/fallback display name) — submitting an
/// empty (or all-whitespace) name clears the alias rather than setting a
/// blank one, matching `InstanceAliases.setAlias`'s own guarantee.
private struct RenameSheet: View {
    let item: SidebarItem
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(item: SidebarItem, currentAlias: String?, onSave: @escaping (String?) -> Void) {
        self.item = item
        self.onSave = onSave
        _text = State(initialValue: currentAlias ?? item.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Project")
                .font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
        dismiss()
    }
}
