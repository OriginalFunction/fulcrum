import Foundation
import Testing
@testable import FulcrumKit

private func instance(webPort: Int, token: String = "t") -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(webPort)",
        port: webPort,
        server: URL(string: "https://127.0.0.1:\(webPort + 45000)")!,
        certificateAuthorityPEM: Data(),
        token: token
    ))
}

private let binary = URL(filePath: "/opt/homebrew/bin/tilt")

@Test(.timeLimit(.minutes(1))) @MainActor func aTriggeredResourceIsInFlightUntilItCompletes() async {
    let runner = GatedCommandRunner()
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    #expect(!coordinator.isInFlight("ai-redis"))

    let task = Task { await coordinator.trigger("ai-redis", on: instance(webPort: 10350)) }
    await runner.waitForInvocation(count: 1)

    #expect(coordinator.isInFlight("ai-redis"))

    await runner.gate.release("ai-redis")
    await task.value

    #expect(!coordinator.isInFlight("ai-redis"))
}

/// The requirement that matters most here: in-flight state is per resource,
/// not one global flag. Triggering `ai-redis` must not disable
/// `auth-service`'s button, and finishing `ai-redis` must not clear
/// `auth-service`'s flag early.
@Test(.timeLimit(.minutes(1))) @MainActor func twoDifferentResourcesCanBeInFlightAtOnceIndependently() async {
    let runner = GatedCommandRunner()
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    let taskA = Task { await coordinator.trigger("ai-redis", on: instance(webPort: 10350)) }
    let taskB = Task { await coordinator.trigger("auth-service", on: instance(webPort: 10350)) }
    await runner.waitForInvocation(count: 2)

    #expect(coordinator.isInFlight("ai-redis"))
    #expect(coordinator.isInFlight("auth-service"))

    await runner.gate.release("ai-redis")
    await taskA.value

    #expect(!coordinator.isInFlight("ai-redis"))
    // The other resource's action is still running and must still read as
    // in flight — a global flag would have cleared this too.
    #expect(coordinator.isInFlight("auth-service"))

    await runner.gate.release("auth-service")
    await taskB.value
    #expect(!coordinator.isInFlight("auth-service"))
}

/// The critical case: `trigger` (the row button) and `setEnabled` (the
/// context menu) are two separate entry points that can both target the
/// same resource. A reference count would keep the button correctly
/// disabled while still letting a second `tilt` invocation race the first
/// underneath it — on a tool whose whole job is mutating someone's live dev
/// environment, that double-invocation is the actual hazard, not just the
/// UI state. This asserts the second call never reaches the runner at all,
/// the flag stays set until the *first* action finishes (not the second,
/// which never started), and a different resource remains unaffected.
///
/// `.timeLimit` is load-bearing here, not decoration. This is the guard test
/// for the double-invocation bug, so its one job is to FAIL — loudly and
/// quickly — if the entry guard in `ResourceActionCoordinator.run(_:_:)` ever
/// goes away. Without the guard, `setEnabled` below stops being refused and
/// instead awaits the same `GatedCommandRunner` gate token (`"shared"`) as
/// the still-running first call, which `release("shared")` at the end only
/// ever satisfies once.
///
/// The limit alone is not enough, which is why `NamedGate` is both
/// cancellation-aware and multi-waiter. A `.timeLimit` trait enforces itself
/// by cancelling the test's `Task`, and a plain `withCheckedContinuation`
/// does not observe that cancellation at all. Measured against the original
/// single-continuation, non-cancellable gate with the guard deleted: still
/// running after 120 seconds, emitting "SWIFT TASK CONTINUATION MISUSE:
/// wait(_:) leaked its continuation". With the gate as it stands now, the same
/// mutation fails in 64 seconds with three real expectation failures naming
/// the defect — the second call reached the runner (`invocations.count → 2`),
/// its argv is the `disable` that should never have been issued, and
/// `isInFlight("shared")` has already been cleared by the second call's
/// `defer` while the first is still running — and then exits.
@Test(.timeLimit(.minutes(1))) @MainActor func aSecondActionOnAnAlreadyInFlightResourceIsRefusedNotQueued() async {
    let runner = GatedCommandRunner()
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    let first = Task { await coordinator.trigger("shared", on: instance(webPort: 10350)) }
    await runner.waitForInvocation(count: 1)
    #expect(coordinator.isInFlight("shared"))

    // A second, different entry point targeting the same resource while the
    // first is still genuinely running.
    await coordinator.setEnabled(false, resource: "shared", on: instance(webPort: 10350))

    // The second call must never have reached the runner — refused at
    // entry, not queued behind the first.
    #expect(runner.invocations.count == 1)
    #expect(runner.invocations == [["trigger", "--port", "10350", "shared"]])
    // Still in flight because the *first* action is still running, not
    // because a second one started.
    #expect(coordinator.isInFlight("shared"))

    // A wholly different resource is unaffected by "shared" being busy.
    let other = Task { await coordinator.trigger("other", on: instance(webPort: 10350)) }
    await runner.waitForInvocation(count: 2)
    #expect(coordinator.isInFlight("other"))
    await runner.gate.release("other")
    await other.value

    await runner.gate.release("shared")
    await first.value
    #expect(!coordinator.isInFlight("shared"))
}

/// A cancelled action (e.g. the view disappearing mid-trigger) is not a
/// tilt failure and must not surface as one. Without explicit handling,
/// `CancellationError` fell through to `message(for:)`'s default case and
/// produced an alert reading the literal text "CancellationError()" — the
/// exact opaque-failure shape this type exists to prevent.
@Test @MainActor func aCancelledActionClearsInFlightWithoutRecordingAFailure() async {
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: CancellingCommandRunner(), binary: binary))

    await coordinator.trigger("ai-redis", on: instance(webPort: 10350))

    #expect(!coordinator.isInFlight("ai-redis"))
    #expect(coordinator.lastFailure == nil)
}

@Test @MainActor func aSuccessfulActionClearsInFlightAndRecordsNoFailure() async {
    let runner = StubCommandRunner()
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.trigger("ai-redis", on: instance(webPort: 10350))

    #expect(!coordinator.isInFlight("ai-redis"))
    #expect(coordinator.lastFailure == nil)
}

/// A failed action clearing the in-flight flag matters more than the happy
/// path: a spinner that stops with no explanation, or worse, a button stuck
/// disabled forever after a failure, is worse than no button at all.
@Test @MainActor func aFailedTriggerClearsInFlightAndRecordsTheFailureMessage() async {
    let runner = StubCommandRunner(failure: "Error: no resource named ai-typo")
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.trigger("ai-typo", on: instance(webPort: 10350))

    #expect(!coordinator.isInFlight("ai-typo"))
    #expect(coordinator.lastFailure == .init(resource: "ai-typo", message: "Error: no resource named ai-typo"))
}

@Test @MainActor func aFailedSetEnabledAlsoClearsInFlightAndRecordsTheFailure() async {
    let runner = StubCommandRunner(failure: "Error: cannot disable Tiltfile")
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.setEnabled(false, resource: "(Tiltfile)", on: instance(webPort: 10350))

    #expect(!coordinator.isInFlight("(Tiltfile)"))
    #expect(coordinator.lastFailure?.resource == "(Tiltfile)")
    #expect(coordinator.lastFailure?.message == "Error: cannot disable Tiltfile")
}

@Test @MainActor func clearFailureDismissesTheRecordedFailure() async {
    let runner = StubCommandRunner(failure: "boom")
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.trigger("ai-redis", on: instance(webPort: 10350))
    #expect(coordinator.lastFailure != nil)

    coordinator.clearFailure()
    #expect(coordinator.lastFailure == nil)
}

/// The recurring failure mode this project keeps getting bitten by: a
/// control that looks live but silently does nothing. Without a located
/// tilt binary, every action must be a documented no-op, not a crash and not
/// a hang.
@Test @MainActor func withoutALocatedTiltBinaryTheCoordinatorIsUnavailableAndActionsNoOp() async {
    let coordinator = ResourceActionCoordinator(actions: nil)

    #expect(!coordinator.isAvailable)

    await coordinator.trigger("ai-redis", on: instance(webPort: 10350))

    #expect(!coordinator.isInFlight("ai-redis"))
    #expect(coordinator.lastFailure == nil)
}

@Test @MainActor func aLocatedTiltBinaryMakesTheCoordinatorAvailable() {
    let coordinator = ResourceActionCoordinator(actions: TiltActions(runner: StubCommandRunner(), binary: binary))
    #expect(coordinator.isAvailable)
}

// MARK: - Test doubles

/// A `CommandRunning` double that always throws `CancellationError`, for
/// exercising the coordinator's cancellation handling without needing to
/// race a real `Task.cancel()` against an in-flight call.
private struct CancellingCommandRunner: CommandRunning {
    func run(_ url: URL, _ args: [String]) async throws -> String {
        throw CancellationError()
    }
}

/// A `CommandRunning` double whose calls suspend until explicitly released by
/// resource name, so tests can observe in-flight state mid-call rather than
/// only before and after — `StubCommandRunner` alone completes synchronously
/// and can never be caught "in flight".
///
/// Every argv this codebase's `TiltActions` produces ends with the resource
/// or label name (`["trigger", "--port", "N", name]`,
/// `["disable", "--port", "N", resource]`), so keying the gate on `args.last`
/// works for both `trigger` and `setEnabled`.
private final class GatedCommandRunner: CommandRunning, @unchecked Sendable {
    let gate = NamedGate()
    private let lock = NSLock()
    private var invocationsStorage: [[String]] = []

    var invocations: [[String]] { lock.withLock { invocationsStorage } }

    func run(_ url: URL, _ args: [String]) async throws -> String {
        lock.withLock { invocationsStorage.append(args) }
        try await gate.wait(args.last ?? "")
        return ""
    }

    /// Polls until `count` calls have reached this runner. A plain assertion
    /// right after `Task { ... }` would race the task's first suspension —
    /// this is the same "poll rather than assume synchronous scheduling"
    /// approach `ProcessCommandRunner`'s own tests use elsewhere in this
    /// suite.
    func waitForInvocation(count: Int) async {
        while invocations.count < count {
            await Task.yield()
        }
    }
}

// `NamedGate` — the suspend-until-released primitive `GatedCommandRunner`
// waits on — lives in `NamedGate.swift`, shared with
// `InstanceActionCoordinatorTests`. Its multi-waiter, cancellation-aware
// behaviour is what makes the refusal test above fail rather than hang under
// mutation; see that file for the measurements.
