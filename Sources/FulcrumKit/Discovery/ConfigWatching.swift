import Foundation

/// Supplies kubeconfig contents and signals when they change.
public protocol ConfigWatching: Sendable {
    var changes: AsyncStream<Void> { get }
    func read() throws -> String
}

/// Test double — `emit` replaces the contents and fires a change.
public final class ManualConfigWatcher: ConfigWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: String
    private let continuation: AsyncStream<Void>.Continuation
    public let changes: AsyncStream<Void>

    public init(initial: String) {
        self.contents = initial
        (self.changes, self.continuation) = AsyncStream<Void>.makeStream()
    }

    public func read() throws -> String {
        lock.withLock { contents }
    }

    public func emit(_ yaml: String) {
        lock.withLock { contents = yaml }
        continuation.yield(())
    }
}

/// Watches `~/.tilt-dev/config` for changes.
///
/// Watches the *file* itself, not its containing directory. Measured against
/// a real `tilt up`: tilt rewrites the config **in place** — same inode
/// before and after, `mtime` updated — and never touches the directory's own
/// `mtime`. A directory watch therefore never sees the event that matters;
/// only a watch on the file itself does.
///
/// The file is *also* watched for `.delete`/`.rename`/`.revoke`, because an
/// atomic replace (temp file written, then renamed over `config`) — which
/// tilt does not currently do, but which *would* orphan a descriptor held on
/// the old inode — is a real possibility worth surviving. On any of those
/// three, the old source is cancelled and a new one is opened on whatever now
/// exists at the path, so the watcher keeps working across a future change in
/// tilt's write strategy.
///
/// If `configURL` doesn't exist yet (tilt has never run), the parent
/// directory is watched instead until something appears there, at which
/// point the watch switches to the file.
public final class DispatchSourceConfigWatcher: ConfigWatching, @unchecked Sendable {
    private let directory: URL
    private let configURL: URL
    private let continuation: AsyncStream<Void>.Continuation
    public let changes: AsyncStream<Void>

    private let lock = NSLock()
    private var source: DispatchSourceFileSystemObject?

    /// `nil` only if `directory` (`~/.tilt-dev`) itself can't be opened.
    public init?(directory: URL = URL(filePath: NSHomeDirectory()).appending(path: ".tilt-dev")) {
        let probe = open(directory.path, O_EVTONLY)
        guard probe >= 0 else { return nil }
        close(probe)

        self.directory = directory
        self.configURL = directory.appending(path: "config")
        (self.changes, self.continuation) = AsyncStream<Void>.makeStream()

        if !openFileSource() {
            openDirectorySource()
        }
    }

    deinit {
        source?.cancel()
        continuation.finish()
    }

    public func read() throws -> String {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return "" }
        return try String(contentsOf: configURL, encoding: .utf8)
    }

    /// Opens a descriptor directly on `configURL` and installs it as the
    /// active source, cancelling whatever was previously installed. Returns
    /// `false` — without disturbing the existing source, if any — when the
    /// file doesn't exist yet.
    @discardableResult
    private func openFileSource() -> Bool {
        let descriptor = open(configURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .global(qos: .utility)
        )
        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self else { return }
            let flags = newSource?.data ?? []
            if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                // The inode we held is gone. Reopen on whatever's at the path
                // now (an atomic replace already put a new inode there) or,
                // if nothing's there yet, fall back to watching the
                // directory until something reappears. This runs *before*
                // the yield below so a consumer reacting to the change can
                // never race ahead of the new watch being armed — without
                // that ordering, a write landing in the gap between "old
                // watch gone" and "new watch active" is silently lost.
                if !self.openFileSource() {
                    self.openDirectorySource()
                }
            }
            self.continuation.yield(())
        }
        newSource.setCancelHandler { close(descriptor) }

        lock.withLock {
            source?.cancel()
            source = newSource
        }
        newSource.resume()
        return true
    }

    /// Watches the parent directory as a fallback for when `configURL`
    /// doesn't exist. Any directory change is treated as a cue to retry
    /// opening the file directly — coarser than watching the file, but only
    /// ever active before tilt has written its first config.
    private func openDirectorySource() {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .attrib, .rename],
            queue: .global(qos: .utility)
        )
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            // Same ordering rationale as the file-source handler: switch to
            // watching the file (if it now exists) before yielding, so a
            // consumer can never race ahead of the new watch being armed.
            self.openFileSource()
            self.continuation.yield(())
        }
        newSource.setCancelHandler { close(descriptor) }

        lock.withLock {
            source?.cancel()
            source = newSource
        }
        newSource.resume()
    }
}
