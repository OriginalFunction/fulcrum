import Foundation

/// Suspends callers by name until explicitly released, so a test can observe
/// an action *while* it is in flight rather than only before and after.
/// Shared by both action-coordinator test suites — the `CommandRunning`
/// doubles that use it stay separate (they key on different argv positions),
/// but the gate itself must not exist in two copies that can drift apart.
///
/// Three properties make this usable as a mutation-detection harness rather
/// than a hang generator:
///
/// 1. **Order-independent.** `wait` before `release`, or `release` before
///    anyone is waiting (which arms a release for the next `wait` on that
///    name), both work. Tests never have to know or care about task-scheduling
///    order.
///
/// 2. **Many waiters per name.** `waiting` is a FIFO queue, not one
///    continuation per name. The single-continuation version this replaced
///    silently *overwrote* the first waiter's continuation when a second
///    waiter arrived on the same name, stranding it forever — which is exactly
///    what a mutated coordinator that stops refusing a concurrent action
///    produces. Measured with `ResourceActionCoordinator`'s entry guard
///    deleted: "SWIFT TASK CONTINUATION MISUSE: wait(_:) leaked its
///    continuation", and a test process still running after six minutes.
///
/// 3. **Cancellation-aware.** A `@Test(.timeLimit(...))` trait enforces its
///    limit by cancelling the test's `Task`, and a plain
///    `withCheckedContinuation` does not observe that cancellation at all —
///    the limit would elapse while the test stayed parked. Resuming with
///    `CancellationError` instead lets the test body run on and record its
///    real assertion failures, which is the difference between a diagnosis
///    and a stalled CI run.
actor NamedGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiting: [String: [Waiter]] = [:]
    /// Releases that arrived before anyone was waiting, counted per name so
    /// two early releases arm two subsequent waits rather than collapsing
    /// into one.
    private var armed: [String: Int] = [:]
    /// Waiters cancelled before their continuation was registered. See
    /// `wait(_:)` — `withTaskCancellationHandler` runs `onCancel` immediately
    /// when the task is *already* cancelled on entry, which can land before
    /// the continuation exists to resume.
    private var cancelledBeforeRegistering: Set<UUID> = []

    func wait(_ name: String) async throws {
        if let pending = armed[name], pending > 0 {
            armed[name] = pending - 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledBeforeRegistering.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[name, default: []].append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id, name: name) }
        }
    }

    /// Releases the longest-waiting caller on `name`, or arms one release for
    /// the next `wait` if nobody is waiting yet.
    func release(_ name: String) {
        guard var queue = waiting[name], !queue.isEmpty else {
            armed[name, default: 0] += 1
            return
        }
        let waiter = queue.removeFirst()
        waiting[name] = queue
        waiter.continuation.resume()
    }

    private func cancel(_ id: UUID, name: String) {
        guard var queue = waiting[name], let index = queue.firstIndex(where: { $0.id == id }) else {
            // The continuation is not registered yet; leave a note for
            // `wait(_:)` to fail it the moment it is.
            cancelledBeforeRegistering.insert(id)
            return
        }
        let waiter = queue.remove(at: index)
        waiting[name] = queue
        waiter.continuation.resume(throwing: CancellationError())
    }
}
