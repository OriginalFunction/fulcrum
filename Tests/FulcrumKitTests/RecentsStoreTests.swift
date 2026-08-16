import Foundation
import Testing
@testable import FulcrumKit

/// Disk-free storage. `RecentsStoreTests` exercises real persistence — save,
/// reload, evict — so it needs storage that genuinely round-trips, but not
/// storage that leaves a file behind. `InMemoryRecentsStorage` round-trips the
/// same encoded bytes `FileRecentsStorage` would write; the one test that
/// must prove the *file* implementation works drives it directly, against a
/// temp directory it removes.
private func storage() -> InMemoryRecentsStorage { InMemoryRecentsStorage() }

private func instance(port: Int, token: String = "t") -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)",
        port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data("pem".utf8),
        token: token
    ))
}

@Test @MainActor func remembersAnObservedInstance() throws {
    let store = RecentsStore(storage: storage())
    store.remember(instance(port: 10350))
    #expect(store.projects.count == 1)
    #expect(store.projects.first?.lastPort == 10350)
}

@Test @MainActor func remembersByPortNotByInstanceIdentity() throws {
    // tilt regenerates (server, token) every start. If recents keyed on
    // InstanceID, restarting a project would add a second entry for it.
    let store = RecentsStore(storage: storage())
    store.remember(instance(port: 10350, token: "first-run"))
    store.remember(instance(port: 10350, token: "second-run"))
    #expect(store.projects.count == 1)
}

@Test @MainActor func mostRecentlySeenSortsFirst() throws {
    var clock = Date(timeIntervalSince1970: 1_000)
    let store = RecentsStore(storage: storage(), now: { clock })

    store.remember(instance(port: 10350))
    clock = Date(timeIntervalSince1970: 2_000)
    store.remember(instance(port: 10360))

    #expect(store.projects.map(\.lastPort) == [10360, 10350])
}

@Test @MainActor func reobservingAProjectMovesItToTheFront() throws {
    var clock = Date(timeIntervalSince1970: 1_000)
    let store = RecentsStore(storage: storage(), now: { clock })

    store.remember(instance(port: 10350))
    clock = Date(timeIntervalSince1970: 2_000)
    store.remember(instance(port: 10360))
    clock = Date(timeIntervalSince1970: 3_000)
    store.remember(instance(port: 10350))

    #expect(store.projects.map(\.lastPort) == [10350, 10360])
}

@Test @MainActor func persistsAcrossInstances() throws {
    let shared = storage()
    let store = RecentsStore(storage: shared)
    store.remember(instance(port: 10350))

    let reloaded = RecentsStore(storage: shared)
    #expect(reloaded.projects.map(\.lastPort) == [10350])
}

@Test @MainActor func evictsOldestBeyondTheLimit() throws {
    var clock = Date(timeIntervalSince1970: 0)
    let store = RecentsStore(storage: storage(), now: { clock })

    for offset in 0..<(RecentsStore.limit + 5) {
        clock = Date(timeIntervalSince1970: TimeInterval(offset))
        store.remember(instance(port: 10_000 + offset))
    }

    #expect(store.projects.count == RecentsStore.limit)
    // The five oldest are gone; the newest survives.
    #expect(store.projects.first?.lastPort == 10_000 + RecentsStore.limit + 4)
    #expect(!store.projects.contains { $0.lastPort == 10_000 })
}

@Test @MainActor func pinnedProjectsSurviveEviction() throws {
    var clock = Date(timeIntervalSince1970: 0)
    let store = RecentsStore(storage: storage(), now: { clock })

    store.remember(instance(port: 9_999))
    let pinnedID = try #require(store.projects.first?.id)
    store.setPinned(true, for: pinnedID)

    for offset in 0..<(RecentsStore.limit + 5) {
        clock = Date(timeIntervalSince1970: TimeInterval(offset + 1))
        store.remember(instance(port: 10_000 + offset))
    }

    #expect(store.projects.contains { $0.lastPort == 9_999 })
}

@Test @MainActor func removeDropsAProject() throws {
    let store = RecentsStore(storage: storage())
    store.remember(instance(port: 10350))
    let id = try #require(store.projects.first?.id)

    store.remove(id: id)
    #expect(store.projects.isEmpty)
}

@Test @MainActor func limitCapsOnlyUnpinnedEntriesNotPinnedOnes() throws {
    // More than `limit` pinned projects must all survive; the cap only
    // constrains the unpinned pool.
    var clock = Date(timeIntervalSince1970: 0)
    let store = RecentsStore(storage: storage(), now: { clock })

    var pinnedIDs: [String] = []
    for offset in 0..<(RecentsStore.limit + 2) {
        clock = Date(timeIntervalSince1970: TimeInterval(offset))
        store.remember(instance(port: 9_000 + offset))
        let id = try #require(store.projects.first?.id)
        store.setPinned(true, for: id)
        pinnedIDs.append(id)
    }

    for offset in 0..<(RecentsStore.limit + 5) {
        clock = Date(timeIntervalSince1970: TimeInterval(offset + 1_000))
        store.remember(instance(port: 10_000 + offset))
    }

    let pinned = store.projects.filter(\.isPinned)
    let unpinned = store.projects.filter { !$0.isPinned }

    #expect(pinned.count == RecentsStore.limit + 2)
    #expect(unpinned.count == RecentsStore.limit)
    #expect(Set(pinned.map(\.id)) == Set(pinnedIDs))
}

@Test @MainActor func removePersistsAcrossInstances() throws {
    let shared = storage()
    let store = RecentsStore(storage: shared)
    store.remember(instance(port: 10350))
    let id = try #require(store.projects.first?.id)

    store.remove(id: id)

    let reloaded = RecentsStore(storage: shared)
    #expect(reloaded.projects.isEmpty)
}

@Test @MainActor func setPinnedPersistsAcrossInstances() throws {
    let shared = storage()
    let store = RecentsStore(storage: shared)
    store.remember(instance(port: 10350))
    let id = try #require(store.projects.first?.id)

    store.setPinned(true, for: id)

    let reloaded = RecentsStore(storage: shared)
    #expect(reloaded.projects.first?.isPinned == true)
}

@Test @MainActor func corruptStoredDataYieldsAnEmptyStoreRatherThanCrashing() throws {
    let store = RecentsStore(storage: InMemoryRecentsStorage(seeded: Data("{ not json".utf8)))
    #expect(store.projects.isEmpty)
}

@Test @MainActor func emptyStorageYieldsAnEmptyStore() throws {
    #expect(RecentsStore(storage: storage()).projects.isEmpty)
}

/// The one test that drives `FileRecentsStorage` itself, so the
/// implementation the app actually ships is not left uncovered by every other
/// test here using in-memory storage. It writes into a directory it creates
/// and removes — a whole directory rather than a loose file, so the teardown
/// cannot leave a stray behind, and `FileManager.removeItem` is synchronous
/// and complete when it returns, unlike the `cfprefsd`-owned plists that made
/// "delete it afterwards" unworkable for `UserDefaults`.
@Test @MainActor func fileStorageRoundTripsThroughARealFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "fulcrum-recents-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appending(path: "recents.json")
    let store = RecentsStore(storage: FileRecentsStorage(fileURL: file))
    store.remember(instance(port: 10350))
    #expect(FileManager.default.fileExists(atPath: file.path))

    let reloaded = RecentsStore(storage: FileRecentsStorage(fileURL: file))
    #expect(reloaded.projects.map(\.lastPort) == [10350])

    // A file that isn't there yet, and one full of garbage, both degrade to
    // an empty list rather than failing launch.
    let missing = RecentsStore(storage: FileRecentsStorage(fileURL: directory.appending(path: "absent.json")))
    #expect(missing.projects.isEmpty)

    try Data("{ not json".utf8).write(to: file)
    #expect(RecentsStore(storage: FileRecentsStorage(fileURL: file)).projects.isEmpty)
}

// MARK: - Relink (Feature 1)

@Test @MainActor func relinkingPointsTheEntryAtItsNewTiltfile() throws {
    let store = RecentsStore(storage: storage())
    store.remember(instance(port: 10361))
    store.updateResolvedName("detachtest", tiltfilePath: "/private/tmp/detachtest/Tiltfile", forPort: 10361)

    #expect(store.relink(id: "port-10361", toTiltfilePath: "/Users/r/Projects/detachtest/Tiltfile"))
    #expect(store.projects.first?.tiltfilePath == "/Users/r/Projects/detachtest/Tiltfile")
}

/// An entry that never had a path is exactly the one Relink is the fix for.
@Test @MainActor func relinkingWorksForAnEntryThatNeverHadAPath() throws {
    let store = RecentsStore(storage: storage())
    store.remember(instance(port: 10395))
    #expect(store.projects.first?.tiltfilePath == nil)

    #expect(store.relink(id: "port-10395", toTiltfilePath: "/Users/r/p/Tiltfile"))
    #expect(store.projects.first?.tiltfilePath == "/Users/r/p/Tiltfile")
}

/// The silent-no-op guard. A Relink naming an entry that is no longer there
/// must REPORT that, so the caller can say so rather than let the user watch
/// a file picker accomplish nothing.
///
/// Mutating `relink` to `@discardableResult ... { return true }` on the
/// missing-entry path fails this.
@Test @MainActor func relinkingAnEntryThatIsNotThereReportsFailureAndChangesNothing() throws {
    let store = RecentsStore(storage: storage())
    store.remember(instance(port: 10360))
    store.updateResolvedName("p", tiltfilePath: "/a/Tiltfile", forPort: 10360)

    #expect(store.relink(id: "port-99999", toTiltfilePath: "/b/Tiltfile") == false)
    #expect(store.projects.count == 1)
    #expect(store.projects.first?.tiltfilePath == "/a/Tiltfile")
}

/// Relinking to the path already recorded is a success, not a failure: the
/// user asked for the entry to point there and afterwards it does. Reporting
/// it as failure would pop an error alert at someone who got what they asked
/// for.
@Test @MainActor func relinkingToTheSamePathSucceedsWithoutReportingFailure() throws {
    let store = RecentsStore(storage: storage())
    store.remember(instance(port: 10360))
    store.updateResolvedName("p", tiltfilePath: "/a/Tiltfile", forPort: 10360)

    #expect(store.relink(id: "port-10360", toTiltfilePath: "/a/Tiltfile"))
    #expect(store.projects.first?.tiltfilePath == "/a/Tiltfile")
}

/// A relink that only lives in memory is lost on the next launch, and the row
/// comes back broken.
@Test @MainActor func aRelinkSurvivesAReload() throws {
    let shared = storage()
    let store = RecentsStore(storage: shared)
    store.remember(instance(port: 10361))
    store.updateResolvedName("detachtest", tiltfilePath: "/gone/Tiltfile", forPort: 10361)
    #expect(store.relink(id: "port-10361", toTiltfilePath: "/found/Tiltfile"))

    let reloaded = RecentsStore(storage: shared)
    #expect(reloaded.projects.first?.tiltfilePath == "/found/Tiltfile")
}

/// Relinking one entry must not disturb another's path — the id is the key,
/// and an implementation keyed on something coarser (or ignoring the key)
/// would rewrite the wrong row.
@Test @MainActor func relinkingOneEntryLeavesTheOthersAlone() throws {
    var clock = Date(timeIntervalSince1970: 1_000)
    let store = RecentsStore(storage: storage(), now: { clock })
    store.remember(instance(port: 10350))
    store.updateResolvedName("a", tiltfilePath: "/a/Tiltfile", forPort: 10350)
    clock = Date(timeIntervalSince1970: 2_000)
    store.remember(instance(port: 10360))
    store.updateResolvedName("b", tiltfilePath: "/b/Tiltfile", forPort: 10360)

    #expect(store.relink(id: "port-10350", toTiltfilePath: "/moved/Tiltfile"))
    #expect(store.projects.first { $0.id == "port-10350" }?.tiltfilePath == "/moved/Tiltfile")
    #expect(store.projects.first { $0.id == "port-10360" }?.tiltfilePath == "/b/Tiltfile")
}

// MARK: - Remove reports what it did

/// The other half of the silent-no-op guard: a "Remove from Recent" that
/// leaves the row must be detectable by its caller.
///
/// Mutating `remove(id:)` to `return true` unconditionally fails this.
@Test @MainActor func removingReportsWhetherThereWasAnythingToRemove() throws {
    let store = RecentsStore(storage: storage())
    store.remember(instance(port: 10360))

    #expect(store.remove(id: "port-10360"))
    #expect(store.projects.isEmpty)
    #expect(store.remove(id: "port-10360") == false, "already gone")
    #expect(store.remove(id: "port-99999") == false, "never existed")
}
