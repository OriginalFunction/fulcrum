import Foundation

/// A `LogLine` together with the sequence number `LogBuffer` stamped on it
/// when it was appended — the line's identity, as opposed to its content.
///
/// THE REASON THIS TYPE EXISTS. `LogLine` carries `time` at only
/// second resolution plus `resource`/`level`/`source`/`message`/`spanID`, and
/// real services repeat all of those verbatim: over a 2,000-line capture from
/// one deliberately repetitive instance, 1,214 rows derived from that content
/// produced just 216 distinct identities — 998 surplus rows, the worst id
/// repeated 86 times. `LogPaneView` renders `ForEach(pane.rows)`, and
/// SwiftUI's `ForEach` requires unique ids: the pane rendered NOTHING AT ALL.
/// Two byte-identical lines emitted within the same second are genuinely
/// indistinguishable by content, so no content-derived scheme can fix that —
/// identity has to come from somewhere else, and `sequence` is that somewhere.
///
/// `sequence` is assigned exactly once, at append, and never recomputed. That
/// is what makes it survive the two things that reshape the pane's row array
/// without changing any row: the 150ms refresh tick rebuilding `rows` from
/// scratch, and ring-buffer eviction shifting every surviving line's
/// POSITION. The position moves; the number does not. (An index-derived id
/// would break on exactly the second one — see `LogRow.ID`.)
public struct BufferedLine: Sendable, Equatable, Hashable, Identifiable {
    /// Monotonically increasing within one `LogBuffer`, starting at 0, with no
    /// gaps and no reuse. Not a position: an evicted line's number is never
    /// handed out again, and a surviving line's number never changes.
    public let sequence: Int
    public let line: LogLine

    public init(sequence: Int, line: LogLine) {
        self.sequence = sequence
        self.line = line
    }

    public var id: Int { sequence }
}

/// A fixed-capacity ring buffer of the most recently appended `LogLine`s.
///
/// `tilt logs --follow` replays a resource's entire history before tailing —
/// one 20-hour-old live instance produced 24,128 lines / 5.7 MB in 20
/// seconds. Kept unbounded, that growth is the risk this buffer exists to
/// remove: at capacity, appending overwrites the oldest line in place rather
/// than growing the backing store.
///
/// This is a real ring buffer (a fixed-size store plus a `head` index that
/// wraps around), NOT an array that gets trimmed. `Array.removeFirst()` is
/// O(n) per call — evicting one line per append at capacity makes eviction
/// O(n^2) overall, which does not survive the measured append rate (see
/// `LogBufferTests.appendWritesStorageOnceRatherThanShiftingOnEviction`).
public struct LogBuffer: Sendable {
    /// `private(set) var` rather than `let` because the user can change how
    /// much scrollback the pane keeps while a stream is running — see
    /// `resize(to:)`, and `SettingsStore.logScrollback` for why that is a
    /// preference at all.
    public private(set) var capacity: Int

    /// Backing storage, always exactly `capacity` slots. `nil` marks a slot
    /// that has never been written (only possible before the buffer first
    /// fills); every slot at index `< count` from `head` holds a real line.
    private var storage: [BufferedLine?]

    /// Index of the oldest live line in `storage`.
    private var head: Int = 0

    /// Number of live lines currently held, from 0 up to `capacity` — the
    /// buffer's OCCUPANCY.
    ///
    /// Public because occupancy turned out to be the variable the log pane's
    /// cost is actually driven by, and `LogPaneModel.adaptRefreshInterval(occupancy:)`
    /// keys on it. Measured directly (`occupancy-hypothesis.md`, Result 2):
    /// holding the arrival rate at 6 lines/sec AND the publication rate at
    /// 5.93/sec and changing nothing but how many lines the buffer holds
    /// moves main-thread availability 100.0% (500 lines) → 99.9% (1,000) →
    /// 95.7% (2,500) → 74.7% (5,000).
    ///
    /// Already known here, so nothing new counts it: every one of `lines`,
    /// `JSONBlock.detect`, `SeverityScanner` and `LogFilter` is O(this) per
    /// publication, which is exactly why it is the right thing to decide from.
    /// Reading it is O(1); reading `lines.count` would be an O(capacity) copy
    /// to find out a number already stored here.
    public private(set) var count: Int = 0

    /// The number the next appended line will be stamped with. Counts every
    /// line this buffer has EVER been given, not how many it currently holds —
    /// eviction must not roll it back, or a surviving line and a later one
    /// could end up sharing a number. Deliberately never reset: a fresh stream
    /// gets a fresh `LogBuffer` (see `LogPaneModel.follow(_:)`), which starts
    /// its own numbering from zero along with the expansion state keyed on it.
    ///
    /// `Int` is 64-bit here; at the measured worst-case ~1,200 lines/sec it
    /// would take longer than the age of the universe to wrap, so overflow is
    /// not a case this handles.
    private var nextSequence: Int = 0

    /// How many appended lines were evicted to stay within `capacity`.
    /// Surfaced so the pane can tell the user "N lines were dropped" instead
    /// of silently showing a partial history as if it were complete.
    public private(set) var droppedCount: Int = 0

    /// Test seam: counts every write into `storage` — the sole place a real
    /// ring buffer touches its backing store per `append`. A correct
    /// implementation writes exactly once per call, at any capacity; an
    /// implementation that shifts surviving elements on eviction (e.g.
    /// `Array.removeFirst()`) writes up to `capacity` times per eviction.
    /// Exists so `LogBufferTests` can assert `append` is O(1) by counting
    /// actual work instead of measuring elapsed time, which is unreliable
    /// under swift-testing's parallel execution. Not `public`: reachable from
    /// tests only through `@testable import`. Cost: one `Int` field plus one
    /// increment on the line that writes into `storage`.
    internal private(set) var storageWrites: Int = 0

    public init(capacity: Int = 5_000) {
        precondition(capacity > 0, "LogBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Appends a line in O(1), stamping it with the next sequence number. At
    /// capacity, overwrites the oldest slot and advances `head` instead of
    /// shifting every other element.
    ///
    /// Stamping happens HERE, at the single point every line in the pane
    /// passes through, rather than at decode: it is the only place that can
    /// promise the numbers are unique and ordered across a whole stream,
    /// whatever produced the lines. Two identical `LogLine`s appended in
    /// sequence come back out as two distinguishable `BufferedLine`s — the
    /// whole point (see `BufferedLine`).
    @discardableResult
    public mutating func append(_ newLine: LogLine) -> BufferedLine {
        let buffered = BufferedLine(sequence: nextSequence, line: newLine)
        nextSequence += 1

        let writeIndex = (head + count) % capacity
        storage[writeIndex] = buffered
        storageWrites += 1
        if count < capacity {
            count += 1
        } else {
            head = (head + 1) % capacity
            droppedCount += 1
        }
        return buffered
    }

    /// Rebuilds this buffer at `newCapacity`, KEEPING THE MOST RECENT lines
    /// and counting whatever no longer fits as dropped. A no-op when the
    /// capacity is unchanged.
    ///
    /// Exists because `SettingsStore.logScrollback` is a live preference: a
    /// user who lowers it mid-stream must not have to relaunch, and — far more
    /// importantly — must not lose the stream. The alternative shape, throwing
    /// the buffer away and re-running `follow(_:)`, would restart
    /// `tilt logs --follow` and blank the pane, which is a visible regression
    /// dressed up as a setting.
    ///
    /// THE THREE INVARIANTS THIS PRESERVES, each of which something
    /// user-visible is keyed to:
    ///
    /// * `nextSequence` is untouched, so every surviving line keeps the
    ///   number it was stamped with. `LogRow.ID` is that number (see
    ///   `BufferedLine`), and `LogPaneModel.expandedBlockIDs` and
    ///   `focusedErrorID` are both keyed on it — an expanded JSON block stays
    ///   expanded across a resize, and "jump to next error" resumes from where
    ///   it was rather than from the top.
    /// * The MOST RECENT lines survive a shrink, not the oldest. A log pane
    ///   that discarded the newest lines to honour a smaller buffer would be
    ///   answering a different question than the one the user asked.
    /// * `droppedCount` absorbs everything discarded, so
    ///   `LogPaneModel.droppedLinesMessage` stays true. Shrinking from 5,000
    ///   to 1,000 with a full buffer states 4,000 more dropped lines
    ///   immediately, because 4,000 lines were in fact dropped. This app
    ///   states truncation rather than hiding it, and a resize is the one
    ///   moment it would be easiest to hide.
    ///
    /// A shrink is exactly the eviction that appending would have performed
    /// anyway, only sooner and in one step — which is why nothing downstream
    /// needs a resize-specific case: every consumer of this buffer already
    /// handles lines going away.
    ///
    /// `storageWrites` is deliberately NOT incremented. It is the seam
    /// `LogBufferTests` uses to assert `append` is O(1), and a resize is
    /// openly O(count); folding its writes into that counter would make the
    /// append test's number depend on whether a resize had happened.
    public mutating func resize(to newCapacity: Int) {
        precondition(newCapacity > 0, "LogBuffer capacity must be positive")
        guard newCapacity != capacity else { return }

        let kept = lines.suffix(newCapacity)
        droppedCount += count - kept.count

        var rebuilt = [BufferedLine?](repeating: nil, count: newCapacity)
        for (index, line) in kept.enumerated() { rebuilt[index] = line }

        storage = rebuilt
        head = 0
        count = kept.count
        capacity = newCapacity
    }

    /// A snapshot of the currently held lines, oldest first.
    ///
    /// This builds a fresh `[BufferedLine]` on every access rather than exposing
    /// a live view into the ring's wrapped internal layout. Deliberate
    /// trade-off: the buffer is written far more often than it is read (a
    /// streaming tail appends on every incoming line; the pane reads once
    /// per render, at UI frame rate at most), so the O(capacity) copy costs
    /// far less in aggregate than a live view would cost in complexity — and
    /// a live view would need to leak the ring's wraparound indexing past
    /// this type's boundary. At the default 5,000 capacity this copy is
    /// microseconds; callers that render on every single append at a fast
    /// stream rate should throttle their own read cadence rather than rely
    /// on this being free.
    public var lines: [BufferedLine] {
        (0..<count).map { storage[(head + $0) % capacity]! }
    }
}
