import Foundation
import Testing
@testable import FulcrumKit

@MainActor
private func freshDefaults() -> UserDefaults {
    TestUserDefaults.fresh()
}

@MainActor
private func makeStore(port: Int, token: String) -> InstanceStore {
    InstanceStore(instance: TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data(), token: token
    )))
}

@Test @MainActor func anAliasOverridesTheProjectName() {
    var aliases = InstanceAliases()
    aliases.setAlias("My Nickname", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")

    let store = makeStore(port: 10350, token: "run-1")
    store.setResolvedTiltfile(path: "/Users/r/Projects/p/Tiltfile", projectName: "p")

    #expect(store.displayName(aliases: aliases) == "My Nickname")
}

@Test @MainActor func clearingAnAliasFallsBackToTheProjectName() {
    var aliases = InstanceAliases()
    aliases.setAlias("My Nickname", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")
    aliases.setAlias(nil, forTiltfilePath: "/Users/r/Projects/p/Tiltfile")

    let store = makeStore(port: 10350, token: "run-1")
    store.setResolvedTiltfile(path: "/Users/r/Projects/p/Tiltfile", projectName: "p")

    #expect(aliases.alias(forTiltfilePath: "/Users/r/Projects/p/Tiltfile") == nil)
    #expect(store.displayName(aliases: aliases) == "p")
}

/// Empty and all-whitespace input must clear the same way `nil` does — a
/// text field that submits "" or "   " must not create a blank-named alias.
@Test func settingAnEmptyOrBlankAliasClearsItInsteadOfStoringABlankOne() {
    var aliases = InstanceAliases()
    aliases.setAlias("My Nickname", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")

    aliases.setAlias("   ", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")
    #expect(aliases.alias(forTiltfilePath: "/Users/r/Projects/p/Tiltfile") == nil)

    aliases.setAlias("Renamed", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")
    aliases.setAlias("", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")
    #expect(aliases.alias(forTiltfilePath: "/Users/r/Projects/p/Tiltfile") == nil)
}

/// THE crux of Task 14: the key is the Tiltfile path, not port and not
/// `TiltInstance.InstanceID` — both change across a restart, but the path
/// does not. This asserts the alias set for one run is still found after a
/// restart lands the same project on a different port with a fresh
/// `(server, token)` pair, which is exactly what a port- or InstanceID-keyed
/// implementation would lose.
@Test @MainActor func anAliasSurvivesARestartOnADifferentPort() {
    var aliases = InstanceAliases()
    aliases.setAlias("My Nickname", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")

    let firstRun = makeStore(port: 10350, token: "run-1")
    firstRun.setResolvedTiltfile(path: "/Users/r/Projects/p/Tiltfile", projectName: "p")
    #expect(firstRun.displayName(aliases: aliases) == "My Nickname")

    // A restart: different port, and tilt regenerated (server, token) — but
    // the same Tiltfile path, because it is the same project on disk.
    let secondRun = makeStore(port: 10360, token: "run-2")
    secondRun.setResolvedTiltfile(path: "/Users/r/Projects/p/Tiltfile", projectName: "p")
    #expect(secondRun.displayName(aliases: aliases) == "My Nickname")
}

@Test @MainActor func aliasesRoundTripThroughPersistence() {
    let defaults = freshDefaults()
    var aliases = InstanceAliases.load(from: defaults)
    aliases.setAlias("My Nickname", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")
    aliases.save(to: defaults)

    let reloaded = InstanceAliases.load(from: defaults)
    #expect(reloaded.alias(forTiltfilePath: "/Users/r/Projects/p/Tiltfile") == "My Nickname")
}

@Test @MainActor func clearingAnAliasPersistsAcrossAReload() {
    let defaults = freshDefaults()
    var aliases = InstanceAliases.load(from: defaults)
    aliases.setAlias("My Nickname", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")
    aliases.save(to: defaults)

    var reloaded = InstanceAliases.load(from: defaults)
    reloaded.setAlias(nil, forTiltfilePath: "/Users/r/Projects/p/Tiltfile")
    reloaded.save(to: defaults)

    let final = InstanceAliases.load(from: defaults)
    #expect(final.alias(forTiltfilePath: "/Users/r/Projects/p/Tiltfile") == nil)
}

// MARK: - Recent projects keep their resolved name after stopping

private func instance(port: Int, token: String = "t") -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data("pem".utf8), token: token
    ))
}

/// This closes the gap carried since plan 2: a stopped instance has no live
/// apiserver left to ask for its name, so `RecentsStore` must have captured
/// it while the instance was still running (`updateResolvedName`) rather
/// than only ever showing the port-based fallback it recorded when the
/// project was first discovered.
@Test @MainActor func recentProjectsKeepTheirResolvedNameAfterStopping() {
    let storage = InMemoryRecentsStorage()
    let recents = RecentsStore(storage: storage)

    // Discovery sees the project before its session resolves — the
    // port-based fallback name, same as today.
    recents.remember(instance(port: 10350))
    #expect(recents.projects.first?.displayName == "tilt-10350")

    // The session resolves while it's still running.
    recents.updateResolvedName("northwind", tiltfilePath: "/Users/dev/src/northwind/Tiltfile", forPort: 10350)
    #expect(recents.projects.first?.displayName == "northwind")
    #expect(recents.projects.first?.tiltfilePath == "/Users/dev/src/northwind/Tiltfile")

    // The project has since stopped: nothing calls `remember` or
    // `updateResolvedName` again, and the store is reloaded fresh, as it
    // would be on a relaunch with no live instance for this project.
    let reloaded = RecentsStore(storage: storage)
    #expect(reloaded.projects.first?.displayName == "northwind")
    #expect(reloaded.projects.first?.tiltfilePath == "/Users/dev/src/northwind/Tiltfile")
}

@Test @MainActor func updateResolvedNameIsANoOpForAPortNeverRemembered() {
    let recents = RecentsStore(storage: InMemoryRecentsStorage())
    recents.updateResolvedName("ghost", tiltfilePath: "/Users/r/ghost/Tiltfile", forPort: 99999)
    #expect(recents.projects.isEmpty)
}
