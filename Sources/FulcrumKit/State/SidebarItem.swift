import Foundation

public enum SidebarSection: Sendable, Hashable {
    case running
    case recent

    public var title: String {
        switch self {
        case .running: "Running"
        case .recent: "Recent"
        }
    }
}

/// One row of the dashboard sidebar.
public struct SidebarItem: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let port: Int
    /// Worst health across the instance's resources, or nil when the project
    /// is not running — a stopped project has no health, which is different
    /// from being healthy.
    public let health: ResourceHealth?
    public let isRunning: Bool
    /// This project's Tiltfile path, when resolved — `nil` for a project
    /// whose `tiltfileKey` hasn't (or never) resolved. Renaming, "Tilt
    /// Down", "Reveal Tiltfile in Finder", and "Copy Tiltfile Path" all need
    /// this and are disabled with an explanatory tooltip when it is nil,
    /// rather than hidden.
    public let tiltfilePath: String?

    /// Whether this row's Tiltfile is still where Fulcrum recorded it.
    ///
    /// Carried as domain state rather than left for the view to infer from
    /// `restartUnavailableReason`'s wording: `.unlinked` and `.broken` both
    /// disable "Start", but only one of them means something is *wrong*, and
    /// a view distinguishing them by string-matching a sentence would break
    /// the moment that sentence is reworded. `restartUnavailableReason` is
    /// derived FROM this below, so the indicator and the tooltip can never
    /// disagree about which case a row is in.
    public let linkState: TiltfileLinkState

    /// Whether to show this row's broken indicator. `false` for `.unlinked` —
    /// see `TiltfileLinkState`.
    public var isBroken: Bool { linkState.isBroken }

    /// The broken indicator's tooltip, `nil` when there is no indicator.
    public var brokenReason: String? { linkState.brokenReason }

    /// Why this row's "Start" context-menu item is disabled, or `nil` if it
    /// isn't — see `canRestart`. Three distinct causes, each named rather
    /// than collapsed into one generic "can't restart" string: the project
    /// is already running, its Tiltfile path predates `tiltfilePath` being
    /// tracked at all, or the Tiltfile has since moved or been deleted. A
    /// disabled control with no explanation, or one explanation covering two
    /// different causes, is this project's recurring failure mode.
    public var restartUnavailableReason: String? {
        if isRunning { return "This project is already running." }
        switch linkState {
        case .linked: return nil
        case .unlinked: return Self.unlinkedReason
        case .broken: return linkState.brokenReason
        }
    }

    /// Shown wherever a row's missing Tiltfile path blocks something. Says
    /// nothing is wrong with the project — because nothing is — and names
    /// the way out, which is Relink.
    public static let unlinkedReason =
        "This project's Tiltfile path isn't known — it was last seen before Fulcrum started tracking it. Use Relink… to point it at the Tiltfile."

    /// Whether "Start" (restart a stopped project's `tilt up`) is available
    /// for this row. `false` for anything currently running — restarting a
    /// live instance is not this action's job — and for a stopped project
    /// whose Tiltfile path is unknown or no longer exists on disk.
    public var canRestart: Bool { restartUnavailableReason == nil }

    /// Whether "Relink…" applies to this row, and why not when it doesn't.
    ///
    /// Only a Recent row has a stored `RecentProject` whose path Relink can
    /// rewrite. A running instance's path comes from its live apiserver, so
    /// there would be nothing for a relink to write to — offering it there
    /// would be a control that picks a file and does nothing.
    ///
    /// Note this is available for a `.linked` Recent row too, not just a
    /// broken one: pointing an entry at a Tiltfile that moved to a location
    /// where a *different* file happens to sit is a legitimate correction,
    /// and hiding the item until something breaks makes it undiscoverable.
    public var relinkUnavailableReason: String? {
        isRunning ? "This project is running — its Tiltfile path comes from the running instance." : nil
    }

    public var canRelink: Bool { relinkUnavailableReason == nil }

    /// Whether "Remove from Recent" applies, and why not when it doesn't. A
    /// running project is not in the Recent list to be removed from.
    public var removeFromRecentUnavailableReason: String? {
        isRunning ? "This project is running — it isn't in the Recent list." : nil
    }

    public var canRemoveFromRecent: Bool { removeFromRecentUnavailableReason == nil }

    /// What this item's status chip means, in words.
    ///
    /// Lives here rather than in the view because it is a total mapping over
    /// domain state producing user-facing text — logic, and testable. A running
    /// project with no health yet is *connecting*, not *not running*: the spec's
    /// rule is that a display failure must never look like a tilt failure.
    public var statusLabel: String {
        guard let health else {
            return isRunning ? "connecting" : "not running"
        }
        return health.label
    }
}

extension SidebarItem {
    /// Merges live instances and remembered projects into the sidebar's two
    /// sections. Sections are always both present, even when empty, so the
    /// headers do not appear and disappear as projects come and go.
    /// - Parameter fileExists: whether a project's Tiltfile still exists on
    ///   disk, which decides `.linked` from `.broken` (see
    ///   `TiltfileLinkState`) and so drives both the broken indicator and
    ///   "Start"'s disabled tooltip.
    ///
    ///   The default is `{ _ in true }` — "assume present" — and NOT a real
    ///   `FileManager.fileExists`, which is what it used to be. This method
    ///   is `@MainActor` and is re-run by `DashboardModel.sections` on every
    ///   SwiftUI body evaluation; a real `stat` here is a blocking syscall
    ///   per project per rebuild, and one entry on a stalled network mount
    ///   would hang the whole UI. Now that the result drives a *visible*
    ///   indicator rather than only a context-menu item's enablement, that
    ///   path is hit constantly. Production passes
    ///   `TiltfileExistenceCache.exists(atPath:)`, which answers from memory
    ///   and refreshes off the main actor; see `DashboardModel.init`.
    ///
    ///   The default is deliberately optimistic rather than pessimistic: an
    ///   absent answer must render a row as ordinary, never as broken. A
    ///   default of `false` would paint every row with a red fault indicator
    ///   the instant a caller forgot to pass anything.
    @MainActor
    public static func build(
        model: AppModel,
        recents: RecentsStore,
        fileExists: (String) -> Bool = { _ in true }
    ) -> [(section: SidebarSection, items: [SidebarItem])] {
        let running = model.stores.map { store in
            SidebarItem(
                id: "port-\(store.instance.webPort)",
                title: store.displayName(aliases: model.aliases),
                port: store.instance.webPort,
                health: store.worstHealth,
                isRunning: true,
                tiltfilePath: store.tiltfilePath,
                linkState: .resolve(tiltfilePath: store.tiltfilePath, fileExists: fileExists)
            )
        }

        // A running project is excluded from Recent so it cannot appear twice.
        let runningPorts = Set(running.map(\.port))
        let recent = recents.projects
            .filter { !runningPorts.contains($0.lastPort) }
            .map { project in
                SidebarItem(
                    id: project.id,
                    // Same `InstanceAliases.displayName(forTiltfilePath:fallback:)`
                    // precedence a running instance uses (see
                    // `InstanceStore.displayName(aliases:)`), just sourced from
                    // `RecentProject` (`displayName` already carries the
                    // resolved name, or the port fallback, captured while it
                    // was last running — see `RecentsStore.updateResolvedName`)
                    // instead of a live `InstanceStore`.
                    title: model.aliases.displayName(forTiltfilePath: project.tiltfilePath, fallback: project.displayName),
                    port: project.lastPort,
                    health: nil,
                    isRunning: false,
                    tiltfilePath: project.tiltfilePath,
                    linkState: .resolve(tiltfilePath: project.tiltfilePath, fileExists: fileExists)
                )
            }

        return [(.running, running), (.recent, recent)]
    }
}
