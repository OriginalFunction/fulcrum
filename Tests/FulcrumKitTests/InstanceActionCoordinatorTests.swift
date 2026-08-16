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

@Test @MainActor func reloadTiltfileTriggersTheTiltfileResourceByName() async throws {
    let runner = StubCommandRunner()
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.reloadTiltfile(on: instance(webPort: 10350))

    #expect(runner.invocations == [["trigger", "--port", "10350", "(Tiltfile)"]])
}

@Test @MainActor func enableAllUsesTheAllFlagNotAResourceLoop() async throws {
    let runner = StubCommandRunner()
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.enableAll(on: instance(webPort: 10350))

    #expect(runner.invocations == [["enable", "--port", "10350", "--all"]])
}

@Test @MainActor func disableAllUsesTheAllFlagNotAResourceLoop() async throws {
    let runner = StubCommandRunner()
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.disableAll(on: instance(webPort: 10350))

    #expect(runner.invocations == [["disable", "--port", "10350", "--all"]])
}

@Test @MainActor func downIsAddressedByTiltfilePathNotByAnInstance() async throws {
    let runner = StubCommandRunner()
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.down(tiltfilePath: "/Users/dev/project/Tiltfile")

    #expect(runner.invocations == [["down", "-f", "/Users/dev/project/Tiltfile"]])
}

@Test(.timeLimit(.minutes(1))) @MainActor func aTriggeredReloadIsInFlightUntilItCompletes() async {
    let runner = GatedCommandRunner()
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))
    let target = instance(webPort: 10350)

    #expect(!coordinator.isInFlight(on: target))

    let task = Task { await coordinator.reloadTiltfile(on: target) }
    await runner.waitForInvocation(count: 1)

    #expect(coordinator.isInFlight(on: target))

    await runner.gate.release("(Tiltfile)")
    await task.value

    #expect(!coordinator.isInFlight(on: target))
}

/// The critical case, mirroring `ResourceActionCoordinator`'s: two different
/// instance-level entry points (the toolbar's "Enable all" and its "Disable
/// all") both targeting the same instance while the first is still running.
/// A reference count would keep the button disabled while still letting a
/// second `tilt` invocation race the first underneath it — this asserts the
/// second call never reaches the runner at all.
/// `.timeLimit` matters here specifically: if the in-flight guard this test
/// exists to pin is ever removed, `disableAll` stops being refused and
/// instead awaits the same `GatedCommandRunner` gate token as the first
/// call — which nothing ever releases a second time, since `release("--all")`
/// below is called exactly once. Without a time limit that is a hang, not a
/// failure: the test (and, in CI, the whole run) stalls with no diagnosis
/// rather than reporting what actually broke. The limit cancels the test's
/// task, `NamedGate` turns that cancellation into a thrown error rather than
/// staying parked, and the body runs on to record the assertions that
/// actually name the defect.
@Test(.timeLimit(.minutes(1))) @MainActor func aSecondActionOnAnAlreadyInFlightInstanceIsRefusedNotQueued() async {
    let runner = GatedCommandRunner()
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))
    let target = instance(webPort: 10350)

    let first = Task { await coordinator.enableAll(on: target) }
    await runner.waitForInvocation(count: 1)
    #expect(coordinator.isInFlight(on: target))

    await coordinator.disableAll(on: target)

    #expect(runner.invocations.count == 1)
    #expect(runner.invocations == [["enable", "--port", "10350", "--all"]])
    #expect(coordinator.isInFlight(on: target))

    await runner.gate.release("--all")
    await first.value
    #expect(!coordinator.isInFlight(on: target))
}

/// `down` is keyed by path, independently of any instance — tearing down two
/// different projects at once must not block on each other, and the same
/// project's `down` and its (now-impossible, since it is being torn down)
/// instance actions are tracked separately too.
///
/// `.timeLimit` for the same reason the refusal test above carries one: every
/// test in this file that parks on `GatedCommandRunner` can, under a mutation
/// that changes which gate token gets waited on, end up awaiting a token
/// nothing releases. A mutation here was measured hanging a whole run for over
/// eight minutes before this limit existed.
@Test(.timeLimit(.minutes(1))) @MainActor func downInFlightIsTrackedIndependentlyOfInstanceActions() async {
    let runner = GatedCommandRunner()
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))
    let target = instance(webPort: 10350)

    #expect(!coordinator.isTiltDownInFlight(tiltfilePath: "/Users/dev/project/Tiltfile"))

    let task = Task { await coordinator.down(tiltfilePath: "/Users/dev/project/Tiltfile") }
    await runner.waitForInvocation(count: 1)

    #expect(coordinator.isTiltDownInFlight(tiltfilePath: "/Users/dev/project/Tiltfile"))
    // A wholly unrelated instance action against the same instance's port is
    // unaffected by "down" being in flight for its Tiltfile path.
    #expect(!coordinator.isInFlight(on: target))

    await runner.gate.release("/Users/dev/project/Tiltfile")
    await task.value
    #expect(!coordinator.isTiltDownInFlight(tiltfilePath: "/Users/dev/project/Tiltfile"))
}

@Test @MainActor func aCancelledInstanceActionClearsInFlightWithoutRecordingAFailure() async {
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: CancellingCommandRunner(), binary: binary))
    let target = instance(webPort: 10350)

    await coordinator.reloadTiltfile(on: target)

    #expect(!coordinator.isInFlight(on: target))
    #expect(coordinator.lastFailure == nil)
}

@Test @MainActor func aFailedActionClearsInFlightAndRecordsTheFailureMessage() async {
    let runner = StubCommandRunner(failure: "Error: cannot disable Tiltfile")
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))
    let target = instance(webPort: 10350)

    await coordinator.disableAll(on: target)

    #expect(!coordinator.isInFlight(on: target))
    #expect(coordinator.lastFailure?.message == "Error: cannot disable Tiltfile")
}

@Test @MainActor func aFailedDownRecordsTheFailureKeyedByPath() async {
    let runner = StubCommandRunner(failure: "Error: no such Tiltfile")
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.down(tiltfilePath: "/Users/dev/project/Tiltfile")

    #expect(coordinator.lastFailure?.target == "/Users/dev/project/Tiltfile")
    #expect(coordinator.lastFailure?.message == "Error: no such Tiltfile")
}

@Test @MainActor func clearFailureDismissesTheRecordedInstanceFailure() async {
    let runner = StubCommandRunner(failure: "boom")
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: runner, binary: binary))

    await coordinator.reloadTiltfile(on: instance(webPort: 10350))
    #expect(coordinator.lastFailure != nil)

    coordinator.clearFailure()
    #expect(coordinator.lastFailure == nil)
}

/// The same silent-failure shape `ResourceActionCoordinator` guards against:
/// without a located tilt binary, every instance-level action must be a
/// documented no-op, not a crash and not a hang.
@Test @MainActor func withoutALocatedTiltBinaryTheInstanceCoordinatorIsUnavailableAndActionsNoOp() async {
    let coordinator = InstanceActionCoordinator(actions: nil)
    let target = instance(webPort: 10350)

    #expect(!coordinator.isAvailable)

    await coordinator.reloadTiltfile(on: target)

    #expect(!coordinator.isInFlight(on: target))
    #expect(coordinator.lastFailure == nil)
}

@Test @MainActor func aLocatedTiltBinaryMakesTheInstanceCoordinatorAvailable() {
    let coordinator = InstanceActionCoordinator(actions: TiltActions(runner: StubCommandRunner(), binary: binary))
    #expect(coordinator.isAvailable)
}

// MARK: - InstanceActionConfirmation

@Test func tiltDownConfirmationNamesTheProjectAndWarnsItDoesNotStopTiltUp() {
    let confirmation = InstanceActionConfirmation.tiltDown(projectName: "northwind")
    #expect(confirmation.title.contains("northwind"))
    #expect(confirmation.message.contains("northwind"))
    #expect(confirmation.message.lowercased().contains("does not stop"))
    #expect(confirmation.confirmButtonTitle == "Tilt Down")
}

@Test func disableAllConfirmationNamesTheProject() {
    let confirmation = InstanceActionConfirmation.disableAll(projectName: "northwind")
    #expect(confirmation.message.contains("northwind"))
    #expect(confirmation.confirmButtonTitle == "Disable All")
}

// MARK: - Test doubles

private struct CancellingCommandRunner: CommandRunning {
    func run(_ url: URL, _ args: [String]) async throws -> String {
        throw CancellationError()
    }
}

/// Same double `ResourceActionCoordinatorTests` uses, duplicated here rather
/// than shared across files — this codebase's existing test doubles (e.g.
/// `StubCommandRunner`) live in the source they support, not a shared test
/// helpers module, and the two coordinators' gates key on different argv
/// positions (`args.last` here is `--all`, a path, or `(Tiltfile)`, never a
/// bare resource name), so this is not a verbatim copy standing in for one.
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

    func waitForInvocation(count: Int) async {
        while invocations.count < count {
            await Task.yield()
        }
    }
}

// `NamedGate` lives in `NamedGate.swift`, shared with
// `ResourceActionCoordinatorTests`. It was originally duplicated here; the two
// copies were identical, and a gate that is subtly wrong in one file and right
// in the other is precisely how a guard test quietly stops guarding.
