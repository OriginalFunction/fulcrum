import Foundation
import Observation

/// Aggregate state across every discovered instance. The single source both
/// surfaces render from.
@Observable
@MainActor
public final class AppModel {
    public let settings: SettingsStore
    public private(set) var stores: [InstanceStore] = []
    private let aliasesDefaults: UserDefaults

    /// Whether `tilt` could be located on this machine — mirrors
    /// `TiltBinary.locate() != nil`, the same search
    /// `ResourceActionCoordinator`/`TiltLauncher` use for the real thing.
    /// Set once, at launch, by `AppDelegate` off the same lookup that builds
    /// `TiltActions`, rather than this running a second search of its own.
    /// Defaults to `true` so a model nobody has told otherwise (every
    /// existing test, mainly) never wrongly claims tilt is missing.
    ///
    /// `MenuDescriptor` reads this to tell "tilt not installed" apart from
    /// "tilt installed, nothing running" — two states with completely
    /// different remedies that must never collapse into one message.
    public var tiltInstalled: Bool = true

    /// User-assigned project nicknames, keyed by Tiltfile path. The single
    /// place they live — `InstanceStore.displayName(aliases:)` and
    /// `SidebarItem.build`'s Recent-item mapping both read this rather than
    /// each holding their own copy, so a rename is visible everywhere at
    /// once. Persists on every mutation via `InstanceAliases.save(to:)`, the
    /// same `didSet`-triggered-write pattern `SettingsStore` uses for its
    /// own properties.
    public var aliases: InstanceAliases {
        didSet { aliases.save(to: aliasesDefaults) }
    }

    public init(settings: SettingsStore, aliasesDefaults: UserDefaults = .standard) {
        self.settings = settings
        self.aliasesDefaults = aliasesDefaults
        self.aliases = InstanceAliases.load(from: aliasesDefaults)
    }

    /// Reconciles discovered instances against existing stores.
    ///
    /// Matching is by `InstanceID` — `(server, token)` — so an instance that
    /// merely restarted on the same port correctly gets a fresh store rather
    /// than inheriting stale resources.
    ///
    /// Both sides must tolerate a repeated id. tilt writes its kubeconfig
    /// non-atomically, so a mid-write read can surface a stale context
    /// alongside a fresh one that resolves to the same `(server, token)`.
    /// Trapping here would turn a one-tick glitch into a crash on the next
    /// tick, since `stores` feeds this same dictionary on the following call.
    public func sync(with discovered: [TiltInstance]) {
        var existing = Dictionary(
            stores.map { ($0.instance.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<TiltInstance.InstanceID>()
        stores = discovered.compactMap { instance in
            guard seen.insert(instance.id).inserted else { return nil }
            if let store = existing.removeValue(forKey: instance.id) { return store }
            return InstanceStore(instance: instance)
        }
    }

    public var worstHealth: ResourceHealth? {
        stores.compactMap(\.worstHealth).max()
    }

    public var allFailingResources: [(instance: InstanceStore, resource: Resource)] {
        stores.flatMap { store in
            store.failingResources.map { (instance: store, resource: $0) }
        }
    }

    private var isBuilding: Bool {
        stores.contains { $0.worstHealth == .building }
    }

    private var failingInstanceCount: Int {
        stores.filter { !$0.failingResources.isEmpty }.count
    }

    private var totalResourceCount: Int {
        stores.reduce(0) { $0 + $1.resources.count }
    }

    /// The disabled first line of the menu.
    public var statusLine: String {
        guard !stores.isEmpty else { return "No tilt instances running" }
        let failing = failingInstanceCount
        guard failing > 0 else {
            return stores.count == 1
                ? "Tilt is running — 1 instance"
                : "Tilt is running — \(stores.count) instances"
        }
        let noun = stores.count == 1 ? "project has" : "projects have"
        return "\(failing) of \(stores.count) \(noun) errors"
    }

    public var iconState: MenuBarIconState {
        guard !stores.isEmpty else {
            return MenuBarIconState(assetName: MenuBarAsset.idle,
                                    badge: nil,
                                    isAnimating: false,
                                    accessibilityLabel: "Fulcrum — no tilt instances running")
        }

        switch settings.iconMode {
        case .worstStateHealth:
            return healthIcon(badge: nil)
        case .healthWithCounts:
            let failing = allFailingResources.count
            let badge = failing > 0 ? "\(failing)/\(totalResourceCount)" : nil
            return healthIcon(badge: badge)
        case .buildActivity:
            return MenuBarIconState(
                assetName: isBuilding ? MenuBarAsset.rocking : MenuBarAsset.level,
                badge: nil,
                isAnimating: isBuilding,
                accessibilityLabel: isBuilding ? "Fulcrum — building" : "Fulcrum — idle"
            )
        case .instanceCount:
            return MenuBarIconState(
                assetName: MenuBarAsset.level,
                badge: "\(stores.count)",
                isAnimating: false,
                accessibilityLabel: "Fulcrum — \(stores.count) instances"
            )
        }
    }

    private func healthIcon(badge: String?) -> MenuBarIconState {
        switch worstHealth {
        case .error:
            MenuBarIconState(assetName: MenuBarAsset.offPlumb, badge: badge,
                             isAnimating: false, accessibilityLabel: "Fulcrum — errors")
        case .building:
            MenuBarIconState(assetName: MenuBarAsset.rocking, badge: badge,
                             isAnimating: true, accessibilityLabel: "Fulcrum — building")
        case .pending:
            MenuBarIconState(assetName: MenuBarAsset.unsettled, badge: badge,
                             isAnimating: false, accessibilityLabel: "Fulcrum — pending")
        case nil:
            // `worstHealth` is nil in exactly two states: a store just discovered
            // whose first `list()` hasn't returned yet, and one whose `list()`
            // keeps failing. Neither is "healthy" — an unassessed instance must
            // not read the same as an all-clear one, so this gets the same
            // not-yet-settled mark as `.pending` rather than falling into the
            // healthy default below.
            MenuBarIconState(assetName: MenuBarAsset.unsettled, badge: badge,
                             isAnimating: false, accessibilityLabel: "Fulcrum — not yet connected")
        default:
            MenuBarIconState(assetName: MenuBarAsset.level, badge: badge,
                             isAnimating: false, accessibilityLabel: "Fulcrum — healthy")
        }
    }
}
