import Foundation
import Testing
@testable import FulcrumKit

/// What the user actually reads on the banner, and what the banner has to
/// carry so that clicking it can go somewhere. Both live in `FulcrumKit`
/// rather than in the app's `NotificationPresenter` so they are reachable by
/// a test at all — the app target has no test bundle.

@Test func theBodyNamesBothTheResourceAndTheProject() {
    // Fulcrum watches several projects at once, and duplicate resource names
    // across projects are ordinary (two projects both running a "web"). A
    // banner saying only "web failed" is not actionable — the user cannot
    // tell which project broke without opening something, which is exactly
    // what the notification exists to save them.
    let content = NotificationContent(FailureNotification(
        instanceName: "northwind", port: 10350, resourceName: "api", kind: .failed
    ))
    #expect(content.body.contains("api"))
    #expect(content.body.contains("northwind"))
}

@Test func aFailureAndARecoveryReadDifferently() {
    let failure = NotificationContent(FailureNotification(
        instanceName: "lab", port: 10360, resourceName: "json-invalid", kind: .failed
    ))
    let recovery = NotificationContent(FailureNotification(
        instanceName: "lab", port: 10360, resourceName: "json-invalid", kind: .recovered
    ))
    #expect(failure.title != recovery.title)
    #expect(!failure.title.isEmpty)
    #expect(!recovery.title.isEmpty)
}

@Test func aRecoveryReplacesItsOwnFailureRatherThanStackingBesideIt() {
    // Same identifier means the system REPLACES the existing entry. Without
    // this, Notification Center accumulates a "json-invalid failed" that is
    // no longer true sitting directly above "json-invalid recovered".
    let failure = NotificationContent(FailureNotification(
        instanceName: "lab", port: 10360, resourceName: "json-invalid", kind: .failed
    ))
    let recovery = NotificationContent(FailureNotification(
        instanceName: "lab", port: 10360, resourceName: "json-invalid", kind: .recovered
    ))
    #expect(failure.identifier == recovery.identifier)
}

@Test func twoProjectsWithTheSameResourceNameGetSeparateIdentifiers() {
    // The counterpart: identifiers must not collide across instances, or one
    // project's failure banner silently replaces another's.
    let first = NotificationContent(FailureNotification(
        instanceName: "p1", port: 10350, resourceName: "web", kind: .failed
    ))
    let second = NotificationContent(FailureNotification(
        instanceName: "p2", port: 10360, resourceName: "web", kind: .failed
    ))
    #expect(first.identifier != second.identifier)
}

@Test func aTargetSurvivesTheUserInfoRoundTrip() {
    // `userInfo` is a property-list dictionary handed back by the system on
    // click, long after the process may have restarted. Anything that does
    // not survive the round trip is a click that lands nowhere.
    let target = NotificationTarget(resourceName: "json-invalid", port: 10360)
    #expect(NotificationTarget(userInfo: target.userInfo) == target)
}

@Test func aResourceNameThatLooksLikeAPortDoesNotConfuseTheRoundTrip() {
    // Both fields are strings in a property list; a positional or
    // loosely-keyed encoding would let a resource literally named "10360"
    // route to the wrong place.
    let target = NotificationTarget(resourceName: "10360", port: 10350)
    #expect(NotificationTarget(userInfo: target.userInfo) == target)
}

@Test func aForeignOrMalformedPayloadYieldsNoTarget() throws {
    // Better to do nothing than to focus a guessed resource.
    //
    // The half-populated cases are built by REMOVING keys from a payload that
    // genuinely parses, and the key names are discovered from that payload
    // rather than spelled out here. Hand-written literals would pass for the
    // wrong reason the moment the real keys were renamed — the whole
    // dictionary would be foreign, and this would look like it was testing a
    // missing field while actually testing a missing everything.
    let valid = NotificationTarget(resourceName: "a", port: 10360).userInfo
    #expect(NotificationTarget(userInfo: valid) != nil, "the payload these mutations start from must itself parse")
    let resourceKey = try #require(valid.first(where: { $0.value == "a" })?.key)
    let portKey = try #require(valid.first(where: { $0.value == "10360" })?.key)

    var withoutPort = valid
    withoutPort[portKey] = nil
    var withoutResource = valid
    withoutResource[resourceKey] = nil
    var unparseablePort = valid
    unparseablePort[portKey] = "not-a-port"

    #expect(NotificationTarget(userInfo: [:]) == nil)
    #expect(NotificationTarget(userInfo: ["something": "else"]) == nil)
    #expect(NotificationTarget(userInfo: withoutPort) == nil)
    #expect(NotificationTarget(userInfo: withoutResource) == nil)
    #expect(NotificationTarget(userInfo: unparseablePort) == nil)
}

// MARK: - The Settings pane's honesty about denial

@Test func aDeniedPermissionIsStatedInSettingsWithAWayToFixIt() {
    // THE denial test. A user who has denied Fulcrum in System Settings and
    // then picks "Failures only" has done everything right and will still get
    // nothing. A picker that silently does nothing is this project's single
    // most recurring failure mode; the pane has to say so and offer the door.
    for policy in [NotificationPolicy.failures, .failuresAndRecoveries] {
        let notice = NotificationSettingsNotice.notice(policy: policy, authorization: .denied)
        #expect(notice?.offersSystemSettings == true)
        #expect(notice?.message.isEmpty == false)
    }
}

@Test func aWorkingChannelSaysNothingAtAll() {
    for policy in NotificationPolicy.allCases {
        #expect(NotificationSettingsNotice.notice(policy: policy, authorization: .authorized) == nil)
    }
}

@Test func policyOffNeedsNoNoticeEvenWhenDenied() {
    // Nothing is being suppressed against the user's wishes here — they
    // turned it off themselves. Warning about a permission that is not being
    // used is noise, and noise is what trains people to ignore the pane.
    for authorization in NotificationAuthorization.allCases {
        #expect(NotificationSettingsNotice.notice(policy: .off, authorization: authorization) == nil)
    }
}

@Test func aNotYetRequestedPermissionIsExplainedButOffersNoButton() {
    // Honest without being alarming: nothing is broken, and there is nothing
    // in System Settings to change yet — the entry does not even exist there
    // until Fulcrum has asked once.
    let notice = NotificationSettingsNotice.notice(policy: .failures, authorization: .notDetermined)
    #expect(notice?.message.isEmpty == false)
    #expect(notice?.offersSystemSettings == false)
}
