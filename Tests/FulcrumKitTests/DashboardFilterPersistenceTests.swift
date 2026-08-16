import Foundation
import Testing
@testable import FulcrumKit

/// The dashboard's two boolean filter toggles ("Alerts on top", "Show
/// disabled") must survive a relaunch; the filter's text `query` and the log
/// pane's `resource` scope must not — see `ResourceFilter`'s and
/// `DashboardModel.filter`'s doc comments for why. This file proves both
/// halves of that split, and that there is exactly one source of truth for
/// the two toggles: `SettingsStore`.
@MainActor
private func makeDashboard(defaults: UserDefaults) -> (DashboardModel, AppModel) {
    let app = AppModel(
        settings: SettingsStore(defaults: defaults),
        aliasesDefaults: TestUserDefaults.fresh()
    )
    let recents = RecentsStore(storage: InMemoryRecentsStorage())
    return (DashboardModel(appModel: app, recents: recents), app)
}

/// The bug report's core claim, made concrete: set both toggles, throw away
/// every in-memory object, and rebuild a whole new `AppModel` /
/// `SettingsStore` / `DashboardModel` chain from the same `UserDefaults`. If
/// the toggles only lived on the discarded `DashboardModel.filter` (the bug
/// as filed — nothing ever read or wrote `SettingsStore.alertsOnTop` /
/// `.showDisabled`), this fails: the rebuilt dashboard reads the fresh
/// `ResourceFilter()` default, `false`, for both.
@Test @MainActor func theTwoFilterToggleSurviveRebuildingTheEntireModelFromTheSameUserDefaults() {
    let defaults = TestUserDefaults.fresh()
    let (dashboard, _) = makeDashboard(defaults: defaults)
    dashboard.filter.alertsOnTop = true
    dashboard.filter.showDisabled = true

    let (rebuilt, _) = makeDashboard(defaults: defaults)

    #expect(rebuilt.filter.alertsOnTop == true)
    #expect(rebuilt.filter.showDisabled == true)
}

/// The other half of the spec: a restored search query would leave a user
/// staring at a filtered table with no memory of why they filtered it, so
/// `query` must NOT come back from a rebuild even though the two booleans do.
@Test @MainActor func theFilterQueryDoesNotSurviveRebuildingTheModel() {
    let defaults = TestUserDefaults.fresh()
    let (dashboard, _) = makeDashboard(defaults: defaults)
    dashboard.filter.query = "auth"
    dashboard.filter.showDisabled = true

    let (rebuilt, _) = makeDashboard(defaults: defaults)

    #expect(rebuilt.filter.query == "")
    // The boolean sitting right next to it in the same struct did persist —
    // proving the query's absence is deliberate, not a rebuild that lost
    // everything.
    #expect(rebuilt.filter.showDisabled == true)
}

/// There must be exactly one source of truth for the two toggles, not two
/// copies a future change could forget to keep in step (the failure mode
/// this project has already paid for twice — see `DashboardModel.filter`'s
/// doc comment). Proven in both directions: writing through the model is
/// visible on settings with no sync call in between, and writing through
/// settings directly is visible through the model the same way.
@Test @MainActor func mutatingEitherTheModelOrSettingsIsImmediatelyVisibleThroughTheOther() {
    let (dashboard, app) = makeDashboard(defaults: TestUserDefaults.fresh())

    dashboard.filter.showDisabled = true
    #expect(app.settings.showDisabled == true)

    app.settings.alertsOnTop = true
    #expect(dashboard.filter.alertsOnTop == true)
}
