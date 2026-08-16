import Foundation

/// Which rule fired on a row, and how loud it says the row is.
///
/// One value rather than two lookups: a caller that needs both — the pane
/// renders the tint and the tests assert the reason — would otherwise run the
/// whole evaluation twice, and two evaluations can be made to disagree by a
/// later edit in a way one cannot.
public struct SeverityMatch: Sendable, Equatable {
    /// The name of the rule that produced `severity`, e.g. `"json.level"`.
    public let rule: String
    public let severity: LogSeverity

    public init(rule: String, severity: LogSeverity) {
        self.rule = rule
        self.severity = severity
    }
}

/// Scores a `LogRow` by severity from the row's own structure — no model, no
/// heuristics over the whole stream, no state carried between rows.
///
/// ## Why rules and not inference
///
/// The pane renders every row with equal weight, and a measured ~1,200
/// lines/second means a real failure scrolls past looking exactly like a
/// health check. The signals that distinguish them are already structured —
/// pino's numeric `level`, an HTTP `statusCode`, a `FATAL:` prefix postgres
/// prints itself — so the useful work is reading what the emitter already
/// said, not guessing. Inference could not keep up with the stream anyway.
///
/// ## Precision beats recall, but not for free
///
/// A rule that paints ordinary lines red destroys the feature: once a
/// developer learns the tint is noise, the tint stops being read, and the
/// genuine failure it was built to surface is lost with it. Every rule below
/// is therefore anchored to something the emitter *stated*. That is a reason
/// to make a rule precise, though — not a reason to leave a signal on the
/// floor. Both anchors below (the case rule for tokens, the cap on red) are
/// stated with the count they were measured at, so the next person can see
/// what each one costs.
///
/// ## Signal families, in precedence order
///
/// 1. **A parsed block's own fields** — `json.level`, `json.statusCode`,
///    `json.err`. ONE signal, evaluated as one: all three are considered and
///    the HIGHEST severity wins, reporting the name of whichever produced it
///    (ties go to the earliest in that list). They are not ranked against each
///    other, because they are not independent claims about different things —
///    `{"statusCode":404,"err":{…}}` is one record whose fields disagree
///    about how bad it is, and taking the first would silently suppress a
///    serialised error object behind a 404.
/// 2. **`tilt.level`** — tilt's own level field on the line.
/// 3. **`token.severity`** — a severity token near the start of a `.line`
///    row's text.
/// 4. **`ansi.red`** — the emitter chose to print the line red.
///
/// Between families it is strictly first-match-wins: a family that fires ends
/// the evaluation. The one place that could bite is `tilt.level` reporting
/// `warn` on a line whose text says `ERROR`, which would score `.warning` —
/// tilt's own level is `info` on all 3,428 lines of the corpus (its warn/error
/// levels are its internal build messages, never a resource's stdout), so this
/// has no instance today, and it is the thing to revisit if that ever changes.
///
/// Stack-frame lines are deliberately NOT a signal. 24 frames tinted for one
/// failure would light up the pane for a single error; a frame is evidence of
/// an error's *context*, not a claim of one. Frames inside a JSON block
/// inherit the block's severity by virtue of being the same row.
///
/// ## Cost
///
/// `ANSI.parse` calls, exactly: ONE for a `.line` row, whatever fires on it,
/// because the token rule and the red rule share that one decode. ZERO for a
/// `.block` row whose own fields answer. One PER LINE for a block whose fields
/// do not answer and which therefore has to be checked for red — the red rule
/// is the only thing in here whose cost scales with a row's line count, and it
/// is bounded by `JSONBlock.maxBlockLines`. Both bounds are pinned by tests
/// that COUNT parses (see `scan(_:countingANSIParsesInto:)`), not ones that
/// time them.
///
/// Otherwise: zero JSON parses (a `JSONBlock` already carries its parsed tree);
/// one forward scan over at most `tokenWindow` characters, with at most eight
/// characters of lookahead at any candidate (the longest token plus the one
/// character after it); and no `NSRegularExpression` anywhere. This runs over
/// every row at ~1,200 lines/sec and over a whole 5,000-row buffer on each
/// refresh.
public enum SeverityScanner {
    /// The rule that fired and the severity it claims, or `nil` when no rule
    /// fired. THE entry point; the two accessors below are conveniences over
    /// this one.
    public static func scan(_ row: LogRow) -> SeverityMatch? {
        scan(row, ansiParseCounter: nil)
    }

    /// The row's severity, or `.normal` when no rule fired.
    public static func severity(of row: LogRow) -> LogSeverity {
        scan(row)?.severity ?? .normal
    }

    /// The NAME of the rule that fired, or `nil` when none did.
    ///
    /// Exists so a test can assert *which* rule fired rather than merely that
    /// something was flagged. "A line was highlighted" is precisely the
    /// assertion that passes for the wrong reason — a rule can be broken into
    /// firing for an unrelated reason and still satisfy it — and seventeen
    /// tests in this project have shipped or nearly shipped doing exactly
    /// that.
    public static func matchingRule(for row: LogRow) -> String? {
        scan(row)?.rule
    }

    private static func scan(_ row: LogRow, ansiParseCounter: ANSIParseCounter?) -> SeverityMatch? {
        switch row {
        case .line(let buffered):
            let line = buffered.line
            // Matched on the case rather than through `LogRow.lines`, which
            // would allocate a fresh single-element array for every ordinary
            // row on every scan — and ordinary rows are nearly all of them.
            if let severity = tiltLevel(of: line.level) {
                return SeverityMatch(rule: "tilt.level", severity: severity)
            }

            // The token rule and the red rule both need this line decoded, so
            // it is decoded once here and shared between them.
            let spans = parseANSI(line.message, counter: ansiParseCounter)
            if let severity = leadingSeverityToken(in: strippedText(of: spans)) {
                return SeverityMatch(rule: "token.severity", severity: severity)
            }
            if carriesRed(spans) {
                return SeverityMatch(rule: "ansi.red", severity: .warning)
            }
            return nil

        case .block(let block, let lines):
            if let match = parsedFields(of: block) { return match }

            var highest: LogSeverity?
            for buffered in lines {
                guard let severity = tiltLevel(of: buffered.line.level) else { continue }
                if highest == nil || severity > highest! { highest = severity }
            }
            if let highest { return SeverityMatch(rule: "tilt.level", severity: highest) }

            // The token rule deliberately does NOT run on a block: a block's
            // text IS a parsed JSON document, so its severity comes from its
            // fields, and the words inside its string values are data.
            // `{"msg":"user asked about ERROR codes","id":7}` is not an error,
            // and neither — by exactly the same reasoning — is
            // `{"statusCode":404,"msg":"FATAL: shutting down"}` any worse than
            // the 404 its fields report.
            for buffered in lines where carriesRed(parseANSI(buffered.line.message, counter: ansiParseCounter)) {
                return SeverityMatch(rule: "ansi.red", severity: .warning)
            }
            return nil
        }
    }
}

// MARK: - Family 1: a parsed block's own fields

extension SeverityScanner {
    /// The strongest claim any of the block's own fields makes.
    ///
    /// All three field rules are evaluated — not short-circuited at the first
    /// hit — and the highest severity wins. A record whose fields disagree
    /// (`{"statusCode":404,"err":{"type":"DatabaseError"}}`, an ordinary Node
    /// error-handler shape) is one record, and the 404 must not bury the
    /// serialised error. Ties keep the earliest rule, so a pino record
    /// carrying both `"level":50` and an `err` object is still reported as
    /// `json.level` — the more specific claim of the two.
    private static func parsedFields(of block: JSONBlock) -> SeverityMatch? {
        var best: SeverityMatch?

        func consider(_ rule: String, _ severity: LogSeverity?) {
            guard let severity else { return }
            guard let current = best else {
                best = SeverityMatch(rule: rule, severity: severity)
                return
            }
            if severity > current.severity {
                best = SeverityMatch(rule: rule, severity: severity)
            }
        }

        consider("json.level", jsonLevel(block))
        consider("json.statusCode", jsonStatusCode(block))
        consider("json.err", jsonErrorObject(block))
        return best
    }

    /// pino's numeric level scale: 30 info, 40 warn, 50 error, 60 fatal.
    ///
    /// Only `>= 50` is honoured. 40 (`warn`) is deliberately left alone: the
    /// design commits to the two thresholds below, the corpus contains no
    /// level-40 record to check a third against (nor did the capture it was
    /// synthesized from), and a threshold nobody has seen fire is a threshold
    /// nobody has seen misfire either.
    ///
    /// A STRING `level` (`"level":"error"`, which some non-pino emitters use)
    /// is likewise not read here — that shape has no instance in the corpus.
    private static func jsonLevel(_ block: JSONBlock) -> LogSeverity? {
        guard case let .number(level)? = field("level", in: block.value) else { return nil }
        if level >= 60 { return .fatal }
        if level >= 50 { return .error }
        return nil
    }

    /// An HTTP status the emitter logged as a field. 5xx is the server saying
    /// it failed; 4xx is a caller's mistake, which matters less to the person
    /// watching this pane but is still not ordinary traffic.
    ///
    /// 2xx/3xx return `nil` rather than `.normal` so the row falls through to
    /// the remaining rules — ALL 22 of the corpus's `statusCode` fields are 200
    /// or 304, and a `res: { "statusCode": 200 }` block must stay untinted
    /// without also becoming un-scannable by anything else.
    private static func jsonStatusCode(_ block: JSONBlock) -> LogSeverity? {
        guard case let .number(code)? = field("statusCode", in: block.value) else { return nil }
        if (500..<600).contains(code) { return .error }
        if (400..<500).contains(code) { return .warning }
        return nil
    }

    /// An `err`/`error` key whose value is an OBJECT — pino's serialised error
    /// (`{"type":…,"message":…,"stack":…}`).
    ///
    /// The value must be an object, not merely present: `"error": null` and
    /// `"error": false` are how emitters say the opposite, and a rule reading
    /// key presence alone would tint every successful request that reports its
    /// error slot as empty.
    ///
    /// ## Which of the two paths below is live, measured
    ///
    /// The FIELDS path is. Its only instances are compact one-line pino
    /// records (`{"level":50,…,"err":{…}}`): 3 in the committed corpus, all of
    /// which also carry `"level":50`, so `parsedFields` ties and reports
    /// `json.level` — `json.err` is evaluated and correct on them, and is never
    /// the name that comes out. Over 23,033 live lines it named ZERO rows.
    ///
    /// The LABEL path is checked because pino's pretty-printer splits a
    /// serialised error across lines as `err: {` followed by the object, and
    /// detection puts the `err:` text in `JSONBlock.label` with everything from
    /// the `{` onward in `value` — so on a block of that shape the key is not
    /// inside `value` at all. On the real emitter that block never arrives.
    /// pino-pretty writes `"stack":` followed by RAW un-quoted multi-line text
    /// (the stack, then its frames), which is not JSON, so the region fails to
    /// parse, `JSONBlock.detect` falls back to one `.line` row per line, and
    /// the largest thing in there that does parse — the inner `"$metadata": {`
    /// — becomes the only block. Both `err: {` errors seen on live data
    /// degraded exactly that way, and
    /// `aLivePinoErrBlockNeverReachesThisRuleBecauseItDoesNotParse`
    /// reproduces one of them verbatim. So the label branch fires only on an
    /// `err: {` block whose contents parse: every unit test above, and nothing
    /// yet observed.
    ///
    /// It is also narrower than it reads: detection hands the label over
    /// verbatim, QUOTES INCLUDED, and the strip below removes only a trailing
    /// colon — so `err: {` reaches this rule and `"err": {` does not.
    ///
    /// The user is not losing those failures. The `ERROR` header above the
    /// block is its own `.line` row and `token.severity` flags it, which is why
    /// this reads as a rule with no recall rather than as a missed error.
    ///
    /// Kept, and deliberately not widened: the fields path is live, correct and
    /// free (the tree is already parsed), and the label path costs one string
    /// compare. Teaching the parser to swallow raw stack text is a change to
    /// what counts as JSON everywhere, and nothing here is a reason to make it.
    private static func jsonErrorObject(_ block: JSONBlock) -> LogSeverity? {
        if var name = block.label {
            // Labels arrive already trimmed of whitespace by detection, as
            // `err:` — the key plus the colon that introduced the object.
            if name.hasSuffix(":") { name.removeLast() }
            if name == "err" || name == "error" { return .error }
        }

        for key in ["err", "error"] {
            if case .object? = field(key, in: block.value) { return .error }
        }
        return nil
    }

    /// Looks a key up by SCANNING the ordered pairs.
    ///
    /// `JSONValue.object` carries ordered pairs rather than a dictionary
    /// precisely so field order survives to the renderer, and building a
    /// `Dictionary` here to look one key up would both undo that and risk
    /// trapping: `Dictionary(uniqueKeysWithValues:)` crashes on a duplicate
    /// key, and duplicate keys are legal JSON that a real emitter can and does
    /// produce. Scanning cannot trap, and takes the first occurrence — the
    /// same one a streaming JSON reader would see.
    ///
    /// Top level only. A pino request log nests `statusCode` under `res`, but
    /// detection hands those over as a LABELLED block (`res: {`) whose value
    /// is the inner object, so the field is top-level exactly where this rule
    /// looks. Descending into children would widen the surface for a nested
    /// field of the same name that means something else.
    private static func field(_ name: String, in value: JSONValue) -> JSONValue? {
        guard case let .object(pairs) = value else { return nil }
        for pair in pairs where pair.0 == name { return pair.1 }
        return nil
    }
}

// MARK: - Family 2: tilt's own level

extension SeverityScanner {
    /// tilt's `level` field, as its own log stream reports it.
    ///
    /// Measured `info` on all 3,428 lines of the committed corpus (and on the
    /// 3,461-line capture it was synthesized from, and on a 52,228-line capture
    /// before that), because tilt's warn/error levels are
    /// its internal build messages rather than a resource's stdout. Honoured
    /// anyway: it costs one comparison, and a rule that reads what the tool
    /// itself said cannot be wrong about it. It has NO corpus validation of
    /// its recall — it is unit-tested only.
    private static func tiltLevel(of level: LogLevel) -> LogSeverity? {
        switch level {
        case .error: .error
        case .warn: .warning
        case .info, .other: nil
        }
    }
}

// MARK: - Family 3: a leading severity token

extension SeverityScanner {
    /// How far into the line a severity token is still read as a severity
    /// CLAIM rather than as data that happens to contain the word.
    ///
    /// Measured in ANSI-STRIPPED columns (escape bytes inflate raw offsets by
    /// five characters apiece and would push a genuine token out of a raw
    /// window). Every genuine UPPER-CASE token in the corpus sits at stripped
    /// column 15 (`[17:42:15.845] ERROR:`), 35 or 36 (postgres'
    /// `2026-08-15 02:05:12.371 UTC [4914] ERROR:`, the two differing only by
    /// the width of the pid); the largest warning-token
    /// column is 26, and the largest column of the 21 lower-case label tokens
    /// is 42 — `12:57:46 PM [vite] (client) Pre-transform error:`, which is the
    /// first fixture string in
    /// `aLowerCaseSeverityLabelIsFoundWhenItIsPunctuatedAsALabel`. 80 leaves
    /// 1.9x headroom over the measured maximum of 42 — room for a longer
    /// timestamp/thread prefix than this corpus happens to contain — while
    /// staying far below the three genuine `render-api` errors that carry
    /// `"severity":"ERROR"` at stripped column 650 inside an embedded JSON
    /// payload. Those three are real errors and are flagged, but by
    /// `json.level` reading their `"level":50` field: they are a structured
    /// claim, and the token rule must not be the thing that reaches 650
    /// characters into a line to find them, because at that distance it would
    /// also reach every payload that merely quotes the word.
    ///
    /// The exact boundary is pinned by a test (a token at column 79 matches,
    /// the same token at column 80 does not), because a window defended only
    /// by prose can be widened threefold without any test noticing.
    private static let tokenWindow = 80

    /// The tokens, as ASCII bytes so the scan can case-fold with one mask
    /// rather than allocating an uppercased `String` per candidate.
    ///
    /// Order is irrelevant to correctness — the trailing word-boundary check
    /// rejects `WARN` inside `WARNING` on its own, so `WARNING` does not need
    /// to be tried first. It reads loudest-first.
    private static let severityTokens: [(bytes: [UInt8], severity: LogSeverity)] = [
        (Array("FATAL".utf8), .fatal),
        (Array("ERROR".utf8), .error),
        (Array("WARNING".utf8), .warning),
        (Array("WARN".utf8), .warning),
    ]

    /// The displayable text of `spans`, concatenated.
    ///
    /// The single-span case is not a micro-optimisation for its own sake:
    /// 3,072 of the corpus's 3,428 lines contain no escape at all and decode
    /// to exactly one span, so returning that span's text hands back an
    /// existing string (copy-on-write, no allocation) on the overwhelmingly
    /// common path, where `joined()` would build a fresh copy of every line in
    /// the buffer on every refresh.
    private static func strippedText(of spans: [ANSI.Span]) -> String {
        spans.count == 1 ? spans[0].text : spans.map(\.text).joined()
    }

    /// `FATAL`/`ERROR`/`WARNING`/`WARN` at a word boundary within the first
    /// `tokenWindow` columns of the ANSI-STRIPPED text.
    ///
    /// ## Why stripped text is not optional here
    ///
    /// Six corpus lines from `studio-api` are emitted as
    /// `ESC[31mERRORESC[39m` — the escape sits flush against the token, so
    /// there is no word boundary between `m` and `E` and a scan over the raw
    /// bytes matches NONE of them. That is a 24% silent miss on this rule's
    /// largest corpus signal, and it fails silently: the lines simply stop
    /// being flagged.
    ///
    /// ## Case, and what it costs
    ///
    /// The match is case-INSENSITIVE, but a token that is not written in upper
    /// case must additionally stand in LABEL position — immediately followed
    /// by a colon (`error: /api/sse/session-events`), or bracketed
    /// (`[error] 23#23: upstream prematurely closed`).
    ///
    /// Measured, on the 3,428-line corpus, by mutating this file and re-running
    /// `theRulesFlagTheSameFortySixCorpusLinesAndNothingElse`:
    /// * Upper case only: 46 flagged rows become 25. The 21 lost are ALL
    ///   genuine failures — 16 vite `Pre-transform error` / `Internal server
    ///   error`, 3 vite `http proxy error`, one nginx `[error] upstream
    ///   prematurely closed connection`, one `error: "fetch failed"` — and 19
    ///   of them fall back to `.warning` via `ansi.red`. The spec's first
    ///   success criterion is that every error-carrying line is highlighted.
    /// * Case-insensitive with NO position requirement: 46 become 79. All 33
    ///   additions are false positives — prose ("recovered from the error and
    ///   retried the upload"), `"error": null` fields, Python `'error': None`
    ///   dict reprs, and aligned `error       : 0` summary columns.
    ///
    /// The label requirement takes the recall and leaves the prose, and the
    /// corpus can now SEE that difference: on the captured corpus this rule
    /// differed from the unrestricted scan on zero lines, so
    /// `theWordErrorInProseIsNotASeverityClaim` was the only thing holding it.
    /// The generated corpus carries that surface deliberately, so the
    /// requirement is now corpus-validated as well as unit-tested.
    ///
    /// A quoted lower-case token is never a claim here: `"error": null` and
    /// Python's `'error': None` name a FIELD, and a field named `error` says
    /// nothing about whether one occurred. That exclusion also swallows the
    /// quoted VALUE form
    /// (`{"level":"error"}`), which `jsonLevel` does not read either because
    /// it requires a number — a known gap with no instance in the corpus,
    /// stated here rather than papered over.
    ///
    /// One forward pass over at most `tokenWindow` characters, with at most
    /// eight characters of lookahead at any candidate — the longest token
    /// (`WARNING`) plus the single character after it that decides the word
    /// boundary and the label form. Nothing here scans to end of line; no
    /// regex, and no substring allocated per candidate.
    private static func leadingSeverityToken(in text: String) -> LogSeverity? {
        var highest: LogSeverity?
        var previous: Character?
        var column = 0
        var index = text.startIndex

        while index < text.endIndex, column < tokenWindow {
            if !isWordCharacter(previous), let severity = token(in: text, at: index, precededBy: previous) {
                // Nothing outranks fatal, so the scan is done the moment one
                // is seen.
                if severity == .fatal { return .fatal }
                if highest == nil || severity > highest! { highest = severity }
            }
            previous = text[index]
            index = text.index(after: index)
            column += 1
        }

        return highest
    }

    /// The severity of the token starting exactly at `index`, if one starts
    /// there and its case and position make it a claim.
    private static func token(in text: String, at index: String.Index, precededBy previous: Character?) -> LogSeverity? {
        for candidate in severityTokens {
            guard let match = matchEnd(candidate.bytes, in: text, at: index) else { continue }
            guard match.wasUpperCase
                || isLabelPosition(in: text, endingAt: match.end, precededBy: previous)
            else { continue }
            return candidate.severity
        }
        return nil
    }

    /// Where `token` ends if it appears at `index` and ends on a word
    /// boundary, plus whether it was written entirely in upper case.
    ///
    /// The trailing boundary is what keeps `ERRORS_TOTAL` and `/api/errors`
    /// out; the leading boundary is the caller's `previous`, which keeps
    /// `NO_ERROR` out. Together they mean the token has to stand as its own
    /// word — while an ANSI escape, already stripped by the time this runs,
    /// cannot masquerade as a boundary in either direction.
    ///
    /// Case-folds by masking bit 5 of the ASCII byte, which maps `a…z` onto
    /// `A…Z` and leaves every other byte outside `A…Z`, so no non-letter can
    /// match a letter. Non-ASCII characters have no `asciiValue` and stop the
    /// match, which is correct: `ERRÖR` is not the token.
    private static func matchEnd(
        _ token: [UInt8], in text: String, at index: String.Index
    ) -> (end: String.Index, wasUpperCase: Bool)? {
        var cursor = index
        var wasUpperCase = true

        for expected in token {
            guard cursor < text.endIndex, let actual = text[cursor].asciiValue else { return nil }
            guard actual & 0b1101_1111 == expected else { return nil }
            if actual != expected { wasUpperCase = false }
            cursor = text.index(after: cursor)
        }

        guard cursor == text.endIndex || !isWordCharacter(text[cursor]) else { return nil }
        return (cursor, wasUpperCase)
    }

    /// Whether a token ending at `end` is punctuated as a LABEL rather than
    /// used as a word: `error:` or `[error]`.
    ///
    /// Looks at exactly ONE character past the token, never more. An earlier
    /// version skipped spaces before requiring the colon, which was both
    /// unbounded — it walked to end of line, so a row with 200,000 spaces in it
    /// still scored `.error`, falsifying the ≤8-character lookahead this file
    /// claims — and wrong: `error       : 0` is a column in an aligned summary
    /// reporting ZERO errors, not a label. A label is written `error:`, flush
    /// against its colon; whitespace between the two means the colon belongs to
    /// a table, not to the token. No corpus line loses its flag to this: all 21
    /// lower-case labels in the fixture are `error:` or `[error]`, and the 7
    /// aligned `error       : 0` rows this excludes are all reporting ZERO.
    ///
    /// A quoted token (`"error"`, `'error'` — JSON's quotes and a Python dict
    /// repr's) is never in label position, whatever follows it. Two shapes,
    /// one reason. `{"msg":"ok","error":null}` names a FIELD, and a field
    /// named `error` is not a claim that one occurred — its VALUE may be, and
    /// that is `json.err`'s job, on the parsed tree rather than on the text.
    /// `{"msg":"error: could not connect"}` puts a real label inside a string,
    /// flush against its colon, where the colon rule above would otherwise
    /// read it — and that is the same prose-inside-a-string that a `.block`
    /// row's fields already take precedence over, applied here to the line
    /// whose block failed to parse. Quoted text is data in both.
    private static func isLabelPosition(
        in text: String, endingAt end: String.Index, precededBy previous: Character?
    ) -> Bool {
        if previous == "\"" || previous == "'" { return false }
        guard end < text.endIndex else { return false }
        if previous == "[" { return text[end] == "]" }
        return text[end] == ":"
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}

// MARK: - Family 4: the emitter's own red

extension SeverityScanner {
    /// Whether any span is red — the emitter's own choice to print this line
    /// in the colour it prints failures in.
    ///
    /// ## Bounded on purpose, and now inert
    ///
    /// This is the weakest signal in the set and the only dirty one. The 30
    /// red lines in the corpus are 6 genuine `studio-api`
    /// errors, 19 genuine vite errors, and 5 copies of Flask's `WARNING: This
    /// is a development server.` boilerplate — printed red on every startup of
    /// every Flask resource, forever. Letting red produce `.error` would put
    /// that boilerplate at the same weight as a crash, so red may promote a
    /// row no further than `.warning`, and only a row that no other rule
    /// matched. It never overrides a rule that fired and it never downgrades
    /// one, which falls out of it being consulted last.
    ///
    /// Since the token rule started reading lower-case label tokens, all 30 of
    /// those lines are claimed by `token.severity` first (25 at `.error`, the
    /// 5 Flask ones at `.warning`), so this rule fires on ZERO rows of the
    /// corpus. It is unit-tested only, and has no corpus validation of its
    /// recall — which is the honest state of it, not a reason to widen it.
    ///
    /// Whitespace-only red spans do not count: a run of red spaces is a
    /// separator or a background bar, not a statement about the line.
    private static func carriesRed(_ spans: [ANSI.Span]) -> Bool {
        spans.contains { span in
            (span.colour == .red || span.colour == .brightRed)
                && span.text.contains { !$0.isWhitespace }
        }
    }
}

// MARK: - Test seam

extension SeverityScanner {
    /// Counts `ANSI.parse` calls made BY the scanner, so a test can assert
    /// "each row is decoded at most once" deterministically instead of
    /// measuring wall-clock time. See `InvocationCounter`, and
    /// `JSONBlock.BraceScanCounter` for the same pattern.
    typealias ANSIParseCounter = InvocationCounter

    /// Same as `scan(_:)`, but increments `counter` once per `ANSI.parse`.
    /// Test-only seam.
    static func scan(_ row: LogRow, countingANSIParsesInto counter: ANSIParseCounter) -> SeverityMatch? {
        scan(row, ansiParseCounter: counter)
    }

    private static func parseANSI(_ message: String, counter: ANSIParseCounter?) -> [ANSI.Span] {
        counter?.increment()
        return ANSI.parse(message)
    }
}
