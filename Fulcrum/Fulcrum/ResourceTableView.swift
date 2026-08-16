import SwiftUI
import AppKit
import FulcrumKit

/// The resource table for the selected project: one collapsible `Section`
/// per `ResourceGroup`, matching tilt's own grouping.
///
/// A real instance measures 49 resources across 18 groups, lopsided (one
/// group of 8, several of 1) — headers are kept slim on purpose so a list of
/// that shape doesn't turn into 18 oversized banners with a handful of rows
/// each.
struct ResourceTableView: View {
    let dashboard: DashboardModel
    let actionCoordinator: ResourceActionCoordinator

    var body: some View {
        Group {
            // Gated on the FILTERED list, not `visibleResources`: a query that
            // matches nothing — or "Disable All", which hides every row under
            // the default filter — otherwise drew a `List` with no sections in
            // it, a blank pane with neither rows nor any explanation.
            if dashboard.visibleGroups.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(dashboard.visibleGroups, id: \.name) { group in
                            Section {
                                ForEach(group.resources) { resource in
                                    ResourceRow(
                                        resource: resource,
                                        instance: dashboard.selectedInstance,
                                        actionCoordinator: actionCoordinator,
                                        isFocused: resource.name == dashboard.selectedResourceName,
                                        select: { dashboard.selectResource(resource.name) }
                                    )
                                }
                            } header: {
                                GroupHeaderRow(
                                    group: group,
                                    // A group only appears here at all when it has at
                                    // least one resource (`ResourceGroup.group` never
                                    // emits an empty bucket), so an empty `resources`
                                    // unambiguously means "collapsed" rather than
                                    // "filtered down to nothing" — no separate lookup
                                    // against `dashboard.collapsedGroups` needed.
                                    isCollapsed: group.resources.isEmpty,
                                    toggle: { dashboard.toggleCollapse(group.name) }
                                )
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // `focus(resource:onInstanceWithPort:)` already guarantees the
                    // target is unhidden by the time this fires (filter cleared,
                    // group expanded, disabled revealed) — otherwise `scrollTo`
                    // would silently do nothing, a row's `id` matching no row
                    // currently in the list. `resource.id` is `resource.name`,
                    // the same identity `ForEach` above already keys rows by, so
                    // no separate id scheme is needed here.
                    .onChange(of: dashboard.selectedResourceName) { _, newValue in
                        guard let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                    .onAppear {
                        guard let selectedResourceName = dashboard.selectedResourceName else { return }
                        proxy.scrollTo(selectedResourceName, anchor: .center)
                    }
                }
            }
        }
        .background(Theme.surface)
        // A failed row action (trigger, enable/disable) surfaces here rather
        // than nowhere: a spinner that just stops with no explanation is the
        // specific silent-failure shape this project keeps getting bitten by.
        // `isPresented` derives from `lastFailure` rather than binding to it
        // directly — `lastFailure` is intentionally not externally settable,
        // so dismissal goes through `clearFailure()` instead.
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { actionCoordinator.lastFailure != nil },
                set: { isPresented in if !isPresented { actionCoordinator.clearFailure() } }
            )
        ) {
            Button("OK", role: .cancel) { actionCoordinator.clearFailure() }
        } message: {
            Text(actionCoordinator.lastFailure?.message ?? "")
        }
    }

    /// Copy comes from `DashboardModel.emptyState` rather than being decided
    /// here — which of the four empty cases applies is logic with edge cases
    /// worth testing, and this view is the untestable half.
    private var emptyState: some View {
        VStack(spacing: 6) {
            if let state = dashboard.emptyState {
                Text(state.title)
                    .foregroundStyle(Theme.textSecondary)
                if let detail = state.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One group's header: a disclosure chevron, its name, and its rollup counts.
/// The whole row toggles collapse, not just the chevron — a bigger hit target
/// for a control the user clicks constantly while scanning 18 groups.
private struct GroupHeaderRow: View {
    let group: ResourceGroup
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 10)

                Text(group.name ?? "Ungrouped")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                GroupCounts(summary: group.summary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .padding(.horizontal, 8)
        .background(Theme.chrome)
    }
}

/// A rollup's counts, `×2 ⚙2 ✓45/49` — tilt's own header shape. Error and
/// pending chips only appear when their count is non-zero (an all-healthy
/// group of 1, the common case among the four singleton groups, should not
/// show `×0 ⚙0`); the healthy/total chip always shows.
///
/// Reuses `StatusChip` for each chip's coloured square rather than inventing
/// a second indicator — the colour is the same semantic language the table
/// rows already use.
///
/// Not `private`: `StatusStripView` reuses this same rendering for the
/// selected instance's own header rather than duplicating the format.
struct GroupCounts: View {
    let summary: ResourceSummary

    var body: some View {
        HStack(spacing: 8) {
            if summary.error > 0 {
                chip(.error, count: "\(summary.error)", label: "\(summary.error) error\(summary.error == 1 ? "" : "s")")
            }
            if summary.pending > 0 {
                chip(.pending, count: "\(summary.pending)", label: "\(summary.pending) pending")
            }
            // Only shown when non-zero, same rule as error/pending — an
            // all-enabled group should not carry a permanent "0 disabled".
            // Disabled resources are excluded from `healthy`/`total` here
            // entirely (see `ResourceSummary`'s doc comment), so this chip is
            // the only place their count appears at all.
            if summary.disabled > 0 {
                chip(.disabled, count: "\(summary.disabled)", label: "\(summary.disabled) disabled")
            }
            chip(.ok, count: "\(summary.healthy)/\(summary.total)",
                 label: "\(summary.healthy) of \(summary.total) healthy")
        }
        .font(.caption2)
        .monospacedDigit()
    }

    private func chip(_ health: ResourceHealth, count: String, label: String) -> some View {
        HStack(spacing: 3) {
            StatusChip(health: health, label: label, size: 7)
            Text(count)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// One resource's row, laid out to match the columns the table used before
/// grouping: status, name, kind, last build, then a trigger button. A
/// right-click anywhere on the row opens the same actions as a context menu,
/// plus Copy Name and one "Open" item per endpoint.
private struct ResourceRow: View {
    let resource: Resource
    /// The selected project's live instance, needed to address `tilt trigger
    /// --port N`. nil only in the moment a project stops out from under an
    /// already-rendered row; every action becomes a no-op rather than a
    /// crash when that happens — see `disabledReason`.
    let instance: TiltInstance?
    let actionCoordinator: ResourceActionCoordinator
    /// Whether this is `DashboardModel.selectedResourceName` — set by
    /// `focus(resource:onInstanceWithPort:)` when the menu bar sends the
    /// user straight to a resource, or by clicking the row (`select`,
    /// below). Highlighted so landing here after a jump across 49 resources
    /// and 18 groups is not just a silent scroll.
    let isFocused: Bool
    /// Calls `DashboardModel.selectResource(resource.name)` — filters the
    /// log pane to just this resource's lines, clearable by clicking the
    /// same row again. A plain tap, not a `List(selection:)` binding: this
    /// table has no other use for row selection, and a binding would fight
    /// with the trigger button and context menu already living on the row.
    let select: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StatusChip(health: resource.health, label: resource.statusLabel)
                .frame(width: 16, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(resource.name)
                    .foregroundStyle(resource.isDisabled ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)

                // tilt renders this beneath a blocked resource's name so it's
                // obvious why nothing is happening, rather than leaving the
                // resource looking merely idle.
                if !resource.waitingOn.isEmpty {
                    Text("Waiting on \(resource.waitingOn.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(resource.kind.displayName)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 70, alignment: .leading)

            Text(resource.lastBuildText)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)

            UptimeCell(readySince: resource.readySince)

            triggerButton
        }
        .padding(.leading, 16)
        .padding(.vertical, 2)
        .background(isFocused ? Theme.focusHighlight : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        // A plain tap anywhere on the row selects it — buttons and the
        // context menu still get first refusal at their own taps, since
        // SwiftUI resolves control hit-testing before this gesture.
        .onTapGesture(perform: select)
        .contextMenu { contextMenuContent }
    }

    private var triggerButton: some View {
        Button {
            triggerAction()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(!canAct || actionCoordinator.isInFlight(resource.name))
        .help(disabledReason ?? "Trigger \(resource.name)")
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Trigger") { triggerAction() }
            .disabled(!canAct || actionCoordinator.isInFlight(resource.name))

        Button(resource.isDisabled ? "Enable" : "Disable") { setEnabledAction() }
            .disabled(!canAct || actionCoordinator.isInFlight(resource.name))

        if !resource.endpoints.isEmpty {
            Divider()
            ForEach(resource.endpoints, id: \.self) { url in
                Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
            }
        }

        Divider()
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(resource.name, forType: .string)
        }
    }

    /// Whether tilt was located and this row has an instance to target.
    /// Both must hold for any control here to do anything real.
    private var canAct: Bool { actionCoordinator.isAvailable && instance != nil }

    /// Non-nil whenever a control here would be disabled for a reason the
    /// user should be told about, for use as its tooltip — a disabled
    /// button with no explanation is the same silent-failure shape as one
    /// that quietly does nothing when clicked.
    private var disabledReason: String? {
        guard actionCoordinator.isAvailable else { return ResourceActionCoordinator.unavailableReason }
        guard instance != nil else { return "This project is no longer running." }
        if actionCoordinator.isInFlight(resource.name) { return "\(resource.name) is already running an action." }
        return nil
    }

    private func triggerAction() {
        guard let instance else { return }
        Task { await actionCoordinator.trigger(resource.name, on: instance) }
    }

    private func setEnabledAction() {
        guard let instance else { return }
        Task {
            await actionCoordinator.setEnabled(resource.isDisabled, resource: resource.name, on: instance)
        }
    }
}

/// The Uptime column's cell: `—` for a resource with nothing currently up,
/// otherwise a duration since `readySince` that ticks once a second.
///
/// The ticking is scoped to exactly this `Text` via `TimelineView`, not to
/// `ResourceRow` or `ResourceTableView` — `TimelineView` re-invokes only its
/// own content closure on each schedule fire, so the 1s tick here never
/// re-executes `ResourceRow.body` (let alone the table's 49 other rows). A
/// per-row `Timer`, or any `@State` "now" living above this cell, would
/// invalidate far more than this one `Text` needs.
private struct UptimeCell: View {
    let readySince: Date?

    var body: some View {
        Group {
            if let readySince {
                TimelineView(.periodic(from: readySince, by: 1)) { context in
                    Text(Uptime.format(context.date.timeIntervalSince(readySince)))
                }
            } else {
                Text("—")
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .monospacedDigit()
        .frame(width: 64, alignment: .trailing)
    }
}
