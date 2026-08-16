import Foundation
import Testing
@testable import FulcrumKit

private func instance(port: Int, token: String = "t") -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data("pem".utf8), token: token
    ))
}

private func event(name: String, update: String, order: Int = 1) -> WatchEvent {
    WatchEvent(type: .added, object: UIResource(
        metadata: .init(name: name, resourceVersion: "1"),
        status: .init(updateStatus: update, runtimeStatus: "ok",
                      disableStatus: .init(state: "Enabled"), buildHistory: nil,
                      pendingBuildSince: nil, order: order, specs: nil)
    ))
}

@MainActor private func makeModel() -> AppModel {
    AppModel(
        settings: SettingsStore(defaults: TestUserDefaults.fresh()),
        aliasesDefaults: TestUserDefaults.fresh()
    )
}

@MainActor private func makeRecents() -> RecentsStore {
    RecentsStore(storage: InMemoryRecentsStorage())
}

@Test @MainActor func runningInstancesAppearUnderRunning() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    let sections = SidebarItem.build(model: model, recents: makeRecents())

    let running = sections.first { $0.section == .running }
    #expect(running?.items.map(\.port) == [10350])
    #expect(running?.items.first?.isRunning == true)
}

@Test @MainActor func aRunningItemCarriesItsWorstHealth() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "web", update: "error"))

    let sections = SidebarItem.build(model: model, recents: makeRecents())
    #expect(sections.first { $0.section == .running }?.items.first?.health == .error)
}

@Test @MainActor func stoppedProjectsAppearUnderRecentWithNoHealth() {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10360))

    let sections = SidebarItem.build(model: model, recents: recents)
    let recent = sections.first { $0.section == .recent }
    #expect(recent?.items.map(\.port) == [10360])
    #expect(recent?.items.first?.isRunning == false)
    #expect(recent?.items.first?.health == nil)

    // Mirror of the "running excludes recent" rule: with nothing running,
    // the Running section must still be present, just empty — not missing.
    let running = sections.first { $0.section == .running }
    #expect(running?.items.isEmpty == true)
}

@Test @MainActor func multipleProjectsWithPartialOverlapSplitBetweenSections() {
    // The dedupe rule only earns its keep across several projects with
    // partial overlap — a single-instance test could pass with a dedupe
    // that breaks past the first entry.
    let model = makeModel()
    model.sync(with: [instance(port: 10350), instance(port: 10360)])

    var clock = Date(timeIntervalSince1970: 1_000)
    let recents = RecentsStore(storage: InMemoryRecentsStorage(), now: { clock })
    recents.remember(instance(port: 10350)) // also running
    clock = Date(timeIntervalSince1970: 2_000)
    recents.remember(instance(port: 10370))
    clock = Date(timeIntervalSince1970: 3_000)
    recents.remember(instance(port: 10380))

    let sections = SidebarItem.build(model: model, recents: recents)
    let running = sections.first { $0.section == .running }
    let recent = sections.first { $0.section == .recent }

    // Order as actually produced: Running follows sync order; Recent is
    // most-recently-seen first, per RecentsStore, with the overlapping
    // 10350 filtered out.
    #expect(running?.items.map(\.port) == [10350, 10360])
    #expect(recent?.items.map(\.port) == [10380, 10370])

    let allItems = sections.flatMap(\.items)
    #expect(Set(allItems.map(\.id)).count == allItems.count)
}

@Test @MainActor func aProjectThatIsRunningIsNotAlsoListedUnderRecent() {
    // Otherwise a project appears twice for as long as it takes discovery
    // to notice it stopped.
    let model = makeModel()
    let recents = makeRecents()
    let live = instance(port: 10350)
    recents.remember(live)
    model.sync(with: [live])

    let sections = SidebarItem.build(model: model, recents: recents)
    #expect(sections.first { $0.section == .running }?.items.count == 1)
    #expect(sections.first { $0.section == .recent }?.items.isEmpty == true)
}

@Test @MainActor func sectionsAreAlwaysReturnedInRunningThenRecentOrder() {
    let sections = SidebarItem.build(model: makeModel(), recents: makeRecents())
    #expect(sections.map(\.section) == [.running, .recent])
}

@Test @MainActor func emptyStateReturnsBothSectionsEmpty() {
    let sections = SidebarItem.build(model: makeModel(), recents: makeRecents())
    #expect(sections.allSatisfy { $0.items.isEmpty })
}

/// The defect this guards: `InstanceStore.worstHealth` is `nil` before the
/// first successful `list()` (or while it keeps failing), and a naive label
/// mapping collapses that into the same "not running" text a genuinely
/// stopped project gets. A tilt instance whose apiserver is unreachable would
/// then sit in the Running section reading as if nothing were running at all
/// — inverting the rule that a display failure must never look like a tilt
/// failure. Mutating `statusLabel` to `guard let health else { return "not
/// running" }` (dropping the `isRunning` branch) makes this fail.
@Test @MainActor func aRunningInstanceWithNoHealthYetReadsAsConnectingNotNotRunning() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    // No resources ever applied: worstHealth is nil, but the instance is running.

    let sections = SidebarItem.build(model: model, recents: makeRecents())
    let item = sections.first { $0.section == .running }?.items.first
    #expect(item?.health == nil)
    #expect(item?.isRunning == true)
    #expect(item?.statusLabel == "connecting")
}

@Test @MainActor func aStoppedProjectWithNoHealthReadsAsNotRunning() {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10360))

    let sections = SidebarItem.build(model: model, recents: recents)
    let item = sections.first { $0.section == .recent }?.items.first
    #expect(item?.health == nil)
    #expect(item?.isRunning == false)
    #expect(item?.statusLabel == "not running")
}

@Test @MainActor func runningItemTitlePrefersTheResolvedProjectNameWhenKnown() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setResolvedTiltfile(path: "/Users/dev/src/northwind/Tiltfile", projectName: "northwind")

    let sections = SidebarItem.build(model: model, recents: makeRecents())
    #expect(sections.first { $0.section == .running }?.items.first?.title == "northwind")
}

@Test @MainActor func runningItemTitleFallsBackToThePortNameWhenNoProjectNameIsResolved() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    // projectName is never set — the pre-resolution / failed-resolution case.

    let sections = SidebarItem.build(model: model, recents: makeRecents())
    #expect(sections.first { $0.section == .running }?.items.first?.title == "tilt-10350")
}

@Test @MainActor func aRunningInstancesStatusLabelDescribesItsWorstHealthWhenKnown() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].apply(event(name: "web", update: "error"))

    let sections = SidebarItem.build(model: model, recents: makeRecents())
    #expect(sections.first { $0.section == .running }?.items.first?.statusLabel == "error")
}

/// `tiltfilePath` is what Rename, Tilt Down, Reveal in Finder, and Copy
/// Tiltfile Path all key on — a running item must carry its instance's
/// resolved path through, not just the derived display name.
@Test @MainActor func runningItemCarriesItsResolvedTiltfilePath() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setResolvedTiltfile(path: "/Users/dev/src/northwind/Tiltfile", projectName: "northwind")

    let sections = SidebarItem.build(model: model, recents: makeRecents())
    #expect(sections.first { $0.section == .running }?.items.first?.tiltfilePath
            == "/Users/dev/src/northwind/Tiltfile")
}

/// An alias overrides the resolved project name for a running item — the
/// alias → project name → fallback precedence `InstanceStore.displayName(aliases:)`
/// decides, exercised here through the sidebar build that actually feeds it.
@Test @MainActor func anAliasOverridesARunningItemsResolvedProjectName() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setResolvedTiltfile(path: "/Users/r/Projects/p/Tiltfile", projectName: "p")
    model.aliases.setAlias("My Nickname", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")

    let sections = SidebarItem.build(model: model, recents: makeRecents())
    #expect(sections.first { $0.section == .running }?.items.first?.title == "My Nickname")
}

/// The other half of Task 14's Recent-name gap: a stopped project's alias
/// must also override its displayed name, keyed by the Tiltfile path
/// `RecentsStore.updateResolvedName` captured while it was still running.
@Test @MainActor func anAliasOverridesAStoppedProjectsTitleInRecent() {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10360))
    recents.updateResolvedName("p", tiltfilePath: "/Users/r/Projects/p/Tiltfile", forPort: 10360)
    model.aliases.setAlias("My Nickname", forTiltfilePath: "/Users/r/Projects/p/Tiltfile")

    let sections = SidebarItem.build(model: model, recents: recents)
    #expect(sections.first { $0.section == .recent }?.items.first?.title == "My Nickname")
}

@Test @MainActor func runningItemsTiltfilePathIsNilBeforeItResolves() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])

    let sections = SidebarItem.build(model: model, recents: makeRecents())
    #expect(sections.first { $0.section == .running }?.items.first?.tiltfilePath == nil)
}

// MARK: - Restarting a Recent project (Task 4)

@Test @MainActor func aStoppedProjectWithAKnownPathCanBeStarted() {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10360))
    recents.updateResolvedName("p", tiltfilePath: "/Users/r/Projects/p/Tiltfile", forPort: 10360)

    let sections = SidebarItem.build(model: model, recents: recents, fileExists: { _ in true })
    let item = sections.first { $0.section == .recent }?.items.first
    #expect(item?.canRestart == true)
    #expect(item?.restartUnavailableReason == nil)
}

/// Recents persisted before `tiltfilePath` existed decode with `nil` there
/// (see `RecentProject.init(from:)`) — `recents.remember` alone (with no
/// `updateResolvedName` call) reproduces exactly that shape.
@Test @MainActor func aStoppedProjectWithNoKnownPathCannotBeStarted() {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10360))

    let sections = SidebarItem.build(model: model, recents: recents, fileExists: { _ in true })
    let item = sections.first { $0.section == .recent }?.items.first
    #expect(item?.tiltfilePath == nil)
    #expect(item?.canRestart == false)
    #expect(item?.restartUnavailableReason != nil)
}

/// The project was moved or deleted since Fulcrum last saw it. Distinct from
/// the "no known path" case above — the tooltip must name the actual path
/// so this reads as a reported cause, not a silently-ignored click.
@Test @MainActor func aTiltfileThatNoLongerExistsIsReportedNotSilentlyIgnored() {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10360))
    recents.updateResolvedName("p", tiltfilePath: "/Users/r/Projects/p/Tiltfile", forPort: 10360)

    let sections = SidebarItem.build(model: model, recents: recents, fileExists: { _ in false })
    let item = sections.first { $0.section == .recent }?.items.first
    #expect(item?.canRestart == false)
    let reason = try? #require(item?.restartUnavailableReason)
    #expect(reason?.contains("/Users/r/Projects/p/Tiltfile") == true)
}

/// Guards against a mutation that ignores `isRunning` and only checks the
/// path: a running project must never offer "Start" even when its Tiltfile
/// path is known and present, because restarting a live instance is not
/// this action's job.
@Test @MainActor func aRunningProjectCanNeverBeRestarted() {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setResolvedTiltfile(path: "/Users/r/Projects/p/Tiltfile", projectName: "p")

    let sections = SidebarItem.build(model: model, recents: makeRecents(), fileExists: { _ in true })
    let item = sections.first { $0.section == .running }?.items.first
    #expect(item?.canRestart == false)
    #expect(item?.restartUnavailableReason != nil)
}

// MARK: - Broken vs unlinked (Feature 1)

/// The live `detachtest` case: `recents.json` records
/// `/private/tmp/detachtest/Tiltfile` and the file has been deleted. This row
/// gets the broken indicator.
@Test @MainActor func aRecentWhoseTiltfileWasDeletedIsBroken() throws {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10361))
    recents.updateResolvedName("detachtest", tiltfilePath: "/private/tmp/detachtest/Tiltfile", forPort: 10361)

    let sections = SidebarItem.build(model: model, recents: recents, fileExists: { _ in false })
    let item = try #require(sections.first { $0.section == .recent }?.items.first)
    #expect(item.linkState == .broken(path: "/private/tmp/detachtest/Tiltfile"))
    #expect(item.isBroken)
    #expect(item.brokenReason?.contains("/private/tmp/detachtest/Tiltfile") == true)
}

/// The distinction the whole feature turns on. An entry persisted before
/// `tiltfilePath` existed (the live `port-10395` / `port-10398` / `port-10399`
/// entries) also cannot be restarted — but nothing is WRONG with it, and
/// flagging it broken would tell the user their project is damaged when it is
/// Fulcrum's record that is incomplete.
///
/// Mutating `TiltfileLinkState.resolve` to `.broken(path: tiltfilePath ?? "")`
/// — the "anything that can't restart is broken" collapse — fails this while
/// leaving `aRecentWhoseTiltfileWasDeletedIsBroken` above green, which is
/// exactly why both exist.
@Test @MainActor func aRecentWithNoRecordedPathIsUnlinkedAndIsNotFlaggedBroken() throws {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10395))

    let sections = SidebarItem.build(model: model, recents: recents, fileExists: { _ in false })
    let item = try #require(sections.first { $0.section == .recent }?.items.first)
    #expect(item.linkState == .unlinked)
    #expect(item.isBroken == false)
    #expect(item.brokenReason == nil)
    // Still not restartable — the two facts are independent, and this is the
    // pair that must not be collapsed into one.
    #expect(item.canRestart == false)
}

/// Both non-restartable states must explain themselves, and must NOT explain
/// themselves with the same sentence — one generic reason covering two causes
/// is this project's recurring failure mode.
@Test @MainActor func brokenAndUnlinkedGiveDifferentReasonsForTheSameDisabledStart() throws {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10361))
    recents.updateResolvedName("gone", tiltfilePath: "/gone/Tiltfile", forPort: 10361)
    recents.remember(instance(port: 10395))

    let sections = SidebarItem.build(model: model, recents: recents, fileExists: { _ in false })
    let items = try #require(sections.first { $0.section == .recent }?.items)
    let broken = try #require(items.first { $0.port == 10361 })
    let unlinked = try #require(items.first { $0.port == 10395 })

    let brokenReason = try #require(broken.restartUnavailableReason)
    let unlinkedReason = try #require(unlinked.restartUnavailableReason)
    #expect(brokenReason != unlinkedReason)
    #expect(brokenReason.contains("/gone/Tiltfile"))
    #expect(unlinkedReason.contains("/gone/Tiltfile") == false)
    #expect(unlinkedReason.isEmpty == false)
}

/// A present Tiltfile is neither broken nor in need of explanation.
@Test @MainActor func aRecentWhoseTiltfileIsStillThereIsLinked() throws {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10360))
    recents.updateResolvedName("p", tiltfilePath: "/there/Tiltfile", forPort: 10360)

    let sections = SidebarItem.build(model: model, recents: recents, fileExists: { _ in true })
    let item = try #require(sections.first { $0.section == .recent }?.items.first)
    #expect(item.linkState == .linked(path: "/there/Tiltfile"))
    #expect(item.isBroken == false)
    #expect(item.canRestart)
}

/// `restartUnavailableReason` is now derived from `linkState` rather than
/// stored alongside it, so the indicator and the tooltip cannot disagree
/// about which case a row is in. This pins that they stay in step for every
/// combination the sidebar can produce.
@Test @MainActor func theStartTooltipAndTheIndicatorAlwaysAgree() {
    let cases: [(state: TiltfileLinkState, broken: Bool, startEnabled: Bool)] = [
        (.linked(path: "/a"), false, true),
        (.unlinked, false, false),
        (.broken(path: "/a"), true, false)
    ]
    for (state, broken, startEnabled) in cases {
        let item = SidebarItem(
            id: "port-1", title: "p", port: 1, health: nil, isRunning: false,
            tiltfilePath: state.path, linkState: state
        )
        #expect(item.isBroken == broken)
        #expect(item.canRestart == startEnabled)
        if broken {
            // The indicator's tooltip and Start's tooltip are the same
            // sentence because they describe the same fact.
            #expect(item.restartUnavailableReason == item.brokenReason)
        }
    }
}

// MARK: - Relink and Remove availability

@Test @MainActor func aStoppedRowCanBeRelinkedAndRemovedWhateverItsLinkState() throws {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10361))
    recents.updateResolvedName("gone", tiltfilePath: "/gone/Tiltfile", forPort: 10361)
    recents.remember(instance(port: 10395))

    let sections = SidebarItem.build(model: model, recents: recents, fileExists: { _ in false })
    let items = try #require(sections.first { $0.section == .recent }?.items)
    #expect(items.count == 2)
    for item in items {
        #expect(item.canRelink, "a Recent row is exactly what Relink addresses")
        #expect(item.relinkUnavailableReason == nil)
        #expect(item.canRemoveFromRecent)
        #expect(item.removeFromRecentUnavailableReason == nil)
    }
}

/// Relink rewrites a stored `RecentProject`'s path. A running instance's path
/// comes from its live apiserver, so there is nothing to rewrite — offering
/// the item there would be a control that opens a panel, takes a choice, and
/// does nothing with it.
@Test @MainActor func aRunningRowOffersNeitherRelinkNorRemoveAndSaysWhy() throws {
    let model = makeModel()
    model.sync(with: [instance(port: 10350)])
    model.stores[0].setResolvedTiltfile(path: "/there/Tiltfile", projectName: "p")

    let sections = SidebarItem.build(model: model, recents: makeRecents(), fileExists: { _ in true })
    let item = try #require(sections.first { $0.section == .running }?.items.first)
    #expect(item.canRelink == false)
    #expect(item.canRemoveFromRecent == false)
    // Disabled controls carry a tooltip saying why — always, not usually.
    let relinkReason = try #require(item.relinkUnavailableReason)
    let removeReason = try #require(item.removeFromRecentUnavailableReason)
    #expect(relinkReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    #expect(removeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
}

/// The default exists so a caller that passes no existence check renders
/// ordinary rows, never a list of red fault indicators. A default of
/// `{ _ in false }` — or the old real `FileManager` call against these
/// fictional paths — fails this.
@Test @MainActor func theDefaultExistenceCheckNeverInventsABrokenRow() throws {
    let model = makeModel()
    let recents = makeRecents()
    recents.remember(instance(port: 10360))
    recents.updateResolvedName("p", tiltfilePath: "/definitely/not/on/this/disk/Tiltfile", forPort: 10360)

    let sections = SidebarItem.build(model: model, recents: recents)
    let item = try #require(sections.first { $0.section == .recent }?.items.first)
    #expect(item.isBroken == false)
}
