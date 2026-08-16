import Foundation
import Testing
@testable import FulcrumKit

// MARK: - Authorization staleness

/// A permission read the test drives one call at a time: it announces itself
/// on the gate as `started-N` and then parks on `finish-N` until released, so
/// two refreshes can be held in flight simultaneously and finished in whatever
/// order the test wants. Nothing here sleeps.
@MainActor
private final class ScriptedAuthorizationReads {
    let gate = NamedGate()
    private(set) var calls = 0
    /// What each successive read returns. The first is the answer that must
    /// NOT survive.
    private let answers: [NotificationAuthorization]

    init(answers: [NotificationAuthorization]) {
        self.answers = answers
    }

    func read() async -> NotificationAuthorization {
        calls += 1
        let call = calls
        await gate.release("started-\(call)")
        try? await gate.wait("finish-\(call)")
        return answers[call - 1]
    }
}

/// The bug, exactly: Fulcrum re-reads the notification permission on every
/// activation, so leaving the app to fix a denial in System Settings and coming
/// back starts overlapping reads. An earlier `.denied` landing after a later
/// `.authorized` left the Settings pane insisting notifications were denied
/// when they were not — and nothing inside the app could clear it.
///
/// Fails against an `AuthorizationState` whose `refresh()` publishes
/// unconditionally.
@Test @MainActor func aStaleDeniedReadCannotOverwriteANewerAuthorizedOne() async throws {
    let reads = ScriptedAuthorizationReads(answers: [.denied, .authorized])
    let state = AuthorizationState { await reads.read() }

    let stale = Task { await state.refresh() }
    try await reads.gate.wait("started-1")

    let fresh = Task { await state.refresh() }
    try await reads.gate.wait("started-2")

    // The newer read finishes first and publishes.
    await reads.gate.release("finish-2")
    #expect(await fresh.value == .authorized)
    #expect(state.authorization == .authorized)

    // The older one finishes second. It still saw `.denied` — it is not being
    // cancelled or skipped, which is the point: it ran to completion and was
    // simply not allowed to publish.
    await reads.gate.release("finish-1")
    #expect(await stale.value == .denied)
    #expect(state.authorization == .authorized, "a superseded read overwrote a newer answer")
}

/// The opposite ordering must still work, or "latest wins" has been
/// implemented as "the first answer wins" — which would pass the test above
/// for the wrong reason on a fixture where the stale read finishes last.
@Test @MainActor func theNewestReadWinsEvenWhenItIsAlsoTheLastToFinish() async throws {
    let reads = ScriptedAuthorizationReads(answers: [.denied, .authorized])
    let state = AuthorizationState { await reads.read() }

    let stale = Task { await state.refresh() }
    try await reads.gate.wait("started-1")
    let fresh = Task { await state.refresh() }
    try await reads.gate.wait("started-2")

    await reads.gate.release("finish-1")
    _ = await stale.value
    await reads.gate.release("finish-2")
    _ = await fresh.value

    #expect(state.authorization == .authorized)
}

/// A refresh with nothing racing it must actually publish — a "gate" that
/// rejected everything would satisfy the staleness tests above.
@Test @MainActor func anUncontestedReadPublishesItsAnswer() async throws {
    let reads = ScriptedAuthorizationReads(answers: [.denied])
    let state = AuthorizationState { await reads.read() }
    #expect(state.authorization == .notDetermined)

    let refresh = Task { await state.refresh() }
    try await reads.gate.wait("started-1")
    await reads.gate.release("finish-1")
    _ = await refresh.value

    #expect(state.authorization == .denied)
}

// MARK: - Delivery ordering

/// Records completion order, and whether one piece of work was still running
/// when the next one started. An `actor` so the closures below can capture it
/// without any `@unchecked` escape hatch.
private actor DeliveryLog {
    private(set) var completed: [String] = []
    private var inFlight: Set<String> = []
    private(set) var overlaps: [String] = []

    func began(_ name: String) {
        if let other = inFlight.first { overlaps.append("\(name) began while \(other) was still running") }
        inFlight.insert(name)
    }

    func finished(_ name: String) {
        inFlight.remove(name)
        completed.append(name)
    }
}

/// The failure this guards: a resource fails and then recovers, both
/// notifications carry the same stable per-(port, resource) identifier, and
/// macOS updates one Notification Center entry in place. Whichever post lands
/// last is what the user is left reading. Delivered as independent tasks, the
/// recovery could land first and the user would see "failed" for a resource
/// that had just gone green.
///
/// Fails against an implementation that starts an independent `Task` per
/// piece of work: the second piece completes immediately while the first is
/// parked on the gate, giving `["recovery", "failure"]` and an overlap.
@Test @MainActor func deliveriesCompleteInSubmissionOrderEvenWhenTheFirstIsSlow() async throws {
    let queue = SerialAsyncQueue()
    let gate = NamedGate()
    let log = DeliveryLog()

    queue.enqueue {
        await log.began("failure")
        try? await gate.wait("post-failure")
        await log.finished("failure")
    }
    queue.enqueue {
        await log.began("recovery")
        await log.finished("recovery")
    }

    // Every chance for a non-serial implementation to run the second piece
    // first — it needs no gate and no further suspension to finish.
    for _ in 0..<10 { await Task.yield() }
    await gate.release("post-failure")
    await queue.drain()

    let completed = await log.completed
    let overlaps = await log.overlaps
    #expect(completed == ["failure", "recovery"])
    #expect(overlaps.isEmpty, "\(overlaps)")
}

/// Order is preserved across more than two pieces, and work submitted while
/// the chain is already running joins the end of it rather than jumping it —
/// a real burst is one failure per watch event, submitted as they arrive.
@Test @MainActor func workSubmittedWhileTheQueueIsBusyJoinsTheEnd() async throws {
    let queue = SerialAsyncQueue()
    let gate = NamedGate()
    let log = DeliveryLog()

    queue.enqueue {
        await log.began("first")
        try? await gate.wait("post-first")
        await log.finished("first")
    }
    for name in ["second", "third", "fourth"] {
        queue.enqueue {
            await log.began(name)
            await log.finished(name)
        }
    }
    for _ in 0..<10 { await Task.yield() }
    await gate.release("post-first")
    await queue.drain()

    let completed = await log.completed
    let overlaps = await log.overlaps
    #expect(completed == ["first", "second", "third", "fourth"])
    #expect(overlaps.isEmpty, "\(overlaps)")
}

/// A queue that has already drained must still run the next thing submitted —
/// a chain implementation that awaits a finished predecessor forever, or
/// forgets to replace its tail, would strand every notification after the
/// first burst.
@Test @MainActor func aQueueThatHasAlreadyDrainedStillRunsTheNextDelivery() async throws {
    let queue = SerialAsyncQueue()
    let log = DeliveryLog()

    queue.enqueue { await log.finished("first") }
    await queue.drain()
    queue.enqueue { await log.finished("second") }
    await queue.drain()

    let completed = await log.completed
    #expect(completed == ["first", "second"])
}
