import SwiftUI
import AppKit
import FulcrumKit

/// Copies text to the general pasteboard — the one AppKit call every "Copy
/// ___" context-menu item in this file (and `LogBlockRow` in `LogPaneView.swift`)
/// needs. Pulled out once rather than repeated per call site.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Syntax-coloured, recursively collapsible rendering of a `JSONValue` — the
/// shared "tree" both of `LogPaneView`'s presentations draw from
/// (`SettingsStore.jsonPresentation`): expanded in place for `.inline`,
/// inside `JSONDetailPane`'s side panel for `.detailPane`. Built once, here,
/// so the two presentations can never drift into two different renderings
/// of the same data — see the plan's Task 6 note that the detail pane is
/// "an alternate presentation of Task 5's tree", not a second tree.
///
/// Colours reuse the six `ansi.*` roles already added for the log pane's
/// ANSI rendering (`Theme.color(forAnsi:)`) rather than adding new assets —
/// this pane distinguishes JSON's own small set of value kinds (string,
/// number, bool, null), which fits comfortably inside six existing hues
/// without inventing a seventh.
///
/// Deliberately NOT built on `DisclosureGroup`: outside a `List`,
/// `DisclosureGroup`'s label expands to the full available width and lays
/// its content out loosely — at the log pane's ~2000pt width that flung leaf
/// values to roughly the pane's horizontal centre, far from their keys, and
/// let a bare chevron land alone on its own line. Every row here is laid out
/// explicitly instead: a fixed-width chevron slot, then the key, then the
/// value or summary immediately beside it, indented a small fixed amount per
/// level — see `JSONNodeView.indentStep`'s doc comment for the exact figure.
struct JSONTreeView: View {
    let value: JSONValue

    var body: some View {
        JSONNodeView(key: nil, value: value, depth: 0)
    }
}

/// One node in the tree: an optional key/index label, then either a leaf's
/// coloured literal immediately after it, or — for a non-empty object/array
/// — a chevron-toggled row whose children recurse directly below it (no
/// `DisclosureGroup`; see `JSONTreeView`'s doc comment for why).
///
/// Each node owns its OWN `@State` fold flag, deliberately untracked by
/// `LogPaneModel`: only the block's top-level expand/collapse is state that
/// has to survive a 150ms refresh tick or a ring-buffer eviction (see
/// `LogPaneModel.expandedBlockIDs`'s doc comment for why THAT one does) — a
/// nested node's fold state is throwaway view state, same as any other
/// disclosure triangle in the app.
private struct JSONNodeView: View {
    enum Key {
        case field(String)
        case index(Int)
    }

    let key: Key?
    let value: JSONValue
    let depth: Int
    @State private var isExpanded = true

    /// Indentation per nesting level. 14pt is two glyphs' width of the pane's
    /// own `.caption` monospaced font — chosen to echo `jsonText(pretty:)`'s
    /// own two-space-per-level convention, so a tree's visual nesting depth
    /// reads the same as what "Copy JSON"/"Copy Value" actually paste. It
    /// sits inside the requested 12–16pt band: enough to read as a distinct
    /// level at a glance, not so much that a real `_aws` blob's four or five
    /// levels eat noticeably into the pane's message column.
    private static let indentStep: CGFloat = 14

    /// The chevron's reserved column, in points — wide enough to be a
    /// comfortable click target on its own (see `chevronButton`'s
    /// `.contentShape`), and matched by `chevronSpacer` on leaf rows so
    /// every row's key starts at the same x position whether or not it owns
    /// a chevron.
    private static let chevronSlot: CGFloat = 16

    var body: some View {
        switch value {
        case .object(let pairs) where !pairs.isEmpty:
            // `spacing: 1` matches `LogPaneView`'s own top-level row rhythm
            // (its `LazyVStack(alignment: .leading, spacing: 1)`) rather than
            // introducing a second, looser rhythm one level down.
            VStack(alignment: .leading, spacing: 1) {
                headerRow(collapsedSummary: "{\(pairs.count) \(pairs.count == 1 ? "key" : "keys")}")
                if isExpanded {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        JSONNodeView(key: .field(pair.0), value: pair.1, depth: depth + 1)
                    }
                }
            }
        case .array(let items) where !items.isEmpty:
            VStack(alignment: .leading, spacing: 1) {
                headerRow(collapsedSummary: "[\(items.count) \(items.count == 1 ? "item" : "items")]")
                if isExpanded {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        JSONNodeView(key: .index(index), value: item, depth: depth + 1)
                    }
                }
            }
        default:
            leafRow
        }
    }

    private func headerRow(collapsedSummary: String) -> some View {
        HStack(spacing: 4) {
            chevronButton
            keyLabel
            if !isExpanded {
                Text(collapsedSummary).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.leading, CGFloat(depth) * Self.indentStep)
        .contextMenu { copyMenu }
    }

    private var leafRow: some View {
        HStack(spacing: 4) {
            chevronSpacer
            keyLabel
            valueText
        }
        .padding(.leading, CGFloat(depth) * Self.indentStep)
        .contextMenu { copyMenu }
    }

    /// The fold toggle for a container row — a real, individually clickable
    /// `Button`, not the whole row (the brief's "sensible hit target", not
    /// "as large a target as possible"). `.buttonStyle(.plain)` strips the
    /// bordered/background chrome a `Button` picks up outside a `List`;
    /// `.contentShape(Rectangle())` over the full `chevronSlot` square makes
    /// that whole reserved column clickable rather than just the glyph's own
    /// much smaller bounding box.
    private var chevronButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Self.chevronSlot, height: Self.chevronSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A leaf's stand-in for `chevronButton` — inert, but the same width, so
    /// leaf keys line up under container keys at the same depth instead of
    /// drifting left by the chevron's width.
    private var chevronSpacer: some View {
        Color.clear.frame(width: Self.chevronSlot, height: Self.chevronSlot)
    }

    @ViewBuilder
    private var keyLabel: some View {
        switch key {
        case .field(let name)?:
            Text("\"\(name)\":").foregroundStyle(Theme.textPrimary)
        case .index(let i)?:
            Text("[\(i)]").foregroundStyle(Theme.textSecondary)
        case nil:
            EmptyView()
        }
    }

    /// Reuses `JSONValue.jsonText(pretty:false)` for the literal text —
    /// exactly what "Copy Value" below copies, too, so what's on screen and
    /// what lands on the pasteboard are never two different renderings of
    /// the same value.
    private var valueText: Text {
        let text = value.jsonText(pretty: false)
        switch value {
        case .string: return Text(text).foregroundStyle(Color(.ansiGreen))
        case .number: return Text(text).foregroundStyle(Color(.ansiCyan))
        case .bool: return Text(text).foregroundStyle(Color(.ansiYellow))
        case .null: return Text(text).foregroundStyle(Theme.textSecondary)
        case .object, .array: return Text(text).foregroundStyle(Theme.textSecondary)
        }
    }

    /// "Copy Value" — Task 5 Step 4's per-node half of the context menu. The
    /// block-level "Copy JSON" (the raw text) lives on `LogBlockRow` in
    /// `LogPaneView.swift`, one level up, since it copies `JSONBlock.raw`
    /// rather than any one node's value.
    private var copyMenu: some View {
        Button("Copy Value") { Clipboard.copy(value.jsonText(pretty: true)) }
    }
}
