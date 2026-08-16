import Foundation
import Testing
@testable import FulcrumKit

private let binary = URL(filePath: "/opt/homebrew/bin/tilt")

// MARK: - argv

@Test func launchesTheGivenTiltfileOnTheGivenPort() async throws {
    let spawner = RecordingSpawner()
    let launcher = TiltLauncher(spawner: spawner, locateBinary: { binary }, fileExists: { _ in true })

    try await launcher.launch(tiltfilePath: "/Users/r/p/Tiltfile", port: 10360)

    #expect(spawner.invocations.count == 1)
    #expect(spawner.invocations.first?.binary == binary)
    #expect(spawner.invocations.first?.arguments == [
        "up", "-f", "/Users/r/p/Tiltfile", "--port", "10360", "--stream",
    ])
}

@Test func launchesThroughTheLocatedBinaryRatherThanTheInheritedPath() async throws {
    // A GUI app launched from Finder inherits launchd's PATH, which excludes
    // /opt/homebrew/bin. Bare "tilt" would resolve to nothing there.
    let spawner = RecordingSpawner()
    let located = URL(filePath: "/Users/r/.local/bin/tilt")
    let launcher = TiltLauncher(spawner: spawner, locateBinary: { located }, fileExists: { _ in true })

    try await launcher.launch(tiltfilePath: "/Users/r/p/Tiltfile", port: 10350)

    #expect(spawner.invocations.first?.binary == located)
    #expect(spawner.invocations.first?.arguments.contains("tilt") == false)
}

@Test func runsInTheTiltfilesOwnDirectory() async throws {
    // Tiltfile relative paths (docker build contexts, local_resource cwd)
    // resolve against the working directory. Launching from Fulcrum's own cwd
    // would silently build the wrong thing.
    let spawner = RecordingSpawner()
    let launcher = TiltLauncher(spawner: spawner, locateBinary: { binary }, fileExists: { _ in true })

    try await launcher.launch(tiltfilePath: "/Users/r/projects/api/Tiltfile", port: 10350)

    #expect(spawner.invocations.first?.workingDirectory.path == "/Users/r/projects/api")
}

// MARK: - Refusing to launch

@Test func rejectsARelativeOrEmptyPath() async throws {
    for path in ["", "Tiltfile", "p/Tiltfile", "./Tiltfile", "~/p/Tiltfile"] {
        let spawner = RecordingSpawner()
        let launcher = TiltLauncher(spawner: spawner, locateBinary: { binary }, fileExists: { _ in true })

        await #expect(throws: TiltLaunchError.pathNotAbsolute(path)) {
            try await launcher.launch(tiltfilePath: path, port: 10350)
        }
        #expect(spawner.invocations.isEmpty, "nothing may be spawned for \"\(path)\"")
    }
}

@Test func refusesToLaunchATiltfileThatIsNotThere() async throws {
    let spawner = RecordingSpawner()
    let launcher = TiltLauncher(spawner: spawner, locateBinary: { binary }, fileExists: { _ in false })

    await #expect(throws: TiltLaunchError.tiltfileMissing("/Users/r/p/Tiltfile")) {
        try await launcher.launch(tiltfilePath: "/Users/r/p/Tiltfile", port: 10350)
    }
    #expect(spawner.invocations.isEmpty)
}

@Test func reportsAMissingTiltBinaryRatherThanFailingToSpawn() async throws {
    let spawner = RecordingSpawner()
    let launcher = TiltLauncher(spawner: spawner, locateBinary: { nil }, fileExists: { _ in true })

    await #expect(throws: TiltLaunchError.tiltNotFound) {
        try await launcher.launch(tiltfilePath: "/Users/r/p/Tiltfile", port: 10350)
    }
    #expect(spawner.invocations.isEmpty)
}

// MARK: - Port selection (Task 1's allocator, consumed)

@Test func choosesAFreePortWhenTheCallerDoesNotNameOne() async throws {
    let spawner = RecordingSpawner()
    let launcher = TiltLauncher(
        spawner: spawner,
        locateBinary: { binary },
        fileExists: { _ in true },
        isPortAvailable: { $0 >= 10352 }
    )

    let port = try await launcher.launch(tiltfilePath: "/Users/r/p/Tiltfile")

    #expect(port == 10352)
    #expect(spawner.invocations.first?.arguments == [
        "up", "-f", "/Users/r/p/Tiltfile", "--port", "10352", "--stream",
    ])
}

@Test func failsWhenNoPortIsFree() async throws {
    let spawner = RecordingSpawner()
    let launcher = TiltLauncher(
        spawner: spawner,
        locateBinary: { binary },
        fileExists: { _ in true },
        isPortAvailable: { _ in false }
    )

    await #expect(throws: TiltLaunchError.noFreePort) {
        try await launcher.launch(tiltfilePath: "/Users/r/p/Tiltfile")
    }
    #expect(spawner.invocations.isEmpty)
}

// MARK: - Fast failure

@Test func surfacesTiltsOwnErrorWhenItExitsImmediately() async throws {
    // The port race Task 1 cannot close: tilt refuses to start and says so.
    // That text is the only thing that tells the user what to do about it.
    let message = "Tilt cannot start because you already have another process on port 10350\n"
    let spawner = RecordingSpawner(outcome: .exitedEarly(exitCode: 1, stderr: message))
    let launcher = TiltLauncher(spawner: spawner, locateBinary: { binary }, fileExists: { _ in true })

    let error = await #expect(throws: TiltLaunchError.self) {
        try await launcher.launch(tiltfilePath: "/Users/r/p/Tiltfile", port: 10350)
    }

    #expect(error == .tiltExitedImmediately(exitCode: 1, stderr: message))
    #expect(error?.userFacingMessage.contains("another process on port 10350") == true)
}

@Test func explainsAnImmediateExitThatSaidNothing() async throws {
    let spawner = RecordingSpawner(outcome: .exitedEarly(exitCode: 2, stderr: ""))
    let launcher = TiltLauncher(spawner: spawner, locateBinary: { binary }, fileExists: { _ in true })

    let error = await #expect(throws: TiltLaunchError.self) {
        try await launcher.launch(tiltfilePath: "/Users/r/p/Tiltfile", port: 10350)
    }
    #expect(error?.userFacingMessage.isEmpty == false)
    #expect(error?.userFacingMessage.contains("2") == true)
}

// MARK: - Lifetime
//
// These drive the real `DetachedProcessSpawner`, because the thing at risk —
// waiting on a child that runs for hours — lives in the spawner, not in the
// argv building above. None of them runs `tilt`: the "binary" is a shell script
// written into a temporary directory this test owns, named so that it can never
// match a `pgrep -f "tilt up"` looking for a real instance.
//
// Neither test measures how long anything took. The child holds itself open on
// a gate that only the test can open, so "launch() came back while the instance
// was still running" is an ordering the test enforces rather than a duration it
// hopes for: nothing can open the gate until `launch()` has returned, and a
// child that answers afterwards can only have been alive to hear it. The one
// bound left is a ceiling on waiting for that answer, which exists so a broken
// implementation fails instead of hanging the suite — no correct behaviour is
// asserted to fit inside it.

@Test func doesNotWaitForTheInstanceToKeepRunning() async throws {
    let directory = try TemporaryProject()
    let child = try directory.writeLaunchTarget(TemporaryProject.gatedScript)
    let launcher = TiltLauncher(
        spawner: DetachedProcessSpawner(settleWindow: 0.25),
        locateBinary: { child }
    )

    try await launcher.launch(tiltfilePath: directory.tiltfile.path, port: 10999)

    // `tilt up` runs for hours; awaiting its exit would hang the caller for the
    // life of the developer's environment. Control is back here with the gate
    // still shut, which it could not be if this call had waited for the child —
    // the child does not exit until the next line runs.
    try directory.openGate()
    let answered = await directory.waitForFile("gate-opened.txt")
    #expect(answered, "the child was gone by the time launch() returned")

    directory.killLaunchedChild()
}

@Test func doesNotTerminateTheInstanceWhenTheLaunchingTaskIsCancelled() async throws {
    // The opposite of `LogStreamer`, whose child is killed on exactly this
    // signal. A `tilt up` is the user's development environment: no path in
    // Fulcrum may take it down, including the one that cancels a launch.
    let directory = try TemporaryProject()
    let child = try directory.writeLaunchTarget(TemporaryProject.gatedScript)
    // Wide enough that the cancellation below lands while the spawner is still
    // watching — the window in which a cancellation branch would signal the
    // child. Nothing is asserted about it.
    let launcher = TiltLauncher(
        spawner: DetachedProcessSpawner(settleWindow: 2),
        locateBinary: { child }
    )

    let tiltfilePath = directory.tiltfile.path
    let task = Task { try await launcher.launch(tiltfilePath: tiltfilePath, port: 10999) }
    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    _ = try? await task.value

    // The child answers the gate after its launch was cancelled. A
    // SIGTERM-on-cancel path would have left nothing alive to answer.
    try directory.openGate()
    let answered = await directory.waitForFile("gate-opened.txt")
    #expect(answered, "cancelling the launch killed the instance")

    directory.killLaunchedChild()
}

@Test func theRealSpawnerRunsTheChildInTheGivenDirectory() async throws {
    let directory = try TemporaryProject()
    let child = try directory.writeLaunchTarget("""
    #!/bin/sh
    pwd > "$(pwd)/cwd.txt"
    """)

    let outcome = try await DetachedProcessSpawner(settleWindow: 5)
        .spawn(binary: child, arguments: [], workingDirectory: directory.url)

    #expect(outcome == .exitedEarly(exitCode: 0, stderr: ""))
    let reported = try String(contentsOf: directory.url.appending(path: "cwd.txt"), encoding: .utf8)
    #expect(
        URL(filePath: reported.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
            == directory.url.resolvingSymlinksInPath()
    )
}

@Test func theRealSpawnerCapturesStderrFromAFastFailure() async throws {
    let directory = try TemporaryProject()
    let child = try directory.writeLaunchTarget("""
    #!/bin/sh
    echo "Tilt cannot start because you already have another process on port 10350" >&2
    exit 1
    """)

    let outcome = try await DetachedProcessSpawner(settleWindow: 5)
        .spawn(binary: child, arguments: [], workingDirectory: directory.url)

    #expect(outcome == .exitedEarly(
        exitCode: 1,
        stderr: "Tilt cannot start because you already have another process on port 10350\n"
    ))
}

@Test func theRealSpawnerReportsABinaryItCannotRun() async throws {
    let directory = try TemporaryProject()
    let missing = directory.url.appending(path: "not-here")

    await #expect(throws: TiltLaunchError.self) {
        _ = try await DetachedProcessSpawner(settleWindow: 0.1)
            .spawn(binary: missing, arguments: [], workingDirectory: directory.url)
    }
}

// MARK: - Doubles

private final class RecordingSpawner: TiltSpawning, @unchecked Sendable {
    struct Invocation: Equatable {
        let binary: URL
        let arguments: [String]
        let workingDirectory: URL
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private let outcome: SpawnOutcome

    var invocations: [Invocation] { lock.withLock { recorded } }

    init(outcome: SpawnOutcome = .running(pid: 4242)) {
        self.outcome = outcome
    }

    func spawn(binary: URL, arguments: [String], workingDirectory: URL) async throws -> SpawnOutcome {
        lock.withLock {
            recorded.append(Invocation(binary: binary, arguments: arguments, workingDirectory: workingDirectory))
        }
        return outcome
    }
}

/// A throwaway directory holding a Tiltfile and a stand-in for the `tilt`
/// binary. Removed when the test's reference goes away, so nothing is left
/// behind outside the repo.
private final class TemporaryProject {
    let url: URL
    let tiltfile: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "fulcrum-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tiltfile = url.appending(path: "Tiltfile")
        try Data("print('lab')\n".utf8).write(to: tiltfile)
    }

    /// A child that stays up until the test lets it go.
    ///
    /// It records its own pid, then waits for a file only the test creates and
    /// reports having seen it. That report is the proof of life: it can only be
    /// written by a process that was still running when the gate opened. The
    /// iteration cap is a backstop so a stranded child cannot outlive the run.
    static let gatedScript = """
    #!/bin/sh
    dir=$(pwd)
    printf '%s' "$$" > "$dir/pid.txt"
    i=0
    while [ ! -f "$dir/gate" ] && [ $i -lt 400 ]; do
        sleep 0.025
        i=$((i + 1))
    done
    if [ -f "$dir/gate" ]; then
        echo opened > "$dir/gate-opened.txt"
    fi
    """

    /// Releases the gated child. Nothing else creates this file, so the child
    /// cannot have seen it before the test called this.
    func openGate() throws {
        try Data("go\n".utf8).write(to: url.appending(path: "gate"))
    }

    /// Waits for the child's answer, up to a ceiling that exists only so a
    /// broken implementation fails rather than hanging the suite. Correct
    /// behaviour answers in one poll; nothing asserts it fits in the ceiling.
    func waitForFile(_ name: String, within ceiling: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(ceiling)
        while Date() < deadline {
            if contains(name) { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return contains(name)
    }

    /// Writes an executable stand-in for `tilt`. Deliberately **not** named
    /// anything containing "tilt": its argv must never look like a real
    /// instance to a `pgrep -f "tilt up"`.
    func writeLaunchTarget(_ script: String) throws -> URL {
        let target = url.appending(path: "launch-probe")
        try Data(script.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    func contains(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: name).path)
    }

    /// Kills only the processes this test started, by the pids they recorded
    /// themselves — never anything found by searching the process table.
    func killLaunchedChild() {
        guard let text = try? String(contentsOf: url.appending(path: "pid.txt"), encoding: .utf8) else { return }
        for pid in text.split(whereSeparator: \.isWhitespace).compactMap({ Int32($0) }) {
            kill(pid, SIGKILL)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
