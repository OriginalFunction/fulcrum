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

@Test func triggerTargetsTheInstancesOwnPort() async throws {
    let runner = StubCommandRunner()
    try await TiltActions(runner: runner, binary: binary)
        .trigger("ai-redis", on: instance(webPort: 10350))
    #expect(runner.invocations == [["trigger", "--port", "10350", "ai-redis"]])
}

@Test func disableUsesTheDisableSubcommandNotAFlag() async throws {
    let runner = StubCommandRunner()
    try await TiltActions(runner: runner, binary: binary)
        .setEnabled(false, resource: "ai-redis", on: instance(webPort: 10350))
    #expect(runner.invocations == [["disable", "--port", "10350", "ai-redis"]])
}

@Test func enableUsesTheEnableSubcommand() async throws {
    let runner = StubCommandRunner()
    try await TiltActions(runner: runner, binary: binary)
        .setEnabled(true, resource: "ai-redis", on: instance(webPort: 10350))
    #expect(runner.invocations == [["enable", "--port", "10350", "ai-redis"]])
}

@Test func setEnabledByLabelUsesLabelsFlagNotAResourceLoop() async throws {
    let runner = StubCommandRunner()
    try await TiltActions(runner: runner, binary: binary)
        .setEnabled(false, label: "backend", on: instance(webPort: 10350))
    #expect(runner.invocations == [["disable", "--port", "10350", "-l", "backend"]])
}

@Test func enableByLabelUsesLabelsFlagToo() async throws {
    let runner = StubCommandRunner()
    try await TiltActions(runner: runner, binary: binary)
        .setEnabled(true, label: "backend", on: instance(webPort: 10350))
    #expect(runner.invocations == [["enable", "--port", "10350", "-l", "backend"]])
}

@Test func setEnabledForAllUsesTheAllFlagNotAResourceLoop() async throws {
    let runner = StubCommandRunner()
    try await TiltActions(runner: runner, binary: binary)
        .setEnabledForAll(false, on: instance(webPort: 10350))
    #expect(runner.invocations == [["disable", "--port", "10350", "--all"]])
}

@Test func enableForAllUsesTheAllFlagToo() async throws {
    let runner = StubCommandRunner()
    try await TiltActions(runner: runner, binary: binary)
        .setEnabledForAll(true, on: instance(webPort: 10350))
    #expect(runner.invocations == [["enable", "--port", "10350", "--all"]])
}

@Test func downIsAddressedByTiltfilePathNotPort() async throws {
    let runner = StubCommandRunner()
    try await TiltActions(runner: runner, binary: binary)
        .down(tiltfilePath: "/Users/dev/project/Tiltfile")
    #expect(runner.invocations == [["down", "-f", "/Users/dev/project/Tiltfile"]])
}

@Test func downRejectsAnEmptyTiltfilePath() async throws {
    let runner = StubCommandRunner()
    await #expect(throws: TiltActionError.self) {
        try await TiltActions(runner: runner, binary: binary).down(tiltfilePath: "")
    }
    #expect(runner.invocations.isEmpty)
}

@Test func downRejectsARelativeTiltfilePath() async throws {
    let runner = StubCommandRunner()
    await #expect(throws: TiltActionError.self) {
        try await TiltActions(runner: runner, binary: binary).down(tiltfilePath: "Tiltfile")
    }
    #expect(runner.invocations.isEmpty)
}

@Test func aNonZeroExitSurfacesTiltsOwnStderr() async throws {
    let runner = StubCommandRunner(failure: "Error: no resource named ai-typo")
    let actions = TiltActions(runner: runner, binary: binary)
    await #expect(throws: TiltActionError.self) {
        try await actions.trigger("ai-typo", on: instance(webPort: 10350))
    }
}

@Test func theStderrTextSurvivesIntoTheThrownError() async throws {
    let runner = StubCommandRunner(failure: "Error: no resource named ai-typo")
    let actions = TiltActions(runner: runner, binary: binary)
    do {
        try await actions.trigger("ai-typo", on: instance(webPort: 10350))
        Issue.record("expected trigger to throw")
    } catch TiltActionError.commandFailed(_, let stderr) {
        #expect(stderr == "Error: no resource named ai-typo")
    }
}

@Test func everyInvocationRunsAgainstTheResolvedBinaryURL() async throws {
    let runner = StubCommandRunner()
    let recorder = URLRecordingCommandRunner(inner: runner)
    try await TiltActions(runner: recorder, binary: binary)
        .trigger("ai-redis", on: instance(webPort: 10350))
    #expect(recorder.urls == [binary])
}

// MARK: - ProcessCommandRunner: timeout, cancellation, and the pipe drain

@Test func aCommandThatOutlivesItsTimeoutThrowsTimedOut() async throws {
    let runner = ProcessCommandRunner(timeout: 0.2)
    do {
        _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"])
        Issue.record("expected the call to throw")
    } catch TiltActionError.timedOut(_, let after) {
        #expect(after == 0.2)
    } catch {
        Issue.record("expected TiltActionError.timedOut, got \(error)")
    }
}

/// The 5-second `sleep` above would also make a naively-implemented timeout
/// "pass" by coincidence if the test just waited for it. This asserts the
/// call actually returns around the 0.2s timeout, not the process's own
/// 5-second duration — the distinction Finding 1 was about.
@Test func theTimeoutFiresWithoutWaitingForTheProcessToFinishOnItsOwn() async throws {
    let runner = ProcessCommandRunner(timeout: 0.2)
    let start = ContinuousClock.now
    _ = try? await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"])
    let elapsed = start.duration(to: .now)
    #expect(elapsed < .seconds(2))
}

@Test func aCancelledCallReturnsPromptlyRatherThanBlocking() async throws {
    let runner = ProcessCommandRunner(timeout: 30)
    let task = Task {
        try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"])
    }
    // Give the process a moment to actually launch before cancelling, so
    // this exercises "cancelled mid-flight," not "cancelled before it started."
    try await Task.sleep(nanoseconds: 100_000_000)

    let start = ContinuousClock.now
    task.cancel()
    let result = await task.result
    let elapsed = start.duration(to: .now)

    #expect(elapsed < .seconds(2))
    switch result {
    case .success:
        Issue.record("expected the cancelled call to throw, not return a result")
    case .failure:
        break
    }
}

/// Regression guard, not a bug fix — confirmed correct as of this commit: a
/// process that floods both stdout and stderr well past the 64KB pipe
/// buffer, simultaneously, must still drain fully rather than deadlock with
/// the process blocked writing to a full, undrained pipe.
@Test func floodedStdoutAndStderrBothDrainWithoutDeadlocking() async throws {
    let runner = ProcessCommandRunner(timeout: 5)
    let output = try await runner.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "yes | head -c 500000; yes | head -c 500000 >&2"]
    )
    #expect(output.utf8.count == 500_000)
}

/// `tiltActionFailureMessage(for:)` is the one mapping every action
/// coordinator and the Open Tiltfile command alert through — this guards
/// against it losing either branch. Mutating either `if let` into the
/// fallthrough `String(describing: error)` makes the matching assertion fail:
/// a `TiltActionError` would print as `commandFailed(exitCode: 1, stderr:
/// "port 10350 already in use")` and a `TiltLaunchError` as
/// `tiltExitedImmediately(exitCode: 1, stderr: "...")` instead of tilt's own
/// words.
@Test func actionFailureMappingReadsATiltActionErrorsStderrVerbatim() {
    let error = TiltActionError.commandFailed(exitCode: 1, stderr: "port 10350 already in use")
    #expect(tiltActionFailureMessage(for: error) == "port 10350 already in use")
}

@Test func actionFailureMappingAlsoCoversATiltLaunchError() {
    let error = TiltLaunchError.tiltExitedImmediately(
        exitCode: 1,
        stderr: "Tilt cannot start because you already have another process on port 10350"
    )
    #expect(tiltActionFailureMessage(for: error)
            == "Tilt cannot start because you already have another process on port 10350")
}

// MARK: - Guard rail: `TiltActions` must never shell out to `up`

/// `TiltActions` shells every action through `CommandRunning`, whose real
/// implementation (`ProcessCommandRunner`) times out at 30s and SIGTERMs —
/// correct for `trigger`/`enable`/`disable`/`down`, catastrophic for
/// `tilt up`, which must outlive Fulcrum and is started only through the
/// entirely separate `TiltSpawning`/`DetachedProcessSpawner` path in
/// `TiltLauncher`. The type system stops the reverse mistake (a
/// `ProcessCommandRunner` cannot be handed to `TiltLauncher.init(spawner:)`),
/// but nothing stops a future method being added to `TiltActions` that shells
/// `tilt up` through `CommandRunning` — that would silently kill a running
/// dev environment 30 seconds after it started.
///
/// Swift has no runtime API to enumerate a type's instance methods the way
/// Objective-C's `class_copyMethodList` can: `Mirror` walks only stored
/// properties, and `TiltActions` is an actor, so it cannot be bridged to the
/// Objective-C runtime for that either. This test cannot, therefore,
/// automatically discover a method added to `TiltActions` after this was
/// written — that is a real, acknowledged gap. What it can do, and does, is
/// call every method `TiltActions` has today (`trigger`,
/// `setEnabled(_:resource:on:)`, `setEnabled(_:label:on:)`,
/// `setEnabledForAll(_:on:)`, `down(tiltfilePath:)`) against a stub runner
/// and assert that none of them ever produced an argv beginning with "up".
/// Anyone adding a new mutating method to `TiltActions` must add a call to it
/// here — the compiler will not force this, so this is the clearest guard
/// achievable without restructuring `TiltActions` around a closed,
/// compiler-enumerable command set.
@Test func noTiltActionsMethodEverShellsOutToUp() async throws {
    let runner = StubCommandRunner()
    let actions = TiltActions(runner: runner, binary: binary)
    let target = instance(webPort: 10350)

    try await actions.trigger("ai-redis", on: target)
    try await actions.setEnabled(true, resource: "ai-redis", on: target)
    try await actions.setEnabled(false, resource: "ai-redis", on: target)
    try await actions.setEnabled(true, label: "backend", on: target)
    try await actions.setEnabled(false, label: "backend", on: target)
    try await actions.setEnabledForAll(true, on: target)
    try await actions.setEnabledForAll(false, on: target)
    try await actions.down(tiltfilePath: "/Users/dev/project/Tiltfile")

    #expect(runner.invocations.count == 8)
    for argv in runner.invocations {
        #expect(argv.first != "up", "TiltActions produced an argv beginning with \"up\": \(argv)")
    }
}

// MARK: - Guard rail: no failure message is ever empty

/// `tiltActionFailureMessage(for:)` maps every `TiltActionError` and
/// `TiltLaunchError` case to alert text through two exhaustive switches, so a
/// *new* case is a compile error. An *existing* arm quietly changed to return
/// `""` would compile fine and no test would catch it — the user gets an
/// alert with an empty body, the same silent-failure shape this project keeps
/// getting bitten by. `allSamples` on each enum (declared beside
/// `userFacingMessage` in `CommandRunning.swift` and `TiltLauncher.swift`)
/// gives one representative instance per case via a switch that is itself
/// exhaustive over a payload-free `Kind` mirror, so adding a case without
/// adding a sample fails to compile.
@Test func everyTiltActionErrorCaseYieldsANonEmptyMessage() {
    #expect(TiltActionError.allSamples.count == TiltActionError.Kind.allCases.count)
    for sample in TiltActionError.allSamples {
        let message = sample.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!message.isEmpty, "\(sample) produced an empty or whitespace-only message")
    }
}

@Test func everyTiltLaunchErrorCaseYieldsANonEmptyMessage() {
    #expect(TiltLaunchError.allSamples.count == TiltLaunchError.Kind.allCases.count)
    for sample in TiltLaunchError.allSamples {
        let message = sample.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!message.isEmpty, "\(sample) produced an empty or whitespace-only message")
    }
}

/// Regression for `CommandRunning.swift`: `commandFailed`'s message did not
/// trim before checking emptiness, unlike `TiltLaunchError.tiltExitedImmediately`
/// right next to it. A process that wrote only whitespace to stderr (some
/// tools flush a blank line before the real output) produced an alert with a
/// whitespace-only body — reachable in principle even though nothing on the
/// current launch path exercises it. `commandFailed` now trims to match.
@Test func commandFailedWithWhitespaceOnlyStderrStillProducesARealMessage() {
    let error = TiltActionError.commandFailed(exitCode: 1, stderr: "   \n")
    #expect(!error.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

/// Wraps a `CommandRunning` to additionally capture which URL each invocation
/// targeted, since `StubCommandRunner` only records argv.
private final class URLRecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.withLock { _urls } }
    private let inner: any CommandRunning

    init(inner: any CommandRunning) { self.inner = inner }

    func run(_ url: URL, _ args: [String]) async throws -> String {
        lock.withLock { _urls.append(url) }
        return try await inner.run(url, args)
    }
}
