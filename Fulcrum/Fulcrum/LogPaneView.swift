import SwiftUI
import FulcrumKit

/// `HH:mm:ss`, local time — shared with `LogFilterBarView`'s Copy action so
/// what's copied matches what's on screen.
enum LogTimeFormat {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// The log pane: `LogFilterBarView` above a scrolling, auto-following list of
/// `dashboard.logPane.filteredLines`.
///
/// Owns none of the streaming or filtering logic — that's all
/// `LogPaneModel`, in `FulcrumKit`, where it's tested. This view is the
/// "untestable half" `ResourceTableView`'s own doc comment describes: layout,
/// `AttributedString` colouring, and the scroll-position plumbing that feeds
/// `LogPaneModel.scrollPositionChanged(isAtBottom:)`.
struct LogPaneView: View {
    @Bindable var dashboard: DashboardModel
    let settings: SettingsStore

    /// The sentinel row's stable id — `LazyVStack`'s trailing marker, both
    /// what `scrollTo` targets and what `onAppear`/`onDisappear` watch to
    /// decide whether the visible region currently includes the bottom.
    private static let bottomID = "log-pane-bottom"

    private var pane: LogPaneModel { dashboard.logPane }

    var body: some View {
        VStack(spacing: 0) {
            LogFilterBarView(pane: pane, dashboard: dashboard)
            LogColumnHeaderView()
            if let message = pane.droppedLinesMessage {
                banner(systemImage: "xmark.bin", text: message)
            }
            if let error = pane.streamError {
                banner(systemImage: "exclamationmark.triangle", text: "Log stream ended: \(error)")
            }
            HStack(spacing: 0) {
                content
                // Task 6: the detail-pane presentation. Gated on the
                // SETTING here, in the view — `LogPaneModel` itself has no
                // notion of `.inline` vs `.detailPane` (see
                // `LogPaneModel.focusedBlockID`'s doc comment) — so flipping
                // this back to `.inline` just stops drawing the panel;
                // `pane.focusedBlock`/`expandedBlockIDs` are untouched, and
                // the same block reappears expanded inline.
                if settings.jsonPresentation == .detailPane, let block = pane.focusedBlock {
                    JSONDetailPane(block: block) { pane.closeDetailPane() }
                }
            }
        }
        .background(logBackground)
        // `.preferredColorScheme` here is scoped to just this pane's subtree,
        // not the window root `DashboardWindow` deliberately avoids setting
        // one on (see that file's comment) — this is the one place Fulcrum
        // intentionally overrides System/Light mode locally, which is what
        // lets `logPaneAppearance == .alwaysDark` keep the pane's terminal
        // look regardless of the app's own appearance, by resolving every
        // `Color(.resource)` used inside it — the ANSI roles included —
        // through their existing dark variant instead of needing a second,
        // pane-only set of assets.
        .preferredColorScheme(settings.logPaneAppearance == .alwaysDark ? .dark : nil)
        // Fires exactly once per hosted view, plus whenever the SELECTION
        // changes while the window is open — and that is all it can be relied
        // on for. Reopening a closed-but-not-released window reuses this same
        // view, so `initial: true` does NOT fire a second time (measured on a
        // Release build: no `onAppear`, no `onChange`, no `body` at all on the
        // second open). Restarting the stream when the window comes back is
        // `DashboardWindowController.show()`'s job, via
        // `DashboardModel.dashboardWindowDidBecomeVisible()`.
        .onChange(of: dashboard.selectedInstance?.id, initial: true) { _, _ in
            pane.follow(dashboard.selectedInstance)
        }
        // `SettingsStore` is a separate `@Observable`, so nothing inside
        // `DashboardModel` can react to the picker moving on its own — a
        // view's `body` re-evaluating is the only hook there is (same reason
        // the `follow` line above exists). The decision itself lives in
        // `DashboardModel.applyLogScrollbackSetting()`, where it is testable;
        // this is only the trigger. It applies to the LIVE buffer, mid-stream
        // — see `LogPaneModel.setCapacity(_:)` for what that does and does
        // not disturb.
        .onChange(of: settings.logScrollback, initial: true) { _, _ in
            dashboard.applyLogScrollbackSetting()
        }
    }

    private var logBackground: Color {
        settings.logPaneAppearance == .alwaysDark ? Color(.chrome) : Theme.surface
    }

    @ViewBuilder
    private func banner(systemImage: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    /// Branches on `pane.emptyState` — the DECISION, made and tested in
    /// `LogPaneModel` — rather than this view inferring "nothing to show"
    /// from `pane.rows.isEmpty` and then guessing why. `@ViewBuilder`, not
    /// `AnyView`: both branches read `pane.rows` at most once each (the
    /// `emptyState` check itself, and `logList`'s `ForEach`), so this adds no
    /// second pass over the cached rows — see `LogPaneModel.rows`'s own doc
    /// comment on why a second recompute per render is exactly what must not
    /// happen here.
    @ViewBuilder
    private var content: some View {
        if let state = pane.emptyState {
            emptyStateView(for: state)
        } else {
            logList
        }
    }

    private var logList: some View {
        // Read once per render pass here, not once per row inside
        // `LogLineRow`/`LogBlockRow` below — `dashboard.resourceHealthByName`
        // reduces `visibleResources` fresh on every access (deliberately, so
        // it's never stale; see its doc comment), so building it once and
        // having each of up to ~5,000 rows do an O(1) dictionary lookup into
        // the result keeps this pass O(resources + lines) rather than
        // O(resources × lines). This read is also what makes the border
        // colour live: it subscribes this view's body to the same
        // `@Observable` `InstanceStore.resources` DashboardModel itself
        // reads, so a resource's health changing re-renders this pane with
        // no explicit refresh call anywhere.
        let healthByName = dashboard.resourceHealthByName
        return ScrollViewReader { proxy in
            ScrollView {
                // `pane.rows` — `JSONBlock.detect(in:)` + filtering, cached
                // on the model — rather than `pane.filteredLines`: this is
                // what turns a run of `_aws` blobs into collapsible block
                // rows instead of a wall of wrapped raw text. Ordinary lines
                // still render exactly as `LogLineRow` always has.
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(pane.rows) { scored in
                        LogRowView(
                            row: scored.row,
                            // Read off the row, never recomputed here.
                            // `SeverityScanner` runs once per line snapshot
                            // inside `LogPaneModel`'s cached derivation (see
                            // `ScoredRow`); calling it from a `body` would put
                            // a whole-buffer scan back into every render.
                            severity: scored.severity,
                            health: health(for: scored.row, in: healthByName),
                            pane: pane,
                            settings: settings
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        // Standard "am I scrolled to the bottom" technique for
                        // a `ScrollView` + `LazyVStack` on a macOS-14 floor —
                        // `onScrollGeometryChange` (the more direct API) needs
                        // macOS 15. A trailing sentinel appearing/disappearing
                        // from the visible region is the same signal this
                        // app's own "load more" affordances would use.
                        .onAppear { pane.scrollPositionChanged(isAtBottom: true) }
                        .onDisappear { pane.scrollPositionChanged(isAtBottom: false) }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .font(.system(.caption, design: .monospaced))
            }
            .textSelection(.enabled)
            .onChange(of: pane.rows.count) { _, _ in
                guard pane.isFollowing else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // "Jump to next error", driven from the filter bar — which has no
            // `ScrollViewProxy` of its own, so the model carries the target
            // and this is where it becomes a scroll.
            //
            // Watches the GENERATION, not `focusedErrorID`: with one failing
            // row on screen every jump wraps back onto the same id, so the id
            // never changes and an `onChange` on it would scroll once and then
            // sit dead while the user kept clicking. See
            // `LogPaneModel.errorJumpGeneration`.
            .onChange(of: pane.errorJumpGeneration) { _, _ in
                guard let target = pane.focusedErrorID else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !pane.isFollowing {
                    jumpToLatestButton(proxy: proxy)
                }
            }
        }
    }

    /// Turns `state` — the typed DECISION `LogPaneModel.emptyState` already
    /// made — into the copy the user reads. This is the "untestable half"
    /// (see this file's own doc comment): which CASE applies is tested
    /// exhaustively in `LogPaneModelTests`; this switch only ever picks
    /// wording for a case that has already been decided, never re-derives
    /// one from `pane`'s booleans itself.
    ///
    /// Mirrors `ResourceTableView.emptyState`'s layout (a title over an
    /// optional detail line, centred in the space the content would
    /// otherwise fill) — the same class of gap, the same look, so the two
    /// panes read as one app's convention rather than two.
    private func emptyStateView(for state: LogPaneModel.EmptyState) -> some View {
        VStack(spacing: 6) {
            Text(title(for: state))
                .foregroundStyle(Theme.textSecondary)
            if let detail = detail(for: state) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func title(for state: LogPaneModel.EmptyState) -> String {
        switch state {
        case .notFollowing: "Not following any instance"
        case .waitingForLines: "Waiting for logs…"
        case .streamEndedWithNoLines: "No lines were produced"
        case .filteredOut: "No lines match the current filter"
        }
    }

    private func detail(for state: LogPaneModel.EmptyState) -> String? {
        switch state {
        case .notFollowing:
            return "Select a running project to see its logs."
        case .waitingForLines:
            return "Connected — lines will appear as they arrive."
        case .streamEndedWithNoLines:
            // Deliberately does not repeat `pane.streamError`'s text — that
            // already has its own banner above (see `body`'s `banner(...)`
            // call for it) — and deliberately does not claim a failure when
            // there wasn't one: a clean `finish()` with nothing produced
            // reaches this exact case too.
            return "The stream ended before producing any output."
        case .filteredOut(let cause):
            return filteredOutDetail(cause)
        }
    }

    /// Builds the `.filteredOut` detail dynamically from `cause` — every
    /// active control gets named, and the way out offered matches only the
    /// control(s) actually responsible, so a scope-and-query combination
    /// (the case the model's own tests call out as the trap) never reads as
    /// blaming just one of the two.
    private func filteredOutDetail(_ cause: LogPaneModel.FilterCause) -> String {
        var reasons: [String] = []
        var waysOut: [String] = []

        if cause.contains(.resourceScope) {
            let name = dashboard.selectedResourceName ?? "the selected resource"
            reasons.append("the resource scope (“\(name)”)")
            waysOut.append("“Show all resources”")
        }
        if cause.contains(.textQuery) {
            reasons.append("the search query")
            waysOut.append("the search field")
        }
        if cause.contains(.source) {
            reasons.append("the source filter")
            waysOut.append("“Clear”")
        }
        if cause.contains(.errorsOnly) {
            reasons.append("“Errors only”")
            waysOut.append("the “Errors only” checkbox")
        }

        let reasonList = reasons.joined(separator: " and ")
        let wayOutList = waysOut.joined(separator: " or ")
        return "Hidden by \(reasonList). Use \(wayOutList) to see them."
    }

    /// A row's health, from whichever `LogLine` it carries — a `.block`'s
    /// lines all share one `resource`/`spanID` (`JSONBlock.detect(in:)`'s own
    /// boundary rule), so its first line's resource speaks for the whole
    /// row. `LogRow.lines` is package-internal, not visible here, so this
    /// switches on the row directly rather than going through it.
    private func health(for row: LogRow, in healthByName: [String: ResourceHealth]) -> ResourceHealth? {
        let resource: String
        switch row {
        case .line(let buffered): resource = buffered.line.resource
        case .block(_, let lines): resource = lines.first?.line.resource ?? ""
        }
        return DashboardModel.health(forResourceNamed: resource, in: healthByName)
    }

    /// The affordance the brief calls "the part users will judge": shown the
    /// instant the pane stops following, gone the instant it resumes —
    /// whether that's from tapping this button or scrolling back down
    /// unassisted (`LogPaneModel.scrollPositionChanged(isAtBottom:)` handles
    /// both the same way).
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            pane.jumpToLatest()
            withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        } label: {
            Label("Jump to Latest", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .padding(10)
    }
}

/// Column widths shared between `LogColumnHeaderView`'s labels and
/// `LogLineRow`'s cells, so the two line up down the page. A fixed
/// `resourceWidth` (rather than sizing to content) is deliberate — a ragged
/// left edge on the message column, from one row's resource name being
/// wider than the next's, would be worse than the truncation it avoids.
private enum LogColumnLayout {
    /// A 3pt left-edge bar, tinted by the emitting resource's health
    /// (`Theme.color(for: ResourceHealth)`) or left `.clear` for a neutral
    /// line — reserved in both the header and every row so a coloured row
    /// next to an uncoloured one never shifts the columns after it.
    static let borderWidth: CGFloat = 3
    /// Fits `HH:mm:ss` (8 monospaced glyphs) with a little breathing room.
    static let timeWidth: CGFloat = 64
    /// Wide enough for real resource names without truncating — measured
    /// against the longest observed, `northwind-render-shared-build` (29
    /// characters); `tenant-metrics-collection` (26) and `tenant-metrics-api`
    /// (19) — the pair that were indistinguishable at the old 90pt column —
    /// both fit clear of each other too. Still `.lineLimit(1)` for the rare
    /// name that exceeds even this, with a `.help()` tooltip carrying the
    /// full name so truncation there stays recoverable.
    static let resourceWidth: CGFloat = 220
    /// Where the "Message" column visually starts — border + time +
    /// resource, plus the row's own 6pt inter-column spacing three times
    /// over. Used to indent `LogBlockRow`'s expanded inline tree so it lines
    /// up under the message column rather than the page's left edge.
    static let messageLeadingIndent: CGFloat = borderWidth + timeWidth + resourceWidth + 18
}

/// Reserves the border column's WIDTH at the head of a `.firstTextBaseline`
/// row, contributing no height and no baseline of its own.
///
/// The `height: 0` is the whole point, and it is not cosmetic. A `Color` is
/// vertically flexible and has no text baseline, so a bare
/// `Color.clear.frame(width: 3)` in a baseline-aligned `HStack` does two
/// damaging things at once: SwiftUI falls back to its BOTTOM edge as the
/// baseline, and it accepts whatever height it is proposed rather than
/// reporting a bounded one. The stack then aligns the text's first baseline to
/// the bottom of a box whose height nothing constrains — so the row's bounds
/// run above the text, by an amount that depends on the height the layout
/// happens to settle on. Measured offscreen with `ImageRenderer` at 2x, that
/// was 13px of empty band above the ink on a single-line row, 86px on a
/// wrapped one, and the entire canvas when the row was handed a definite
/// height (the same failure `LogColumnHeaderView` once hit for ~400pt). With
/// `.background` behind the row that empty band is visible as a severity wash
/// floating above its own text — which is what this reserves the column
/// without doing.
///
/// A zero-height view has bottom == top, so it sits exactly ON the baseline
/// and adds nothing in either direction. The row's height is then the text's,
/// which is what it was always meant to be.
private struct BorderColumnSpacer: View {
    var body: some View {
        Color.clear.frame(width: LogColumnLayout.borderWidth, height: 0)
    }
}

private extension View {
    /// Draws the health bar down the row's leading edge, in the column
    /// `BorderColumnSpacer` reserved. An `.overlay` because the bar must be
    /// sized BY the row, never the other way round: as a child of the row's
    /// `HStack` a `Color` dictates the row's height instead of following it
    /// (see `BorderColumnSpacer`). An overlay is measured from its parent and
    /// contributes nothing back, so the bar spans exactly the text's height —
    /// including every line of a wrapped message, which as an `HStack` child
    /// it did not.
    ///
    /// `nil` health stays `.clear`, not green: an unknown resource must not
    /// read as a healthy one. See `LogLineRow.health`.
    func healthBorder(_ health: ResourceHealth?) -> some View {
        overlay(alignment: .leading) {
            (health.map(Theme.color(for:)) ?? .clear)
                .frame(width: LogColumnLayout.borderWidth)
        }
    }
}

/// The pane's column labels, directly beneath the filter bar — without them
/// the three columns relied on position alone. Styled after
/// `ResourceTableView`'s own header chrome (see this file's `banner(...)`,
/// which already uses the identical `Theme.chrome` background and separator
/// pattern) so the two panes read as one app's tables, not two.
private struct LogColumnHeaderView: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            BorderColumnSpacer()
            Text("Time")
                .frame(width: LogColumnLayout.timeWidth, alignment: .leading)
            Text("Resource")
                .frame(width: LogColumnLayout.resourceWidth, alignment: .leading)
            Text("Message")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
        // `BorderColumnSpacer` is what keeps this header the height of its own
        // labels. A bare `Color.clear.frame(width:)` here — which is what this
        // was — is vertically greedy, and the header sits in a `VStack` beside
        // a greedy `ScrollView`, so the unconstrained height once let it claim
        // ~400pt of the pane. `.fixedSize` clamped the height back but not the
        // baseline: measured offscreen it still pushed these labels 3pt below
        // centre in their own chrome band, leaving their descenders 1pt off
        // the bottom edge. The zero-height spacer fixes both, and this stays
        // as the guard it has been since that ~400pt build.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}

/// One log line: a left-edge bar tinted by the emitting resource's health,
/// then time, resource (tinted by level), then the ANSI-coloured message.
/// Message text wraps rather than truncating — a log pane that clips a long
/// line to save space is the same "truncation looks like completeness"
/// failure `droppedLinesMessage` exists to avoid at the buffer level, just
/// one row down.
///
/// The border and the resource text colour are deliberately two different
/// dimensions, both wanted: the border says "this resource is failing" (this
/// row's `health`, from `DashboardModel.health(forResourceNamed:in:)`), the
/// text says "this line is an error" (`line.level`) — a healthy resource can
/// still log an individual error line, and a failing resource's routine info
/// lines are still worth flagging by their source.
private struct LogLineRow: View {
    let line: LogLine
    /// This line's resource's health, or `nil` for a tilt-level message
    /// (`line.resource == ""`) or a name not currently in
    /// `dashboard.resourceHealthByName` — both render with no border colour,
    /// never green, which would falsely read as healthy.
    let health: ResourceHealth?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            BorderColumnSpacer()
            Text(LogTimeFormat.formatter.string(from: line.time))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: LogColumnLayout.timeWidth, alignment: .leading)
            Text(line.resource.isEmpty ? "tilt" : line.resource)
                .foregroundStyle(Theme.color(for: line.level))
                .lineLimit(1)
                .frame(width: LogColumnLayout.resourceWidth, alignment: .leading)
                .help(line.resource.isEmpty ? "tilt" : line.resource)
            Text(attributedMessage)
                .textSelection(.enabled)
        }
        .healthBorder(health)
    }

    /// `ANSI.parse(_:)` (pure, from `FulcrumKit`) does the actual escape
    /// decoding; this only maps its spans onto SwiftUI attributes, which is
    /// exactly the part that can't live in `FulcrumKit` — `AttributedString`
    /// colouring needs `import SwiftUI`, and the package must not.
    private var attributedMessage: AttributedString {
        var result = AttributedString()
        for span in ANSI.parse(line.message) {
            var run = AttributedString(span.text)
            run.foregroundColor = Theme.color(forAnsi: span.colour)
            if span.bold {
                run.inlinePresentationIntent = .stronglyEmphasized
            }
            result += run
        }
        return result
    }
}

/// One row in `pane.rows` — either an ordinary line (`LogLineRow`, unchanged
/// from before blocks rendered as a tree) or a JSON block (`LogBlockRow`,
/// Task 5/6). A thin `switch`, not a protocol or `AnyView`: `LogRow` is
/// already a two-case enum, so this is just following its shape.
///
/// This is also where the SEVERITY WASH goes, once, wrapping whichever of the
/// two the row is — rather than in each of them separately, which is two
/// places to change the day the tint does. A `.background` draws BEHIND its
/// content, which is the whole requirement: the message already carries the
/// emitter's own ANSI colours (`Theme.color(forAnsi:)`) and those have to stay
/// legible, so the tint may sit behind the text and never over it.
///
/// `.frame(maxWidth: .infinity, alignment: .leading)` is what makes the band
/// span the pane rather than stopping at the end of the message: an `HStack`
/// sizes to its content, and a wash that ended mid-row would read as a
/// highlight of the text rather than a mark on the line. It changes the row's
/// width, not its height.
///
/// The row's HEIGHT is only honest because of `BorderColumnSpacer` — read that
/// before touching either row's `HStack`. A `.background` can only be as
/// well-aligned as the bounds it fills, and while the health bar was a plain
/// `Color` child of a `.firstTextBaseline` `HStack` those bounds ran well above
/// the text, so the wash did too. That is a defect of the ROW, not of the
/// wash; the wash merely made it visible. Nothing here should ever be nudged
/// by a padding constant to compensate — the error was never constant (13px on
/// a single-line row, 86px on a wrapped one, measured at 2x), so a constant
/// could not have cancelled it.
private struct LogRowView: View {
    let row: LogRow
    /// Scored by `SeverityScanner` inside `LogPaneModel`'s cached derivation
    /// and handed down — this view never asks for it itself.
    let severity: LogSeverity
    let health: ResourceHealth?
    let pane: LogPaneModel
    let settings: SettingsStore

    var body: some View {
        rowContent
            .frame(maxWidth: .infinity, alignment: .leading)
            // The `@ViewBuilder` form, not `?? .clear`: `Optional` conforms to
            // `View`, so `nil` here adds nothing to the hierarchy at all,
            // which is what an ordinary row should cost.
            .background { Theme.wash(for: severity) }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row {
        case .line(let buffered):
            LogLineRow(line: buffered.line, health: health)
        case .block(let block, let lines):
            // `row.id` rather than an id `LogBlockRow` rebuilds for itself:
            // identity is the row's, and there is exactly one definition of
            // it (`LogRow.ID`). A second, view-local derivation is how the
            // chevron and the model end up disagreeing about which block is
            // open.
            LogBlockRow(
                block: block, rowID: row.id, origin: lines.first?.line,
                health: health, pane: pane, settings: settings
            )
        }
    }
}

/// A detected JSON block. Collapsed, this is ONE scannable line — a
/// disclosure chevron plus `JSONValue.summary`, e.g.
/// `› {status: "success", data: {…}}` — which is the whole point of Task 5:
/// five consecutive ~500-byte `_aws` blobs used to render as five walls of
/// wrapped text filling the entire pane, and now render as five short lines.
///
/// What clicking the summary DOES depends on `settings.jsonPresentation`
/// (Task 6): `.inline` expands the tree in place, right below this row,
/// through `LogPaneModel.toggleExpansion(_:)` — which also pauses
/// auto-follow, since inserting the tree resizes the flowing log itself.
/// `.detailPane` opens the SAME tree in a side panel instead, through
/// `LogPaneModel.openInDetailPane(_:)` — which does NOT pause auto-follow,
/// since nothing about the flowing log changes shape. Both paths write into
/// the same underlying model state (`LogPaneModel.focusedBlockID`'s doc
/// comment explains why), so this view never has to reconcile two different
/// "is this one open" answers itself.
private struct LogBlockRow: View {
    let block: JSONBlock
    /// Handed down from `LogRow.id` — never re-derived here. See `LogRowView`.
    let rowID: LogRow.ID
    /// The block's first line, whose time/resource/level label the whole row.
    let origin: LogLine?
    let health: ResourceHealth?
    let pane: LogPaneModel
    let settings: SettingsStore

    /// Long enough that the measured ~500-byte `_aws` blobs still show
    /// several distinguishing fields; short enough that five of them in a
    /// row read as five lines, not five more walls of text.
    private static let summaryBudget = 180

    /// Whether THIS row currently reads as "open" — which property that
    /// means depends on the presentation: `.inline` shows its own tree
    /// inline, so it's `isExpanded`; `.detailPane` shows at most one block
    /// at a time in the side panel, so it's "am I the focused one", not
    /// merely "am I expanded" (a block can stay a member of `expandedBlockIDs`
    /// after a different one replaces it in the panel — see
    /// `LogPaneModel.openInDetailPane(_:)`'s doc comment).
    private var isOpenHere: Bool {
        switch settings.jsonPresentation {
        case .inline: pane.isExpanded(rowID)
        case .detailPane: pane.focusedBlockID == rowID
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if settings.jsonPresentation == .inline, pane.isExpanded(rowID) {
                JSONTreeView(value: block.value)
                    .padding(.leading, LogColumnLayout.messageLeadingIndent)
            }
        }
        .contextMenu {
            Button("Copy JSON") { Clipboard.copy(block.raw) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            BorderColumnSpacer()
            Text(origin.map { LogTimeFormat.formatter.string(from: $0.time) } ?? "")
                .foregroundStyle(Theme.textSecondary)
                .frame(width: LogColumnLayout.timeWidth, alignment: .leading)
            Text(originResourceLabel)
                .foregroundStyle(origin.map { Theme.color(for: $0.level) } ?? Theme.textPrimary)
                .lineLimit(1)
                .frame(width: LogColumnLayout.resourceWidth, alignment: .leading)
                .help(originResourceLabel)
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isOpenHere ? 90 : 0))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Text(summaryText)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)
        }
        // On the HEADER, not on `body`'s `VStack`: the bar marks the log line
        // this block came from, and an expanded tree is that line's contents,
        // not more lines. Running it down the tree too would claim a resource
        // health for rows that are not log rows at all.
        .healthBorder(health)
    }

    private var originResourceLabel: String {
        let resource = origin?.resource ?? ""
        return resource.isEmpty ? "tilt" : resource
    }

    /// A user scanning the collapsed log must be able to tell this row is
    /// JSON without expanding it — `JSONValue.summary`, prefixed by the
    /// block's own label (e.g. `res:`) when it had one, exactly the text
    /// that preceded the `{` on the source line.
    private var summaryText: String {
        let summary = block.value.summary(maxLength: Self.summaryBudget)
        return block.label.map { "\($0): \(summary)" } ?? summary
    }

    private func toggle() {
        switch settings.jsonPresentation {
        case .inline:
            pane.toggleExpansion(rowID)
        case .detailPane:
            if pane.focusedBlockID == rowID {
                pane.closeDetailPane()
            } else {
                pane.openInDetailPane(rowID)
            }
        }
    }
}
