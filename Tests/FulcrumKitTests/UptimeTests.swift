import Foundation
import Testing
@testable import FulcrumKit

private func uiResource(
    name: String = "x",
    runtimeStatus: String? = "ok",
    conditions: [UIResource.Condition] = []
) -> UIResource {
    UIResource(
        metadata: .init(name: name, resourceVersion: "1", labels: nil),
        status: .init(
            updateStatus: nil,
            runtimeStatus: runtimeStatus,
            disableStatus: nil,
            buildHistory: nil,
            pendingBuildSince: nil,
            order: nil,
            specs: nil,
            waiting: nil,
            endpointLinks: nil,
            conditions: conditions
        )
    )
}

private func condition(_ type: String, status: String, time: String) -> UIResource.Condition {
    .init(type: type, status: status, lastTransitionTime: time, reason: nil)
}

private let readyTimeText = "2026-08-10T18:07:43.743635Z"
private let readyTimeParsed = try! Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    .parse(readyTimeText)

@Test func readySinceComesFromTheReadyConditionNotUpToDate() {
    // UpToDate and Ready deliberately carry DIFFERENT timestamps here — if
    // the implementation read UpToDate instead of Ready (or vice versa via
    // some accidental fallback), this is the only shape of test that would
    // actually catch it. A fixture where both share one timestamp cannot
    // discriminate between the two.
    let r = Resource(uiResource: uiResource(conditions: [
        condition("UpToDate", status: "True", time: "2026-08-10T14:00:09.298740Z"),
        condition("Ready", status: "True", time: readyTimeText),
    ]))
    #expect(r.readySince == readyTimeParsed)
}

@Test func aResourceWithNoRuntimeHasNoUptime() {
    // runtimeStatus == "not_applicable" -> readySince is nil even though a
    // Ready condition exists with a real timestamp: (Tiltfile) and one-shot
    // local_resource commands have no runtime to be "up".
    let r = Resource(uiResource: uiResource(runtimeStatus: "not_applicable", conditions: [
        condition("Ready", status: "True", time: readyTimeText),
    ]))
    #expect(r.readySince == nil)
}

@Test func aNotReadyResourceHasNoUptime() {
    // Ready status "False" -> nil, not a duration since it last succeeded.
    let r = Resource(uiResource: uiResource(conditions: [
        condition("Ready", status: "False", time: readyTimeText),
    ]))
    #expect(r.readySince == nil)
}

@Test func aResourceWithNoReadyConditionHasNoUptime() {
    let r = Resource(uiResource: uiResource(conditions: [
        condition("UpToDate", status: "True", time: readyTimeText),
    ]))
    #expect(r.readySince == nil)
}

@Test func uptimeFormatsAtHumanScales() {
    #expect(Uptime.format(45) == "45s")
    #expect(Uptime.format(3_600) == "1h 0m")
    #expect(Uptime.format(90_061) == "1d 1h")
}
