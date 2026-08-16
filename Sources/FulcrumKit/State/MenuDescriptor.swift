import Foundation

/// The menu as data, built from an `AppModel` snapshot.
///
/// `NSMenu` cannot restructure gracefully while open, so the menu is always
/// rebuilt at `menuWillOpen` from a snapshot. Describing it as values first
/// keeps the display rules testable without AppKit.
public enum MenuDescriptor {
    public enum Item: Sendable, Equatable {
        /// Disabled informational row.
        case status(String)
        case separator
        /// `port` is carried explicitly so the renderer can route a click without
        /// re-parsing it out of `instanceName`, which is a display string.
        case failure(instanceName: String, port: Int, resourceName: String)
        /// `health` is `nil` when the instance's health has not been assessed yet —
        /// no resources have ever been listed, whether because the first `list()`
        /// hasn't returned or because it keeps failing. That state must render as
        /// "unknown", never fall back to a sentinel `.ok`; see `MenuBarController.dot(for:)`.
        ///
        /// `groups` carries this instance's resources pre-grouped, tilt's own
        /// order preserved within each, and ALL of them — disabled included.
        /// That makes it equal to `DashboardModel.visibleGroups` for the same
        /// instance with nothing typed in the search box and *Show disabled*
        /// on, i.e. the dashboard showing everything it has. See
        /// `instanceGroups(for:)` for why the menu does not track the
        /// dashboard's filter instead. Empty for an instance with no resources
        /// yet (still connecting, or a `list()` that keeps failing): the
        /// renderer must treat that as "no submenu", not an empty one.
        case instance(name: String, port: Int, summary: String, health: ResourceHealth?, groups: [ResourceGroup])
        /// One group's row inside an instance's submenu. `resources` is the
        /// group's full, uncapped list — `resourceItems(for:)` is what applies
        /// the display cap, kept separate so this case's `summary` always
        /// reflects the true total regardless of how many rows are shown.
        case group(name: String?, summary: ResourceSummary, resources: [Resource])
        /// One resource's row inside a group's submenu.
        case resource(name: String, health: ResourceHealth)
        case openDashboard
        /// Opens a file picker for a Tiltfile and starts it as a new tilt
        /// instance. Placed with the other app-level commands — see
        /// `MenuBarController` for why the status menu, not a File menu, is
        /// where this has to live.
        ///
        /// `disabledReason` is non-nil when this command cannot possibly
        /// succeed — tilt itself was not found, so there is no binary to
        /// launch a Tiltfile with. The row must still appear (see
        /// `MenuBarController.unbuilt` for why hiding beats nothing), just
        /// disabled with a tooltip explaining why, never left clickable onto
        /// a failure the user only discovers after clicking. `nil` means the
        /// command works normally.
        case openTiltfile(disabledReason: String?)
        case recent
        case settings
        case quit
    }

    /// Most failures shown inline before collapsing into a "N more…" row.
    static let failureLimit = 5

    /// Most resources shown in one group's submenu before collapsing into a
    /// trailing "…and N more" row. The measured real shape — 49 resources
    /// over 18 groups, largest at 8 — never approaches this; it exists to
    /// guard the pathological case of one group with hundreds of resources,
    /// which must never truncate silently.
    static let groupItemLimit = 50

    /// The same explanation `ResourceActionCoordinator.unavailableReason` /
    /// `InstanceActionCoordinator.unavailableReason` give their own disabled
    /// controls, copied rather than referenced: both of those are
    /// `@MainActor`-isolated types, and this constant is read from
    /// `startupHint(for:)`'s nonisolated default-value context. Kept as text
    /// identical to that shared string on purpose — every surface that turns
    /// itself off because tilt can't be found must read the same.
    static let tiltNotInstalledReason =
        "tilt was not found. Install it, or set FULCRUM_TILT_PATH, then relaunch Fulcrum."

    @MainActor
    public static func build(from model: AppModel) -> [Item] {
        var items: [Item] = [.status(model.statusLine)]
        items.append(contentsOf: startupHint(for: model))

        let failures = visibleFailures(in: model)
        if !failures.isEmpty {
            items.append(.separator)
            items.append(contentsOf: failures.prefix(failureLimit).map {
                .failure(instanceName: $0.instance.displayName(aliases: model.aliases),
                         port: $0.instance.instance.webPort,
                         resourceName: $0.resource.name)
            })
            let overflow = failures.count - failureLimit
            if overflow > 0 { items.append(.status("\(overflow) more…")) }
        }

        if !model.stores.isEmpty {
            items.append(.separator)
            items.append(contentsOf: model.stores.map { store in
                .instance(name: store.displayName(aliases: model.aliases),
                          port: store.instance.webPort,
                          summary: summary(for: store),
                          health: store.worstHealth,
                          groups: instanceGroups(for: store))
            })
        }

        items.append(contentsOf: [
            .separator, .openDashboard,
            .openTiltfile(disabledReason: model.tiltInstalled ? nil : tiltNotInstalledReason),
            .recent,
            .separator, .settings, .quit
        ])
        return items
    }

    /// The first-run explanation, shown only while nothing is running at
    /// all — once anything is running there is something to look at, and
    /// neither message applies (`aRunningInstanceSuppressesBothMessages`).
    ///
    /// "tilt not installed" and "tilt installed, nothing running" are
    /// deliberately distinct: they have different remedies, and telling an
    /// installed user to go install tilt is worse than saying nothing.
    @MainActor
    private static func startupHint(for model: AppModel) -> [Item] {
        guard model.stores.isEmpty else { return [] }
        return model.tiltInstalled
            ? [.status("Nothing running yet — use “Open Tiltfile…” below to start a project.")]
            : [.status("tilt isn't installed — get it from tilt.dev, then relaunch Fulcrum.")]
    }

    /// An instance's resources, grouped for its submenu: every resource it
    /// has, disabled ones included.
    ///
    /// The settled answer to "does the menu follow *Show disabled*?" is NO —
    /// the menu always reports the instance's true totals. It was built from a
    /// plain `ResourceFilter()` (which hides disabled resources), on the theory
    /// that matching the dashboard's default view kept the surfaces honest.
    /// It did the opposite: with *Show disabled* on, the status strip and the
    /// group headers counted 5 resources with 2 disabled while this menu
    /// counted 3 with 0 — three surfaces, two answers — and the `⊘` term
    /// `MenuBarController.groupSummaryText` renders for `summary.disabled` was
    /// dead code that could never fire.
    ///
    /// Following the filter instead was the other option and is worse:
    /// - The filter is per-window state on `DashboardModel`, not a setting.
    ///   The menu would change its numbers because of something the user did
    ///   in a window that may not even be open, with nothing in the menu to
    ///   explain it. The menu has no filter bar to say "3 of 5 shown".
    /// - It is not achievable in general anyway. The search query filters the
    ///   dashboard too, and a status menu cannot mirror a text box.
    ///
    /// So the menu describes the instance and the dashboard describes its own
    /// view of it, and `summary.disabled` (`⊘N`) is exactly the term that
    /// reconciles them: menu total − ⊘N is what the dashboard shows with
    /// *Show disabled* off. Nothing is hidden and nothing is miscounted —
    /// `ResourceSummary` keeps `disabled` out of `healthy`, so counting
    /// disabled resources here cannot restore the "a disabled resource is
    /// green and healthy" lie that field exists to prevent. It also makes
    /// disabled resources reachable from the menu at all: clicking one calls
    /// `DashboardModel.focus(resource:onInstanceWithPort:)`, which turns
    /// *Show disabled* on for exactly that reason.
    @MainActor
    private static func instanceGroups(for store: InstanceStore) -> [ResourceGroup] {
        ResourceGroup.group(store.resources)
    }

    /// Wraps one `ResourceGroup` as the `Item` an instance's submenu renders
    /// it with — the domain value carries everything the row and its own
    /// nested submenu need.
    public static func groupItem(for group: ResourceGroup) -> Item {
        .group(name: group.name, summary: group.summary, resources: group.resources)
    }

    /// The leaf rows for one group's submenu: `.resource` items in tilt's own
    /// order, capped at `groupItemLimit` with a trailing disabled overflow
    /// row rather than truncating silently.
    public static func resourceItems(for resources: [Resource]) -> [Item] {
        var items = resources.prefix(groupItemLimit).map { Item.resource(name: $0.name, health: $0.health) }
        let overflow = resources.count - groupItemLimit
        if overflow > 0 {
            items.append(.status("…and \(overflow) more — open the dashboard"))
        }
        return items
    }

    @MainActor
    private static func visibleFailures(in model: AppModel) -> [(instance: InstanceStore, resource: Resource)] {
        // `.always` and `.auto` deliberately share an arm: both show failures when
        // failures exist, and `allFailingResources` is empty when none do. They
        // diverge only once plan 2 adds an "all clear" row, which `.always` shows
        // and `.auto` omits. Do not "simplify" this into one case — the split is
        // load-bearing for that future behaviour.
        switch model.settings.failuresInMenu {
        case .never: []
        case .always, .auto: model.allFailingResources
        }
    }

    /// Threads the store's connection state into the summary text so a display
    /// failure can never read as a tilt failure. Without this, an instance whose
    /// `list()` fails every cycle sits at zero resources forever and renders a
    /// confident `"0 ok"` — the app reporting all-clear about an instance it has
    /// never once successfully contacted.
    @MainActor
    private static func summary(for store: InstanceStore) -> String {
        switch store.connection {
        case .connecting:
            return "connecting…"
        case .live:
            return healthSummary(for: store)
        case .degraded, .gone:
            // No resources yet means this cycle has never succeeded — say so
            // plainly rather than printing a bare, confident "0 ok".
            guard !store.resources.isEmpty else { return "reconnecting…" }
            return "\(healthSummary(for: store)) · reconnecting…"
        }
    }

    /// The instance row's own count, read off the same `ResourceSummary` its
    /// submenu's group headers are built from — `healthy`, not "how many rows
    /// are in there". A disabled resource is not being assessed at all, so it
    /// is neither failing nor ok: `ResourceSummary` counts it separately and
    /// this row simply does not claim it. That is what stops the row reading
    /// a confident "3 ok" over a submenu whose every resource is disabled,
    /// and it keeps this text equal to the sum of the ✓ terms below it.
    @MainActor
    private static func healthSummary(for store: InstanceStore) -> String {
        let failing = store.failingResources.count
        if failing > 0 { return "\(failing) failing" }
        return "\(ResourceSummary(resources: store.resources).healthy) ok"
    }
}

extension MenuDescriptor.Item {
    /// Whether this is an `.instance` row — a `where` clause over a `case`
    /// pattern can't be used as a `first(where:)` key path, so tests that
    /// need to pick the instance row out of a built menu use this instead.
    public var isInstance: Bool {
        if case .instance = self { true } else { false }
    }
}
