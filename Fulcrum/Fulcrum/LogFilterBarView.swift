import SwiftUI
import AppKit
import FulcrumKit

/// The log pane's own filter bar — a second, independent filter/search bar
/// from `FilterBarView`'s (that one filters the resource table by name;
/// this one filters `LogPaneModel.lines` by text and source). Order left to
/// right matches tilt's own log-view controls: search, regex toggle, source,
/// then Clear.
///
/// There is deliberately no level picker — see `LogFilter`'s doc comment for
/// why it was removed rather than shipped non-functional: a 24,128-line
/// sample of the developer's real project, and live `tilt logs --json`
/// against two running instances, were 100% `level: "info"`.
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

            Button("Copy") { copyVisibleLines() }
                .help("Copy the lines currently shown to the clipboard")
                .disabled(pane.filteredLines.isEmpty)
        }
        .font(.caption)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
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
