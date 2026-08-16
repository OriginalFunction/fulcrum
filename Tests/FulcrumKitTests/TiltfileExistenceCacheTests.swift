import Foundation
import Testing
@testable import FulcrumKit

/// Records every existence check: which path, how many, and — the point of
/// the whole exercise — whether it ran on the main thread.
///
/// Counting, not timing. Six timing-shaped tests on this project have already
/// been replaced; "the sidebar rebuilt quickly" is a measurement of the
/// machine, whereas "the filesystem was touched three times for three
/// projects across fifty rebuilds" is a measurement of the code.
private final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var mainThreadCalls = 0
    private var missing: Set<String> = []

    var callCount: Int { lock.withLock { paths.count } }
    var calls: [String] { lock.withLock { paths } }
    /// A `stat` that ran on the main thread is a `stat` that could block the
    /// UI on a stalled network mount — the defect this cache exists to fix.
    var everRanOnMainThread: Bool { lock.withLock { mainThreadCalls > 0 } }

    func setMissing(_ newValue: Set<String>) { lock.withLock { missing = newValue } }

    var probe: TiltfileExistenceCache.Probe {
        { [self] path in
            lock.withLock {
                paths.append(path)
                if Thread.isMainThread { mainThreadCalls += 1 }
                return !missing.contains(path)
            }
        }
    }
}

/// Wrapped in a synchronous function because `Thread.isMainThread` is
/// unavailable directly from an async context.
private func isOnMainThread() -> Bool { Thread.isMainThread }

@MainActor private func makeCache(
    _ log: ProbeLog, ttl: TimeInterval = 5, clock: @escaping () -> Date
) -> TiltfileExistenceCache {
    TiltfileExistenceCache(probe: log.probe, ttl: ttl, now: clock)
}

// MARK: - The count that proves the fix

/// THE performance claim, stated as a count. Fifty sidebar rebuilds across
/// three projects previously meant 150 blocking `stat` calls on the main
/// actor — `SidebarItem.build` ran `FileManager.fileExists` per entry per
/// rebuild, and `DashboardModel.sections` is re-derived on every SwiftUI body
/// evaluation. It must now be three: one per distinct path.
///
/// Mutating `exists(atPath:)` back to `probe(path)` makes this report 150.
@Test @MainActor func fiftyRebuildsOfThreeProjectsTouchTheFilesystemThreeTimes() async {
    let log = ProbeLog()
    let cache = makeCache(log, clock: { Date(timeIntervalSince1970: 0) })
    let paths = ["/a/Tiltfile", "/b/Tiltfile", "/c/Tiltfile"]

    for _ in 0..<50 {
        for path in paths { _ = cache.exists(atPath: path) }
    }
    await cache.settle()
    // One more full sweep, now that every answer has landed, to prove the
    // settled cache is read rather than re-probed.
    for _ in 0..<50 {
        for path in paths { _ = cache.exists(atPath: path) }
    }
    await cache.settle()

    #expect(log.callCount == 3)
    #expect(Set(log.calls) == Set(paths))
}

/// Repeated reads of one path before any answer has come back must coalesce
/// into a single in-flight probe, not queue up one per read.
@Test @MainActor func repeatedReadsBeforeTheFirstAnswerLandsCoalesceIntoOneProbe() async {
    let log = ProbeLog()
    let cache = makeCache(log, clock: { Date(timeIntervalSince1970: 0) })

    for _ in 0..<20 { _ = cache.exists(atPath: "/a/Tiltfile") }
    await cache.settle()

    #expect(log.callCount == 1)
}

/// The other half of the fix: the check is not merely rarer, it is off the
/// main actor entirely. A cache that still probed synchronously — just less
/// often — would satisfy the count above while a single stalled mount still
/// froze the UI.
///
/// Mutating `scheduleRefresh` to call `probe(path)` inline instead of inside
/// `Task.detached` fails this.
@Test @MainActor func theFilesystemIsNeverTouchedOnTheMainThread() async {
    let log = ProbeLog()
    let cache = makeCache(log, clock: { Date(timeIntervalSince1970: 0) })

    #expect(isOnMainThread(), "the caller is on the main actor, which is what makes the check below meaningful")
    _ = cache.exists(atPath: "/a/Tiltfile")
    await cache.settle()

    #expect(log.callCount == 1)
    #expect(log.everRanOnMainThread == false)
}

// MARK: - What an unanswered read says

/// A path nothing has been learned about yet reads as PRESENT, never as
/// missing. The first sidebar render happens before any probe can have
/// returned, and a pessimistic default would paint a red fault indicator on
/// every healthy row for that frame — telling the user their projects are
/// broken because Fulcrum has not looked yet.
///
/// Mutating the fallback to `?? false` fails this.
@Test @MainActor func aPathNotYetProbedReadsAsPresentRatherThanBroken() {
    let log = ProbeLog()
    log.setMissing(["/gone/Tiltfile"])
    let cache = makeCache(log, clock: { Date(timeIntervalSince1970: 0) })

    #expect(cache.exists(atPath: "/gone/Tiltfile"))
}

/// …and once the answer lands, it is the probe's answer, not the optimistic
/// default. Without this, the previous test would be satisfied by a cache
/// that always says `true`.
@Test @MainActor func theProbesAnswerReplacesTheOptimisticDefault() async {
    let log = ProbeLog()
    log.setMissing(["/gone/Tiltfile"])
    let cache = makeCache(log, clock: { Date(timeIntervalSince1970: 0) })

    _ = cache.exists(atPath: "/gone/Tiltfile")
    await cache.settle()

    #expect(cache.exists(atPath: "/gone/Tiltfile") == false)
    #expect(cache.exists(atPath: "/here/Tiltfile")) // never probed: optimistic
}

// MARK: - Invalidation

/// A cached answer must not be permanent: a Tiltfile restored (or deleted)
/// outside Fulcrum has to show up without relaunching the app. Driven by an
/// injected clock, so this asserts the TTL rule rather than waiting on one.
@Test @MainActor func theAnswerIsReprobedOnceTheTTLHasPassed() async {
    let log = ProbeLog()
    var clock = Date(timeIntervalSince1970: 0)
    let cache = makeCache(log, ttl: 5, clock: { clock })

    _ = cache.exists(atPath: "/a/Tiltfile")
    await cache.settle()
    #expect(log.callCount == 1)

    clock = Date(timeIntervalSince1970: 4)
    _ = cache.exists(atPath: "/a/Tiltfile")
    await cache.settle()
    #expect(log.callCount == 1, "still fresh: within the TTL")

    clock = Date(timeIntervalSince1970: 6)
    _ = cache.exists(atPath: "/a/Tiltfile")
    await cache.settle()
    #expect(log.callCount == 2, "stale: past the TTL")
}

/// A Tiltfile that reappears is picked up on the next refresh — the cache
/// tracks the filesystem rather than latching the first answer forever.
@Test @MainActor func aRestoredTiltfileStopsReadingAsMissing() async {
    let log = ProbeLog()
    var clock = Date(timeIntervalSince1970: 0)
    log.setMissing(["/a/Tiltfile"])
    let cache = makeCache(log, ttl: 5, clock: { clock })

    _ = cache.exists(atPath: "/a/Tiltfile")
    await cache.settle()
    #expect(cache.exists(atPath: "/a/Tiltfile") == false)

    log.setMissing([])
    clock = Date(timeIntervalSince1970: 100)
    _ = cache.exists(atPath: "/a/Tiltfile")
    await cache.settle()
    #expect(cache.exists(atPath: "/a/Tiltfile"))
}

/// `invalidate` is what a Relink calls: the newly chosen path has never been
/// probed, and waiting out the TTL to confirm it would leave the row showing
/// its old broken indicator for seconds after the user fixed it.
@Test @MainActor func invalidateForcesAFreshProbeWithoutWaitingForTheTTL() async {
    let log = ProbeLog()
    let cache = makeCache(log, ttl: 3_600, clock: { Date(timeIntervalSince1970: 0) })
    log.setMissing(["/a/Tiltfile"])

    _ = cache.exists(atPath: "/a/Tiltfile")
    await cache.settle()
    #expect(cache.exists(atPath: "/a/Tiltfile") == false)
    #expect(log.callCount == 1)

    log.setMissing([])
    cache.invalidate("/a/Tiltfile")
    await cache.settle()

    #expect(log.callCount == 2)
    #expect(cache.exists(atPath: "/a/Tiltfile"))
}

/// Invalidating one path must not throw away every other answer — that would
/// turn each Relink into a full re-stat of the whole Recent list.
@Test @MainActor func invalidatingOnePathLeavesTheOthersCached() async {
    let log = ProbeLog()
    let cache = makeCache(log, ttl: 3_600, clock: { Date(timeIntervalSince1970: 0) })

    _ = cache.exists(atPath: "/a/Tiltfile")
    _ = cache.exists(atPath: "/b/Tiltfile")
    await cache.settle()
    #expect(log.callCount == 2)

    cache.invalidate("/a/Tiltfile")
    await cache.settle()
    _ = cache.exists(atPath: "/b/Tiltfile")
    await cache.settle()

    #expect(log.callCount == 3)
}
