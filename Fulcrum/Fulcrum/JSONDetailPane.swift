import SwiftUI
import FulcrumKit

/// Task 6's alternate presentation: the same `JSONTreeView` Task 5 built,
/// drawn beside the log instead of inside its row. `LogPaneView` shows this
/// alongside `content` whenever `settings.jsonPresentation == .detailPane`
/// and `pane.focusedBlockID` names an open block — see
/// `LogPaneModel.openInDetailPane(_:)`'s doc comment for why opening this
/// way never pauses auto-follow the way the inline chevron does: the log's
/// own flowing content never resizes because of this panel.
///
/// Stays open while the log scrolls or new lines arrive underneath it
/// (nothing in `LogPaneView` ties this view's presence to scroll position);
/// closes only via the explicit button here or Escape.
struct JSONDetailPane: View {
    let block: JSONBlock
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                JSONTreeView(value: block.value)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.caption, design: .monospaced))
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.separator).frame(width: 1)
        }
        // The brief's explicit "closes with an explicit control or Escape".
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack {
            Text(block.label ?? "JSON")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Button("Copy JSON") { Clipboard.copy(block.raw) }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Close")
        }
        .padding(8)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}
