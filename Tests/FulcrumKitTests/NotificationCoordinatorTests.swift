import Foundation
import Testing
@testable import FulcrumKit

/// `NotificationCoordinator` is everything about notification *delivery* that
/// can be tested without `UserNotifications`: when the permission prompt is
/// allowed to appear, what gets posted and what doesn't, and where a click
/// lands. The app-side conformer (`NotificationPresenter`) is deliberately a
/// straight translation of these calls into `UNUserNotificationCenter`, so
/// the rules live here where a test can reach them.
///
/// Decisions pinned down by these tests:
/// - The permission prompt is NEVER requested until a notification would
///   genuinely be delivered right now. Not at launch, not on an observation
///   that produces nothing.
/// - A notification that triggered the prompt is held, not dropped: granting
///   permission delivers it. Otherwise the very failure that justified asking
///   is the one the user never sees.
/// - The policy is re-read from `SettingsStore` on every observation, so a
///   change in Settings takes effect immediately — without resetting the
///   `FailureNotifier` baseline underneath it.
/// - Whether the user is looking at the failing instance right now decides
///   suppression; whether the app is merely running does not.

/// Records what the app side would have been asked to do. Stands in for
/// `NotificationPresenter`, which cannot exist in this target.
@MainActor
final class RecordingDeliverer: NotificationDelivering {
    var authorization: NotificationAuthorization
    private(set) var delivered: [FailureNotification] = []
    private(set) var authorizationRequests = 0
    private var pendingCompletion: (@MainActor (NotificationAuthorization) -> Void)?

    init(authorization: NotificationAuthorization = .authorized) {
        self.authorization = authorization
    }

    func requestAuthorization(_ completion: @escaping @MainActor (NotificationAuthorization) -> Void) {
        authorizationRequests += 1
        pendingCompletion = completion
    }

    /// Stands in for the user answering the system prompt. Updates the cached
    /// authorization first, exactly as the real presenter does, so anything
    /// the completion triggers sees the settled answer.
    func answerPrompt(_ answer: NotificationAuthorization) {
        authorization = answer
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(answer)
    }

    func deliver(_ notification: FailureNotification) {
        delivered.append(notification)
    }
}

/// Records where a notification click was routed, so a test can assert it
/// reaches the app's existing focus route with the right target.
@MainActor
final class RecordingFocus {
    private(set) var focused: [NotificationTarget] = []

    var action: @MainActor (String, Int) -> Void {
        { [self] name, port in focused.append(NotificationTarget(resourceName: name, port: port)) }
    }
}

@MainActor
private func makeCoordinator(
    policy: NotificationPolicy = .failures,
    deliverer: RecordingDeliverer,
    focus: RecordingFocus = RecordingFocus(),
    isViewingInstance: @escaping @MainActor (Int) -> Bool = { _ in false }
) -> (NotificationCoordinator, SettingsStore) {
    let settings = SettingsStore(defaults: TestUserDefaults.fresh())
    settings.notificationPolicy = policy
    let coordinator = NotificationCoordinator(
        settings: settings,
        delivering: deliverer,
        isViewingInstance: isViewingInstance,
        focusResource: focus.action
    )
    return (coordinator, settings)
}

// MARK: - When the prompt is allowed to appear

@Test @MainActor func nothingWorthSayingMeansNoPermissionPrompt() {
    // THE authorization-timing test. A prompt the user cannot connect to
    // anything they did is how an app gets denied permanently, and denial is
    // unrecoverable from inside the app. The first observation of an instance
    // is a baseline (see `FailureNotifier`) — even if every resource in it is
    // already red, there is nothing to say, so there must be no prompt.
    let deliverer = RecordingDeliverer(authorization: .notDetermined)
    let (coordinator, _) = makeCoordinator(deliverer: deliverer)

    coordinator.observe(resources: [res("a", health: .error), res("b", health: .error)],
                        forPort: 10360, instanceName: "lab")
    // A second observation with no transition in it is equally uneventful.
    coordinator.observe(resources: [res("a", health: .error), res("b", health: .error)],
                        forPort: 10360, instanceName: "lab")

    #expect(deliverer.authorizationRequests == 0)
    #expect(deliverer.delivered.isEmpty)
}

@Test @MainActor func theFirstRealFailurePromptsAndThenDeliversOnceGranted() {
    // The prompt lands at the one moment it is self-explanatory: something
    // just broke and Fulcrum has something to tell the user. The notification
    // that caused the prompt must survive it — dropping it would mean the
    // failure that justified asking is the one failure never shown.
    let deliverer = RecordingDeliverer(authorization: .notDetermined)
    let (coordinator, _) = makeCoordinator(deliverer: deliverer)

    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")

    #expect(deliverer.authorizationRequests == 1)
    #expect(deliverer.delivered.isEmpty, "nothing can be posted before the user answers")

    deliverer.answerPrompt(.authorized)
    #expect(deliverer.delivered.map(\.resourceName) == ["a"])
    #expect(deliverer.delivered.map(\.kind) == [.failed])
}

@Test @MainActor func aRefusedPromptDeliversNothingAndIsNeverAskedAgain() {
    // macOS only ever shows the prompt once; asking again is a no-op that
    // silently reports the stored answer. Re-requesting on every failure
    // would be pointless work — and the queued notification must be dropped,
    // not held forever waiting for permission that is not coming.
    let deliverer = RecordingDeliverer(authorization: .notDetermined)
    let (coordinator, _) = makeCoordinator(deliverer: deliverer)

    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")
    deliverer.answerPrompt(.denied)
    #expect(deliverer.delivered.isEmpty)

    // A second, genuinely new failure while denied.
    coordinator.observe(resources: [res("b", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("b", health: .error)], forPort: 10360, instanceName: "lab")
    #expect(deliverer.authorizationRequests == 1)
    #expect(deliverer.delivered.isEmpty)
}

@Test @MainActor func failuresArrivingWhileThePromptIsUnansweredDoNotStackMorePrompts() {
    // The prompt is modal to the user, not to the app: watch ticks keep
    // arriving while it sits there. The failures must be SEPARATE ticks, each
    // newsworthy in its own right — a single tick where two resources fail
    // together would raise one request no matter what, and would not exercise
    // the in-flight guard at all.
    let deliverer = RecordingDeliverer(authorization: .notDetermined)
    let (coordinator, _) = makeCoordinator(deliverer: deliverer)

    coordinator.observe(resources: [res("a", health: .ok), res("b", health: .ok)],
                        forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error), res("b", health: .ok)],
                        forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error), res("b", health: .error)],
                        forPort: 10360, instanceName: "lab")

    #expect(deliverer.authorizationRequests == 1, "the second failure must not raise a second prompt")

    // And everything that accumulated behind the prompt is posted, not just
    // whichever one happened to raise it.
    deliverer.answerPrompt(.authorized)
    #expect(deliverer.delivered.map(\.resourceName).sorted() == ["a", "b"])
}

@Test @MainActor func turningThePolicyOnAsksForPermissionThereAndThen() {
    // The other legitimate prompt moment: the user just deliberately switched
    // notifications on in Settings, which is as clear an opt-in gesture as
    // exists. Asking here means the permission is already settled before the
    // first failure, rather than the prompt ambushing them later.
    let deliverer = RecordingDeliverer(authorization: .notDetermined)
    let (coordinator, settings) = makeCoordinator(policy: .off, deliverer: deliverer)

    settings.notificationPolicy = .failures
    coordinator.policyDidChange()

    #expect(deliverer.authorizationRequests == 1)
}

@Test @MainActor func turningThePolicyOffDoesNotAskForPermission() {
    let deliverer = RecordingDeliverer(authorization: .notDetermined)
    let (coordinator, settings) = makeCoordinator(policy: .failures, deliverer: deliverer)

    settings.notificationPolicy = .off
    coordinator.policyDidChange()

    #expect(deliverer.authorizationRequests == 0)
}

@Test @MainActor func anAlreadyAnsweredPermissionIsNotReRequestedOnAPolicyChange() {
    let granted = RecordingDeliverer(authorization: .authorized)
    let (grantedCoordinator, grantedSettings) = makeCoordinator(policy: .off, deliverer: granted)
    grantedSettings.notificationPolicy = .failures
    grantedCoordinator.policyDidChange()
    #expect(granted.authorizationRequests == 0)

    let refused = RecordingDeliverer(authorization: .denied)
    let (refusedCoordinator, refusedSettings) = makeCoordinator(policy: .off, deliverer: refused)
    refusedSettings.notificationPolicy = .failures
    refusedCoordinator.policyDidChange()
    #expect(refused.authorizationRequests == 0)
}

// MARK: - What gets delivered

@Test @MainActor func aResourceTurningRedIsDeliveredExactlyOnce() {
    // The watch re-observes every few seconds; a still-red resource must not
    // re-post on every tick.
    let deliverer = RecordingDeliverer()
    let (coordinator, _) = makeCoordinator(deliverer: deliverer)

    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")

    #expect(deliverer.delivered.count == 1)
    #expect(deliverer.delivered.first?.resourceName == "a")
    #expect(deliverer.delivered.first?.port == 10360)
    #expect(deliverer.delivered.first?.instanceName == "lab")
}

@Test @MainActor func aPolicyChangeTakesEffectOnTheVeryNextObservation() {
    // Deliberately does NOT call `policyDidChange()`. That method exists to
    // settle the system permission at an opt-in moment; delivery must not
    // depend on it, because the Settings picker writes straight through its
    // binding to `SettingsStore` and any code path that forgets to ring the
    // bell would otherwise leave the setting silently inert until relaunch.
    // That is the exact silent no-op this project keeps re-shipping.
    let deliverer = RecordingDeliverer()
    let (coordinator, settings) = makeCoordinator(policy: .off, deliverer: deliverer)

    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")
    #expect(deliverer.delivered.isEmpty, "muted while off")

    settings.notificationPolicy = .failures

    coordinator.observe(resources: [res("b", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("b", health: .error)], forPort: 10360, instanceName: "lab")
    #expect(deliverer.delivered.map(\.resourceName) == ["b"])
}

@Test @MainActor func settlingThePermissionOnAPolicyChangeDoesNotReArmTheBaseline() {
    // The other half: `policyDidChange()` must not rebuild the notifier.
    // Rebuilding would reset every baseline, so the resource that was already
    // red before the change would read as a brand-new failure on the next
    // tick — a notification storm triggered by opening Settings.
    let deliverer = RecordingDeliverer()
    let (coordinator, settings) = makeCoordinator(policy: .off, deliverer: deliverer)

    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")

    settings.notificationPolicy = .failuresAndRecoveries
    coordinator.policyDidChange()

    // "a" is still red and the notifier still knows it — not a transition.
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")
    #expect(deliverer.delivered.isEmpty)

    // ...and its recovery is a real transition off that retained `.error`,
    // which only a preserved baseline can see.
    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10360, instanceName: "lab")
    #expect(deliverer.delivered.map(\.kind) == [.recovered])
}

@Test @MainActor func nothingIsDeliveredForTheInstanceTheUserIsWatching() {
    // Deliberate: a banner about the row the user is looking at, in the
    // window they are looking at, interrupts to say what the screen already
    // says. Narrow on purpose — this is "the dashboard is frontmost AND
    // showing this project", not merely "the app is running".
    let deliverer = RecordingDeliverer()
    let focus = RecordingFocus()
    let (coordinator, _) = makeCoordinator(
        deliverer: deliverer, focus: focus, isViewingInstance: { $0 == 10360 }
    )

    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10360, instanceName: "watched")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "watched")
    #expect(deliverer.delivered.isEmpty)

    // A different project failing behind that window still notifies — the
    // user is not looking at THAT one.
    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10350, instanceName: "other")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10350, instanceName: "other")
    #expect(deliverer.delivered.map(\.port) == [10350])
}

@Test @MainActor func aSuppressedFailureNeverAsksForPermissionEither() {
    // The suppression decision has to happen before the authorization one, or
    // watching a project that breaks would raise a permission prompt for a
    // notification that was never going to be posted.
    let deliverer = RecordingDeliverer(authorization: .notDetermined)
    let (coordinator, _) = makeCoordinator(deliverer: deliverer, isViewingInstance: { _ in true })

    coordinator.observe(resources: [res("a", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("a", health: .error)], forPort: 10360, instanceName: "lab")

    #expect(deliverer.authorizationRequests == 0)
    #expect(deliverer.delivered.isEmpty)
}

// MARK: - Where a click lands

@Test @MainActor func aClickRoutesToTheResourceAndPortItNamed() {
    // Must go through the app's existing focus route (`DashboardModel.focus`
    // via `AppDelegate`), the same one the status menu's failure rows use. A
    // second "which resource is selected" concept has already caused a real
    // bug on this project.
    let deliverer = RecordingDeliverer()
    let focus = RecordingFocus()
    let (coordinator, _) = makeCoordinator(deliverer: deliverer, focus: focus)

    coordinator.handleActivation(NotificationTarget(resourceName: "json-invalid", port: 10360))

    #expect(focus.focused == [NotificationTarget(resourceName: "json-invalid", port: 10360)])
}

@Test @MainActor func aDeliveredNotificationCarriesEnoughToRouteItsOwnClick() throws {
    // End to end within this target: what was delivered must round-trip
    // through the property-list payload the system hands back on click, and
    // arrive at the same resource. A notification whose click cannot be
    // resolved is a banner that goes nowhere.
    let deliverer = RecordingDeliverer()
    let focus = RecordingFocus()
    let (coordinator, _) = makeCoordinator(deliverer: deliverer, focus: focus)

    coordinator.observe(resources: [res("json-invalid", health: .ok)], forPort: 10360, instanceName: "lab")
    coordinator.observe(resources: [res("json-invalid", health: .error)], forPort: 10360, instanceName: "lab")

    let posted = try #require(deliverer.delivered.first)
    let userInfo = NotificationTarget(posted).userInfo
    let target = try #require(NotificationTarget(userInfo: userInfo))
    coordinator.handleActivation(target)

    #expect(focus.focused == [NotificationTarget(resourceName: "json-invalid", port: 10360)])
}
