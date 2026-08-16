import Foundation

/// Streams a tilt instance's logs, line by line, for as long as the caller
/// keeps consuming.
///
/// The seam exists for the same reason `CommandRunning` does: everything
/// behind it spawns a real child process, and the log pane must be testable
/// without one. It differs from `CommandRunning` in the one way that matters
/// most here — the child is **long-lived**. A one-shot `tilt trigger` that
/// leaks a process leaks one process; a leaked `tilt logs --follow` leaks one
/// per instance selection and keeps streaming for the rest of the session.
///
/// Contract every implementation must honour:
///
/// - **The stream ends when the child ends.** A stream that goes quiet
///   because its child died must be distinguishable from one that is merely
///   idle: a clean child exit finishes the stream, and any other ending
///   finishes it *throwing* a `TiltActionError` carrying the child's own
///   stderr.
/// - **A malformed line is skipped, not fatal.** tilt interleaves plain text
///   with its JSON output; one unparseable line must not end the stream.
/// - **Cancellation kills the child.** When the consumer stops consuming —
///   by cancelling its task or simply dropping the stream — the child process
///   must actually be gone, not merely unobserved.
public protocol LogStreaming: Sendable {
    /// Streams `instance`'s logs, replaying at most `tail` historical lines
    /// before following live ones.
    ///
    /// `tail` is not optional and not decorative: `tilt logs --follow` with no
    /// bound replays the instance's *entire* history first — a measured 24,128
    /// lines / 5.7 MB in 20 seconds from a 20-hour-old instance. Implementations
    /// reject a non-positive `tail` rather than quietly running unbounded.
    ///
    /// Errors are `TiltActionError`, so the existing
    /// `tiltActionFailureMessage(for:)` mapping renders them for the UI
    /// without a second error taxonomy.
    func stream(instance: TiltInstance, tail: Int) -> AsyncThrowingStream<LogLine, any Error>
}
