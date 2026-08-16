import Foundation
import Testing
@testable import FulcrumKit

private func instance(port: Int, token: String = "t") -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)",
        port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data(),
        token: token
    ))
}

private func event(name: String, update: String, order: Int = 1) -> WatchEvent {
    WatchEvent(type: .added, object: UIResource(
        metadata: .init(name: name, resourceVersion: "1"),
        status: .init(updateStatus: update, runtimeStatus: "ok",
                      disableStatus: .init(state: "Enabled"),
                      buildHistory: nil, pendingBuildSince: nil, order: order)
    ))
}

@MainActor
private func makeModel() -> AppModel {
    AppModel(
        settings: SettingsStore(defaults: TestUserDefaults.fresh()),
        aliasesDefaults: TestUserDefaults.fresh()
    )
}

@Test @MainActor func syncCreatesStoresForNewInstances() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350), instance(port: 10360)])
    #expect(model.stores.count == 2)
}

@Test @MainActor func syncPreservesExistingStoreAndItsData() {
    let model = makeModel()
    let live = instance(port: 10350)
    model.sync(with: [live])
    model.stores[0].apply(event(name: "web", update: "ok"))

    model.sync(with: [live, instance(port: 10360)])
    let preserved = model.stores.first { $0.instance.id == live.id }
    #expect(preserved?.resources.count == 1)
}

@Test @MainActor func syncDropsInstancesNoLongerPresent() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350), instance(port: 10360)])
    model.sync(with: [instance(port: 10350)])
    #expect(model.stores.count == 1)
    #expect(model.stores[0].instance.webPort == 10350)
}

@Test @MainActor func restartOnSamePortReplacesTheStore() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350, token: "old")])
    model.stores[0].apply(event(name: "web", update: "ok"))

    model.sync(with: [instance(port: 10350, token: "new")])
    #expect(model.stores.count == 1)
    #expect(model.stores[0].resources.isEmpty, "a regenerated token means a new instance")
}

@Test @MainActor func worstHealthSpansAllInstances() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350), instance(port: 10360)])
    model.stores[0].apply(event(name: "a", update: "ok"))
    model.stores[1].apply(event(name: "b", update: "error"))
    #expect(model.worstHealth == .error)
}

@Test @MainActor func failingResourcesAreCollectedAcrossInstances() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350), instance(port: 10360)])
    model.stores[0].apply(event(name: "a", update: "error"))
    model.stores[1].apply(event(name: "b", update: "error"))
    #expect(model.allFailingResources.map(\.resource.name).sorted() == ["a", "b"])
}

@Test @MainActor func iconShowsIdleWhenNothingIsRunning() {
    let model = makeModel()
    #expect(model.iconState.assetName == MenuBarAsset.idle)
    #expect(model.iconState.isAnimating == false)
    #expect(model.statusLine == "No tilt instances running")
}

@Test @MainActor func iconReflectsErrorInWorstStateMode() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "a", update: "error"))
    #expect(model.iconState.assetName == MenuBarAsset.offPlumb)
}

/// The mutation this guards against: collapsing `worstHealth == nil` into the
/// same `default:` arm as `.ok`/`.disabled`, which is what shipped before this
/// fix. An instance discovered but never yet listed has no assessed health —
/// it must not render the same green "all healthy" mark as one confirmed OK.
@Test @MainActor func iconShowsUnsettledWhenNoInstanceHasBeenAssessedYet() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    // No resources ever applied: worstHealth is nil, not `.ok`.
    #expect(model.stores[0].worstHealth == nil)
    #expect(model.iconState.assetName == MenuBarAsset.unsettled)
}

@Test @MainActor func iconAnimatesWhileBuilding() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "a", update: "in_progress"))
    #expect(model.iconState.isAnimating)
}

@Test @MainActor func buildActivityModeIgnoresErrors() {
    let model = makeModel()
    model.settings.iconMode = .buildActivity
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "a", update: "error"))
    #expect(model.iconState.assetName == MenuBarAsset.level)
    #expect(model.iconState.isAnimating == false)
}

@Test @MainActor func instanceCountModeBadgesTheCount() {
    let model = makeModel()
    model.settings.iconMode = .instanceCount
    model.sync(with: [instance(port: 10350), instance(port: 10360)])
    #expect(model.iconState.badge == "2")
}

@Test @MainActor func healthWithCountsBadgesFailingOverTotal() {
    let model = makeModel()
    model.settings.iconMode = .healthWithCounts
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "a", update: "error", order: 1))
    model.stores[0].apply(event(name: "b", update: "ok", order: 2))
    #expect(model.iconState.badge == "1/2")
}

@Test @MainActor func statusLineNamesTheFailureCount() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350), instance(port: 10360)])
    model.stores[0].apply(event(name: "a", update: "error"))
    model.stores[1].apply(event(name: "b", update: "ok"))
    #expect(model.statusLine == "1 of 2 projects have errors")
}

/// tilt's kubeconfig is written non-atomically; a read caught mid-write can
/// surface a stale context alongside a fresh one that resolves to the same
/// `(server, token)`. `sync` must tolerate a repeated id on its own input —
/// and, critically, must never let a repeated id persist into `stores`,
/// because `stores` feeds `sync`'s own dictionary build on the *next* call.
/// Before the fix, a duplicate surviving into `stores` made the following
/// `sync(with:)` call — regardless of what it's passed — trap.
@Test @MainActor func duplicateIDInDiscoveredListDoesNotCrashNextSync() {
    let model = makeModel()
    let a = instance(port: 10350)
    model.sync(with: [a, a])
    #expect(model.stores.count == 1)

    // The regression: this second call rebuilds `existing` from `stores`.
    model.sync(with: [a])
    #expect(model.stores.count == 1)
}

@Test @MainActor func duplicateIDPreservesExistingStoreData() {
    let model = makeModel()
    let a = instance(port: 10350)
    model.sync(with: [a])
    model.stores[0].apply(event(name: "web", update: "ok"))

    model.sync(with: [a, a])
    #expect(model.stores.count == 1)
    #expect(model.stores[0].resources.count == 1)
}
