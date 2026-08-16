import Foundation

/// Confirms an instance is actually reachable.
///
/// A `kill -9`'d tilt leaves its kubeconfig entry behind, so presence in the
/// config is necessary but not sufficient.
public protocol LivenessProbing: Sendable {
    func isAlive(_ instance: TiltInstance) async -> Bool
}

/// Test double.
public struct StubLivenessProbe: LivenessProbing {
    private let alive: Bool
    public init(alive: Bool) { self.alive = alive }
    public func isAlive(_ instance: TiltInstance) async -> Bool { alive }
}

/// Probes the `uiresources` endpoint — the one confirmed against tilt v0.36.3.
public struct HTTPLivenessProbe: LivenessProbing {
    private let makeTransport: @Sendable (TiltInstance) -> any DataTransport

    public init(makeTransport: @escaping @Sendable (TiltInstance) -> any DataTransport = { URLSessionTransport(instance: $0) }) {
        self.makeTransport = makeTransport
    }

    public func isAlive(_ instance: TiltInstance) async -> Bool {
        let url = instance.server.appending(path: "/apis/tilt.dev/v1alpha1/uiresources")
        do {
            _ = try await makeTransport(instance).data(from: url)
            return true
        } catch {
            return false
        }
    }
}
