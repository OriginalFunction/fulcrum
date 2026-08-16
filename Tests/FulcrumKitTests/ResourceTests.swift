import Foundation
import Testing
@testable import FulcrumKit

/// Builds a `UIResource` stating only the field the test exercises. Defaults
/// mirror an unremarkable, healthy resource with no labels, no blockers, and
/// no endpoints.
private func uiResource(
    name: String,
    labels: [String: String]? = nil,
    waiting: UIResource.Waiting? = nil,
    endpointLinks: [String] = [],
    updateStatus: String? = nil
) -> UIResource {
    UIResource(
        metadata: .init(name: name, resourceVersion: "1", labels: labels),
        status: .init(
            updateStatus: updateStatus,
            runtimeStatus: nil,
            disableStatus: nil,
            buildHistory: nil,
            pendingBuildSince: nil,
            order: nil,
            specs: nil,
            waiting: waiting,
            endpointLinks: endpointLinks.map { .init(url: $0) }
        )
    )
}

@Test func groupComesFromTheSingleMetadataLabel() {
    let r = Resource(uiResource: uiResource(name: "ai-redis", labels: ["ai": "ai"]))
    #expect(r.group == "ai")
}

@Test func aResourceWithNoLabelsHasNoGroup() {
    let r = Resource(uiResource: uiResource(name: "(Tiltfile)", labels: nil))
    #expect(r.group == nil)
}

@Test func groupIsDeterministicWhenMultipleLabelsArePresent() {
    // Not an observed shape, but the mapping must not depend on dictionary
    // iteration order if tilt ever emits more than one label.
    let r = Resource(uiResource: uiResource(name: "x", labels: ["zebra": "zebra", "aardvark": "aardvark"]))
    #expect(r.group == "aardvark")
}

@Test func waitingOnNamesTheBlockingResource() {
    let r = Resource(uiResource: uiResource(
        name: "ai-api",
        waiting: .init(reason: "waiting-for-dep",
                       on: [.init(kind: "UIResource", name: "ai-pdf-image-extractor")])))
    #expect(r.waitingOn == ["ai-pdf-image-extractor"])
    #expect(r.waitingReason == "waiting-for-dep")
}

@Test func aResourceThatIsNotBlockedHasNoWaitingInfo() {
    let r = Resource(uiResource: uiResource(name: "ai-redis"))
    #expect(r.waitingOn.isEmpty)
    #expect(r.waitingReason == nil)
}

@Test func endpointLinksBecomeURLs() {
    let r = Resource(uiResource: uiResource(name: "ai-redis",
                                            endpointLinks: ["http://localhost:6380/"]))
    #expect(r.endpoints == [URL(string: "http://localhost:6380/")!])
}

@Test func anUndecodableEndpointURLIsDroppedNotFatal() {
    let r = Resource(uiResource: uiResource(name: "x", endpointLinks: ["not a url", ""]))
    #expect(r.endpoints.isEmpty)
}

@Test func aResourceWithNoEndpointsHasAnEmptyList() {
    let r = Resource(uiResource: uiResource(name: "x"))
    #expect(r.endpoints.isEmpty)
}

@Test func pendingUpdateStatusIsDistinctFromHealthy() {
    let r = Resource(uiResource: uiResource(name: "x", updateStatus: "pending"))
    #expect(r.health == .pending)
    #expect(r.health != .ok)
}

@Test func okUpdateStatusIsNotPending() {
    let r = Resource(uiResource: uiResource(name: "x", updateStatus: "ok"))
    #expect(r.health != .pending)
}
