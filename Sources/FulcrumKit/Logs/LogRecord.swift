import Foundation

/// Groups the log pane's rows into *records* — a header line plus the
/// continuation lines that elaborate it — so that filtering can keep a
/// matched line's whole record instead of the matched line alone.
///
/// ## Why this exists
///
/// Grouping a JSON block was not enough. In real pino output the header
/// carrying the correlation ID, method and URL is a SEPARATE log record from
/// the blocks beneath it — the shape captured from a real `login-bff` stream,
/// with the emitting service's name replaced by a fictional one:
///
/// ```
/// [01:13:52] INFO (northwind-account-service): 8fe3c125-… GET /api/auth/check   ← header
///     req: { … }                                                        ← block
///     correlationId: "8fe3c125-…"                                       ← line
///     res: { "statusCode": 304, … }                                     ← block
/// ```
///
/// Searching `statusCode` kept only the `res:` block, so the header — the
/// user's actual reported pain — was still lost. Records are what put it
/// back.
///
/// ## Scope: text search only
///
/// A record is a plain `[LogRow]` run, not a wrapper type, and grouping is
/// used in exactly one place: `LogFilter.apply(to rows:)`, and there only
/// when a TEXT QUERY is set. A level, source or resource filter does not
/// group — "show me only errors" is a different intent from "find this thing
/// and show me its context", and answering the first with a record's `info`
/// continuations reads as a broken filter rather than as context. The
/// unfiltered pane, meanwhile, renders precisely what it rendered before
/// this type existed — line for line, no grouping whatsoever.
///
/// That containment is what makes a heuristic acceptable here: a misjudged
/// record can only ever change what survives a SEARCH, never what you read
/// while scrolling, and clearing the search box always restores the verbatim
/// stream. `LogRecordTests.anUnfilteredPaneIsNotGrouped` and
/// `onlyATextQueryFormsRecords` pin both halves, by counting grouping passes
/// — the output of grouping a pane that matches everything is that pane
/// again, so nothing about the returned rows can tell you whether this ran.
///
/// Because a record is a run of the caller's own rows, grouping also cannot
/// change what a row IS — only which rows are kept together. That is a type
/// invariant, not a promise.
///
/// ## The rule, measured over 8,000 real lines
///
/// A record starts at a header line: `[` at the very start of the line
/// followed by a timestamp. Its continuations are the following contiguous
/// rows from the same resource AND span that begin with whitespace.
/// Anything else stands alone.
///
/// | Measured | |
/// |---|---|
/// | records formed | 3,427 |
/// | …that are a lone header (grouping is a no-op) | 2,915 (85%) |
/// | …with real continuations | 512 |
/// | standalone lines (no header, untouched) | 1,333 |
/// | largest record | 194 lines |
///
/// It groups `auth-service`, `login-bff` and `platform-backend`, and does
/// nothing at all to `nginx-proxy` or `management-client` — neither emits
/// headers, so both degrade to the previous behaviour rather than being
/// mangled.
public enum LogRecord {
    /// Splits `rows` into records, in order. Every row appears in exactly
    /// one record and the concatenation of the result is `rows` again — a
    /// partition, never a filter (`LogRecordTests.groupingNeverLosesOrReordersRows`).
    public static func group(_ rows: [LogRow]) -> [[LogRow]] {
        group(rows, firstLine: { $0.lines.first?.line })
    }

    /// `group(_:)` over any row type that can name its own first `LogLine`.
    ///
    /// Generic solely so `LogFilter` can group `ScoredRow`s — which are
    /// `LogRow`s with a severity attached — without either a second copy of
    /// this partition or an index-arithmetic dance to map a `[[LogRow]]`
    /// result back onto the scored rows it came from. The grouping RULE reads
    /// nothing but the row's first line, so there is nothing here for a row
    /// type to change: `firstLine` is the entire surface a row presents to it.
    static func group<Row>(_ rows: [Row], firstLine: (Row) -> LogLine?) -> [[Row]] {
        var records: [[Row]] = []
        records.reserveCapacity(rows.count)

        // The header that opened the record being built, or nil when the
        // last row could not start one. Held as the record's ORIGIN line
        // (rather than comparing against the previous row) for the same
        // reason `JSONBlock.scanBlock` compares against its opener: a record
        // belongs to one resource and span throughout, so drift line-by-line
        // is not possible.
        var origin: LogLine?
        var current: [Row] = []

        func closeCurrent() {
            if !current.isEmpty { records.append(current) }
            current = []
            origin = nil
        }

        for row in rows {
            // A row always covers at least one line in practice; a
            // hypothetical empty one can neither open nor continue a record,
            // so it stands alone rather than being dropped.
            guard let first = firstLine(row) else {
                closeCurrent()
                records.append([row])
                continue
            }

            let text = ANSI.strip(first.message)

            if isHeader(text) {
                closeCurrent()
                origin = first
                current = [row]
                continue
            }

            if let origin, isContinuation(text), origin.isSameStream(as: first) {
                current.append(row)
                continue
            }

            closeCurrent()
            records.append([row])
        }

        closeCurrent()
        return records
    }

    /// True when `text` opens a record: a `[` at the very START of the line,
    /// then a timestamp, then `]`.
    ///
    /// ANCHORING IS THE WHOLE POINT. A real nginx access line carries a
    /// bracketed timestamp mid-line —
    /// `169.254.169.254 - - [12/Aug/2026:01:13:52 +0000] "GET /x HTTP/1.1" 304 0`
    /// — and an unanchored pattern turns all 266 measured nginx lines into
    /// record headers.
    ///
    /// The bracketed field must also START WITH A DIGIT, which is what
    /// separates a timestamp from any other leading bracketed field. Measured
    /// on port 10350: `management-client` prefixes 377 lines of proxied HTML
    /// with `[readiness probe: success]`, which a "bracket containing a
    /// colon" test would happily accept.
    ///
    /// Accepted verbatim shapes, all measured live: `[01:13:52]`,
    /// `[2026-08-12 01:15:41.992]`, `[2026-08-12T01:16:31.931Z]`, plus
    /// nginx's `[12/Aug/2026:01:13:52 +0000]` — which is why letters are
    /// allowed after the leading digit (`Aug`), and see
    /// `timestampSeparators` for why accepting that shape rather than
    /// rejecting it is what makes the anchor testable. At least one `:` is
    /// required, without which `[2026-08-12]` or `[12345]` would qualify.
    ///
    /// Hand-rolled rather than `NSRegularExpression`, matching `JSONBlock`'s
    /// reasoning: this runs over every row of the buffer on every keystroke
    /// that changes the query, and it stops at the first character that
    /// cannot belong to a timestamp — usually the first one.
    static func isHeader(_ text: String) -> Bool {
        guard text.first == "[" else { return false }

        var sawColon = false
        var length = 0

        for character in text.dropFirst() {
            if character == "]" {
                return length > 0 && sawColon
            }
            if length == 0 {
                // A timestamp starts with a digit — see `[readiness probe:
                // success]` above. This single check is what separates a
                // timestamp from every other leading bracketed field.
                guard character.isNumber else { return false }
            } else if character == ":" {
                sawColon = true
            } else {
                guard character.isLetter || character.isNumber || timestampSeparators.contains(character)
                else { return false }
            }
            length += 1
        }

        // No closing bracket at all.
        return false
    }

    /// The non-digit characters the measured timestamp shapes use: `-` and
    /// `.` for `2026-08-12 01:15:41.992`, `T`/`Z` for the ISO-8601 variant,
    /// a space for the date/time gap, and `+` for a zone offset.
    ///
    /// `/` is included — with letters, above — so that nginx's own
    /// `12/Aug/2026:01:13:52 +0000` counts as a timestamp too. That is
    /// deliberate and was found by mutation: while the character set also
    /// rejected the nginx shape, deleting the start-of-line anchor changed
    /// nothing and `LogRecordTests.aResourceWithNoHeadersIsUntouched` passed
    /// against an unanchored pattern — the exact bug it is named for, masked
    /// by a second guard. Accepting the shape leaves the anchor as the only
    /// thing standing between 266 measured nginx lines and being read as
    /// record headers, which is what that test is there to pin. (A bracketed
    /// nginx timestamp at the START of a line genuinely is a header by this
    /// rule; nothing measured emits one.)
    private static let timestampSeparators: Set<Character> = ["-", ".", "T", "Z", "+", " ", "/"]

    /// True when `text` can continue the record above it: pino indents every
    /// continuation, and nothing that opens a record is indented.
    ///
    /// Deliberately not "is not a header": a blank line, an `_aws` blob at
    /// column zero and an nginx access line all sit between two records
    /// without belonging to either.
    static func isContinuation(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isWhitespace
    }
}
