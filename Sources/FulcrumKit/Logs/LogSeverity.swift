import Foundation

/// How loudly a log row is claiming something went wrong.
///
/// Four levels rather than a boolean because the two failure kinds a developer
/// treats differently — "a request 404'd" and "the process is going down" —
/// need to look different in the pane, and because the weakest signal
/// (`ANSI` red) is only ever allowed to reach `.warning`. A boolean would
/// force that signal to either shout or be discarded.
///
/// `Comparable` is the whole point of the type: every caller asks
/// "is this at least an error?" (`>= .error`) rather than switching on cases,
/// so the rules can disagree about *which* level without every call site
/// having to enumerate them. The synthesized ordering follows declaration
/// order, so `.normal < .warning < .error < .fatal`.
public enum LogSeverity: Comparable, Sendable, Hashable {
    case normal
    case warning
    case error
    case fatal
}
