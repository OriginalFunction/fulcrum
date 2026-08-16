import Testing
@testable import FulcrumKit

private func resource(update: String?, runtime: String?, disabled: Bool = false) -> UIResource {
    UIResource(
        metadata: .init(name: "r", resourceVersion: "1"),
        status: .init(
            updateStatus: update,
            runtimeStatus: runtime,
            disableStatus: disabled ? .init(state: "Disabled") : .init(state: "Enabled"),
            buildHistory: nil,
            pendingBuildSince: nil,
            order: 1
        )
    )
}

@Test func errorInEitherChannelIsError() {
    #expect(Resource(uiResource: resource(update: "error", runtime: "ok")).health == .error)
    #expect(Resource(uiResource: resource(update: "ok", runtime: "error")).health == .error)
}

@Test func inProgressUpdateIsBuilding() {
    #expect(Resource(uiResource: resource(update: "in_progress", runtime: "ok")).health == .building)
}

@Test func pendingInEitherChannelIsPending() {
    #expect(Resource(uiResource: resource(update: "pending", runtime: "ok")).health == .pending)
    #expect(Resource(uiResource: resource(update: "ok", runtime: "pending")).health == .pending)
}

@Test func healthyResourceIsOK() {
    #expect(Resource(uiResource: resource(update: "ok", runtime: "ok")).health == .ok)
    #expect(Resource(uiResource: resource(update: "ok", runtime: "not_applicable")).health == .ok)
    #expect(Resource(uiResource: resource(update: "not_applicable", runtime: "ok")).health == .ok)
}

@Test func disabledOverridesEverythingIncludingError() {
    let disabled = Resource(uiResource: resource(update: "error", runtime: "error", disabled: true))
    #expect(disabled.health == .disabled)
    #expect(disabled.isDisabled)
}

@Test func errorOutranksBuildingWhichOutranksPending() {
    #expect(ResourceHealth.error > .building)
    #expect(ResourceHealth.building > .pending)
    #expect(ResourceHealth.pending > .ok)
    #expect(ResourceHealth.ok > .disabled)
}

@Test func worstOfACollectionIsTheMaximum() {
    let healths: [ResourceHealth] = [.ok, .building, .ok]
    #expect(healths.max() == .building)
}

@Test func missingStatusIsTreatedAsPending() {
    let bare = UIResource(metadata: .init(name: "bare", resourceVersion: nil), status: nil)
    #expect(Resource(uiResource: bare).health == .pending)
}

@Test func unassessedUpdateStatusIsPending() {
    #expect(Resource(uiResource: resource(update: "none", runtime: "ok")).health == .pending)
}

@Test func unassessedRuntimeStatusIsPending() {
    #expect(Resource(uiResource: resource(update: "ok", runtime: "unknown")).health == .pending)
    #expect(Resource(uiResource: resource(update: "ok", runtime: "none")).health == .pending)
}

@Test func notApplicableStaysOK() {
    #expect(Resource(uiResource: resource(update: "not_applicable", runtime: "ok")).health == .ok)
    #expect(Resource(uiResource: resource(update: "ok", runtime: "not_applicable")).health == .ok)
}

@Test func errorBeatsUnassessedRuntime() {
    #expect(Resource(uiResource: resource(update: "error", runtime: "unknown")).health == .error)
}

@Test func eachHealthCaseHasItsOwnLabel() {
    #expect(ResourceHealth.error.label == "error")
    #expect(ResourceHealth.building.label == "building")
    #expect(ResourceHealth.pending.label == "pending")
    #expect(ResourceHealth.ok.label == "healthy")
    #expect(ResourceHealth.disabled.label == "disabled")
}

@Test func aResourcesStatusLabelDescribesItsOwnHealth() {
    let error = Resource(uiResource: resource(update: "error", runtime: "ok"))
    #expect(error.statusLabel == "error")

    let healthy = Resource(uiResource: resource(update: "ok", runtime: "ok"))
    #expect(healthy.statusLabel == "healthy")
}
