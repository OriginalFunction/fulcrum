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
/// `refreshInterval`) rather than on every incoming line — appended lines
/// sit in the ring buffer, marked `dirty`, until the next tick coalesces
/// however many arrived into one copy.
@Observable
@MainActor
public final class LogPaneModel {
    /// Matches `LogBuffer`'s own default — see its doc comment for why 5,000
    /// is the chosen ceiling.
    public static let defaultCapacity = 5_000

    /// How often a live stream's accumulated lines are copied out of the
    /// ring buffer into `lines`. 150ms coalesces roughly 180 lines per
    /// refresh at the measured worst-case rate — frequent enough to feel
    /// live, far short of the per-line copy that does not survive that rate.
    static let refreshInterval: Duration = .milliseconds(150)

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
    /// Set on every append, cleared by `refreshIfNeeded()` — the coalescing
    /// flag that makes the buffer-to-`lines` copy a per-tick cost instead of
    /// a per-line one.
    private var dirty = false

    /// The pane's active filter. A plain stored `var`, same pattern as
    /// `DashboardModel.filter` — the filter bar binds directly to its fields.
    public var filter = LogFilter()

    /// A throttled snapshot of the current stream's lines, oldest first. See
    /// the type's doc comment for why this lags the ring buffer by up to
    /// `refreshInterval` rather than mirroring it exactly.
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
    /// a block a user opened to read becoming unusable 150ms later.
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
        for row in rows {
            guard row.id == focusedBlockID, case .block(let block, _) = row else { continue }
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

    /// `lines` with the active `filter` applied — what the pane actually
    /// draws. Computed, not cached: `LogFilter.apply(to:)` already compiles
    /// its regex once per call rather than once per line, so recomputing
    /// this on every access (each keystroke, each refresh tick) stays cheap
    /// at the buffer's scale.
    ///
    /// Returns bare `LogLine`s: this is the flat, ungrouped view (the filter
    /// bar's Copy action and its empty-state check), and nothing reading it
    /// needs a row identity — that is `rows`' job.
    public var filteredLines: [LogLine] {
        filter.apply(to: lines.map(\.line))
    }

    /// `lines`, grouped into `LogRow`s (`JSONBlock.detect(in:)`) and then
    /// filtered as rows (`LogFilter.apply(to rows:)`) — what the pane
    /// actually draws once JSON blocks render as collapsible units.
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
    /// `lines` and `filter` are read into locals BEFORE the cache check, and
    /// deliberately so: `@Observable` records a dependency only on properties
    /// a `body` actually touches, so a cache hit that skipped reading `lines`
    /// would leave SwiftUI with no dependency on it and the pane would stop
    /// redrawing when new lines arrived. The cache storage itself is
    /// `@ObservationIgnored` for the mirror-image reason — writing it from
    /// inside a getter would otherwise publish a change during a render.
    public var rows: [LogRow] {
        let lines = self.lines
        let filter = self.filter

        if let cached = cachedRows, cached.generation == linesGeneration, cached.filter == filter {
            return cached.rows
        }

        let computed = filter.apply(to: JSONBlock.detect(in: lines))
        rowsRecomputeCount += 1
        cachedRows = (generation: linesGeneration, filter: filter, rows: computed)
        return computed
    }

    /// Bumped at every site that assigns `lines`, and used as that snapshot's
    /// cache key. An identity counter rather than comparing the arrays: the
    /// point of the cache is to avoid O(buffer) work per read, which an
    /// array-equality check would put straight back.
    @ObservationIgnored private var linesGeneration = 0
    @ObservationIgnored private var cachedRows: (generation: Int, filter: LogFilter, rows: [LogRow])?

    /// Test-only seam: how many times `rows` has actually run
    /// `JSONBlock.detect` + `LogFilter.apply` rather than answering from its
    /// cache. Exists so `LogPaneModelTests` can assert the caching by
    /// COUNTING invocations — four wall-clock bounds on this project have
    /// already been replaced by deterministic assertions after flaking or
    /// failing to discriminate, and a timing test here would measure the
    /// machine, not the cache.
    @ObservationIgnored private(set) var rowsRecomputeCount = 0

    /// "N earlier lines dropped", or `nil` when nothing has been evicted yet.
    /// Exists so truncation is always stated, never left to look like a
    /// complete history — see `LogBuffer.droppedCount`'s own doc comment.
    public var droppedLinesMessage: String? {
        guard droppedCount > 0 else { return nil }
        return "\(droppedCount) earlier \(droppedCount == 1 ? "line" : "lines") dropped"
    }

    /// Which control(s) are keeping a `.filteredOut` empty pane empty — see
    /// `EmptyState.filteredOut(_:)`. An `OptionSet` rather than one enum case
    /// per combination: the three controls combine independently (any subset
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
        /// filter, or several of those at once (`cause` names exactly
        /// which).
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
    /// one a line-by-line trace would show as the actual culprit: the three
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
        dirty = false
        expandedBlockIDs = []
        focusedBlockID = nil

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
                try? await Task.sleep(for: Self.refreshInterval)
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
    /// when — something has actually been appended since the last call.
    /// Called by `follow(_:)`'s internal timer; also callable directly,
    /// which is how `LogPaneModelTests` proves the coalescing behaviour
    /// deterministically instead of racing a real timer.
    public func refreshIfNeeded() {
        guard dirty else { return }
        lines = buffer.lines
        linesGeneration += 1
        droppedCount = buffer.droppedCount
        dirty = false
    }

    /// Resumes following after the user has scrolled away — either because
    /// they scrolled back to the bottom themselves (`scrollPositionChanged`)
    /// or tapped the pane's "Jump to latest" affordance.
    public func jumpToLatest() {
        isFollowing = true
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

    /// Appends into the ring buffer and marks the throttled snapshot dirty.
    /// Internal rather than private: `@testable import` uses this to drive
    /// ingestion directly and deterministically, the same test-seam shape as
    /// `LogFilter.CompilationCounter` — awaiting the real stream task would
    /// otherwise make throttling tests race the consumer instead of
    /// asserting on it.
    func receive(_ line: LogLine) {
        buffer.append(line)
        dirty = true
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
