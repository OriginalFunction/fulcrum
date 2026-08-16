import Foundation

/// Everything the status item needs to render itself.
///
/// `assetName` refers to a template imageset in the app's asset catalog, not an
/// SF Symbol. The mark is a beam resting on a pivot, and its *angle* carries the
/// state — level for healthy, hard tilt for a failure. macOS renders menu bar
/// icons monochrome regardless, so shape has to do the work colour cannot.
public struct MenuBarIconState: Sendable, Equatable {
    public let assetName: String
    /// Text drawn beside the mark, or `nil` for mark-only.
    public let badge: String?
    public let isAnimating: Bool
    public let accessibilityLabel: String
}

/// The template imagesets in `Assets.xcassets`, by state.
public enum MenuBarAsset {
    public static let level = "MenuBarLevel"          // all healthy
    public static let rocking = "MenuBarRocking"      // building — rotate to animate
    public static let unsettled = "MenuBarUnsettled"  // pending / not yet assessed
    public static let offPlumb = "MenuBarOffPlumb"    // something failed
    public static let idle = "MenuBarIdle"            // no tilt instances running
}
