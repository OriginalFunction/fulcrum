import Foundation
import Testing
@testable import FulcrumKit

// MARK: - The bug this file exists for
//
// Reported as "the logs only work the first time": open the dashboard and
// `northwind`'s logs appear; switch to another project and the pane says
// "No lines were produced"; switch BACK and it says the same; close and
// reopen the window and it works again — until the next switch.
//
// The cause was ordering, not streaming. `follow(_:)` cancelled the previous
// stream task and installed a new one synchronously on the main actor. The
// previous task, however, was only *asked* to stop: a cancelled
// `AsyncThrowingStream` consumer does not throw — `next()` returns `nil`, the
// `for await` loop exits NORMALLY, and everything written after that loop then
// ran, on the main actor, AFTER the replacement was already installed. That
// trailing cleanup cancelled `self.flushTask` (by then the NEW stream's
// throttled-refresh loop, so nothing ever copied the ring buffer into `lines`
// again) and set `self.hasStreamEnded = true` on the live pane — which is
// exactly the "the stream ended before producing any output" empty state the
// user saw. Closing the window (`follow(nil)`) let the stale cleanup land
// harmlessly, so the next open worked.
//
// Measured before the fix, by this file's first test: after `follow(A)` then
// `follow(B)`, awaiting A's task to completion left B's flush task
// `isCancelled == true` and `hasStreamEnded == true`, and a line pushed to B
// never reached `lines` at all.
//
// ORDERING IS ESTABLISHED BY COMPLETION, NOT BY WAITING. Every test below
// holds the main actor across `follow(A)` → `follow(B)` (no `await` between
// them), so A's consuming task provably cannot have run yet: its loop exit and
// the cleanup after it are still ahead. `await aTask?.value` is then the gate —
// it returns only once that whole cleanup has run against a pane that already
// belongs to B. No sleep decides anything here; `untilTrue` only bounds how
// long the pane's own 150ms refresh tick may take, and fails rather than hangs.
//
// `.timeLimit` is the right bound for these — unlike the lifecycle tests'
// `Thread`-based watchdog, which exists because a deadlocked main actor never
// reaches a suspension point for a cancellation to land on. Nothing here
// spawns a process or takes a lock; the only way `await …value` fails to
// return is a `follow(_:)` that stops terminating its outgoing stream, and
// that was measured to surface as this trait's named 60s failure (and is
// covered against a real pid by `DashboardLogLifecycleTests`).

/// A `LogStreaming` double whose streams reproduce the one `LogStreamer`
/// behaviour this file turns on: **terminating a stream ends it cleanly**.
/// `LogStreamer` gets there through `onTermination` → `LogStreamChild.stop()`
/// → SIGTERM → `didStop` → `continuation.finish()`, so a cancelled consumer's
/// loop exits normally rather than throwing. `StubLogStreaming` leaves that
/// implicit (`AsyncThrowingStream` cancellation happens to finish the iterator
/// too); this states it, because it is the entire mechanism of the bug.
private final class CleanFinishOnTerminationStub: LogStreaming, @unchecked Sendable {
    private let lock = NSLock()
    /// Keyed by instance id and deliberately overwritten by a later call for
    /// the same id: a switch away and back makes two `stream()` calls for one
    /// instance, and `push`/`finish` must address the newer one.
    private var continuations: [TiltInstance.InstanceID: AsyncThrowingStream<LogLine, any Error>.Continuation] = [:]
    private var terminatedCount = 0

    /// How many streams have terminated for any reason — the stub's own view
    /// of `onTermination`, which is what kills the real child.
    var terminationCount: Int { lock.withLock { terminatedCount } }

    func stream(instance: TiltInstance, tail: Int) -> AsyncThrowingStream<LogLine, any Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { continuations[instance.id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.terminatedCount += 1 }
                // The `LogStreamer` behaviour under test: the stream ends
                // cleanly, so the consumer's loop returns rather than throws.
                continuation.finish()
            }
        }
    }

    func push(_ line: LogLine, to id: TiltInstance.InstanceID) {
        lock.withLock { continuations[id] }?.yield(line)
    }

    func fail(_ id: TiltInstance.InstanceID, error: any Error) {
        lock.withLock { continuations[id] }?.finish(throwing: error)
    }
}

private struct StaleStubError: Error, CustomStringConvertible {
    var description: String { "the superseded stream's failure" }
}

private func instance(port: Int) -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data("pem".utf8), token: "t\(port)"
    ))
}

/// Waits for a condition the pane's own throttled refresh loop is responsible
/// for making true, and FAILS — naming what it waited for — rather than
/// hanging if that loop is dead. Bounded far above the 150ms tick it waits on,
/// so it discriminates "the loop is gone" from "the machine is busy".
@MainActor
private func untilTrue(
    _ description: String,
    within seconds: Double = 5,
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "timed out after \(seconds)s waiting for \(description)", sourceLocation: sourceLocation)
}

// MARK: - The regression

/// THE test: the user's step 2. Switching instances must leave the new
/// stream's pipeline completely intact — its flush loop running, its lines
/// reaching `lines`, and no claim that it has ended.
///
/// The `lines` assertion deliberately never calls `refreshIfNeeded()`: the
/// symptom was that the pane's OWN loop had been cancelled out from under it,
/// and a test that pumped the refresh by hand would have passed against the
/// broken code while the app stayed blank.
@Test(.timeLimit(.minutes(1))) @MainActor
func switchingInstancesLeavesTheNewStreamsFlushLoopDelivering() async {
    let stub = CleanFinishOnTerminationStub()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    let aTask = pane.streamTaskForTesting

    pane.follow(b) // no await in between — A's task has provably not run yet
    let bFlush = pane.flushTaskForTesting

    await aTask?.value // the gate: A's cleanup has now run, in full, against B's pane

    #expect(bFlush?.isCancelled == false, "the superseded stream cancelled the new stream's flush loop")
    #expect(!pane.hasStreamEnded, "the superseded stream declared the new stream ended")
    #expect(pane.streamError == nil)

    stub.push(line(message: "from-b"), to: b.id)
    await untilTrue("B's own flush loop to publish its line") { !pane.lines.isEmpty }
    #expect(pane.lines.map(\.line.message) == ["from-b"])
    #expect(pane.emptyState == nil)

    pane.follow(nil)
}

/// The same ordering told through the empty state the user actually read.
/// Deterministic to the last assertion — no polling at all.
@Test(.timeLimit(.minutes(1))) @MainActor
func aSupersededStreamNeverReportsTheNewStreamAsEndedWithNoLines() async {
    let stub = CleanFinishOnTerminationStub()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    let aTask = pane.streamTaskForTesting
    pane.follow(b)
    await aTask?.value

    // B's stream is open and simply has not produced anything yet: "waiting",
    // never "the stream ended before producing any output".
    #expect(pane.emptyState == .waitingForLines)

    pane.follow(nil)
}

/// A superseded stream's backlog must not be poured into the new stream's
/// buffer. Lines pushed to A while the main actor is held are buffered by
/// `AsyncThrowingStream` and handed to A's consumer even though it is
/// cancelled by then (measured: an already-cancelled iterator still received
/// every buffered element), so the loop's guard is the only thing standing
/// between A's history and B's pane.
@Test(.timeLimit(.minutes(1))) @MainActor
func aSupersededStreamsBufferedLinesNeverLandInTheNewStreamsBuffer() async {
    let stub = CleanFinishOnTerminationStub()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    stub.push(line(message: "from-a-1"), to: a.id)
    stub.push(line(message: "from-a-2"), to: a.id)
    let aTask = pane.streamTaskForTesting

    pane.follow(b)
    await aTask?.value

    stub.push(line(message: "from-b"), to: b.id)
    await untilTrue("B's line to arrive") { !pane.lines.isEmpty }
    #expect(pane.lines.map(\.line.message) == ["from-b"])
}

/// A superseded stream's FAILURE must not be reported as the new stream's.
/// The error is armed before the switch so it is already terminal when A's
/// consumer resumes — the only way a stale `catch` can fire at all.
@Test(.timeLimit(.minutes(1))) @MainActor
func aSupersededStreamsFailureNeverSurfacesOnTheNewStream() async {
    let stub = CleanFinishOnTerminationStub()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    stub.fail(a.id, error: StaleStubError())
    let aTask = pane.streamTaskForTesting

    pane.follow(b)
    await aTask?.value

    #expect(pane.streamError == nil, "the superseded stream's failure was shown against the new one")
    #expect(!pane.hasStreamEnded)
    #expect(pane.flushTaskForTesting?.isCancelled == false)

    pane.follow(nil)
}

/// The user's steps 2 and 3 back to back, with no `await` anywhere in the
/// sequence: A → B → A, then both superseded tasks allowed to finish. Two
/// stale cleanups now land on one live pane, which is what made the switch
/// back to `northwind` fail as well.
@Test(.timeLimit(.minutes(1))) @MainActor
func rapidlySwitchingBackAndForthLeavesOnlyTheFinalStreamLive() async {
    let stub = CleanFinishOnTerminationStub()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    let first = pane.streamTaskForTesting
    pane.follow(b)
    let second = pane.streamTaskForTesting
    pane.follow(a) // back to A: a second, distinct stream for the same instance
    let third = pane.streamTaskForTesting

    await first?.value
    await second?.value

    #expect(third?.isCancelled == false)
    #expect(pane.flushTaskForTesting?.isCancelled == false)
    #expect(!pane.hasStreamEnded)
    #expect(pane.currentlyFollowedInstanceID == a.id)

    stub.push(line(message: "from-a-again"), to: a.id)
    await untilTrue("the third stream's line to reach the pane") { !pane.lines.isEmpty }
    #expect(pane.lines.map(\.line.message) == ["from-a-again"])

    pane.follow(nil)
}

/// `follow(nil)` mid-flight — the dashboard window closing — must leave the
/// pane genuinely "not following", not "ended". Before the fix the stale
/// cleanup set `hasStreamEnded` on a pane that was following nothing at all,
/// and re-following had to reset it to hide the damage.
@Test(.timeLimit(.minutes(1))) @MainActor
func followingNilMidFlightLeavesThePaneNotFollowingRatherThanEnded() async {
    let stub = CleanFinishOnTerminationStub()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)

    pane.follow(a)
    let aTask = pane.streamTaskForTesting

    pane.follow(nil) // exactly `DashboardWindowController.windowWillClose`
    await aTask?.value

    #expect(!pane.hasStreamEnded)
    #expect(!pane.isFollowingAnInstance)
    #expect(pane.lines.isEmpty)
    #expect(pane.streamError == nil)
    #expect(pane.emptyState == .notFollowing)
    #expect(stub.terminationCount == 1, "closing the window must terminate the stream (the real child's kill signal)")

    // The user's step 4: reopening the window streams again, and the stale
    // cleanup that already landed must not have poisoned the new stream.
    pane.follow(a)
    #expect(!pane.hasStreamEnded)
    stub.push(line(message: "after-reopen"), to: a.id)
    await untilTrue("the reopened stream's line to reach the pane") { !pane.lines.isEmpty }
    #expect(pane.lines.map(\.line.message) == ["after-reopen"])

    pane.follow(nil)
}

/// The guard must not have bought staleness safety by breaking the ordinary
/// path: a stream that genuinely ends still flushes its last, unticked line
/// and still reports itself ended. (The dropped-final-line race this protects
/// is the same one `LogStreamChild.finishIfComplete` was fixed for.)
@Test(.timeLimit(.minutes(1))) @MainActor
func aGenuineStreamEndStillFlushesItsResidualLineAndReportsEnded() async {
    let stub = CleanFinishOnTerminationStub()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)

    pane.follow(a)
    stub.push(line(message: "the last line"), to: a.id)
    // Ends the stream with the line still unflushed — no refresh tick has had
    // a chance to run, so only the stream task's own final flush can publish it.
    stub.fail(a.id, error: StaleStubError())
    await pane.streamTaskForTesting?.value

    #expect(pane.lines.map(\.line.message) == ["the last line"])
    #expect(pane.hasStreamEnded)
    #expect(pane.streamError != nil)
}
