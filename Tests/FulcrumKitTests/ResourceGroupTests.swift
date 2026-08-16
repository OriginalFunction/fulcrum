import Foundation
import Testing
@testable import FulcrumKit

/// Builds a `Resource` stating only the field the test exercises. Defaults
/// mirror an unremarkable, healthy, ungrouped resource with tilt order 0.
///
/// Routed through `UIResource` (rather than a hypothetical memberwise
/// `Resource` initializer, which does not exist) so the health mapping stays
/// anchored to tilt's real `updateStatus`/`disableStatus` vocabulary instead
/// of drifting from it.
///
/// Not `private`: shared with other files in this test target (e.g.
/// `ResourceFilterTests`) rather than each writing its own copy.
/// `disabled` is a separate parameter from `health` because real tilt
/// resources report both an update status AND a disable status — passing
/// `disabled: true` mirrors `ResourceHealth.derive`'s "disabled wins
/// outright" rule regardless of what `health` was asked for.
func res(
    _ name: String,
    group: String? = nil,
    order: Int = 0,
    health: ResourceHealth = .ok,
    disabled: Bool = false
) -> Resource {
    let updateStatus: String? = {
        switch health {
        case .ok: "ok"
        case .error: "error"
        case .pending: "pending"
        case .building: "in_progress"
        case .disabled: nil
        }
    }()
    return Resource(uiResource: UIResource(
        metadata: .init(name: name, resourceVersion: "1", labels: group.map { [$0: $0] }),
        status: .init(
            updateStatus: updateStatus,
            runtimeStatus: nil,
            disableStatus: (disabled || health == .disabled) ? .init(state: "Disabled") : nil,
            buildHistory: nil,
            pendingBuildSince: nil,
            order: order,
            specs: nil,
            waiting: nil,
            endpointLinks: nil
        )
    ))
}

@Test func resourcesAreGroupedByLabelPreservingTiltOrder() {
    let groups = ResourceGroup.group([
        res("ai-redis", group: "ai", order: 2),
        res("auth-redis", group: "auth", order: 3),
        res("ai-api", group: "ai", order: 1),
    ])
    #expect(groups.map(\.name) == ["ai", "auth"])
    #expect(groups[0].resources.map(\.name) == ["ai-api", "ai-redis"])
}

@Test func ungroupedResourcesSortLastUnderNoName() {
    let groups = ResourceGroup.group([res("(Tiltfile)", group: nil), res("ai-redis", group: "ai")])
    #expect(groups.map(\.name) == ["ai", nil])
}

@Test func summaryCountsMatchTiltsOwnHeader() {
    // The counts tilt's own header showed for the 49-resource project this was
    // measured against: 49 resources, 2 errored, 2 pending, 45 healthy.
    let group = ResourceGroup(name: "ai", resources: [
        res("a", health: .error), res("b", health: .error),
        res("c", health: .pending), res("d", health: .pending),
    ] + (0..<45).map { res("ok\($0)", health: .ok) })
    #expect(group.summary.error == 2)
    #expect(group.summary.pending == 2)
    #expect(group.summary.healthy == 45)
    #expect(group.summary.disabled == 0)
    #expect(group.summary.total == 49)
}

/// The bug this guards: a disabled resource folded into `healthy` reads as
/// passing an assessment it was never subjected to. `disabled` must be its
/// own bucket, not a subset of `healthy` — reusing `summaryCountsMatchTiltsOwnHeader`'s
/// shape but adding disabled resources whose count must show up nowhere
/// else.
@Test func disabledResourcesAreCountedSeparatelyFromHealthy() {
    let group = ResourceGroup(name: "ai", resources: [
        res("a", health: .ok), res("b", health: .ok),
        res("c", health: .disabled), res("d", health: .disabled), res("e", health: .disabled),
    ])
    #expect(group.summary.healthy == 2)
    #expect(group.summary.disabled == 3)
    #expect(group.summary.error == 0)
    #expect(group.summary.pending == 0)
    #expect(group.summary.total == 5)
}

@Test func duplicateResourceNamesDoNotCollapse() {
    // tilt emits per-instance names; two instances can both have "broken".
    let groups = ResourceGroup.group([res("broken", group: "a"), res("broken", group: "a")])
    #expect(groups[0].resources.count == 2)
}

/// `collapsed(from:)` is the only way to produce a `ResourceGroup` whose
/// `resources` and `summary` don't structurally agree — no public
/// initializer takes both as independent arguments, so this is the one
/// path that must be proven correct: it must copy the source group's real
/// counts, not recompute them from the now-empty `resources`.
@Test func collapsedPreservesTheOriginalGroupsSummaryButEmptiesItsResources() {
    let group = ResourceGroup(name: "ai", resources: [
        res("a", health: .error), res("b", health: .ok), res("c", health: .pending),
    ])
    let collapsed = ResourceGroup.collapsed(from: group)
    #expect(collapsed.name == "ai")
    #expect(collapsed.resources.isEmpty)
    #expect(collapsed.summary == group.summary)
    #expect(collapsed.summary.total == 3)
}

/// Every `ResourceHealth` case must land in exactly one of the four buckets
/// — none may vanish, and none may double-count. Exercising every case (not
/// just the three tilt's own header names, and not just the ones a naive
/// summary happens to have been written against) is what would catch a
/// summary that silently drops an unrecognised state, or folds `.disabled`
/// into `.healthy` the way this project's summary used to.
@Test func errorPendingHealthyAndDisabledSumToTotalAcrossEveryHealthCase() {
    let resources = ResourceHealth.allCases.flatMap { health in
        (0..<3).map { i in res("\(health)-\(i)", health: health) }
    }
    let summary = ResourceGroup(name: "mixed", resources: resources).summary

    #expect(summary.total == resources.count)
    #expect(summary.error + summary.pending + summary.healthy + summary.disabled == summary.total)
    #expect(summary.error == 3)
    #expect(summary.pending == 3)
    #expect(summary.disabled == 3)
    // .ok and .building: the two cases that are neither error, pending, nor disabled.
    #expect(summary.healthy == 6)
}
