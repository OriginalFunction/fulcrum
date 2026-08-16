import Foundation

/// The log pane's filter bar: text search (plain or regex), a source
/// channel, and a resource. Mirrors `ResourceFilter`'s shape (a value type
/// holding query state plus an `apply(to:)` that runs the whole pipeline)
/// but does not share code with it — that type filters `Resource` on name;
/// this one filters `LogLine` on message, source, and resource, which are
/// different fields on a different type.
///
/// There is deliberately no minimum-level control. One existed through plan
/// 4 and was removed here: a 24,128-line sample of the developer's real
/// project was 100% `level: "info"`, and live `tilt logs --json` against two
/// running instances (one of them a lab built specifically to exercise odd
/// JSON log shapes, including a resource whose own message text literally
/// contains the word "ERROR") confirmed why — tilt's `level` field is set by
/// its own build/deploy pipeline reporting a halting problem to its "alert
/// pane" (Tiltfile errors, build failures it detected itself), never by
/// inspecting a resource's own stdout/stderr content. A resource printing
/// "ERROR" to its own logs still arrives at `info`; tilt does not parse
/// message text to promote it. A control that cannot distinguish anything on
/// real data is worse than no control — it teaches the user the app is
/// broken. `LogLine.level` itself, and `LogLineRow`'s per-line tinting by
/// it, are unaffected: a future tilt release, or a project whose Tiltfile
/// genuinely fails, can still produce a non-`info` line, and it still
/// renders distinctly. Only the filter *control* — the thing that could
/// never usefully narrow a real pane — is gone.
public struct LogFilter: Sendable, Equatable {
    /// Matched against a line's `message` — as plain case-insensitive
    /// substring, or as a regular expression when `isRegex` is true.
    public var query: String
    public var isRegex: Bool
    public var source: LogSource?
    /// Matched exactly against a line's `resource` field (not a substring,
    /// and not tilt's own positional CLI filtering — that is broken in live
    /// tilt v0.36.3: `tilt logs ... server` returned lines for `(Tiltfile)`
    /// and `quick` too). `nil` means every resource, including tilt-level
    /// messages whose `resource` is `""`. Set to a specific resource name,
    /// tilt-level messages are excluded — they belong to no resource, not to
    /// whichever one is selected.
    public var resource: String?
    /// Keep only rows `SeverityScanner` scored at `.error` or above.
    ///
    /// This is the honest replacement for the minimum-level control described
    /// above: that one read tilt's `level` field, which is `info` on every line
    /// of a real project, so it could not narrow anything. This one reads
    /// signals the emitter actually stated — a pino `level: 50`, a 5xx
    /// `statusCode`, a serialised `err` object, an `ERROR:` label — measured to
    /// flag 46 rows of a committed 3,461-line corpus with no false positives.
    ///
    /// A `Bool`, not a `LogSeverity` threshold. `.warning` is the level the
    /// weakest signal (`ansi.red`) can reach, and a control that surfaces
    /// "Flask printed its development-server banner in red" alongside a crash
    /// is the noisy control this feature exists to avoid. Errors and fatals are
    /// the two the user is hunting; the tint still shows warnings in place.
    public var errorsOnly: Bool

    public init(
        query: String = "",
        isRegex: Bool = false,
        source: LogSource? = nil,
        resource: String? = nil,
        errorsOnly: Bool = false
    ) {
        self.query = query
        self.isRegex = isRegex
        self.source = source
        self.resource = resource
        self.errorsOnly = errorsOnly
    }

    /// True when `isRegex` is set and `query` fails to compile as a regular
    /// expression — e.g. `"("` typed on the way to `"(foo|bar)"`. Exposed
    /// separately from `apply(to:)` so the pane can show "invalid pattern"
    /// without recompiling the regex itself. `apply(to:)` responds to this by
    /// returning no matches rather than throwing or falling back to
    /// substring matching, which would show confusing results mid-keystroke.
    ///
    /// Gated on `hasTextQuery`, not on `!query.isEmpty`, so it agrees with
    /// `apply(to:)` about what counts as a query at all: a whitespace-only
    /// pattern is no query, so it is not a pattern that can be invalid
    /// either. (No whitespace-only pattern actually fails to compile today,
    /// so this is consistency rather than a behaviour change — but the two
    /// answering the same question two different ways is exactly how a
    /// filter bar ends up flagging a field the user sees as empty.)
    public var isRegexInvalid: Bool {
        guard isRegex, hasTextQuery else { return false }
        return (try? NSRegularExpression(pattern: query)) == nil
    }

    /// Applies resource, source, then text-query filtering, in that order —
    /// cheap equality checks first, the (potentially regex) text search
    /// last.
    ///
    /// The query's `NSRegularExpression` is compiled exactly once here, not
    /// once per line: 24,128 lines / 5.7 MB arrived in 20s from one live
    /// instance, and this runs over the whole buffer on every keystroke. A
    /// fresh `NSRegularExpression` per line is the naive shape and it makes
    /// typing feel broken (see `LogFilterTests.regexIsCompiledOnceNotPerLine`,
    /// which asserts this deterministically via `CompilationCounter` rather
    /// than by timing — a wall-clock version of this test flaked under
    /// swift-testing's parallel execution, where the same compile-once code
    /// measured 4-5ms idle and 15.4ms loaded, both real, neither a
    /// regression).
    ///
    /// ## This overload cannot apply `errorsOnly`, and no pane path asks it to
    ///
    /// Severity is scored on a `LogRow`, not on a line, and that is not an
    /// implementation detail to route around: a serialised `err: { … }`
    /// spanning six lines is ONE failing thing, and not one of those six lines
    /// is a failure by itself (`err: {` matches no rule at all). Teaching this
    /// overload to score each line separately would therefore not close the
    /// gap — it would answer a DIFFERENT question from the one the pane
    /// answers, and quietly disagree with it about blocks instead of about the
    /// gate.
    ///
    /// So the field is genuinely inexpressible here, and the fix is not to
    /// express it but to make sure nothing user-facing arrives here needing
    /// it. `LogPaneModel.filteredLines` — Copy's source, and the one path that
    /// used to — is now flattened out of `rows`, so the pane and the clipboard
    /// derive from a single filtering pass and cannot diverge on this field or
    /// on any field added later. See `LogPaneModel.filteredLines`, and
    /// `LogPaneModelTests.copyingTakesExactlyWhatThePaneShows`.
    ///
    /// What remains here is the line-level predicate: resource, source, query.
    /// Callers wanting the pane's answer want `apply(to rows:)`.
    public func apply(to lines: [LogLine]) -> [LogLine] {
        applyCounting(to: lines, compilationCounter: nil)
    }

    /// The row-based counterpart of `apply(to lines:)`, for the log pane's
    /// grouped display list (`JSONBlock.detect(in:)`'s output).
    ///
    /// A `.block` is kept — and kept WHOLE, every line it spans — the moment
    /// any one of its lines individually satisfies every active criterion
    /// (resource, source, query). This is the fix for the project's founding
    /// complaint: searching a log pane for `statusCode` used to match only
    /// the `"statusCode": 200,` fragment and lose the `res:` header line
    /// carrying the correlation ID above it. Matching per-line and then
    /// discarding everything but the matching line would reproduce exactly
    /// that bug one level up; matching per-line but keeping the whole block
    /// when any line qualifies is what actually fixes it. A `.line` row
    /// behaves identically to `apply(to lines:)` on that one line — same
    /// predicate, so the two overloads cannot disagree about what "matches"
    /// means.
    ///
    /// ## Records
    ///
    /// The block is not the whole unit, though. In real pino output the
    /// header carrying the correlation ID, method and URL is a SEPARATE log
    /// record from the `res: { … }` block beneath it, so keeping the block
    /// whole still lost the header — the user's actual reported pain. Rows
    /// are therefore grouped into records (`LogRecord.group`) and a record
    /// is kept whole when ANY row in it matches.
    ///
    /// GROUPING HAPPENS HERE AND ONLY HERE, and only for a TEXT QUERY. Source
    /// and resource filter literally, row by row, with no records formed at
    /// all.
    ///
    /// That split is the intent behind each control, not an implementation
    /// convenience. A text query means "find this thing and show me its
    /// context" — the context is the point, and returning the matched
    /// fragment without the header that explains it is the bug this whole
    /// feature exists to fix. A literal filter (source or resource) means
    /// the opposite: "show me only lines matching this field, exactly".
    /// Grouping there would pull unrelated rows back in under a filter the
    /// user set precisely to exclude them.
    ///
    /// With no text query, then, this never forms a record, and with no
    /// criterion set at all it returns every row it was given — the pane
    /// renders line for line exactly as it did before records existed. That
    /// containment is the scope decision made with the user, and it is what
    /// makes a heuristic acceptable: a misjudged record can only change what
    /// survives a SEARCH, never what you read while scrolling, and clearing
    /// the search box always restores the verbatim stream.
    ///
    /// A whitespace-only query is not a query (`hasTextQuery`): the search
    /// field looks empty to the user, so it must behave that way. Before
    /// that trim it was matched literally — `"   "` kept 9,794 of 21,718
    /// lines captured live, and grouped what survived, with nothing visible
    /// in the field to explain either.
    ///
    /// Shares `matchPredicate(compilationCounter:)` with `apply(to lines:)`
    /// rather than re-deriving its own regex handling, so the regex is
    /// compiled once per call here too, not once per row — see
    /// `LogFilterTests.regexIsCompiledOnceNotPerLine` and its row-based
    /// counterpart.
    ///
    /// ## Errors only
    ///
    /// `errorsOnly` is applied LAST, after record grouping, and that ordering
    /// is the whole of what "both controls active means both applied" means
    /// here. Gating BEFORE grouping would delete a record's header before
    /// `LogRecord.group` ever saw it — the header is frequently the only row
    /// that opens a record, so dropping it first turns the remaining
    /// continuation rows into standalone ones and the query then keeps a
    /// different set than it would have. Gating after leaves grouping to see
    /// the stream it was measured against, and the user gets exactly the
    /// intersection they asked for: the failing rows of the records that
    /// matched their search.
    ///
    /// It takes `ScoredRow`s rather than scoring here so that
    /// `LogPaneModel.rows` pays for `SeverityScanner` once per line snapshot
    /// rather than once per filter edit — see `ScoredRow`'s own doc comment,
    /// and `LogPaneModelTests.changingTheFilterDoesNotRescanSeverity`.
    public func apply(to rows: [ScoredRow]) -> [ScoredRow] {
        applyCounting(to: rows, compilationCounter: nil)
    }

    /// The unscored counterpart of `apply(to rows: [ScoredRow])`, which scores
    /// the rows itself before filtering them.
    ///
    /// Deliberately not an overload that IGNORES `errorsOnly`: a field on this
    /// type that one `apply` honours and another silently drops is precisely
    /// the silent no-op this project keeps shipping. Callers with no scores to
    /// hand pay for the scan; `LogPaneModel` has scores to hand and uses the
    /// overload above.
    public func apply(to rows: [LogRow]) -> [LogRow] {
        apply(to: rows.map(ScoredRow.init(scoring:))).map(\.row)
    }

    /// Runs resource, source, then text-query filtering, same as
    /// `apply(to:)`, but increments `compilationCounter` once per regex
    /// compilation. `compilationCounter` is nil in the public `apply(to:)`
    /// overload above; only test code has a way to construct one.
    private func applyCounting(to lines: [LogLine], compilationCounter: CompilationCounter?) -> [LogLine] {
        let matches = matchPredicate(compilationCounter: compilationCounter)
        return lines.filter(matches)
    }

    /// Row-based counterpart of `applyCounting(to lines:compilationCounter:)`
    /// — same shared predicate, applied once per row rather than once per
    /// line, with a `.block` kept whole when ANY of its lines matches, and
    /// (for a text query only) the whole record that block sits in kept with
    /// it.
    private func applyCounting(
        to rows: [ScoredRow],
        compilationCounter: CompilationCounter?,
        recordGroupingCounter: RecordGroupingCounter? = nil
    ) -> [ScoredRow] {
        let matches = matchPredicate(compilationCounter: compilationCounter)
        let kept: [ScoredRow]

        // Source and resource filter literally — row by row, no records.
        // With nothing set at all the predicate accepts everything, so this
        // returns exactly the rows it was given: the unfiltered pane is not
        // grouped. Structural, not incidental — see the scope decision in
        // `apply(to rows:)`'s doc comment and
        // `LogRecordTests.anUnfilteredPaneIsNotGrouped`, which counts
        // grouping passes rather than comparing output to input (with no
        // criterion set those are equal either way, so a result-only
        // assertion cannot see this guard at all).
        if hasTextQuery {
            recordGroupingCounter?.increment()
            kept = LogRecord.group(rows, firstLine: { $0.lines.first?.line }).flatMap { record in
                record.contains { $0.lines.contains { matches($0.line) } } ? record : []
            }
        } else {
            kept = rows.filter { row in row.lines.contains { matches($0.line) } }
        }

        // Last, on purpose — see `apply(to rows: [ScoredRow])`'s doc comment.
        guard errorsOnly else { return kept }
        return kept.filter(\.isFailure)
    }

    /// Whether the text query is anything other than whitespace. A query of
    /// `"   "` reads as an EMPTY search field to the user, so it must filter
    /// nothing and group nothing — see `apply(to rows:)`'s doc comment for
    /// what it did before this trim. Deliberately not `query = trimmed`
    /// anywhere: a query of `"GET /api "` keeps its trailing space and
    /// matches on it, because that one was typed on purpose.
    ///
    /// Public rather than private: `LogPaneModel.emptyState` needs the exact
    /// same "does this count as a query" answer `apply(to:)` uses internally
    /// — a second, hand-rolled `!query.isEmpty` there would disagree with
    /// this one on a whitespace-only query, exactly the kind of two-places-
    /// answer-the-same-question drift this project keeps getting bitten by.
    public var hasTextQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Builds the resource/source/query predicate exactly once per
    /// `apply(to:)` call, then reuses the same closure for every line (or
    /// every line of every block). This is the seam that makes "compile the
    /// regex once, not once per line" true for both the line-based and
    /// row-based overloads: whichever one calls this pays the
    /// regex-compilation cost a single time here, before any filtering
    /// happens, rather than each candidate line separately compiling (or
    /// re-deriving) its own match check.
    private func matchPredicate(compilationCounter: CompilationCounter?) -> (LogLine) -> Bool {
        var checks: [(LogLine) -> Bool] = []

        if let resource {
            checks.append { $0.resource == resource }
        }
        if let source {
            checks.append { $0.source == source }
        }

        let queryMatches = queryPredicate(compilationCounter: compilationCounter)

        return { line in
            for check in checks where !check(line) {
                return false
            }
            return queryMatches(line)
        }
    }

    /// Just the text-search step. Compiles the regex once (when `isRegex`)
    /// and returns a closure that reuses it across every line, rather than
    /// recompiling per line inside a filter closure.
    private func queryPredicate(compilationCounter: CompilationCounter?) -> (LogLine) -> Bool {
        guard hasTextQuery else { return { _ in true } }

        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
                // Invalid pattern (e.g. mid-type "("): no matches, never a
                // substring-match fallback — see `isRegexInvalid`.
                return { _ in false }
            }
            compilationCounter?.increment()
            return { line in
                let range = NSRange(line.message.startIndex..., in: line.message)
                return regex.firstMatch(in: line.message, range: range) != nil
            }
        }

        // Plain substring match. `lowercased()` rather than
        // `localizedCaseInsensitiveContains`, matching `ResourceFilter`'s
        // reasoning: locale-tailored casing could make a plain ASCII query
        // stop matching machine-generated log text.
        let needle = query.lowercased()
        return { line in line.message.lowercased().contains(needle) }
    }
}

extension LogFilter {
    /// Counts regex compilations, so `LogFilterTests` can assert "compiled
    /// once per call, not once per line" deterministically instead of
    /// measuring wall-clock time. See `InvocationCounter`.
    typealias CompilationCounter = InvocationCounter

    /// Counts record-grouping passes (`LogRecord.group`), so `LogRecordTests`
    /// can assert that grouping RAN — or, more importantly, that it did not.
    ///
    /// Needed because grouping's output is indistinguishable from its input
    /// whenever every row matches: with no criterion set (or with a filter
    /// that keeps everything) `LogRecord.group(rows).flatMap { $0 }` IS
    /// `rows`, so "the unfiltered pane is not grouped" — the safety property
    /// the whole record heuristic was scoped around — cannot be observed
    /// from the returned array at all. This seam observes the operation
    /// rather than its result, which is what makes deleting the guard in
    /// `applyCounting(to rows:...)` a test failure instead of a silent
    /// widening of the feature.
    typealias RecordGroupingCounter = InvocationCounter

    /// Same as `apply(to:)`, but increments `counter` once per regex
    /// compilation performed while filtering `lines`. Test-only seam.
    func apply(to lines: [LogLine], countingRegexCompilationsInto counter: CompilationCounter) -> [LogLine] {
        applyCounting(to: lines, compilationCounter: counter)
    }

    /// Row-based counterpart of `apply(to:countingRegexCompilationsInto:)` —
    /// the same test-only counting seam, for `apply(to rows:)`.
    func apply(to rows: [LogRow], countingRegexCompilationsInto counter: CompilationCounter) -> [LogRow] {
        applyCounting(to: rows.map(ScoredRow.init(scoring:)), compilationCounter: counter).map(\.row)
    }

    /// Same as `apply(to rows:)`, but increments `counter` once per record-
    /// grouping pass — which is at most one per call, and zero unless there
    /// is a text query. Test-only seam; see `RecordGroupingCounter`.
    func apply(to rows: [LogRow], countingRecordGroupingsInto counter: RecordGroupingCounter) -> [LogRow] {
        applyCounting(
            to: rows.map(ScoredRow.init(scoring:)), compilationCounter: nil, recordGroupingCounter: counter
        ).map(\.row)
    }
}
