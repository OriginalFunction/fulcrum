import Foundation

/// Picks the port a newly launched `tilt up` should listen on.
///
/// Tilt does **not** fall back when its port is taken: it refuses to start at
/// all, printing "Tilt cannot start because you already have another process
/// on port 10350" and exiting immediately. So a developer who already has one
/// instance running cannot start a second without being handed a different
/// port, and picking one is Fulcrum's job.
///
/// The check is deliberately **advisory**. A port that probes free here can be
/// claimed by something else in the moment between this call and tilt binding
/// it. That race is not papered over: `TiltLauncher` surfaces tilt's own
/// refusal verbatim when it happens, which is both truthful and the only
/// account that stays correct as tilt's own behaviour changes.
public enum PortAllocator {
    /// Tilt's own default. The first port a new instance is offered, so a
    /// developer with nothing else running gets the port they expect.
    public static let defaultTiltPort = 10350

    /// Ports Fulcrum is willing to hand to `tilt --port`. The floor excludes
    /// privileged ports, which need root to bind — offering one would produce a
    /// launch failure the user has no way to act on. The ceiling is the last
    /// port that exists.
    public static let validPorts = 1024...65535

    /// How many ports a single search will probe before giving up. Bounded so
    /// a pathological machine cannot turn "open a Tiltfile" into a scan of the
    /// whole port space. A hundred consecutive busy ports means something is
    /// wrong that a wider search would not fix.
    public static let searchLimit = 100

    /// The first port at or after `start` that `isAvailable` accepts, or `nil`
    /// if the bounded search finds none.
    ///
    /// - Parameters:
    ///   - start: where to begin. Clamped up into `validPorts`; a start above
    ///     the range yields `nil` without probing anything.
    ///   - limit: the maximum number of probes.
    ///   - isAvailable: injected so the search can be tested without binding
    ///     real sockets. Defaults to `isPortFree(_:)`.
    public static func freePort(
        startingAt start: Int = defaultTiltPort,
        limit: Int = searchLimit,
        isAvailable: (Int) -> Bool = { isPortFree($0) }
    ) -> Int? {
        guard limit > 0, start <= validPorts.upperBound else { return nil }

        var candidate = max(start, validPorts.lowerBound)
        var probes = 0
        while candidate <= validPorts.upperBound, probes < limit {
            probes += 1
            if isAvailable(candidate) { return candidate }
            candidate += 1
        }
        return nil
    }

    /// Whether a TCP port on 127.0.0.1 can be bound right now.
    ///
    /// Binds and closes immediately rather than listening: the goal is to
    /// learn whether tilt would collide, not to hold the port — holding it
    /// would guarantee the collision this exists to avoid. `SO_REUSEADDR` is
    /// deliberately *not* set, so a port still in `TIME_WAIT` reads as busy and
    /// the search moves on; being conservative costs one port number, while
    /// being optimistic costs a failed launch.
    public static func isPortFree(_ port: Int) -> Bool {
        guard validPorts.contains(port) else { return false }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}
