import Foundation
import Testing
@testable import FulcrumKit

// MARK: - Harness
//
// `LogPaneModel` is driven through the `LogStreaming` seam, never a real
// `tilt logs` process — this stub hands back one controllable
// `AsyncThrowingStream` per `stream(instance:tail:)` call, keyed by instance,
// so a test can push lines and end the stream (cleanly or with an error) on
// its own schedule. Mirrors `StubCommandRunner`'s shape: a lock-protected
// `final class`, `@unchecked Sendable`, because the continuations are
// captured and driven from the test body while `LogPaneModel` consumes them
// concurrently from its own `Task`.
//
// Not `private`: `DashboardModelTests` reuses this to prove `DashboardModel`
// actually wires its injected `logStreaming` through to `logPane`, the same
// "shared, not `private`" precedent as `LogBufferTests.line(...)`.
final class StubLogStreaming: LogStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [TiltInstance.InstanceID: AsyncThrowingStream<LogLine, any Error>.Continuation] = [:]
    private var recordedInstances: [TiltInstance.InstanceID] = []
    /// Every *call* to `stream(instance:tail:)` whose stream has started but
    /// not yet terminated (cancelled, `finish()`ed, or failed) — driven by
    /// `onTermination`, the same signal `LogStreamer` itself reacts to by
    /// killing its child. Keyed by a per-call token, not by instance id: a
    /// test that selects the same instance twice (switch away, switch back)
    /// makes two separate `stream()` calls for the same id, and the first
    /// one's `onTermination` firing late must not evict the second, still-
    /// live one just because they share an instance id.
    private var active: [UUID: TiltInstance.InstanceID] = [:]

    var streamedInstanceCount: Int { lock.withLock { recordedInstances.count } }
    var mostRecentlyStreamedInstanceID: TiltInstance.InstanceID? { lock.withLock { recordedInstances.last } }
    var activeInstanceIDs: Set<TiltInstance.InstanceID> { lock.withLock { Set(active.values) } }

    func stream(instance: TiltInstance, tail: Int) -> AsyncThrowingStream<LogLine, any Error> {
        let token = UUID()
        lock.withLock {
            recordedInstances.append(instance.id)
            active[token] = instance.id
        }
        return AsyncThrowingStream { continuation in
            lock.withLock { continuations[instance.id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.active.removeValue(forKey: token) }
            }
        }
    }

    func push(_ line: LogLine, to id: TiltInstance.InstanceID) {
        lock.withLock { continuations[id] }?.yield(line)
    }

    func finish(_ id: TiltInstance.InstanceID) {
        lock.withLock { continuations[id] }?.finish()
    }

    func fail(_ id: TiltInstance.InstanceID, error: any Error) {
        lock.withLock { continuations[id] }?.finish(throwing: error)
    }
}

private struct StubError: Error, CustomStringConvertible {
    var description: String { "stub stream failure" }
}

private func instance(port: Int) -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-\(port)", port: port,
        server: URL(string: "https://127.0.0.1:\(port + 45000)")!,
        certificateAuthorityPEM: Data("pem".utf8), token: "t\(port)"
    ))
}

// MARK: - Streaming lifecycle

@Test @MainActor func followStartsStreamingTheGivenInstance() {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    pane.follow(instance(port: 10350))
    #expect(stub.streamedInstanceCount == 1)
}

@Test @MainActor func followIsANoOpWhenTheInstanceHasNotChanged() {
    // Re-selecting the same already-followed instance must not restart the
    // stream — the view is expected to call `follow` on every render where
    // the selection *might* have changed, and a real restart on each of
    // those would drop the buffer and flicker the pane constantly.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)
    pane.follow(target)
    pane.follow(target)
    pane.follow(target)
    #expect(stub.streamedInstanceCount == 1)
}

@Test @MainActor func isFollowingAnInstanceReflectsWhetherFollowHasEverBeenStarted() {
    // `DashboardModel.followSelectedInstanceLogs()` reads this to decide
    // whether discovery reconciling the instance set is allowed to touch
    // the pane at all — it must not start a stream on its own the first
    // time, only re-point one that's already running.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    #expect(!pane.isFollowingAnInstance)

    pane.follow(instance(port: 10350))
    #expect(pane.isFollowingAnInstance)

    pane.follow(nil)
    #expect(!pane.isFollowingAnInstance)
}

@Test @MainActor func followingNilAfterAnInstanceAllowsReselectingItLater() {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)
    pane.follow(target)
    pane.follow(nil)
    pane.follow(target)
    #expect(stub.streamedInstanceCount == 2)
}

@Test @MainActor func switchingInstancesClearsThePreviousBuffer() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    stub.push(line(message: "from-a"), to: a.id)
    stub.finish(a.id)
    await pane.streamTaskForTesting?.value

    #expect(pane.lines.map(\.line.message) == ["from-a"])

    pane.follow(b)
    #expect(pane.lines.isEmpty)
    #expect(pane.droppedCount == 0)
}

@Test @MainActor func streamEndingCleanlyFlushesTheFinalLinesWithoutWaitingForATick() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "one"), to: target.id)
    stub.push(line(message: "two"), to: target.id)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value

    #expect(pane.lines.map(\.line.message) == ["one", "two"])
}

@Test @MainActor func streamFailureSurfacesAsAReadableMessage() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "before the failure"), to: target.id)
    stub.fail(target.id, error: StubError())
    await pane.streamTaskForTesting?.value

    #expect(pane.streamError != nil)
    // The failure ends the stream, but whatever arrived before it is not
    // thrown away — same "don't lose what already arrived" rule
    // `LogStreamer` itself follows on a child's abnormal exit.
    #expect(pane.lines.map(\.line.message) == ["before the failure"])
}

@Test @MainActor func followingNilStopsTheStreamAndClearsState() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "one"), to: target.id)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value
    #expect(!pane.lines.isEmpty)

    pane.follow(nil)
    #expect(pane.lines.isEmpty)
    #expect(pane.streamError == nil)
}

// MARK: - Throttled refresh
//
// These drive ingestion through `receive(_:)`, the package-internal test
// seam, rather than through a real stream — asserting "not per append" by
// racing a background consumer against a real timer is exactly the kind of
// timing-based test this project has been burned by twice already (see
// `LogFilter.apply`'s doc comment). Calling `receive` directly makes the
// coalescing behaviour a deterministic, synchronous fact instead.

@Test @MainActor func refreshIsThrottledNotPerAppend() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for i in 1...50 {
        pane.receive(line(message: "m\(i)"))
    }
    // Fifty appends, zero refreshes: `lines` must still reflect nothing.
    #expect(pane.lines.isEmpty)

    pane.refreshIfNeeded()
    #expect(pane.lines.count == 50)

    // A second call with nothing newly appended must be a no-op, not a
    // second O(capacity) copy — this is the "coalesce, don't re-read on
    // every tick regardless" half of the contract.
    pane.refreshIfNeeded()
    #expect(pane.lines.count == 50)
}

@Test @MainActor func droppedLinesMessageIsNilUntilSomethingIsEvicted() {
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 3)
    for i in 1...3 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.droppedLinesMessage == nil)
}

@Test @MainActor func droppedLinesMessageStatesTheCountAndPluralises() {
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 3)
    for i in 1...4 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.droppedLinesMessage == "1 earlier line dropped")

    for i in 5...7 { pane.receive(line(message: "m\(i)")) }
    pane.refreshIfNeeded()
    #expect(pane.droppedLinesMessage == "4 earlier lines dropped")
}

@Test @MainActor func filteredLinesAppliesTheActiveFilter() {
    // Just proves the wiring — `LogFilter.apply(to:)`'s own behaviour is
    // exhaustively covered by `LogFilterTests`.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "ok", source: .runtime))
    pane.receive(line(message: "uh oh", source: .build))
    pane.refreshIfNeeded()

    pane.filter.source = .build
    #expect(pane.filteredLines.map(\.message) == ["uh oh"])
}

// MARK: - Auto-scroll "follow" state

@Test @MainActor func startsFollowingByDefault() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    #expect(pane.isFollowing)
}

@Test @MainActor func scrollingAwayFromTheBottomStopsFollowing() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.scrollPositionChanged(isAtBottom: false)
    #expect(!pane.isFollowing)
}

@Test @MainActor func scrollingBackToTheBottomResumesFollowingWithoutJumpToLatest() {
    // The rule isn't "only the button resumes it" — scrolling back down
    // yourself must work too, or the pane feels stuck in "not following"
    // forever once you've glanced away.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.scrollPositionChanged(isAtBottom: false)
    pane.scrollPositionChanged(isAtBottom: true)
    #expect(pane.isFollowing)
}

@Test @MainActor func jumpToLatestResumesFollowing() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.scrollPositionChanged(isAtBottom: false)
    #expect(!pane.isFollowing)
    pane.jumpToLatest()
    #expect(pane.isFollowing)
}

@Test @MainActor func startingANewStreamResetsFollowingToTrue() async throws {
    // A freshly opened stream should show its tail even if the previous
    // selection had been scrolled away from — "not following" is a
    // decision about *this* stream, not a sticky app-wide preference.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    pane.scrollPositionChanged(isAtBottom: false)
    #expect(!pane.isFollowing)

    pane.follow(b)
    #expect(pane.isFollowing)
}

// MARK: - JSON block expansion state

@Test @MainActor func expansionStateSurvivesARefresh() {
    // Lines stream in and the throttled snapshot is rebuilt on a tick
    // (`refreshIfNeeded()`, called directly here per the project's
    // count/inspect-not-time rule rather than racing the real 150ms timer).
    // An expanded block that collapses the moment more lines arrive is
    // unusable — this is the resource table's group-collapse bug
    // (`DashboardModel.collapsedGroups`) recurring for the log pane.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    let blockLines = [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#),
        line(message: "}"),
    ]
    for blockLine in blockLines { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    guard case .block = pane.rows.first, pane.rows.count == 1 else {
        Issue.record("expected the streamed lines to form one block"); return
    }
    let id = pane.rows.first!.id
    pane.toggleExpansion(id)
    #expect(pane.isExpanded(id))

    // A tick with unrelated new content: `rows` is rebuilt from scratch (a
    // fresh `JSONBlock.detect` + `LogFilter.apply`, since the line snapshot
    // changed), but the block itself is untouched by it.
    pane.receive(line(message: "unrelated line after the block"))
    pane.refreshIfNeeded()

    #expect(pane.rows.count == 2)
    #expect(pane.rows.first!.id == id)
    #expect(pane.isExpanded(id))
}

@Test @MainActor func expansionStateSurvivesRingBufferEviction() {
    // `LogBuffer` evicts oldest-first once appends exceed capacity. Capacity
    // 5 here: "before" + the block's 4 lines exactly fill it, so the very
    // next append evicts "before" and shifts the block from row index 1 to
    // row index 0 — while its own 4 lines are untouched. An index-keyed
    // `expandedBlockIDs` would either lose the expansion (still keyed on 1,
    // but the block is now at 0) or, worse, misattribute it to whatever
    // unrelated row now sits at index 1.
    let pane = LogPaneModel(streaming: StubLogStreaming(), capacity: 5)
    let blockLines = [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#),
        line(message: "}"),
    ]
    pane.receive(line(message: "before"))
    for blockLine in blockLines { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    #expect(pane.rows.count == 2)
    guard case .block = pane.rows[1] else {
        Issue.record("expected the res block at row 1, before eviction"); return
    }
    let blockID = pane.rows[1].id
    pane.toggleExpansion(blockID)
    #expect(pane.isExpanded(blockID))

    // One more line: capacity 5 was already full (5 lines held), so this
    // append evicts "before" — the block's own lines are not evicted, only
    // repositioned in the rebuilt `rows` array.
    pane.receive(line(message: "after"))
    pane.refreshIfNeeded()
    #expect(pane.droppedCount == 1)

    #expect(pane.rows.count == 2)
    guard case .block = pane.rows[0] else {
        Issue.record("expected the res block to have shifted to row 0 after eviction"); return
    }
    let shiftedBlockID = pane.rows[0].id

    // Same block, same identity, despite the position change.
    #expect(shiftedBlockID == blockID)
    #expect(pane.isExpanded(shiftedBlockID))

    // The unrelated new line, which now occupies the block's OLD index (1),
    // must not have inherited its expansion.
    guard case .line = pane.rows[1] else {
        Issue.record("expected the new unrelated line at row 1"); return
    }
    #expect(!pane.isExpanded(pane.rows[1].id))
}

@Test @MainActor func twoDifferentBlocksHaveTwoDifferentIdentities() {
    // Every other test in this section works with ONE block, so all 20 of
    // them passed with `LogRow.ID.block` collapsed to `.block(lines: [])` —
    // every block in the buffer sharing a single identity. With one block on
    // screen that is indistinguishable from correct; with two it is the
    // feature failing outright: expanding A expands B as well, and the
    // detail pane renders whichever block comes first rather than the one
    // clicked. What identity has to be keyed on is the row's own content —
    // see `LogRow.ID`'s doc comment, including the known collision it does
    // accept (two blocks identical field-for-field within the same second).
    // These two are not that: they differ in their JSON.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in [
        line(message: "req: {"), line(message: #"  "url": "/api/auth/check""#), line(message: "}"),
        line(message: "res: {"), line(message: #"  "statusCode": 304"#), line(message: "}"),
    ] { pane.receive(l) }
    pane.refreshIfNeeded()

    #expect(pane.rows.count == 2)
    guard case .block(let requestBlock, _) = pane.rows[0],
          case .block(let responseBlock, _) = pane.rows[1] else {
        Issue.record("expected the streamed lines to form two distinct blocks"); return
    }
    let request = pane.rows[0].id
    let response = pane.rows[1].id
    #expect(request != response)

    // Expanding one must not expand the other.
    pane.toggleExpansion(request)
    #expect(pane.isExpanded(request))
    #expect(!pane.isExpanded(response))

    // And the detail pane must open the block that was actually clicked,
    // not merely a block. Reduced to `Bool` before `#expect` sees it: a
    // failing comparison of two `JSONBlock`s makes swift-testing reflect
    // over their `JSONValue` trees to render the message.
    pane.openInDetailPane(response)
    let opened = pane.focusedBlock == responseBlock
    let openedTheWrongOne = pane.focusedBlock == requestBlock
    #expect(opened)
    #expect(!openedTheWrongOne)
}

@Test @MainActor func repetitiveIdenticalLinesStillGetDistinctRowIdentities() {
    // THE live bug: an instance whose logs are highly repetitive rendered
    // NOTHING at all — no rows — while `tilt logs --json --tail 2000 --follow`
    // was demonstrably producing output. `LogPaneView` renders
    // `ForEach(pane.rows)`, and SwiftUI's `ForEach` requires unique ids;
    // measured over a 2,000-line capture from that instance, 1,214 rows
    // carried only 216 distinct ids (998 surplus rows, the worst id repeated
    // 86 times) and the pane drew nothing.
    //
    // The shape reproduced here is exactly what made it constant: byte-
    // identical messages, the SAME second-resolution timestamp (`LogLine.time`
    // has no sub-second component), the same resource and the same span — so
    // nothing about a row's CONTENT can tell two of these emissions apart. A
    // row's identity therefore cannot be derived from its content; it comes
    // from the sequence number `LogBuffer` stamps at append time.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    let sameSecond = Date(timeIntervalSince1970: 1_786_493_715)
    func repeated(_ message: String) -> LogLine {
        line(message: message, time: sameSecond, resource: "json-lab", spanID: "localserve:1")
    }

    // 200 identical block/line pairs: 400 rows, every one indistinguishable
    // from its 199 twins by any field it carries.
    for _ in 0..<200 {
        pane.receive(repeated("res: {"))
        pane.receive(repeated(#"  "statusCode": 200"#))
        pane.receive(repeated("}"))
        pane.receive(repeated("tick"))
    }
    pane.refreshIfNeeded()

    let rows = pane.rows
    #expect(rows.count == 400)
    #expect(Set(rows.map(\.id)).count == rows.count)
}

@Test @MainActor func togglingExpansionTwiceCollapsesAgain() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    let blockLines = [
        line(message: "{"),
        line(message: #"  "ok": true"#),
        line(message: "}"),
    ]
    for blockLine in blockLines { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    let id = pane.rows.first!.id
    #expect(!pane.isExpanded(id))
    pane.toggleExpansion(id)
    #expect(pane.isExpanded(id))
    pane.toggleExpansion(id)
    #expect(!pane.isExpanded(id))
}

@Test @MainActor func switchingInstancesClearsExpansionState() {
    // Same rationale as the buffer itself getting cleared on `follow(_:)`:
    // an expansion referring to a block from the previous stream has no
    // meaning once that stream's content is gone.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)

    pane.follow(a)
    let blockLines = [
        line(message: "{"),
        line(message: #"  "ok": true"#),
        line(message: "}"),
    ]
    for blockLine in blockLines { pane.receive(blockLine) }
    pane.refreshIfNeeded()
    pane.toggleExpansion(pane.rows.first!.id)
    #expect(!pane.expandedBlockIDs.isEmpty)

    pane.follow(b)
    #expect(pane.expandedBlockIDs.isEmpty)
}

// MARK: - `rows` caching

@Test @MainActor func rowsIsBuiltOncePerChangeNotOncePerRead() {
    // SwiftUI reads `rows` several times per render (the list, the scroll
    // target, the empty-state check). Each read used to re-run
    // `JSONBlock.detect` — ANSI strip, trim, brace scan and JSON parse over
    // the whole buffer — plus `LogFilter.apply`, on the main actor, for an
    // answer that had not changed.
    //
    // Counted, not timed, per the project's standing rule: `rowsRecomputeCount`
    // is the seam, the same shape as `LogFilter.CompilationCounter`.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for blockLine in [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200"#),
        line(message: "}"),
        line(message: "a plain line"),
    ] { pane.receive(blockLine) }
    pane.refreshIfNeeded()

    _ = pane.rows
    _ = pane.rows
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 1)

    // A new snapshot is a genuine change: exactly one more build.
    pane.receive(line(message: "another plain line"))
    pane.refreshIfNeeded()
    _ = pane.rows
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 2)

    // So is a filter edit, even with the same lines.
    pane.filter.query = "statusCode"
    _ = pane.rows
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 3)

    // A no-op tick (nothing appended) must not invalidate anything.
    pane.refreshIfNeeded()
    _ = pane.rows
    #expect(pane.rowsRecomputeCount == 3)
}

@Test @MainActor func rowsNeverAnswersFromAStaleCache() {
    // The mutation guard for the test above: a cache keyed on the wrong
    // thing (or never invalidated) makes `rows` cheap AND wrong, which is
    // strictly worse than recomputing. Every input `rows` derives from is
    // changed here in turn, and the ANSWER — not the recompute count — is
    // checked each time.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.receive(line(message: "first"))
    pane.refreshIfNeeded()
    // The first line the buffer ever saw, so sequence 0 — and that number is
    // the row's whole identity now (`LogRow.ID`).
    #expect(pane.rows.map(\.id) == [LogRow.ID(sequence: 0)])
    #expect(pane.rows.flatMap { $0.lines.map(\.line.message) } == ["first"])

    // New lines show up.
    pane.receive(line(message: "second"))
    pane.refreshIfNeeded()
    #expect(pane.rows.count == 2)

    // A filter change re-filters the same lines.
    pane.filter.query = "second"
    #expect(pane.rows.count == 1)
    pane.filter.query = ""
    #expect(pane.rows.count == 2)

    // Following a new instance empties it.
    pane.follow(instance(port: 10350))
    #expect(pane.rows.isEmpty)
}

// MARK: - Expansion side effects: follow-pause and the shared "open block"
//
// `toggleExpansion` (the INLINE chevron) and `openInDetailPane` (the detail
// pane's own click) are two entry points into the same underlying state —
// see `LogPaneModel.focusedBlockID`'s doc comment for why that sharing is
// what makes switching `SettingsStore.jsonPresentation` mid-session
// lossless. These tests exercise that sharing directly, without any
// `JSONPresentation` involved at all — proving the model needs none.

private func openBlockLines() -> [LogLine] {
    [line(message: "{"), line(message: #"  "ok": true"#), line(message: "}")]
}

@Test @MainActor func expandingABlockInlinePausesFollowing() {
    // Task 5's most important interaction: expanding a block while the pane
    // is tailing must not push it off screen. "Jump to Latest" is the only
    // way back — this only checks the pause half.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    #expect(pane.isFollowing)

    pane.toggleExpansion(pane.rows.first!.id)
    #expect(!pane.isFollowing)
}

@Test @MainActor func collapsingABlockDoesNotResumeFollowing() {
    // Only "Jump to Latest" (or scrolling back down) resumes following —
    // collapsing the block just read must not silently resume tailing out
    // from under the user.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    let id = pane.rows.first!.id

    pane.toggleExpansion(id)
    #expect(!pane.isFollowing)
    pane.toggleExpansion(id)
    #expect(!pane.isFollowing)
}

@Test @MainActor func openingInDetailPaneDoesNotPauseFollowing() {
    // Task 6's whole point: the tree renders BESIDE the log, not in place,
    // so nothing about the flowing content resizes and there is no reason
    // to stop tailing.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    #expect(pane.isFollowing)

    pane.openInDetailPane(pane.rows.first!.id)
    #expect(pane.isFollowing)
}

@Test @MainActor func toggleExpansionAlsoFocusesTheBlockForTheDetailPane() {
    // The INLINE path must leave a trail the detail pane can pick up: a
    // block expanded via the chevron is the one that presentation would
    // show if `jsonPresentation` were flipped to `.detailPane` afterward.
    // Without this, that switch would show a blank detail pane.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    let id = pane.rows.first!.id
    #expect(pane.focusedBlockID == nil)

    pane.toggleExpansion(id)
    #expect(pane.focusedBlockID == id)
}

@Test @MainActor func openInDetailPaneAlsoMarksTheBlockExpanded() {
    // The mirror image: a block opened via the DETAIL PANE reads as already
    // expanded if `jsonPresentation` is flipped back to `.inline`.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    let id = pane.rows.first!.id

    pane.openInDetailPane(id)
    #expect(pane.isExpanded(id))
    #expect(pane.focusedBlockID == id)
}

@Test @MainActor func closingTheDetailPaneCollapsesItsBlock() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    let id = pane.rows.first!.id
    pane.openInDetailPane(id)

    pane.closeDetailPane()
    #expect(pane.focusedBlockID == nil)
    #expect(!pane.isExpanded(id))
}

@Test @MainActor func closingTheDetailPaneWithNothingOpenIsANoOp() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.closeDetailPane()
    #expect(pane.focusedBlockID == nil)
}

@Test @MainActor func openingADifferentBlockInDetailPaneReplacesTheFocusedOne() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in [
        line(message: "{"), line(message: #"  "a": 1"#), line(message: "}"),
        line(message: "{"), line(message: #"  "b": 2"#), line(message: "}"),
    ] { pane.receive(l) }
    pane.refreshIfNeeded()
    #expect(pane.rows.count == 2)
    let first = pane.rows[0].id
    let second = pane.rows[1].id

    pane.openInDetailPane(first)
    #expect(pane.focusedBlockID == first)
    pane.openInDetailPane(second)
    #expect(pane.focusedBlockID == second)
    // The first block stays a member of `expandedBlockIDs` even though it's
    // no longer the focused one — only `closeDetailPane` or toggling it
    // directly collapses it, same as clicking a second row in a real
    // inspector-style panel does not retroactively close the first.
    #expect(pane.isExpanded(first))
}

@Test @MainActor func followingANewInstanceClearsTheFocusedBlock() {
    // Same rationale as `switchingInstancesClearsExpansionState` above: a
    // focused block from the previous stream has no meaning once that
    // stream's content is gone.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let a = instance(port: 10350)
    let b = instance(port: 10360)
    pane.follow(a)
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    pane.openInDetailPane(pane.rows.first!.id)
    #expect(pane.focusedBlockID != nil)

    pane.follow(b)
    #expect(pane.focusedBlockID == nil)
}

@Test @MainActor func focusedBlockLooksUpTheActualBlockFromRows() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    for l in openBlockLines() { pane.receive(l) }
    pane.refreshIfNeeded()
    #expect(pane.focusedBlock == nil)

    let id = pane.rows.first!.id
    pane.openInDetailPane(id)
    guard case .block(let expectedBlock, _) = pane.rows.first! else {
        Issue.record("expected the streamed lines to form one block"); return
    }
    #expect(pane.focusedBlock == expectedBlock)
}

// The resource health map used to live here, snapshotted onto `LogPaneModel`
// and refreshed by `DashboardModel.followSelectedInstanceLogs()`. That
// snapshot went stale between reconciles — the exact case this feature
// exists to catch — so it moved to `DashboardModel.resourceHealthByName`, a
// live computed property over `visibleResources` with no cache to refresh.
// See `DashboardModelTests.swift`'s "Log pane resource health" section.

// MARK: - Empty state
//
// THE bug this section exists for: a resource scoped to `(Tiltfile)` — which
// genuinely emits zero lines — rendered a blank pane with a "Scoped to
// (Tiltfile)" chip and nothing else, and a user reasonably reported the app
// as broken. `emptyState` is the fix: a typed DECISION about which of four
// reasons applies, asserted here by exact case (and, for `.filteredOut`, by
// exact `FilterCause` membership) — never by "some message appeared", which
// would pass just as happily if two causes swapped names.

@Test @MainActor func emptyStateIsNotFollowingBeforeFollowHasEverBeenCalled() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    #expect(pane.emptyState == .notFollowing)
}

@Test @MainActor func emptyStateIsNotFollowingAfterFollowingNil() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "one"), to: target.id)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value

    pane.follow(nil)
    #expect(pane.emptyState == .notFollowing)
}

@Test @MainActor func emptyStateIsWaitingForLinesWhileTheStreamIsOpenAndNothingHasArrived() {
    // The normal, few-hundred-ms window right after `follow(_:)` — this must
    // never be reported as any of the other three cases.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    #expect(pane.emptyState == .waitingForLines)
}

@Test @MainActor func emptyStateIsStreamEndedWithNoLinesAfterACleanFinishThatProducedNothing() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value

    #expect(pane.emptyState == .streamEndedWithNoLines)
}

@Test @MainActor func emptyStateIsStreamEndedWithNoLinesAfterAFailureThatProducedNothing() async throws {
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.fail(target.id, error: StubError())
    await pane.streamTaskForTesting?.value

    // `streamError`'s own banner already states the failure — this case must
    // still be reported (the empty pane needs SOME explanation), just not a
    // duplicate of that banner's text, which is the view's job to avoid, not
    // this enum's.
    #expect(pane.streamError != nil)
    #expect(pane.emptyState == .streamEndedWithNoLines)
}

@Test @MainActor func emptyStateIsNilWhenAtLeastOneLineMatchesTheActiveFilter() {
    // "Has content" is not a case of `EmptyState` at all — `nil` is the only
    // representation, exactly mirroring `DashboardModel.emptyState`'s own
    // "non-nil exactly when the view draws nothing" contract.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "hello", resource: "server"))
    pane.refreshIfNeeded()

    #expect(pane.emptyState == nil)
}

@Test @MainActor func emptyStateNamesOnlyTheResourceScopeWhenItAloneExcludesEverything() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "hello", resource: "server"))
    pane.refreshIfNeeded()

    pane.filter.resource = "some-other-resource"
    #expect(pane.emptyState == .filteredOut([.resourceScope]))
}

@Test @MainActor func emptyStateNamesOnlyTheTextQueryWhenItAloneExcludesEverything() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "hello", resource: "server"))
    pane.refreshIfNeeded()

    pane.filter.query = "no-such-substring"
    #expect(pane.emptyState == .filteredOut([.textQuery]))
}

@Test @MainActor func emptyStateNamesBothScopeAndQueryWhenBothExcludeEverything() {
    // The other half of the trap: with two controls active, the state must
    // not point at only one of them — a message built from a case that
    // dropped the second bit would send the user to clear the wrong thing
    // (or only half the right thing).
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "hello", resource: "server"))
    pane.refreshIfNeeded()

    pane.filter.resource = "some-other-resource"
    pane.filter.query = "no-such-substring"

    guard case .filteredOut(let cause) = pane.emptyState else {
        Issue.record("expected .filteredOut, got \(String(describing: pane.emptyState))"); return
    }
    #expect(cause.contains(.resourceScope))
    #expect(cause.contains(.textQuery))
    #expect(!cause.contains(.source))
}

@Test @MainActor func emptyStateNamesTheSourceFilterWhenItAloneExcludesEverything() {
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.receive(line(message: "runtime line", source: .runtime))
    pane.refreshIfNeeded()

    pane.filter.source = .build
    #expect(pane.emptyState == .filteredOut([.source]))
}

@Test @MainActor func emptyStateIsWaitingNotFilteredOutWhenTheBufferItselfIsEmptyEvenWithAFilterSet() {
    // THE trap, stated directly: a filter field being "active" is not enough
    // to blame it — with the raw buffer itself empty, every active filter
    // field trivially excludes everything (there is nothing to include), so
    // `.filteredOut` must never fire here. This is `emptyState`'s doc-comment
    // precedence (case 2 gates on `lines`, before `filter` is ever read) made
    // into an assertion.
    let pane = LogPaneModel(streaming: StubLogStreaming())
    pane.follow(instance(port: 10350))
    pane.filter.resource = "some-resource-that-will-never-arrive"
    pane.filter.query = "anything"

    #expect(pane.emptyState == .waitingForLines)
}

@Test @MainActor func emptyStateStaysFilteredOutRatherThanStreamEndedWhenLinesExistButAreExcluded() async throws {
    // The converse of the trap: once at least one line has genuinely
    // arrived, the stream having since ended must not overwrite the more
    // specific `.filteredOut` diagnosis with the generic "nothing arrived"
    // one — the user's actual problem is the filter, not a dead stream.
    let stub = StubLogStreaming()
    let pane = LogPaneModel(streaming: stub)
    let target = instance(port: 10350)

    pane.follow(target)
    stub.push(line(message: "hello", resource: "server"), to: target.id)
    stub.finish(target.id)
    await pane.streamTaskForTesting?.value

    pane.filter.resource = "some-other-resource"
    #expect(pane.emptyState == .filteredOut([.resourceScope]))
}
