import Foundation

/// Resolves the human-meaningful project name a developer actually calls
/// their project, from data reachable at runtime.
public enum ProjectIdentity {
    /// The directory containing the Tiltfile, which is what a developer calls
    /// "the project". Returns nil when the path has no parent directory to name.
    public static func displayName(forTiltfilePath path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return nil }
        let name = (parent as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// The name shown for a project when no real name is known — a
    /// `tiltfileKey` that is missing, unfetchable, or unusable. Every display
    /// site defers to this single function rather than building its own
    /// `"tilt-<port>"` literal, so the fallback shape can't drift between them.
    public static func fallbackName(forPort port: Int) -> String {
        "tilt-\(port)"
    }
}
