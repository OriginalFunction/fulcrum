import Foundation

/// The dashboard's filter-bar state: name search, disabled-resource
/// visibility, and alert-priority ordering.
public struct ResourceFilter: Sendable, Equatable {
    /// Matched against a resource's name only (not its group) — tilt's own
    /// filter box is name-only, and matching more than the user typed is
    /// worse than matching less.
    public var query: String
    /// When true, resources whose health is `.error` are moved to the top of
    /// the list, ahead of everything else, without otherwise reordering
    /// anything.
    public var alertsOnTop: Bool
    /// When false (the default), disabled resources are hidden entirely.
    public var showDisabled: Bool

    public init(query: String = "", alertsOnTop: Bool = false, showDisabled: Bool = false) {
        self.query = query
        self.alertsOnTop = alertsOnTop
        self.showDisabled = showDisabled
    }

    /// Applies the name search, then disabled-visibility, then alerts-on-top
    /// ordering.
    public func apply(to resources: [Resource]) -> [Resource] {
        var result = matchingQuery(resources)

        if !showDisabled {
            result = result.filter { !$0.isDisabled }
        }

        if alertsOnTop {
            result = Self.stablePartitionAlertsOnTop(result)
        }

        return result
    }

    /// Just the name-search step of `apply(to:)`, exposed separately so an
    /// empty table can say *which* hider emptied it — "nothing matches your
    /// search" and "everything left is disabled" need different words, and
    /// telling them apart means asking what survives the query alone. Split
    /// out rather than reimplemented at the call site: two copies of this
    /// matching rule would be two chances to disagree about what "matches".
    public func matchingQuery(_ resources: [Resource]) -> [Resource] {
        guard !query.isEmpty else { return resources }
        // `lowercased()` rather than `localizedCaseInsensitiveContains` or
        // `localizedLowercase`: this project avoids locale-dependent
        // comparisons for machine-generated names (see the group-name
        // sort in ResourceGroup), and locale-tailored casing (e.g. the
        // Turkish "I") could make a plain ASCII query silently stop
        // matching a resource it matched a moment ago.
        let needle = query.lowercased()
        return resources.filter { $0.name.lowercased().contains(needle) }
    }

    /// Lifts `.error` resources to the front, preserving every other
    /// resource's relative order, and preserving the errors' relative order
    /// among themselves.
    ///
    /// This is deliberately NOT `resources.sorted(by:)`. Swift's `sorted`
    /// is explicitly documented as not guaranteed stable, and tilt pushes a
    /// fresh snapshot every few seconds — an unstable sort would make
    /// same-band rows visibly swap places under the user's cursor on every
    /// update. Zipping in each element's original index and using it as an
    /// explicit tiebreak makes the comparator a strict total order (no two
    /// elements ever compare equal), so the result is stable regardless of
    /// whatever algorithm `sorted` happens to use.
    private static func stablePartitionAlertsOnTop(_ resources: [Resource]) -> [Resource] {
        resources.enumerated()
            .sorted { lhs, rhs in
                let lhsIsAlert = lhs.element.health == .error
                let rhsIsAlert = rhs.element.health == .error
                if lhsIsAlert != rhsIsAlert { return lhsIsAlert }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
