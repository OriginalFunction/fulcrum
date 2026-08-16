import Foundation
import Testing
@testable import FulcrumKit

// MARK: - Harness
//
// Task 6's whole point is the lifecycle of the `tilt logs --follow` child
// behind `dashboard.logPane` — every test in this file drives a REAL
// `LogStreamer` against `/bin/sh` (never against a live `tilt`, same
// discipline `LogStreamerTests` uses) and verifies a real pid, the way that
// file's own doc comment insists on: asserting only that a stream ended
// proves nothing about the child still running behind it.
//
// Each spawned script writes its own pid to a fresh file before looping,
// rather than reporting it as the first log line the way `LogStreamerTests`
// does — a stream that gets cancelled within milliseconds of starting (the
// rapid-switch case below) may never get a line through the throttled
// `LogPaneModel` pipeline at all, and pid discovery must not race that.

private struct TestTimeout: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "the operation did not finish within \(seconds)s" }
}

/// Fails, rather than hangs, when the thing under test stops making
/// progress — same shape and same reasoning as `LogStreamerTests.within`:
/// one test on this project once stalled a run for six minutes under
/// mutation with no diagnosis.
@discardableResult
private func within<T: Sendable>(
    _ seconds: Double = 10,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeout(seconds: seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

/// `ps` output for `pid`, or nil when no such process exists — makes a
/// failure say *what* survived instead of just "still alive".
private func psDescription(_ pid: Int32) async -> String? {
    let runner = ProcessCommandRunner(timeout: 5)
    guard let output = try? await runner.run(
        URL(fileURLWithPath: "/bin/ps"), ["-o", "state=,comm=", "-p", "\(pid)"]
    ) else { return nil }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Polls rather than asserting once: termination and reaping are
/// asynchronous, same as `LogStreamerTests`'s own cancellation tests.
private func waitForDeath(_ pid: Int32, timeout: Double = 10) async {
    let deadline = Date().addingTimeInterval(timeout)
    while isAlive(pid) && Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

private func instance(port: Int) -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data("pem".utf8), token: "t\(port)"
    ))
}

@MainActor private func makeDashboard(logStreaming: any LogStreaming) -> (DashboardModel, AppModel) {
    let app = AppModel(settings: SettingsStore(defaults: TestUserDefaults.fresh()), aliasesDefaults: TestUserDefaults.fresh())
    let recents = RecentsStore(storage: InMemoryRecentsStorage())
    return (DashboardModel(appModel: app, recents: recents, logStreaming: logStreaming), app)
}

/// A directory under `FileManager.default.temporaryDirectory`, unique per
/// test and removed by the caller's `defer` — same pattern
/// `RecentsStoreTests.fileStorageRoundTripsThroughARealFile` uses so a whole
/// directory (not a loose file) is what gets cleaned up.
private func makeScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "fulcrum-log-lifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A `LogStreamer` whose "tilt" is `/bin/sh`: each call writes its own pid to
/// a fresh, uniquely-numbered file in `directory` before looping, decoupling
/// pid discovery from the log-delivery channel entirely.
private final class PidFileStreamerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func makeStreamer() -> LogStreamer {
        LogStreamer(binary: URL(fileURLWithPath: "/bin/sh")) { [self] _, _ in
            let n = lock.withLock { count += 1; return count }
            let pidFile = directory.appendingPathComponent("call-\(n).pid").path
            let script = """
            echo $$ > '\(pidFile)'
            fmt='{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"tick","spanID":"s","progressID":"","buildEvent":"","source":"runtime"}'
            while :; do echo "$fmt"; sleep 0.2; done
            """
            return ["-c", script]
        }
    }

    /// The pid the `n`th `stream(instance:tail:)` call's child reported,
    /// waiting for the file to appear rather than assuming it already has.
    func pid(forCall n: Int) async throws -> Int32 {
        let file = directory.appendingPathComponent("call-\(n).pid")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestTimeout(seconds: 10)
    }
}

// MARK: - Step 1: one stream at a time, with a real child process

/// The stub-based tests in `DashboardModelTests` already prove the settled
/// outcome deterministically; this confirms the same story end to end
/// against a real spawned process, the way `LogStreamerTests` verifies
/// `LogStreamer` itself.
@Test(.timeLimit(.minutes(1))) @MainActor func rapidlySwitchingInstancesLeavesExactlyOneRealChildAlive() async throws {
    let watchdog = MainThreadWatchdog("rapidlySwitchingInstancesLeavesExactlyOneRealChildAlive")
    defer { watchdog.done() }
    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = PidFileStreamerFactory(directory: directory)
    let (dashboard, app) = makeDashboard(logStreaming: factory.makeStreamer())
    app.sync(with: [instance(port: 10350), instance(port: 10360)])

    dashboard.logPane.follow(dashboard.selectedInstance) // simulates the window opening; call 1
    let firstPID = try await within { try await factory.pid(forCall: 1) }
    #expect(isAlive(firstPID), "the first child never came up")

    // No `await` between this and the follow above — the shape rapid
    // sidebar arrowing produces.
    dashboard.selectedSidebarID = "port-10360" // call 2

    let secondPID = try await within { try await factory.pid(forCall: 2) }
    try await within { await waitForDeath(firstPID) }

    let firstSurvivor = isAlive(firstPID) ? await psDescription(firstPID) : nil
    #expect(firstSurvivor == nil, "the previous instance's child \(firstPID) survived switching: \(firstSurvivor ?? "")")
    #expect(isAlive(secondPID), "the newly selected instance's child \(secondPID) should still be running")
}

// MARK: - Step 3: stop cleanly

/// Case 1 of 3: closing the dashboard window. `DashboardWindowController`
/// lives in the app target and cannot be unit tested here, but its
/// `windowWillClose` calls exactly `dashboard.logPane.follow(nil)` — this
/// proves that call, against a real child, actually kills it.
@Test(.timeLimit(.minutes(1))) @MainActor func closingTheDashboardWindowStopsTheRealChildProcess() async throws {
    let watchdog = MainThreadWatchdog("closingTheDashboardWindowStopsTheRealChildProcess")
    defer { watchdog.done() }
    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = PidFileStreamerFactory(directory: directory)
    let (dashboard, app) = makeDashboard(logStreaming: factory.makeStreamer())
    app.sync(with: [instance(port: 10370)])

    dashboard.logPane.follow(dashboard.selectedInstance) // window opening
    let pid = try await within { try await factory.pid(forCall: 1) }
    #expect(isAlive(pid), "the child never came up before the close")

    dashboard.logPane.follow(nil) // exactly `DashboardWindowController.windowWillClose`'s call

    try await within { await waitForDeath(pid) }
    let survivor = isAlive(pid) ? await psDescription(pid) : nil
    #expect(survivor == nil, "child pid \(pid) survived the window closing: \(survivor ?? "")")
    #expect(!dashboard.logPane.isFollowingAnInstance)
}

/// The close's missing other half, against a real child: reopening the
/// dashboard window must bring a NEW `tilt logs` child up. It did not — the
/// pane rendered its header row over nothing from the second open onwards,
/// which is the entire "the logs don't always appear" report (see
/// `DashboardModelTests.reopeningTheDashboardWindowStartsTheStreamAgain` for
/// the instrumented sequence and the cause).
///
/// A real process here rather than only the counted stub, for this file's
/// stated reason: a second `stream(instance:tail:)` call proves the model
/// asked, and only a live pid proves anything actually came back up. The
/// assertion is the existence of call 2's pid file — a count, not a clock;
/// `within` only bounds the wait so a regression fails fast instead of
/// hanging.
@Test(.timeLimit(.minutes(1))) @MainActor func reopeningTheDashboardWindowStartsARealChildProcessAgain() async throws {
    let watchdog = MainThreadWatchdog("reopeningTheDashboardWindowStartsARealChildProcessAgain")
    defer { watchdog.done() }
    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = PidFileStreamerFactory(directory: directory)
    let (dashboard, app) = makeDashboard(logStreaming: factory.makeStreamer())
    app.sync(with: [instance(port: 10370)])

    dashboard.dashboardWindowDidBecomeVisible() // `DashboardWindowController.show()`
    let firstPID = try await within { try await factory.pid(forCall: 1) }
    dashboard.logPane.follow(nil) // `windowWillClose`
    try await within { await waitForDeath(firstPID) }

    dashboard.dashboardWindowDidBecomeVisible() // `show()` again

    let secondPID = try await within { try await factory.pid(forCall: 2) }
    #expect(isAlive(secondPID), "the reopened window's child \(secondPID) is not running")
    #expect(dashboard.logPane.currentlyFollowedInstanceID == dashboard.selectedInstance?.id)

    // Clean up: nothing else in this test stops the second stream.
    dashboard.logPane.follow(nil)
    try await within { await waitForDeath(secondPID) }
}

/// Case 2 of 3: quitting the app. `AppDelegate.applicationWillTerminate`
/// also calls exactly `dashboard.logPane.follow(nil)`, alongside stopping
/// every `InstanceSupervisor` — proven identically to the window-close case
/// because it is, deliberately, the same call: `logPane`'s stream is not a
/// supervisor and nothing else in `applicationWillTerminate` would reach it.
@Test(.timeLimit(.minutes(1))) @MainActor func quittingTheAppStopsTheRealChildProcess() async throws {
    let watchdog = MainThreadWatchdog("quittingTheAppStopsTheRealChildProcess")
    defer { watchdog.done() }
    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = PidFileStreamerFactory(directory: directory)
    let (dashboard, app) = makeDashboard(logStreaming: factory.makeStreamer())
    app.sync(with: [instance(port: 10370)])

    dashboard.logPane.follow(dashboard.selectedInstance)
    let pid = try await within { try await factory.pid(forCall: 1) }
    #expect(isAlive(pid), "the child never came up before quitting")

    dashboard.logPane.follow(nil) // exactly `AppDelegate.applicationWillTerminate`'s call

    try await within { await waitForDeath(pid) }
    let survivor = isAlive(pid) ? await psDescription(pid) : nil
    #expect(survivor == nil, "child pid \(pid) survived the app quitting: \(survivor ?? "")")
}

/// Case 3 of 3: the followed instance disappearing from discovery.
/// `AppDelegate.reconcile(with:)` calls `AppModel.sync(with:)` then
/// `DashboardModel.followSelectedInstanceLogs()` — exactly reproduced here,
/// against a real child, without the window ever needing to be open or
/// re-rendering for it to happen.
@Test(.timeLimit(.minutes(1))) @MainActor func anInstanceDisappearingFromDiscoveryStopsItsRealChildProcess() async throws {
    let watchdog = MainThreadWatchdog("anInstanceDisappearingFromDiscoveryStopsItsRealChildProcess")
    defer { watchdog.done() }
    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = PidFileStreamerFactory(directory: directory)
    let (dashboard, app) = makeDashboard(logStreaming: factory.makeStreamer())
    app.sync(with: [instance(port: 10370)])

    dashboard.logPane.follow(dashboard.selectedInstance) // window already open, following 10370
    let pid = try await within { try await factory.pid(forCall: 1) }
    #expect(isAlive(pid), "the child never came up before disappearing")

    // The instance vanishes from discovery — `reconcile(with:)`'s real
    // sequence: sync first, then re-point (or stop) the pane.
    app.sync(with: [])
    dashboard.followSelectedInstanceLogs()

    try await within { await waitForDeath(pid) }
    let survivor = isAlive(pid) ? await psDescription(pid) : nil
    #expect(survivor == nil, "child pid \(pid) survived its instance disappearing: \(survivor ?? "")")
    #expect(!dashboard.logPane.isFollowingAnInstance)
}

/// The companion case to the previous test: discovery losing an instance
/// that is NOT the one currently followed must not disturb the followed
/// one's child at all.
@Test(.timeLimit(.minutes(1))) @MainActor func discoveryLosingAnUnrelatedInstanceLeavesTheFollowedChildRunning() async throws {
    let watchdog = MainThreadWatchdog("discoveryLosingAnUnrelatedInstanceLeavesTheFollowedChildRunning")
    defer { watchdog.done() }
    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = PidFileStreamerFactory(directory: directory)
    let (dashboard, app) = makeDashboard(logStreaming: factory.makeStreamer())
    app.sync(with: [instance(port: 10350), instance(port: 10360)])
    dashboard.selectedSidebarID = "port-10350"

    dashboard.logPane.follow(dashboard.selectedInstance)
    let pid = try await within { try await factory.pid(forCall: 1) }
    #expect(isAlive(pid))

    app.sync(with: [instance(port: 10350)]) // 10360 disappears; 10350 (followed) stays
    dashboard.followSelectedInstanceLogs()

    // No teardown should happen here — give it a moment to prove nothing
    // changes rather than only checking the instant after.
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(isAlive(pid), "the followed instance's child was killed by an unrelated instance disappearing")
    #expect(dashboard.logPane.isFollowingAnInstance)

    // Clean up: nothing else in this test stops the stream.
    dashboard.logPane.follow(nil)
    try await within { await waitForDeath(pid) }
}

// MARK: - Step 4: the lifecycle calls must not deadlock

/// Fails the run loudly when the main thread stops making progress.
///
/// `.timeLimit` cannot do this job, and every test in this file already
/// carries one. It enforces its limit by cancelling the test's `Task`, and a
/// deadlocked main actor never reaches a suspension point to notice — which
/// is exactly how an ABBA inversion between `LogStreamChild`'s mutex and the
/// concurrency runtime's task-status lock stalled a full-suite run for 13
/// minutes with no diagnosis, three times over. This runs on its own
/// `Thread`, outside the concurrency runtime, so it still fires when the main
/// thread is wedged. It cannot unblock a deadlock; it converts one into a
/// fast, named failure, which is the difference between a diagnosis and a
/// beachball.
private final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    init(_ label: String, seconds: Double = 60) {
        let thread = Thread { [self] in
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                if lock.withLock({ finished }) { return }
            }
            FileHandle.standardError.write(Data("""

            FATAL: \(label) made no progress for \(Int(seconds))s.
            The main thread is almost certainly deadlocked: check that nothing
            reached from AsyncThrowingStream's onTermination (LogStreamChild.stop)
            blocks on a lock the delivery path holds while calling yield.
            Sample the process to confirm: `sample <pid> 3`.

            """.utf8))
            exit(EXIT_FAILURE)
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func done() { lock.withLock { finished = true } }
}

/// Cancelling a stream whose child is flooding stdout is the exact shape that
/// deadlocked: the delivery path is mid-`yield` while `follow(nil)` cancels
/// the consuming task on the main actor, so `LogStreamChild.stop` blocked on a
/// mutex held by `readStdout` → `emit` → `yield` →
/// `flagAsAndEnqueueOnExecutor`. The `--tail 2000` replay is precisely this
/// busy period, so the user-facing version is: click another project, close
/// the window, or quit while logs are pouring in, and the app never comes back.
///
/// **What this test does and does not guarantee.** What it checks
/// deterministically is that each of 25 cancellations mid-flood actually kills
/// its child. It is *not* a reliable deadlock detector on its own: run in
/// isolation against the broken implementation it passed 25 and 60 iterations
/// without hanging. What does detect the deadlock is the full suite's
/// contention — measured against the broken implementation, 3 of 3 full-suite
/// runs hung, this test's watchdog firing in 2 of them and
/// `discoveryLosingAnUnrelatedInstanceLeavesTheFollowedChildRunning`'s in the
/// third. The guarantee against this bug class comes from the locking
/// discipline documented on `LogStreamChild`; the watchdog only ensures a
/// regression costs 60 seconds and names itself instead of stalling a run for
/// 13 minutes.
@Test(.timeLimit(.minutes(1))) @MainActor func cancellingAFloodingStreamNeverDeadlocks() async throws {
    let watchdog = MainThreadWatchdog("cancellingAFloodingStreamNeverDeadlocks")
    defer { watchdog.done() }

    let directory = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let factory = FloodingStreamerFactory(directory: directory)
    let (dashboard, app) = makeDashboard(logStreaming: factory.makeStreamer())
    app.sync(with: [instance(port: 10370)])

    for i in 1...25 {
        dashboard.logPane.follow(dashboard.selectedInstance)
        // Wait for the child to exist before cancelling it, so cancellation
        // lands on a stream that is genuinely mid-delivery rather than one
        // still being spawned.
        let pid = try await factory.pid(forCall: i)
        try await Task.sleep(nanoseconds: 20_000_000)

        dashboard.logPane.follow(nil)

        await waitForDeath(pid)
        #expect(!isAlive(pid), "iteration \(i): child \(pid) survived cancellation")
    }
}

/// A child that floods stdout with no pause, so the delivery path is almost
/// always mid-yield when cancellation lands. `PidFileStreamerFactory`'s
/// `sleep 0.2` deliberately leaves that window mostly empty; this one removes
/// it, and that difference is what makes the deadlock reproducible.
private final class FloodingStreamerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func makeStreamer() -> LogStreamer {
        LogStreamer(binary: URL(fileURLWithPath: "/bin/sh")) { [self] _, _ in
            let n = lock.withLock { count += 1; return count }
            let pidFile = directory.appendingPathComponent("call-\(n).pid").path
            let script = """
            echo $$ > '\(pidFile)'
            fmt='{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"flood","spanID":"s","progressID":"","buildEvent":"","source":"runtime"}'
            while :; do echo "$fmt"; done
            """
            return ["-c", script]
        }
    }

    func pid(forCall n: Int) async throws -> Int32 {
        let file = directory.appendingPathComponent("call-\(n).pid")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestTimeout(seconds: 10)
    }
}
