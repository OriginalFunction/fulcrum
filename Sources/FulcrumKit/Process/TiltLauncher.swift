import Foundation

/// Starts a new `tilt up` for a Tiltfile the user picked.
///
/// ## This child is not ours to kill
///
/// A `tilt up` started here is the user's development environment. It must
/// outlive Fulcrum: quitting a menu bar app is not a request to tear down the
/// services someone is working on. That makes this the opposite of the
/// `tilt logs` children in `LogStreamer`, which are deliberately SIGTERM'd on
/// window close, on quit, and on switching instances, and of the one-shot
/// commands in `ProcessCommandRunner`, which are terminated on timeout and on
/// cancellation.
///
/// Three things keep the two lifecycles from being confused with each other:
///
/// 1. **A separate spawn path.** Nothing here goes through `CommandRunning`.
///    `TiltSpawning` is a different protocol with a different return type — it
///    reports whether the process *came up*, and cannot report an exit status
///    for a process that keeps running, because no caller may wait for one.
/// 2. **No teardown to reach for.** `DetachedProcessSpawner` has no `stop`,
///    holds no reference to the child after it settles, and never calls
///    `terminate()` or `kill` on any path — including cancellation, which is
///    exactly where the other two do.
/// 3. **The child is unhooked from Fulcrum's own I/O.** It inherits neither
///    stdin nor Fulcrum's stdout/stderr, so it does not die when Fulcrum's
///    pipes close, and it cannot write into a stream some other component owns.
///
/// A child started this way reparents to launchd when Fulcrum exits and keeps
/// running. `setsid` does not exist on macOS and is not needed: the whole
/// requirement is *never terminate it*.
public struct TiltLauncher: Sendable {
    private let spawner: any TiltSpawning
    private let locateBinary: @Sendable () -> URL?
    private let fileExists: @Sendable (String) -> Bool
    private let isPortAvailable: @Sendable (Int) -> Bool

    /// - Parameters:
    ///   - spawner: how the process is started. Injected so tests can assert on
    ///     exact argv without ever starting a real `tilt up`.
    ///   - locateBinary: defaults to `TiltBinary.locate()`, which is what makes
    ///     this work when Fulcrum was launched from Finder and inherited
    ///     launchd's `PATH` (no `/opt/homebrew/bin`).
    ///   - fileExists: existence check for the Tiltfile.
    ///   - isPortAvailable: the probe `PortAllocator` uses when no port is
    ///     named by the caller.
    public init(
        spawner: any TiltSpawning = DetachedProcessSpawner(),
        locateBinary: @escaping @Sendable () -> URL? = { TiltBinary.locate() },
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        isPortAvailable: @escaping @Sendable (Int) -> Bool = { PortAllocator.isPortFree($0) }
    ) {
        self.spawner = spawner
        self.locateBinary = locateBinary
        self.fileExists = fileExists
        self.isPortAvailable = isPortAvailable
    }

    /// Starts `tilt up` for `tiltfilePath` and returns the port it was given.
    ///
    /// Returns as soon as the instance is up — **not** when it exits, which for
    /// a healthy instance is hours away and would hang the caller for the life
    /// of the developer's environment. The one thing it does wait for is the
    /// short window in which tilt refuses to start (a taken port, a Tiltfile
    /// that will not parse); see `DetachedProcessSpawner.settleWindow`.
    ///
    /// - Parameters:
    ///   - tiltfilePath: an absolute path to an existing Tiltfile.
    ///   - port: the port to serve on, or `nil` to pick a free one.
    @discardableResult
    public func launch(tiltfilePath: String, port: Int? = nil) async throws -> Int {
        guard !tiltfilePath.isEmpty, tiltfilePath.hasPrefix("/") else {
            throw TiltLaunchError.pathNotAbsolute(tiltfilePath)
        }
        guard fileExists(tiltfilePath) else {
            throw TiltLaunchError.tiltfileMissing(tiltfilePath)
        }
        guard let binary = locateBinary() else {
            throw TiltLaunchError.tiltNotFound
        }

        let chosenPort: Int
        if let port {
            chosenPort = port
        } else if let free = PortAllocator.freePort(isAvailable: isPortAvailable) {
            chosenPort = free
        } else {
            throw TiltLaunchError.noFreePort
        }

        // `--stream` needs no TTY: tilt runs with stdout redirected, registers
        // its kubeconfig context, and Fulcrum's discovery finds it from there.
        let arguments = ["up", "-f", tiltfilePath, "--port", "\(chosenPort)", "--stream"]

        // Relative paths inside a Tiltfile — docker build contexts,
        // `local_resource` working directories — resolve against the process's
        // working directory, not against the Tiltfile. Launching from Fulcrum's
        // own cwd would build something other than what the user opened.
        let workingDirectory = URL(filePath: tiltfilePath).deletingLastPathComponent()

        switch try await spawner.spawn(
            binary: binary,
            arguments: arguments,
            workingDirectory: workingDirectory
        ) {
        case .running:
            return chosenPort
        case let .exitedEarly(exitCode, stderr):
            // The port race `PortAllocator` cannot close, and every other
            // reason tilt declines to start. Its own words, verbatim.
            throw TiltLaunchError.tiltExitedImmediately(exitCode: exitCode, stderr: stderr)
        }
    }
}

// MARK: - Spawning

/// How `TiltLauncher` starts a process that is meant to outlive Fulcrum.
///
/// Separate from `CommandRunning` on purpose. That protocol returns a finished
/// command's stdout, which means waiting for the process to exit and killing it
/// if it takes too long — correct for `tilt trigger`, catastrophic for
/// `tilt up`. This one returns as soon as the process is up and has nothing to
/// say about what happens afterwards, because nothing in Fulcrum is allowed to
/// wait for that or to cut it short.
public protocol TiltSpawning: Sendable {
    /// Starts `binary` and returns once it is running, or once it has failed
    /// fast. Implementations must not terminate the child on any path.
    func spawn(binary: URL, arguments: [String], workingDirectory: URL) async throws -> SpawnOutcome
}

/// What became of a spawn attempt, as of the moment the spawner stopped
/// watching. There is deliberately no case for "finished": a spawner that could
/// report an exit status for a healthy instance would be one that waited for it.
public enum SpawnOutcome: Sendable, Equatable {
    /// Still running when the spawner let go. `pid` is for diagnostics only —
    /// nothing in Fulcrum signals it.
    case running(pid: Int32)
    /// Gone before the settle window was out, carrying whatever it printed to
    /// stderr on the way. This is how a launch failure reaches the user.
    case exitedEarly(exitCode: Int32, stderr: String)
}

/// Starts a child, watches it just long enough to catch a refusal to start,
/// and then forgets about it.
public struct DetachedProcessSpawner: TiltSpawning {
    /// How long to watch before declaring the instance up.
    ///
    /// The only bound on how long `launch` blocks. Tilt's refusals happen at
    /// once — a taken port ends the process in well under a second — so this
    /// buys the difference between a useful error and a silent no-op, at the
    /// cost of a beat before the UI moves on.
    private let settleWindow: TimeInterval

    public init(settleWindow: TimeInterval = 1.0) {
        self.settleWindow = settleWindow
    }

    public func spawn(
        binary: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> SpawnOutcome {
        let child = DetachedChild(binary: binary, arguments: arguments, workingDirectory: workingDirectory)
        try child.start()
        return await child.settle(within: settleWindow)
    }
}

/// Owns the `Process` for exactly as long as it takes to find out whether it
/// stayed up. `@unchecked Sendable` for the same reason `LogStreamChild` is:
/// `Process` is not `Sendable`, and access here is confined by `lock`.
private final class DetachedChild: @unchecked Sendable {
    /// Only the tail of a failed launch's stderr is kept — enough to explain
    /// the failure, bounded so a chatty process cannot produce an unbounded
    /// error message.
    private static let stderrTailLimit = 8 * 1024

    private let binary: URL
    private let arguments: [String]
    private let workingDirectory: URL
    private let process = Process()

    /// Where the child's stderr goes: a temporary file that is unlinked the
    /// moment it is open. The descriptor stays valid for the child, so nothing
    /// is left on disk and the space is reclaimed when the instance finally
    /// exits, however many hours later.
    ///
    /// Not a `Pipe`, deliberately. A pipe nobody drains fills after ~64 KB and
    /// then blocks the writer forever — and nobody can drain this one, because
    /// draining means holding on to a process we have just promised to forget.
    /// A file write never blocks.
    private let stderrSink: FileHandle?

    private let lock = NSLock()
    private var recordedExit: Int32?
    private var waiter: CheckedContinuation<Int32?, Never>?
    private var answered = false

    init(binary: URL, arguments: [String], workingDirectory: URL) {
        self.binary = binary
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.stderrSink = Self.makeUnlinkedSink()
    }

    func start() throws {
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        // Nothing of Fulcrum's is inherited. stdin would put the child in
        // competition for a terminal it does not have; Fulcrum's own stdout
        // would tie the instance's life to Fulcrum's, which is precisely what
        // must not happen. `tilt up --stream` writes its log to stdout and
        // Fulcrum reads logs back through `tilt logs`, so discarding it here
        // costs nothing.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrSink ?? FileHandle.nullDevice

        // Installed before `run()` so an instant failure cannot land before
        // anything is listening for it.
        process.terminationHandler = { [weak self] finished in
            self?.recordExit(finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            try? stderrSink?.close()
            throw TiltLaunchError.spawnFailed(binary: binary, reason: error.localizedDescription)
        }
    }

    /// Waits at most `window` for the child to fall over, then lets go of it.
    ///
    /// Two properties matter more than the mechanism. The wait is bounded by
    /// `window` on every path, so no caller can be held for the life of an
    /// instance. And it has no cancellation branch at all: there is nowhere in
    /// here for a cancelled `Task` to turn into a signal to the child.
    /// `ProcessCommandRunner` has exactly such a branch and terminates its
    /// process in it — correct there, and the one behaviour that must never
    /// leak into this path.
    ///
    /// The deadline is a plain dispatch timer rather than a `Task.sleep`, so
    /// nothing here observes cancellation, and no thread is blocked while
    /// waiting.
    func settle(within window: TimeInterval) async -> SpawnOutcome {
        let status: Int32? = await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            let alreadyExited: Int32? = lock.withLock {
                if let recordedExit {
                    answered = true
                    return recordedExit
                }
                waiter = continuation
                return nil
            }
            if let alreadyExited {
                continuation.resume(returning: alreadyExited)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(window, 0)) {
                self.stopWaiting()
            }
        }

        guard let status else {
            // Up. From here on nothing in Fulcrum touches this process again:
            // no reference is kept, and no code path signals it.
            let pid = process.processIdentifier
            try? stderrSink?.close()
            return .running(pid: pid)
        }
        return .exitedEarly(exitCode: status, stderr: readStderrTail())
    }

    /// The child exited. Wakes `settle` if it is still watching; if it has
    /// already let go, this is simply recorded and nothing happens — an
    /// instance that ends hours from now is not Fulcrum's business.
    private func recordExit(_ status: Int32) {
        let waiting: CheckedContinuation<Int32?, Never>? = lock.withLock {
            recordedExit = status
            guard !answered, let waiting = waiter else { return nil }
            answered = true
            waiter = nil
            return waiting
        }
        waiting?.resume(returning: status)
    }

    /// The settle window elapsed with the child still alive.
    private func stopWaiting() {
        let waiting: (CheckedContinuation<Int32?, Never>, Int32?)? = lock.withLock {
            guard !answered, let waiting = waiter else { return nil }
            answered = true
            waiter = nil
            return (waiting, recordedExit)
        }
        guard let (continuation, status) = waiting else { return }
        continuation.resume(returning: status)
    }

    private func readStderrTail() -> String {
        guard let stderrSink else { return "" }
        defer { try? stderrSink.close() }
        do {
            try stderrSink.seek(toOffset: 0)
        } catch {
            return ""
        }
        guard let data = try? stderrSink.readToEnd() else { return "" }
        let tail = data.count > Self.stderrTailLimit ? data.suffix(Self.stderrTailLimit) : data
        return String(decoding: tail, as: UTF8.self)
    }

    /// A file opened and immediately unlinked: a private scratch buffer with no
    /// name in the filesystem, so no test and no run can leave one behind.
    private static func makeUnlinkedSink() -> FileHandle? {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fulcrum-launch-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forUpdating: url)
        else { return nil }
        unlink(url.path)
        return handle
    }
}

// MARK: - Errors

/// Why a launch did not happen — or happened and immediately came apart.
///
/// Every case names something the user can act on, in their own terms: install
/// tilt, pick a real Tiltfile, free a port. `tiltExitedImmediately` carries
/// tilt's own stderr verbatim for the same reason `TiltActionError` does:
/// paraphrasing it throws away the one detail that lets someone fix the
/// problem.
public enum TiltLaunchError: Error, Equatable {
    /// `TiltBinary.locate` found no `tilt` anywhere it looks.
    case tiltNotFound
    /// The path was empty or relative. A relative path would resolve against
    /// whatever directory Fulcrum happens to be running in.
    case pathNotAbsolute(String)
    /// Nothing exists at that path.
    case tiltfileMissing(String)
    /// Every port in the search window was taken.
    case noFreePort
    /// The process could not be started at all.
    case spawnFailed(binary: URL, reason: String)
    /// Tilt started and was gone again within the settle window, with `stderr`
    /// as its own explanation. The usual cause is the port race:
    /// "Tilt cannot start because you already have another process on port N".
    case tiltExitedImmediately(exitCode: Int32, stderr: String)
}

extension TiltLaunchError {
    /// Text fit for an alert body.
    public var userFacingMessage: String {
        switch self {
        case .tiltNotFound:
            return "Could not find the tilt command. Install tilt, or set FULCRUM_TILT_PATH to its location."
        case let .pathNotAbsolute(path):
            return path.isEmpty
                ? "No Tiltfile was chosen."
                : "A Tiltfile must be given by its full path, got: \"\(path)\""
        case let .tiltfileMissing(path):
            return "There is no Tiltfile at \(path)."
        case .noFreePort:
            return "Could not find a free port to start tilt on."
        case let .spawnFailed(binary, reason):
            return "Could not launch \(binary.path): \(reason)"
        case let .tiltExitedImmediately(exitCode, stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "tilt stopped immediately after starting (exit code \(exitCode))."
                : trimmed
        }
    }
}

extension TiltLaunchError {
    /// Mirrors `TiltLaunchError`'s case set with no associated values, so it
    /// can be `CaseIterable` even though `TiltLaunchError` itself cannot be —
    /// Swift only synthesizes `CaseIterable` for enums without payloads.
    enum Kind: CaseIterable {
        case tiltNotFound, pathNotAbsolute, tiltfileMissing, noFreePort, spawnFailed, tiltExitedImmediately
    }

    /// One representative instance per case. The switch is exhaustive over
    /// `Kind`, so adding a new case to `TiltLaunchError` without adding a
    /// matching `Kind` case and a sample here is a compile error, not a
    /// silent gap.
    static func sample(for kind: Kind) -> TiltLaunchError {
        switch kind {
        case .tiltNotFound:
            return .tiltNotFound
        case .pathNotAbsolute:
            return .pathNotAbsolute("Tiltfile")
        case .tiltfileMissing:
            return .tiltfileMissing("/Users/dev/project/Tiltfile")
        case .noFreePort:
            return .noFreePort
        case .spawnFailed:
            return .spawnFailed(binary: URL(filePath: "/opt/homebrew/bin/tilt"), reason: "no such file or directory")
        case .tiltExitedImmediately:
            return .tiltExitedImmediately(
                exitCode: 1,
                stderr: "Tilt cannot start because you already have another process on port 10350"
            )
        }
    }

    /// Every case, once each, with representative payloads — what a test
    /// iterates to assert a property holds for the whole enum without
    /// hardcoding a case list that can fall out of sync with the type.
    static var allSamples: [TiltLaunchError] { Kind.allCases.map(sample(for:)) }
}
