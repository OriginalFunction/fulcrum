import Foundation
import Testing
@testable import FulcrumKit

private func instance(port: Int) -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data("pem".utf8), token: "t\(port)"
    ))
}

private func event(name: String, update: String, order: Int, group: String? = nil, disabled: Bool = false) -> WatchEvent {
    WatchEvent(type: .added, object: UIResource(
        metadata: .init(name: name, resourceVersion: "1", labels: group.map { [$0: $0] }),
        status: .init(updateStatus: update, runtimeStatus: "ok",
                      disableStatus: .init(state: disabled ? "Disabled" : "Enabled"), buildHistory: nil,
                      pendingBuildSince: nil, order: order, specs: nil)
    ))
}

@MainActor private func makeDashboard(
    logStreaming: any LogStreaming = LogStreamer()
) -> (DashboardModel, AppModel, RecentsStore) {
    let app = AppModel(
        settings: SettingsStore(defaults: TestUserDefaults.fresh()),
        aliasesDefaults: TestUserDefaults.fresh()
    )
    let recents = RecentsStore(storage: InMemoryRecentsStorage())
    return (DashboardModel(appModel: app, recents: recents, logStreaming: logStreaming), app, recents)
}

/// The names the table actually draws: the selected instance's resources
/// after the active filter AND the group-collapse state. `DashboardModel`
/// carried this as a public property that nothing in the app ever read — only
/// these tests — so it lives here now.
@MainActor private func drawnResourceNames(_ dashboard: DashboardModel) -> [String] {
    dashboard.visibleGroups.flatMap { $0.resources.map(\.name) }
}

@Test @MainActor func selectsTheFirstRunningInstanceWhenNothingIsSelected() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    #expect(dashboard.selectedItem?.port == 10350)
}

@Test @MainActor func showsResourcesForTheSelectedInstance() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    app.stores[0].apply(event(name: "alpha", update: "ok", order: 1))
    app.stores[1].apply(event(name: "beta", update: "ok", order: 1))

    dashboard.selectedSidebarID = "port-10360"
    #expect(dashboard.visibleResources.map(\.name) == ["beta"])
}

@Test @MainActor func selectedInstanceMatchesTheSelectedSidebarItem() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])

    dashboard.selectedSidebarID = "port-10360"

    #expect(dashboard.selectedInstance?.webPort == 10360)
}

@Test @MainActor func selectedInstanceIsNilWhenTheSelectedProjectIsNotRunning() {
    let (dashboard, _, recents) = makeDashboard()
    recents.remember(instance(port: 10360))
    dashboard.selectedSidebarID = "port-10360"

    #expect(dashboard.selectedInstance == nil)
}

@Test @MainActor func aStoppedProjectShowsNoResources() {
    let (dashboard, _, recents) = makeDashboard()
    recents.remember(instance(port: 10360))
    dashboard.selectedSidebarID = "port-10360"
    #expect(dashboard.visibleResources.isEmpty)
}

@Test @MainActor func selectionSurvivesAnUnrelatedInstanceAppearing() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.selectedSidebarID = "port-10360"

    // 10360 is not first either before or after this sync, so a regression that
    // always returned the first item would fail this — unlike selecting an
    // already-first item, which such a regression would pass by accident.
    app.sync(with: [instance(port: 10350), instance(port: 10360), instance(port: 10370)])
    #expect(dashboard.selectedItem?.port == 10360)
}

@Test @MainActor func selectionFallsBackWhenTheSelectedInstanceDisappears() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.selectedSidebarID = "port-10360"

    app.sync(with: [instance(port: 10350)])
    // The selected project vanished; fall back rather than showing a blank pane.
    #expect(dashboard.selectedItem?.port == 10350)
}

@Test @MainActor func selectedSidebarIDReflectsTheFallbackSoTheSidebarHighlightAgrees() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.selectedSidebarID = "port-10360"

    app.sync(with: [instance(port: 10350)])
    // The content already falls back; the id must too, or the sidebar
    // highlights nothing while the pane shows the fallback project's resources.
    #expect(dashboard.selectedSidebarID == "port-10350")
}

@Test @MainActor func statusSummaryCountsInstancesAndResources() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    app.stores[0].apply(event(name: "a", update: "ok", order: 1))
    app.stores[0].apply(event(name: "b", update: "in_progress", order: 2))
    app.stores[1].apply(event(name: "c", update: "ok", order: 1))

    #expect(dashboard.statusSummary == "2 instances · 3 resources · 1 building")
}

@Test @MainActor func statusSummaryOmitsTheBuildingClauseWhenNothingIsBuilding() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "a", update: "ok", order: 1))
    #expect(dashboard.statusSummary == "1 instance · 1 resource")
}

@Test @MainActor func statusSummaryReadsEmptyWhenNothingIsRunning() {
    let (dashboard, _, _) = makeDashboard()
    #expect(dashboard.statusSummary == "No tilt instances running")
}

@Test @MainActor func worstHealthIsTheMaximumAcrossAllProjects() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    app.stores[0].apply(event(name: "a", update: "ok", order: 1))
    app.stores[1].apply(event(name: "b", update: "error", order: 1))

    #expect(dashboard.worstHealth == .error)
}

@Test @MainActor func worstHealthIsNilWhenNothingIsRunning() {
    let (dashboard, _, _) = makeDashboard()
    #expect(dashboard.worstHealth == nil)
}

@Test @MainActor func worstHealthIsNilWithOnlyStoppedProjectsInRecents() {
    let (dashboard, _, recents) = makeDashboard()
    recents.remember(instance(port: 10360))
    // A stopped project has no health — not `.disabled`, which is a resource
    // state — so it must not surface as the worst health.
    #expect(dashboard.worstHealth == nil)
}

@Test @MainActor func statusStripLabelReadsNoInstancesWhenNothingIsRunning() {
    let (dashboard, _, _) = makeDashboard()
    #expect(dashboard.statusStripLabel == "no instances running")
}

/// The defect this guards against: VoiceOver announcing a bare health word
/// ("error") for the strip's chip reads as if describing one resource, when
/// it is actually the worst across every running instance. Mutating
/// `statusStripLabel` to `return worstHealth?.label ?? "no instances
/// running"` — dropping the "aggregate status:" framing — makes this fail.
@Test @MainActor func statusStripLabelIsFramedAsAnAggregateNotABareHealthWord() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "a", update: "error", order: 1))

    #expect(dashboard.statusStripLabel == "aggregate status: error")
    #expect(dashboard.statusStripLabel != "error")
}

@Test @MainActor func collapsingAGroupHidesItsRowsButKeepsItsHeader() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "ai-redis", update: "ok", order: 2, group: "ai"))
    app.stores[0].apply(event(name: "ai-worker", update: "error", order: 3, group: "ai"))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 1, group: "auth"))

    dashboard.toggleCollapse("ai")

    let ai = try #require(dashboard.visibleGroups.first { $0.name == "ai" })
    #expect(ai.resources.isEmpty)
    // Header still reports the true count — not derived from the now-empty
    // `resources` array, which a naive `ResourceSummary(resources: [])` would.
    #expect(ai.summary.total == 3)
    #expect(ai.summary.error == 1)

    let auth = try #require(dashboard.visibleGroups.first { $0.name == "auth" })
    #expect(auth.resources.map(\.name) == ["auth-svc"])
}

/// The requirement that matters most: tilt pushes a watch event every few
/// seconds and `visibleGroups` is rebuilt from scratch (fresh `ResourceGroup`
/// values) on every read. A collapse keyed on anything but the stable group
/// name — an index, or a reference to a transient `ResourceGroup` — would
/// silently reset here, re-expanding the group under the user mid-build.
@Test @MainActor func collapseStateSurvivesAResourceRefresh() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 1, group: "auth"))

    dashboard.toggleCollapse("ai")
    #expect(dashboard.collapsedGroups.contains("ai"))

    // A fresh watch push: an existing resource's status flips and a new one
    // joins the group — the model re-applies the full resource list, exactly
    // as tilt's watch does every few seconds.
    app.stores[0].apply(event(name: "ai-api", update: "error", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "ai-new", update: "ok", order: 2, group: "ai"))

    #expect(dashboard.collapsedGroups.contains("ai"))
    let ai = try #require(dashboard.visibleGroups.first { $0.name == "ai" })
    #expect(ai.resources.isEmpty)
    #expect(ai.summary.total == 2)
}

@Test @MainActor func togglingCollapseTwiceReExpandsTheGroup() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))

    dashboard.toggleCollapse("ai")
    dashboard.toggleCollapse("ai")

    #expect(!dashboard.collapsedGroups.contains("ai"))
    let ai = try #require(dashboard.visibleGroups.first { $0.name == "ai" })
    #expect(ai.resources.map(\.name) == ["ai-api"])
}

/// `(Tiltfile)` is the one resource tilt never labels — its group name is
/// `nil`. `collapsedGroups` is `Set<String>`, so `nil` needs a stable key of
/// its own; this proves collapsing the ungrouped bucket actually works
/// rather than silently no-oping because `nil` can't be stored.
@Test @MainActor func collapsingTheUngroupedBucketHidesTiltfileRow() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "(Tiltfile)", update: "ok", order: 0, group: nil))
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))

    dashboard.toggleCollapse(nil)

    let ungrouped = try #require(dashboard.visibleGroups.first { $0.name == nil })
    #expect(ungrouped.resources.isEmpty)
    #expect(ungrouped.summary.total == 1)

    let ai = try #require(dashboard.visibleGroups.first { $0.name == "ai" })
    #expect(ai.resources.map(\.name) == ["ai-api"])
}

/// `visibleGroups` must consume the active filter, not just `visibleResources`
/// directly — otherwise the filter bar (Task 6) would have nothing to bind to
/// that actually affects the grouped table.
@Test @MainActor func visibleGroupsRespectsTheActiveFilter() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 1, group: "auth"))

    dashboard.filter.query = "auth"

    #expect(dashboard.visibleGroups.map(\.name) == ["auth"])
}

@Test @MainActor func selectedSummaryIsNilWhenNothingIsRunning() {
    let (dashboard, _, _) = makeDashboard()
    #expect(dashboard.selectedSummary == nil)
}

@Test @MainActor func selectedSummaryReflectsTheSelectedInstanceOnly() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    app.stores[0].apply(event(name: "a", update: "ok", order: 1))
    app.stores[0].apply(event(name: "b", update: "error", order: 2))
    app.stores[1].apply(event(name: "c", update: "ok", order: 1))

    dashboard.selectedSidebarID = "port-10350"

    let summary = try #require(dashboard.selectedSummary)
    #expect(summary.total == 2)
    #expect(summary.error == 1)
    #expect(summary.healthy == 1)
}

/// The settled answer to "what do the counts count?": whatever the table is
/// showing. `selectedSummary` follows the active filter, because the group
/// headers below it always have — a strip reading `✓2/2` above a table
/// drawing one row is the header disagreeing with the thing it heads.
@Test @MainActor func selectedSummaryFollowsTheActiveFilter() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 1, group: "auth"))

    dashboard.filter.query = "auth"

    let summary = try #require(dashboard.selectedSummary)
    #expect(summary.total == 1)
}

/// The same answer for the other hider. Disabled resources are excluded from
/// the counts unless the user has asked to see them, exactly as they are
/// excluded from the rows.
@Test @MainActor func selectedSummaryExcludesDisabledResourcesUntilTheUserAsksForThem() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "ai-batch", update: "ok", order: 2, group: "ai", disabled: true))
    app.stores[0].apply(event(name: "ai-worker", update: "ok", order: 3, group: "ai", disabled: true))

    // Measured before the fix: this read `✓3/3` while the group header
    // directly beneath it read `✓1/1`.
    #expect(try #require(dashboard.selectedSummary).total == 1)

    dashboard.filter.showDisabled = true
    let summary = try #require(dashboard.selectedSummary)
    #expect(summary.total == 3)
    // The two disabled resources must land in their own bucket, not get
    // folded into `healthy` — see `ResourceSummary`'s doc comment.
    #expect(summary.disabled == 2)
    #expect(summary.healthy == 1)
}

/// The regression guard proper: the status strip and the group headers are
/// two independent readers, and this drives BOTH of their real code paths and
/// compares the results. `selectedSummary` is what `StatusStripView` renders;
/// `visibleGroups.map(\.summary)` is what each `GroupHeaderRow` renders. It
/// deliberately does not recompute the expected numbers from a third
/// expression — a test that computes the same thing twice compares production
/// to itself and can never fail, which this project has already shipped once.
///
/// Driven through the worst case this branch made reachable: "Disable All"
/// disables every resource, after which the strip read `RESOURCES ✓5/5` —
/// everything healthy — above a table with no rows in it at all.
@Test @MainActor func theStatusStripAndTheGroupHeadersNeverReportDifferentCounts() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "error", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "ai-batch", update: "pending", order: 2, group: "ai"))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 3, group: "auth"))
    app.stores[0].apply(event(name: "auth-db", update: "ok", order: 4, group: "auth", disabled: true))
    app.stores[0].apply(event(name: "(Tiltfile)", update: "ok", order: 0, group: nil))

    // Every state a user can actually put the dashboard into, including the
    // one that produced the measured `✓5/5` over an empty table.
    let states: [(name: String, apply: @MainActor () -> Void)] = [
        ("untouched", {}),
        ("searching", { dashboard.filter.query = "auth" }),
        ("search matching nothing", { dashboard.filter.query = "zzz" }),
        ("showing disabled", { dashboard.filter.query = ""; dashboard.filter.showDisabled = true }),
        ("a group collapsed", { dashboard.filter.showDisabled = false; dashboard.toggleCollapse("ai") }),
        ("every resource disabled", {
            dashboard.toggleCollapse("ai")
            app.stores[0].apply(event(name: "ai-api", update: "error", order: 1, group: "ai", disabled: true))
            app.stores[0].apply(event(name: "ai-batch", update: "pending", order: 2, group: "ai", disabled: true))
            app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 3, group: "auth", disabled: true))
            app.stores[0].apply(event(name: "(Tiltfile)", update: "ok", order: 0, group: nil, disabled: true))
        })
    ]

    for state in states {
        state.apply()

        let strip = try #require(dashboard.selectedSummary)
        let headers = dashboard.visibleGroups.map(\.summary)

        #expect(strip.total == headers.reduce(0) { $0 + $1.total }, "totals disagree while \(state.name)")
        #expect(strip.error == headers.reduce(0) { $0 + $1.error }, "error counts disagree while \(state.name)")
        #expect(strip.pending == headers.reduce(0) { $0 + $1.pending }, "pending counts disagree while \(state.name)")
        #expect(strip.healthy == headers.reduce(0) { $0 + $1.healthy }, "healthy counts disagree while \(state.name)")
        #expect(strip.disabled == headers.reduce(0) { $0 + $1.disabled }, "disabled counts disagree while \(state.name)")
    }
}

// MARK: - Empty state

/// The bug this exists for: the table gated its empty state on the UNFILTERED
/// resource list, so a query matching nothing drew a `List` with no sections
/// — a blank pane with neither rows nor any message. `emptyState` must be
/// non-nil exactly when `visibleGroups` is empty, which is what the table
/// actually draws from.
@Test @MainActor func aSearchMatchingNothingExplainsItselfInsteadOfShowingABlankPane() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 2, group: "auth"))

    #expect(dashboard.emptyState == nil)

    dashboard.filter.query = "zzz"

    #expect(dashboard.visibleGroups.isEmpty)
    let state = try #require(dashboard.emptyState)
    // Names the query, and the way out — this is the difference between "no
    // resources" (nothing to do) and "nothing matches" (clear the search).
    #expect(state.title.contains("zzz"))
    #expect(try #require(state.detail).contains("Clear the search"))
    #expect(try #require(state.detail).contains("2 resources"))
}

/// The other way this branch can empty the table: "Disable All". Every
/// resource still exists, so "No resources" would be a lie; the way out is
/// the Show disabled toggle, not the search box.
@Test @MainActor func disablingEveryResourceSaysSoRatherThanClaimingThereAreNone() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai", disabled: true))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 2, group: "auth", disabled: true))

    let state = try #require(dashboard.emptyState)
    #expect(state.title == "All resources are disabled")
    #expect(try #require(state.detail).contains("2 disabled resources"))
    #expect(try #require(state.detail).contains("Show disabled"))

    dashboard.filter.showDisabled = true
    #expect(dashboard.emptyState == nil)
}

/// Both hiders at once: the query matches, but everything it matched is
/// disabled. Blaming the search alone would send the user to clear a query
/// that is not the problem.
@Test @MainActor func aQueryThatOnlyMatchesDisabledResourcesBlamesTheRightHider() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 2, group: "auth", disabled: true))

    dashboard.filter.query = "auth"

    let state = try #require(dashboard.emptyState)
    #expect(state.title == "No enabled resources match “auth”")
    #expect(try #require(state.detail).contains("1 disabled resource "))
}

@Test @MainActor func aRunningProjectWithNoResourcesSaysSoWithNoWayOutToOffer() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])

    let state = try #require(dashboard.emptyState)
    #expect(state.title == "No resources")
    #expect(state.detail == nil)
}

/// The third first-run state: the dashboard is open, nothing has ever run,
/// and nothing is in Recent either — `selectedItem` is `nil`, not merely a
/// stopped project. Distinct from `aStoppedProjectIsTheOneEmptyStateThatTellsYouToStartIt`
/// below: "Start this project" is a lie when there is no project to start.
/// This must point at the real way in — Open Tiltfile… — rather than sit
/// blank or repeat that misleading copy.
@Test @MainActor func aFreshDashboardWithNothingSelectedPointsAtOpenTiltfile() throws {
    let (dashboard, _, _) = makeDashboard()

    #expect(dashboard.selectedItem == nil)
    let state = try #require(dashboard.emptyState)
    #expect(state.title == "No project open")
    #expect(state.detail == "Choose “Open Tiltfile…” from the status menu, or press ⌘O, to start one.")
}

@Test @MainActor func aStoppedProjectIsTheOneEmptyStateThatTellsYouToStartIt() throws {
    let (dashboard, _, recents) = makeDashboard()
    recents.remember(instance(port: 10360))
    dashboard.selectedSidebarID = "port-10360"

    let state = try #require(dashboard.emptyState)
    #expect(state.title == "Not running")
    #expect(state.detail == "Start this project to see its resources.")
}

@Test @MainActor func focusingAFailureSelectsItsInstanceAndResource() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    app.stores[0].apply(event(name: "ai-pdf-image-extractor", update: "error", order: 1, group: "ai"))
    // A second instance and a selection elsewhere, so this proves focus
    // actually moves the selection rather than the target already being
    // selected by default.
    dashboard.selectedSidebarID = "port-10360"

    dashboard.focus(resource: "ai-pdf-image-extractor", onInstanceWithPort: 10350)

    #expect(dashboard.selectedSidebarID == "port-10350")
    #expect(dashboard.selectedResourceName == "ai-pdf-image-extractor")
}

/// The trap this guards against: the user has typed "auth" into the filter
/// and a failing `ai-pdf-image-extractor` is clicked from the menu. Clearing
/// the query alone is not enough if the resource's group is also collapsed —
/// both must be undone or the dashboard opens onto a table with nothing in
/// it.
@Test @MainActor func focusingClearsAnActiveFilterAndExpandsACollapsedGroupThatWouldHideTheTarget() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-pdf-image-extractor", update: "error", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "auth-svc", update: "ok", order: 2, group: "auth"))

    dashboard.filter.query = "auth"
    dashboard.toggleCollapse("ai")

    dashboard.focus(resource: "ai-pdf-image-extractor", onInstanceWithPort: 10350)

    #expect(dashboard.filter.query.isEmpty)
    #expect(!dashboard.collapsedGroups.contains("ai"))
    #expect(drawnResourceNames(dashboard).contains("ai-pdf-image-extractor"))
}

/// The third hider `focus` must undo, alongside the active filter and a
/// collapsed group: `showDisabled`. A disabled resource is hidden by
/// default, so focusing one without revealing it would land the user on the
/// same dead end the other two checks already guard against.
@Test @MainActor func focusingADisabledResourceRevealsIt() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    app.stores[0].apply(event(name: "ai-batch", update: "ok", order: 2, group: "ai", disabled: true))

    dashboard.focus(resource: "ai-batch", onInstanceWithPort: 10350)

    #expect(dashboard.filter.showDisabled)
    #expect(drawnResourceNames(dashboard).contains("ai-batch"))
}

/// `(Tiltfile)` is tilt's one ungrouped resource — its collapse key is the
/// `nil`-standing-in sentinel, not the literal group name. Focusing it must
/// expand the same bucket `toggleCollapse(nil)` collapsed, proving the two
/// sides agree on that key.
@Test @MainActor func focusingAnUngroupedResourceExpandsTheUngroupedBucket() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "(Tiltfile)", update: "ok", order: 0, group: nil))

    dashboard.toggleCollapse(nil)
    dashboard.focus(resource: "(Tiltfile)", onInstanceWithPort: 10350)

    #expect(drawnResourceNames(dashboard).contains("(Tiltfile)"))
}

/// Proves `DashboardModel`'s `logStreaming` parameter actually reaches
/// `logPane`, not just that `logPane` exists — a `DashboardModel` built with
/// the default `LogStreamer()` would compile and pass every other test here
/// while silently never delivering an injected stub to the pane at all.
@Test @MainActor func logPaneStreamsThroughTheInjectedStreamingDependency() async throws {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350)])

    dashboard.logPane.follow(dashboard.selectedInstance)
    #expect(stub.streamedInstanceCount == 1)
}

// MARK: - Log pane lifecycle: tracking the selected instance

/// `followSelectedInstanceLogs()` — and therefore an explicit
/// `selectedSidebarID` change — must never start a stream on its own; only
/// the dashboard window actually opening does that (`DashboardWindowController.show()`
/// in the app target, or `logPane.follow(_:)` called directly, as this test
/// does to simulate it). Without this guard, picking an instance in the
/// sidebar before ever opening the window would spawn a `tilt logs --follow`
/// child for a pane nothing is displaying yet.
@Test @MainActor func selectingAnInstanceDoesNotStartAStreamBeforeThePaneHasEverFollowedOne() {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350), instance(port: 10360)])

    dashboard.selectedSidebarID = "port-10360"

    #expect(stub.streamedInstanceCount == 0)
    #expect(!dashboard.logPane.isFollowingAnInstance)
}

/// Once the pane IS following something (the window is open), an explicit
/// sidebar selection re-points it at the newly selected instance — this is
/// the piece that used to live only in `LogPaneView`'s `onChange`, untestable
/// without a running view. Proven at the `DashboardModel` level so switching
/// actually starts the new instance's stream without a view in the loop.
@Test @MainActor func selectingADifferentInstanceRePointsAnAlreadyActivePane() {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350), instance(port: 10360)])

    // Simulates the dashboard window having been opened once already —
    // `DashboardWindowController.show()`'s real trigger.
    dashboard.logPane.follow(dashboard.selectedInstance)
    #expect(stub.streamedInstanceCount == 1)

    dashboard.selectedSidebarID = "port-10360"

    #expect(stub.streamedInstanceCount == 2)
    #expect(stub.mostRecentlyStreamedInstanceID == instance(port: 10360).id)
}

/// THE test for Task 6's Step 1: two selections in quick succession, with no
/// `await` between them at all — the shape a user arrowing quickly through
/// the sidebar produces — must settle on exactly one active stream: the
/// last instance picked, with every earlier one torn down, none left
/// permanently orphaned.
///
/// This does not assert zero *transient* overlap: `LogPaneModel.follow(_:)`
/// calls `streamTask?.cancel()` before starting the next stream (proven by
/// `switchingInstancesClearsThePreviousBuffer` et al.), but that only marks
/// the old task cancelled — a task that has not yet been scheduled to run
/// does not react to cancellation until the run loop gets to it (confirmed
/// against Swift's `AsyncThrowingStream`: cancelling an *already-suspended*
/// consumer fires `onTermination` synchronously, but cancelling one that
/// hasn't started running yet does not, until it does). A brief window where
/// an old, already-cancelled stream's child hasn't been reaped yet is
/// therefore expected and self-resolving; what must never happen is a
/// *permanent* leak. The bounded poll below gives that self-resolution a
/// chance without hanging if it never arrives; the settled-state assertion
/// is what actually catches a regression — see the next test for the
/// specific mutation ("teardown moved after start") this is written against.
@Test(.timeLimit(.minutes(1))) @MainActor func rapidlySwitchingInstancesSettlesOnExactlyTheLastOneSelected() async throws {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350), instance(port: 10360), instance(port: 10370)])

    dashboard.logPane.follow(dashboard.selectedInstance) // simulates the window opening
    dashboard.selectedSidebarID = "port-10360"
    dashboard.selectedSidebarID = "port-10370"

    #expect(try await settledActiveInstanceIDs(stub) == [instance(port: 10370).id])
}

/// The mutation this whole file's lifecycle tests are written against:
/// `streamTask?.cancel()` moved to *after* `streamTask` is reassigned to the
/// new `Task`, so it cancels the stream that was just started instead of the
/// one being replaced. Unlike the transient-overlap window the previous test
/// tolerates, this leaves the OLD stream permanently un-cancelled — nothing
/// ever tears it down — which a settled-state poll catches deterministically:
/// the active set never converges to just the last selection, so it never
/// stops growing/disagreeing, and the bounded wait times out into a failing
/// `#expect` rather than hanging.
///
/// This test does not depend on that mutation actually being present — it
/// exercises the same rapid-switch path as the previous test and pins down
/// the *correct* outcome (only the third instance's process survives)
/// precisely because, on the reordered code, it would not.
@Test(.timeLimit(.minutes(1))) @MainActor func rapidlySwitchingLeavesNoInstanceOtherThanTheLastOneActive() async throws {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350), instance(port: 10360), instance(port: 10370)])

    dashboard.logPane.follow(dashboard.selectedInstance)
    dashboard.selectedSidebarID = "port-10360"
    dashboard.selectedSidebarID = "port-10370"
    dashboard.selectedSidebarID = "port-10350"
    dashboard.selectedSidebarID = "port-10370"

    let active = try await settledActiveInstanceIDs(stub)
    #expect(active == [instance(port: 10370).id])
    #expect(!active.contains(instance(port: 10350).id))
    #expect(!active.contains(instance(port: 10360).id))
}

/// Waits for the stub's streams to CONVERGE — for exactly one call to
/// `stream(instance:tail:)` to still be live — and then reports which
/// instance that surviving stream belongs to.
///
/// The condition is counted, not timed. This helper used to define "settled"
/// as "the observed set has not changed for 200ms", which is a wall-clock
/// proxy for the thing the callers actually assert about: every superseded
/// stream has terminated. The two are not the same. `LogPaneModel.follow(_:)`
/// cancels the outgoing session, but cancelling a `Task` the executor has not
/// yet scheduled does not fire the stream's `onTermination` until it does —
/// and `StubLogStreaming` only drops a stream from `active` from that
/// callback. Under swift-testing's parallel execution the gap between two
/// `onTermination` firings can exceed any quiet period you pick, at which
/// point the poll called an intermediate state settled and handed back a set
/// still carrying a superseded stream's instance. That failed on correct
/// code, 2 runs in 11. `StubLogStreaming.delayTerminationReporting(for:by:)`
/// reproduces it on demand, and
/// `settledActiveInstanceIDsWaitsForEveryStreamToTerminateNotForTheClockToGoQuiet`
/// below holds this helper to the counted answer.
///
/// It counts live *streams* rather than live instance ids on purpose:
/// `activeInstanceIDs` collapses two live streams for the same instance into
/// one element, and `rapidlySwitchingLeavesNoInstanceOtherThanTheLastOneActive`
/// switches away from 10370 and back to it — so "one id left" is true there
/// while an earlier 10370 stream is still winding down, and only "one stream
/// left" means converged. Both callers open exactly one stream per selection
/// (3 and 5 respectively) and correctly leave exactly one alive.
///
/// The deadline is a hang-guard, not an assertion about speed: nothing here
/// requires convergence to happen *within* it. On the mutation these tests are
/// written against — teardown moved after the new session is installed, so the
/// superseded streams are never cancelled at all — the count never reaches 1,
/// and returning the un-converged set makes the caller's `#expect` fail while
/// naming the leaked instances, which is strictly more useful than hanging or
/// than throwing a bare timeout. 10s is the same bound the process-reaping
/// waits in `LogStreamerTests` and `DashboardLogLifecycleTests` use, and it is
/// 50x the 200ms window that was not enough.
@MainActor private func settledActiveInstanceIDs(
    _ stub: StubLogStreaming,
    timeout: Double = 10
) async throws -> Set<TiltInstance.InstanceID> {
    let deadline = Date().addingTimeInterval(timeout)
    while stub.activeStreamCount != 1 && Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return stub.activeInstanceIDs
}

/// The guard that keeps `settledActiveInstanceIDs` honest, and the only
/// reason `StubLogStreaming.delayTerminationReporting(for:by:)` exists.
///
/// This is the flake itself, made deterministic. The helper used to return as
/// soon as the observed instance set had held still for 200ms; here the two
/// superseded streams that must disappear from the answer take a full second
/// to report their termination, so a quiet-clock helper reads the
/// intermediate state as settled and hands back a set still containing 10360.
/// Measured against the previous helper this failed 10 runs out of 10 — the
/// real flake failed 2 in 11 — and against this one it passes 10 out of 10.
///
/// Both defects the old helper had are covered. 10360 is a superseded stream
/// for a DIFFERENT instance, which must not appear in the answer at all.
/// 10370 is superseded by a later stream for the SAME instance (the fourth
/// switch selects it again), so the count of distinct active *ids* is 1 while
/// two streams are still live — which is why the helper counts streams, and
/// why `activeStreamCount` is asserted here rather than only the id set.
@Test(.timeLimit(.minutes(1))) @MainActor func settledActiveInstanceIDsWaitsForEveryStreamToTerminateNotForTheClockToGoQuiet() async throws {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350), instance(port: 10360), instance(port: 10370)])
    stub.delayTerminationReporting(for: instance(port: 10360).id, by: .seconds(1))
    stub.delayTerminationReporting(for: instance(port: 10370).id, by: .seconds(1))

    dashboard.logPane.follow(dashboard.selectedInstance)
    dashboard.selectedSidebarID = "port-10360"
    dashboard.selectedSidebarID = "port-10370"
    dashboard.selectedSidebarID = "port-10350"
    dashboard.selectedSidebarID = "port-10370"

    let active = try await settledActiveInstanceIDs(stub)
    #expect(active == [instance(port: 10370).id])
    #expect(stub.activeStreamCount == 1, "returned before the superseded streams had actually terminated")
}

/// The other half of `logPane`'s doc comment: discovery reconciling the live
/// instance set (`AppDelegate.reconcile(with:)`'s real call to
/// `AppModel.sync(with:)`) must re-point — or stop — an already-active pane
/// the moment the followed instance stops, not only the next time a view
/// happens to re-render.
@Test @MainActor func discoveryLosingTheFollowedInstanceStopsThePane() {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350)])
    dashboard.logPane.follow(dashboard.selectedInstance)
    #expect(dashboard.logPane.isFollowingAnInstance)

    app.sync(with: [])
    dashboard.followSelectedInstanceLogs()

    #expect(!dashboard.logPane.isFollowingAnInstance)
}

// MARK: - Log pane lifecycle: the dashboard window opening, closing, opening again

/// THE regression this file gained after the log pane shipped blank.
///
/// The user-visible report was "the logs don't always appear": header row
/// drawn, nothing under it. Instrumenting a Release build against a live
/// instance produced the whole sequence — open #1 streamed (`rows=1324`),
/// `windowWillClose` called `logPane.follow(nil)`, and the second `show()`
/// then reached nothing at all: `rows=0 lines=0 following=nil`, with no
/// `tilt logs` child left running.
///
/// The cause was entirely in which method `show()` called.
/// `followSelectedInstanceLogs()` guards on `LogPaneModel.isFollowingAnInstance`
/// — which the close had just cleared — so it early-returned. Nothing else
/// covered for it: the window is `isReleasedWhenClosed = false`, so reopening
/// reuses the same hosted view and `LogPaneView`'s `onChange(..., initial:
/// true)` never fires a second time (measured: no `onAppear`, no `onChange`,
/// no `body` re-evaluation on reopen).
///
/// `dashboardWindowDidBecomeVisible()` is what `show()` calls now, and this
/// pins the property that matters: a SECOND stream really is started, counted
/// through the injected streamer rather than inferred from any elapsed time.
@Test @MainActor func reopeningTheDashboardWindowStartsTheStreamAgain() {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350)])

    // `show()` starts the FIRST stream by itself too — it used to lean on
    // `LogPaneView`'s `onChange(..., initial: true)` for that, which is
    // exactly the crutch that had nothing left to give on the second open.
    dashboard.dashboardWindowDidBecomeVisible() // `DashboardWindowController.show()`
    #expect(stub.streamedInstanceCount == 1)

    dashboard.logPane.follow(nil) // exactly `windowWillClose`'s call
    #expect(!dashboard.logPane.isFollowingAnInstance)

    dashboard.dashboardWindowDidBecomeVisible() // `show()` again — the app's ONLY call on reopen

    #expect(stub.streamedInstanceCount == 2)
    #expect(dashboard.logPane.currentlyFollowedInstanceID == instance(port: 10350).id)
}

/// The deliberate asymmetry between the two entry points, so the fix above
/// cannot be "simplified" into dropping the guard altogether: while the
/// window is shut, a discovery tick must still start nothing. Only the window
/// becoming visible may start a stream from a standing stop.
@Test @MainActor func discoveryDoesNotRestartTheStreamWhileTheWindowIsClosed() {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350)])

    dashboard.dashboardWindowDidBecomeVisible()
    dashboard.logPane.follow(nil) // window closed
    #expect(stub.streamedInstanceCount == 1)

    // A reconcile tick arriving while the window is shut — `AppDelegate`
    // calls this on every discovery event, open window or not.
    app.sync(with: [instance(port: 10350)])
    dashboard.followSelectedInstanceLogs()

    #expect(stub.streamedInstanceCount == 1)
    #expect(!dashboard.logPane.isFollowingAnInstance)
}

/// Why `show()` goes through `DashboardModel` at all rather than calling
/// `logPane.follow(_:)` itself: the resource scope belongs to the instance it
/// was set on. Closing the window scoped to a resource, having that instance
/// disappear while shut, then reopening must land on the fallback instance
/// with the scope cleared — not showing an empty pane under a stale chip.
@Test @MainActor func reopeningOntoADifferentInstanceClearsTheResourceScope() {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.selectedSidebarID = "port-10350"
    dashboard.dashboardWindowDidBecomeVisible()
    dashboard.selectResource("ai-api")
    #expect(dashboard.logPane.filter.resource == "ai-api")

    dashboard.logPane.follow(nil)           // window closes
    app.sync(with: [instance(port: 10360)]) // 10350 disappears while it is shut
    dashboard.dashboardWindowDidBecomeVisible()

    #expect(dashboard.logPane.currentlyFollowedInstanceID == instance(port: 10360).id)
    #expect(dashboard.selectedResourceName == nil)
    #expect(dashboard.logPane.filter.resource == nil)
}

// MARK: - Log pane resource selection (reuses `selectedResourceName`)

/// Reuses `selectedResourceName` — the same property menu-bar `focus`
/// already sets — rather than adding a second selection concept: selecting a
/// resource in the table filters `logPane.filter` to it.
@Test @MainActor func selectingAResourceFiltersTheLogPaneToIt() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))

    dashboard.selectResource("ai-api")

    #expect(dashboard.selectedResourceName == "ai-api")
    #expect(dashboard.logPane.filter.resource == "ai-api")
}

/// The pane's only "clearable back to all" affordance for this filter:
/// selecting the resource that's already selected clears it, rather than
/// requiring a separate clear control.
@Test @MainActor func selectingTheSameResourceAgainClearsTheSelection() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))

    dashboard.selectResource("ai-api")
    dashboard.selectResource("ai-api")

    #expect(dashboard.selectedResourceName == nil)
    #expect(dashboard.logPane.filter.resource == nil)
}

/// `focus(resource:onInstanceWithPort:)` — the menu bar's jump-to-resource —
/// must filter the log pane too, through the exact same
/// `selectedResourceName` it already sets for the table's highlight. Not a
/// toggle: a menu-bar jump lands on the target even if it happened to
/// already be selected, unlike a table click.
@Test @MainActor func focusingAResourceAlsoFiltersTheLogPaneToIt() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "error", order: 1))

    dashboard.focus(resource: "ai-api", onInstanceWithPort: 10350)

    #expect(dashboard.logPane.filter.resource == "ai-api")

    // Focusing the already-selected resource again must not toggle it off —
    // the trap `selectResource(_:)`'s toggle would fall into here.
    dashboard.focus(resource: "ai-api", onInstanceWithPort: 10350)
    #expect(dashboard.logPane.filter.resource == "ai-api")
}

/// The bug this guards: a resource name selected on one instance carried
/// over to a different instance's differently-named resources would
/// silently filter the new pane down to whatever, usually nothing, happens
/// to share that name — worse than showing every resource's logs.
@Test @MainActor func switchingInstancesClearsTheResourceSelectionAndTheLogFilter() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))

    dashboard.selectResource("ai-api")
    #expect(dashboard.selectedResourceName == "ai-api")

    dashboard.selectedSidebarID = "port-10360"

    #expect(dashboard.selectedResourceName == nil)
    #expect(dashboard.logPane.filter.resource == nil)
}

/// The requirement most likely to be got wrong: a naive "clear the scope"
/// might set `logPane.filter.resource` to `""` rather than `nil`. Per
/// `LogFilter.resource`'s doc comment, `""` means "only tilt-level lines";
/// `nil` means every line. Clearing must land on `nil`.
@Test @MainActor func clearingTheSelectedResourceRestoresTiltLevelLinesToo() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))

    dashboard.logPane.follow(dashboard.selectedInstance)
    dashboard.logPane.receive(line(message: "resource line", resource: "ai-api"))
    dashboard.logPane.receive(line(message: "tilt line", resource: ""))
    dashboard.logPane.refreshIfNeeded()

    dashboard.selectResource("ai-api")
    #expect(dashboard.logPane.filteredLines.map(\.message) == ["resource line"])

    dashboard.clearSelectedResource()

    #expect(dashboard.logPane.filteredLines.map(\.message) == ["resource line", "tilt line"])
}

/// `clearSelectedResource()` must go through `setSelectedResource(_:)`, not
/// write `logPane.filter.resource` on its own — otherwise the table's
/// highlight (driven by `selectedResourceName`) would stay stuck on the
/// resource even after the log pane stopped being scoped to it.
@Test @MainActor func clearingTheSelectedResourceAlsoClearsTheTableHighlight() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))

    dashboard.selectResource("ai-api")
    #expect(dashboard.selectedResourceName == "ai-api")

    dashboard.clearSelectedResource()

    #expect(dashboard.selectedResourceName == nil)
    #expect(dashboard.logPane.filter.resource == nil)
}

/// Select, verify the subset, clear, verify everything (including
/// tilt-level lines and every other resource's) is back exactly as before
/// the scope was ever applied.
@Test @MainActor func scopingAndClearingRoundTrips() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))

    dashboard.logPane.follow(dashboard.selectedInstance)
    dashboard.logPane.receive(line(message: "a", resource: "ai-api"))
    dashboard.logPane.receive(line(message: "b", resource: "auth-svc"))
    dashboard.logPane.receive(line(message: "tilt line", resource: ""))
    dashboard.logPane.refreshIfNeeded()

    let allMessages = dashboard.logPane.filteredLines.map(\.message)
    #expect(allMessages == ["a", "b", "tilt line"])

    dashboard.selectResource("ai-api")
    #expect(dashboard.logPane.filteredLines.map(\.message) == ["a"])

    dashboard.clearSelectedResource()
    #expect(dashboard.logPane.filteredLines.map(\.message) == allMessages)
}

// MARK: - Resource scope vs. a fallback instance selection

/// The reviewer's exact scenario: the followed instance disappears from
/// discovery and a different one takes its place as the fallback selection.
/// `selectedSidebarID`'s setter clearing the scope is not enough on its
/// own — this path goes through `followSelectedInstanceLogs()` directly
/// (`AppDelegate.reconcile(with:)`'s real call, reproduced here), never
/// touching the setter at all. A scope left pointed at "ai-api" while the
/// pane re-streams an instance with no such resource renders zero lines
/// under a chip claiming to be scoped — worse than showing everything.
@Test @MainActor func aFallbackInstanceSelectionClearsTheResourceScope() {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.selectedSidebarID = "port-10350"
    dashboard.logPane.follow(dashboard.selectedInstance) // simulates the window opening
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))

    dashboard.selectResource("ai-api")
    #expect(dashboard.selectedResourceName == "ai-api")
    #expect(dashboard.logPane.filter.resource == "ai-api")

    // 10350 disappears; 10360 remains and becomes the fallback selection —
    // `reconcile(with:)`'s real sequence: sync first, then re-point the pane.
    app.sync(with: [instance(port: 10360)])
    dashboard.followSelectedInstanceLogs()

    #expect(dashboard.selectedInstance?.webPort == 10360)
    #expect(dashboard.selectedResourceName == nil)
    #expect(dashboard.logPane.filter.resource == nil)
    #expect(stub.mostRecentlyStreamedInstanceID == dashboard.selectedInstance?.id)
}

/// The companion case: a routine discovery tick that resolves back to the
/// exact same instance (nothing actually changed) must not disturb a scope
/// the user set on purpose. Clearing on every reconcile, rather than only
/// when the followed instance genuinely changes, would be its own bug —
/// the scope would never survive long enough to be useful.
@Test @MainActor func aNoOpReconcileLeavesTheResourceScopeIntact() {
    let stub = StubLogStreaming()
    let (dashboard, app, _) = makeDashboard(logStreaming: stub)
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.selectedSidebarID = "port-10350"
    dashboard.logPane.follow(dashboard.selectedInstance)
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))

    dashboard.selectResource("ai-api")
    #expect(dashboard.selectedResourceName == "ai-api")

    // Same instances, same identities — a routine discovery tick with
    // nothing actually different about the followed instance.
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.followSelectedInstanceLogs()

    #expect(dashboard.selectedInstance?.webPort == 10350)
    #expect(dashboard.selectedResourceName == "ai-api")
    #expect(dashboard.logPane.filter.resource == "ai-api")
}

// MARK: - Log pane resource health (live, not cached)
//
// `DashboardModel.resourceHealthByName` reads `visibleResources` directly on
// every access — no snapshot anywhere, unlike the `LogPaneModel`-held cache
// this replaced (that cache only refreshed inside
// `followSelectedInstanceLogs()`, so a resource's health changing between
// reconciles — the exact case this feature exists to catch — left it
// stale). `res(...)` (used below) is `ResourceGroupTests.swift`'s shared
// `Resource` builder, not private to that file — see its own doc comment.

@Test @MainActor func resourceHealthByNameReflectsTheSelectedInstancesResources() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "error", order: 1))

    #expect(dashboard.resourceHealthByName["ai-api"] == .error)
}

/// The regression guard for the staleness the cached design had: a
/// resource's health changing — no instance re-selection, no discovery
/// reconcile, no explicit refresh call of any kind — must be visible
/// immediately, because `resourceHealthByName` recomputes from the live
/// `InstanceStore` on every access. Proven against the old
/// `logPane.health(forResource:)` cache in this same file's history before
/// this fix: that version failed here, returning the stale `.ok`.
@Test @MainActor func resourceHealthByNameReflectsAChangeWithNoReselectionOrReconcile() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].apply(event(name: "ai-api", update: "ok", order: 1))
    dashboard.selectedSidebarID = "port-10350"
    dashboard.logPane.follow(dashboard.selectedInstance)
    #expect(dashboard.resourceHealthByName["ai-api"] == .ok)

    // Health changes in place — same call `InstanceSupervisor` makes on
    // every watch tick — with nothing else touched: no `selectedSidebarID`
    // write, no `followSelectedInstanceLogs()` call.
    app.stores[0].apply(event(name: "ai-api", update: "error", order: 1))

    #expect(dashboard.resourceHealthByName["ai-api"] == .error)
}

/// A resource that goes away between two selections (the whole instance is
/// replaced by a fallback, same setup `aFallbackInstanceSelectionClearsTheResourceScope`
/// above uses) must stop resolving to its old health rather than lingering
/// — `resourceHealthByName` is recomputed from `visibleResources`, which is
/// itself scoped to whichever instance is currently selected, so there is no
/// separate "replace" step to get wrong.
@Test @MainActor func switchingInstancesChangesTheResourceHealthMap() {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.selectedSidebarID = "port-10350"
    app.stores[0].apply(event(name: "ai-api", update: "error", order: 1))
    #expect(dashboard.resourceHealthByName["ai-api"] == .error)

    app.stores[1].apply(event(name: "auth-svc", update: "ok", order: 1))
    dashboard.selectedSidebarID = "port-10360"

    #expect(dashboard.resourceHealthByName["ai-api"] == nil)
    #expect(dashboard.resourceHealthByName["auth-svc"] == .ok)
}

/// `resourceHealthByName`'s underlying builder must not trap the way
/// `Dictionary(uniqueKeysWithValues:)` would on a duplicate name.
/// `InstanceStore.byName` already keys resources by name, so
/// `visibleResources` cannot itself carry a duplicate today — this calls the
/// actual production builder directly with a hand-built duplicate list
/// instead, so the defensive choice is proven independent of that invariant
/// holding. `reduce(into:)`'s plain assignment means the later entry wins,
/// so this also pins that specific behaviour down rather than merely
/// "doesn't crash".
@Test func healthMapToleratesDuplicateResourceNames() {
    let map = DashboardModel.healthMap(from: [res("ai-api", health: .error), res("ai-api", health: .ok)])
    #expect(map["ai-api"] == .ok)
}

@Test func healthForResourceNamedLooksUpAKnownResourcesHealth() {
    let map: [String: ResourceHealth] = ["ai-api": .error, "ai-redis": .ok]
    #expect(DashboardModel.health(forResourceNamed: "ai-api", in: map) == .error)
    #expect(DashboardModel.health(forResourceNamed: "ai-redis", in: map) == .ok)
}

@Test func healthForResourceNamedIsNilForTiltLevelLines() {
    // "" is a tilt-level message's resource, not any resource's own name —
    // it must never resolve to a colour, even in the unrealistic case where
    // the map itself somehow holds an entry for "". A test that merely left
    // "" absent from the map would pass on an implementation that forgot the
    // explicit guard entirely (plain dictionary lookup already returns nil
    // for an absent key), so this deliberately puts "" -> .ok in the map and
    // asserts the lookup still refuses to return it.
    let map: [String: ResourceHealth] = ["": .ok, "ai-api": .ok]
    #expect(DashboardModel.health(forResourceNamed: "", in: map) == nil)
}

@Test func healthForResourceNamedIsNilForAnUnknownResource() {
    // Evicted, renamed, or a line that arrived before the resource list did
    // — none of those should crash or default to healthy.
    let map: [String: ResourceHealth] = ["ai-api": .ok]
    #expect(DashboardModel.health(forResourceNamed: "does-not-exist", in: map) == nil)
}

// MARK: - Relink (Feature 1)

@MainActor private func brokenRecentItem(
    _ dashboard: DashboardModel, _ recents: RecentsStore,
    port: Int = 10361, path: String = "/private/tmp/detachtest/Tiltfile"
) throws -> SidebarItem {
    recents.remember(instance(port: port))
    recents.updateResolvedName("detachtest", tiltfilePath: path, forPort: port)
    let item = try #require(dashboard.sections.first { $0.section == .recent }?.items.first)
    return item
}

@Test @MainActor func relinkingARecentRowUpdatesItsStoredPath() throws {
    let (dashboard, _, recents) = makeDashboard()
    let item = try brokenRecentItem(dashboard, recents)

    #expect(dashboard.relink(item: item, toTiltfilePath: "/Users/r/detachtest/Tiltfile") == .relinked)
    #expect(recents.projects.first?.tiltfilePath == "/Users/r/detachtest/Tiltfile")
}

/// `InstanceAliases` is keyed on the Tiltfile path. Rewriting the path
/// without moving the alias orphans it: the project silently reverts to its
/// resolved or `tilt-<port>` name, and the user's rename looks like it was
/// thrown away by an unrelated action.
///
/// Mutating `relink` to drop the alias-move block fails this.
@Test @MainActor func relinkingCarriesAnExistingRenameAcrossToTheNewPath() throws {
    let (dashboard, app, recents) = makeDashboard()
    let item = try brokenRecentItem(dashboard, recents, path: "/gone/Tiltfile")
    app.aliases.setAlias("My Nickname", forTiltfilePath: "/gone/Tiltfile")

    #expect(dashboard.relink(item: item, toTiltfilePath: "/found/Tiltfile") == .relinked)
    #expect(app.aliases.alias(forTiltfilePath: "/found/Tiltfile") == "My Nickname")
    #expect(app.aliases.alias(forTiltfilePath: "/gone/Tiltfile") == nil, "the old key must not linger")
    #expect(dashboard.sections.first { $0.section == .recent }?.items.first?.title == "My Nickname")
}

/// A project with no rename must not acquire one, and must not have some
/// other project's alias attached to it by a careless copy.
@Test @MainActor func relinkingWithoutARenameSetsNoAlias() throws {
    let (dashboard, app, recents) = makeDashboard()
    let item = try brokenRecentItem(dashboard, recents, path: "/gone/Tiltfile")

    #expect(dashboard.relink(item: item, toTiltfilePath: "/found/Tiltfile") == .relinked)
    #expect(app.aliases.alias(forTiltfilePath: "/found/Tiltfile") == nil)
}

/// The silent-no-op guard at the level the view actually calls. Every
/// non-`relinked` outcome must carry a message the caller can put in an
/// alert — an outcome that reports failure with nothing to say is a silent
/// no-op wearing a return value.
@Test @MainActor func everyRelinkFailureOutcomeCarriesAMessageAndEveryOutcomeIsUnambiguous() {
    for outcome in [DashboardModel.RelinkOutcome.relinked, .notARecentEntry, .entryNoLongerExists] {
        if outcome == .relinked {
            #expect(outcome.didChangeAnything)
            #expect(outcome.failureMessage == nil)
        } else {
            #expect(outcome.didChangeAnything == false)
            let message = outcome.failureMessage ?? ""
            #expect(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }
}

/// The entry can vanish while the modal open panel is up — the Recent list is
/// live and the panel stays open for as long as the user takes to choose.
@Test @MainActor func relinkingAnEntryThatVanishedWhileThePanelWasOpenReportsIt() throws {
    let (dashboard, _, recents) = makeDashboard()
    let item = try brokenRecentItem(dashboard, recents)
    recents.remove(id: item.id)

    #expect(dashboard.relink(item: item, toTiltfilePath: "/found/Tiltfile") == .entryNoLongerExists)
}

@Test @MainActor func aRunningProjectCannotBeRelinked() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].setResolvedTiltfile(path: "/there/Tiltfile", projectName: "p")
    let item = try #require(dashboard.sections.first { $0.section == .running }?.items.first)

    #expect(dashboard.relink(item: item, toTiltfilePath: "/elsewhere/Tiltfile") == .notARecentEntry)
}

/// Relinking must re-ask the filesystem about the chosen path even when the
/// cache already holds an answer for it — the answer it holds is by
/// definition from BEFORE the user went and fixed things.
///
/// The scenario, which is the ordinary one: the row is broken, the user
/// creates the Tiltfile at the location they intend, then relinks to it. The
/// cache has already probed that location (a moment earlier it did not exist)
/// and, with a TTL measured in seconds-to-minutes, would keep saying so — so
/// the row the user just repaired keeps its red indicator, and the obvious
/// conclusion is that Relink did not work.
///
/// Note what a weaker version of this test would miss: relinking to a path
/// the cache has NEVER seen needs no invalidation at all, because
/// `exists(atPath:)` schedules a probe for any unknown path on the next read.
/// A test that relinked to an unseen path would pass with the invalidation
/// deleted. Mutating `relink` to drop `tiltfileExistence.invalidate(_:)`
/// fails THIS one.
@Test @MainActor func relinkingReprobesTheChosenPathEvenWhenTheCacheAlreadyHasAStaleAnswer() async throws {
    let app = AppModel(settings: SettingsStore(defaults: TestUserDefaults.fresh()),
                       aliasesDefaults: TestUserDefaults.fresh())
    let recents = RecentsStore(storage: InMemoryRecentsStorage())
    let disk = FakeDisk(missing: ["/gone/Tiltfile", "/found/Tiltfile"])
    // A long TTL so this asserts the invalidation rather than a timer that
    // would have expired on its own.
    let existence = TiltfileExistenceCache(probe: disk.probe, ttl: 3_600,
                                           now: { Date(timeIntervalSince1970: 0) })
    let dashboard = DashboardModel(appModel: app, recents: recents, tiltfileExistence: existence)

    let item = try brokenRecentItem(dashboard, recents, path: "/gone/Tiltfile")
    // The intended destination has already been probed, and did not exist.
    _ = existence.exists(atPath: "/found/Tiltfile")
    await existence.settle()
    #expect(existence.exists(atPath: "/found/Tiltfile") == false)
    #expect(dashboard.sections.first { $0.section == .recent }?.items.first?.isBroken == true)

    // The user creates the file, then relinks to it.
    disk.setMissing([])
    #expect(dashboard.relink(item: item, toTiltfilePath: "/found/Tiltfile") == .relinked)
    await existence.settle()

    #expect(dashboard.sections.first { $0.section == .recent }?.items.first?.isBroken == false)
}

/// A relink to a location that is ALSO missing must not read as repaired.
/// Without the invalidation the newly chosen path is simply unknown, and an
/// unknown path answers optimistically — so the row would go quiet and claim
/// to be fixed.
@Test @MainActor func relinkingToAPathThatIsAlsoMissingStillReadsAsBroken() async throws {
    let app = AppModel(settings: SettingsStore(defaults: TestUserDefaults.fresh()),
                       aliasesDefaults: TestUserDefaults.fresh())
    let recents = RecentsStore(storage: InMemoryRecentsStorage())
    let disk = FakeDisk(missing: ["/gone/Tiltfile", "/also-gone/Tiltfile"])
    let existence = TiltfileExistenceCache(probe: disk.probe, ttl: 3_600,
                                           now: { Date(timeIntervalSince1970: 0) })
    let dashboard = DashboardModel(appModel: app, recents: recents, tiltfileExistence: existence)

    let item = try brokenRecentItem(dashboard, recents, path: "/gone/Tiltfile")
    #expect(dashboard.relink(item: item, toTiltfilePath: "/also-gone/Tiltfile") == .relinked)
    await existence.settle()

    #expect(dashboard.sections.first { $0.section == .recent }?.items.first?.isBroken == true)
}

/// A filesystem whose contents the test can change mid-run, for asserting
/// that a cached answer is re-asked rather than latched.
private final class FakeDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var missing: Set<String>

    init(missing: Set<String>) { self.missing = missing }
    func setMissing(_ newValue: Set<String>) { lock.withLock { missing = newValue } }

    var probe: TiltfileExistenceCache.Probe {
        { [self] path in lock.withLock { !missing.contains(path) } }
    }
}

// MARK: - Remove from Recent

@Test @MainActor func removingARecentRowTakesItOutOfTheSidebar() throws {
    let (dashboard, _, recents) = makeDashboard()
    let item = try brokenRecentItem(dashboard, recents)

    #expect(dashboard.removeFromRecent(item: item))
    #expect(dashboard.sections.first { $0.section == .recent }?.items.isEmpty == true)
    #expect(recents.projects.isEmpty)
}

@Test @MainActor func removingARowThatIsAlreadyGoneReportsFailure() throws {
    let (dashboard, _, recents) = makeDashboard()
    let item = try brokenRecentItem(dashboard, recents)
    #expect(dashboard.removeFromRecent(item: item))
    #expect(dashboard.removeFromRecent(item: item) == false)
}

@Test @MainActor func aRunningProjectCannotBeRemovedFromRecent() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    let item = try #require(dashboard.sections.first { $0.section == .running }?.items.first)
    #expect(dashboard.removeFromRecent(item: item) == false)
}

// MARK: - The sidebar's existence checks are cheap (Feature 1, performance)

/// THE count that proves the main-actor `stat` per entry per rebuild is gone,
/// measured through the production path — `DashboardModel.sections`, which a
/// SwiftUI body re-reads many times per render.
///
/// Before the fix this was 3 projects x 40 rebuilds = 120 blocking `stat`
/// calls on the main actor. Mutating `DashboardModel.sections` to pass
/// `{ FileManager.default.fileExists(atPath: $0) }` instead of the cache
/// makes this report 120.
@Test @MainActor func fortySidebarRebuildsStatEachProjectOnce() async throws {
    let app = AppModel(settings: SettingsStore(defaults: TestUserDefaults.fresh()),
                       aliasesDefaults: TestUserDefaults.fresh())
    let recents = RecentsStore(storage: InMemoryRecentsStorage())
    let probes = ProbeCounter()
    let existence = TiltfileExistenceCache(probe: probes.probe, ttl: 3_600,
                                           now: { Date(timeIntervalSince1970: 0) })
    let dashboard = DashboardModel(appModel: app, recents: recents, tiltfileExistence: existence)

    for port in [10350, 10360, 10370] {
        recents.remember(instance(port: port))
        recents.updateResolvedName("p\(port)", tiltfilePath: "/p\(port)/Tiltfile", forPort: port)
    }

    for _ in 0..<40 { _ = dashboard.sections }
    await existence.settle()
    for _ in 0..<40 { _ = dashboard.sections }
    await existence.settle()

    #expect(dashboard.sections.first { $0.section == .recent }?.items.count == 3)
    #expect(probes.count == 3)
}

/// Counts existence probes across threads.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    var probe: TiltfileExistenceCache.Probe {
        { [self] _ in
            lock.withLock { _count += 1 }
            return true
        }
    }
}

// MARK: - The header's Tiltfile path (Feature 2)

@Test @MainActor func theHeaderPathOfARunningProjectIsItsResolvedTiltfile() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    app.stores[0].setResolvedTiltfile(path: "/Users/dev/src/northwind/Tiltfile", projectName: "northwind")

    #expect(dashboard.selectedTiltfilePath == "/Users/dev/src/northwind/Tiltfile")
}

@Test @MainActor func theHeaderPathOfAStoppedProjectComesFromItsRecentEntry() throws {
    let (dashboard, _, recents) = makeDashboard()
    _ = try brokenRecentItem(dashboard, recents, path: "/private/tmp/detachtest/Tiltfile")

    #expect(dashboard.selectedTiltfilePath == "/private/tmp/detachtest/Tiltfile")
}

/// "Render nothing rather than an empty gap or a placeholder that looks like
/// a path." `nil`, never `""` — an empty string would reserve a line's height
/// and draw a blank where a path belongs.
///
/// Mutating `selectedTiltfilePath` to `selectedItem?.tiltfilePath ?? ""`
/// fails this.
@Test @MainActor func theHeaderPathIsNilRatherThanEmptyWhenThereIsNothingToShow() throws {
    let (empty, _, _) = makeDashboard()
    #expect(empty.selectedTiltfilePath == nil, "nothing selected at all")

    let (dashboard, _, recents) = makeDashboard()
    recents.remember(instance(port: 10395)) // remembered, but no path ever recorded
    #expect(dashboard.selectedItem != nil)
    #expect(dashboard.selectedTiltfilePath == nil)
}

/// A running project whose Tiltfile key has not resolved yet also has nothing
/// truthful to show.
@Test @MainActor func theHeaderPathIsNilBeforeARunningProjectsPathResolves() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350)])
    #expect(dashboard.selectedItem?.isRunning == true)
    #expect(dashboard.selectedTiltfilePath == nil)
}

/// The header must follow the selection rather than latch onto the first
/// project it saw — two projects with different paths is the case that
/// distinguishes those.
@Test @MainActor func theHeaderPathFollowsTheSelection() throws {
    let (dashboard, app, _) = makeDashboard()
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    app.stores[0].setResolvedTiltfile(path: "/a/Tiltfile", projectName: "a")
    app.stores[1].setResolvedTiltfile(path: "/b/Tiltfile", projectName: "b")

    dashboard.selectedSidebarID = "port-10360"
    #expect(dashboard.selectedTiltfilePath == "/b/Tiltfile")
    dashboard.selectedSidebarID = "port-10350"
    #expect(dashboard.selectedTiltfilePath == "/a/Tiltfile")
}

// MARK: - Log scrollback preference

@Test @MainActor func theLogPaneIsBuiltWithTheStoredScrollbackSetting() {
    // Not with `LogPaneModel.defaultCapacity`, which is 5,000 and is only the
    // fallback for a pane built without one. A dashboard that ignored the
    // stored preference until something happened to change it would give the
    // user 5,000 lines on every launch however they had set it.
    let app = AppModel(
        settings: SettingsStore(defaults: TestUserDefaults.fresh()),
        aliasesDefaults: TestUserDefaults.fresh()
    )
    app.settings.logScrollback = .lines500
    let dashboard = DashboardModel(
        appModel: app, recents: RecentsStore(storage: InMemoryRecentsStorage())
    )
    #expect(dashboard.logPane.capacity == 500)
}

@Test @MainActor func applyingTheScrollbackSettingResizesTheLivePane() {
    // `SettingsStore` is a separate `@Observable`, so nothing here can react
    // to the picker moving on its own — `LogPaneView` pushes it in. This is
    // the decision half of that push, which is why it lives in `FulcrumKit`
    // where it can be tested without SwiftUI.
    let (dashboard, app, _) = makeDashboard(logStreaming: StubLogStreaming())
    #expect(dashboard.logPane.capacity == 1_000, "the shipped default")
    for i in 1...1_000 { dashboard.logPane.receive(line(message: "m\(i)")) }
    dashboard.logPane.refreshIfNeeded()

    app.settings.logScrollback = .lines500
    dashboard.applyLogScrollbackSetting()

    #expect(dashboard.logPane.capacity == 500)
    #expect(dashboard.logPane.lines.count == 500)
    #expect(dashboard.logPane.lines.first?.line.message == "m501", "the newest 500 survive")
}

@Test @MainActor func applyingAnUnchangedScrollbackSettingIsANoOp() {
    // `LogPaneView` calls this on every `onChange`, `initial: true` included,
    // so the common case is "nothing changed". It must not republish the
    // buffer there — see
    // `setCapacityToTheCapacityAlreadyInForceDoesNotRepublish`.
    let (dashboard, _, _) = makeDashboard(logStreaming: StubLogStreaming())
    for i in 1...100 { dashboard.logPane.receive(line(message: "m\(i)")) }
    dashboard.logPane.refreshIfNeeded()
    _ = dashboard.logPane.rows
    let recomputesBefore = dashboard.logPane.rowsRecomputeCount

    dashboard.applyLogScrollbackSetting()

    _ = dashboard.logPane.rows
    #expect(dashboard.logPane.capacity == 1_000)
    #expect(dashboard.logPane.rowsRecomputeCount == recomputesBefore)
}
