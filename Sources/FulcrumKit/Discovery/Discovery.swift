import Foundation

/// Turns kubeconfig contents into the set of reachable tilt instances.
public actor Discovery {
    private let watcher: any ConfigWatching
    private let probe: any LivenessProbing
    private let continuation: AsyncStream<[TiltInstance]>.Continuation
    public nonisolated let stream: AsyncStream<[TiltInstance]>
    private var task: Task<Void, Never>?

    public init(watcher: any ConfigWatching, probe: any LivenessProbing) {
        self.watcher = watcher
        self.probe = probe
        (self.stream, self.continuation) = AsyncStream<[TiltInstance]>.makeStream()
    }

    deinit {
        task?.cancel()
        // Wake any consumer sitting in `for await` — a cancelled task will never
        // yield again, so leaving the stream open strands them permanently.
        continuation.finish()
    }

    /// Reads the config once and returns the instances that answer a probe.
    ///
    /// A malformed or missing config yields an empty list rather than throwing —
    /// tilt writes this file, and a half-written read is a transient condition,
    /// not an error worth surfacing.
    public func instances() async -> [TiltInstance] {
        let yaml = (try? watcher.read()) ?? ""
        guard let config = try? Kubeconfig.parse(yaml: yaml) else { return [] }

        var live: [TiltInstance] = []
        for entry in config.tiltEntries {
            let instance = TiltInstance(entry: entry)
            if await probe.isAlive(instance) { live.append(instance) }
        }
        return live
    }

    /// Begins emitting on `stream` whenever the config changes.
    ///
    /// `self` is re-derived from `weak self` on every iteration rather than bound
    /// once before the loop. A single top-of-loop `guard let self` would keep a
    /// strong reference alive for the loop's entire — effectively unbounded —
    /// lifetime, since `watcher.changes` never finishes on its own: `Discovery`
    /// would retain its own task, and the task would retain `Discovery`, so
    /// `deinit` (and the `continuation.finish()` it's responsible for) would never
    /// run. Re-deriving `self` each iteration means the strong reference is held
    /// only for that iteration's work and is released while suspended awaiting the
    /// next change.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let changes = self?.watcher.changes else { return }
            for await _ in changes {
                guard let self else { return }
                let current = await self.instances()
                await self.emit(current)
            }
        }
    }

    private func emit(_ instances: [TiltInstance]) {
        continuation.yield(instances)
    }
}
