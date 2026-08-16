import Foundation
import os

/// Exponential backoff, saturating at `cap`.
public struct BackoffPolicy: Sendable {
    private let base: Duration
    private let cap: Duration

    public init(base: Duration = .seconds(1), cap: Duration = .seconds(30)) {
        self.base = base
        self.cap = cap
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        // Clamp the shift before it happens. Swift's `<<` on Int is a "smart shift" —
        // it does not trap or produce undefined behaviour at width 64, it just returns
        // 0. The real hazard is smaller: at shift 63 the result flips sign (Int.min),
        // which would make this return a garbage negative Duration and the retry loop
        // would spin with no wait at all. Capping well below that keeps it sane.
        let shift = min(attempt, 16)
        let scaled = base * (1 << shift)
        return scaled > cap ? cap : scaled
    }
}

/// Governs how hard `InstanceSupervisor` tries to resolve a project's real
/// name before giving up for the life of that connection.
///
/// Measured against a live tilt v0.36.3 instance: `uisessions` answers
/// `{"items":[]}` — 200 OK, zero items — for a real window (~115ms, twice
/// measured) after tilt's kubeconfig entry first appears and before its
/// Tiltfile session object exists. `localhost` TLS GETs otherwise measure
/// ~20ms, so a supervisor started right as `tilt up` begins can and does
/// land inside that window. An empty `items` array must count as "not yet
/// resolved," not "resolved to no name" — treating it as terminal freezes
/// that instance at the `tilt-<port>` fallback for its entire lifetime, with
/// nothing ever retrying. The same applies to a transient transport failure
/// (timeout, 500). `maxAttempts` bounds the retries so a tilt version that
/// never populates `tiltfileKey` doesn't retry forever.
public struct SessionRetryPolicy: Sendable {
    public let maxAttempts: Int
    public let delay: Duration

    /// 20 attempts at 100ms apart is a 2s worst-case budget — roughly 17x
    /// the measured ~115ms race, with margin for a slower machine, while
    /// still bounded.
    public init(maxAttempts: Int = 20, delay: Duration = .milliseconds(100)) {
        self.maxAttempts = maxAttempts
        self.delay = delay
    }
}

/// Signature of `Task.sleep(for:)`. Exists as a seam so tests can observe the
/// exact `Duration` the retry loop requests instead of measuring wall-clock
/// gaps — this project has repeatedly found timing-based assertions on
/// concurrently-run tests to be unreliable under parallel load. Production
/// always uses the real `Task.sleep`; only tests substitute a recorder.
public typealias BackoffSleeper = @Sendable (Duration) async throws -> Void

/// Keeps one `InstanceStore` fed: list, then watch, reconnecting on failure.
@MainActor
public final class InstanceSupervisor {
    private let store: InstanceStore
    private let makeClient: @Sendable (TiltInstance) -> TiltAPIClient
    private let backoff: BackoffPolicy
    private let sessionRetry: SessionRetryPolicy
    private let sleeper: BackoffSleeper
    private var task: Task<Void, Never>?
    /// How many `session()` fetches have been attempted, across every
    /// `runOnce()` call this supervisor has ever made. One supervisor lives
    /// for exactly one connection's lifetime (a restarted instance gets a
    /// fresh store and a fresh supervisor), so this budget is spent once per
    /// connection, not once per cycle — see `resolveProjectNameIfNeeded`.
    private var sessionFetchAttempts = 0
    /// Set once tilt has given a definitive non-empty `uisessions` answer
    /// that still yields no usable name — a real "no name available", not
    /// the empty-items startup race. Distinct from the attempt cap: this
    /// stops retries immediately, regardless of how much of the budget in
    /// `sessionRetry.maxAttempts` remains.
    private var gaveUpOnSessionResolution = false
    /// Fires once, the moment the Tiltfile path and project name are first
    /// resolved for this connection — `resolveProjectNameIfNeeded` only ever
    /// reaches this on one cycle per supervisor lifetime (see
    /// `gaveUpOnSessionResolution` and the attempt cap). Lets a caller
    /// (`AppDelegate`) mirror the resolved name into `RecentsStore` so a
    /// stopped project keeps showing it — see
    /// `RecentsStore.updateResolvedName` — without `InstanceSupervisor`
    /// needing to know that store exists; it only knows tilt's session API.
    private let onResolved: (@MainActor (_ tiltfilePath: String, _ projectName: String) -> Void)?

    private static let logger = Logger(subsystem: "com.originalfunction.fulcrum", category: "InstanceSupervisor")

    /// Called after every applied update — the initial list and each watch
    /// event — with the store whose resources just changed. This is the one
    /// observation path the notification feature hangs off (`AppDelegate`
    /// forwards it to `NotificationCoordinator`); nothing polls tilt a second
    /// time to find out what the supervisor already knows.
    ///
    /// Declared *after* `makeClient` in `init`, not before it: an unlabelled
    /// trailing closure is matched by forward scan to the first unfulfilled
    /// parameter that can accept one, and every existing call site passes
    /// `makeClient` as a trailing closure. Placing this parameter ahead of
    /// `makeClient` silently stole all of them (confirmed — it broke every
    /// `InstanceSupervisor` test at once when tried).
    private let onResourcesUpdated: (@MainActor (InstanceStore) -> Void)?

    public init(
        store: InstanceStore,
        backoff: BackoffPolicy = BackoffPolicy(),
        sessionRetry: SessionRetryPolicy = SessionRetryPolicy(),
        makeClient: @escaping @Sendable (TiltInstance) -> TiltAPIClient = { TiltAPIClient(instance: $0) },
        onResourcesUpdated: (@MainActor (InstanceStore) -> Void)? = nil,
        onResolved: (@MainActor (_ tiltfilePath: String, _ projectName: String) -> Void)? = nil,
        sleeper: @escaping BackoffSleeper = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.onResourcesUpdated = onResourcesUpdated
        self.backoff = backoff
        self.sessionRetry = sessionRetry
        self.makeClient = makeClient
        self.onResolved = onResolved
        self.sleeper = sleeper
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                let succeeded = await self.runOnce()
                attempt = succeeded ? 0 : attempt + 1
                if Task.isCancelled { return }
                try? await self.sleeper(self.backoff.delay(forAttempt: attempt))
            }
        }
    }

    /// Cancels the retry loop. Dropping the last reference to this object does
    /// **not** terminate an in-flight loop by itself — a loop iteration holds a
    /// strong reference to `self` for the duration of its current `runOnce()`
    /// call, so ARC cannot free it mid-cycle. Callers must call `stop()`
    /// explicitly before discarding a supervisor.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One list-then-watch cycle. Returns whether it connected successfully.
    ///
    /// On failure the store is marked `degraded` and its resources are left
    /// untouched — stale data beats a blank table.
    @discardableResult
    public func runOnce() async -> Bool {
        let client = makeClient(store.instance)
        do {
            let list = try await client.list()
            store.applyList(list)
            store.setConnection(.live)
            onResourcesUpdated?(store)
        } catch {
            store.setConnection(.degraded)
            return false
        }

        await resolveProjectNameIfNeeded(using: client)

        // Watch outcome decides both the connection state and the return value.
        // Kubernetes-shaped watch endpoints close cleanly on idle timeout as routine
        // behaviour, so a clean end is NOT success — it means nothing is watching any
        // more, and leaving the store `.live` would show false-healthy status.
        //
        // Returning false on any watch failure is what makes backoff work: if the
        // instance lists fine but its watch keeps dying, an unconditional `true` would
        // reset the attempt counter every cycle and the loop would retry at the base
        // delay forever.
        do {
            var receivedAny = false
            for try await event in client.watch(fromResourceVersion: store.lastResourceVersion) {
                store.apply(event)
                onResourcesUpdated?(store)
                receivedAny = true
            }
            store.setConnection(.degraded)
            // A stream that delivered events before closing did real work; treat that as a
            // successful cycle so a long-lived healthy watch does not accumulate backoff.
            // A stream that closed without ever yielding is a failure.
            //
            // KNOWN LIMITATION: this is a boolean, not a rate. A watch that flaps —
            // yields exactly one event, dies, repeat — returns true every cycle and so
            // never accumulates backoff, which is the same failure this return value
            // was introduced to fix, one event short of triggering it. Closing it
            // properly needs a rate or duration measure (e.g. treat a cycle shorter
            // than the current backoff delay as a failure regardless of event count).
            // Deferred deliberately: it is a design decision, not an oversight.
            return receivedAny
        } catch {
            store.setConnection(.degraded)
            return false
        }
    }

    /// Resolves `store.projectName`, retrying while the answer is
    /// indistinguishable from "not ready yet": an empty `items` array (the
    /// startup race `SessionRetryPolicy` documents) or a transient transport
    /// error. Bounded by `sessionRetry.maxAttempts` across this supervisor's
    /// whole lifetime, so a tilt version that never populates `tiltfileKey`
    /// eventually stops trying rather than retrying forever.
    ///
    /// A non-empty `items` array with no usable `tiltfileKey` is a real
    /// answer, not race noise, and is terminal: no further attempts.
    private func resolveProjectNameIfNeeded(using client: TiltAPIClient) async {
        while store.projectName == nil, !gaveUpOnSessionResolution, sessionFetchAttempts < sessionRetry.maxAttempts {
            sessionFetchAttempts += 1
            do {
                let session = try await client.session()
                guard let first = session.items.first else {
                    // Empty items: the startup race. Not an answer — retry.
                    try? await Task.sleep(for: sessionRetry.delay)
                    continue
                }
                if let tiltfileKey = first.status.tiltfileKey,
                   let name = ProjectIdentity.displayName(forTiltfilePath: tiltfileKey) {
                    store.setResolvedTiltfile(path: tiltfileKey, projectName: name)
                    onResolved?(tiltfileKey, name)
                } else {
                    // A real, non-empty answer with no usable tiltfileKey — not
                    // the race this retry exists for. Terminal: later cycles
                    // must not keep re-asking a question tilt already answered.
                    gaveUpOnSessionResolution = true
                }
                return
            } catch is CancellationError {
                // The supervisor is shutting down, not a fetch failure. Don't
                // log it as one, and don't spend another attempt retrying —
                // there won't be a next cycle to retry on.
                return
            } catch {
                Self.logger.error("session() fetch failed, will retry: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: sessionRetry.delay)
            }
        }
    }
}
