import Foundation
import Observation

/// Selection and derived content for the dashboard window.
///
/// Holds no data of its own — it reads `AppModel` and `RecentsStore` and derives
/// what the window shows, so there is exactly one source of truth for instance
/// state and the window cannot drift from the menu bar.
@Observable
@MainActor
public final class DashboardModel {
    private let appModel: AppModel
    private let recents: RecentsStore

    /// The user's explicit choice, which may name a project that has since
    /// disappeared. Read through `selectedSidebarID`, never directly.
    private var explicitSelectionID: String?

    /// The log pane's live state for whichever instance is currently
    /// selected.
    ///
    /// `DashboardModel` keeps this pointed at `selectedInstance` itself —
    /// see `followSelectedInstanceLogs()` — for every way that selection can
    /// change *within this object*: an explicit sidebar pick
    /// (`selectedSidebarID`'s setter, below). What it cannot react to on its
    /// own is `AppModel.stores` changing out from under it — an
    /// `@Observable` class has no hook that fires when *another* object's
    /// property changes, only a view's `body` re-evaluating does — which is
    /// why `AppDelegate.reconcile(with:)` also calls
    /// `followSelectedInstanceLogs()` right after `AppModel.sync(with:)`,
    /// and why `LogPaneView` additionally calls
    /// `logPane.follow(dashboard.selectedInstance)` itself on
    /// `onChange(of: dashboard.selectedInstance?.id, initial: true)` as a
    /// safety net for that same external-change case while the window is
    /// open. `follow(_:)` is a no-op when the instance hasn't actually
    /// changed, so all of these paths calling it is safe.
    ///
    /// What that `initial: true` is NOT is "the pane's activation whenever
    /// the dashboard window opens" — it fires once per hosted view, and a
    /// reopened window reuses the one it already had. Activation belongs to
    /// `dashboardWindowDidBecomeVisible()`, which `DashboardWindowController.show()`
    /// calls on every open; see that method for the blank-pane bug that came
    /// from believing otherwise.
    public let logPane: LogPaneModel

    /// Answers "is this Tiltfile still there?" for the sidebar without a
    /// blocking `stat` on the main actor. See `TiltfileExistenceCache`.
    public let tiltfileExistence: TiltfileExistenceCache

    public init(
        appModel: AppModel,
        recents: RecentsStore,
        logStreaming: any LogStreaming = LogStreamer(),
        tiltfileExistence: TiltfileExistenceCache = TiltfileExistenceCache()
    ) {
        self.appModel = appModel
        self.recents = recents
        self.logPane = LogPaneModel(streaming: logStreaming)
        self.tiltfileExistence = tiltfileExistence
    }

    /// Re-derived on every read, which for a SwiftUI body means many times
    /// per render — which is exactly why the existence check it passes down
    /// is a memory lookup (`TiltfileExistenceCache.exists(atPath:)`) rather
    /// than a filesystem call. The cache is `@Observable`, so a refreshed
    /// answer landing from the background re-evaluates the body that read it
    /// and the indicator appears on its own; nothing has to poll.
    public var sections: [(section: SidebarSection, items: [SidebarItem])] {
        SidebarItem.build(
            model: appModel,
            recents: recents,
            fileExists: { [tiltfileExistence] in tiltfileExistence.exists(atPath: $0) }
        )
    }

    /// The outcome of a Relink, so the caller can tell "done" from "nothing
    /// happened" and alert on the latter. A Relink that picks a file and
    /// silently changes nothing is the failure mode this type exists to make
    /// unrepresentable — there is no case here that means "maybe".
    public enum RelinkOutcome: Equatable, Sendable {
        case relinked
        /// The row is a running instance, whose path comes from its live
        /// apiserver and has no stored entry to rewrite.
        case notARecentEntry
        /// The entry vanished between the row being drawn and the panel
        /// being dismissed — the list is live, and the panel is modal for as
        /// long as the user takes to pick a file.
        case entryNoLongerExists

        public var didChangeAnything: Bool { self == .relinked }

        /// Why nothing happened, for the alert. `nil` on success.
        public var failureMessage: String? {
            switch self {
            case .relinked: nil
            case .notARecentEntry: "Only a stopped project in the Recent list can be relinked."
            case .entryNoLongerExists: "This project is no longer in the Recent list, so its Tiltfile path could not be updated."
            }
        }
    }

    /// Points `item`'s remembered entry at `tiltfilePath`, carrying any
    /// rename across with it.
    ///
    /// The alias move is not incidental. `InstanceAliases` is keyed on the
    /// Tiltfile path — the only identifier stable across a restart — so
    /// rewriting the path without moving the alias would orphan it: the
    /// project silently reverts to its resolved or `tilt-<port>` name and the
    /// user's rename appears to have been thrown away by an unrelated action.
    public func relink(item: SidebarItem, toTiltfilePath tiltfilePath: String) -> RelinkOutcome {
        guard item.canRelink else { return .notARecentEntry }
        let previousPath = item.tiltfilePath
        guard recents.relink(id: item.id, toTiltfilePath: tiltfilePath) else { return .entryNoLongerExists }

        if let previousPath, previousPath != tiltfilePath,
           let alias = appModel.aliases.alias(forTiltfilePath: previousPath) {
            appModel.aliases.setAlias(alias, forTiltfilePath: tiltfilePath)
            appModel.aliases.setAlias(nil, forTiltfilePath: previousPath)
        }
        // The new path has never been probed, and the old one's cached answer
        // is now attached to a path this entry no longer uses.
        tiltfileExistence.invalidate(tiltfilePath)
        return .relinked
    }

    /// Forgets `item`'s remembered entry, reporting whether the row actually
    /// went away. `false` means the caller must say so — a "Remove from
    /// Recent" that leaves the row is the same silent no-op as a Relink that
    /// changes nothing.
    public func removeFromRecent(item: SidebarItem) -> Bool {
        guard item.canRemoveFromRecent else { return false }
        return recents.remove(id: item.id)
    }

    /// The selected project's Tiltfile path for the instance header, or `nil`
    /// when there is nothing truthful to show.
    ///
    /// `nil` — not `""`, and not a placeholder like "Unknown path" — for both
    /// "nothing selected" and "this project has no recorded path", so the
    /// header can render nothing at all rather than an empty gap or a line
    /// that looks like a path but names no file. One source for both a
    /// running instance (resolved from its `tiltfileKey`) and a stopped one
    /// (`RecentProject.tiltfilePath`), because `SidebarItem.build` has
    /// already made that choice; deriving it a second time here is how the
    /// header and the sidebar would come to disagree.
    public var selectedTiltfilePath: String? {
        selectedItem?.tiltfilePath
    }

    private var allItems: [SidebarItem] {
        sections.flatMap(\.items)
    }

    /// The selection, resolved against what currently exists.
    ///
    /// Reading returns the id actually being shown, so a `List(selection:)`
    /// binding highlights the same project the detail pane is displaying —
    /// including after a fallback. Writing records an explicit choice.
    ///
    /// Without this, a project disappearing leaves the stored id naming
    /// something gone: the content falls back but the sidebar highlights
    /// nothing, which looks broken rather than graceful.
    public var selectedSidebarID: String? {
        get { selectedItem?.id }
        set {
            guard newValue != explicitSelectionID else { return }
            explicitSelectionID = newValue
            // A resource focus (and the log filter it drives, see
            // `setSelectedResource(_:)`) is scoped to the instance it was
            // set on — carrying it over to a different instance's
            // differently-named resources would silently filter the new
            // pane down to whatever, usually nothing, happens to share that
            // name. Cleared explicitly here rather than left to
            // `followSelectedInstanceLogs()`'s own change-detection below:
            // that detection only runs once the pane has started following
            // something at least once, so an explicit pick made before the
            // dashboard window has ever been opened needs its own clear —
            // otherwise a scope set on one instance could still be sitting
            // there, unnoticed, the first time the pane ever starts
            // streaming a different one.
            setSelectedResource(nil)
            followSelectedInstanceLogs()
        }
    }

    /// Keeps the log pane pointed at whichever instance is currently
    /// selected — see `logPane`'s own doc comment for the three places this
    /// gets called and why none of them can cover the whole story alone.
    /// A no-op until the pane has been asked to follow something at least
    /// once (`LogPaneModel.isFollowingAnInstance`), which is what keeps this
    /// from starting a stream on its own the first time. Starting one is
    /// `dashboardWindowDidBecomeVisible()`'s job exclusively — this method
    /// only KEEPS an already-running pane pointed at the right instance.
    ///
    /// Also the single place a *change* of followed instance clears the
    /// resource scope (via `setSelectedResource(_:)`) — deliberately here
    /// rather than at each call site. `selectedSidebarID`'s setter clearing
    /// on its own was not enough: `AppDelegate.reconcile(with:)` re-points
    /// the pane through this method directly, after a fallback selection
    /// picked up by `AppModel.sync(with:)`, without ever touching the
    /// setter — the scope survived that path and stuck the pane on a
    /// resource name the newly-followed instance has no lines for. Doing
    /// the comparison here instead means every current and future caller of
    /// this method gets the clearing behaviour for free, rather than each
    /// one needing to remember its own.
    ///
    /// Compares against what the pane is *actually* streaming
    /// (`LogPaneModel.currentlyFollowedInstanceID`), not against whatever
    /// this object last resolved on its own — a routine reconcile that
    /// resolves back to the exact same instance must leave a user's scope
    /// alone, and only the pane's own record of what it's streaming can
    /// tell "genuinely changed" apart from "re-resolved to the same thing".
    public func followSelectedInstanceLogs() {
        guard logPane.isFollowingAnInstance else { return }
        pointLogPaneAtSelection()
    }

    /// The dashboard window has become visible — point the pane at the
    /// selection and START the stream, from a standing stop if necessary.
    /// `DashboardWindowController.show()`'s call, and the ONLY caller allowed
    /// to skip `followSelectedInstanceLogs()`'s "has the pane ever been
    /// started" guard: a window actually being on screen is precisely the
    /// condition that guard is a proxy for.
    ///
    /// It exists because the guarded method cannot serve this path, which is
    /// the bug it was added to fix. Closing the window calls
    /// `logPane.follow(nil)` (`windowWillClose`), which clears
    /// `isFollowingAnInstance` — so on the NEXT `show()`,
    /// `followSelectedInstanceLogs()` early-returned and started nothing.
    /// Nothing else covered for it either: `window.isReleasedWhenClosed` is
    /// `false`, so reopening reuses the same `NSHostingController` and the
    /// same hosted view, and `LogPaneView`'s `onChange(..., initial: true)`
    /// — the pane's other activation path — does not fire a second time.
    /// Instrumenting a Release build proved it: after close → reopen, no
    /// `onAppear`, no `onChange`, no `body` re-evaluation, no `tilt logs`
    /// child, and a pane reading `rows=0 lines=0 following=nil` under its
    /// header row. The window's second open reached NOTHING that could start
    /// a stream, which is the user-visible "the logs don't always appear":
    /// always, from the second open of the window until the selection next
    /// changed.
    ///
    /// Note what this deliberately does NOT do: start a stream on selection
    /// changes or discovery ticks. Those keep going through
    /// `followSelectedInstanceLogs()`, so picking a project in the sidebar
    /// before the window has ever been opened still spawns nothing (see
    /// `selectingAnInstanceDoesNotStartAStreamBeforeThePaneHasEverFollowedOne`).
    public func dashboardWindowDidBecomeVisible() {
        pointLogPaneAtSelection()
    }

    /// The shared body of the two entry points above: clear a resource scope
    /// that belonged to a different instance, then re-point the pane. Only
    /// the guard differs between them, deliberately — the scope-clearing rule
    /// documented on `followSelectedInstanceLogs()` must hold on every path
    /// that changes which instance is followed, this one included.
    private func pointLogPaneAtSelection() {
        if logPane.currentlyFollowedInstanceID != selectedInstance?.id {
            setSelectedResource(nil)
        }
        logPane.follow(selectedInstance)
    }

    /// Resolves the selection, falling back to the first available item when the
    /// selected project has gone away — a window showing a blank pane because
    /// its selection evaporated is worse than one that moves on.
    public var selectedItem: SidebarItem? {
        let items = allItems
        if let explicitSelectionID,
           let match = items.first(where: { $0.id == explicitSelectionID }) {
            return match
        }
        return items.first
    }

    /// The store backing the current selection, or nil when nothing is
    /// selected or the selected project is not running. The shared lookup
    /// behind both `visibleResources` and `selectedInstance` — keeping it in
    /// one place means those two can never disagree about which instance is
    /// selected.
    private var selectedStore: InstanceStore? {
        guard let selected = selectedItem, selected.isRunning else { return nil }
        return appModel.stores.first(where: { $0.instance.webPort == selected.port })
    }

    public var visibleResources: [Resource] {
        selectedStore?.resources ?? []
    }

    /// The selected instance's resources as a name → health lookup, for the
    /// log pane's per-line border colour. Computed fresh from
    /// `visibleResources` on every access — deliberately not cached anywhere
    /// (an earlier version snapshotted this into `LogPaneModel`, refreshed
    /// only from `followSelectedInstanceLogs()`; a resource's health
    /// changing between reconciles — the exact moment this feature exists to
    /// catch — left that snapshot stale). `InstanceStore.resources` is
    /// `@Observable`, so reading this from a SwiftUI view body subscribes
    /// the view to every watch-driven change with no refresh call needed.
    ///
    /// Callers looking up many names in one pass (`LogPaneView`, up to the
    /// pane's ~5,000-line capacity) should read this ONCE per render and
    /// look up from the result via `health(forResourceNamed:in:)`, not call
    /// this once per line — it repeats the `reduce` below on every access.
    ///
    public var resourceHealthByName: [String: ResourceHealth] {
        Self.healthMap(from: visibleResources)
    }

    /// The `reduce(into:)` behind `resourceHealthByName`, factored out so it
    /// can be exercised directly against a hand-built, deliberately
    /// duplicate-containing list — `InstanceStore.byName` already keys
    /// resources by name, so `visibleResources` cannot itself contain a
    /// duplicate today, and a test going through `resourceHealthByName`
    /// alone could never prove this line does the defensive thing rather
    /// than merely never being asked to.
    ///
    /// `reduce(into:)`, never `Dictionary(uniqueKeysWithValues:)` — tilt can
    /// emit duplicate resource names across instances, and the unique-keys
    /// initializer traps on a duplicate instead of picking one.
    nonisolated static func healthMap(from resources: [Resource]) -> [String: ResourceHealth] {
        resources.reduce(into: [:]) { map, resource in
            map[resource.name] = resource.health
        }
    }

    /// The health to tint a log line's left-edge border with, or `nil` for
    /// no colour — never a default of `.ok`, which would falsely read as
    /// healthy. Pure and static: it does no lookup of its own state, only
    /// the guard and subscript against whatever map is passed in — see
    /// `resourceHealthByName`'s doc comment for why callers build that map
    /// once and pass it here rather than each call re-deriving it.
    ///
    /// `nil` for `resourceName == ""` — a tilt-level message, which belongs
    /// to no resource — regardless of what `map` contains; and `nil` for a
    /// name not currently in `map` (evicted, renamed, or a line that arrived
    /// before the resource list did).
    public nonisolated static func health(forResourceNamed resourceName: String, in map: [String: ResourceHealth]) -> ResourceHealth? {
        guard !resourceName.isEmpty else { return nil }
        return map[resourceName]
    }

    /// The live `TiltInstance` behind the current selection, or nil when
    /// nothing is selected or the selected project is not running. Row
    /// actions (trigger, enable/disable) need this to address `TiltActions`
    /// at the right instance's port — `Resource` itself carries no instance
    /// reference, since one `Resource` value has no way to know which
    /// instance it came from once it's out of `InstanceStore`.
    public var selectedInstance: TiltInstance? {
        selectedStore?.instance
    }

    /// The live `TiltInstance` running on `port`, or nil when no instance is
    /// currently running there. Used by the sidebar's per-project context
    /// menu, which — unlike the detail pane — can act on a row that is not
    /// the current selection.
    public func instance(forPort port: Int) -> TiltInstance? {
        appModel.stores.first(where: { $0.instance.webPort == port })?.instance
    }

    /// The alias currently set for `path`, if any — used to prefill the
    /// rename sheet with the name actually in effect, not the resolved
    /// project name underneath it.
    public func alias(forTiltfilePath path: String) -> String? {
        appModel.aliases.alias(forTiltfilePath: path)
    }

    /// Sets or clears (`nil`, or trimmed-empty — see `InstanceAliases.setAlias`)
    /// the alias for `path`. Routed through here rather than exposing
    /// `appModel.aliases` directly, so the sidebar depends only on
    /// `DashboardModel`, the same boundary every other dashboard surface
    /// already respects.
    public func setAlias(_ alias: String?, forTiltfilePath path: String) {
        appModel.aliases.setAlias(alias, forTiltfilePath: path)
    }

    /// The dashboard's active resource filter (name search, disabled
    /// visibility, alerts-on-top ordering).
    ///
    /// Computed, not stored: `alertsOnTop` and `showDisabled` are assembled
    /// live from `SettingsStore.alertsOnTop` / `.showDisabled` on every read
    /// and split straight back to them on every write — `SettingsStore` is
    /// the single source of truth for those two, the same object every other
    /// persisted preference in this app lives on. There is deliberately no
    /// separate `DashboardModel`-side copy to keep in step; a filter bar
    /// binding (`$dashboard.filter.showDisabled`) that read from one and
    /// wrote to the other is exactly the shape that produced this project's
    /// display-name precedence bug and its menu-versus-dashboard count
    /// divergence. `query` is the one field with no `SettingsStore` backing
    /// at all — see `filterQuery`'s doc comment for why it must not persist.
    public var filter: ResourceFilter {
        get {
            ResourceFilter(
                query: filterQuery,
                alertsOnTop: appModel.settings.alertsOnTop,
                showDisabled: appModel.settings.showDisabled
            )
        }
        set {
            filterQuery = newValue.query
            appModel.settings.alertsOnTop = newValue.alertsOnTop
            appModel.settings.showDisabled = newValue.showDisabled
        }
    }

    /// The filter bar's name search — session-only, unlike the two booleans
    /// `filter` otherwise persists through `SettingsStore`. Restoring a query
    /// from a previous launch would open the dashboard on a table already
    /// filtered down to something, with no visible reason why; an empty
    /// search box that doesn't match what's on screen is a worse first
    /// impression than one relaunch losing what was typed.
    private var filterQuery = ""

    /// The resource the user most recently asked to be taken to — set by
    /// `focus(resource:onInstanceWithPort:)` or `selectResource(_:)` — for
    /// the table to scroll to or highlight, and for `logPane.filter.resource`
    /// to filter down to (kept in step by `setSelectedResource(_:)`, the one
    /// place either of those setters is written). `nil` when nothing has
    /// been focused this session, or when the selection has been cleared.
    public private(set) var selectedResourceName: String?

    /// The single place `selectedResourceName` is ever assigned — keeps
    /// `logPane.filter.resource` in step with it so there is exactly one
    /// "which resource is picked" concept, not a table-side one and a
    /// log-pane-side one that can drift apart (that duplication was a
    /// review finding on the previous plan). `logPane.filter.resource == ""`
    /// (tilt-level messages) is intentionally unreachable from here — see
    /// `LogFilter.resource`'s own doc comment on what `nil` versus `""`
    /// means; a picked *resource* always has a real name.
    private func setSelectedResource(_ name: String?) {
        selectedResourceName = name
        logPane.filter.resource = name
    }

    /// Selects `name` as the log pane's resource filter and the table's
    /// highlight target. Selecting the resource that is already selected
    /// clears it instead — back to every resource's logs — which is the
    /// pane's only "clearable back to all" affordance for this filter.
    public func selectResource(_ name: String) {
        setSelectedResource(selectedResourceName == name ? nil : name)
    }

    /// Clears the resource focus — back to every resource's logs, including
    /// tilt-level ones, and the table's highlight removed. The log pane's
    /// "Show all resources" control (shown only while `selectedResourceName`
    /// is set) routes through this rather than writing
    /// `logPane.filter.resource` directly, which would desynchronise the
    /// table's highlight from the log scope.
    public func clearSelectedResource() {
        setSelectedResource(nil)
    }

    /// Selects `port`'s instance and brings `resourceName` into view: clears
    /// any active filter that would hide it, expands its group if collapsed,
    /// and reveals it if `showDisabled` currently has it hidden. Used by the
    /// menu bar to jump straight to a failing (or, from a group submenu, any)
    /// resource — without all three, focusing a resource one of them
    /// currently hides would open the dashboard onto a row that isn't there.
    /// Also points the log pane at that resource, same as clicking its row
    /// in the table would (`selectResource(_:)`) — but always selects rather
    /// than toggling, since a menu-bar jump should land on the target even
    /// if it happened to already be selected.
    public func focus(resource resourceName: String, onInstanceWithPort port: Int) {
        selectedSidebarID = "port-\(port)"
        filter.query = ""
        if let store = appModel.stores.first(where: { $0.instance.webPort == port }),
           let resource = store.resources.first(where: { $0.name == resourceName }) {
            collapsedGroups.remove(Self.collapseKey(for: resource.group))
            if resource.isDisabled { filter.showDisabled = true }
        }
        setSelectedResource(resourceName)
    }

    /// Which groups are collapsed, keyed by group name (see `collapseKey(for:)`
    /// for how the ungrouped `nil` bucket is represented as a `String`).
    ///
    /// Deliberately independent of `visibleGroups`: tilt pushes a watch event
    /// every few seconds, and `visibleGroups` re-derives fresh `ResourceGroup`
    /// values from the current resource list on every read — nothing about
    /// those values persists between reads. Storing collapse state here,
    /// keyed on the stable group name rather than on an index or on one of
    /// those transient `ResourceGroup` values, is what lets a collapse
    /// survive a refresh instead of silently re-expanding under the user.
    public private(set) var collapsedGroups: Set<String> = []

    /// Toggles whether `groupName`'s rows are hidden. `nil` names the
    /// ungrouped bucket (tilt's `(Tiltfile)`-only case).
    public func toggleCollapse(_ groupName: String?) {
        let key = Self.collapseKey(for: groupName)
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
        } else {
            collapsedGroups.insert(key)
        }
    }

    /// The selected instance's resources after the active filter, before
    /// grouping and before collapse. THE one filtered source: every count the
    /// dashboard shows — the status strip's rollup and each group header's —
    /// derives from this single expression, so the two cannot report different
    /// numbers for the same instance.
    ///
    /// This exists because they did. `selectedSummary` was built from the
    /// unfiltered `visibleResources` while `visibleGroups` filtered; measured
    /// on 3 resources with 2 disabled, the strip read `✓3/3` while the group
    /// header read `✓1/1`. Worst case was this branch's own "Disable All": a
    /// 5-resource instance showed `RESOURCES ✓5/5` — everything healthy — over
    /// a table with zero rows in it.
    private var filteredResources: [Resource] {
        filter.apply(to: visibleResources)
    }

    /// The selected instance's resources, filtered and grouped for display.
    ///
    /// A collapsed group's `resources` is emptied so the table renders no
    /// rows for it, but `ResourceGroup.collapsed(from:)` carries the true,
    /// pre-collapse `summary` over regardless, so its header keeps reporting
    /// accurate numbers while collapsed.
    public var visibleGroups: [ResourceGroup] {
        ResourceGroup.group(filteredResources).map { group in
            guard collapsedGroups.contains(Self.collapseKey(for: group.name)) else { return group }
            return ResourceGroup.collapsed(from: group)
        }
    }

    /// The selected instance's rollup counts, matching tilt's own header
    /// (`×2 ⚙2 ✓45/49`). `nil` when nothing is selected or the selected
    /// project is not running, distinct from a running instance with zero
    /// resources.
    ///
    /// Counts what the table is actually showing — `filteredResources`, the
    /// same source the group headers sum to. The settled answer to "are
    /// disabled resources counted?" is therefore: only when the user has asked
    /// to see them (`ResourceFilter.showDisabled`), and identically on every
    /// surface. A strip that counted the whole instance while the rows beneath
    /// it counted something else is a header disagreeing with the thing it
    /// heads, which is worse than a number that moves when you type in the
    /// search box.
    ///
    /// Collapse deliberately does not affect this: `visibleGroups` empties a
    /// collapsed group's rows but `ResourceGroup.collapsed(from:)` carries its
    /// true summary over, so a collapsed group still contributes its counts to
    /// both its own header and this rollup.
    public var selectedSummary: ResourceSummary? {
        guard selectedItem?.isRunning == true else { return nil }
        return ResourceSummary(resources: filteredResources)
    }

    /// What the table shows when it has no rows to draw.
    ///
    /// Lives here rather than in the view for the reason `Resource.lastBuildText`
    /// does: it is logic with edge cases worth testing, and `FulcrumKit` is
    /// where testable things go.
    public struct EmptyState: Equatable, Sendable {
        public let title: String
        /// The line beneath the title, naming the way out. `nil` when there
        /// isn't one — a running project that genuinely has no resources is
        /// not something the user can act on.
        public let detail: String?
    }

    /// The empty state to draw, or `nil` when there are rows.
    ///
    /// Keyed on `visibleGroups`, the same thing the table draws from, so this
    /// cannot say "here are your rows" while the table renders none. The view
    /// previously gated its empty state on the unfiltered `visibleResources`,
    /// which meant a search matching nothing — or "Disable All", which hides
    /// every row by default — produced a blank pane with no rows and no
    /// message at all.
    ///
    /// The wording distinguishes the five ways a table ends up empty, because
    /// they have five different ways out: nothing is selected at all (open
    /// one), the project isn't running (start it), it has no resources
    /// (nothing to do), the search matches nothing (clear it), or everything
    /// left is disabled (show disabled, or re-enable them).
    public var emptyState: EmptyState? {
        guard visibleGroups.isEmpty else { return nil }

        // Distinct from a selected-but-stopped project below: "Start this
        // project" is a lie when there is no project to start — a totally
        // fresh dashboard (nothing running, nothing ever in Recent) has no
        // `selectedItem` at all, and its way in is Open Tiltfile…, not a
        // restart.
        guard let selectedItem else {
            return EmptyState(
                title: "No project open",
                detail: "Choose “Open Tiltfile…” from the status menu, or press ⌘O, to start one."
            )
        }

        guard selectedItem.isRunning else {
            return EmptyState(title: "Not running", detail: "Start this project to see its resources.")
        }

        let all = visibleResources
        guard !all.isEmpty else {
            return EmptyState(title: "No resources", detail: nil)
        }

        let matchingQuery = filter.matchingQuery(all)
        guard !matchingQuery.isEmpty else {
            return EmptyState(
                title: "No resources match “\(filter.query)”",
                detail: "Clear the search to see \(Self.count(all.count, "resource"))."
            )
        }

        // The query matched, so the only thing left that can have emptied the
        // table is `showDisabled` — every survivor is disabled.
        let hidden = matchingQuery.count
        return EmptyState(
            title: filter.query.isEmpty
                ? "All resources are disabled"
                : "No enabled resources match “\(filter.query)”",
            detail: "\(Self.count(hidden, "disabled resource")) hidden. Turn on Show disabled to see \(hidden == 1 ? "it" : "them")."
        )
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// A stable `String` key for a group name, standing in for the ungrouped
    /// `nil` bucket that `Set<String>` cannot store directly. Not the empty
    /// string: tilt group labels are arbitrary user text, and an empty-string
    /// label would otherwise collide with the ungrouped bucket.
    private static func collapseKey(for groupName: String?) -> String {
        groupName ?? "\u{0}ungrouped"
    }

    /// The status strip's text.
    public var statusSummary: String {
        let instances = appModel.stores.count
        guard instances > 0 else { return "No tilt instances running" }

        let resources = appModel.stores.reduce(0) { $0 + $1.resources.count }
        let building = appModel.stores.reduce(0) {
            $0 + $1.resources.filter { $0.health == .building }.count
        }

        var parts = [
            "\(instances) \(instances == 1 ? "instance" : "instances")",
            "\(resources) \(resources == 1 ? "resource" : "resources")"
        ]
        if building > 0 { parts.append("\(building) building") }
        return parts.joined(separator: " · ")
    }

    /// Worst health across every project, for the status strip's chip.
    ///
    /// `nil` when nothing is running — distinct from healthy, which is the
    /// distinction this codebase has had to fix twice at other levels.
    public var worstHealth: ResourceHealth? {
        sections.flatMap(\.items).compactMap(\.health).max()
    }

    /// The status strip's chip accessibility label.
    ///
    /// Deliberately worded as an aggregate rather than reusing a bare
    /// `ResourceHealth.label` — this chip is the worst health across every
    /// running instance, not one resource's own status, and VoiceOver
    /// announcing a plain "error" here would claim to describe a single thing
    /// when it actually means "something, somewhere".
    public var statusStripLabel: String {
        guard let worstHealth else { return "no instances running" }
        return "aggregate status: \(worstHealth.label)"
    }
}
