import Foundation
import Testing
@testable import FulcrumKit

@MainActor
private func makeStore() -> InstanceStore {
    let instance = TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-10350",
        port: 10350,
        server: URL(string: "https://127.0.0.1:55501")!,
        certificateAuthorityPEM: Data(),
        token: "token"
    ))
    return InstanceStore(instance: instance)
}

private func event(_ kind: WatchEvent.Kind, name: String, update: String, order: Int) -> WatchEvent {
    WatchEvent(type: kind, object: UIResource(
        metadata: .init(name: name, resourceVersion: "1"),
        status: .init(updateStatus: update, runtimeStatus: "ok",
                      disableStatus: .init(state: "Enabled"),
                      buildHistory: nil, pendingBuildSince: nil, order: order)
    ))
}

@Test @MainActor func addedEventsInsertResources() {
    let store = makeStore()
    store.apply(event(.added, name: "web", update: "ok", order: 2))
    store.apply(event(.added, name: "api", update: "ok", order: 1))
    #expect(store.resources.map(\.name) == ["api", "web"])
}

@Test @MainActor func modifiedEventReplacesInPlace() {
    let store = makeStore()
    store.apply(event(.added, name: "web", update: "ok", order: 1))
    store.apply(event(.modified, name: "web", update: "error", order: 1))
    #expect(store.resources.count == 1)
    #expect(store.resources.first?.health == .error)
}

@Test @MainActor func deletedEventRemovesResource() {
    let store = makeStore()
    store.apply(event(.added, name: "web", update: "ok", order: 1))
    store.apply(event(.deleted, name: "web", update: "ok", order: 1))
    #expect(store.resources.isEmpty)
}

@Test @MainActor func bookmarkAndErrorEventsAreIgnored() {
    let store = makeStore()
    store.apply(event(.added, name: "web", update: "ok", order: 1))
    store.apply(event(.bookmark, name: "web", update: "error", order: 1))
    store.apply(event(.error, name: "web", update: "error", order: 1))
    #expect(store.resources.first?.health == .ok)
}

@Test @MainActor func worstHealthIsTheMaximum() {
    let store = makeStore()
    store.apply(event(.added, name: "a", update: "ok", order: 1))
    store.apply(event(.added, name: "b", update: "in_progress", order: 2))
    store.apply(event(.added, name: "c", update: "ok", order: 3))
    #expect(store.worstHealth == .building)
}

@Test @MainActor func failingResourcesListsOnlyErrors() {
    let store = makeStore()
    store.apply(event(.added, name: "a", update: "error", order: 1))
    store.apply(event(.added, name: "b", update: "ok", order: 2))
    store.apply(event(.added, name: "c", update: "error", order: 3))
    #expect(store.failingResources.map(\.name) == ["a", "c"])
}

@Test @MainActor func applyListReplacesEntireContents() {
    let store = makeStore()
    store.apply(event(.added, name: "stale", update: "ok", order: 1))
    store.applyList(UIResourceList(
        metadata: .init(resourceVersion: "99"),
        items: [UIResource(metadata: .init(name: "fresh", resourceVersion: "2"),
                           status: .init(updateStatus: "ok", runtimeStatus: "ok",
                                         disableStatus: nil, buildHistory: nil,
                                         pendingBuildSince: nil, order: 1))]
    ))
    #expect(store.resources.map(\.name) == ["fresh"])
    #expect(store.lastResourceVersion == "99")
}

@Test @MainActor func degradedConnectionRetainsResources() {
    let store = makeStore()
    store.apply(event(.added, name: "web", update: "ok", order: 1))
    store.setConnection(.degraded)
    #expect(store.connection == .degraded)
    #expect(store.resources.count == 1, "stale data must survive a dropped watch")
}

@Test @MainActor func startsInConnectingState() {
    #expect(makeStore().connection == .connecting)
}

@Test @MainActor func setResolvedTiltfileSetsBothTheProjectNameAndThePath() {
    let store = makeStore()
    #expect(store.tiltfilePath == nil)

    store.setResolvedTiltfile(path: "/Users/dev/src/northwind/Tiltfile", projectName: "northwind")

    #expect(store.tiltfilePath == "/Users/dev/src/northwind/Tiltfile")
    #expect(store.projectName == "northwind")
    #expect(store.displayName == "northwind")
}

@Test @MainActor func applyListToleratesDuplicateNames() {
    let store = makeStore()
    store.applyList(UIResourceList(
        metadata: .init(resourceVersion: "1"),
        items: [
            UIResource(metadata: .init(name: "web", resourceVersion: "1"),
                       status: .init(updateStatus: "ok", runtimeStatus: "ok",
                                     disableStatus: nil, buildHistory: nil,
                                     pendingBuildSince: nil, order: 1)),
            UIResource(metadata: .init(name: "web", resourceVersion: "2"),
                       status: .init(updateStatus: "error", runtimeStatus: "ok",
                                     disableStatus: nil, buildHistory: nil,
                                     pendingBuildSince: nil, order: 1)),
        ]
    ))
    #expect(store.resources.count == 1)
    #expect(store.resources.first?.health == .error)
}
