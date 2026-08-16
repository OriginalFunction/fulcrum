import Foundation
import Observation

/// Whether each known Tiltfile is still on disk — answered from memory, never
/// by touching the filesystem on the caller's thread.
///
/// WHY THIS EXISTS. `SidebarItem.build` used to call
/// `FileManager.default.fileExists` for every entry, inline, on the main
/// actor. `DashboardModel.sections` re-derives that build on every read, and
/// a SwiftUI body reads it many times per render — so the cost was a blocking
/// `stat` syscall per project per render, forever. A single Recent entry
/// pointing at a stalled network mount (an unreachable SMB or SSHFS share
/// takes its timeout, not microseconds) would hang the entire UI, not just
/// that row. That was survivable while the result only decided whether a
/// context-menu item was greyed out; now that it drives a visible indicator
/// on every row, the path is hit constantly and it is not.
///
/// THE FIX HAS TWO HALVES, and both are needed:
///
/// 1. `exists(atPath:)` is a dictionary lookup. It never blocks, and it is
///    the only thing the main actor runs. Reading a path that is unknown or
///    stale *schedules* a refresh and returns immediately with whatever is
///    already known.
/// 2. The refresh performs the actual `stat` inside `Task.detached`, so the
///    blocking call happens on a cooperative-pool thread. A cache that merely
///    probed less often would still freeze the UI whenever it did probe.
///
/// Being `@Observable` is what closes the loop without polling: a SwiftUI
/// body that read `exists(atPath:)` is subscribed to `entries`, so when a
/// background answer lands the body re-evaluates and the indicator appears.
///
/// AN UNKNOWN PATH READS AS PRESENT. The optimistic default is deliberate and
/// asymmetric: being briefly wrong about a broken Tiltfile costs a moment's
/// delay before an indicator appears, whereas being briefly wrong the other
/// way paints a red fault marker on every healthy project for the first frame
/// after launch — telling the user their projects are damaged because Fulcrum
/// has not looked yet.
@Observable
@MainActor
public final class TiltfileExistenceCache {
    /// Deliberately a plain `@Sendable` closure rather than a protocol: it is
    /// one question with a `Bool` answer, and it must be callable from
    /// outside the main actor.
    public typealias Probe = @Sendable (String) -> Bool

    private struct Answer {
        let exists: Bool
        let checkedAt: Date
    }

    private let probe: Probe
    /// How long an answer is trusted. Bounded so a Tiltfile restored (or
    /// deleted) outside Fulcrum is noticed without relaunching, and so a
    /// wrong answer cannot latch permanently — but long enough that a render
    /// storm does not become a `stat` storm.
    private let ttl: TimeInterval
    private let now: () -> Date

    private var entries: [String: Answer] = [:]
    /// One refresh per path at a time. Without this, the twenty reads a
    /// single render performs would each schedule their own `stat`.
    ///
    /// Not `@ObservationTracked`-relevant state: it is bookkeeping, and a
    /// view has no reason to re-render because a probe started.
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

    public init(
        probe: @escaping Probe = { FileManager.default.fileExists(atPath: $0) },
        ttl: TimeInterval = 5,
        now: @escaping () -> Date = Date.init
    ) {
        self.probe = probe
        self.ttl = ttl
        self.now = now
    }

    /// Whether `path` exists, as far as this cache currently knows.
    ///
    /// Synchronous, non-blocking, and safe to call from a view body as often
    /// as SwiftUI likes. Schedules a background refresh when the answer is
    /// missing or stale; see the type's doc comment for why an unknown path
    /// answers `true`.
    public func exists(atPath path: String) -> Bool {
        let entry = entries[path]
        if let entry, now().timeIntervalSince(entry.checkedAt) < ttl {
            return entry.exists
        }
        scheduleRefresh(path)
        return entry?.exists ?? true
    }

    /// Drops what is known about `path` and re-probes it now.
    ///
    /// Relink calls this: the newly chosen file has never been probed, and
    /// waiting out the TTL would leave the row wearing its old broken
    /// indicator for seconds after the user fixed it. Scoped to one path —
    /// invalidating everything would turn each Relink into a re-`stat` of the
    /// whole Recent list.
    public func invalidate(_ path: String) {
        entries[path] = nil
        scheduleRefresh(path)
    }

    /// Awaits every refresh currently scheduled.
    ///
    /// Exists so tests can assert on settled state by *ordering* rather than
    /// by waiting a hopeful interval — the same reason `TiltLauncher`'s tests
    /// use a gate file instead of a stopwatch. Nothing in the app calls it;
    /// the app gets its updates through `@Observable` instead.
    public func settle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    /// The `stat` itself, on a cooperative-pool thread. The enclosing `Task`
    /// inherits the main actor (so the dictionary writes are safe without
    /// locking); only the `Task.detached` inside it leaves, which is exactly
    /// the part that can block.
    private func scheduleRefresh(_ path: String) {
        guard inFlight[path] == nil else { return }
        let probe = self.probe
        inFlight[path] = Task { [weak self] in
            let exists = await Task.detached(priority: .utility) { probe(path) }.value
            guard let self else { return }
            self.entries[path] = Answer(exists: exists, checkedAt: self.now())
            self.inFlight[path] = nil
        }
    }
}
