import Foundation
import Observation

/// Instance-level actions — reload the Tiltfile, enable/disable everything on
/// an instance, tear a project's resources down — shared by the dashboard's
/// per-instance toolbar and the sidebar's per-project context menu. Both
/// surfaces call the exact same methods here rather than each shelling out to
/// `TiltActions` on its own, so there is exactly one place that guards
/// against two of these racing each other underneath a developer's live
/// environment, and exactly one place an action's failure gets surfaced.
///
/// Mirrors `ResourceActionCoordinator`'s pattern deliberately — same
/// in-flight `Set` keyed by target, same refuse-rather-than-queue guard, same
/// `lastFailure` alert plumbing — just keyed by instance (or, for `down`,
/// Tiltfile path) instead of resource name. Two coordinators exist rather
/// than one shared one because the two target spaces genuinely differ: a
/// resource action is meaningless without a resource name, an instance
/// action is meaningless without an instance (or, for `down`, a Tiltfile
/// path) — folding both into one type would mean either could be called with
/// the other's kind of key by mistake.
@Observable
@MainActor
public final class InstanceActionCoordinator {
    /// One failed action, surfaced to the UI as an alert.
    public struct Failure: Equatable, Sendable {
        public let target: String
        public let message: String
    }

    private let actions: TiltActions?
    private var inFlight: Set<String> = []

    /// The most recent action failure, or nil once dismissed via
    /// `clearFailure()`.
    public private(set) var lastFailure: Failure?

    /// `actions` is nil when `TiltBinary.locate()` found no tilt install on
    /// this machine. Every action method below becomes a no-op in that case,
    /// same as `ResourceActionCoordinator` — the UI disables its controls
    /// using `isAvailable`, but a no-op here means a control that slips
    /// through fails safe instead of shelling out against a binary that does
    /// not exist.
    public init(actions: TiltActions?) {
        self.actions = actions
    }

    /// Whether tilt was located. Drives whether every instance-level control
    /// is enabled at all.
    public var isAvailable: Bool { actions != nil }

    /// The same fixed explanation `ResourceActionCoordinator` uses — one
    /// shared string so a disabled control reads identically no matter which
    /// coordinator disabled it.
    public static let unavailableReason = ResourceActionCoordinator.unavailableReason

    /// Whether an instance-scoped action (reload, enable all, disable all)
    /// is currently running against `instance`.
    public func isInFlight(on instance: TiltInstance) -> Bool {
        inFlight.contains(Self.key(for: instance))
    }

    /// Whether `tilt down` is currently running for the Tiltfile at `path`.
    /// Kept distinct from `isInFlight(on:)` because `down` is addressed by
    /// path, not by a live instance — a project can be torn down after it
    /// has already stopped.
    public func isTiltDownInFlight(tiltfilePath path: String) -> Bool {
        inFlight.contains(path)
    }

    public func clearFailure() {
        lastFailure = nil
    }

    /// `tilt trigger "(Tiltfile)" --port N` — manually re-runs the
    /// Tiltfile's own build, bypassing its trigger mode. Verified against a
    /// live instance (port 10370) before this button shipped: `tilt get
    /// uiresources` showed a fresh `buildHistory` entry after the call.
    public func reloadTiltfile(on instance: TiltInstance) async {
        await run(Self.key(for: instance)) { try await $0.trigger("(Tiltfile)", on: instance) }
    }

    public func enableAll(on instance: TiltInstance) async {
        await run(Self.key(for: instance)) { try await $0.setEnabledForAll(true, on: instance) }
    }

    public func disableAll(on instance: TiltInstance) async {
        await run(Self.key(for: instance)) { try await $0.setEnabledForAll(false, on: instance) }
    }

    /// Deletes the resources the Tiltfile at `path` defines. The caller (the
    /// toolbar, the context menu) owns confirming this with the user first —
    /// this method does not prompt, it only guards against two `down`s
    /// racing for the same path.
    public func down(tiltfilePath path: String) async {
        await run(path) { try await $0.down(tiltfilePath: path) }
    }

    private static func key(for instance: TiltInstance) -> String { "port-\(instance.webPort)" }

    /// Same shape as `ResourceActionCoordinator.run(_:_:)`: refuses to start
    /// when `key` already has an action in flight rather than queuing behind
    /// it, and clears the flag on every exit path via `defer` so a failure
    /// never leaves a control disabled forever.
    private func run(_ key: String, _ body: (TiltActions) async throws -> Void) async {
        guard let actions else { return }
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            try await body(actions)
        } catch is CancellationError {
            // The task was cancelled out from under it, not a tilt failure —
            // nothing went wrong that the user needs an alert about.
        } catch {
            lastFailure = Failure(target: key, message: tiltActionFailureMessage(for: error))
        }
    }
}

/// Copy for the confirmation a destructive instance-level action needs
/// before it runs — shared by the dashboard toolbar and the sidebar's
/// context menu so the wording (and the fact that a confirmation happens at
/// all) can never drift between the two entry points for the same action.
/// Pure data: presenting it is AppKit's job (`NSAlert`), which belongs in
/// the app target, not here.
public enum InstanceActionConfirmation: Equatable, Sendable {
    case tiltDown(projectName: String)
    case disableAll(projectName: String)

    public var title: String {
        switch self {
        case .tiltDown: "Tilt Down \u{201C}\(projectNameForTitle)\u{201D}?"
        case .disableAll: "Disable All Resources?"
        }
    }

    private var projectNameForTitle: String {
        switch self {
        case let .tiltDown(name): name
        case let .disableAll(name): name
        }
    }

    public var message: String {
        switch self {
        case let .tiltDown(name):
            return "This deletes every resource \"\(name)\" defines — deployments, services, everything tilt built. "
                + "It does not stop a running `tilt up`; that process will keep fighting it. This cannot be undone from Fulcrum."
        case let .disableAll(name):
            return "This disables every resource in \"\(name)\"."
        }
    }

    public var confirmButtonTitle: String {
        switch self {
        case .tiltDown: "Tilt Down"
        case .disableAll: "Disable All"
        }
    }
}
