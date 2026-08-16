import Foundation

/// Aggregate health counts for a set of resources, matching the shape of
/// tilt's own header (`×2 ⚙2 ✓45/49`).
public struct ResourceSummary: Sendable, Equatable {
    public let error: Int
    public let pending: Int
    public let healthy: Int
    /// Resources the user has disabled — counted separately from `healthy`
    /// rather than folded into it. A disabled resource sitting under a green
    /// "healthy" check (reachable with *Show disabled* on) is exactly the
    /// lie this field exists to stop: it is not being assessed at all, so it
    /// cannot be reported as passing an assessment.
    public let disabled: Int
    public let total: Int

    /// `healthy` is derived as everything that is neither `error`, `pending`,
    /// nor `disabled`, rather than counted only for `.ok`. `ResourceHealth`
    /// has more cases than that trio (`.building`) and every one of them must
    /// still land somewhere — `error + pending + healthy + disabled == total`
    /// holds for any input by construction, not by enumerating every case
    /// tilt happens to send today.
    init(resources: [Resource]) {
        let error = resources.filter { $0.health == .error }.count
        let pending = resources.filter { $0.health == .pending }.count
        let disabled = resources.filter { $0.health == .disabled }.count
        self.error = error
        self.pending = pending
        self.disabled = disabled
        self.total = resources.count
        self.healthy = total - error - pending - disabled
    }
}
