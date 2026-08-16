import Foundation

/// Whether a project's Tiltfile is still where Fulcrum recorded it.
///
/// This exists because "this project cannot be restarted" covers two
/// situations the user must not be shown identically, and a view deciding
/// which is which by reading `SidebarItem.restartUnavailableReason` — a
/// user-facing sentence — would be inferring domain state from display text.
/// Reword the sentence and the indicator silently changes meaning.
///
/// - `.linked`: a path is recorded and something is at it. Nothing to say.
/// - `.unlinked`: no path was ever recorded. This is a *gap*, not a fault:
///   the entry was persisted before Fulcrum tracked `tiltfilePath` at all
///   (see `RecentProject.init(from:)`'s `decodeIfPresent`), or the project
///   stopped before its Tiltfile key resolved. Nothing is wrong with the
///   project; Fulcrum simply never learned where it lives. Relinking is the
///   fix, but the row must NOT be flagged as broken — flagging it would tell
///   the user their project is damaged when it is Fulcrum's record that is
///   incomplete.
/// - `.broken`: a path IS recorded and nothing is there any more. The
///   Tiltfile has been moved, renamed, or deleted since Fulcrum last saw it.
///   This is the only state that earns the broken indicator.
public enum TiltfileLinkState: Sendable, Hashable {
    case linked(path: String)
    case unlinked
    case broken(path: String)

    /// The recorded path, whether or not it still resolves. `nil` only for
    /// `.unlinked`, which by definition has none.
    public var path: String? {
        switch self {
        case .linked(let path), .broken(let path): path
        case .unlinked: nil
        }
    }

    /// Whether this state is the one that gets a broken indicator. Deliberately
    /// `false` for `.unlinked` — see the type's doc comment.
    public var isBroken: Bool {
        if case .broken = self { return true }
        return false
    }

    /// What is wrong, in words, for the indicator's tooltip — `nil` when
    /// nothing is wrong. Names the actual path: a broken indicator that does
    /// not say *which* file is missing leaves the user with no way to act on
    /// it, which is the same silent-failure shape as a disabled control with
    /// no explanation.
    public var brokenReason: String? {
        guard case .broken(let path) = self else { return nil }
        return "The Tiltfile at \(path) could not be found. It may have been moved or deleted."
    }

    /// Classifies a recorded path against an existence check.
    ///
    /// `fileExists` is injected rather than called directly so this stays a
    /// pure function — and, in production, so the check can come from
    /// `TiltfileExistenceCache` instead of a blocking `stat` on the main
    /// actor. See that type for why that matters here.
    public static func resolve(tiltfilePath: String?, fileExists: (String) -> Bool) -> TiltfileLinkState {
        guard let tiltfilePath else { return .unlinked }
        return fileExists(tiltfilePath) ? .linked(path: tiltfilePath) : .broken(path: tiltfilePath)
    }
}
