import Foundation
import Testing
@testable import FulcrumKit

@Test func backoffGrowsExponentiallyAndCaps() {
    let policy = BackoffPolicy(base: .milliseconds(1000), cap: .seconds(30))
    #expect(policy.delay(forAttempt: 0) == .milliseconds(1000))
    #expect(policy.delay(forAttempt: 1) == .milliseconds(2000))
    #expect(policy.delay(forAttempt: 2) == .milliseconds(4000))
    #expect(policy.delay(forAttempt: 20) == .seconds(30), "must saturate, not overflow")
}

@Test func backoffNeverReturnsNegativeOrZero() {
    let policy = BackoffPolicy(base: .milliseconds(1000), cap: .seconds(30))
    for attempt in 0..<64 {
        #expect(policy.delay(forAttempt: attempt) > .zero)
    }
}

@MainActor
private func makeStore() -> InstanceStore {
    InstanceStore(instance: TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-10350", port: 10350,
        server: URL(string: "https://127.0.0.1:55501")!,
        certificateAuthorityPEM: Data(), token: "t"
    )))
}

/// Kubernetes-shaped watch endpoints close cleanly on idle timeout as routine
/// behaviour — that's normal, not a failure. `StubTransport` replays the same
/// payload for both `list()` and `watch()`'s byte stream; as watch input this
/// multi-line JSON blob splits into two fragments, neither of which decodes as a
/// `WatchEvent`, so the watch loop ends cleanly having delivered zero events.
/// That must read as `.degraded`, never `.live` — a clean close with nothing
/// watched is not health, and this task exists specifically to prevent it from
/// looking like health.
@Test @MainActor func cleanWatchCloseWithNoEventsDemotesToDegraded() async throws {
    let store = makeStore()
    let list = Data("""
    {"kind":"UIResourceList","metadata":{"resourceVersion":"5"},
     "items":[{"metadata":{"name":"web"},"status":{"updateStatus":"ok","order":1}}]}
    """.utf8)

    let supervisor = InstanceSupervisor(store: store) { instance in
        TiltAPIClient(instance: instance, transport: StubTransport(data: list))
    }
    let result = await supervisor.runOnce()

    #expect(store.resources.map(\.name) == ["web"], "list still loaded")
    #expect(store.connection == .degraded, "a clean close with no events is not live")
    #expect(result == false, "no events delivered, so this cycle must not reset backoff")
}

@Test @MainActor func failedStartDegradesWithoutClearingResources() async throws {
    struct Unreachable: Error {}
    let store = makeStore()
    store.apply(WatchEvent(type: .added, object: UIResource(
        metadata: .init(name: "stale", resourceVersion: "1"),
        status: .init(updateStatus: "ok", runtimeStatus: "ok", disableStatus: nil,
                      buildHistory: nil, pendingBuildSince: nil, order: 1)
    )))

    let supervisor = InstanceSupervisor(store: store) { instance in
        TiltAPIClient(instance: instance, transport: StubTransport(error: Unreachable()))
    }
    await supervisor.runOnce()

    #expect(store.connection == .degraded)
    #expect(store.resources.map(\.name) == ["stale"])
}

/// Distinguishes the two payloads `StubTransport` cannot: a genuine list response
/// and a genuine single watch event, so a watch that does real work before closing
/// is exercised distinctly from one that never yields anything. Path-discriminates
/// `uisessions` the same way `EmptyWatchTransport` does below and for the same
/// reason: an un-discriminated double would hand `session()` an `{"items":[]}`
/// look-alike and the retry loop added for Finding 1 would burn its whole default
/// budget (~2s) chasing a race that was never actually happening in this test.
private struct TwoPhaseTransport: DataTransport {
    let listPayload: Data
    let watchLine: Data

    func data(from url: URL) async throws -> Data {
        guard url.path.contains("uisessions") else { return listPayload }
        return Data("""
        {"items":[{"metadata":{"name":"Tiltfile"},"status":{}}]}
        """.utf8)
    }

    func bytes(from url: URL) async throws -> AsyncThrowingStream<UInt8, any Error> {
        AsyncThrowingStream { continuation in
            for byte in watchLine { continuation.yield(byte) }
            continuation.finish()
        }
    }
}

/// The other half of the `receivedAny` branch: a watch that delivers a real event
/// before closing did useful work, so that cycle counts as a success even though
/// the connection still ends `.degraded` once the stream closes.
@Test @MainActor func watchThatDeliversAnEventCountsAsSuccess() async throws {
    let store = makeStore()
    let list = Data("""
    {"kind":"UIResourceList","metadata":{"resourceVersion":"1"},"items":[]}
    """.utf8)
    let watchLine = Data("""
    {"type":"ADDED","object":{"metadata":{"name":"web","resourceVersion":"2"},"status":{"updateStatus":"ok","order":1}}}
    """.utf8)

    let supervisor = InstanceSupervisor(store: store) { instance in
        TiltAPIClient(instance: instance, transport: TwoPhaseTransport(listPayload: list, watchLine: watchLine))
    }
    let result = await supervisor.runOnce()

    #expect(store.resources.map(\.name) == ["web"], "the watched event was applied")
    #expect(store.connection == .degraded, "the watch still ended, even though it delivered an event")
    #expect(result == true, "a watch that did real work before closing is a successful cycle")
}

/// Discriminates `list()` from `session()` by path so a single transport can
/// answer both endpoints `runOnce()` hits after a successful list, distinctly
/// from the watch byte stream.
private struct SessionAwareTransport: DataTransport {
    let listPayload: Data
    let sessionPayload: Data
    let onSessionFetch: (@Sendable () async -> Void)?

    init(listPayload: Data, sessionPayload: Data, onSessionFetch: (@Sendable () async -> Void)? = nil) {
        self.listPayload = listPayload
        self.sessionPayload = sessionPayload
        self.onSessionFetch = onSessionFetch
    }

    func data(from url: URL) async throws -> Data {
        if url.path.contains("uisessions") {
            await onSessionFetch?()
            return sessionPayload
        }
        return listPayload
    }

    func bytes(from url: URL) async throws -> AsyncThrowingStream<UInt8, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private let emptyResourceList = Data("""
{"kind":"UIResourceList","metadata":{"resourceVersion":"1"},"items":[]}
""".utf8)

@Test @MainActor func runOnceResolvesTheProjectNameFromTheSession() async throws {
    let store = makeStore()
    let session = Data("""
    {"items":[{"metadata":{"name":"Tiltfile"},
     "status":{"tiltfileKey":"/Users/dev/src/northwind/Tiltfile"}}]}
    """.utf8)

    let supervisor = InstanceSupervisor(store: store) { instance in
        TiltAPIClient(instance: instance,
                      transport: SessionAwareTransport(listPayload: emptyResourceList, sessionPayload: session))
    }
    _ = await supervisor.runOnce()

    #expect(store.projectName == "northwind")
    #expect(store.displayName == "northwind")
    // Task 13/14: the raw path is kept alongside the derived name — Tilt
    // Down, Reveal in Finder, and `InstanceAliases` all key on this, not on
    // the derived display name.
    #expect(store.tiltfilePath == "/Users/dev/src/northwind/Tiltfile")
}

/// The ambiguity this pins: a missing/unusable `tiltfileKey` must leave
/// `projectName` nil rather than storing an empty or garbage name, and every
/// display site derives its fallback from the port through `displayName`.
@Test @MainActor func aMissingTiltfileKeyLeavesTheProjectNameNilAndFallsBackToThePortName() async throws {
    let store = makeStore() // port 10350, per makeStore()
    let session = Data("""
    {"items":[{"metadata":{"name":"Tiltfile"},"status":{}}]}
    """.utf8)

    let supervisor = InstanceSupervisor(store: store) { instance in
        TiltAPIClient(instance: instance,
                      transport: SessionAwareTransport(listPayload: emptyResourceList, sessionPayload: session))
    }
    _ = await supervisor.runOnce()

    #expect(store.projectName == nil)
    #expect(store.displayName == "tilt-10350")
}

/// `onResolved` is how `AppDelegate` mirrors a resolved name into
/// `RecentsStore` without `InstanceSupervisor` knowing that store exists.
/// This pins that it actually fires, exactly once, with the raw Tiltfile
/// path and the derived name — not, say, the display name or the store's
/// fallback.
@Test @MainActor func onResolvedFiresOnceWithTheTiltfilePathAndProjectName() async throws {
    let store = makeStore()
    let session = Data("""
    {"items":[{"metadata":{"name":"Tiltfile"},
     "status":{"tiltfileKey":"/Users/dev/src/northwind/Tiltfile"}}]}
    """.utf8)
    var resolved: [(path: String, name: String)] = []

    let supervisor = InstanceSupervisor(
        store: store,
        makeClient: { instance in
            TiltAPIClient(instance: instance,
                          transport: SessionAwareTransport(listPayload: emptyResourceList, sessionPayload: session))
        },
        onResolved: { path, name in resolved.append((path, name)) }
    )
    _ = await supervisor.runOnce()
    _ = await supervisor.runOnce()

    #expect(resolved.count == 1)
    #expect(resolved.first?.path == "/Users/dev/src/northwind/Tiltfile")
    #expect(resolved.first?.name == "northwind")
}

/// A missing/unusable `tiltfileKey` never resolves — `onResolved` must not
/// fire on a "no name" answer, only a real one.
@Test @MainActor func onResolvedNeverFiresWhenNoUsableTiltfileKeyIsEverFound() async throws {
    let store = makeStore()
    let session = Data(#"{"items":[{"metadata":{"name":"Tiltfile"},"status":{}}]}"#.utf8)
    var fired = false

    let supervisor = InstanceSupervisor(
        store: store,
        makeClient: { instance in
            TiltAPIClient(instance: instance,
                          transport: SessionAwareTransport(listPayload: emptyResourceList, sessionPayload: session))
        },
        onResolved: { _, _ in fired = true }
    )
    _ = await supervisor.runOnce()

    #expect(!fired)
}

/// "Fetches the session once when a connection is first established" — once
/// resolved, subsequent cycles must not keep re-fetching it.
@Test @MainActor func theSessionIsNotRefetchedOnceTheProjectNameIsResolved() async throws {
    let store = makeStore()
    let counter = CallCounter()
    let session = Data("""
    {"items":[{"metadata":{"name":"Tiltfile"},
     "status":{"tiltfileKey":"/Users/dev/src/northwind/Tiltfile"}}]}
    """.utf8)

    let supervisor = InstanceSupervisor(store: store) { instance in
        TiltAPIClient(instance: instance, transport: SessionAwareTransport(
            listPayload: emptyResourceList, sessionPayload: session,
            onSessionFetch: { await counter.increment() }
        ))
    }
    _ = await supervisor.runOnce()
    _ = await supervisor.runOnce()

    #expect(await counter.count == 1)
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Plays back a scripted sequence of `session()` responses, one per call,
/// holding on the last entry once the script is exhausted. Lets a single
/// test drive the internal empty-items/error retry loop deterministically,
/// without waiting out real multi-attempt delays.
private actor SessionScript {
    enum Step {
        case emptyItems
        case resolved(tiltfileKey: String)
        /// A real, non-empty answer that still carries no usable name.
        case unresolvedItem
        case failure
        case cancelled
    }

    private var steps: [Step]
    private(set) var callCount = 0

    init(_ steps: [Step]) { self.steps = steps }

    func next() -> Step {
        callCount += 1
        guard steps.count > 1 else { return steps[0] }
        return steps.removeFirst()
    }
}

private struct ScriptedSessionTransport: DataTransport {
    let listPayload: Data
    let script: SessionScript

    func data(from url: URL) async throws -> Data {
        guard url.path.contains("uisessions") else { return listPayload }
        switch await script.next() {
        case .emptyItems:
            return Data(#"{"items":[]}"#.utf8)
        case let .resolved(key):
            return Data("""
            {"items":[{"metadata":{"name":"Tiltfile"},"status":{"tiltfileKey":"\(key)"}}]}
            """.utf8)
        case .unresolvedItem:
            return Data(#"{"items":[{"metadata":{"name":"Tiltfile"},"status":{}}]}"#.utf8)
        case .failure:
            struct TransientFailure: Error {}
            throw TransientFailure()
        case .cancelled:
            throw CancellationError()
        }
    }

    func bytes(from url: URL) async throws -> AsyncThrowingStream<UInt8, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

/// Finding 1 of the Task 1 review, measured against a live tilt v0.36.3
/// instance: `uisessions` answers `{"items":[]}` — 200 OK, zero items — for
/// ~115ms after tilt's kubeconfig entry first appears, before its Tiltfile
/// session object exists. Treating that as a resolved "no name" (the
/// previous behaviour) froze a project queried inside that window at
/// `tilt-<port>` for its entire lifetime. An empty `items` array must be
/// retried, not treated as an answer.
@Test @MainActor func emptyItemsAreRetriedUntilResolvedWithinOneCycle() async throws {
    let store = makeStore()
    let script = SessionScript([.emptyItems, .emptyItems, .resolved(tiltfileKey: "/Users/dev/src/northwind/Tiltfile")])
    let supervisor = InstanceSupervisor(
        store: store,
        sessionRetry: SessionRetryPolicy(maxAttempts: 10, delay: .milliseconds(1)),
        makeClient: { instance in
            TiltAPIClient(instance: instance, transport: ScriptedSessionTransport(listPayload: emptyResourceList, script: script))
        }
    )
    _ = await supervisor.runOnce()

    #expect(store.projectName == "northwind")
    #expect(await script.callCount == 3, "the two empty-items answers must not have been treated as terminal")
}

/// The same race also applies to a transient transport error (timeout, 500)
/// per the review finding — it must be retried, not frozen at the fallback.
@Test @MainActor func aTransientSessionFetchFailureIsRetried() async throws {
    let store = makeStore()
    let script = SessionScript([.failure, .resolved(tiltfileKey: "/Users/dev/src/northwind/Tiltfile")])
    let supervisor = InstanceSupervisor(
        store: store,
        sessionRetry: SessionRetryPolicy(maxAttempts: 10, delay: .milliseconds(1)),
        makeClient: { instance in
            TiltAPIClient(instance: instance, transport: ScriptedSessionTransport(listPayload: emptyResourceList, script: script))
        }
    )
    _ = await supervisor.runOnce()

    #expect(store.projectName == "northwind")
}

/// The other half of "bounded": a tilt version (or a genuinely broken
/// apiserver) that never returns a non-empty `uisessions` answer must not be
/// retried forever, in this cycle or any later one.
@Test @MainActor func sessionResolutionGivesUpAfterTheAttemptCapAndKeepsTheFallbackName() async throws {
    let store = makeStore() // port 10350, per makeStore()
    let script = SessionScript([.emptyItems]) // never resolves
    let supervisor = InstanceSupervisor(
        store: store,
        sessionRetry: SessionRetryPolicy(maxAttempts: 3, delay: .milliseconds(1)),
        makeClient: { instance in
            TiltAPIClient(instance: instance, transport: ScriptedSessionTransport(listPayload: emptyResourceList, script: script))
        }
    )
    _ = await supervisor.runOnce()
    _ = await supervisor.runOnce() // a later cycle must not resume spending the exhausted budget

    #expect(store.projectName == nil)
    #expect(store.displayName == "tilt-10350")
    #expect(await script.callCount == 3, "capped at maxAttempts across the supervisor's lifetime, not per cycle")
}

/// A definitive non-empty answer with no usable `tiltfileKey` is real data
/// from tilt, not race noise — it must not be retried like an empty-items
/// answer would be, even though the attempt budget has room left.
@Test @MainActor func aDefinitiveNoNameAnswerIsNotRetriedDespiteRemainingBudget() async throws {
    let store = makeStore()
    let script = SessionScript([.unresolvedItem, .resolved(tiltfileKey: "/Users/dev/src/northwind/Tiltfile")])
    let supervisor = InstanceSupervisor(
        store: store,
        sessionRetry: SessionRetryPolicy(maxAttempts: 10, delay: .milliseconds(1)),
        makeClient: { instance in
            TiltAPIClient(instance: instance, transport: ScriptedSessionTransport(listPayload: emptyResourceList, script: script))
        }
    )
    _ = await supervisor.runOnce()
    _ = await supervisor.runOnce()

    #expect(store.projectName == nil)
    #expect(await script.callCount == 1, "a real no-name answer is terminal, not retried on a later cycle")
}

/// Finding 3: cancellation must not be mistaken for a failure worth retrying
/// (there is no point — the supervisor is shutting down) or for a resolved
/// answer.
@Test @MainActor func cancellationDuringSessionFetchStopsImmediatelyWithoutRetrying() async throws {
    let store = makeStore()
    let script = SessionScript([.cancelled, .resolved(tiltfileKey: "/Users/dev/src/northwind/Tiltfile")])
    let supervisor = InstanceSupervisor(
        store: store,
        sessionRetry: SessionRetryPolicy(maxAttempts: 10, delay: .milliseconds(1)),
        makeClient: { instance in
            TiltAPIClient(instance: instance, transport: ScriptedSessionTransport(listPayload: emptyResourceList, script: script))
        }
    )
    _ = await supervisor.runOnce()

    #expect(store.projectName == nil)
    #expect(await script.callCount == 1, "cancellation must stop the loop immediately rather than retrying")
}

/// A transport whose `list()` always succeeds but whose watch always ends
/// immediately with zero events — the "list is fine, watch keeps dying" failure
/// mode `BackoffPolicy` exists to protect against. Records the wall-clock time of
/// each `list()` call so the test can inspect the gaps `start()` actually slept.
private actor CallLog {
    private(set) var timestamps: [ContinuousClock.Instant] = []
    func record() { timestamps.append(ContinuousClock.now) }
}

/// Path-discriminating so the backoff tests below measure only `list()`
/// cycles. Recording on *any* URL (the earlier version of this double) meant
/// adding the `session()` fetch silently doubled up log entries per cycle
/// and corrupted the gap-based timing assertions — the exact regression
/// Finding 2 of the Task 1 review flagged. `uisessions` answers with a
/// stable non-empty-but-nameless payload (not logged, and not
/// `{"items":[]}`) so it resolves in exactly one attempt and never
/// contributes retry-driven timing noise of its own.
private struct EmptyWatchTransport: DataTransport {
    let log: CallLog

    func data(from url: URL) async throws -> Data {
        guard url.path.contains("uisessions") else {
            await log.record()
            return Data("""
            {"kind":"UIResourceList","metadata":{"resourceVersion":"1"},"items":[]}
            """.utf8)
        }
        return Data("""
        {"items":[{"metadata":{"name":"Tiltfile"},"status":{}}]}
        """.utf8)
    }

    func bytes(from url: URL) async throws -> AsyncThrowingStream<UInt8, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

/// Records the `Duration` values `start()`'s retry loop actually requests from
/// its sleeper, in order — the seam `InstanceSupervisor.sleeper` exists for.
private actor DelayLog {
    private(set) var delays: [Duration] = []
    func record(_ delay: Duration) { delays.append(delay) }
}

/// Pins the exact regression the reviewer flagged: `runOnce()` used to return
/// `true` unconditionally once `list()` succeeded, so `start()` reset `attempt`
/// to 0 every cycle and every retry used the base delay forever.
///
/// `backoffGrowsExponentiallyAndCaps` above and `cleanWatchCloseWithNoEventsDemotesToDegraded`
/// already pin the regression's two halves in isolation — the pure backoff math, and
/// `runOnce()` returning `false` on an event-less watch. Neither exercises the wiring
/// between them inside `start()`'s loop: that a failing cycle actually increments the
/// `attempt` counter fed to `backoff.delay`, cycle over cycle. This test closes that gap.
///
/// This used to measure wall-clock gaps between `list()` calls via `Task.sleep` and
/// `ContinuousClock` timestamps. Under swift-testing's parallel execution that measurement
/// is not trustworthy — a loaded machine can inflate an early gap past a later one, which is
/// exactly what happened here (see git history for the observed failure). Substituting a
/// recording `sleeper` for `Task.sleep` lets the test assert on the `Duration` values the
/// code actually requests — deterministic, and exact rather than a threshold.
@Test(.timeLimit(.minutes(1))) @MainActor func backoffRequestsGrowingDelaysOnRepeatedWatchFailure() async throws {
    let store = makeStore()
    let log = CallLog()
    let delayLog = DelayLog()
    let policy = BackoffPolicy(base: .milliseconds(10), cap: .milliseconds(50))

    let supervisor = InstanceSupervisor(
        store: store,
        backoff: policy,
        makeClient: { instance in
            TiltAPIClient(instance: instance, transport: EmptyWatchTransport(log: log))
        },
        sleeper: { delay in await delayLog.record(delay) }
    )

    supervisor.start()
    // The sleeper above doesn't actually sleep, so the loop free-runs and this
    // settles almost immediately; poll rather than assume a fixed wall-clock
    // budget so this stays robust under whatever load the machine is under.
    // The `.timeLimit` above is the backstop if something is actually broken.
    while await delayLog.delays.count < 5 {
        try await Task.sleep(for: .milliseconds(5))
    }
    supervisor.stop()

    let delays = await delayLog.delays
    #expect(delays.count >= 5, "need several cycles to observe growth")

    // Every cycle's watch yields nothing, so every cycle is a failure: attempt
    // climbs 1, 2, 3, ... and the requested delay must match the policy's pure
    // function exactly for each one, capping once attempt is large enough.
    let expected = (1...delays.count).map { policy.delay(forAttempt: $0) }
    #expect(delays == expected, "requested delays must follow the backoff sequence for consecutive failures")
    #expect(delays.last! == .milliseconds(50), "later retries should have reached the cap")
}

/// The retry loop's own on/off switch needs coverage: this is the thing the whole
/// task exists to add, and until now nothing exercised `start()`/`stop()` at all.
@Test(.timeLimit(.minutes(1))) @MainActor func stopHaltsTheRetryLoop() async throws {
    let store = makeStore()
    let log = CallLog()
    let policy = BackoffPolicy(base: .milliseconds(5), cap: .milliseconds(20))

    let supervisor = InstanceSupervisor(store: store, backoff: policy) { instance in
        TiltAPIClient(instance: instance, transport: EmptyWatchTransport(log: log))
    }

    supervisor.start()
    try await Task.sleep(for: .milliseconds(80))
    supervisor.stop()

    // Cancellation is cooperative: a cycle already in flight when stop() lands is
    // free to finish (only the *next* iteration's checks observe the cancellation),
    // so give that one cycle room to settle before taking the baseline count.
    try await Task.sleep(for: .milliseconds(50))
    let countAtStop = await log.timestamps.count
    #expect(countAtStop > 0, "the loop should have cycled at least once")

    // If stop() didn't actually cancel the loop, more calls would keep arriving.
    try await Task.sleep(for: .milliseconds(150))
    let countAfterWaiting = await log.timestamps.count
    #expect(countAfterWaiting == countAtStop, "no further runOnce() calls after stop() has settled")
}

/// The notification feature needs to see resources on every watch tick, and it
/// must NOT get there by starting a second polling loop of its own alongside
/// this one — two loops asking tilt the same question independently would
/// disagree about ordering and double-count transitions. `onResourcesUpdated`
/// is the hook: the supervisor already applies every list and every watch
/// event, so it is the one place that knows a store's resources just changed.
@Test @MainActor func everyAppliedUpdateIsHandedToTheResourceObserver() async throws {
    let store = makeStore()
    let list = Data("""
    {"kind":"UIResourceList","metadata":{"resourceVersion":"1"},"items":[]}
    """.utf8)
    let watchLine = Data("""
    {"type":"ADDED","object":{"metadata":{"name":"web","resourceVersion":"2"},"status":{"updateStatus":"error","order":1}}}
    """.utf8)

    // Snapshots taken at call time, not a reference to the store: the point is
    // that the observer is invoked AFTER each apply, with the state that apply
    // produced. Holding the store and reading it at the end would pass even if
    // both calls arrived before anything was applied.
    var seen: [[String]] = []
    let supervisor = InstanceSupervisor(
        store: store,
        makeClient: { instance in
            TiltAPIClient(instance: instance,
                          transport: TwoPhaseTransport(listPayload: list, watchLine: watchLine))
        },
        onResourcesUpdated: { updated in seen.append(updated.resources.map(\.name)) }
    )
    await supervisor.runOnce()

    #expect(seen == [[], ["web"]],
            "once for the initial list (empty), once for the watch event that added web")
}

/// A cycle that never connects has nothing to report — firing the observer with
/// stale resources would let a transport outage read as a resource state.
@Test @MainActor func aFailedListDoesNotInvokeTheResourceObserver() async throws {
    struct Unreachable: Error {}
    let store = makeStore()
    var calls = 0
    let supervisor = InstanceSupervisor(
        store: store,
        makeClient: { instance in
            TiltAPIClient(instance: instance, transport: StubTransport(error: Unreachable()))
        },
        onResourcesUpdated: { _ in calls += 1 }
    )
    await supervisor.runOnce()

    #expect(calls == 0)
}
