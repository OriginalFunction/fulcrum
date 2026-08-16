import Foundation
import Testing
@testable import FulcrumKit

/// `FailureNotifier` is where the notification feature is actually decided:
/// which resource health transitions are newsworthy enough to interrupt the
/// user. Getting the baseline wrong produces either a notification storm at
/// every launch (every already-broken resource fires) or permanent silence
/// after the first real failure (state never resets on recovery).
///
/// Design pinned down by these tests:
/// - Baseline is per (port, resource name), established the first time that
///   key is ever passed to `observe`, however broken it already is. That
///   first observation notifies nothing.
/// - Only `.error` counts as "failing". `.pending` and `.building` are normal
///   transient states, not failures — see `ResourceHealth`'s own comments on
///   why they exist as distinct cases from `.ok`.
/// - Prior health is never pruned when a resource is briefly absent from an
///   observation (renamed/removed then restored): the old value is kept so a
///   `.ok` → (gone) → `.error` sequence still reads as a genuine transition,
///   not a fresh baseline that would swallow the failure silently.

@Test @MainActor func theFirstObservationOfAnInstanceNotifiesNothing() {
    // THE test for this task. On connect, tilt replays current state — a
    // project with three already-broken resources must produce ZERO
    // notifications, or launching the app spams every past failure.
    let notifier = FailureNotifier(policy: .failures)
    let out = notifier.observe(resources: [res("a", health: .error), res("b", health: .error)],
                                forPort: 10350, instanceName: "p")
    #expect(out.isEmpty)
}

@Test @MainActor func aResourceTurningRedAfterTheBaselineNotifies() {
    let notifier = FailureNotifier(policy: .failures)
    _ = notifier.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    let out = notifier.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    #expect(out.count == 1)
    #expect(out.first?.kind == .failed)
    #expect(out.first?.resourceName == "a")
    #expect(out.first?.port == 10350)
    #expect(out.first?.instanceName == "p")
}

@Test @MainActor func aResourceStayingRedDoesNotNotifyAgain() {
    // Observed every few seconds by the watch. Re-notifying would be constant.
    let notifier = FailureNotifier(policy: .failures)
    _ = notifier.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    _ = notifier.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    let out = notifier.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    #expect(out.isEmpty)
}

@Test @MainActor func aBuildingOrPendingResourceIsNeverTreatedAsAFailure() {
    // Neither state is a failure — a resource mid-rebuild or waiting on a
    // dependency is normal, not newsworthy. Only `.error` is.
    let notifier = FailureNotifier(policy: .failuresAndRecoveries)
    _ = notifier.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    let toBuilding = notifier.observe(resources: [res("a", health: .building)], forPort: 10350, instanceName: "p")
    let toPending = notifier.observe(resources: [res("a", health: .pending)], forPort: 10350, instanceName: "p")
    let backToOk = notifier.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    #expect(toBuilding.isEmpty)
    #expect(toPending.isEmpty)
    #expect(backToOk.isEmpty)
}

@Test @MainActor func aResourceRecoveringNotifiesOnlyUnderTheRecoveryPolicy() {
    let failuresOnly = FailureNotifier(policy: .failures)
    _ = failuresOnly.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    _ = failuresOnly.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    let noRecoveryNotice = failuresOnly.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    #expect(noRecoveryNotice.isEmpty)

    let failuresAndRecoveries = FailureNotifier(policy: .failuresAndRecoveries)
    _ = failuresAndRecoveries.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    _ = failuresAndRecoveries.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    let recoveryNotice = failuresAndRecoveries.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    #expect(recoveryNotice.count == 1)
    #expect(recoveryNotice.first?.kind == .recovered)
}

@Test @MainActor func aResourceThatFailsRecoversAndFailsAgainNotifiesTwice() {
    // The state must reset on recovery, or the second real failure is silent —
    // worse than noise, because the user now trusts it.
    let notifier = FailureNotifier(policy: .failures)
    _ = notifier.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    let firstFailure = notifier.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    _ = notifier.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    let secondFailure = notifier.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    #expect(firstFailure.map(\.kind) == [.failed])
    #expect(secondFailure.map(\.kind) == [.failed])
}

@Test @MainActor func policyOffNotifiesNothingEvenOnATransition() {
    let notifier = FailureNotifier(policy: .off)
    _ = notifier.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    let out = notifier.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    #expect(out.isEmpty)
}

@Test @MainActor func eachInstanceKeepsItsOwnBaseline() {
    // Two instances, same resource NAME in both — a failure in one must not
    // suppress or trigger the other. tilt emits duplicate names across
    // instances; that has already caused one bug here.
    //
    // Uses `.failuresAndRecoveries` deliberately: a name-only key would let
    // instance 1's failure poison instance 2's baseline for "web", and the
    // giveaway is a spurious `.recovered` notification on instance 2 even
    // though instance 2's "web" never actually failed. Under `.failures`
    // alone that leak is invisible — the bogus transition it causes is a
    // recovery, which that policy suppresses anyway — so it would not
    // actually exercise the keying this test claims to guard.
    let notifier = FailureNotifier(policy: .failuresAndRecoveries)
    _ = notifier.observe(resources: [res("web", health: .ok)], forPort: 10350, instanceName: "p1")
    _ = notifier.observe(resources: [res("web", health: .ok)], forPort: 10360, instanceName: "p2")

    let firstInstanceFailure = notifier.observe(
        resources: [res("web", health: .error)], forPort: 10350, instanceName: "p1")
    #expect(firstInstanceFailure.count == 1)
    #expect(firstInstanceFailure.first?.port == 10350)

    // The second instance's "web" is still healthy and was never marked
    // failing, so re-observing it as `.ok` is not a transition at all — a
    // name-collapsed key would instead see this as error→ok and wrongly
    // emit `.recovered`.
    let secondInstanceStillOk = notifier.observe(
        resources: [res("web", health: .ok)], forPort: 10360, instanceName: "p2")
    #expect(secondInstanceStillOk.isEmpty)

    // And the second instance can independently fail — it must not be
    // suppressed by the first instance's failure already having fired.
    let secondInstanceFailure = notifier.observe(
        resources: [res("web", health: .error)], forPort: 10360, instanceName: "p2")
    #expect(secondInstanceFailure.count == 1)
    #expect(secondInstanceFailure.first?.port == 10360)
}

@Test @MainActor func aResourceDisappearingAndReturningRedNotifiesOnce() {
    // Renamed or removed from the Tiltfile, then back. Must not double-fire,
    // and must not be silent.
    let notifier = FailureNotifier(policy: .failures)
    _ = notifier.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "p")
    // "a" is gone from this tick's resource list entirely.
    _ = notifier.observe(resources: [], forPort: 10350, instanceName: "p")
    // It returns, already red.
    let out = notifier.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    #expect(out.count == 1)
    #expect(out.first?.kind == .failed)

    // Staying red on the next tick must not fire again.
    let again = notifier.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "p")
    #expect(again.isEmpty)
}
