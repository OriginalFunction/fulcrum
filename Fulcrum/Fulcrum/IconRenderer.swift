import AppKit
import FulcrumKit

/// Turns a `MenuBarIconState` into what the status item shows.
@MainActor
enum IconRenderer {
    /// Menu bar glyphs render at their image's natural size. SF Symbols in the menu
    /// bar land around 18pt, so pinning ours to the same figure is what keeps the
    /// mark from sitting visibly larger than its neighbours — the assets are already
    /// 18x18, but stating it here means a future asset resize cannot silently change
    /// how big the icon appears.
    private static let glyphSize = NSSize(width: 18, height: 18)

    static func apply(_ state: MenuBarIconState, to button: NSStatusBarButton) {
        // Template imagesets from the asset catalog, not SF Symbols — the beam's
        // angle is the signal, and macOS tints template images for us.
        let image = NSImage(named: state.assetName)
        image?.accessibilityDescription = state.accessibilityLabel
        image?.isTemplate = true
        image?.size = glyphSize
        button.image = image
        button.title = state.badge.map { " \($0)" } ?? ""
        button.imagePosition = state.badge == nil ? .imageOnly : .imageLeading
        button.toolTip = state.accessibilityLabel
    }
}
