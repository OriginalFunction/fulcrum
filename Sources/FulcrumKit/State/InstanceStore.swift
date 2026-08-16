import Foundation
import Observation

/// How current this instance's data is. Kept strictly separate from resource
/// health so a transport problem can never be mistaken for a tilt problem.
public enum ConnectionState: Sendable, Equatable {
    case connecting
    case live
    /// Watch dropped; displayed data is last-known and may be stale.
    case degraded
    /// Instance is no longer present. Never set in plan 1 — `InstanceSupervisor`
    /// only ever transitions between `.connecting`, `.live`, and `.degraded`, and
    /// a gone instance is currently just dropped from `AppModel.stores` by `sync`.
    /// Reserved for plan 2's Recents feature, which needs to keep a store around
    /// after its instance disappears in order to display it as a recent entry.
    case gone
}

/// Live state for a single tilt instance.
@Observable
@MainActor
public final class InstanceStore {
    public let instance: TiltInstance
    public private(set) var resources: [Resource] = []
    public private(set) var connection: ConnectionState = .connecting
    public private(set) var lastResourceVersion: String?
    /// The project's real name, resolved from `uisessions`' `tiltfileKey`.
    /// `nil` until resolved — a failed or absent `tiltfileKey` leaves this
    /// nil rather than storing a fallback, so `displayName` stays the single
    /// place that decides what to show instead.
    public private(set) var projectName: String?
    /// The absolute path to this instance's Tiltfile, resolved from the same
    /// `tiltfileKey` `projectName` is derived from. `nil` until resolved, for
    /// the same reason `projectName` is. This is the stable identity
    /// `InstanceAliases` keys on (unlike port, which a restart can change, or
    /// `TiltInstance.InstanceID`, which tilt regenerates every start), and
    /// what "Tilt Down", "Reveal in Finder", and "Copy Tiltfile Path" all
    /// need — none of them can act without it, which is why every one of
    /// them is disabled, with a tooltip explaining why, until this resolves.
    public private(set) var tiltfilePath: String?

    private var byName: [String: Resource] = [:]

    public init(instance: TiltInstance) {
        self.instance = instance
    }

    public var worstHealth: ResourceHealth? {
        resources.map(\.health).max()
    }

    /// The resolved project name, or the `tilt-<port>` fallback when none has
    /// been resolved yet. The one place this instance's display name is
    /// decided — every UI call site (sidebar, menu) reads this rather than
    /// re-deriving the fallback itself.
    public var displayName: String {
        projectName ?? ProjectIdentity.fallbackName(forPort: instance.webPort)
    }

    /// `displayName`, with a user-assigned alias taking precedence when one
    /// exists for this instance's Tiltfile path. Every alias-aware UI call
    /// site (`SidebarItem.build`, `MenuDescriptor.build`) reads through here
    /// for a live instance. The actual alias → fallback decision is made in
    /// exactly one place, `InstanceAliases.displayName(forTiltfilePath:fallback:)`
    /// — `SidebarItem.build`'s Recent-item mapping calls that same method
    /// (with `RecentProject`'s path and resolved/fallback name instead of
    /// this instance's) rather than re-deriving the precedence itself, so a
    /// running project and a stopped one cannot silently disagree about how
    /// an alias applies.
    public func displayName(aliases: InstanceAliases) -> String {
        aliases.displayName(forTiltfilePath: tiltfilePath, fallback: displayName)
    }

    public var failingResources: [Resource] {
        resources.filter { $0.health == .error }
    }

    /// Replaces all contents — used for the initial list and for re-listing
    /// after the server reports the resourceVersion has aged out.
    ///
    /// `list` is external data from tilt's HTTP API; nothing enforces that
    /// `metadata.name` is unique across items. Last-write-wins deliberately
    /// mirrors `apply`'s subscript upsert below, so the two paths cannot
    /// drift apart — a malformed snapshot must degrade, never crash.
    public func applyList(_ list: UIResourceList) {
        byName = Dictionary(
            list.items.map { ($0.metadata.name, Resource(uiResource: $0)) },
            uniquingKeysWith: { _, latest in latest }
        )
        lastResourceVersion = list.metadata.resourceVersion
        rebuild()
    }

    public func apply(_ event: WatchEvent) {
        let resource = Resource(uiResource: event.object)
        switch event.type {
        case .added, .modified:
            byName[resource.name] = resource
        case .deleted:
            byName.removeValue(forKey: resource.name)
        case .bookmark, .error:
            // Defensive, and unreachable in practice: `UIResource.Metadata.name` is
            // non-optional, but neither a real BOOKMARK envelope (resourceVersion
            // only) nor a real ERROR envelope (a Status object) carries a `name`.
            // Decoding either against `UIResource` fails, so `TiltAPIClient.emit`'s
            // `try?` already drops them before an event of this type can reach
            // `apply` at all. This arm exists so the switch stays exhaustive and
            // the intent is documented, not because it is expected to run.
            break
        }
        if let version = event.object.metadata.resourceVersion {
            lastResourceVersion = version
        }
        rebuild()
    }

    public func setConnection(_ state: ConnectionState) {
        connection = state
    }

    /// Sets `projectName` and `tiltfilePath` together — they are resolved
    /// from the same `uisessions` answer and must never disagree about which
    /// project they name. The ONLY way to set either — a `setProjectName(_:)`
    /// that set the name alone existed alongside this and made a store whose
    /// name and path disagreed constructible; nothing in the app ever called
    /// it.
    public func setResolvedTiltfile(path: String, projectName name: String) {
        tiltfilePath = path
        projectName = name
    }

    /// Sorted by tilt's own display order, name as a stable tiebreak.
    private func rebuild() {
        resources = byName.values.sorted {
            $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order
        }
    }
}
