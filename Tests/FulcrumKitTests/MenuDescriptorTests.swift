import Foundation
import Testing
@testable import FulcrumKit

private func instance(port: Int) -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data(), token: "t\(port)"
    ))
}

private func event(name: String, update: String, order: Int, group: String? = nil, disabled: Bool = false) -> WatchEvent {
    WatchEvent(type: .added, object: UIResource(
        metadata: .init(name: name, resourceVersion: "1", labels: group.map { [$0: $0] }),
        status: .init(updateStatus: update, runtimeStatus: "ok",
                      disableStatus: .init(state: disabled ? "Disabled" : "Enabled"),
                      buildHistory: nil, pendingBuildSince: nil, order: order)
    ))
}

@MainActor
private func makeDashboard(for model: AppModel) -> DashboardModel {
    let recents = RecentsStore(storage: InMemoryRecentsStorage())
    return DashboardModel(appModel: model, recents: recents)
}

@MainActor
private func makeModel() -> AppModel {
    AppModel(
        settings: SettingsStore(defaults: TestUserDefaults.fresh()),
        aliasesDefaults: TestUserDefaults.fresh()
    )
}

private func failureNames(_ items: [MenuDescriptor.Item]) -> [String] {
    items.compactMap { if case let .failure(_, _, name) = $0 { name } else { nil } }
}

@Test @MainActor func autoHidesFailuresWhenEverythingIsHealthy() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "web", update: "ok", order: 1))

    let items = MenuDescriptor.build(from: model)
    #expect(failureNames(items).isEmpty)
}

@Test @MainActor func autoShowsFailuresWhenSomethingIsFailing() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "web", update: "error", order: 1))

    #expect(failureNames(MenuDescriptor.build(from: model)) == ["web"])
}

@Test @MainActor func neverSuppressesFailuresEvenWhenFailing() {
    let model = makeModel()
    model.settings.failuresInMenu = .never
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "web", update: "error", order: 1))

    #expect(failureNames(MenuDescriptor.build(from: model)).isEmpty)
}

@Test @MainActor func failuresAreCappedAtFive() {
    let model = makeModel()
    model.settings.failuresInMenu = .always
    model.sync(with: [instance(port: 10350)])
    for index in 1...8 {
        model.stores[0].apply(event(name: "r\(index)", update: "error", order: index))
    }

    let items = MenuDescriptor.build(from: model)
    #expect(failureNames(items).count == 5)
    #expect(items.contains { if case let .status(text) = $0 { text == "3 more…" } else { false } })
}

@Test @MainActor func exactlyFiveFailuresShowNoOverflowRow() {
    let model = makeModel()
    model.settings.failuresInMenu = .always
    model.sync(with: [instance(port: 10350)])
    for index in 1...5 {
        model.stores[0].apply(event(name: "r\(index)", update: "error", order: index))
    }

    let items = MenuDescriptor.build(from: model)
    #expect(failureNames(items).count == 5)
    #expect(!items.contains { if case let .status(text) = $0 { text.hasSuffix("more…") } else { false } })
}

@Test @MainActor func exactlySixFailuresShowOneMoreRow() {
    let model = makeModel()
    model.settings.failuresInMenu = .always
    model.sync(with: [instance(port: 10350)])
    for index in 1...6 {
        model.stores[0].apply(event(name: "r\(index)", update: "error", order: index))
    }

    let items = MenuDescriptor.build(from: model)
    #expect(failureNames(items).count == 5)
    #expect(items.contains { if case let .status(text) = $0 { text == "1 more…" } else { false } })
}

/// "tilt not installed" and "tilt installed, nothing running" are distinct
/// states with distinct remedies — conflating them would tell a user who
/// already has tilt to go install it. This is the not-installed one: it must
/// say so, and it must not offer "Open Tiltfile…" as something that can
/// actually succeed, since there is no tilt to launch it with.
@Test @MainActor func theMenuExplainsWhenTiltIsNotInstalled() {
    let model = makeModel()
    model.tiltInstalled = false

    let items = MenuDescriptor.build(from: model)
    #expect(items.contains(.status("tilt isn't installed — get it from tilt.dev, then relaunch Fulcrum.")))

    guard case let .openTiltfile(reason) = items.first(where: {
        if case .openTiltfile = $0 { true } else { false }
    }) else {
        Issue.record("expected an openTiltfile item")
        return
    }
    // Same explanation `ResourceActionCoordinator`/`InstanceActionCoordinator`
    // give their own disabled controls, so every surface that turns itself
    // off for this reason says the same thing.
    #expect(reason == "tilt was not found. Install it, or set FULCRUM_TILT_PATH, then relaunch Fulcrum.")
}

/// The other of the two: tilt IS installed, there is just nothing running
/// yet. The remedy here is real — "Open Tiltfile…" already exists — so this
/// state must point at it, not invent a second entry point.
@Test @MainActor func theMenuOffersToOpenATiltfileWhenNothingIsRunning() {
    let model = makeModel()
    // tiltInstalled defaults true; stores is empty.

    let items = MenuDescriptor.build(from: model)
    #expect(items.contains(.status("Nothing running yet — use “Open Tiltfile…” below to start a project.")))

    guard case let .openTiltfile(reason) = items.first(where: {
        if case .openTiltfile = $0 { true } else { false }
    }) else {
        Issue.record("expected an openTiltfile item")
        return
    }
    #expect(reason == nil)
}

/// Once anything is running there is something to look at, so neither the
/// not-installed nor the nothing-running hint applies — even (as tested
/// here) in the contradictory case where `tiltInstalled` is somehow still
/// `false`: a live instance is proof enough on its own, and showing an
/// "install tilt" message above a running project would just be confusing.
@Test @MainActor func aRunningInstanceSuppressesBothMessages() {
    let model = makeModel()
    model.tiltInstalled = false
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "web", update: "ok", order: 1))

    let items = MenuDescriptor.build(from: model)
    #expect(!items.contains {
        if case let .status(text) = $0 {
            text.contains("isn't installed") || text.contains("Nothing running yet")
        } else {
            false
        }
    })
}

@Test @MainActor func alwaysIncludesTheStandardTail() {
    let model = makeModel()
    let items = MenuDescriptor.build(from: model)
    #expect(items.contains { if case .openDashboard = $0 { true } else { false } })
    #expect(items.contains { if case .openTiltfile = $0 { true } else { false } })
    #expect(items.contains { if case .settings = $0 { true } else { false } })
    #expect(items.contains { if case .quit = $0 { true } else { false } })
}

/// The status menu is the always-available surface (Fulcrum's main menu bar
/// only exists while the dashboard window is open) — this guards against
/// `openTiltfile` regressing into a File-menu-only command by asserting it
/// is present in the plain `MenuDescriptor.build(from:)` output with no
/// window involved at all.
@Test @MainActor func openTiltfileAppearsEvenWithNothingRunning() {
    let items = MenuDescriptor.build(from: makeModel())
    #expect(items.contains { if case .openTiltfile = $0 { true } else { false } })
}

@Test @MainActor func firstItemIsAlwaysTheStatusLine() {
    let model = makeModel()
    let items = MenuDescriptor.build(from: model)
    guard case let .status(text) = items.first else {
        Issue.record("expected a status item first")
        return
    }
    #expect(text == "No tilt instances running")
}

@Test @MainActor func instanceRowsSummariseResourceCounts() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.live)
    model.stores[0].apply(event(name: "a", update: "ok", order: 1))
    model.stores[0].apply(event(name: "b", update: "error", order: 2))

    let summaries: [String] = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(summaries == ["1 failing"])
}

@Test @MainActor func healthyInstanceSummarySaysOK() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.live)
    model.stores[0].apply(event(name: "a", update: "ok", order: 1))

    let summaries: [String] = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(summaries == ["1 ok"])
}

@Test @MainActor func connectingInstanceSummarySaysConnecting() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    // Freshly synced store: connection defaults to `.connecting` and no
    // resources have ever been listed.

    let summaries: [String] = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(summaries == ["connecting…"])
}

@Test @MainActor func degradedInstanceWithResourcesAppendsReconnecting() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.live)
    model.stores[0].apply(event(name: "a", update: "ok", order: 1))
    model.stores[0].setConnection(.degraded)

    let summaries: [String] = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(summaries == ["1 ok · reconnecting…"])
}

@Test @MainActor func degradedInstanceWithFailuresAppendsReconnecting() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.live)
    model.stores[0].apply(event(name: "a", update: "error", order: 1))
    model.stores[0].setConnection(.degraded)

    let summaries: [String] = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(summaries == ["1 failing · reconnecting…"])
}

/// The mutation this guards against: dropping the connection dimension from
/// `summary(for:)` and falling back to the bare resource-count logic. That
/// mutant would render this case as `"0 ok"` — a confident, false-healthy
/// claim about an instance that has never once been successfully contacted.
/// It must instead say it is not connected.
@Test @MainActor func degradedInstanceWithNoResourcesNeverShowsBareZeroOK() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.degraded)

    let summaries: [String] = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(summaries == ["reconnecting…"])
    #expect(!summaries.contains("0 ok"))
}

@Test @MainActor func goneConnectionIsTreatedAsDegraded() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.live)
    model.stores[0].apply(event(name: "a", update: "ok", order: 1))
    model.stores[0].setConnection(.gone)

    let summaries: [String] = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(summaries == ["1 ok · reconnecting…"])
}

@Test @MainActor func unassessedInstanceHealthIsNilNotOK() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    // No resources ever applied: worstHealth is nil.

    let healths: [ResourceHealth?] = MenuDescriptor.build(from: model).compactMap { item in
        if case let .instance(_, _, _, health, _) = item { Optional(health) } else { nil }
    }
    #expect(healths == [nil])
}

private func instanceGroups(_ items: [MenuDescriptor.Item]) -> [ResourceGroup]? {
    guard case let .instance(_, _, _, _, groups) = items.first(where: \.isInstance) else { return nil }
    return groups
}

@Test @MainActor func eachRunningInstanceCarriesItsGroupsAsASubmenu() throws {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    model.stores[0].apply(event(name: "auth-svc", update: "ok", order: 1, group: "auth"))

    let groups = try #require(instanceGroups(MenuDescriptor.build(from: model)))
    #expect(groups.map(\.name) == ["ai", "auth"])
}

@Test @MainActor func aGroupSubmenuListsItsResourcesInTiltOrder() throws {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    // Applied out of tilt order; the group must still list them by `order`.
    model.stores[0].apply(event(name: "ai-worker", update: "ok", order: 3, group: "ai"))
    model.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    model.stores[0].apply(event(name: "ai-redis", update: "ok", order: 2, group: "ai"))

    let groups = try #require(instanceGroups(MenuDescriptor.build(from: model)))
    let ai = try #require(groups.first { $0.name == "ai" })
    #expect(ai.resources.map(\.name) == ["ai-api", "ai-redis", "ai-worker"])
}

/// A connecting instance has zero resources — an empty submenu would be a
/// dead end the user can open onto nothing. The descriptor must hand the
/// controller an empty `groups` array so it can render the row plainly
/// instead of attaching a pointless submenu.
@Test @MainActor func anInstanceWithNoResourcesYetStillRendersWithoutAnEmptySubmenu() throws {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    // Freshly synced: connection defaults to `.connecting`, no resources ever applied.

    let groups = try #require(instanceGroups(MenuDescriptor.build(from: model)))
    #expect(groups.isEmpty)
}

/// Compares against a live `DashboardModel.visibleGroups`, not a second call
/// to `ResourceGroup.group` — otherwise this only proves the production code
/// agrees with itself, and would still pass if the dashboard's own grouping
/// broke.
///
/// The dashboard is put in the state that shows everything it has (*Show
/// disabled* on, nothing typed), because that is the view the menu is defined
/// to equal: the menu always reports the instance's true totals, disabled
/// included. See `MenuDescriptor.instanceGroups(for:)`. The fixture keeps a
/// disabled resource because that is where the surfaces diverged in practice —
/// with *Show disabled* on the strip and headers read `disabled=1`, and the
/// menu read `disabled=0` over a shorter list.
@Test @MainActor func groupSummariesInTheMenuMatchTheDashboardShowingEverything() throws {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    model.stores[0].apply(event(name: "ai-worker", update: "error", order: 2, group: "ai"))
    model.stores[0].apply(event(name: "ai-batch", update: "ok", order: 3, group: "ai", disabled: true))

    let dashboard = makeDashboard(for: model)
    dashboard.selectedSidebarID = "port-10350"
    dashboard.filter.showDisabled = true

    let groups = try #require(instanceGroups(MenuDescriptor.build(from: model)))
    let menuAI = try #require(groups.first { $0.name == "ai" })
    let dashboardAI = try #require(dashboard.visibleGroups.first { $0.name == "ai" })

    #expect(menuAI.resources.map(\.name) == dashboardAI.resources.map(\.name))
    #expect(menuAI.summary == dashboardAI.summary)
    #expect(menuAI.summary.total == 3)
    #expect(menuAI.summary.error == 1)
    #expect(menuAI.summary.disabled == 1)
    // The disabled resource is listed, not merely counted: the menu is the
    // only way to reach one without first knowing to turn the filter on.
    #expect(menuAI.resources.map(\.name).contains("ai-batch"))
}

/// The cross-surface test the `⊘` term's existence depends on. It walks the
/// REAL menu path (`MenuDescriptor.build` → the `.instance` row's `groups` →
/// each group's `summary`, which is what `MenuBarController.groupSummaryText`
/// renders) and the REAL dashboard path (`DashboardModel.selectedSummary` and
/// `visibleGroups`, which is what the status strip and the group headers
/// render), on one `AppModel`, and requires every field to agree. Recomputing
/// the same expression twice would prove nothing; these are two independently
/// written derivations that disagreed in production.
///
/// Fails against the pre-fix code, which derived the menu from a plain
/// `ResourceFilter()`: measured 3 enabled + 2 disabled gave `disabled=2
/// total=5` on the dashboard and `disabled=0 total=3` in the menu.
@Test @MainActor func theMenusCountsMatchTheDashboardShowingEverything() throws {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.live)
    model.stores[0].apply(event(name: "ai-api", update: "error", order: 1, group: "ai"))
    model.stores[0].apply(event(name: "ai-worker", update: "pending", order: 2, group: "ai"))
    model.stores[0].apply(event(name: "ai-batch", update: "ok", order: 3, group: "ai", disabled: true))
    model.stores[0].apply(event(name: "web", update: "ok", order: 4, group: "web"))
    model.stores[0].apply(event(name: "web-db", update: "ok", order: 5, group: "web", disabled: true))

    let dashboard = makeDashboard(for: model)
    dashboard.selectedSidebarID = "port-10350"
    dashboard.filter.showDisabled = true

    let menu = try #require(instanceGroups(MenuDescriptor.build(from: model))).map(\.summary)
    let strip = try #require(dashboard.selectedSummary)
    let headers = dashboard.visibleGroups.map(\.summary)

    #expect(menu.reduce(0) { $0 + $1.total } == strip.total)
    #expect(menu.reduce(0) { $0 + $1.error } == strip.error)
    #expect(menu.reduce(0) { $0 + $1.pending } == strip.pending)
    #expect(menu.reduce(0) { $0 + $1.healthy } == strip.healthy)
    #expect(menu.reduce(0) { $0 + $1.disabled } == strip.disabled)
    // Group for group, not just in aggregate — a menu that lost one disabled
    // resource and gained another would still sum correctly.
    #expect(menu == headers)
    // The numbers themselves, so a fix that made both surfaces equally wrong
    // (both dropping disabled resources) does not pass either.
    #expect(strip.total == 5)
    #expect(strip.disabled == 2)
    #expect(strip.error == 1)
    #expect(strip.pending == 1)
    #expect(strip.healthy == 1)
}

/// The menu is built from the instance, not from whatever state a dashboard
/// window happens to be left in — it has no filter bar and could not explain a
/// number that moved for reasons invisible in the menu. This is the guard on
/// the decision recorded in `MenuDescriptor.instanceGroups(for:)`: a future
/// "just read `dashboard.filter`" would satisfy the test above and fail here.
@Test @MainActor func theMenuIgnoresWhateverFilterTheDashboardIsLeftIn() throws {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.live)
    model.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    model.stores[0].apply(event(name: "ai-batch", update: "ok", order: 2, group: "ai", disabled: true))

    let dashboard = makeDashboard(for: model)
    dashboard.selectedSidebarID = "port-10350"
    dashboard.filter.showDisabled = true
    let showingEverything = try #require(instanceGroups(MenuDescriptor.build(from: model)))

    dashboard.filter.showDisabled = false
    dashboard.filter.query = "nothing matches this"
    dashboard.toggleCollapse("ai")

    #expect(try #require(instanceGroups(MenuDescriptor.build(from: model))) == showingEverything)
    #expect(dashboard.visibleGroups.isEmpty, "the dashboard really was filtered down to nothing")
}

/// The instance row's own summary text is a fourth surface counting the same
/// resources, and its "N ok" must not include ones that are disabled — those
/// are not being assessed, so they are neither failing nor ok. Driven through
/// "Disable All", which is what made this reachable: every resource disabled
/// left the row reading a confident "3 ok".
///
/// Note the submenu is NOT empty afterwards any more — the menu lists disabled
/// resources (see `instanceGroups(for:)`) — so the row and its submenu are
/// checked to agree the other way: `0 ok` over a group reporting `⊘3 ✓0/3`.
@Test @MainActor func theInstanceRowSummaryDoesNotCountDisabledResources() throws {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setConnection(.live)
    model.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai"))
    model.stores[0].apply(event(name: "ai-worker", update: "ok", order: 2, group: "ai"))
    model.stores[0].apply(event(name: "ai-batch", update: "ok", order: 3, group: "ai", disabled: true))

    let summaries = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(summaries == ["2 ok"])

    // Everything disabled: the row must not still claim three healthy
    // resources over a submenu that now has none.
    model.stores[0].apply(event(name: "ai-api", update: "ok", order: 1, group: "ai", disabled: true))
    model.stores[0].apply(event(name: "ai-worker", update: "ok", order: 2, group: "ai", disabled: true))

    let afterDisableAll = MenuDescriptor.build(from: model).compactMap {
        if case let .instance(_, _, summary, _, _) = $0 { summary } else { nil }
    }
    #expect(afterDisableAll == ["0 ok"])

    let groups = try #require(instanceGroups(MenuDescriptor.build(from: model)))
    let ai = try #require(groups.first { $0.name == "ai" })
    #expect(ai.summary.disabled == 3)
    #expect(ai.summary.healthy == 0)
    #expect(ai.summary.total == 3)
}

private func plainResource(name: String, order: Int) -> Resource {
    Resource(uiResource: UIResource(
        metadata: .init(name: name, resourceVersion: "1"),
        status: .init(updateStatus: "ok", runtimeStatus: "ok",
                      disableStatus: .init(state: "Enabled"),
                      buildHistory: nil, pendingBuildSince: nil, order: order)
    ))
}

@Test func aGroupSubmenuUnder50ResourcesShowsNoOverflowRow() {
    var resources: [Resource] = []
    for index in 1...50 { resources.append(plainResource(name: "r\(index)", order: index)) }

    let items = MenuDescriptor.resourceItems(for: resources)
    #expect(items.count == 50)
    #expect(!items.contains { if case .status = $0 { true } else { false } })
}

/// The measured real-world shape (49 resources over 18 groups) never
/// approaches this cap; it exists to guard the pathological single-group
/// case, which must never truncate silently.
@Test func aGroupSubmenuOver50ResourcesIsCappedWithATrailingOverflowRow() {
    var resources: [Resource] = []
    for index in 1...53 { resources.append(plainResource(name: "r\(index)", order: index)) }

    let items = MenuDescriptor.resourceItems(for: resources)
    let resourceItems = items.compactMap { item -> String? in
        if case let .resource(name, _) = item { name } else { nil }
    }
    var expectedNames: [String] = []
    for index in 1...50 { expectedNames.append("r\(index)") }

    #expect(resourceItems.count == 50)
    #expect(resourceItems == expectedNames)
    #expect(items.last == .status("…and 3 more — open the dashboard"))
}
