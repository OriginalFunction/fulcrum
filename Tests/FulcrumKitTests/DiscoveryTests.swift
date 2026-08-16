import Foundation
import Testing
@testable import FulcrumKit

// Deviation from brief: Task 3's parser requires `certificate-authority-data` on each
// cluster block (missing or invalid base64 drops the entry). The brief's fixture YAML
// omits it. Added a valid base64 CA blob to each cluster so these fixtures parse into
// entries instead of yielding zero.
private let twoInstances = """
apiVersion: v1
clusters:
- cluster:
    server: https://127.0.0.1:55501
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
  name: tilt-10360
- cluster:
    server: https://127.0.0.1:55777
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
  name: tilt-10350
contexts:
- context: {cluster: tilt-10360, user: tilt-10360}
  name: tilt-10360
- context: {cluster: tilt-10350, user: tilt-10350}
  name: tilt-10350
kind: Config
users:
- name: tilt-10360
  user: {token: token-a}
- name: tilt-10350
  user: {token: token-b}
"""

private let emptyConfig = """
apiVersion: v1
clusters: null
contexts: null
kind: Config
users: null
"""

@Test func discoversLiveInstancesFromConfig() async throws {
    let watcher = ManualConfigWatcher(initial: twoInstances)
    let discovery = Discovery(watcher: watcher, probe: StubLivenessProbe(alive: true))
    let found = await discovery.instances()
    #expect(found.count == 2)
    #expect(found.map(\.webPort) == [10350, 10360])
}

@Test func excludesInstancesThatFailLiveness() async throws {
    let watcher = ManualConfigWatcher(initial: twoInstances)
    let discovery = Discovery(watcher: watcher, probe: StubLivenessProbe(alive: false))
    let found = await discovery.instances()
    #expect(found.isEmpty)
}

@Test func emptyConfigYieldsNoInstances() async throws {
    let watcher = ManualConfigWatcher(initial: emptyConfig)
    let discovery = Discovery(watcher: watcher, probe: StubLivenessProbe(alive: true))
    #expect(await discovery.instances().isEmpty)
}

@Test func malformedConfigYieldsNoInstancesRatherThanThrowing() async throws {
    let watcher = ManualConfigWatcher(initial: "{{{ not yaml")
    let discovery = Discovery(watcher: watcher, probe: StubLivenessProbe(alive: true))
    #expect(await discovery.instances().isEmpty)
}

@Test func emitsUpdatedInstancesWhenConfigChanges() async throws {
    let watcher = ManualConfigWatcher(initial: emptyConfig)
    let discovery = Discovery(watcher: watcher, probe: StubLivenessProbe(alive: true))
    await discovery.start()

    var iterator = discovery.stream.makeAsyncIterator()
    watcher.emit(twoInstances)

    let update = await iterator.next()
    #expect(update?.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func finishesStreamWhenDiscoveryDeallocates() async throws {
    let watcher = ManualConfigWatcher(initial: emptyConfig)
    var discovery: Discovery? = Discovery(watcher: watcher, probe: StubLivenessProbe(alive: true))
    await discovery?.start()

    var iterator = discovery!.stream.makeAsyncIterator()

    // Drive the internal task through one full loop iteration — entering the loop,
    // reading the change, computing instances, and yielding onto `stream` — before
    // dropping the last strong reference. Consuming the resulting value is
    // deterministic proof the task actually ran and looped back to await the next
    // change, rather than never having been scheduled at all (see report for why
    // that distinction matters).
    watcher.emit(emptyConfig)
    _ = await iterator.next()

    discovery = nil // drop the last strong reference while the task is looping

    let update = await iterator.next()
    #expect(update == nil)
}

/// File-vs-directory watching is the property this whole task exists to guarantee, and
/// every other test exercises it only through `ManualConfigWatcher`, which sidesteps the
/// real filesystem entirely. These tests drive the actual `DispatchSourceConfigWatcher`
/// against a real temp directory.
private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "fulcrum-discovery-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Appends to `url` by opening a handle, writing, and closing it — never via
/// `Data.write(to:)` / `String.write(to:atomically:true)`, which replace the file
/// (write-to-temp-then-rename) rather than writing in place.
private func appendInPlace(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    try handle.write(contentsOf: Data(text.utf8))
}

/// This is the case that was actually broken: tilt rewrites `config` in place — same
/// inode, updated `mtime` — never via rename. A watcher bound to the directory (the
/// previous implementation) never sees this, because the directory's own `mtime` never
/// changes when a file inside it is edited in place.
@Test(.timeLimit(.minutes(1)))
func dispatchSourceConfigWatcherFiresOnInPlaceWrite() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configFile = directory.appending(path: "config")
    try "kind: Config".write(to: configFile, atomically: false, encoding: .utf8)

    let watcher = try #require(DispatchSourceConfigWatcher(directory: directory))
    var iterator = watcher.changes.makeAsyncIterator()

    try appendInPlace("\nextra: true", to: configFile)

    let event: Void? = await iterator.next()
    #expect(event != nil)
}

/// tilt doesn't do this today, but a watcher that only survives in-place writes would
/// break the moment it started. Replace the file via the classic write-to-temp-then-
/// rename dance (raw `rename(2)`, since `FileManager.moveItem` refuses to overwrite an
/// existing destination), then prove the watcher re-armed on the new inode by writing to
/// it in place afterwards — that second event is the only thing that actually
/// distinguishes "survived the replace" from "happened to see one stray event".
@Test(.timeLimit(.minutes(1)))
func dispatchSourceConfigWatcherSurvivesAtomicReplace() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configFile = directory.appending(path: "config")
    try "kind: Config".write(to: configFile, atomically: false, encoding: .utf8)

    let watcher = try #require(DispatchSourceConfigWatcher(directory: directory))
    var iterator = watcher.changes.makeAsyncIterator()

    let tempFile = directory.appending(path: ".config.tmp")
    try "kind: Config\nreplaced: true".write(to: tempFile, atomically: false, encoding: .utf8)
    let renamed = tempFile.path.withCString { from in
        configFile.path.withCString { to in rename(from, to) }
    }
    #expect(renamed == 0)

    let replaceEvent: Void? = await iterator.next()
    #expect(replaceEvent != nil)

    // Proves the re-arm: without it, this write lands on an orphaned descriptor
    // and no further event ever arrives.
    try appendInPlace("\nafter-replace: true", to: configFile)

    let writeEvent: Void? = await iterator.next()
    #expect(writeEvent != nil)
}

/// tilt has never run, so `config` doesn't exist when the watcher is constructed.
/// `init?` must still succeed (only `~/.tilt-dev` itself is required), falling back to
/// watching the directory until the file appears.
@Test(.timeLimit(.minutes(1)))
func dispatchSourceConfigWatcherFiresWhenConfigAppearsLater() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = try #require(DispatchSourceConfigWatcher(directory: directory))
    var iterator = watcher.changes.makeAsyncIterator()

    let configFile = directory.appending(path: "config")
    try "kind: Config".write(to: configFile, atomically: false, encoding: .utf8)

    let event: Void? = await iterator.next()
    #expect(event != nil)
    #expect(try watcher.read() == "kind: Config")
}
