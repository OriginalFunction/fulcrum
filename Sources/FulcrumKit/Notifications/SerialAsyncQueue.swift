import Foundation

/// Runs fire-and-forget async work strictly in the order it was submitted.
///
/// Written for notification delivery, where the ordering is the message.
/// `NotificationPresenter.deliver(_:)` used to start an independent
/// `Task` per notification, and independent tasks finish in whatever order the
/// runtime likes. Two notifications about the SAME resource — a failure and
/// then its recovery — carry a stable per-(port, resource) identifier, so
/// macOS updates one Notification Center entry in place rather than stacking
/// them: whichever task posted last is the entry the user is left looking at.
/// Inverted, that reads "web recovered" for a resource that has just failed,
/// which is worse than no notification at all.
///
/// Serialised globally rather than per resource. Per-resource keying would
/// need a dictionary of chains, an eviction rule for resources that go away,
/// and a decision about what "same resource" means across a port change — all
/// to buy concurrency between notifications, of which this app delivers a
/// handful an hour. One chain has none of those questions and orders
/// everything, including two resources whose notifications a user reads as a
/// sequence.
@MainActor
public final class SerialAsyncQueue {
    /// The most recently submitted piece of work. Each new submission awaits
    /// this one before starting, so the chain is the ordering — there is no
    /// queue array to keep in step with it, and nothing to drain on failure.
    private var tail: Task<Void, Never>?

    public init() {}

    /// Submits `work`, to run after everything submitted before it. Returns
    /// immediately; callers are fire-and-forget by design (a delivery must
    /// never make the caller wait on the notification system).
    public func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            // `.value`, not `await previous` — a `Task<Void, Never>` never
            // throws and never needs cancellation handling here: cancelling a
            // notification post mid-flight would only produce the same
            // ambiguous ordering this type exists to remove.
            await previous?.value
            await work()
        }
    }

    /// Awaits everything submitted so far.
    ///
    /// Nothing in the app calls this — deliveries are fire-and-forget. It
    /// exists because a test cannot assert on completion ORDER without a join
    /// point, and the alternative (asserting after a sleep) is the timing-shaped
    /// test this project has replaced seven of.
    public func drain() async {
        await tail?.value
    }
}
