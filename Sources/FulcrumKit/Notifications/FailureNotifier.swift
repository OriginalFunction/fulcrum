import Foundation

/// A resource health transition worth surfacing to the user, as decided by
/// `FailureNotifier`. Pure data — delivering it as an actual system
/// notification is a later concern that lives outside `FulcrumKit`.
public struct FailureNotification: Equatable, Sendable {
    public enum Kind: Sendable {
        case failed
        case recovered
    }

    public let instanceName: String
    public let port: Int
    public let resourceName: String
    public let kind: Kind

    public init(instanceName: String, port: Int, resourceName: String, kind: Kind) {
        self.instanceName = instanceName
        self.port = port
        self.resourceName = resourceName
        self.kind = kind
    }
}

/// Decides which resource health transitions are worth notifying about.
///
/// This is the whole feature: Fulcrum lives in the menu bar so the user is
/// NOT looking at it, and a notifier that fires on every already-broken
/// resource at launch gets muted within a day — worse than no notifier at
/// all, because the user now distrusts a channel they've silenced.
///
/// ## What counts as a failure
/// Only `.error` does. `.pending` and `.building` are ordinary transient
/// states on the way to something else (see `ResourceHealth.derive`'s own
/// reasoning for why they are distinct from `.ok`), not failures — treating
/// them as newsworthy would notify on every routine rebuild. `.disabled` is
/// the user's own doing, not a failure either.
///
/// ## Baseline
/// The first time a given `(port, resource name)` pair is ever passed to
/// `observe`, it is recorded silently, however broken it already is. This is
/// what makes launching the app against a project with pre-existing failures
/// silent instead of a spam burst: `tilt` replays full current state on
/// connect, and that replay must not read as "everything just broke".
///
/// ## Reconnects
/// A dropped-and-retried watch (`InstanceSupervisor`'s backoff loop) reuses
/// the same `InstanceSupervisor` and the same `FailureNotifier` for the
/// life of that connection — restarting the loop is not the same as
/// restarting the app. Because baseline state lives in this object, not in
/// the connection, a flaky reconnect does not re-arm the baseline: a
/// resource that was already red before the drop is still known to be red
/// after it, so the reconnect itself notifies nothing. The alternative
/// (re-baselining on every reconnect) would either storm on every flaky
/// watch or, if reconnects are frequent, silently swallow real failures that
/// happen to land right after one.
///
/// ## Persistence across app launches
/// This object's state is in-memory only — nothing is written to disk. A
/// fresh app launch constructs a fresh `FailureNotifier`, so a resource that
/// is already red when the app starts is (correctly, per the baseline rule
/// above) silent on launch, exactly like the tilt-replay case. The
/// trade-off: if a resource broke while the app was not running and is
/// still broken at next launch, the user gets no notification for it — only
/// the dashboard's own display will show it red. Given the choice between
/// "silent about a pre-existing failure until it changes again" and
/// "storms every relaunch with every currently-broken resource", the former
/// is the one that keeps the channel trustworthy.
///
/// ## Keying
/// State is tracked per `(port, resource name)`, never per name alone.
/// `tilt` emits duplicate resource names across separate instances (e.g. two
/// projects both running a "web" resource) — keying on name alone would let
/// one instance's failure suppress or fire for another.
@MainActor
public final class FailureNotifier {
    private struct Key: Hashable {
        let port: Int
        let resourceName: String
    }

    /// Settable, not fixed at construction: the user can change the policy in
    /// Settings mid-session, and this is what makes that change take effect
    /// without discarding the baseline underneath it. Rebuilding the notifier
    /// on a policy change would instead re-arm every baseline — an
    /// already-red resource would read as a fresh failure on the next tick.
    /// This is also what `NotificationPolicy`'s own doc comment already
    /// promised ("switching back mid-session does not miss a transition that
    /// happened while muted"): `observe` keeps tracking health while `.off`,
    /// it only withholds the notification.
    public var policy: NotificationPolicy
    private var priorHealth: [Key: ResourceHealth] = [:]

    public init(policy: NotificationPolicy) {
        self.policy = policy
    }

    /// Observes one snapshot of `resources` for a given instance and returns
    /// what should be delivered for it. Pure with respect to its inputs
    /// (deterministic per call), aside from the notifier's own running
    /// baseline, which this call also advances.
    ///
    /// A resource absent from `resources` (renamed or removed from the
    /// Tiltfile) is left untouched in the baseline rather than forgotten —
    /// forgetting it would make its return read as a fresh baseline, which
    /// would silently swallow a genuine failure if it comes back red.
    @discardableResult
    public func observe(resources: [Resource], forPort port: Int, instanceName: String) -> [FailureNotification] {
        resources.reduce(into: [FailureNotification]()) { notifications, resource in
            let key = Key(port: port, resourceName: resource.name)
            let previousHealth = priorHealth[key]
            priorHealth[key] = resource.health

            // No prior record: this observation establishes the baseline.
            // Notifying here would spam every already-broken resource at
            // first connect (see `theFirstObservationOfAnInstanceNotifiesNothing`).
            guard let previousHealth, policy != .off else { return }

            let wasFailing = previousHealth == .error
            let isFailing = resource.health == .error

            if !wasFailing, isFailing {
                notifications.append(FailureNotification(
                    instanceName: instanceName, port: port, resourceName: resource.name, kind: .failed
                ))
            } else if wasFailing, !isFailing, policy == .failuresAndRecoveries {
                notifications.append(FailureNotification(
                    instanceName: instanceName, port: port, resourceName: resource.name, kind: .recovered
                ))
            }
        }
    }
}
