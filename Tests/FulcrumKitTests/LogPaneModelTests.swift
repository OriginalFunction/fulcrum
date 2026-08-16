import Foundation
import Observation
import Testing
@testable import FulcrumKit

// MARK: - Harness
//
// `LogPaneModel` is driven through the `LogStreaming` seam, never a real
// `tilt logs` process — this stub hands back one controllable
// `AsyncThrowingStream` per `stream(instance:tail:)` call, keyed by instance,
// so a test can push lines and end the stream (cleanly or with an error) on
// its own schedule. Mirrors `StubCommandRunner`'s shape: a lock-protected
// `final class`, `@unchecked Sendable`, because the continuations are
// captured and driven from the test body while `LogPaneModel` consumes them
// concurrently from its own `Task`.
//
// Not `private`: `DashboardModelTests` reuses this to prove `DashboardModel`
// actually wires its injected `logStreaming` through to `logPane`, the same
// "shared, not `private`" precedent as `LogBufferTests.line(...)`.
final class StubLogStreaming: LogStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [TiltInstance.InstanceID: AsyncThrowingStream<LogLine, any Error>.Continuation] = [:]
    private var recordedInstances: [TiltInstance.InstanceID] = []
    /// Every *call* to `stream(instance:tail:)` whose stream has started but
    /// not yet terminated (cancelled, `finish()`ed, or failed) — driven by
    /// `onTermination`, the same signal `LogStreamer` itself reacts to by
    /// killing its child. Keyed by a per-call token, not by instance id: a
    /// test that selects the same instance twice (switch away, switch back)
    /// makes two separate `stream()` calls for the same id, and the first
    /// one's `onTermination` firing late must not evict the second, still-
    /// live one just because they share an instance id.
    private var active: [UUID: TiltInstance.InstanceID] = [:]
    /// Instance ids whose streams must take a while to *report* that they
    /// terminated — see `delayTerminationReporting(for:by:)`.
    private var terminationDelays: [TiltInstance.InstanceID: Duration] = [:]

    var streamedInstanceCount: Int { lock.withLock { recordedInstances.count } }
    var mostRecentlyStreamedInstanceID: TiltInstance.InstanceID? { lock.withLock { recordedInstances.last } }
    var activeInstanceIDs: Set<TiltInstance.InstanceID> { lock.withLock { Set(active.values) } }
    /// How many *calls* to `stream(instance:tail:)` are still live — the count
    /// of un-terminated tokens, which `activeInstanceIDs` cannot report because
    /// it collapses two live streams for the same instance into one element.
    /// A test that switches away from an instance and back again has exactly
    /// that shape, so "one stream left" and "one instance id left" are
    /// different claims there and only the former means *converged*.
    var activeStreamCount: Int { lock.withLock { active.count } }

    /// Makes every stream opened for `id` wait `delay` before dropping itself
    /// from `active`, without changing when it actually terminates.
    ///
    /// This models the thing that made `settledActiveInstanceIDs` flaky on
    /// correct code: `onTermination` is what evicts a superseded stream, and
    /// under swift-testing's parallel execution the executor can take an
    /// arbitrarily long time to get to a cancelled-but-never-scheduled task.
    /// Armed, it turns a scheduling stall that only *sometimes* exceeded the
    /// old helper's 200ms quiet period into one that always does.
    func delayTerminationReporting(for id: TiltInstance.InstanceID, by delay: Duration) {
        lock.withLock { terminationDelays[id] = delay }
    }

    func stream(instance: TiltInstance, tail: Int) -> AsyncThrowingStream<LogLine, any Error> {
        let token = UUID()
        let instanceID = instance.id
        lock.withLock {
            recordedInstances.append(instanceID)
            active[token] = instanceID
        }
        return AsyncThrowingStream { continuation in
            lock.withLock { continuations[instanceID] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                guard let delay = self.lock.withLock({ self.terminationDelays[instanceID] }) else {
                    self.lock.withLock { _ = self.active.removeValue(forKey: token) }
                    return
                }
                Task.detached {
                    try? await Task.sleep(for: delay)
                    self.lock.withLock { _ = self.active.removeValue(forKey: token) }
                }
            }
        }
    }

    func push(_ line: LogLine, to id: TiltInstance.InstanceID) {
        lock.withLock { continuations[id] }?.yield(line)
    }

    func finish(_ id: TiltInstance.InstanceID) {
        lock.withLock { continuations[id] }?.finish()
    }

    func fail(_ id: TiltInstance.InstanceID, error: any Error) {
        lock.withLock { continuations[id] }?.finish(throwing: error)
    }
}

private struct StubError: Error, CustomStringConvertible {
    var description: String { "stub stream failure" }
}

private func instance(port: Int) -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data("pem".utf8), token: "t\(port)"
    ))
}

// MARK: - Streaming lifecycle

@Test @MainActor func followStartsStreamingTheGivenInstance() {
    // THE GIVEN instance, not merely "a" stream: a count alone passes for a
    // `follow` that opened a stream against the wrong instance, which is the
    // one failure this name rules out. `mostRecentlyStreamedInstanceID` exists
    // for exactly that distinction.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)

    #expect(stub.streamedInstanceCount == 1)
    #expect(stub.mostRecentlyStreamedInstanceID == target.id)
}

@Test @MainActor func followIsANoOpWhenTheInstanceHasNotChanged() {
    // Re-selecting the same already-followed instance must not restart the
    // stream — the view is expected to call `follow` on every render where
    // the selection *might* have changed, and a real restart on each of
    // those would drop the buffer and flicker the pane constantly.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)
    pane.follow(target)
    pane.follow(target)
    pane.follow(target)
    #expect(stub.streamedInstanceCount == 1)
}

@Test @MainActor func isFollowingAnInstanceReflectsWhetherFollowHasEverBeenStarted() {
    // `DashboardModel.followSelectedInstanceLogs()` reads this to decide
    // whether discovery reconciling the instance set is allowed to touch
    // the pane at all — it must not start a stream on its own the first
    // time, only re-point one that's already running.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    #expect(!pane.isFollowingAnInstance)

    pane.follow(instance(port: 10350))
    #expect(pane.isFollowingAnInstance)

    pane.follow(nil)
    #expect(!pane.isFollowingAnInstance)
}

@Test @MainActor func followingNilAfterAnInstanceAllowsReselectingItLater() {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)
    pane.follow(target)
    pane.follow(nil)
    pane.follow(target)
    #expect(stub.streamedInstanceCount == 2)
}

@Test @MainActor func switchingInstancesClearsThePreviousBuffer() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    stub.push(line(message: "from-a"), to: a.id)
    stub.finish(a.id)
    await pane.streamTaskForTesting?.value

    #expect(pane.lines.map(\.line.message) == ["from-a"])

    pane.follow(b)
    #expect(pane.lines.isEmpty)
    #expect(pane.droppedCount == 0)
}

@Test @MainActor func streamEndingCleanlyFlushesTheFinalLinesWithoutWaitingForATick() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "one"), to: target.id)
    stub.push(line(message: "two"), to: target.id)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value

    #expect(pane.lines.map(\.line.message) == ["one", "two"])
}

@Test @MainActor func streamFailureSurfacesAsAReadableMessage() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "before the failure"), to: target.id)
    stub.fail(target.id, error: StubError())
    await pane.streamTaskForTesting?.value

    // READABLE is the claim, so the text is asserted rather than its
    // non-nil-ness: this banner is shown to the user verbatim, and non-nil is
    // equally true of `String(reflecting:)`'s `FulcrumKitTests.StubError()`.
    // The error's own description is what comes through.
    #expect(pane.streamError == "stub stream failure")
    // The failure ends the stream, but whatever arrived before it is not
    // thrown away — same "don't lose what already arrived" rule
    // `LogStreamer` itself follows on a child's abnormal exit.
    #expect(pane.lines.map(\.line.message) == ["before the failure"])

    // And on the error type the app actually throws here, the readable text is
    // tilt's own stderr, verbatim — `tiltActionFailureMessage(for:)`'s whole
    // job, and the difference between a banner the user can act on and
    // "commandFailed(exitCode: 1, stderr: ...)".
    let second = LogPaneModel(streaming: stub)
    let other = instance(port: 10360)
    second.follow(other)
    stub.fail(other.id, error: TiltActionError.commandFailed(
        exitCode: 1, stderr: "Error: could not connect to tilt at 127.0.0.1:10360\n"
    ))
    await second.streamTaskForTesting?.value

    #expect(second.streamError == "Error: could not connect to tilt at 127.0.0.1:10360")
}

/// Waits until no stream opened on `stub` is still live, then reports how many
/// are — the same counted answer, and the same hang-guard shape, as
/// `DashboardModelTests.settledActiveInstanceIDs`.
///
/// The deadline is a guard against hanging, not an assertion about speed:
/// nothing here requires termination to happen *within* it. A stream that is
/// never cancelled never terminates, so the poll runs out, the count comes back
/// non-zero and the caller's `#expect` fails naming the leak — strictly more
/// useful than a timeout with no explanation. 10s is the bound the process-
/// reaping waits in `LogStreamerTests` already use.
@MainActor private func settledActiveStreamCount(
    _ stub: StubLogStreaming, timeout: Double = 10
) async throws -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while stub.activeStreamCount != 0 && Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return stub.activeStreamCount
}

@Test(.timeLimit(.minutes(1))) @MainActor func followingNilStopsTheStreamAndClearsState() async throws {
    // BOTH halves of the name. The version this replaces called
    // `stub.finish(...)` and awaited the stream task before `follow(nil)`, so
    // the stream was already over and "stops the stream" could not fail:
    // deleting `session?.cancel()` from `follow(_:)` left it green. Here the
    // stream is still LIVE when `follow(nil)` runs, and its termination —
    // driven by `onTermination`, the same signal `LogStreamer` reacts to by
    // killing its child — is what the count below observes.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    // Straight into the ring buffer, so `lines` has content to clear without
    // ending the stream to flush it.
    pane.receive(line(message: "one"))
    pane.refreshIfNeeded()
    #expect(!pane.lines.isEmpty)
    #expect(stub.activeStreamCount == 1, "the stream must still be live for this test to mean anything")

    pane.follow(nil)

    // Clears state.
    #expect(pane.lines.isEmpty)
    #expect(pane.streamError == nil)
    // Stops the stream.
    let stillLive = try await settledActiveStreamCount(stub)
    #expect(stillLive == 0, "the stream outlived follow(nil)")
}

// MARK: - Throttled refresh
//
// These drive ingestion through `receive(_:)`, the package-internal test
// seam, rather than through a real stream — asserting "not per append" by
// racing a background consumer against a real timer is exactly the kind of
// timing-based test this project has been burned by twice already (see
// `LogFilter.apply`'s doc comment). Calling `receive` directly makes the
// coalescing behaviour a deterministic, synchronous fact instead.

@Test @MainActor func refreshIsThrottledNotPerAppend() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for i in 1...50 {
        pane.receive(line(message: "m\(i)"))
    }
    // Fifty appends, zero refreshes: `lines` must still reflect nothing.
    #expect(pane.lines.isEmpty)

    pane.refreshIfNeeded()
    #expect(pane.lines.count == 50)

    // A second call with nothing newly appended must be a no-op, not a
    // second O(capacity) copy — this is the "coalesce, don't re-read on
    // every tick regardless" half of the contract.
    pane.refreshIfNeeded()
    #expect(pane.lines.count == 50)
}

// MARK: - Adaptive refresh interval
//
// The pane's cost is `publications/sec x cost/publication`. A coalescer that
// publishes on a timer holds the first term nearly constant whatever the
// stream does — `occupancy-hypothesis.md` measured 5.93 / 6.47 / 6.24 / 6.25
// publications per second at 6 / 50 / 500 / 1,200 lines/sec — so the term
// that actually varies is the second, and it is O(buffer occupancy). The
// interval is therefore selected from OCCUPANCY, not from arrival rate.
//
// Every assertion below is a count, a buffer state, or a selected constant.
// Nothing sleeps, waits for a tick, or measures one; `refreshIfNeeded()` is
// driven directly, the same shape the throttling tests above use. A test that
// timed this feature would measure the machine.

/// Appends `count` lines and takes one tick, then answers with the interval
/// the policy selected for the NEXT tick.
@MainActor private func intervalAfterTick(receiving count: Int, on pane: LogPaneModel) -> Duration {
    if count > 0 {
        for i in 1...count { pane.receive(line(message: "m\(i)")) }
    }
    pane.refreshIfNeeded()
    return pane.activeRefreshInterval
}

@Test @MainActor func aTickCoalescesEveryLineThatArrivedSinceTheLastOne() {
    // The coalescer's own contract, asserted as a count. Not a policy input
    // any more — see `theIntervalIsSelectedByOccupancyNotByArrivalRate` — but
    // still the reason one publication can absorb a burst.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for i in 1...200 { pane.receive(line(message: "m\(i)")) }

    pane.refreshIfNeeded()
    #expect(pane.linesCoalescedByLastTick == 200, "200 arrivals must fold into ONE publication")
    #expect(pane.lines.count == 200)

    // Per-tick, not cumulative: a tick with nothing new coalesced nothing,
    // however many the tick before it folded in.
    pane.refreshIfNeeded()
    #expect(pane.linesCoalescedByLastTick == 0)
    #expect(pane.lines.count == 200, "a second tick must not republish the same lines")

    for i in 1...5 { pane.receive(line(message: "later \(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.linesCoalescedByLastTick == 5)
}

@Test @MainActor func theAdaptiveIntervalsAndOccupancyThresholdAreTheMeasuredNumbers() {
    // Deliberately a change-detector, and the only honest kind of test for
    // these three: each is a number whose justification lives in a
    // MEASUREMENT rather than in the code, so changing one has to be a
    // deliberate act that revisits the measurement. Every other test in this
    // section refers to them symbolically — which is right, they test the
    // policy's shape — so none of them would notice one being edited.
    //
    // 150ms: the shipped interval, unchanged; what a pane holding few lines
    //   keeps.
    // 500ms: `occupancy-hypothesis.md` Result 4 — at 6 lines/sec into a full
    //   5,000-line buffer, the fast interval held 73.9% main-thread
    //   availability and the slow one 89.4%. (Also `hang-investigation.md`
    //   §5 at 1,199 lines/sec: 43% vs 81%.)
    // 2,500 lines: `occupancy-hypothesis.md` Result 2, the capacity sweep at
    //   a pinned 6 lines/sec and a pinned 5.93 publications/sec —
    //   100.0% at 500 lines, 99.9% at 1,000, 95.7% at 2,500, 74.7% at 5,000.
    //   2,500 is the last measured point at which the pane is still
    //   essentially free.
    #expect(LogPaneModel.refreshInterval == .milliseconds(150))
    #expect(LogPaneModel.floodedRefreshInterval == .milliseconds(500))
    #expect(LogPaneModel.floodedOccupancy == 2_500)
}

@Test @MainActor func aPaneHoldingFewLinesKeepsTheFastRefreshInterval() {
    // The quiet path: a nearly-empty buffer is cheap to publish, so there is
    // nothing to buy by publishing it less often and the user keeps today's
    // responsiveness.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    #expect(pane.activeRefreshInterval == LogPaneModel.refreshInterval, "a pane starts fast")

    for _ in 1...20 {
        #expect(intervalAfterTick(receiving: 1, on: pane) == LogPaneModel.refreshInterval)
    }
}

@Test @MainActor func aBufferAtTheOccupancyThresholdSelectsTheSlowerInterval() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    let selected = intervalAfterTick(receiving: LogPaneModel.floodedOccupancy, on: pane)
    #expect(selected == LogPaneModel.floodedRefreshInterval)
}

@Test @MainActor func aBufferOneLineShortOfTheOccupancyThresholdKeepsTheFastInterval() {
    // Pins which side of the threshold is inclusive. Without this, `>` and
    // `>=` are indistinguishable.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    let selected = intervalAfterTick(receiving: LogPaneModel.floodedOccupancy - 1, on: pane)
    #expect(selected == LogPaneModel.refreshInterval)
}

@Test @MainActor func theIntervalIsSelectedByOccupancyNotByArrivalRate() {
    // The entire point of this round, as two inverse cases. The rule that
    // shipped in aa38437 got BOTH of these backwards, and was measured
    // afterwards to buy +0.1 points at the developer's real 6 lines/sec.

    // A trickle into a full buffer — the developer's actual workload — is
    // slow, even though only six lines arrived in the tick.
    let full = LogPaneModel(streaming: StubLogStreaming())
    for i in 1...LogPaneModel.floodedOccupancy { full.receive(line(message: "history \(i)")) }
    full.refreshIfNeeded()
    #expect(intervalAfterTick(receiving: 6, on: full) == LogPaneModel.floodedRefreshInterval)
    #expect(full.linesCoalescedByLastTick == 6, "this case means nothing unless the tick was a trickle")

    // A burst into a nearly-empty buffer is fast, even though the tick
    // coalesced a couple of hundred lines at once.
    let empty = LogPaneModel(streaming: StubLogStreaming())
    #expect(intervalAfterTick(receiving: 200, on: empty) == LogPaneModel.refreshInterval)
    #expect(empty.linesCoalescedByLastTick == 200, "this case means nothing unless the tick was a burst")
}

@Test @MainActor func aFullBufferWhoseStreamStopsDeadStaysOnTheSlowInterval() {
    // Occupancy does not fall when a stream goes quiet, and neither does the
    // cost of publishing it: the copy, the detection, the severity scan and
    // the filter are all O(occupancy) whether or not anything arrived. The
    // lines-per-tick rule returned to 150ms here, which is exactly the
    // +0.1-point non-result this round replaced.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    #expect(intervalAfterTick(receiving: LogPaneModel.floodedOccupancy, on: pane)
            == LogPaneModel.floodedRefreshInterval)

    pane.refreshIfNeeded()
    #expect(pane.linesCoalescedByLastTick == 0, "this test means nothing unless the tick was empty")
    #expect(pane.activeRefreshInterval == LogPaneModel.floodedRefreshInterval)
}

@Test @MainActor func aCapacityBelowTheThresholdNeverSelectsTheSlowInterval() {
    // The threshold is absolute, not a fraction of capacity, because the cost
    // is a function of how many rows exist. A pane capped below it is already
    // cheap — Result 2 measured a 2,500-line buffer at 95.7% and a 1,000-line
    // one at 99.9% — so it must never pay the 500ms.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 1_000)
    for _ in 1...5 {
        #expect(intervalAfterTick(receiving: 1_000, on: pane) == LogPaneModel.refreshInterval)
    }
    #expect(pane.lines.count == 1_000, "the buffer must actually be full for this to mean anything")
}

@Test @MainActor func followingANewInstanceRestartsOnTheFastInterval() {
    // `follow(_:)` installs a fresh `LogBuffer`, and is therefore the only
    // thing in the app that lowers occupancy. Set explicitly rather than left
    // to the next tick so a freshly opened pane's first tick is the fast one.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    #expect(intervalAfterTick(receiving: LogPaneModel.floodedOccupancy, on: pane)
            == LogPaneModel.floodedRefreshInterval)

    pane.follow(instance(port: 10360))
    #expect(pane.activeRefreshInterval == LogPaneModel.refreshInterval)
    #expect(pane.linesCoalescedByLastTick == 0, "the new stream inherits no arrivals from the old")
}

@Test @MainActor func droppedLinesMessageIsNilUntilSomethingIsEvicted() {
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 3)
    for i in 1...3 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.droppedLinesMessage == nil)
}

@Test @MainActor func droppedLinesMessageStatesTheCountAndPluralises() {
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 3)
    for i in 1...4 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.droppedLinesMessage == "1 earlier line dropped")

    for i in 5...7 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.droppedLinesMessage == "4 earlier lines dropped")
}

@Test @MainActor func filteredLinesAppliesTheActiveFilter() {
    // Just proves the wiring — `LogFilter.apply(to:)`'s own behaviour is
    // exhaustively covered by `LogFilterTests`.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "ok", source: .runtime))
    pane.receive(line(message: "uh oh", source: .build))
    pane.refreshIfNeeded()

    pane.filter.source = .build
    #expect(pane.filteredLines.map(\.message) == ["uh oh"])
}

// MARK: - Auto-scroll "follow" state

@Test @MainActor func startsFollowingByDefault() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    #expect(pane.isFollowing)
}

@Test @MainActor func scrollingAwayFromTheBottomStopsFollowing() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.scrollPositionChanged(isAtBottom: false)
    #expect(!pane.isFollowing)
}

@Test @MainActor func scrollingBackToTheBottomResumesFollowingWithoutJumpToLatest() {
    // The rule isn't "only the button resumes it" — scrolling back down
    // yourself must work too, or the pane feels stuck in "not following"
    // forever once you've glanced away.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.scrollPositionChanged(isAtBottom: false)
    pane.scrollPositionChanged(isAtBottom: true)
    #expect(pane.isFollowing)
}

@Test @MainActor func jumpToLatestResumesFollowing() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.scrollPositionChanged(isAtBottom: false)
    #expect(!pane.isFollowing)
    pane.jumpToLatest()
    #expect(pane.isFollowing)
}

@Test @MainActor func startingANewStreamResetsFollowingToTrue() async throws {
    // A freshly opened stream should show its tail even if the previous
    // selection had been scrolled away from — "not following" is a
    // decision about *this* stream, not a sticky app-wide preference.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    pane.scrollPositionChanged(isAtBottom: false)
    #expect(!pane.isFollowing)

    pane.follow(b)
    #expect(pane.isFollowing)
}

// MARK: - JSON block expansion state

@Test @MainActor func expansionStateSurvivesARefresh() {
    // Lines stream in and the throttled snapshot is rebuilt on a tick
    // (`refreshIfNeeded()`, called directly here per the project's
    // count/inspect-not-time rule rather than racing the real 150ms timer).
    // An expanded block that collapses the moment more lines arrive is
    // unusable — this is the resource table's group-collapse bug
    // (`DashboardModel.collapsedGroups`) recurring for the log pane.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    let blockLines = [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#),
        line(message: "}"),
    ]
    for blockLine in blockLines { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    guard case .block = pane.rows.first?.row, pane.rows.count == 1 else {
        Issue.record("expected the streamed lines to form one block"); return
    }
    let id = pane.rows.first!.id
    pane.toggleExpansion(id)
    #expect(pane.isExpanded(id))

    // A tick with unrelated new content: `rows` is rebuilt from scratch (a
    // fresh `JSONBlock.detect` + `LogFilter.apply`, since the line snapshot
    // changed), but the block itself is untouched by it.
    pane.receive(line(message: "unrelated line after the block"))
    pane.refreshIfNeeded()

    #expect(pane.rows.count == 2)
    #expect(pane.rows.first!.id == id)
    #expect(pane.isExpanded(id))
}

@Test @MainActor func expansionStateSurvivesRingBufferEviction() {
    // `LogBuffer` evicts oldest-first once appends exceed capacity. Capacity
    // 5 here: "before" + the block's 4 lines exactly fill it, so the very
    // next append evicts "before" and shifts the block from row index 1 to
    // row index 0 — while its own 4 lines are untouched. An index-keyed
    // `expandedBlockIDs` would either lose the expansion (still keyed on 1,
    // but the block is now at 0) or, worse, misattribute it to whatever
    // unrelated row now sits at index 1.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 5)
    let blockLines = [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#),
        line(message: "}"),
    ]
    pane.receive(line(message: "before"))
    for blockLine in blockLines { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    #expect(pane.rows.count == 2)
    guard case .block = pane.rows[1].row else {
        Issue.record("expected the res block at row 1, before eviction"); return
    }
    let blockID = pane.rows[1].id
    pane.toggleExpansion(blockID)
    #expect(pane.isExpanded(blockID))

    // One more line: capacity 5 was already full (5 lines held), so this
    // append evicts "before" — the block's own lines are not evicted, only
    // repositioned in the rebuilt `rows` array.
    pane.receive(line(message: "after"))
    pane.refreshIfNeeded()
    #expect(pane.droppedCount == 1)

    #expect(pane.rows.count == 2)
    guard case .block = pane.rows[0].row else {
        Issue.record("expected the res block to have shifted to row 0 after eviction"); return
    }
    let shiftedBlockID = pane.rows[0].id

    // Same block, same identity, despite the position change.
    #expect(shiftedBlockID == blockID)
    #expect(pane.isExpanded(shiftedBlockID))

    // The unrelated new line, which now occupies the block's OLD index (1),
    // must not have inherited its expansion.
    guard case .line = pane.rows[1].row else {
        Issue.record("expected the new unrelated line at row 1"); return
    }
    #expect(!pane.isExpanded(pane.rows[1].id))
}

@Test @MainActor func twoDifferentBlocksHaveTwoDifferentIdentities() {
    // Every other test in this section works with ONE block, so all 20 of
    // them passed with `LogRow.ID.block` collapsed to `.block(lines: [])` —
    // every block in the buffer sharing a single identity. With one block on
    // screen that is indistinguishable from correct; with two it is the
    // feature failing outright: expanding A expands B as well, and the
    // detail pane renders whichever block comes first rather than the one
    // clicked. What identity has to be keyed on is the row's own content —
    // see `LogRow.ID`'s doc comment, including the known collision it does
    // accept (two blocks identical field-for-field within the same second).
    // These two are not that: they differ in their JSON.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in [
        line(message: "req: {"), line(message: #"  "url": "/api/auth/check""#), line(message: "}"),
        line(message: "res: {"), line(message: #"  "statusCode": 304"#), line(message: "}"),
    ] { pane.receive(l) }
    pane.refreshIfNeeded()

    #expect(pane.rows.count == 2)
    guard case .block(let requestBlock, _) = pane.rows[0].row,
          case .block(let responseBlock, _) = pane.rows[1].row else {
        Issue.record("expected the streamed lines to form two distinct blocks"); return
    }
    let request = pane.rows[0].id
    let response = pane.rows[1].id
    #expect(request != response)

    // Expanding one must not expand the other.
    pane.toggleExpansion(request)
    #expect(pane.isExpanded(request))
    #expect(!pane.isExpanded(response))

    // And the detail pane must open the block that was actually clicked,
    // not merely a block. Reduced to `Bool` before `#expect` sees it: a
    // failing comparison of two `JSONBlock`s makes swift-testing reflect
    // over their `JSONValue` trees to render the message.
    pane.openInDetailPane(response)
    let opened = pane.focusedBlock == responseBlock
    let openedTheWrongOne = pane.focusedBlock == requestBlock
    #expect(opened)
    #expect(!openedTheWrongOne)
}

@Test @MainActor func repetitiveIdenticalLinesStillGetDistinctRowIdentities() {
    // THE live bug: an instance whose logs are highly repetitive rendered
    // NOTHING at all — no rows — while `tilt logs --json --tail 2000 --follow`
    // was demonstrably producing output. `LogPaneView` renders
    // `ForEach(pane.rows)`, and SwiftUI's `ForEach` requires unique ids;
    // measured over a 2,000-line capture from that instance, 1,214 rows
    // carried only 216 distinct ids (998 surplus rows, the worst id repeated
    // 86 times) and the pane drew nothing.
    //
    // The shape reproduced here is exactly what made it constant: byte-
    // identical messages, the SAME second-resolution timestamp (`LogLine.time`
    // has no sub-second component), the same resource and the same span — so
    // nothing about a row's CONTENT can tell two of these emissions apart. A
    // row's identity therefore cannot be derived from its content; it comes
    // from the sequence number `LogBuffer` stamps at append time.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    let sameSecond = Date(timeIntervalSince1970: 1_786_493_715)
    func repeated(_ message: String) -> LogLine {
        line(message: message, time: sameSecond, resource: "json-lab", spanID: "localserve:1")
    }

    // 200 identical block/line pairs: 400 rows, every one indistinguishable
    // from its 199 twins by any field it carries.
    for _ in 0..<200 {
        pane.receive(repeated("res: {"))
        pane.receive(repeated(#"  "statusCode": 200"#))
        pane.receive(repeated("}"))
        pane.receive(repeated("tick"))
    }
    pane.refreshIfNeeded()

    let rows = pane.rows
    #expect(rows.count == 400)
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test @MainActor func togglingExpansionTwiceCollapsesAgain() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    let blockLines = [
        line(message: "{"),
        line(message: #"  "ok": true"#),
        line(message: "}"),
    ]
    for blockLine in blockLines { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    let id = pane.rows.first!.id
    #expect(!pane.isExpanded(id))
    pane.toggleExpansion(id)
    #expect(pane.isExpanded(id))
    pane.toggleExpansion(id)
    #expect(!pane.isExpanded(id))
}

@Test @MainActor func switchingInstancesClearsExpansionState() {
    // Same rationale as the buffer itself getting cleared on `follow(_:)`:
    // an expansion referring to a block from the previous stream has no
    // meaning once that stream's content is gone.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    let blockLines = [
        line(message: "{"),
        line(message: #"  "ok": true"#),
        line(message: "}"),
    ]
    for blockLine in blockLines { pane.receive(blockLine) }
    pane.refreshIfNeeded()
    pane.toggleExpansion(pane.rows.first!.id)
    #expect(!pane.expandedBlockIDs.isEmpty)

    pane.follow(b)
    #expect(pane.expandedBlockIDs.isEmpty)
}

// MARK: - `rows` caching

@Test @MainActor func rowsIsBuiltOncePerChangeNotOncePerRead() {
    // SwiftUI reads `rows` several times per render (the list, the scroll
    // target, the empty-state check). Each read used to re-run
    // `JSONBlock.detect` — ANSI strip, trim, brace scan and JSON parse over
    // the whole buffer — plus `LogFilter.apply`, on the main actor, for an
    // answer that had not changed.
    //
    // Counted, not timed, per the project's standing rule: `rowsRecomputeCount`
    // is the seam, the same shape as `LogFilter.CompilationCounter`.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for blockLine in [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200"#),
        line(message: "}"),
        line(message: "a plain line"),
    ] { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    _ = pane.rows
    _ = pane.rows
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 1)

    // A new snapshot is a genuine change: exactly one more build.
    pane.receive(line(message: "another plain line"))
    pane.refreshIfNeeded()
    _ = pane.rows
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 2)

    // So is a filter edit, even with the same lines.
    pane.filter.query = "statusCode"
    _ = pane.rows
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 3)

    // A no-op tick (nothing appended) must not invalidate anything.
    pane.refreshIfNeeded()
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 3)
}

@Test @MainActor func rowsNeverAnswersFromAStaleCache() {
    // The mutation guard for the test above: a cache keyed on the wrong
    // thing (or never invalidated) makes `rows` cheap AND wrong, which is
    // strictly worse than recomputing. Every input `rows` derives from is
    // changed here in turn, and the ANSWER — not the recompute count — is
    // checked each time.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "first"))
    pane.refreshIfNeeded()
    // The first line the buffer ever saw, so sequence 0 — and that number is
    // the row's whole identity now (`LogRow.ID`).
    #expect(pane.rows.map(\.id) == [LogRow.ID(sequence: 0)])
    #expect(pane.rows.flatMap { $0.lines.map(\.line.message) } == ["first"])

    // New lines show up.
    pane.receive(line(message: "second"))
    pane.refreshIfNeeded()
    #expect(pane.rows.count == 2)

    // A filter change re-filters the same lines.
    pane.filter.query = "second"
    #expect(pane.rows.count == 1)
    pane.filter.query = ""
    #expect(pane.rows.count == 2)

    // Following a new instance empties it.
    pane.follow(instance(port: 10350))
    #expect(pane.rows.isEmpty)
}

// MARK: - Expansion side effects: follow-pause and the shared "open block"
//
// `toggleExpansion` (the INLINE chevron) and `openInDetailPane` (the detail
// pane's own click) are two entry points into the same underlying state —
// see `LogPaneModel.focusedBlockID`'s doc comment for why that sharing is
// what makes switching `SettingsStore.jsonPresentation` mid-session
// lossless. These tests exercise that sharing directly, without any
// `JSONPresentation` involved at all — proving the model needs none.

private func openBlockLines() -> [LogLine] {
    [line(message: "{"), line(message: #"  "ok": true"#), line(message: "}")]
}

@Test @MainActor func expandingABlockInlinePausesFollowing() {
    // Task 5's most important interaction: expanding a block while the pane
    // is tailing must not push it off screen. "Jump to Latest" is the only
    // way back — this only checks the pause half.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    #expect(pane.isFollowing)

    pane.toggleExpansion(pane.rows.first!.id)
    #expect(!pane.isFollowing)
}

@Test @MainActor func collapsingABlockDoesNotResumeFollowing() {
    // Only "Jump to Latest" (or scrolling back down) resumes following —
    // collapsing the block just read must not silently resume tailing out
    // from under the user.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    let id = pane.rows.first!.id

    pane.toggleExpansion(id)
    #expect(!pane.isFollowing)
    pane.toggleExpansion(id)
    #expect(!pane.isFollowing)
}

@Test @MainActor func openingInDetailPaneDoesNotPauseFollowing() {
    // Task 6's whole point: the tree renders BESIDE the log, not in place,
    // so nothing about the flowing content resizes and there is no reason
    // to stop tailing.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    #expect(pane.isFollowing)

    pane.openInDetailPane(pane.rows.first!.id)
    #expect(pane.isFollowing)
}

@Test @MainActor func toggleExpansionAlsoFocusesTheBlockForTheDetailPane() {
    // The INLINE path must leave a trail the detail pane can pick up: a
    // block expanded via the chevron is the one that presentation would
    // show if `jsonPresentation` were flipped to `.detailPane` afterward.
    // Without this, that switch would show a blank detail pane.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    let id = pane.rows.first!.id
    #expect(pane.focusedBlockID == nil)

    pane.toggleExpansion(id)
    #expect(pane.focusedBlockID == id)
}

@Test @MainActor func openInDetailPaneAlsoMarksTheBlockExpanded() {
    // The mirror image: a block opened via the DETAIL PANE reads as already
    // expanded if `jsonPresentation` is flipped back to `.inline`.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    let id = pane.rows.first!.id

    pane.openInDetailPane(id)
    #expect(pane.isExpanded(id))
    #expect(pane.focusedBlockID == id)
}

@Test @MainActor func closingTheDetailPaneCollapsesItsBlock() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    let id = pane.rows.first!.id
    pane.openInDetailPane(id)

    pane.closeDetailPane()
    #expect(pane.focusedBlockID == nil)
    #expect(!pane.isExpanded(id))
}

@Test @MainActor func closingTheDetailPaneWithNothingOpenIsANoOp() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.closeDetailPane()
    #expect(pane.focusedBlockID == nil)
}

@Test @MainActor func openingADifferentBlockInDetailPaneReplacesTheFocusedOne() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in [
        line(message: "{"), line(message: #"  "a": 1"#), line(message: "}"),
        line(message: "{"), line(message: #"  "b": 2"#), line(message: "}"),
    ] { pane.receive(l) }
    pane.refreshIfNeeded()
    #expect(pane.rows.count == 2)
    let first = pane.rows[0].id
    let second = pane.rows[1].id

    pane.openInDetailPane(first)
    #expect(pane.focusedBlockID == first)
    pane.openInDetailPane(second)
    #expect(pane.focusedBlockID == second)
    // The first block stays a member of `expandedBlockIDs` even though it's
    // no longer the focused one — only `closeDetailPane` or toggling it
    // directly collapses it, same as clicking a second row in a real
    // inspector-style panel does not retroactively close the first.
    #expect(pane.isExpanded(first))
}

@Test @MainActor func followingANewInstanceClearsTheFocusedBlock() {
    // Same rationale as `switchingInstancesClearsExpansionState` above: a
    // focused block from the previous stream has no meaning once that
    // stream's content is gone.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)
    pane.follow(a)
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    pane.openInDetailPane(pane.rows.first!.id)
    #expect(pane.focusedBlockID != nil)

    pane.follow(b)
    #expect(pane.focusedBlockID == nil)
}

@Test @MainActor func focusedBlockLooksUpTheActualBlockFromRows() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    #expect(pane.focusedBlock == nil)

    let id = pane.rows.first!.id
    pane.openInDetailPane(id)
    guard case .block(let expectedBlock, _) = pane.rows.first!.row else {
        Issue.record("expected the streamed lines to form one block"); return
    }
    #expect(pane.focusedBlock == expectedBlock)
}

// The resource health map used to live here, snapshotted onto `LogPaneModel`
// and refreshed by `DashboardModel.followSelectedInstanceLogs()`. That
// snapshot went stale between reconciles — the exact case this feature
// exists to catch — so it moved to `DashboardModel.resourceHealthByName`, a
// live computed property over `visibleResources` with no cache to refresh.
// See `DashboardModelTests.swift`'s "Log pane resource health" section.

// MARK: - Empty state
//
// THE bug this section exists for: a resource scoped to `(Tiltfile)` — which
// genuinely emits zero lines — rendered a blank pane with a "Scoped to
// (Tiltfile)" chip and nothing else, and a user reasonably reported the app
// as broken. `emptyState` is the fix: a typed DECISION about which of four
// reasons applies, asserted here by exact case (and, for `.filteredOut`, by
// exact `FilterCause` membership) — never by "some message appeared", which
// would pass just as happily if two causes swapped names.

@Test @MainActor func emptyStateIsNotFollowingBeforeFollowHasEverBeenCalled() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    #expect(pane.emptyState == .notFollowing)
}

@Test @MainActor func emptyStateIsNotFollowingAfterFollowingNil() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "one"), to: target.id)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value

    pane.follow(nil)
    #expect(pane.emptyState == .notFollowing)
}

@Test @MainActor func emptyStateIsWaitingForLinesWhileTheStreamIsOpenAndNothingHasArrived() {
    // The normal, few-hundred-ms window right after `follow(_:)` — this must
    // never be reported as any of the other three cases.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    #expect(pane.emptyState == .waitingForLines)
}

@Test @MainActor func emptyStateIsStreamEndedWithNoLinesAfterACleanFinishThatProducedNothing() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value

    #expect(pane.emptyState == .streamEndedWithNoLines)
}

@Test @MainActor func emptyStateIsStreamEndedWithNoLinesAfterAFailureThatProducedNothing() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.fail(target.id, error: StubError())
    await pane.streamTaskForTesting?.value

    // `streamError`'s own banner already states the failure — this case must
    // still be reported (the empty pane needs SOME explanation), just not a
    // duplicate of that banner's text, which is the view's job to avoid, not
    // this enum's.
    #expect(pane.streamError != nil)
    #expect(pane.emptyState == .streamEndedWithNoLines)
}

@Test @MainActor func emptyStateIsNilWhenAtLeastOneLineMatchesTheActiveFilter() {
    // "Has content" is not a case of `EmptyState` at all — `nil` is the only
    // representation, exactly mirroring `DashboardModel.emptyState`'s own
    // "non-nil exactly when the view draws nothing" contract.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "hello", resource: "server"))
    pane.refreshIfNeeded()

    #expect(pane.emptyState == nil)
}

@Test @MainActor func emptyStateNamesOnlyTheResourceScopeWhenItAloneExcludesEverything() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "hello", resource: "server"))
    pane.refreshIfNeeded()

    pane.filter.resource = "some-other-resource"
    #expect(pane.emptyState == .filteredOut([.resourceScope]))
}

@Test @MainActor func emptyStateNamesOnlyTheTextQueryWhenItAloneExcludesEverything() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "hello", resource: "server"))
    pane.refreshIfNeeded()

    pane.filter.query = "no-such-substring"
    #expect(pane.emptyState == .filteredOut([.textQuery]))
}

@Test @MainActor func emptyStateNamesBothScopeAndQueryWhenBothExcludeEverything() {
    // The other half of the trap: with two controls active, the state must
    // not point at only one of them — a message built from a case that
    // dropped the second bit would send the user to clear the wrong thing
    // (or only half the right thing).
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "hello", resource: "server"))
    pane.refreshIfNeeded()

    pane.filter.resource = "some-other-resource"
    pane.filter.query = "no-such-substring"

    guard case .filteredOut(let cause) = pane.emptyState else {
        Issue.record("expected .filteredOut, got \(String(describing: pane.emptyState))"); return
    }
    #expect(cause.contains(.resourceScope))
    #expect(cause.contains(.textQuery))
    #expect(!cause.contains(.source))
}

@Test @MainActor func emptyStateNamesTheSourceFilterWhenItAloneExcludesEverything() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "runtime line", source: .runtime))
    pane.refreshIfNeeded()

    pane.filter.source = .build
    #expect(pane.emptyState == .filteredOut([.source]))
}

@Test @MainActor func emptyStateIsWaitingNotFilteredOutWhenTheBufferItselfIsEmptyEvenWithAFilterSet() {
    // THE trap, stated directly: a filter field being "active" is not enough
    // to blame it — with the raw buffer itself empty, every active filter
    // field trivially excludes everything (there is nothing to include), so
    // `.filteredOut` must never fire here. This is `emptyState`'s doc-comment
    // precedence (case 2 gates on `lines`, before `filter` is ever read) made
    // into an assertion.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.filter.resource = "some-resource-that-will-never-arrive"
    pane.filter.query = "anything"

    #expect(pane.emptyState == .waitingForLines)
}

@Test @MainActor func emptyStateStaysFilteredOutRatherThanStreamEndedWhenLinesExistButAreExcluded() async throws {
    // The converse of the trap: once at least one line has genuinely
    // arrived, the stream having since ended must not overwrite the more
    // specific `.filteredOut` diagnosis with the generic "nothing arrived"
    // one — the user's actual problem is the filter, not a dead stream.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "hello", resource: "server"), to: target.id)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value

    pane.filter.resource = "some-other-resource"
    #expect(pane.emptyState == .filteredOut([.resourceScope]))
}

// MARK: - Severity: "Errors only", the count, and jump-to-next
//
// The scoring rules themselves are `SeverityScannerTests`' subject, validated
// against a committed 3,461-line corpus. Nothing here re-tests them: these
// state what the PANE does with the score. Fixtures are therefore the
// smallest shapes that reach a known rule — a leading `ERROR:`/`WARN:` token
// for `token.severity`, a serialised `err: { … }` for `json.err` — chosen so
// a failure reads as "the pane mishandled a scored row", never as "the
// scanner changed its mind".

/// Deliberately NOT prefixed with a bracketed timestamp: `LogRecord.isHeader`
/// treats `[01:13:52] …` at column zero as a record header, and a record
/// would then pull neighbouring rows through a text query. These tests are
/// about the severity gate, so each fixture line stands alone.
private func severityFixture() -> [LogLine] {
    [
        line(message: "GET /healthz 200"),
        line(message: "WARN: disk at 80%"),
        line(message: "ERROR: boom on /api/invoke"),
        line(message: "FATAL: shutting down"),
    ]
}

@Test @MainActor func errorsOnlyKeepsOnlyRowsAtErrorOrAbove() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in severityFixture() { pane.receive(fixture) }
    pane.refreshIfNeeded()

    #expect(pane.rows.count == 4)

    pane.filter.errorsOnly = true

    // The warning is the assertion that matters. "At error or above" is a
    // threshold, and a gate written `>= .warning` would keep three rows here
    // and still look like it worked — the tint already distinguishes
    // warnings in place, so promoting them into this control would flood it
    // with Flask's red development-server banner and the rest of the noise
    // `ansi.red` is capped at `.warning` precisely to keep out.
    #expect(pane.rows.flatMap { $0.lines.map(\.line.message) }
        == ["ERROR: boom on /api/invoke", "FATAL: shutting down"])
}

@Test @MainActor func errorsOnlyComposesWithATextQuery() {
    // Both active must mean both applied. The trap is one control silently
    // winning — which a single-assertion test cannot see, because "the right
    // answer" for `query AND errorsOnly` is a SUBSET of each control's own
    // answer. So all three are asserted: each alone keeps two rows, and only
    // together do they keep one.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in [
        line(message: "ERROR: boom on /api/invoke"),
        line(message: "ERROR: boom on /api/health"),
        line(message: "GET /api/invoke 200"),
    ] { pane.receive(fixture) }
    pane.refreshIfNeeded()

    pane.filter.query = "invoke"
    #expect(pane.rows.flatMap { $0.lines.map(\.line.message) }
        == ["ERROR: boom on /api/invoke", "GET /api/invoke 200"])

    pane.filter.query = ""
    pane.filter.errorsOnly = true
    #expect(pane.rows.flatMap { $0.lines.map(\.line.message) }
        == ["ERROR: boom on /api/invoke", "ERROR: boom on /api/health"])

    pane.filter.query = "invoke"
    #expect(pane.rows.flatMap { $0.lines.map(\.line.message) }
        == ["ERROR: boom on /api/invoke"])
}

@Test @MainActor func theErrorCountReflectsTheUnfilteredBuffer() {
    // "3 errors" must count what is THERE, not what survives the current
    // filter — a count that drops to zero because you searched for something
    // else is worse than no count: it states, falsely, that the stream is
    // clean.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in severityFixture() { pane.receive(fixture) }
    pane.refreshIfNeeded()

    #expect(pane.errorCount == 2)

    // A query that excludes every line empties the pane and must leave the
    // count alone.
    pane.filter.query = "no-such-substring"
    #expect(pane.rows.isEmpty)
    #expect(pane.errorCount == 2)

    // So must the severity gate itself, and the resource scope.
    pane.filter = LogFilter(errorsOnly: true)
    #expect(pane.errorCount == 2)
    pane.filter = LogFilter(resource: "some-other-resource")
    #expect(pane.rows.isEmpty)
    #expect(pane.errorCount == 2)
}

@Test @MainActor func theErrorCountCountsRowsNotLines() {
    // A serialised pino error spans four lines and is ONE failure. Counting
    // its lines would report a single crash as four, and the number in the
    // filter bar is read as "how many things went wrong".
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in [
        line(message: "err: {"),
        line(message: #"  "type": "Error","#),
        line(message: #"  "message": "failed with status code 500""#),
        line(message: "}"),
    ] { pane.receive(fixture) }
    pane.refreshIfNeeded()

    guard pane.rows.count == 1, case .block = pane.rows[0].row else {
        Issue.record("fixture: expected the four lines to detect as one block"); return
    }
    #expect(pane.rows[0].severity == .error)
    #expect(pane.errorCount == 1)
}

@Test @MainActor func jumpToNextErrorWrapsAndReportsWhenThereAreNone() {
    // Silently doing nothing is this project's recurring failure mode.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "GET /healthz 200"))
    pane.refreshIfNeeded()

    #expect(pane.jumpToNextError() == .noErrorsInBuffer)
    #expect(pane.focusedErrorID == nil)
    #expect(pane.errorJumpGeneration == 0)

    pane.receive(line(message: "ERROR: first failure"))
    pane.receive(line(message: "GET /healthz 200"))
    pane.receive(line(message: "FATAL: second failure"))
    pane.refreshIfNeeded()

    let failing = pane.rows.filter(\.isFailure).map(\.id)
    #expect(failing.count == 2)

    #expect(pane.jumpToNextError() == .moved(to: failing[0]))
    #expect(pane.focusedErrorID == failing[0])
    #expect(pane.errorJumpGeneration == 1)

    #expect(pane.jumpToNextError() == .moved(to: failing[1]))
    #expect(pane.focusedErrorID == failing[1])

    // Past the last one: back to the first, and SAID so. A jump that
    // reported `.moved` here would be indistinguishable from one that
    // stopped dead at the end of the buffer.
    #expect(pane.jumpToNextError() == .wrapped(to: failing[0]))
    #expect(pane.focusedErrorID == failing[0])
    #expect(pane.errorJumpGeneration == 3)
}

@Test @MainActor func theFirstJumpOfASessionHasNotWrapped() {
    // The off-by-one in the wrap rule: with no previous target there is no
    // "past the last one" to have run off, so landing on the first failing
    // row is a plain move. Reporting `.wrapped` would put "wrapped around to
    // the first error" in front of a user who had not been anywhere yet.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "ERROR: only failure"))
    pane.refreshIfNeeded()

    guard case .moved = pane.jumpToNextError() else {
        Issue.record("expected the first jump to report .moved"); return
    }
    // And with exactly one failing row, the SECOND jump does wrap — onto the
    // same id, which is why the view watches `errorJumpGeneration` rather
    // than `focusedErrorID` for "a jump happened".
    guard case .wrapped = pane.jumpToNextError() else {
        Issue.record("expected the second jump to report .wrapped"); return
    }
    #expect(pane.errorJumpGeneration == 2)
}

@Test @MainActor func jumpToNextErrorSaysSoWhenTheFilterHidesEveryError() {
    // The distinction the whole `ErrorJump` type exists for. The count beside
    // the button still reads "2 errors" (it is unfiltered, deliberately), so
    // reporting this as "no errors" would directly contradict the number next
    // to it and read as the button being broken.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "ERROR: first failure"))
    pane.receive(line(message: "ERROR: second failure"))
    pane.refreshIfNeeded()

    pane.filter.query = "no-such-substring"

    #expect(pane.jumpToNextError() == .everyErrorFilteredOut(errorCount: 2))
    #expect(pane.focusedErrorID == nil)
    #expect(pane.errorJumpGeneration == 0)
}

@Test @MainActor func jumpingToAnErrorStopsFollowing() {
    // Otherwise the next 150ms refresh tick auto-scrolls straight back to the
    // tail and the user is yanked away from the failure they just asked to
    // see — the same bug `toggleExpansion(_:)` pauses following to avoid.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "ERROR: boom"))
    pane.refreshIfNeeded()
    #expect(pane.isFollowing)

    pane.jumpToNextError()
    #expect(!pane.isFollowing)
}

@Test @MainActor func jumpingWithNowhereToGoLeavesFollowingAlone() {
    // The mutation guard for the test above: pausing follow unconditionally
    // would make a button that reports "there are no errors" ALSO silently
    // stop the pane tailing, which is a side effect the user never asked for
    // and cannot see the cause of.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "GET /healthz 200"))
    pane.refreshIfNeeded()

    pane.jumpToNextError()
    #expect(pane.isFollowing)
}

@Test @MainActor func followingANewInstanceForgetsTheJumpTarget() {
    // Sequence numbers restart with the new buffer, so a retained target
    // would have the next jump compare this stream's ids against another
    // stream's.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "ERROR: boom"))
    pane.refreshIfNeeded()
    pane.jumpToNextError()
    #expect(pane.focusedErrorID != nil)

    pane.follow(instance(port: 10350))
    #expect(pane.focusedErrorID == nil)
}

@Test @MainActor func emptyStateNamesErrorsOnlyWhenItAloneExcludesEverything() {
    // A pane full of healthy lines, emptied by the severity gate, must say
    // which control did it — "no lines match the current filter" with nothing
    // named reads as the app having lost the stream.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "GET /healthz 200"))
    pane.refreshIfNeeded()

    pane.filter.errorsOnly = true
    #expect(pane.emptyState == .filteredOut([.errorsOnly]))
}

// MARK: - Severity stays inside the cached derivation
//
// The plan's Step 4, and the reason `detectionRecomputeCount` exists
// alongside `rowsRecomputeCount`: a single counter cannot tell "the pane
// re-filtered" apart from "the pane re-scanned 5,000 rows for severity".
// Counted, never timed — the eighth wall-clock test in this project was
// replaced one commit before this one.

@Test @MainActor func changingTheFilterDoesNotRescanSeverity() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in severityFixture() { pane.receive(fixture) }
    pane.refreshIfNeeded()

    _ = pane.rows
    _ = pane.rows
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 1)
    #expect(pane.detectionRecomputeCount == 1)

    // A filter edit re-filters. It must not re-detect, and it must not
    // re-score: neither depends on the filter, and both run over the whole
    // buffer.
    pane.filter.query = "boom"
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 2)
    #expect(pane.detectionRecomputeCount == 1)

    pane.filter.errorsOnly = true
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 3)
    #expect(pane.detectionRecomputeCount == 1)

    // Reading the count is a field read off the same cache, not a second
    // pass over the buffer — the filter bar reads it on every render.
    _ = pane.errorCount
    _ = pane.errorCount
    #expect(pane.detectionRecomputeCount == 1)

    // A new snapshot is the one thing that genuinely invalidates the scan.
    pane.receive(line(message: "ERROR: something new"))
    pane.refreshIfNeeded()
    _ = pane.rows
    _ = pane.rows
    #expect(pane.detectionRecomputeCount == 2)
}

@Test @MainActor func togglingErrorsOnlyInvalidatesTheRowsCache() {
    // The mutation guard for the test above. `rows` is cached on `LogFilter`
    // equality, so a field added to that struct participates automatically —
    // unless it is held somewhere else, in which case the cache goes stale
    // and the control appears to do nothing on its second use. Asserted on
    // the ANSWER, not the recompute count, and toggled back so a cache that
    // only ever invalidates once cannot pass.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in severityFixture() { pane.receive(fixture) }
    pane.refreshIfNeeded()

    #expect(pane.rows.count == 4)
    pane.filter.errorsOnly = true
    #expect(pane.rows.count == 2)
    pane.filter.errorsOnly = false
    #expect(pane.rows.count == 4)
}

@Test @MainActor func everyRowCarriesTheSeverityTheScannerScoredIt() {
    // The wiring assertion for the tint: the pane must hand the view the
    // scanner's own answer for each row, not a re-derivation of it. Compared
    // against `SeverityScanner` directly so a change of rules moves both
    // sides together and this test keeps stating only the wiring.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in severityFixture() { pane.receive(fixture) }
    pane.refreshIfNeeded()

    #expect(pane.rows.map(\.severity) == pane.rows.map { SeverityScanner.severity(of: $0.row) })
    #expect(pane.rows.map(\.severity) == [.normal, .warning, .error, .fatal])
}

// MARK: - Copy takes what the pane shows
//
// `filteredLines` is what the filter bar's Copy action puts on the clipboard,
// and it used to filter the buffer independently of `rows`. Two passes, two
// answers: `errorsOnly` is a ROW property (`LogFilter.apply(to lines:)` cannot
// express it and does not), so with the gate on, the pane drew one row and
// Copy handed over every line — and Copy stayed enabled on a pane the gate had
// emptied. `filteredLines` is now `rows` flattened, which is why these are
// statements about a derivation rather than about two pipelines agreeing.

@Test @MainActor func copyingTakesExactlyWhatThePaneShows() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in severityFixture() { pane.receive(fixture) }
    pane.refreshIfNeeded()

    #expect(pane.filteredLines.map(\.message) == severityFixture().map(\.message))

    // THE regression. The gate is inexpressible line-by-line, so a
    // second, line-based filtering pass silently ignored it here.
    pane.filter.errorsOnly = true
    #expect(pane.rows.flatMap { $0.lines.map(\.line.message) }
        == ["ERROR: boom on /api/invoke", "FATAL: shutting down"])
    #expect(pane.filteredLines.map(\.message)
        == ["ERROR: boom on /api/invoke", "FATAL: shutting down"])
}

@Test @MainActor func copyingTakesAMatchedBlockWholeJustAsThePaneDrawsIt() {
    // The same divergence one layer down, and the reason this is a derivation
    // rather than a patch for one field: the row pipeline keeps a matched
    // block WHOLE, so the pane draws four lines. A line-based pass keeps only
    // the line containing the query, so Copy used to hand over one — losing
    // the `res: {` header that explains it, which is the founding bug of this
    // whole feature, reproduced on the clipboard.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#),
        line(message: "}"),
    ] { pane.receive(fixture) }
    pane.refreshIfNeeded()

    pane.filter.query = "statusCode"
    #expect(pane.rows.count == 1)
    #expect(pane.filteredLines.map(\.message)
        == ["res: {", #"  "statusCode": 200,"#, #"  "headers": {}"#, "}"])
}

@Test @MainActor func copyIsEmptyExactlyWhenThePaneIs() {
    // `LogFilterBarView` disables Copy on `rows.isEmpty` while copying
    // `filteredLines`, so the two must answer the same question. They do by
    // construction — `filteredLines` is `rows` flattened and every row covers
    // at least one line — and this pins it across each control in turn, the
    // severity gate included, because "Copy is enabled on a pane showing
    // nothing" is precisely what shipped.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for fixture in severityFixture() { pane.receive(fixture) }
    pane.refreshIfNeeded()

    for filter in [
        LogFilter(),
        LogFilter(query: "boom"),
        LogFilter(query: "no-such-substring"),
        LogFilter(source: .build),
        LogFilter(resource: "some-other-resource"),
        LogFilter(errorsOnly: true),
        LogFilter(query: "healthz", errorsOnly: true),
    ] {
        pane.filter = filter
        #expect(pane.rows.isEmpty == pane.filteredLines.isEmpty, "disagreed for \(filter)")
    }

    // And at least one of those shapes really does empty the pane, so the
    // loop above is not seven trivially-true comparisons.
    pane.filter = LogFilter(query: "healthz", errorsOnly: true)
    #expect(pane.rows.isEmpty)
}

// MARK: - The `@Observable` dependency the caches must not skip
//
// `rowsRecomputeCount` proves the caches CACHE. It says nothing about whether
// a cache HIT still registers the dependency SwiftUI redraws on, and those are
// two different claims: the regression this pins is a pane that stopped
// redrawing when new lines arrived, because a cache hit returned without ever
// touching `lines` and `@Observable` records a dependency only on properties
// a closure actually reads.
//
// Both cache layers can reintroduce it independently — `rows` by moving its
// `detectedRows` call below its own cache check, `detectedRows` by moving its
// `lines` read below its. `withObservationTracking` is the only thing that can
// see either: it observes the REGISTRATION, not the value, exactly as
// `RecordGroupingCounter` observes an operation whose output is
// indistinguishable from its input.

/// Whether mutating something in `mutate` is reported to an observer that
/// tracked `read`.
///
/// `onChange` is `@Sendable`, so the flag is an `InvocationCounter` rather
/// than a captured `var` — the same seam the counting tests use, for the same
/// reason it exists.
@MainActor
private func mutationIsObserved(whileReading read: () -> Void, then mutate: () -> Void) -> Bool {
    let observed = InvocationCounter()
    withObservationTracking(read) { observed.increment() }
    mutate()
    return observed.count > 0
}

@Test @MainActor func readingRowsRegistersTheDependencyOnLinesEvenOnACacheHit() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "first"))
    pane.refreshIfNeeded()

    // Warm BOTH caches. A cache hit is the only path that can skip the read,
    // so a test that tracked a cold read would pass against the bug.
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 1)
    #expect(pane.detectionRecomputeCount == 1)

    // Appended before tracking starts: `receive` marks the ring buffer dirty
    // and touches nothing `rows` reads, so the ONLY mutation inside the
    // tracked window is `refreshIfNeeded()` assigning `lines`.
    pane.receive(line(message: "second"))

    let observed = mutationIsObserved(
        whileReading: { _ = pane.rows },
        then: { pane.refreshIfNeeded() }
    )

    #expect(observed)
    // Repeated AFTER the window, and that is the point: the check before it
    // only says the caches were warm going in, while this one says the tracked
    // read itself did not recompute — neither counter moved across it, so
    // `observed` is a claim about a cache HIT registering the dependency
    // rather than about a recompute incidentally doing it. True today because
    // `receive` does not bump `linesGeneration`; asserted here so it stays
    // structural if that ever changes. (`refreshIfNeeded()` invalidates both
    // caches but recomputes nothing on its own, so the counters are still 1.)
    #expect(pane.rowsRecomputeCount == 1)
    #expect(pane.detectionRecomputeCount == 1)
    // And the answer really did change, so the registration above is about a
    // redraw that was genuinely needed. This read is the one that recomputes.
    #expect(pane.rows.count == 2)
}

@Test @MainActor func readingTheErrorCountRegistersTheDependencyOnLinesEvenOnACacheHit() {
    // The count sits in the filter bar and is read on every render. It answers
    // from the same detection cache, so it can go stale the same way — and a
    // count frozen at "0 errors" while errors stream in is worse than no count,
    // for the same reason an unfiltered count is better than a filtered one.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "GET /healthz 200"))
    pane.refreshIfNeeded()
    _ = pane.errorCount
    #expect(pane.detectionRecomputeCount == 1)

    pane.receive(line(message: "ERROR: boom"))

    let observed = mutationIsObserved(
        whileReading: { _ = pane.errorCount },
        then: { pane.refreshIfNeeded() }
    )

    #expect(observed)
    // After the window, for the reason spelled out in the test above: this is
    // what makes `observed` a statement about a cache hit rather than about a
    // read that happened to recompute.
    #expect(pane.detectionRecomputeCount == 1)
    #expect(pane.errorCount == 1)
}

// MARK: - Live capacity changes (`SettingsStore.logScrollback`)

@Test @MainActor func everyOfferedScrollbackChoiceSelectsTheIntervalItsCopyPromises() {
    // `floodedOccupancy` is ABSOLUTE, not a fraction of capacity, and this is
    // the claim that makes that the right shape once capacity is a user
    // preference: a small buffer must never buy a 500ms publish interval it
    // does not need, and a large one must still get it. The settings copy
    // says exactly this — "the pane stays fully responsive" on the two small
    // choices, "updates twice a second instead of six times once it fills" on
    // the two large ones — so this test is what stops that copy becoming a
    // lie.
    //
    // Every pane below is filled TO CAPACITY, which is the worst case each
    // choice can reach; there is no state in which a 1,000-line pane holds
    // 2,500 lines.
    for choice in LogScrollback.allCases {
        let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: choice.lineCount)
        let interval = intervalAfterTick(receiving: choice.lineCount * 2, on: pane)

        #expect(pane.lines.count == choice.lineCount,
                "\(choice.title): the buffer must actually be full for this to mean anything")
        switch choice {
        case .lines500, .lines1000:
            #expect(interval == LogPaneModel.refreshInterval,
                    "\(choice.title) is below floodedOccupancy and must never pay the 500ms")
        case .lines2500, .lines5000:
            #expect(interval == LogPaneModel.floodedRefreshInterval,
                    "\(choice.title) reaches floodedOccupancy and must be published less often")
        }
    }
}

@Test @MainActor func setCapacityShrinksTheLiveBufferKeepingTheNewestLines() {
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    for i in 1...10 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()

    pane.setCapacity(3)

    #expect(pane.capacity == 3)
    #expect(pane.lines.map(\.line.message) == ["m8", "m9", "m10"])
}

@Test @MainActor func setCapacityPublishesImmediatelyRatherThanWaitingForATick() {
    // Without this, `lines` and `droppedLinesMessage` would keep describing
    // the OLD buffer until the next tick that happened to coalesce something
    // — and on a quiet stream that is not a few hundred milliseconds, it is
    // indefinitely. The pane would state fewer dropped lines than it had
    // actually dropped, which is the one thing this pane's truncation copy
    // exists to prevent.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    for i in 1...10 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.droppedLinesMessage == nil)

    pane.setCapacity(3)

    // No `refreshIfNeeded()` between the resize and these assertions.
    #expect(pane.lines.count == 3)
    #expect(pane.droppedLinesMessage == "7 earlier lines dropped")
}

@Test @MainActor func setCapacityLeavesTheStreamRunningRatherThanRestartingIt() {
    // Restarting would blank the pane, re-run `tilt logs --tail 2000`, and
    // restart the sequence numbering — losing exactly the scrollback the user
    // was adjusting. The buffer is resized in place instead, and the session
    // is untouched.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub, capacity: 10)
    let target = instance(port: 10350)
    pane.follow(target)
    let streamTaskBefore = pane.streamTaskForTesting
    let flushTaskBefore = pane.flushTaskForTesting

    pane.setCapacity(3)

    #expect(stub.streamedInstanceCount == 1, "no second `tilt logs` was started")
    #expect(pane.currentlyFollowedInstanceID == target.id)
    #expect(pane.streamTaskForTesting == streamTaskBefore, "the same consuming task is still draining")
    #expect(pane.flushTaskForTesting == flushTaskBefore, "the same flush loop is still ticking")
    #expect(pane.hasStreamEnded == false)
}

@Test @MainActor func linesArrivingAfterAResizeStillReachThePane() {
    // The other half of "the stream is not restarted": the resized buffer has
    // to go on accepting what the still-live stream delivers.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    for i in 1...10 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    pane.setCapacity(3)

    pane.receive(line(message: "after"))
    pane.refreshIfNeeded()

    #expect(pane.lines.map(\.line.message) == ["m9", "m10", "after"])
}

@Test @MainActor func shrinkingBelowTheThresholdGivesTheFastIntervalBackAtOnce() {
    // A user whose pane has gone sluggish lowers the setting to get its
    // responsiveness back. Leaving the slow interval in place until some
    // later tick decided otherwise would make the setting appear not to have
    // worked, which is the same broken promise one step smaller.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 5_000)
    #expect(intervalAfterTick(receiving: 5_000, on: pane) == LogPaneModel.floodedRefreshInterval)

    pane.setCapacity(1_000)

    // No tick between the resize and this assertion.
    #expect(pane.activeRefreshInterval == LogPaneModel.refreshInterval)
}

@Test @MainActor func shrinkingToAStillLargeBufferKeepsTheSlowInterval() {
    // The threshold is absolute, so a shrink that lands ON it changes
    // nothing: 2,500 lines is 2,500 lines whatever the ring's capacity says.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 5_000)
    #expect(intervalAfterTick(receiving: 5_000, on: pane) == LogPaneModel.floodedRefreshInterval)

    pane.setCapacity(2_500)

    #expect(pane.lines.count == 2_500)
    #expect(pane.activeRefreshInterval == LogPaneModel.floodedRefreshInterval)
}

@Test @MainActor func growingKeepsEveryLineTheUserHadScrolledBackThrough() {
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 3)
    for i in 1...5 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.droppedLinesMessage == "2 earlier lines dropped")

    pane.setCapacity(5_000)

    #expect(pane.capacity == 5_000)
    #expect(pane.lines.map(\.line.message) == ["m3", "m4", "m5"])
    #expect(pane.droppedLinesMessage == "2 earlier lines dropped", "growing discards nothing")
}

@Test @MainActor func setCapacityToTheCapacityAlreadyInForceDoesNotRepublish() {
    // `LogPaneView` calls this through
    // `DashboardModel.applyLogScrollbackSetting()` on every `onChange`,
    // including the `initial: true` one, and the picker's `onChange` can fire
    // for a value that did not actually change. Republishing there would bump
    // `linesGeneration` and throw away both derivation caches — an ANSI
    // strip, a brace scan, a JSON parse and a severity scan over the whole
    // buffer — for an identical answer. Counted, not timed.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    for i in 1...10 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    _ = pane.rows
    let recomputesBefore = pane.rowsRecomputeCount
    let detectionsBefore = pane.detectionRecomputeCount

    pane.setCapacity(10)

    _ = pane.rows
    #expect(pane.rowsRecomputeCount == recomputesBefore)
    #expect(pane.detectionRecomputeCount == detectionsBefore)
}

@Test @MainActor func setCapacityDoesNotDisturbAutoFollow() {
    // The user is reading something 800 lines up. Changing how much
    // scrollback the pane keeps is not them asking to be dragged back to the
    // tail — `isFollowing` is left exactly as they set it, in both
    // directions.
    let paused = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    for i in 1...10 { paused.receive(line(message: "m\(i)")) }
    paused.refreshIfNeeded()
    paused.scrollPositionChanged(isAtBottom: false)
    paused.setCapacity(3)
    #expect(paused.isFollowing == false)

    let tailing = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    for i in 1...10 { tailing.receive(line(message: "m\(i)")) }
    tailing.refreshIfNeeded()
    tailing.setCapacity(3)
    #expect(tailing.isFollowing == true)
}

@Test @MainActor func anExpandedBlockThatSurvivesAResizeStaysExpanded() {
    // `expandedBlockIDs` is keyed by `LogRow.ID`, i.e. sequence number, and
    // `LogBuffer.resize(to:)` preserves those. A block a user opened to read
    // must not collapse because they adjusted an unrelated preference — the
    // same guarantee `expansionStateSurvivesRingBufferEviction` makes about
    // ordinary eviction, which is what a shrink is.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    for i in 1...6 { pane.receive(line(message: "filler\(i)")) }
    for blockLine in [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#),
        line(message: "}"),
    ] { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    guard case .block = pane.rows.last?.row else {
        Issue.record("expected the res block as the last row"); return
    }
    let blockID = pane.rows.last!.id
    pane.toggleExpansion(blockID)
    #expect(pane.isExpanded(blockID))

    // Shrink to exactly the block's own four lines: every filler line goes,
    // the block survives, and its position in `rows` changes.
    pane.setCapacity(4)

    #expect(pane.rows.count == 1)
    #expect(pane.rows[0].id == blockID, "same block, same identity, new position")
    #expect(pane.isExpanded(blockID))
    #expect(pane.focusedBlockID == blockID)
    #expect(pane.focusedBlock != nil, "the detail pane can still resolve it")
}

@Test @MainActor func theJumpToNextErrorCursorKeepsItsPlaceAcrossAResize() {
    // `focusedErrorID` is a sequence number and `jumpToNextError()` searches
    // for the first failing row AFTER it. Preserved sequence numbers mean the
    // next jump goes forwards from where the user was, rather than rewinding
    // to the top of a buffer they have already read.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    pane.receive(line(message: "boom one", level: .error))
    for i in 1...4 { pane.receive(line(message: "quiet\(i)")) }
    pane.receive(line(message: "boom two", level: .error))
    for i in 5...8 { pane.receive(line(message: "quiet\(i)")) }
    pane.refreshIfNeeded()

    #expect(pane.jumpToNextError() == .moved(to: pane.rows[0].id))
    let cursorBefore = pane.focusedErrorID
    #expect(cursorBefore != nil)

    // Shrink so the first error is evicted but the second survives.
    pane.setCapacity(6)

    #expect(pane.focusedErrorID == cursorBefore, "the cursor is not rewound")
    #expect(pane.errorCount == 1, "only the second failure is still in the buffer")
    guard case .moved(let landed) = pane.jumpToNextError() else {
        Issue.record("expected the next jump to move forwards to the surviving error"); return
    }
    #expect(pane.rows.first { $0.id == landed }?.lines.first?.line.message == "boom two")
}

@Test @MainActor func followingANewInstanceUsesTheCapacityMostRecentlySet() {
    // `follow(_:)` builds a fresh `LogBuffer` from `buffer.capacity`. If it
    // read anything else — the type's fallback, say — switching instances
    // would silently revert the user's preference until they relaunched.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 5_000)
    pane.setCapacity(500)

    pane.follow(instance(port: 10350))

    #expect(pane.capacity == 500)
    for i in 1...600 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.lines.count == 500)
    #expect(pane.droppedCount == 100)
}

@Test @MainActor func aResizeAbsorbsPendingArrivalsSoTheNextTickDoesNotRedoThem() {
    // A resize publishes everything the buffer holds, which includes lines
    // that arrived since the last tick and had not been published yet. Those
    // arrivals are therefore no longer pending, and `pendingLineCount` says
    // so — otherwise the very next tick would rebuild an identical `lines`
    // snapshot and throw away both derivation caches for it. Counted, not
    // timed.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 10)
    for i in 1...10 { pane.receive(line(message: "m\(i)")) }
    // Deliberately no `refreshIfNeeded()`: all ten are still pending.

    pane.setCapacity(3)

    #expect(pane.lines.map(\.line.message) == ["m8", "m9", "m10"])
    _ = pane.rows
    let recomputesBefore = pane.rowsRecomputeCount

    pane.refreshIfNeeded()

    _ = pane.rows
    #expect(pane.linesCoalescedByLastTick == 0)
    #expect(pane.rowsRecomputeCount == recomputesBefore)
}
