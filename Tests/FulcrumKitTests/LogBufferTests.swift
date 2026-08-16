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
