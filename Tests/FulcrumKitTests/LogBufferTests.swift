import Foundation
import Testing
@testable import FulcrumKit

/// Builds a `LogLine` stating only the field the test exercises. Not
/// `private`: shared with other files in this test target (e.g. the log
/// pane's tests in a later task) rather than each writing its own copy — see
/// `res(...)` in `ResourceGroupTests.swift` for the pattern this follows.
func line(
    message: String,
    time: Date = Date(timeIntervalSince1970: 0),
    resource: String = "server",
    level: LogLevel = .info,
    source: LogSource = .runtime,
    spanID: String = ""
) -> LogLine {
    LogLine(time: time, resource: resource, level: level, source: source, message: message, spanID: spanID)
}

/// Stamps `lines` with sequence numbers the way the live pane does — by
/// pushing them through a real `LogBuffer` — so tests that call
/// `JSONBlock.detect(in:)`/`LogFilter.apply(to rows:)` directly exercise the
/// same identities the pane sees. Deliberately not a hand-rolled
/// `enumerated().map`: if `LogBuffer` ever stopped stamping uniquely, a test
/// helper that numbered lines itself would keep passing while the app broke.
///
/// Shared across this test target, same rationale as `line(...)` above.
func buffered(_ lines: [LogLine]) -> [BufferedLine] {
    var buffer = LogBuffer(capacity: max(1, lines.count))
    for line in lines { buffer.append(line) }
    return buffer.lines
}

/// Single-line convenience for the many tests that build one line inline.
func buffered(_ line: LogLine) -> BufferedLine {
    buffered([line])[0]
}

@Test func stampsEveryAppendedLineWithADistinctSequenceNumber() {
    // The identity guarantee `LogRow.ID` rests on, at its source: byte-
    // identical lines carrying the same second-resolution timestamp, the same
    // resource and the same span — indistinguishable by every field they
    // have — must still come back out distinguishable.
    var buffer = LogBuffer(capacity: 500)
    let sameSecond = Date(timeIntervalSince1970: 1_786_493_715)
    for _ in 0..<500 {
        buffer.append(line(message: "tick", time: sameSecond, resource: "json-lab", spanID: "localserve:1"))
    }

    let sequences = buffer.lines.map(\.sequence)
    #expect(Set(sequences).count == 500)
    #expect(sequences == Array(0..<500))
}

@Test func aSurvivingLinesSequenceNumberIsUnchangedByEviction() {
    // Eviction shifts every surviving line's POSITION — which is precisely
    // why identity cannot be a position. The number stamped at append must
    // ride through unchanged, and an evicted line's number must never be
    // handed out again: reuse would let a new row inherit an expanded block's
    // identity.
    var buffer = LogBuffer(capacity: 3)
    for i in 1...3 { buffer.append(line(message: "m\(i)")) }
    let survivor = buffer.lines[2]
    #expect(survivor.sequence == 2)

    for i in 4...5 { buffer.append(line(message: "m\(i)")) }
    #expect(buffer.lines.map(\.sequence) == [2, 3, 4])
    // Same line, same number, new position (index 2 -> index 0).
    #expect(buffer.lines[0] == survivor)
}

@Test func keepsTheMostRecentLinesWhenFull() {
    var buffer = LogBuffer(capacity: 3)
    for i in 1...5 { buffer.append(line(message: "m\(i)")) }
    #expect(buffer.lines.map(\.line.message) == ["m3", "m4", "m5"])
}

@Test func countsWhatItDropped() {
    // Silent truncation reads as "these are all the logs" when they are not.
    var buffer = LogBuffer(capacity: 3)
    for i in 1...5 { buffer.append(line(message: "m\(i)")) }
    #expect(buffer.droppedCount == 2)
}

@Test func appendWritesStorageOnceRatherThanShiftingOnEviction() {
    // 24,128 lines arrived in 20s (~1,200/s) from one live instance. Append
    // 50,000 into a 5,000-capacity buffer — 45,000 of those evict — and
    // assert the work done is O(N), not O(N x capacity). A `removeFirst()`-
    // based eviction shifts every surviving element per call (up to
    // `capacity` writes per eviction), which is O(n) per call and O(n^2)
    // overall: with capacity 5,000 and 50,000 appends that is up to ~225M
    // element writes versus the 50,000 a real ring buffer performs.
    //
    // This used to measure elapsed time with `ContinuousClock` and assert
    // `elapsed < .milliseconds(200)`. That is exactly the kind of assertion
    // this codebase has already replaced six times over: swift-testing runs
    // tests concurrently, so a busy machine inflates the interval regardless
    // of the implementation under test — observed failing once in ~13 full-
    // suite runs with `elapsed -> 0.234916875 seconds` against the correct
    // O(1) implementation. Counting the actual writes behind
    // `LogBuffer.storageWrites` (a test seam, see its doc comment) proves the
    // same property deterministically: no clock involved, nothing to flake.
    var buffer = LogBuffer(capacity: 5_000)
    for i in 1...50_000 { buffer.append(line(message: "m\(i)")) }

    #expect(buffer.storageWrites == 50_000)
    #expect(buffer.lines.count == 5_000)
    #expect(buffer.droppedCount == 45_000)
}

// MARK: - Live resize (`SettingsStore.logScrollback`)

@Test func shrinkingKeepsTheMostRecentLinesAndCountsTheRestAsDropped() {
    // The user lowered their scrollback preference mid-stream. What has to
    // survive is the NEWEST end of the log, because that is the end they are
    // reading; and the count of what went has to be truthful, because the
    // pane states truncation rather than hiding it.
    var buffer = LogBuffer(capacity: 10)
    for i in 1...10 { buffer.append(line(message: "m\(i)")) }
    #expect(buffer.droppedCount == 0)

    buffer.resize(to: 3)

    #expect(buffer.capacity == 3)
    #expect(buffer.count == 3)
    #expect(buffer.lines.map(\.line.message) == ["m8", "m9", "m10"])
    #expect(buffer.droppedCount == 7)
}

@Test func shrinkingAddsToTheDropCountAlreadyAccumulated() {
    // The buffer had already evicted before the resize. A resize that
    // ASSIGNED rather than added would erase that history and report a
    // smaller number of lost lines than were actually lost.
    var buffer = LogBuffer(capacity: 5)
    for i in 1...8 { buffer.append(line(message: "m\(i)")) }
    #expect(buffer.droppedCount == 3)

    buffer.resize(to: 2)

    #expect(buffer.lines.map(\.line.message) == ["m7", "m8"])
    #expect(buffer.droppedCount == 6, "3 already evicted plus the 3 the shrink discarded")
}

@Test func aResizedBuffersSurvivingLinesKeepTheirSequenceNumbers() {
    // `LogRow.ID` is the sequence number, and `LogPaneModel.expandedBlockIDs`
    // and `focusedErrorID` are both keyed on it. Renumbering on resize would
    // collapse an expanded block and rewind the jump-to-error cursor, and —
    // worse — could hand a surviving line a number an evicted one already
    // used, letting a new row inherit an expansion it never earned.
    var buffer = LogBuffer(capacity: 10)
    for i in 1...10 { buffer.append(line(message: "m\(i)")) }
    let before = buffer.lines.suffix(3).map(\.sequence)

    buffer.resize(to: 3)

    #expect(buffer.lines.map(\.sequence) == before)
    #expect(before == [7, 8, 9])
}

@Test func aResizedBufferGoesOnStampingWithoutReusingASequenceNumber() {
    // The other half of identity: `nextSequence` counts every line the buffer
    // has EVER been given, and a resize must not roll it back to the new
    // count. Reuse would give a fresh line the identity of an evicted one.
    var buffer = LogBuffer(capacity: 10)
    for i in 1...10 { buffer.append(line(message: "m\(i)")) }
    buffer.resize(to: 3)

    buffer.append(line(message: "next"))

    #expect(buffer.lines.map(\.sequence) == [8, 9, 10])
    #expect(buffer.lines.last?.line.message == "next")
}

@Test func growingKeepsEveryLineAndDropsNothingFurther() {
    // Raising the preference costs the user nothing: a bigger ring cannot
    // lose anything the smaller one was already holding.
    var buffer = LogBuffer(capacity: 3)
    for i in 1...5 { buffer.append(line(message: "m\(i)")) }
    #expect(buffer.droppedCount == 2)

    buffer.resize(to: 10)

    #expect(buffer.capacity == 10)
    #expect(buffer.lines.map(\.line.message) == ["m3", "m4", "m5"])
    #expect(buffer.droppedCount == 2, "growing discards nothing, so the count must not move")
}

@Test func aResizedBufferEvictsAtItsNewCapacity() {
    // The resize has to change the ring's actual behaviour, not merely its
    // reported `capacity`. Shrink to 3, then append past it.
    var buffer = LogBuffer(capacity: 10)
    for i in 1...10 { buffer.append(line(message: "m\(i)")) }
    buffer.resize(to: 3)

    for i in 11...13 { buffer.append(line(message: "m\(i)")) }

    #expect(buffer.count == 3)
    #expect(buffer.lines.map(\.line.message) == ["m11", "m12", "m13"])
    #expect(buffer.droppedCount == 10, "7 discarded by the shrink plus 3 evicted by the appends")
}

@Test func aBufferGrownAfterFillingEvictsAtTheLargerCapacity() {
    // The mirror image, and the one a "resize only writes down a new number"
    // implementation fails: a buffer that filled at 3 and grew to 6 must
    // accept 3 more lines before it drops anything again.
    var buffer = LogBuffer(capacity: 3)
    for i in 1...3 { buffer.append(line(message: "m\(i)")) }
    buffer.resize(to: 6)

    for i in 4...6 { buffer.append(line(message: "m\(i)")) }

    #expect(buffer.count == 6)
    #expect(buffer.droppedCount == 0)
    #expect(buffer.lines.map(\.line.message) == ["m1", "m2", "m3", "m4", "m5", "m6"])
}

@Test func resizingToTheCapacityAlreadyInForceChangesNothing() {
    var buffer = LogBuffer(capacity: 5)
    for i in 1...7 { buffer.append(line(message: "m\(i)")) }
    let writesBefore = buffer.storageWrites

    buffer.resize(to: 5)

    #expect(buffer.lines.map(\.line.message) == ["m3", "m4", "m5", "m6", "m7"])
    #expect(buffer.droppedCount == 2)
    #expect(buffer.storageWrites == writesBefore)
}

@Test func resizingDoesNotChargeItsRebuildToTheAppendWriteCounter() {
    // `storageWrites` is the seam
    // `appendWritesStorageOnceRatherThanShiftingOnEviction` asserts O(1)
    // appends with. A resize is openly O(count); folding its rebuild into
    // that counter would make the append test's number depend on whether a
    // resize had happened, which is how a deterministic assertion quietly
    // turns into a meaningless one.
    var buffer = LogBuffer(capacity: 10)
    for i in 1...10 { buffer.append(line(message: "m\(i)")) }
    #expect(buffer.storageWrites == 10)

    buffer.resize(to: 3)
    #expect(buffer.storageWrites == 10)

    buffer.append(line(message: "next"))
    #expect(buffer.storageWrites == 11, "one write per append, resize or no resize")
}
