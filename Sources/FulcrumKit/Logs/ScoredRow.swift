import Foundation

/// A `LogRow` and the `LogSeverity` `SeverityScanner` scored it at, carried
/// together as one value.
///
/// ## Why the severity travels with the row
///
/// The pane needs a row's severity at three moments — to tint it, to decide
/// whether "Errors only" keeps it, and to decide whether "next error" lands on
/// it — and SwiftUI reads `LogPaneModel.rows` several times per render pass.
/// Scoring at the point of USE would mean re-running `SeverityScanner` over the
/// whole buffer for each of those reads, on the main actor, every frame: the
/// scanner is cheap per row (see its "Cost" section) but not free, and 5,000
/// rows × several reads × 60fps is not a budget it was measured against.
///
/// Attaching it here means the scan happens exactly once per line snapshot,
/// inside `LogPaneModel`'s cached derivation, and every later question about a
/// row's severity is a field read. A separate `severityByRowID` dictionary
/// alongside `rows` would do the same job and could go stale against it; a
/// single value cannot disagree with itself.
///
/// Identity is the ROW's identity, never a second definition of it — see
/// `LogRow.ID`, and `LogPaneView`'s own note about what happens when a view
/// re-derives an id the model already owns.
public struct ScoredRow: Sendable, Equatable, Identifiable {
    public let row: LogRow
    public let severity: LogSeverity

    public var id: LogRow.ID { row.id }

    public init(row: LogRow, severity: LogSeverity) {
        self.row = row
        self.severity = severity
    }

    /// Scores `row` with `SeverityScanner` right now.
    ///
    /// The one place a `ScoredRow` is built from an unscored row, so "how a row
    /// gets its severity" has a single answer. `LogPaneModel` calls this once
    /// per row per line snapshot; `LogFilter.apply(to rows: [LogRow])` calls it
    /// for callers that have no scores to hand (tests, chiefly) rather than
    /// quietly ignoring `errorsOnly`.
    public init(scoring row: LogRow) {
        self.init(row: row, severity: SeverityScanner.severity(of: row))
    }

    /// Whether this row is at least an error — the single definition of what
    /// "Errors only" keeps, what the pane counts, and what "next error" jumps
    /// to. Three call sites asking `>= .error` three times is three chances to
    /// pick a different threshold.
    public var isFailure: Bool { severity >= .error }

    /// Forwards `LogRow.lines`, so a scored row can stand in for the row it
    /// wraps everywhere the row's lines are what matters.
    var lines: [BufferedLine] { row.lines }
}
