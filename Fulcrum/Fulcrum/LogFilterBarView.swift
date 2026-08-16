import SwiftUI
import AppKit
import FulcrumKit

/// The log pane's own filter bar — a second, independent filter/search bar
/// from `FilterBarView`'s (that one filters the resource table by name;
/// this one filters `LogPaneModel.lines` by text, severity and source). Order
/// left to right matches tilt's own log-view controls: search, regex toggle,
/// Errors only, source, then Clear — with the error count and "Next error"
/// pushed to the trailing edge beside Copy, where they read as navigation
/// rather than as another filter.
///
/// There is deliberately no level picker — see `LogFilter`'s doc comment for
/// why it was removed rather than shipped non-functional: a 24,128-line
/// sample of the developer's real project, and live `tilt logs --json`
/// against two running instances, were 100% `level: "info"`. "Errors only" is
/// its replacement, and the difference is that it reads signals the emitter
/// actually stated rather than a field tilt never sets.
struct LogFilterBarView: View {
    @Bindable var pane: LogPaneModel
    /// Read-only here: only `selectedResourceName` (for the scope chip) and
    /// `clearSelectedResource()` (for "Show all resources") are needed, and
    /// routing the clear through `DashboardModel` rather than writing
    /// `pane.filter.resource` directly is what keeps the table's highlight
    /// in step with the log scope — see `setSelectedResource(_:)`'s doc
    /// comment. No `@Bindable` needed: nothing here binds `$dashboard...`
    /// directly, and `@Observable` tracks plain-property reads in `body`
    /// without a property wrapper.
    let dashboard: DashboardModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textSecondary)
                TextField("Filter logs", text: $pane.filter.query)
                    .textFieldStyle(.plain)
                if pane.filter.isRegexInvalid {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Color(.statusError))
                        .help("Invalid regular expression")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .frame(maxWidth: 220)

            // Only present while the pane is scoped to one resource
            // (`dashboard.selectedResourceName` set by clicking its row in
            // the table above) — an always-visible "Show all resources"
            // that does nothing most of the time would be worse than one
            // that appears when it applies. The chip names which resource,
            // so the pane never shows a subset of lines with no indication
            // why; the button beside it is the only way out of that scope
            // other than clicking the same table row again.
            if let scopedResourceName = dashboard.selectedResourceName {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(Theme.textSecondary)
                    Text("Scoped to \(scopedResourceName)")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                Button("Show all resources") {
                    dashboard.clearSelectedResource()
                }
                .help("Clear the resource scope and show every resource's logs")
            }

            Toggle("Regex", isOn: $pane.filter.isRegex)
                .toggleStyle(.checkbox)

            // The honest replacement for the level dropdown removed in v1 —
            // see `LogFilter.errorsOnly`. Same idiom as `Regex` beside it: a
            // checkbox bound straight through to a `LogFilter` field, so the
            // `rows` cache keys on it for free.
            Toggle("Errors only", isOn: $pane.filter.errorsOnly)
                .toggleStyle(.checkbox)
                .help("Show only rows scored as an error or worse")

            Picker("Source", selection: sourceBinding) {
                Text("All").tag(SourceOption.all)
                Text("Build").tag(SourceOption.build)
                Text("Runtime").tag(SourceOption.runtime)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 100)

            // Resets search/regex/source only — `resource` is preserved
            // rather than replaced wholesale by `LogFilter()`.
            // That field is not this bar's own state: it's driven by the
            // table selection via `dashboard.selectedResourceName`
            // (`setSelectedResource(_:)`'s doc comment), and blowing it away
            // here would silently desync the table's highlight from the log
            // scope exactly like writing `logPane.filter.resource` directly
            // would — "Show all resources" above is the only control meant
            // to clear it.
            Button("Clear") { pane.filter = LogFilter(resource: pane.filter.resource) }
                .disabled(pane.filter == LogFilter(resource: pane.filter.resource))

            Spacer()

            errorNavigator

            Button("Copy") { copyVisibleLines() }
                .help("Copy the lines currently shown to the clipboard")
                // `rows`, not `filteredLines`, and the two cannot disagree:
                // `filteredLines` IS `rows` flattened, and every row covers at
                // least one line (`LogRow.lines`), so "no rows" and "no lines
                // to copy" are the same fact. This reads the cached array
                // rather than flattening it on every render.
                .disabled(pane.rows.isEmpty)
        }
        .font(.caption)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
        // "All 2 errors are hidden by the filter" stops being true the moment
        // the filter changes, and "no errors in this buffer" stops being true
        // the moment one arrives. Neither may sit there contradicting the
        // count beside it.
        .onChange(of: pane.filter) { _, _ in jumpNotice = nil }
        .onChange(of: pane.errorCount) { _, _ in jumpNotice = nil }
    }

    // MARK: - Errors: the count, and the way to them

    /// What the last "Next error" press did, when that was something the user
    /// needs told. `nil` whenever the last press simply moved the pane, and
    /// cleared whenever the filter or the buffer changes underneath it so a
    /// stale complaint never outlives the situation that produced it.
    ///
    /// View state, not model state, deliberately. `LogPaneModel` returns the
    /// typed DECISION (`ErrorJump`) and this is the only place that turns one
    /// into words — the same split `EmptyState` already uses, and the reason
    /// which case applies stays testable in `FulcrumKit` while the wording
    /// stays here where nothing can test it anyway.
    @State private var jumpNotice: LogPaneModel.ErrorJump?

    /// The count and the jump, together: the count states that failures
    /// EXIST, the button reaches them. Separating them would leave a number
    /// with no way to act on it and a button with no reason to press it.
    @ViewBuilder
    private var errorNavigator: some View {
        if let notice = jumpNoticeText {
            Text(notice)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }

        // `pane.errorCount` is the UNFILTERED buffer's count — it does not
        // move when the user searches. See its doc comment: a count that
        // dropped to zero because you searched for something else would state,
        // falsely, that the stream is clean.
        Text(errorCountText)
            .foregroundStyle(pane.errorCount > 0 ? Color(.statusError) : Theme.textSecondary)
            .help("Rows scored as an error or worse in the whole buffer, whatever the filter shows")

        Button {
            let outcome = pane.jumpToNextError()
            // Only the two "nowhere to go" outcomes are worth saying out
            // loud; a jump that moved the pane has already shown its own
            // result on screen.
            switch outcome {
            case .moved, .wrapped: jumpNotice = nil
            case .noErrorsInBuffer, .everyErrorFilteredOut: jumpNotice = outcome
            }
        } label: {
            // Plain text, matching `Clear` / `Copy` / `Show all resources`
            // beside it rather than introducing a lone icon button into a bar
            // that has none.
            Text("Next error")
        }
        // Deliberately NOT disabled when the count is zero. A disabled button
        // is this project's silent no-op wearing a nicer suit: it says "not
        // now" without saying why, and the two reasons there is nothing to
        // jump to — no failures at all, versus a filter hiding the ones the
        // count beside it is advertising — are exactly what the user needs
        // told apart. Pressing it always answers.
        .help("Scroll to the next error, wrapping at the end")
    }

    private var errorCountText: String {
        let count = pane.errorCount
        return "\(count) \(count == 1 ? "error" : "errors")"
    }

    /// Turns the typed outcome into copy. Only ever called for a case the
    /// model already decided — this never re-derives which situation applies
    /// from `pane`'s own properties.
    private var jumpNoticeText: String? {
        switch jumpNotice {
        case nil, .moved, .wrapped:
            return nil
        case .noErrorsInBuffer:
            return "No errors in this buffer"
        case .everyErrorFilteredOut(let errorCount):
            let noun = errorCount == 1 ? "error is" : "errors are"
            return "All \(errorCount) \(noun) hidden by the filter"
        }
    }

    /// A log you cannot get text out of is not usable — `.textSelection` on
    /// the pane's content covers drag-selecting a few lines, but copying
    /// everything currently visible (which may be thousands of lines) by
    /// dragging across all of them is not a real option. This is that path.
    private func copyVisibleLines() {
        let text = pane.filteredLines
            .map { line in
                "\(LogTimeFormat.formatter.string(from: line.time)) [\(line.level.rawValue)] " +
                "\(line.resource.isEmpty ? "tilt" : line.resource): \(line.message)"
            }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Source picker

    // `LogSource` is `RawRepresentable` + `Equatable` but not `Hashable`,
    // which is what `Picker(selection:)` needs — adding `Hashable` purely to
    // satisfy this view would widen `FulcrumKit`'s public surface for a
    // SwiftUI-only concern. This small local option enum, with a
    // hand-written `Binding` translating to and from `LogFilter.source`,
    // keeps that translation entirely on this side of the package boundary
    // instead.

    private enum SourceOption: Hashable { case all, build, runtime }

    private var sourceBinding: Binding<SourceOption> {
        Binding(
            get: {
                switch pane.filter.source {
                case .build: .build
                case .runtime: .runtime
                default: .all
                }
            },
            set: { newValue in
                pane.filter.source = switch newValue {
                case .all: nil
                case .build: .build
                case .runtime: .runtime
                }
            }
        )
    }
}
