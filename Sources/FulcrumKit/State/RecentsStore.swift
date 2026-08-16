import Foundation
import Observation

/// Where a `RecentsStore` keeps its list between launches.
///
/// A seam, not indirection for its own sake. `RecentsStore` was constructed
/// directly from a `URL`, so every test that merely needed *a* recents store —
/// `DashboardModel`, `MenuDescriptor`, `SidebarItem` and alias tests all take
/// one as a collaborator without caring about persistence — had to invent a
/// UUID-named file in `TMPDIR` and then never clean it up. Measured: 1,635
/// files, 6.7MB, growing ~15 per full-suite run. The same class of damage as
/// the 1,335 `UserDefaults` suite plists already fixed on this branch, and
/// fixed the same way: give the type a storage seam so a test can hand it
/// something with no disk behind it at all, rather than leaving files around
/// and hoping something deletes them.
public protocol RecentsStorage: Sendable {
    /// The persisted bytes, or nil when nothing has been stored yet.
    func read() -> Data?
    func write(_ data: Data)
}

/// The real, on-disk storage: one JSON file, replaced atomically.
///
/// Both operations swallow their errors. This is a cache of convenience,
/// never a source of truth — losing it costs the user nothing but a
/// re-observation, and it must never block launch or fail a write path the
/// user did not ask for.
public struct FileRecentsStorage: RecentsStorage {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    public func write(_ data: Data) {
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Remembers projects Fulcrum has observed, so a stopped project stays visible
/// in the sidebar instead of vanishing.
///
/// Fed by discovery rather than by any launcher: anything Fulcrum ever sees gets
/// recorded, so projects started from a terminal appear here too.
@Observable
@MainActor
public final class RecentsStore {
    /// Caps *unpinned* entries only. Pinned entries are never evicted and do
    /// not count against it, so the list can exceed `limit` when many
    /// projects are pinned — that is intended, not a bug.
    public static let limit = 20

    private let storage: RecentsStorage
    private let now: () -> Date

    public private(set) var projects: [RecentProject] = []

    public init(storage: RecentsStorage, now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.now = now
        self.projects = Self.load(from: storage)
    }

    /// The app's real storage: one JSON file under Application Support.
    public static func defaultStorage() -> RecentsStorage {
        FileRecentsStorage(fileURL: defaultFileURL())
    }

    /// The conventional location, under Application Support.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let directory = base.appending(path: "Fulcrum")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "recents.json")
    }

    public func remember(_ instance: TiltInstance) {
        let id = Self.identifier(forPort: instance.webPort)
        let seenAt = now()
        let previousShape = Self.persistedShape(of: projects)

        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].lastSeen = seenAt
            projects[index].lastPort = instance.webPort
        } else {
            projects.append(RecentProject(
                id: id,
                displayName: ProjectIdentity.fallbackName(forPort: instance.webPort),
                lastPort: instance.webPort,
                lastSeen: seenAt
            ))
        }
        normalise(previousShape: previousShape)
    }

    /// Records the project name and Tiltfile path resolved for the project
    /// last remembered on `port`, so it keeps showing its real name (and
    /// carries a Tiltfile path an alias, "Tilt Down", or "Reveal in Finder"
    /// can key on) once the instance stops — there is no live apiserver left
    /// to re-ask a name from at that point, so this is the only chance to
    /// capture it. A no-op if `port` was never remembered, which can happen
    /// if `InstanceSupervisor` resolves a name for an instance whose
    /// discovery event hasn't reached `remember()` yet.
    public func updateResolvedName(_ name: String, tiltfilePath: String, forPort port: Int) {
        guard let index = projects.firstIndex(where: { $0.id == Self.identifier(forPort: port) }) else { return }
        guard projects[index].displayName != name || projects[index].tiltfilePath != tiltfilePath else { return }
        projects[index].displayName = name
        projects[index].tiltfilePath = tiltfilePath
        save()
    }

    /// Points a remembered project at a different Tiltfile — the user
    /// answering "the file moved, here it is now" — and reports whether it
    /// actually landed.
    ///
    /// KEYED ON `id`, NOT ON PORT, unlike `updateResolvedName` above. That
    /// method is keyed on port because its caller (`InstanceSupervisor`)
    /// knows only the live instance's port; it has no entry in hand. This
    /// one's caller is a sidebar row the user right-clicked, which already
    /// carries the entry's own `id` — the same handle `remove(id:)` and
    /// `setPinned(_:for:)` take. Keying it on port instead would make it
    /// address entries through a value that merely *happens* to be encoded
    /// in the id today, and would be wrong the moment a project is
    /// remembered under anything but its port.
    ///
    /// Returns `false` when `id` names nothing — the caller must surface
    /// that rather than let a Relink that picked a file quietly change
    /// nothing, which is precisely this project's recurring failure mode. It
    /// deliberately does NOT return `false` for "same path as before": the
    /// user asked for the entry to point there, and afterwards it does, so
    /// the request succeeded. Reporting a no-op change as a failure would
    /// pop an error alert at someone who got what they asked for.
    @discardableResult
    public func relink(id: String, toTiltfilePath tiltfilePath: String) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        guard projects[index].tiltfilePath != tiltfilePath else { return true }
        projects[index].tiltfilePath = tiltfilePath
        save()
        return true
    }

    /// Forgets a remembered project, reporting whether there was one to
    /// forget. The `Bool` exists for the same reason `relink`'s does: a
    /// "Remove from Recent" that leaves the row must be impossible, and a
    /// `Void` return gives the caller nothing to detect that with.
    @discardableResult
    public func remove(id: String) -> Bool {
        let countBefore = projects.count
        projects.removeAll { $0.id == id }
        guard projects.count != countBefore else { return false }
        save()
        return true
    }

    public func setPinned(_ pinned: Bool, for id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].isPinned = pinned
        save()
    }

    private static func identifier(forPort port: Int) -> String { "port-\(port)" }

    /// Newest first, then evict unpinned overflow.
    ///
    /// `limit` caps *unpinned* entries. Pinned ones are never evicted and do not
    /// count against it — pinning is the user saying "keep this regardless", and
    /// silently dropping a pinned project would break that promise. The list can
    /// therefore exceed `limit` if many projects are pinned, which is intended.
    ///
    /// `previousShape`, from `remember()` before it touched anything, is compared
    /// against the post-sort/evict shape to decide whether to persist. See
    /// `persistedShape(of:)` for why the comparison excludes `lastSeen`.
    private func normalise(previousShape: [PersistedShape]) {
        projects.sort { $0.lastSeen > $1.lastSeen }

        var unpinnedKept = 0
        projects = projects.filter { project in
            guard !project.isPinned else { return true }
            guard unpinnedKept < Self.limit else { return false }
            unpinnedKept += 1
            return true
        }

        if Self.persistedShape(of: projects) != previousShape {
            save()
        }
    }

    /// Identity, port, and pin state — everything persisted that isn't
    /// `lastSeen` — in list order.
    ///
    /// `remember()` is called on every discovery reconcile (2-3 times per tilt
    /// config rewrite, per the file watcher's deliberately coarse debounce), and
    /// every call bumps `lastSeen`. Comparing full `RecentProject` equality would
    /// therefore see a "change" on essentially every call and never skip a
    /// write — a no-op dirty check. Comparing this reduced shape instead means:
    /// re-affirming an already-front, already-known project (no reorder, no
    /// addition, no eviction) is correctly seen as no persisted-relevant change
    /// and skips the write, while any reorder, addition, eviction, or pin change
    /// still saves the live, already up-to-date state. Ordering therefore never
    /// goes stale relative to disk — only the exact `lastSeen` timestamp of an
    /// unmoved entry can lag briefly, until the next real change flushes it.
    private struct PersistedShape: Equatable {
        let id: String
        let lastPort: Int
        let isPinned: Bool
    }

    private static func persistedShape(of projects: [RecentProject]) -> [PersistedShape] {
        projects.map { PersistedShape(id: $0.id, lastPort: $0.lastPort, isPinned: $0.isPinned) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        storage.write(data)
    }

    /// Missing or corrupt storage yields an empty list. This is a cache of
    /// convenience, never a source of truth — losing it costs the user nothing
    /// but a re-observation, so it must never block launch.
    private static func load(from storage: RecentsStorage) -> [RecentProject] {
        guard let data = storage.read(),
              let decoded = try? JSONDecoder().decode([RecentProject].self, from: data)
        else { return [] }
        return decoded.sorted { $0.lastSeen > $1.lastSeen }
    }
}
