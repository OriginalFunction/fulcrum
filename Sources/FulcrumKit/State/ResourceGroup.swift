import Foundation

/// Resources bundled by tilt's group label, in the shape the dashboard
/// renders: one section per group, tilt's own display order preserved
/// within each.
public struct ResourceGroup: Sendable, Equatable {
    /// The group's label, or `nil` for resources tilt did not label at all
    /// (observed only for `(Tiltfile)`).
    public let name: String?
    public let resources: [Resource]
    /// Set only via `collapsed(from:)`, for a collapsed group whose
    /// `resources` has been emptied for display. `nil` means "derive it from
    /// `resources`", which is the normal case.
    private let overrideSummary: ResourceSummary?

    public init(name: String?, resources: [Resource]) {
        self.name = name
        self.resources = resources
        self.overrideSummary = nil
    }

    /// Private: the only place a `resources`/`summary` mismatch can be
    /// constructed is `collapsed(from:)` below, which is correct by
    /// construction because it copies `summary` from a fully-populated group
    /// before dropping its resources. A public initializer taking both as
    /// independent arguments would let any future caller build a group whose
    /// header contradicts its rows — the same "two parts of the app disagree
    /// about reality" bug class the `group(_:)` doc comment below warns about
    /// for `Dictionary(uniqueKeysWithValues:)`.
    private init(name: String?, resources: [Resource], overrideSummary: ResourceSummary?) {
        self.name = name
        self.resources = resources
        self.overrideSummary = overrideSummary
    }

    /// This group's rollup counts, matching tilt's own header.
    public var summary: ResourceSummary { overrideSummary ?? ResourceSummary(resources: resources) }

    /// The collapsed presentation of `group`: same name and summary, but no
    /// resources to render. Used when a group's header must keep reporting
    /// its true rollup counts while its rows are hidden.
    public static func collapsed(from group: ResourceGroup) -> ResourceGroup {
        ResourceGroup(name: group.name, resources: [], overrideSummary: group.summary)
    }

    /// Groups resources by their `group` label, sorting resources within a
    /// group by tilt's own `order` and sorting groups by name with the
    /// ungrouped (`nil`) bucket last.
    ///
    /// Built as a `reduce(into:)` over an explicitly tracked key order
    /// rather than `Dictionary(uniqueKeysWithValues:)` — that initializer
    /// traps the instant two resources share a group, which any group with
    /// more than one member does by definition, and which two same-named
    /// resources from different instances can do even within one group.
    public static func group(_ resources: [Resource]) -> [ResourceGroup] {
        struct Accumulator {
            var order: [String?] = []
            var buckets: [String?: [Resource]] = [:]
        }

        let accumulated = resources.reduce(into: Accumulator()) { acc, resource in
            let key = resource.group
            if acc.buckets[key] == nil {
                acc.order.append(key)
            }
            acc.buckets[key, default: []].append(resource)
        }

        let groups = accumulated.order.map { key in
            ResourceGroup(
                name: key,
                resources: (accumulated.buckets[key] ?? []).sorted { $0.order < $1.order }
            )
        }

        return groups.sorted { lhs, rhs in
            switch (lhs.name, rhs.name) {
            case let (lhsName?, rhsName?): return lhsName < rhsName
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }
}
