import Foundation
import Observation

/// Live state behind the dashboard's log pane: the current stream's lines,
/// the active filter, and the auto-scroll "follow" decision.
///
/// `follow(_:)` points this at (at most) one instance's stream at a time —
/// switching instances cancels the old stream and starts fresh, same
/// lifecycle `InstanceSupervisor` uses for the resource watch. The view is
/// responsible for calling it when the dashboard's selection changes
/// (`LogPaneView`'s `onChange(of: dashboard.selectedInstance?.id)`); an
/// `@Observable` class has no way to react to another object's property
/// changing on its own, only a view's `body` re-evaluating does.
///
/// Reading `LogBuffer.lines` is an O(capacity) copy — cheap once, not cheap
/// at the measured ~1,200 lines/sec a real instance can produce (24,128
/// lines / 5.7 MB in 20s). `lines`/`droppedCount` are therefore refreshed on
/// a timer (`refreshIfNeeded()`, ticked by an internal loop at
/// `activeRefreshInterval`) rather than on every incoming line — appended
/// lines sit in the ring buffer, counted by `pendingLineCount`, until the
/// next tick coalesces however many arrived into one copy.
///
/// That tick interval is ADAPTIVE — see `adaptRefreshInterval(occupancy:)`.
/// The pane's cost is `publications/sec x O(occupancy)`, and a coalescer that
/// publishes on a timer holds the first term nearly constant whatever the
/// stream does — so a pane holding a lot of lines is deliberately published
/// less often than a pane holding few, regardless of how fast they arrived.
@Observable
@MainActor
public final class LogPaneModel {
    /// The capacity a pane built WITHOUT one gets. Matches `LogBuffer`'s own
    /// default.
    ///
    /// This is NOT the app's default scrollback and has not been since
    /// capacity became a preference: `SettingsStore.logScrollback` is, it
    /// defaults to 1,000 lines, and `DashboardModel` always passes it here
    /// explicitly. The remaining callers of this fallback are tests, which
    /// want a buffer roomy enough to exercise `floodedOccupancy` without
    /// spelling a capacity out every time. Left at 5,000 for exactly that
    /// reason rather than lowered to match the shipped default, which would
    /// silently put a threshold the tests are about out of their reach.
    public static let defaultCapacity = 5_000

    /// How often a live stream's accumulated lines are copied out of the ring
    /// buffer into `lines` while the stream is NOT flooding — and the
    /// interval every stream starts on (`follow(_:)` resets to it). Frequent
    /// enough that a trickle of lines appears as it lands.
    ///
    /// The name is historical: this was the single constant, and the tick is
    /// still this often for every stream that isn't a firehose. See
    /// `floodedRefreshInterval` for the other half.
    static let refreshInterval: Duration = .milliseconds(150)

    /// The tick interval used while the buffer is full enough to make a
    /// publication expensive (`adaptRefreshInterval(occupancy:)` decides when
    /// that is).
    ///
    /// 500ms is a MEASURED number, not a guess, and it has now been measured
    /// twice against two different theories of what makes the pane slow:
    ///
    /// * `hang-investigation.md` §5, at 1,199 lines/sec into a full buffer —
    ///   the shipped 150ms tree held **43%** main-thread availability against
    ///   an 87% ceiling, the same tree at 500ms held **81%**.
    /// * `occupancy-hypothesis.md` Result 4, at **6 lines/sec** into a full
    ///   buffer, which is the developer's real measured stream rate — the
    ///   fast interval held **73.9%**, the slow interval **89.4%**.
    ///
    /// The second one is why this constant survived the rewrite below while
    /// the thing that selects it did not: 500ms was never the part that was
    /// keyed to the wrong variable.
    static let floodedRefreshInterval: Duration = .milliseconds(500)

    /// A buffer holding AT LEAST this many lines makes each publication
    /// expensive enough to be worth publishing less often, and selects
    /// `floodedRefreshInterval`. Below it, `refreshInterval`.
    ///
    /// Read straight off the measured cost curve in `occupancy-hypothesis.md`
    /// Result 2 — the cleanest experiment in any of the three reports, because
    /// it pins the arrival rate at 6 lines/sec AND the publication rate at
    /// 5.93/sec and varies nothing but how many lines the buffer holds:
    ///
    /// | occupancy | main-thread availability |
    /// |---|---|
    /// | 500 | 100.0% |
    /// | 1,000 | 99.9% |
    /// | **2,500** | **95.7%** |
    /// | 5,000 | 74.7% |
    ///
    /// 2,500 is a MEASURED POINT on that curve, not an interpolation, and it
    /// is the last one at which the pane is still essentially free. Choosing
    /// lower would trade a certain 500ms of added latency for at most the 4.3
    /// points that separate 2,500 from 100% — and at 1,000 lines, for the 0.1
    /// points that separate it from perfect. Choosing higher (3,000, say)
    /// would put the threshold somewhere no measurement exists, inside the
    /// interval where 21 of the curve's 25 points are lost. So the threshold
    /// goes at the knee's upper measured end: everything cheap stays fast,
    /// and the expensive region is entered already slowed.
    ///
    /// ABSOLUTE, not a fraction of `capacity`, because the cost is a function
    /// of how many rows exist, not of how full the ring is. That distinction
    /// became load-bearing the moment capacity turned into a user preference
    /// (`SettingsStore.logScrollback`), because it is what makes the four
    /// offered capacities behave as their settings copy claims:
    ///
    /// | scrollback | can occupancy reach 2,500? | slow interval ever selected |
    /// |---|---|---|
    /// | 500 | no | never |
    /// | 1,000 (default) | no | never |
    /// | 2,500 | exactly, when full | once full |
    /// | 5,000 | yes | once half full |
    ///
    /// A user who picks a small buffer therefore gets no added latency AT
    /// ALL, and one who picks a large buffer keeps the protection — which a
    /// fractional threshold would invert, imposing 500ms of lag on a
    /// 500-line pane measured at 100% availability purely for being full.
    /// Verified by test, not by inspection:
    /// `aCapacityBelowTheThresholdNeverSelectsTheSlowInterval` and
    /// `everyOfferedScrollbackChoiceSelectsTheIntervalItsCopyPromises`.
    static let floodedOccupancy = 2_500

    private let streaming: any LogStreaming
    /// `tilt logs --tail` bound for the initial replay. Deliberately well
    /// under `defaultCapacity`: `LogStreamer`'s own doc records `--tail 50
    /// --follow` returning 76 lines in 12s against the same instance that
    /// produced 24,128 lines / 5.7 MB with no tail bound at all — the initial
    /// burst this pane has to absorb is `tail`'s cost, not the buffer's.
    private let tail: Int

    private var buffer: LogBuffer
    private var currentInstanceID: TiltInstance.InstanceID?

    /// One `follow(_:)`'s worth of async work — the task draining the stream,
    /// the task ticking the throttled refresh — and, the reason this is a
    /// class rather than two fields on the model, the IDENTITY that says
    /// whether that work is still the pane's current work.
    ///
    /// This type exists because of a bug class, not a bug: three times now,
    /// async work belonging to a superseded stream has clobbered the state of
    /// the live one (a dropped final line, a main-thread deadlock, and the
    /// one this shape was introduced for — a stale task cancelling the NEW
    /// stream's flush loop and declaring it ended, which killed the log pane
    /// on every instance switch until the dashboard was closed and reopened).
    ///
    /// `Task.isCancelled` is not enough to prevent it and never was. A
    /// cancelled `AsyncThrowingStream` consumer does not throw: its `next()`
    /// returns `nil`, so the `for await` loop exits NORMALLY and runs whatever
    /// follows it. Worse, a task can finish its loop without cancellation ever
    /// being requested (the producer simply ended first) and still be stale by
    /// the time it resumes on the main actor — where `follow(_:)` has, in the
    /// meantime, installed a replacement. Cancellation is a request; identity
    /// is a fact.
    @MainActor
    private final class StreamSession {
        var streamTask: Task<Void, Never>?
        var flushTask: Task<Void, Never>?

        /// Both tasks, never one: `follow(_:)` replacing a session must not be
        /// able to leave half of the old one running.
        func cancel() {
            streamTask?.cancel()
            flushTask?.cancel()
        }
    }

    /// The session `follow(_:)` most recently installed, or `nil` when nothing
    /// is being followed. Every async write below is gated on being THIS one —
    /// see `ifCurrent(_:_:)`.
    private var session: StreamSession?

    /// How many lines have been appended since the last `refreshIfNeeded()`
    /// tick — the coalescing counter that makes the buffer-to-`lines` copy a
    /// per-tick cost instead of a per-line one.
    ///
    /// A COUNT rather than the `dirty` flag it replaces. It was briefly the
    /// input to the refresh policy too; that turned out to be the wrong
    /// variable (see `adaptRefreshInterval(occupancy:)`) and it is now purely
    /// the coalescer's own state, plus the one number
    /// `linesCoalescedByLastTick` reports. One piece of state, not two that
    /// have to agree: `pendingLineCount > 0` IS "dirty".
    ///
    /// `@ObservationIgnored` because it is written on every single arriving
    /// line — at 1,200 lines/sec that is 1,200 `withMutation` calls a second
    /// announcing a change no view can observe (it is private) or would want
    /// to. The published fact is `lines`, once per tick.
    @ObservationIgnored private var pendingLineCount = 0

    /// The interval `follow(_:)`'s flush loop is currently sleeping for —
    /// either `refreshInterval` or `floodedRefreshInterval`, chosen by
    /// `adaptRefreshInterval(occupancy:)` at each tick. Internal so
    /// `LogPaneModelTests` can assert WHICH interval a given buffer state
    /// selects, and so `hangprobe` can report it per run — both countable
    /// facts about the policy rather than measurements of how long anything
    /// took.
    ///
    /// `@ObservationIgnored` for a correctness reason, not a performance one:
    /// this is written on every tick INCLUDING ticks that publish nothing, and
    /// an observed write there would invalidate the pane's body on a tick
    /// where not one line arrived — re-rendering 4,200 rows to announce that
    /// the stream went quiet.
    @ObservationIgnored private(set) var activeRefreshInterval: Duration = LogPaneModel.refreshInterval

    /// How many lines the most recent `refreshIfNeeded()` tick folded into
    /// one publication — 0 for a tick that found nothing to publish.
    ///
    /// Test-only seam, same shape and same reasoning as `rowsRecomputeCount`:
    /// "the coalescer folded N lines into one publication" and "the policy
    /// therefore chose interval X" are both COUNTS, and a test that asserted
    /// either by timing a real tick would measure the machine.
    @ObservationIgnored private(set) var linesCoalescedByLastTick = 0

    /// The pane's active filter. A plain stored `var`, same pattern as
    /// `DashboardModel.filter` — the filter bar binds directly to its fields.
    public var filter = LogFilter()

    /// A throttled snapshot of the current stream's lines, oldest first. See
    /// the type's doc comment for why this lags the ring buffer by up to
    /// `activeRefreshInterval` rather than mirroring it exactly.
    ///
    /// `BufferedLine`, not `LogLine`: each carries the sequence number the
    /// buffer stamped it with, which is what gives the `rows` derived from
    /// this snapshot an identity that two byte-identical lines cannot share
    /// (see `BufferedLine` and `LogRow.ID`).
    public private(set) var lines: [BufferedLine] = []

    /// Mirrors `LogBuffer.droppedCount` as of the last refresh — how many
    /// earlier lines were evicted to stay within capacity. `droppedLinesMessage`
    /// turns this into the pane's user-facing copy.
    public private(set) var droppedCount: Int = 0

    /// Whether the pane should keep scrolling to the newest line as more
    /// arrive. Starts `true` on every `follow(_:)` (a freshly opened stream
    /// should show its tail); the view flips it to `false` the instant the
    /// user scrolls away from the bottom (`scrollPositionChanged(isAtBottom:)`)
    /// and back to `true` when they either scroll back down themselves or
    /// tap "Jump to latest" (`jumpToLatest()`). Kept as testable state here,
    /// not inferred inside the view, precisely because "stop following the
    /// moment the user scrolls up" is a decision with an edge case worth
    /// pinning down — see `LogPaneModelTests`.
    public var isFollowing = true

    /// Which JSON blocks (see `rows`) are currently expanded in the pane,
    /// keyed by `LogRow.ID` — see that type's doc comment for exactly what
    /// identity it is and why it deliberately is not the row's index.
    ///
    /// Independent state, same shape as `DashboardModel.collapsedGroups`:
    /// `rows` is re-derived from scratch on every throttled refresh tick
    /// (`refreshIfNeeded()`) and again on every ring-buffer eviction once the
    /// stream passes capacity — neither of those touches this set. Without
    /// that independence, an expanded block would collapse the instant more
    /// lines arrived, which is exactly the bug report this exists to avoid:
    /// a block a user opened to read becoming unusable one tick later.
    public private(set) var expandedBlockIDs: Set<LogRow.ID> = []

    /// Expands `id` if it is currently collapsed, collapses it otherwise —
    /// the INLINE interaction path (a row's disclosure chevron in
    /// `LogPaneView`). Expanding this way pauses auto-follow: see `expand(_:pauseFollowing:)`.
    ///
    /// Contrast `openInDetailPane(_:)`, the detail-pane presentation's own
    /// entry point — both funnel through the same `expand`/`collapse`
    /// helpers below, which is what keeps `focusedBlockID` in sync
    /// regardless of which presentation the user actually clicked in (see
    /// that property's doc comment for why that sync is the whole point).
    public func toggleExpansion(_ id: LogRow.ID) {
        if expandedBlockIDs.contains(id) {
            collapse(id)
        } else {
            expand(id, pauseFollowing: true)
        }
    }

    /// Opens `id` for the detail-pane presentation (`SettingsStore.jsonPresentation
    /// == .detailPane`) — the same underlying "expanded" state `toggleExpansion(_:)`
    /// sets from the inline chevron, but WITHOUT pausing auto-follow.
    ///
    /// That asymmetry is deliberate, not an oversight: inline expansion
    /// inserts the tree into the flowing log itself, resizing it and pushing
    /// everything below off screen the instant it happens — the exact bug
    /// `toggleExpansion(_:)`'s pause exists to prevent. The detail pane
    /// renders the tree in a side panel instead; the log's own flowing
    /// content never changes shape, so there is nothing for a still-tailing
    /// pane to be yanked away from.
    ///
    /// A block opened here also becomes a member of `expandedBlockIDs` — if
    /// the presentation setting is later switched to `.inline`, this same
    /// block should render already expanded there, not collapsed.
    public func openInDetailPane(_ id: LogRow.ID) {
        expand(id, pauseFollowing: false)
    }

    /// Closes whichever block the detail pane currently shows
    /// (`focusedBlockID`). A no-op when nothing is open. Also collapses that
    /// block's inline state — closing the panel is a genuine "I'm done with
    /// this", not merely hiding the side view while leaving it expanded for
    /// `.inline` to surface later.
    public func closeDetailPane() {
        guard let id = focusedBlockID else { return }
        collapse(id)
    }

    /// Whether `id` is currently expanded. A plain `Set` lookup, exposed so
    /// the view doesn't reach into `expandedBlockIDs` directly for a single
    /// membership check.
    public func isExpanded(_ id: LogRow.ID) -> Bool {
        expandedBlockIDs.contains(id)
    }

    /// Which single block, if any, the detail-pane presentation should show
    /// beside the log. Deliberately a second piece of state alongside
    /// `expandedBlockIDs` rather than derived from it — a `Set` has no
    /// "most recent", and the detail pane can only show one block at a time.
    ///
    /// This is the ENTIRE mechanism behind "switching presentation must not
    /// lose state" (the plan's Task 6 Step 3): `LogPaneModel` has no concept
    /// of `JSONPresentation` at all — that enum lives in `SettingsStore`, a
    /// view-level rendering choice `LogPaneView` reads. Both `toggleExpansion(_:)`
    /// (the inline path) and `openInDetailPane(_:)` (the detail-pane path)
    /// funnel through the same `expand(_:pauseFollowing:)` helper and always
    /// set this property, so whichever path the user actually clicked
    /// through, this always names the block the OTHER presentation would
    /// show if the setting were flipped. There is nothing for a presentation
    /// switch to blank out, by construction, because nothing about it is
    /// keyed to which presentation was active when the block was opened.
    public private(set) var focusedBlockID: LogRow.ID?

    /// The `JSONBlock` `focusedBlockID` currently names, looked up from
    /// `rows` — what `JSONDetailPane` actually renders. `nil` both when
    /// nothing is open and (defensively) if the id no longer matches any
    /// current row.
    public var focusedBlock: JSONBlock? {
        guard let focusedBlockID else { return nil }
        for scored in rows {
            guard scored.id == focusedBlockID, case .block(let block, _) = scored.row else { continue }
            return block
        }
        return nil
    }

    private func expand(_ id: LogRow.ID, pauseFollowing: Bool) {
        expandedBlockIDs.insert(id)
        focusedBlockID = id
        if pauseFollowing { isFollowing = false }
    }

    private func collapse(_ id: LogRow.ID) {
        expandedBlockIDs.remove(id)
        if focusedBlockID == id { focusedBlockID = nil }
    }

    /// The current stream's failure, rendered via the same
    /// `tiltActionFailureMessage(for:)` mapping every other tilt-action
    /// failure in this app uses. `nil` while the stream is healthy, or
    /// before one has ever been started.
    public private(set) var streamError: String?

    /// Whether the currently-followed stream's consuming loop has run to
    /// completion — cleanly (the child exited / `finish()`) or via
    /// `streamError`. `false` from the moment `follow(_:)` starts a stream
    /// until that loop actually exits; reset to `false` again by the next
    /// `follow(_:)` call. This is what lets `emptyState` tell "nothing has
    /// arrived YET" (`.waitingForLines`, still normal) apart from "nothing
    /// arrived, and nothing more will" (`.streamEndedWithNoLines`) — both
    /// are "buffer is empty" but only one of them is a dead end.
    public private(set) var hasStreamEnded = false

    public init(streaming: any LogStreaming = LogStreamer(), tail: Int = 2_000, capacity: Int = LogPaneModel.defaultCapacity) {
        self.streaming = streaming
        self.tail = tail
        self.buffer = LogBuffer(capacity: capacity)
    }

    /// Exactly the lines the pane is drawing, flattened out of `rows` and
    /// stripped of row identity — what the filter bar's Copy action puts on
    /// the clipboard.
    ///
    /// DERIVED FROM `rows`, not filtered independently. This used to be its
    /// own pass (`filter.apply(to: lines.map(\.line))`), and that is a second
    /// answer to a question `rows` already answers — which drifted the moment
    /// a filter field arrived that only the row pipeline could express.
    /// `errorsOnly` is exactly that: severity is a property of a ROW (a
    /// serialised `err: { … }` spanning six lines is one failing thing; none
    /// of those six lines is a failure on its own), so the line-based
    /// `LogFilter.apply(to lines:)` cannot apply it and did not. With "Errors
    /// only" on, the pane drew one row and Copy handed over all three lines,
    /// and Copy stayed enabled on a pane the gate had emptied.
    ///
    /// Deriving instead of re-filtering makes that class of divergence
    /// structurally impossible rather than merely fixed: whatever `rows`
    /// keeps, this keeps, for every filter field that exists now or is added
    /// later. It also picks up the row pipeline's grouping — a matched line's
    /// whole block and record — which is what the pane shows and therefore
    /// what "copy the lines currently shown" has always meant, correctly.
    ///
    /// Cheap for the same reason: `rows` is cached, so this is a flatten, not
    /// a second filter pass over the buffer.
    public var filteredLines: [LogLine] {
        rows.flatMap { $0.lines.map(\.line) }
    }

    /// `lines`, grouped into `LogRow`s (`JSONBlock.detect(in:)`), scored by
    /// `SeverityScanner`, and then filtered as rows
    /// (`LogFilter.apply(to rows:)`) — what the pane actually draws once JSON
    /// blocks render as collapsible units.
    ///
    /// `ScoredRow`, not `LogRow`: the severity the pane tints each row with is
    /// computed HERE, once per line snapshot, and travels attached to the row
    /// it describes. See `detectedRows` (where the scan happens) and
    /// `ScoredRow` (why it is one value and not a side table).
    ///
    /// Record grouping (`LogRecord.group`) lives inside
    /// `LogFilter.apply(to rows:)` and therefore inside this same cached
    /// derivation — never a second pass run per SwiftUI read. Grouping needs
    /// a TEXT QUERY: with the search field empty this returns exactly
    /// `JSONBlock.detect(in: lines)` filtered row by row against whatever
    /// level/source/resource is picked, and with nothing picked either, that
    /// is `JSONBlock.detect(in: lines)` itself — the unfiltered pane is not
    /// grouped.
    ///
    /// Detection runs BEFORE filtering, deliberately: grouping the filtered
    /// line list instead would let the query itself strip a block's header
    /// line before detection ever saw it (the header rarely contains the
    /// query text — that's the whole reason the block existed in the first
    /// place), silently reproducing the "search matches a JSON fragment and
    /// loses the line above it" bug this feature exists to fix.
    ///
    /// CACHED, unlike `filteredLines`. SwiftUI reads this several times per
    /// render (the list, the scroll target, the empty-state check), and
    /// recomputing meant re-running `JSONBlock.detect` — an ANSI strip, a
    /// trim, a brace scan and a JSON parse over the whole buffer — for each
    /// of those reads, on the main actor, every frame. At the 5,000-line
    /// capacity that is the same work several times over for an identical
    /// answer.
    ///
    /// The cache is keyed on everything the result derives from, and nothing
    /// else: the `lines` snapshot (via `linesGeneration`, bumped at the only
    /// two sites that assign `lines`) and `filter` (a small `Equatable`
    /// value, compared directly). That is what keeps this from reintroducing
    /// the staleness class of bug removed from this type's resource-health
    /// lookup — the previous version of that bug came from a cache refreshed
    /// on hand-picked events rather than derived from its inputs.
    ///
    /// `lines` and `filter` are read BEFORE the cache check, and deliberately
    /// so: `@Observable` records a dependency only on properties a `body`
    /// actually touches, so a cache hit that skipped reading `lines` would
    /// leave SwiftUI with no dependency on it and the pane would stop
    /// redrawing when new lines arrived. `lines` is now read one level down,
    /// in `detectedRows`, which this getter calls unconditionally and first
    /// for exactly that reason. The cache storage itself is
    /// `@ObservationIgnored` for the mirror-image reason — writing it from
    /// inside a getter would otherwise publish a change during a render.
    public var rows: [ScoredRow] {
        // `detected` first, unconditionally: it is what reads `self.lines`,
        // and that read is the `@Observable` dependency described above. Do
        // not "optimise" it below the cache check.
        let detected = detectedRows
        let filter = self.filter

        if let cached = cachedRows, cached.generation == linesGeneration, cached.filter == filter {
            return cached.rows
        }

        let computed = filter.apply(to: detected)
        rowsRecomputeCount += 1
        cachedRows = (generation: linesGeneration, filter: filter, rows: computed)
        return computed
    }

    /// `lines` detected into rows and SCORED by `SeverityScanner`, with no
    /// filter applied at all — the shared input behind both `rows` and
    /// `errorCount`, cached on the line snapshot alone.
    ///
    /// TWO caches rather than one because they key on different things, and
    /// collapsing them would break one of the two properties that make this
    /// worth having:
    ///
    /// * `rows` keys on the snapshot AND the filter, because it must
    ///   re-filter when the user types.
    /// * Detection and severity key on the snapshot ONLY, because neither
    ///   depends on the filter. Typing a character must not re-run
    ///   `JSONBlock.detect` (an ANSI strip, a trim, a brace scan and a JSON
    ///   parse over the whole buffer) nor re-run `SeverityScanner` over 5,000
    ///   rows. Counted, not timed, by
    ///   `LogPaneModelTests.changingTheFilterDoesNotRescanSeverity`.
    ///
    /// This is also where the plan's "severity must be computed inside the
    /// cached derivation, not per SwiftUI read" is actually enforced: nothing
    /// outside this getter ever calls `SeverityScanner`, so there is no path
    /// by which a view read can provoke a scan.
    ///
    /// Reads `self.lines` into a local BEFORE its own cache check, for the
    /// identical `@Observable` reason `rows` does — see `rows`' doc comment.
    /// A cache hit that skipped that read would leave every caller downstream
    /// of it, `rows` included, with no dependency on `lines`.
    private var detectedRows: [ScoredRow] {
        let lines = self.lines

        if let cached = cachedDetection, cached.generation == linesGeneration {
            return cached.rows
        }

        let computed = JSONBlock.detect(in: lines).map(ScoredRow.init(scoring:))
        detectionRecomputeCount += 1
        cachedDetection = (
            generation: linesGeneration,
            rows: computed,
            // `reduce`, not `count(where:)`: the latter is gated on the Swift
            // 6 standard library, which back-deploys no further than macOS 15
            // — this app's floor is 14.
            errorCount: computed.reduce(into: 0) { total, row in if row.isFailure { total += 1 } }
        )
        return computed
    }

    /// How many rows in the WHOLE buffer are at `.error` or above, ignoring
    /// every filter — what the filter bar shows as "3 errors".
    ///
    /// Unfiltered deliberately. A count that drops to zero because the user
    /// searched for something unrelated is worse than no count at all: it
    /// states, falsely, that the stream is clean. The number the user needs is
    /// "there are failures in here", and that fact does not change when they
    /// type in the search box. `jumpToNextError()` is where the difference
    /// between "there are none" and "yours are hidden" gets reported.
    ///
    /// Rows, not lines: a serialised `err: { … }` spanning six lines is one
    /// failure, and counting its lines would inflate a single crash into six.
    public var errorCount: Int {
        _ = detectedRows
        return cachedDetection?.errorCount ?? 0
    }

    /// Bumped at every site that assigns `lines`, and used as that snapshot's
    /// cache key. An identity counter rather than comparing the arrays: the
    /// point of the cache is to avoid O(buffer) work per read, which an
    /// array-equality check would put straight back.
    @ObservationIgnored private var linesGeneration = 0
    @ObservationIgnored private var cachedRows: (generation: Int, filter: LogFilter, rows: [ScoredRow])?
    @ObservationIgnored
    private var cachedDetection: (generation: Int, rows: [ScoredRow], errorCount: Int)?

    /// Test-only seam: how many times `rows` has actually run
    /// `LogFilter.apply` rather than answering from its cache. Exists so
    /// `LogPaneModelTests` can assert the caching by COUNTING invocations —
    /// four wall-clock bounds on this project have already been replaced by
    /// deterministic assertions after flaking or failing to discriminate, and
    /// a timing test here would measure the machine, not the cache.
    @ObservationIgnored private(set) var rowsRecomputeCount = 0

    /// Test-only seam alongside `rowsRecomputeCount`: how many times
    /// `JSONBlock.detect` + `SeverityScanner` have actually run.
    ///
    /// A separate counter because the two caches answer different questions
    /// and a single number cannot tell them apart. "Severity is computed
    /// inside the cached derivation" is a claim about THIS counter staying
    /// put while `rowsRecomputeCount` moves.
    @ObservationIgnored private(set) var detectionRecomputeCount = 0

    /// "N earlier lines dropped", or `nil` when nothing has been evicted yet.
    /// Exists so truncation is always stated, never left to look like a
    /// complete history — see `LogBuffer.droppedCount`'s own doc comment.
    public var droppedLinesMessage: String? {
        guard droppedCount > 0 else { return nil }
        return "\(droppedCount) earlier \(droppedCount == 1 ? "line" : "lines") dropped"
    }

    /// Which control(s) are keeping a `.filteredOut` empty pane empty — see
    /// `EmptyState.filteredOut(_:)`. An `OptionSet` rather than one enum case
    /// per combination: the four controls combine independently (any subset
    /// can be active at once), and `LogPaneView` needs to name every member
    /// that's set, not just the "worst" one.
    public struct FilterCause: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// `filter.resource` is set — the table-row scope
        /// (`DashboardModel.selectedResourceName`, the "Scoped to …" chip).
        public static let resourceScope = FilterCause(rawValue: 1 << 0)
        /// `filter.query` is non-blank (`LogFilter.hasTextQuery`).
        public static let textQuery = FilterCause(rawValue: 1 << 1)
        /// `filter.source` is set. There is deliberately no level-based
        /// member — `LogFilter` carries no `minimumLevel` field; see that
        /// type's doc comment for why the control was removed rather than
        /// kept non-functional.
        public static let source = FilterCause(rawValue: 1 << 2)
        /// `filter.errorsOnly` is set. The severity gate is the one control
        /// that can empty a pane full of perfectly healthy lines — which is
        /// exactly when it must name itself, or "no lines match the current
        /// filter" reads as the app having lost the stream.
        public static let errorsOnly = FilterCause(rawValue: 1 << 3)
    }

    /// Every distinct reason the pane can have nothing to draw — the DECISION
    /// half of the empty-state fix; `LogPaneView` only turns a case into copy,
    /// never re-derives which one applies. That split matters here
    /// specifically because the pane's founding bug report was a user reading
    /// a correct-but-silent blank region as "the app is broken": a resource
    /// scoped to `(Tiltfile)`, which genuinely emits zero lines, looked
    /// indistinguishable from a hung stream. Four cases, four different ways
    /// out, and — per `emptyState`'s doc comment — a fixed precedence so the
    /// four can never be confused for each other on the one input shape where
    /// several of them look simultaneously true.
    public enum EmptyState: Equatable, Sendable {
        /// Nothing is being followed at all — no instance selected, or the
        /// selected project isn't running. See `isFollowingAnInstance`.
        case notFollowing
        /// Following an instance; its stream is still open; the buffer has
        /// not received a single line yet. Normal for a few hundred ms after
        /// `follow(_:)` — this must read as "waiting", not "empty".
        case waitingForLines
        /// The stream ended — cleanly or via `streamError` — having produced
        /// no lines at all. `streamError`'s own banner already states the
        /// failure, if there was one; this case's copy must not repeat it,
        /// only that the stream is no longer live and nothing came through.
        case streamEndedWithNoLines
        /// At least one line has arrived, but every one of them is currently
        /// excluded — by the resource scope, the text query, the source
        /// filter, the severity gate, or several of those at once (`cause`
        /// names exactly which).
        case filteredOut(FilterCause)
    }

    /// The pane's current empty-state DECISION, or `nil` when there is at
    /// least one row to draw (`rows` is non-empty) — mirrors
    /// `DashboardModel.emptyState`'s own "non-nil exactly when the thing the
    /// view actually draws from is empty" contract, gated on `rows` rather
    /// than `lines` for the identical reason: `rows` is what `LogPaneView`
    /// renders, so this can never say "here's why it's empty" while the view
    /// draws content, or vice versa.
    ///
    /// PRECEDENCE, deliberately fixed rather than inferred from whichever
    /// condition a caller happens to check first:
    ///
    /// 1. `.notFollowing` — checked before anything else, because none of the
    ///    other three questions ("has a line arrived", "did a filter exclude
    ///    it") mean anything when there is no stream to ask them about.
    /// 2. `.waitingForLines` / `.streamEndedWithNoLines` — checked next,
    ///    together, ahead of the filter check: both answer "is `lines`
    ///    itself empty", i.e. the RAW buffer before any filtering. This is
    ///    the precedence THE TRAP is about — with zero lines in the buffer,
    ///    every active filter field is trivially "excluding everything" too
    ///    (an empty set matches no filter), so a naive check of "is a filter
    ///    active" first would misreport a stream that simply hasn't produced
    ///    output yet as one whose filter is the problem. Gating on `lines`
    ///    before ever inspecting `filter` makes that misattribution
    ///    structurally impossible, not just unlikely.
    /// 3. `.filteredOut(cause)` — reached only once `lines` is confirmed
    ///    non-empty, so by construction this case never fires on a genuinely
    ///    empty buffer.
    ///
    /// `cause` lists every currently-active filter field, not only whichever
    /// one a line-by-line trace would show as the actual culprit: the four
    /// controls AND together, so with two active, clearing either alone might
    /// restore matches — the message must not blame only one when both are
    /// live, which is the other half of the trap this precedence is written
    /// against.
    public var emptyState: EmptyState? {
        guard rows.isEmpty else { return nil }

        guard isFollowingAnInstance else { return .notFollowing }

        guard !lines.isEmpty else {
            return hasStreamEnded ? .streamEndedWithNoLines : .waitingForLines
        }

        var cause: FilterCause = []
        if filter.resource != nil { cause.insert(.resourceScope) }
        if filter.hasTextQuery { cause.insert(.textQuery) }
        if filter.source != nil { cause.insert(.source) }
        if filter.errorsOnly { cause.insert(.errorsOnly) }
        return .filteredOut(cause)
    }

    /// Points the pane at `instance`'s stream, replacing whatever it was
    /// previously following. `nil` stops streaming entirely (nothing
    /// selected, or the selected project isn't running).
    ///
    /// A no-op when `instance` is already the one being followed — the view
    /// is expected to call this on every render where the selection *might*
    /// have changed (see the type's doc comment), and restarting an
    /// unchanged stream would otherwise drop the buffer and flicker the pane
    /// on every unrelated re-render.
    public func follow(_ instance: TiltInstance?) {
        guard instance?.id != currentInstanceID else { return }
        currentInstanceID = instance?.id

        // Dropped, not merely cancelled: from this line on, everything the
        // outgoing session's tasks might still do is a no-op (`ifCurrent`),
        // whether or not they ever notice the cancellation.
        session?.cancel()
        session = nil
        buffer = LogBuffer(capacity: buffer.capacity)
        lines = []
        linesGeneration += 1
        droppedCount = 0
        streamError = nil
        hasStreamEnded = false
        isFollowing = true
        // Back to the fast interval, and with no arrivals credited to the
        // outgoing stream. This is one of only two things that lower
        // occupancy — the fresh `LogBuffer` above holds nothing; the other is
        // `setCapacity(_:)` — and between them the reason
        // `adaptRefreshInterval(occupancy:)` can be a pure function of an
        // input that never oscillates. Set here rather than left to
        // the next tick so the pane's first tick after a switch is the
        // responsive one, whatever the instance being left behind was doing.
        pendingLineCount = 0
        linesCoalescedByLastTick = 0
        activeRefreshInterval = Self.refreshInterval
        expandedBlockIDs = []
        focusedBlockID = nil
        // Sequence numbers restart with the new buffer, so a retained target
        // from the old stream would make the next jump compare this stream's
        // ids against another stream's — and land somewhere arbitrary.
        // `errorJumpGeneration` deliberately is NOT reset: it is a monotonic
        // "a jump happened" tick the view watches, and rewinding it to 0 is
        // indistinguishable from never having jumped.
        focusedErrorID = nil

        guard let instance else { return }

        // Built synchronously, here, rather than inside the `Task` below.
        // `LogStreaming.stream(instance:tail:)` is documented to do its real
        // work (spawn the child, in `LogStreamer`'s case) the moment it's
        // called, not lazily on first await — so the stream must exist
        // before `follow(_:)` returns. A `Task { }`'s body does not start
        // running the instant it's created, only when the executor gets to
        // it; calling `stream(...)` inside that closure left a window where
        // a caller who pushed a line (or ended the stream) immediately after
        // `follow(_:)` returned raced ahead of the subscription ever being
        // registered, and that push or end was silently lost — for a clean
        // `finish()` lost that way, the consuming loop below then awaits a
        // signal that will never arrive again. `LogPaneModelTests` hung on
        // exactly this before the fix moved the call out here.
        let lineStream = streaming.stream(instance: instance, tail: tail)

        let session = StreamSession()
        self.session = session

        session.streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await streamedLine in lineStream {
                    // One check, doing both jobs — the write is gated, and a
                    // superseded stream's backlog stops being walked. It is
                    // deliberately NOT `Task.isCancelled`: cancellation does
                    // not stop delivery on its own (measured — an already-
                    // cancelled iterator was still handed all three of its
                    // stream's buffered elements), and a task can be stale
                    // without ever having been cancelled.
                    guard self.isCurrent(session) else { break }
                    self.receive(streamedLine)
                }
            } catch {
                self.ifCurrent(session) { self.streamError = tiltActionFailureMessage(for: error) }
            }
            // The stream ended (clean or failed) — the periodic loop below has
            // nothing left to coalesce, but whatever arrived since its last
            // tick still needs to reach `lines` once.
            self.ifCurrent(session) {
                session.flushTask?.cancel()
                self.refreshIfNeeded()
                // Set AFTER the final `refreshIfNeeded()`, not before: `emptyState`
                // must never observe "ended" with lines still sitting unflushed in
                // the buffer, which would read as `.streamEndedWithNoLines` for a
                // stream that in fact produced output.
                self.hasStreamEnded = true
            }
        }

        session.flushTask = Task { [weak self] in
            while !Task.isCancelled {
                // Re-read per iteration, not hoisted: this is the entire
                // mechanism by which `adaptRefreshInterval(occupancy:)`
                // takes effect. A switch therefore lands on the tick AFTER
                // the one that decided it, which is as it should be — the
                // decision is made from a tick that has already elapsed.
                guard let interval = self?.activeRefreshInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.ifCurrent(session) { self.refreshIfNeeded() }
            }
        }
    }

    /// The ONLY channel from a stream's async work back into this pane's
    /// state: `mutate` runs if and only if `session` is still the session
    /// `follow(_:)` last installed.
    ///
    /// The guard is placed here, once, rather than at each of the five writes
    /// a stream task can perform (`receive`, `streamError`, `flushTask.cancel`,
    /// `refreshIfNeeded`, `hasStreamEnded`) because the failure mode is
    /// *forgetting one* — which is precisely what shipped: three of the five
    /// were not guarded at all, and the two that were used `Task.isCancelled`,
    /// which the loop's own normal exit walks straight past. `streamTask`
    /// and `flushTask` are no longer fields on the model either, so a stale
    /// task has nothing to reach for even by accident; it can only reach its
    /// OWN session's tasks, and only inside this method.
    ///
    /// Not taken further — the whole stream lifecycle moved out into a
    /// separate owned object — deliberately: the state these mutations touch
    /// (`lines`, `droppedCount`, `streamError`, `hasStreamEnded`) is exactly
    /// what SwiftUI observes on this type, so relocating it would mean either
    /// splitting the pane's observable surface across two objects or copying
    /// it back, and a copy that has to be kept in sync is the staleness bug
    /// this project has already fixed once (see `rows`' cache doc comment).
    private func ifCurrent(_ session: StreamSession, _ mutate: () -> Void) {
        guard isCurrent(session) else { return }
        mutate()
    }

    /// Whether `session` is still the one `follow(_:)` last installed — the
    /// single fact every guard above is written against.
    private func isCurrent(_ session: StreamSession) -> Bool {
        session === self.session
    }

    /// Copies the buffer's current lines out to `lines` when — and only
    /// when — something has actually been appended since the last call, and
    /// re-decides how long the flush loop should sleep before the next tick.
    /// Called by `follow(_:)`'s internal timer; also callable directly,
    /// which is how `LogPaneModelTests` proves the coalescing behaviour
    /// deterministically instead of racing a real timer.
    ///
    /// The interval decision sits BEFORE the "is there anything to publish"
    /// guard, and — stated plainly because the previous version of this
    /// comment claimed otherwise and was wrong — that placement is currently
    /// UNOBSERVABLE. Moving it below the guard changes no behaviour and
    /// breaks no test, verified by mutation. It could not be otherwise: the
    /// policy's input is `buffer.count`, and the only two things that change
    /// it are an append (which sets `pendingLineCount`, so such a tick
    /// publishes) and `setCapacity(_:)` (which re-decides the interval
    /// itself, for its own reasons, before any tick runs). So a tick that
    /// publishes nothing is a tick whose decision cannot differ from the last
    /// one's.
    ///
    /// It stays here anyway, as a statement about what kind of thing this is:
    /// the interval is a function of the model's STATE, not of what happened
    /// in one tick, and a reader should not have to infer that from where the
    /// call sits relative to an early return. When the input was per-tick
    /// arrivals this placement WAS load-bearing, which is exactly why leaving
    /// the old justification in place would have been a lie by inheritance.
    public func refreshIfNeeded() {
        let coalesced = pendingLineCount
        pendingLineCount = 0
        linesCoalescedByLastTick = coalesced
        adaptRefreshInterval(occupancy: buffer.count)

        guard coalesced > 0 else { return }
        lines = buffer.lines
        linesGeneration += 1
        droppedCount = buffer.droppedCount
    }

    /// Changes how many lines this pane keeps, LIVE — mid-stream, with no
    /// relaunch and without restarting anything. A no-op at the current
    /// capacity. Driven by `SettingsStore.logScrollback` through
    /// `DashboardModel.applyLogScrollbackSetting()`.
    ///
    /// THE STREAM IS NOT RESTARTED, and that is the whole design constraint
    /// rather than an optimisation. `session`, its `streamTask` and its
    /// `flushTask` are untouched; `currentInstanceID` is untouched; no new
    /// `tilt logs --follow` child is spawned. The obvious alternative —
    /// rebuilding the model, or calling `follow(_:)` again — would blank the
    /// pane, drop every line the user had scrolled back through, restart the
    /// sequence numbering (and with it every expanded block), and cost a
    /// fresh `--tail 2000` replay. A preference that throws away your
    /// scrollback in order to change how much scrollback you keep is a
    /// regression wearing a feature's clothes.
    ///
    /// WHAT SURVIVES, and why each one does:
    ///
    /// * **The lines themselves, most-recent-first on a shrink.** See
    ///   `LogBuffer.resize(to:)`. A shrink is precisely the eviction that
    ///   appending would have done anyway, brought forward.
    /// * **`droppedCount`, truthfully.** Published here rather than left to
    ///   the next tick, so `droppedLinesMessage` can never state a smaller
    ///   number than the count of lines actually discarded — not even for the
    ///   one tick it would take to catch up.
    /// * **Auto-follow (`isFollowing`) and the user's scroll position.**
    ///   Neither is reset. A user reading something 800 lines up is still
    ///   reading it afterwards, provided it survived the shrink; if it did
    ///   not, the list has nothing left to anchor to and jumps, which is the
    ///   unavoidable cost of asking for a smaller buffer and is stated in the
    ///   setting's own copy.
    /// * **`expandedBlockIDs` and `focusedBlockID`.** Keyed by `LogRow.ID`,
    ///   i.e. sequence numbers, which `LogBuffer.resize(to:)` preserves. Not
    ///   pruned of ids whose rows a shrink evicted, for the same reason
    ///   ordinary eviction does not prune them: `expandedBlockIDs` is
    ///   deliberately independent of `rows`, and `focusedBlock` already
    ///   resolves a vanished id to `nil`.
    /// * **`focusedErrorID`.** Also a sequence number, and
    ///   `jumpToNextError()` searches for the first failing row *after* it —
    ///   which stays well defined even when the row it names has been
    ///   evicted. The cursor keeps its place in the stream rather than
    ///   rewinding to the top.
    ///
    /// `pendingLineCount` is zeroed because this call publishes everything
    /// the buffer holds: its meaning is "arrivals not yet reflected in
    /// `lines`", and after the assignment above there are none.
    /// `linesCoalescedByLastTick` is deliberately left alone — this is not a
    /// tick, and overwriting it would misreport what the last one folded.
    public func setCapacity(_ newCapacity: Int) {
        guard newCapacity != buffer.capacity else { return }
        buffer.resize(to: newCapacity)

        lines = buffer.lines
        linesGeneration += 1
        droppedCount = buffer.droppedCount
        pendingLineCount = 0
        // A shrink is the ONE thing besides `follow(_:)` that lowers
        // occupancy, so the interval has to be re-decided here — see
        // `adaptRefreshInterval(occupancy:)`. Shrinking below
        // `floodedOccupancy` must give the fast interval back immediately,
        // not at some later tick: choosing a smaller buffer to get the pane's
        // responsiveness back and then waiting 500ms for the next tick to
        // notice is the same broken promise one step smaller.
        adaptRefreshInterval(occupancy: buffer.count)
    }

    /// The capacity the pane is currently keeping — what
    /// `setCapacity(_:)` last set, or the one it was built with. Exposed so
    /// `DashboardModel` and `LogPaneModelTests` can assert the wiring
    /// actually took, rather than inferring it from how many lines happen to
    /// have arrived.
    public var capacity: Int { buffer.capacity }

    /// Picks the interval the NEXT tick will wait, from how many lines the
    /// buffer is holding.
    ///
    /// OCCUPANCY, not arrival rate, and that distinction is the whole point.
    /// Everything this model does per publication — the `buffer.lines` copy,
    /// `JSONBlock.detect`, `SeverityScanner`, `LogFilter` — is O(occupancy),
    /// and so is the `ForEach` identity enumeration downstream of it. The
    /// publication rate, meanwhile, is nearly INDEPENDENT of how fast lines
    /// arrive: `occupancy-hypothesis.md` measured 5.93, 6.47, 6.24 and 6.25
    /// publications/sec at 6, 50, 500 and 1,200 lines/sec — a 5% spread across
    /// a 200x change in arrival rate, because a coalescer that publishes on a
    /// timer publishes on a timer. So `passes/sec x cost/pass` is very nearly
    /// `constant x occupancy`, and occupancy is the only term in it that a
    /// slow stream ever moves.
    ///
    /// This replaced a lines-per-tick rule (`floodedTickLineCount = 133`) that
    /// shipped in aa38437 and was measured, afterwards, to buy **+0.1 points
    /// at 6 lines/sec and −0.5 at 50** — nothing, on the only workload that
    /// matters, because the developer's real stream is 6.4 lines/sec and never
    /// came close to tripping it. Occupancy buys **+15.5 points at that same 6
    /// lines/sec** (73.9% → 89.4%, Result 4) and gives up nothing at flood,
    /// because a flooding stream fills the buffer within seconds and trips
    /// this instead.
    ///
    /// A PURE FUNCTION of occupancy, with one threshold rather than the two
    /// the lines-per-tick rule needed, and that is a deliberate reduction
    /// rather than a lost safeguard. Two thresholds existed to stop an input
    /// that jitters from flapping the interval. Occupancy does not jitter: it
    /// is monotonically non-decreasing for as long as a stream runs at a
    /// fixed capacity (`LogBuffer` only ever appends, and at capacity holds).
    /// Exactly two things lower it, and NEITHER can flap:
    ///
    /// * `follow(_:)` installing a fresh buffer, which resets this to the
    ///   fast interval explicitly and by name.
    /// * `setCapacity(_:)` shrinking the buffer, which likewise re-decides
    ///   this itself. Its input is `SettingsStore.logScrollback` — a value
    ///   only a human picking a menu item changes, at human speed and by an
    ///   explicit act, which is the opposite of the oscillating signal
    ///   hysteresis exists to damp.
    ///
    /// A second threshold here would therefore still be a branch no stream
    /// can reach, and the only test that could cover it would be one
    /// asserting a state the app cannot produce. The anti-oscillation
    /// property remains structural, which is strictly stronger than a
    /// hysteresis band.
    ///
    /// Counts, never a clock. Occupancy is an integer `LogBuffer` already
    /// maintains; nothing here measures, infers, or corrects for elapsed time.
    ///
    /// What the user gives up: once the buffer fills, the pane lags up to
    /// 500ms behind the stream — for this developer, from ~13 minutes after
    /// the pane opens, permanently. At 6 lines/sec that is ~3 lines appearing
    /// twice a second instead of 1 line appearing six times a second.
    /// Auto-follow, scroll position, text selection, block expansion and
    /// jump-to-next-error are all untouched. **No report has measured
    /// perception**, and that judgement is the developer's, not the harness's.
    private func adaptRefreshInterval(occupancy: Int) {
        activeRefreshInterval = occupancy >= Self.floodedOccupancy
            ? Self.floodedRefreshInterval
            : Self.refreshInterval
    }

    /// Resumes following after the user has scrolled away — either because
    /// they scrolled back to the bottom themselves (`scrollPositionChanged`)
    /// or tapped the pane's "Jump to latest" affordance.
    public func jumpToLatest() {
        isFollowing = true
    }

    // MARK: - Jump to next error

    /// What one `jumpToNextError()` did. A typed DECISION, not copy —
    /// `LogFilterBarView` turns a case into words, exactly as it does for
    /// `EmptyState`, so which case applies stays testable here and only the
    /// wording lives in the view.
    ///
    /// The two "nowhere to go" cases are separate on purpose, and that
    /// separation is the point of the whole type. Returning `Bool`, or
    /// returning `nil`, would collapse "this stream has no failures in it"
    /// into "your filter is hiding the three failures the count beside this
    /// button is advertising" — and the second one, reported as the first,
    /// reads as the button being broken. This project's single recurring
    /// failure mode is an action that reports success while doing nothing
    /// (`NSApp.sendAction` returning true, an asset catalog dropping an icon
    /// set on a green build, `notarytool` exiting 0 on a rejection); an action
    /// that cannot express "I did nothing, and here is which nothing" is the
    /// same shape one step earlier.
    public enum ErrorJump: Equatable, Sendable {
        /// Moved forward to the next failing row after the previous target.
        case moved(to: LogRow.ID)
        /// Ran off the end and came back to the first failing row. Distinct
        /// from `.moved` so "wrapping is real" is a claim a test can make —
        /// see `jumpToNextErrorWrapsAndReportsWhenThereAreNone`.
        case wrapped(to: LogRow.ID)
        /// The buffer holds no failing row at all. Nothing is hidden; there is
        /// nothing to hide.
        case noErrorsInBuffer
        /// The buffer holds `errorCount` failing rows and the active filter
        /// excludes every one of them.
        case everyErrorFilteredOut(errorCount: Int)
    }

    /// The row `jumpToNextError()` last landed on, and the row the next call
    /// searches forward from. `nil` before the first jump, and reset by
    /// `follow(_:)` along with the rest of the pane's per-stream state.
    public private(set) var focusedErrorID: LogRow.ID?

    /// Bumped once per jump that LANDS somewhere. The view scrolls on this
    /// changing rather than on `focusedErrorID` changing, because those are
    /// different events: with exactly one failing row on screen, every jump
    /// wraps back onto the same id, so `focusedErrorID` never changes and an
    /// `onChange` watching it would scroll once and then sit there while the
    /// user clicked — a silent no-op wearing a working button's clothes.
    public private(set) var errorJumpGeneration = 0

    /// Moves to the next row at `.error` or above, wrapping to the first once
    /// past the last, and REPORTS when there is nowhere to go.
    ///
    /// Searches the rows the pane is actually drawing (`rows`), not the whole
    /// buffer: a jump that scrolled to a row the current filter excludes would
    /// scroll to nothing at all. When the filter excludes every failing row the
    /// result says so, naming the count, so the view can tell the user their
    /// filter is what is in the way rather than leaving the button dead.
    ///
    /// Stops following. Auto-scroll would otherwise drag the user back to the
    /// tail on the next refresh tick, which is the same "yanked away
    /// from what you were reading" bug `toggleExpansion(_:)` pauses following
    /// to avoid.
    @discardableResult
    public func jumpToNextError() -> ErrorJump {
        let failing = rows.filter(\.isFailure).map(\.id)

        guard !failing.isEmpty else {
            let total = errorCount
            return total == 0 ? .noErrorsInBuffer : .everyErrorFilteredOut(errorCount: total)
        }

        // Ordered by sequence because `rows` is (the buffer is oldest-first
        // and detection partitions it in order), so "the next one" is the
        // first id whose sequence is greater than the current target's. Not
        // an index into `rows`: the array is rebuilt on every refresh tick and
        // on every eviction, and an index survives neither — the same reason
        // `LogRow.ID` is a sequence number rather than a position.
        let next = focusedErrorID.flatMap { current in
            failing.first { $0.sequence > current.sequence }
        }
        // Having never jumped is not having wrapped. The first jump of a
        // session lands on the first failing row going forwards, and calling
        // that `.wrapped` would put "wrapped to the first error" in front of a
        // user who had not been anywhere yet.
        let didWrap = focusedErrorID != nil && next == nil

        let target = next ?? failing[0]
        focusedErrorID = target
        errorJumpGeneration += 1
        isFollowing = false

        return didWrap ? .wrapped(to: target) : .moved(to: target)
    }

    /// The view's sole hook for the auto-scroll decision: reports whether
    /// the visible scroll region is currently at (or effectively at) the
    /// bottom. Scrolling away stops following immediately; scrolling back
    /// resumes it — nothing about "the user is mid-read" is inferred beyond
    /// that position, on purpose, so the rule stays exactly the one users
    /// judge a log pane by: never yank them back down while they're reading
    /// somewhere else.
    public func scrollPositionChanged(isAtBottom: Bool) {
        isFollowing = isAtBottom
    }

    /// Appends into the ring buffer and counts the line towards the next
    /// throttled snapshot. Internal rather than private: `@testable import` uses this to drive
    /// ingestion directly and deterministically, the same test-seam shape as
    /// `LogFilter.CompilationCounter` — awaiting the real stream task would
    /// otherwise make throttling tests race the consumer instead of
    /// asserting on it.
    func receive(_ line: LogLine) {
        buffer.append(line)
        pendingLineCount += 1
    }

    /// Test-only seam: the task currently draining the active stream, so
    /// tests can `await` its completion deterministically (`.value`) instead
    /// of polling or sleeping for a background consumer to catch up.
    var streamTaskForTesting: Task<Void, Never>? { session?.streamTask }

    /// Test-only seam alongside `streamTaskForTesting`: the throttled-refresh
    /// loop behind the CURRENT session. A test asserting "the new stream's
    /// flush loop is still alive" needs the loop itself, not a symptom of it —
    /// the regression this exists for made `lines` stop updating precisely
    /// because a superseded stream cancelled this task.
    var flushTaskForTesting: Task<Void, Never>? { session?.flushTask }

    /// Whether the pane is currently pointed at an instance — `true` from
    /// the moment `follow(_:)` was last called with a non-nil instance,
    /// until `follow(nil)` is called.
    ///
    /// `DashboardModel` reads this before re-pointing the pane at whatever
    /// is now selected (an explicit sidebar pick, or discovery reconciling
    /// the live instance set): re-pointing an already-active pane is
    /// correct, but *starting* one on its own the first time is not this
    /// class's call to make — that belongs to the dashboard window actually
    /// being open, which is what `LogPaneView`'s own
    /// `onChange(..., initial: true)` represents. Without this guard, a
    /// discovery tick would start a `tilt logs --follow` child for whatever
    /// instance happens to be selected the moment it first appears, even if
    /// the dashboard window has never been opened.
    public var isFollowingAnInstance: Bool { currentInstanceID != nil }

    /// The instance `follow(_:)` last pointed the stream at, or `nil` before
    /// the first call (or after `follow(nil)`). Read by
    /// `DashboardModel.followSelectedInstanceLogs()` to tell a genuine
    /// change of followed instance apart from a no-op re-resolution to the
    /// same one — see that method's doc comment for why the distinction
    /// matters.
    public var currentlyFollowedInstanceID: TiltInstance.InstanceID? { currentInstanceID }
}
