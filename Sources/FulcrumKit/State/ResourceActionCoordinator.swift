import Foundation
import Observation

/// Per-resource in-flight and failure state for row actions (trigger,
/// enable/disable) fired from the resource table.
///
/// Deliberately keyed per resource name rather than one global "an action is
/// running" flag: triggering `ai-redis` must not disable `auth-service`'s
/// button. `inFlight` is a `Set<String>`, so membership is independent per
/// resource — two resources can be in flight at once, and finishing (or
/// failing) one never touches the other's entry.
@Observable
@MainActor
public final class ResourceActionCoordinator {
    /// One failed action, surfaced to the UI as an alert.
    public struct Failure: Equatable, Sendable {
        public let resource: String
        public let message: String
    }

    private let actions: TiltActions?
    private var inFlight: Set<String> = []

    /// The most recent action failure, or nil once dismissed via
    /// `clearFailure()`. Read-only from outside — the UI drives the alert's
    /// dismissal through `clearFailure()` rather than assigning nil directly,
    /// so this stays the one place a failure can be recorded.
    public private(set) var lastFailure: Failure?

    /// `actions` is nil when `TiltBinary.locate()` found no tilt install on
    /// this machine. Every action method below becomes a no-op in that case
    /// rather than shelling out against a binary that doesn't exist — the UI
    /// layer is expected to disable its controls using `isAvailable` as the
    /// primary line of defense, but a no-op here means a control that slips
    /// through fails safe instead of crashing or hanging.
    public init(actions: TiltActions?) {
        self.actions = actions
    }

    /// Whether tilt was located. Drives whether the row's action controls are
    /// enabled at all — see `unavailableReason` for the tooltip to pair with
    /// disabling them.
    public var isAvailable: Bool { actions != nil }

    /// Fixed, user-facing explanation for why every action control is
    /// disabled when `isAvailable` is false. One shared string so every
    /// control's tooltip says the same thing.
    public static let unavailableReason =
        "tilt was not found. Install it, or set FULCRUM_TILT_PATH, then relaunch Fulcrum."

    public func isInFlight(_ resourceName: String) -> Bool {
        inFlight.contains(resourceName)
    }

    public func clearFailure() {
        lastFailure = nil
    }

    public func trigger(_ name: String, on instance: TiltInstance) async {
        await run(name) { try await $0.trigger(name, on: instance) }
    }

    public func setEnabled(_ enabled: Bool, resource: String, on instance: TiltInstance) async {
        await run(resource) { try await $0.setEnabled(enabled, resource: resource, on: instance) }
    }

    /// Marks `resourceName` in flight for the duration of `body`, clearing it
    /// again on every exit path — success, thrown error, or cancellation —
    /// via `defer`. A failed action that left the flag set would leave that
    /// row's button disabled forever, which is worse than not having the
    /// button at all.
    ///
    /// Refuses to start at all when `resourceName` already has an action in
    /// flight, rather than counting concurrent callers and letting a second
    /// one through. `trigger` and `setEnabled` are two separate UI entry
    /// points (the row's button and its context menu) that can both target
    /// the same resource; a reference count would keep the button correctly
    /// disabled while still letting two `tilt` invocations race against the
    /// same resource underneath it, which is the actual hazard on a tool
    /// whose entire job is mutating someone's live dev environment. This
    /// guard makes that structurally impossible: only the call that
    /// performed the `insert` ever performs the matching `remove`.
    private func run(_ resourceName: String, _ body: (TiltActions) async throws -> Void) async {
        guard let actions else { return }
        guard !inFlight.contains(resourceName) else { return }
        inFlight.insert(resourceName)
        defer { inFlight.remove(resourceName) }
        do {
            try await body(actions)
        } catch is CancellationError {
            // Not a tilt failure — the task was cancelled out from under it
            // (e.g. the view disappearing mid-action). Nothing went wrong
            // that the user needs an alert about.
        } catch {
            // `tiltActionFailureMessage(for:)`, not a local copy of the same
            // switch: this and `InstanceActionCoordinator` are two surfaces
            // reporting the same failures, and alert wording that can drift
            // between the row-level and instance-level surfaces is a defect
            // waiting to happen. `CancellationError` never reaches it — the
            // arm above catches that first, so it can never turn into an
            // alert reading the literal text "CancellationError()".
            lastFailure = Failure(resource: resourceName, message: tiltActionFailureMessage(for: error))
        }
    }
}
