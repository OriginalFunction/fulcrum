import Foundation

/// Runs an external command and returns its captured stdout.
///
/// `TiltActions` never touches `Process` directly — it goes through this seam
/// instead. That is what makes exact-argv assertions possible in tests
/// without ever shelling out for real, which matters because every action
/// behind this protocol mutates a developer's live environment: the wrong
/// `--port` triggers a build in the wrong project, or disables the wrong
/// resource.
public protocol CommandRunning: Sendable {
    /// Runs `url` with `args` and returns captured stdout. Throws
    /// `TiltActionError` on a non-zero exit, on a launch failure, or on
    /// timeout — always carrying a real reason, never a generic "something
    /// went wrong." A silent failure here is the specific bug class this
    /// project keeps getting bitten by. If the calling `Task` is cancelled,
    /// implementations must return promptly rather than block, and should
    /// terminate any child process they started.
    func run(_ url: URL, _ args: [String]) async throws -> String
}

/// Thrown by a `CommandRunning` implementation. Always carries a real reason
/// — the process's own stderr, or why it never got that far — so the UI can
/// show the user what actually happened instead of a generic failure.
public enum TiltActionError: Error, Equatable {
    /// The process ran to completion but exited non-zero. `stderr` is its
    /// own stderr text, verbatim.
    case commandFailed(exitCode: Int32, stderr: String)
    /// The process never launched — e.g. `binary` doesn't exist at that path
    /// anymore, or isn't executable.
    case launchFailed(binary: URL, reason: String)
    /// The process exceeded its timeout and was terminated.
    case timedOut(binary: URL, after: TimeInterval)
    /// A caller-side precondition failed before any process was launched.
    case invalidArgument(String)
}

extension TiltActionError {
    /// Text fit for an alert body. `commandFailed` carries tilt's own stderr
    /// verbatim — that is the actual reason the action failed, and
    /// paraphrasing it would throw away the one detail that lets the user fix
    /// the problem. Reached by every action coordinator
    /// (`ResourceActionCoordinator`, `InstanceActionCoordinator`) through
    /// `tiltActionFailureMessage(for:)` below, so alert wording cannot drift
    /// between the row-level and instance-level surfaces. It is the only
    /// implementation of this mapping — `ResourceActionCoordinator` once
    /// carried a byte-for-byte private copy, which is exactly the drift this
    /// exists to prevent.
    public var userFacingMessage: String {
        switch self {
        case let .commandFailed(_, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "tilt exited with an error." : trimmed
        case let .launchFailed(_, reason):
            return "Could not launch tilt: \(reason)"
        case let .timedOut(_, after):
            return "tilt did not respond within \(Int(after))s."
        case let .invalidArgument(message):
            return message
        }
    }
}

extension TiltActionError {
    /// Mirrors `TiltActionError`'s case set with no associated values, so it
    /// can be `CaseIterable` even though `TiltActionError` itself cannot be —
    /// Swift only synthesizes `CaseIterable` for enums without payloads.
    enum Kind: CaseIterable {
        case commandFailed, launchFailed, timedOut, invalidArgument
    }

    /// One representative instance per case. The switch is exhaustive over
    /// `Kind`, so adding a new case to `TiltActionError` without adding a
    /// matching `Kind` case and a sample here is a compile error, not a
    /// silent gap — the same guarantee `tiltActionFailureMessage(for:)`'s own
    /// exhaustive switches give the case set itself.
    static func sample(for kind: Kind) -> TiltActionError {
        switch kind {
        case .commandFailed:
            return .commandFailed(exitCode: 1, stderr: "Error: no resource named ai-typo")
        case .launchFailed:
            return .launchFailed(binary: URL(filePath: "/opt/homebrew/bin/tilt"), reason: "no such file or directory")
        case .timedOut:
            return .timedOut(binary: URL(filePath: "/opt/homebrew/bin/tilt"), after: 30)
        case .invalidArgument:
            return .invalidArgument("down requires an absolute Tiltfile path, got: \"\"")
        }
    }

    /// Every case, once each, with representative payloads — what a test
    /// iterates to assert a property holds for the whole enum without
    /// hardcoding a case list that can fall out of sync with the type.
    static var allSamples: [TiltActionError] { Kind.allCases.map(sample(for:)) }
}

/// Renders any error as alert-ready text, deferring to `TiltActionError.userFacingMessage`
/// or `TiltLaunchError.userFacingMessage` when the error is one of those two.
/// Both name a real cause in the user's own terms — tilt's own stderr for a
/// command that failed or a launch that raced a busy port — so paraphrasing
/// either would throw away the detail that lets someone fix the problem.
///
/// This is the single mapping every alert in Fulcrum goes through:
/// `ResourceActionCoordinator` and `InstanceActionCoordinator` for row- and
/// instance-level actions, and the Open Tiltfile command (`TiltLauncher`) for
/// starting a new instance. A launch failure is a second error type, not a
/// second alert path — extending this one function is what keeps their
/// wording from drifting apart the way `ResourceActionCoordinator` once did
/// with its own byte-for-byte copy.
///
/// `CancellationError` must never reach here — callers catch it separately
/// before it can turn into an alert reading the literal text
/// "CancellationError()".
public func tiltActionFailureMessage(for error: Error) -> String {
    if let actionError = error as? TiltActionError { return actionError.userFacingMessage }
    if let launchError = error as? TiltLaunchError { return launchError.userFacingMessage }
    return String(describing: error)
}

/// Test double. Records every invocation's argv (not the resolved binary
/// URL — see `everyInvocationRunsAgainstTheResolvedBinaryURL` for a wrapper
/// that also captures that) so tests can assert on exact CLI flags without
/// shelling out.
///
/// A `final class` with a lock, not an actor: tests read `.invocations`
/// synchronously right after `await`ing the call under test, mirroring the
/// existing `ManualConfigWatcher` test-double pattern in this codebase.
public final class StubCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInvocations: [[String]] = []
    private let failureMessage: String?
    private let output: String

    public var invocations: [[String]] {
        lock.withLock { recordedInvocations }
    }

    public init(output: String = "") {
        self.output = output
        self.failureMessage = nil
    }

    public init(failure message: String) {
        self.output = ""
        self.failureMessage = message
    }

    public func run(_ url: URL, _ args: [String]) async throws -> String {
        lock.withLock { recordedInvocations.append(args) }
        if let failureMessage {
            throw TiltActionError.commandFailed(exitCode: 1, stderr: failureMessage)
        }
        return output
    }
}

/// Real implementation. A thin `Process` wrapper that captures stdout and
/// stderr separately, throws `TiltActionError` on a non-zero exit or a
/// failure to launch, and enforces a timeout.
public struct ProcessCommandRunner: CommandRunning {
    private let timeout: TimeInterval

    /// - Parameter timeout: how long to let the process run before it is
    ///   terminated and `TiltActionError.timedOut` is thrown. Injectable so
    ///   tests can use a short one instead of waiting out the real default.
    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    public func run(_ url: URL, _ args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TiltActionError.launchFailed(binary: url, reason: error.localizedDescription)
        }

        // Races three things: the process actually finishing, a timeout, and
        // this call's own Task being cancelled. `Task.detached` work (the
        // pipe drain below) does not observe the caller's cancellation on
        // its own — `await`ing it ignores cancellation entirely — so without
        // the second and third branches here, a hung `tilt` (stale port,
        // stuck network call) would hang this call forever with no way out.
        // Whichever branch loses gets cancelled by `group.cancelAll()`, and
        // the process is explicitly terminated so a hung child doesn't keep
        // running, and its pipes close, unblocking the abandoned drain.
        return try await withThrowingTaskGroup(of: RunOutcome.self) { group in
            defer { group.cancelAll() }

            group.addTask {
                async let stdoutData = Task.detached { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }.value
                async let stderrData = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }.value
                async let waited: Void = Task.detached { process.waitUntilExit() }.value
                let (stdout, stderr, _) = await (stdoutData, stderrData, waited)
                return .finished(stdout: stdout, stderr: stderr, status: process.terminationStatus)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                return .timedOut
            }
            group.addTask {
                // Polls rather than a single `Task.sleep` because there's no
                // "wake me on cancellation" primitive — this is how a task
                // group races against the caller's own cancellation.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                return .cancelled
            }

            guard let outcome = try await group.next() else {
                throw TiltActionError.timedOut(binary: url, after: timeout)
            }

            switch outcome {
            case .finished(let stdout, let stderr, let status):
                guard status == 0 else {
                    throw TiltActionError.commandFailed(
                        exitCode: status,
                        stderr: String(data: stderr, encoding: .utf8) ?? ""
                    )
                }
                return String(data: stdout, encoding: .utf8) ?? ""
            case .timedOut:
                if process.isRunning { process.terminate() }
                throw TiltActionError.timedOut(binary: url, after: timeout)
            case .cancelled:
                if process.isRunning { process.terminate() }
                throw CancellationError()
            }
        }
    }
}

private enum RunOutcome: Sendable {
    case finished(stdout: Data, stderr: Data, status: Int32)
    case timedOut
    case cancelled
}
