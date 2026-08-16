import Foundation

/// User-assigned nicknames for tilt projects, keyed by the project's
/// Tiltfile path — the one identifier that is stable across a restart.
///
/// Port cannot be the key: a restart may pick a different one. Nor can
/// `TiltInstance.InstanceID` (`server`, `token`): tilt regenerates both on
/// every start, which is exactly why `InstanceID` uses them in the first
/// place — it deliberately treats a restart as a new instance. The Tiltfile
/// path is the only thing here that means "the same project" across a
/// restart, so it is the only thing an alias can survive one keyed on.
///
/// A pure value type — like `ResourceFilter`, which `DashboardModel` holds as
/// a plain stored `var` — so it can be constructed, mutated, and asserted on
/// in tests without any UserDefaults or other I/O in the loop. `AppModel`
/// holds the live instance of this and persists it on every mutation via
/// `load(from:)`/`save(to:)`, the same UserDefaults-backed mechanism
/// `SettingsStore` uses.
public struct InstanceAliases: Equatable, Sendable {
    private var byPath: [String: String]

    public init(byPath: [String: String] = [:]) {
        self.byPath = byPath
    }

    public func alias(forTiltfilePath path: String) -> String? {
        byPath[path]
    }

    /// Empty (or all-whitespace) input clears the alias rather than storing
    /// a blank one — a display site must never render an empty name, and
    /// this is the one place that guarantee holds for a value that could
    /// otherwise be set to `""` directly from a text field.
    public mutating func setAlias(_ alias: String?, forTiltfilePath path: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            byPath[path] = trimmed
        } else {
            byPath.removeValue(forKey: path)
        }
    }

    /// The ONE place alias → fallback precedence is decided, for anything
    /// identified by an optional Tiltfile path — a live `InstanceStore`
    /// (`InstanceStore.displayName(aliases:)`) and a stopped `RecentProject`
    /// (`SidebarItem.build`) both delegate to this rather than each
    /// re-deriving `alias ?? fallback` on their own, so the two cannot
    /// silently drift apart. `path` is optional because the caller may not
    /// have one yet (an unresolved Tiltfile key); `fallback` is whatever
    /// that caller already knows to show in that case — a resolved project
    /// name, or the `tilt-<port>` name, already decided upstream.
    public func displayName(forTiltfilePath path: String?, fallback: String) -> String {
        if let path, let alias = alias(forTiltfilePath: path) { return alias }
        return fallback
    }

    private static let defaultsKey = "instanceAliasesByTiltfilePath"

    /// Persisted through the same mechanism `SettingsStore` uses: `UserDefaults`,
    /// under one key, as a `[String: String]` — a directly representable
    /// property-list type, so no separate encoder or file is needed.
    public static func load(from defaults: UserDefaults = .standard) -> InstanceAliases {
        InstanceAliases(byPath: defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(byPath, forKey: Self.defaultsKey)
    }
}
