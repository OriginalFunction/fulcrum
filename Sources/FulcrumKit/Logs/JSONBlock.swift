import Foundation

/// A run of consecutive `LogLine`s whose message text is a single JSON
/// object — either a compact one-liner or a multi-line, pretty-printed one.
///
/// Grouping exists because pino-style services routinely log a JSON object
/// across several physical lines, e.g.:
/// ```
/// res: {
///   "statusCode": 200,
///   "headers": {}
/// }
/// ```
/// Searching the log pane for `statusCode` and matching only the
/// `"statusCode": 200,` fragment loses the `res:` line above it — the only
/// place the correlation context lives. `JSONBlock.detect(in:)` groups the
/// block so the pane can show (and filter against) it as one unit.
///
/// A `JSONBlock` only ever exists for text that actually PARSED — `value`
/// is non-optional, and `detect(in:)` is the only thing that builds one.
/// See `detect(in:)`'s doc comment for why parseability, not brace balance,
/// is the gate.
public struct JSONBlock: Sendable, Equatable {
    /// Text preceding the JSON's opening `{` on the same line, e.g. `"res:"`
    /// for a pino-style `res: {`. `nil` when the line is bare `{` (or the
    /// object opens at column zero on a single-line block).
    public let label: String?
    /// The block's lines, ANSI-stripped and re-joined with `"\n"`, starting
    /// at the opening `{` — `label` is deliberately excluded so this is
    /// parseable as JSON on its own. Guaranteed to parse: it is exactly the
    /// text `value` was parsed from.
    public let raw: String
    /// How many `LogLine`s this block spans (1 for a compact single-line
    /// object).
    public let lineCount: Int
    /// `raw`'s parsed tree. Held rather than re-derived because the pane
    /// needs it to render (field names, collapsed summary, per-field tinting)
    /// and `detect(in:)` has already paid for it: parsing is what proved this
    /// was a block at all, so throwing the result away would mean parsing the
    /// same text a second time on every render.
    public let value: JSONValue

    public init(label: String?, raw: String, lineCount: Int, value: JSONValue) {
        self.label = label
        self.raw = raw
        self.lineCount = lineCount
        self.value = value
    }
}

/// One row in the log pane's display list: either an ordinary line, or a
/// `JSONBlock` together with the `BufferedLine`s it groups (kept alongside the
/// block so the pane can still show their individual timestamps/resource,
/// and so filtering can match against the whole block's text).
///
/// Rows hold `BufferedLine`s, not bare `LogLine`s, purely so that every row
/// has an identity — see `LogRow.ID`. Nothing else in detection, filtering or
/// grouping reads the sequence number; those all work off `BufferedLine.line`.
public enum LogRow: Sendable, Equatable {
    case line(BufferedLine)
    case block(JSONBlock, lines: [BufferedLine])
}

extension LogRow {
    /// The `BufferedLine`s this row covers, in order — one for a `.line`, the
    /// whole grouped run for a `.block`. The single place that flattens a
    /// row back to lines, so record grouping, filtering and tests all agree
    /// on what a row's lines are.
    ///
    /// Never empty: `.line` carries exactly one, and `JSONBlock.detect(in:)`
    /// — the only thing that builds a `.block` — always includes at least the
    /// opening line the block was detected from.
    var lines: [BufferedLine] {
        switch self {
        case .line(let line): [line]
        case .block(_, let lines): lines
        }
    }
}

extension LogRow: Identifiable {
    /// A row's identity across rebuilds of the `[LogRow]` array it lives in —
    /// what `LogPaneView`'s `ForEach(pane.rows)` renders against, and what
    /// `LogPaneModel.expandedBlockIDs` keys on to remember which blocks the
    /// user has expanded.
    ///
    /// The sequence number `LogBuffer` stamped on the row's FIRST line, and
    /// nothing else. Rows partition the buffer's lines into consecutive,
    /// non-empty, disjoint runs, so every row starts at a different line and
    /// therefore at a different sequence number: ids here cannot collide, by
    /// construction rather than by observation.
    ///
    /// ## Not the index, and not the content either
    ///
    /// Deliberately NOT the row's index in the array. `LogPaneModel` reruns
    /// `JSONBlock.detect(in:)` whenever its line snapshot changes, and
    /// `LogBuffer` evicts oldest-first once the stream passes 5,000 lines —
    /// both change *where* a given block sits in the rebuilt array without
    /// changing the block itself. An index-keyed `Set` would silently point
    /// at whatever row now happens to occupy that position: the block the
    /// user expanded collapses, and — worse — an unrelated row that slides
    /// into the vacated index reads as expanded when the user never touched
    /// it. A sequence number is immune: eviction shifts positions, never
    /// numbers.
    ///
    /// This was ALSO keyed on the row's own content — the whole `LogLine` for
    /// `.line`, the full ordered run for `.block` — and that shipped as a
    /// known, accepted limitation: two emissions matching field-for-field
    /// would collide, judged cosmetic ("one indistinguishable block's
    /// expansion state applying to another"). That ruling was wrong, and it
    /// cost the log pane outright. `LogLine.time` is second-resolution, so
    /// byte-identical lines emitted within the same second from the same
    /// resource and span are genuinely indistinguishable by content; a live
    /// instance with repetitive output made that constant rather than rare.
    /// Measured over a 2,000-line capture from it: 1,214 rows, 216 distinct
    /// ids, 998 surplus. SwiftUI's `ForEach` requires unique ids, and given
    /// duplicates it does not merely mis-attribute expansion state — it
    /// renders incorrectly, and here it rendered NOTHING AT ALL. The failure
    /// mode is the pane going blank, not a cosmetic mix-up.
    ///
    /// See `LogPaneModelTests.repetitiveIdenticalLinesStillGetDistinctRowIdentities`,
    /// which reproduces that shape and asserts every row's id is distinct.
    public struct ID: Sendable, Hashable {
        /// `BufferedLine.sequence` of the row's first line.
        public let sequence: Int

        public init(sequence: Int) {
            self.sequence = sequence
        }
    }

    public var id: ID {
        switch self {
        case .line(let buffered):
            ID(sequence: buffered.sequence)
        case .block(_, let lines):
            // `lines` is non-empty for every block `detect(in:)` builds (see
            // `LogRow.lines`). The fallback is unreachable there; it exists so
            // a hand-constructed empty block cannot trap the render pass.
            ID(sequence: lines.first?.sequence ?? .min)
        }
    }
}

extension JSONBlock {
    /// Caps how many lines a single block may span. The measured maximum
    /// across 1,500 real lines was 8; 200 is generous headroom above that.
    /// Exists so a process killed mid-write — leaving an opening `{` with no
    /// matching close — can't turn the rest of the buffer into one runaway
    /// "block". When the cap is hit, detection gives up on that opener and
    /// falls back to plain `.line` rows instead.
    private static let maxBlockLines = 200

    /// Groups `lines` into `LogRow`s, detecting JSON objects — single-line
    /// or multi-line — by tracking brace depth in one forward pass and then
    /// requiring the candidate to actually parse.
    ///
    /// ## Parseability is the gate, not brace balance
    ///
    /// Brace depth alone finds *candidates*; `JSONValue.parse` decides. Over
    /// 21,224 lines captured live, brace balance alone produced 48 "blocks"
    /// that no JSON parser accepts, swallowing 394 lines into collapsed rows
    /// the user could no longer read individually. The worst of those were
    /// Node stack traces — `    at async <anonymous> (…/routes.ts:95:20) {`
    /// opens a perfectly balanced 9-line span — and `util.inspect` output
    /// (`Loaded config: {`, 20 lines, unquoted keys, `undefined` values). A
    /// collapsed stack trace is precisely the thing a developer most needs to
    /// read, so a construct that does not parse is not a block: its lines are
    /// emitted as ordinary `.line` rows.
    ///
    /// Cost of the gate: one `JSONValue.parse` per candidate that closed its
    /// braces — 1,078 parses over those 21,224 lines. Parsing only ever
    /// touches bytes that are inside a candidate block, so the total is
    /// bounded by the buffer's own size and stays the same order as detection
    /// itself. The tree is kept on the block (`JSONBlock.value`) rather than
    /// discarded, so the pane never re-parses to render.
    ///
    /// ## Resource and span boundary
    ///
    /// tilt's log stream is globally interleaved: consecutive lines routinely
    /// come from different resources. A block may therefore only absorb lines
    /// carrying the SAME `resource` *and* `spanID` as its opener; a line from
    /// anywhere else ends the candidate, which then falls back to plain rows.
    /// Without that, a `platform-backend` block opened by `request: {`
    /// absorbed an `nginx-proxy` access-log line, which stopped existing as a
    /// row of its own — 3 blocks swallowed 23 foreign lines in the measured
    /// sample.
    ///
    /// `spanID` is checked in addition to `resource` because it is strictly
    /// finer and costs nothing measured: no block in the sample was
    /// single-resource but multi-span, so the two boundaries reject exactly
    /// the same 23 lines today. What `spanID` additionally catches is one
    /// resource emitting on two streams at once — 37 resources in the sample
    /// carried more than one span (`build:141` and
    /// `cmd:management-shared-build:update`, or `build:6` and
    /// `localserve:1`), and 88 adjacent line pairs switched span *without*
    /// switching resource. A resource-only boundary would let a build-log
    /// line land inside a runtime JSON block for the same resource.
    ///
    /// ## Scanning
    ///
    /// Detection runs on ANSI-STRIPPED text, not raw. Real tilt output has
    /// colour codes sitting between a label and its brace — e.g.
    /// `res: \u{1B}[36m{` — which would make "line ends in `{`" fail on the
    /// raw bytes even though the visible line plainly ends in `{`. Escape
    /// bytes themselves never contain literal `{`/`"`, so stripping first is
    /// safe: it can only remove noise, never a real brace or quote the depth
    /// counter needs to see.
    ///
    /// Deliberately NOT indentation-based — ordinary pino continuation lines
    /// (e.g. `    tenant: "contoso"`) are indented but are not JSON at all.
    /// Brace depth is the only structural signal used; a `{` inside a quoted
    /// string (tracked with escape handling, so `\"` does not end the string)
    /// never opens a block.
    ///
    /// Each line's characters are scanned exactly ONCE, up front, and every
    /// later step reuses that cached scan — see `advancing(_:by:)`. Before,
    /// an opener that failed to close rescanned up to `maxBlockLines`
    /// characters-and-all for every candidate, making a buffer of 5,000
    /// consecutive `res: {` openers cost 5,000 × 200 line scans (measured
    /// 0.69s) rather than 5,000.
    /// ## Identity
    ///
    /// Takes `BufferedLine`s rather than bare `LogLine`s solely so the
    /// sequence number `LogBuffer` stamped at append time reaches the rows
    /// this builds — that number is a row's whole identity (`LogRow.ID`), and
    /// detection is the step between the buffer and the pane. Nothing below
    /// reads it: every scanning, boundary and parsing decision here is made
    /// on `BufferedLine.line`, exactly as before.
    public static func detect(in lines: [BufferedLine]) -> [LogRow] {
        detect(in: lines, braceScanCounter: nil)
    }

    static func detect(in lines: [BufferedLine], braceScanCounter: BraceScanCounter?) -> [LogRow] {
        // Strip ANSI, trim, and brace-scan once per line up front rather than
        // per detection attempt — this keeps the whole scan a single forward
        // pass over the buffer's total content rather than re-parsing escapes
        // and re-counting braces repeatedly.
        var stripped: [String] = []
        var trimmed: [String] = []
        var scans: [BraceScan] = []
        stripped.reserveCapacity(lines.count)
        trimmed.reserveCapacity(lines.count)
        scans.reserveCapacity(lines.count)
        for buffered in lines {
            let text = ANSI.strip(buffered.line.message)
            let t = text.trimmingCharacters(in: .whitespaces)
            stripped.append(text)
            trimmed.append(t)
            // Whitespace carries no brace-scan meaning, so scanning the
            // trimmed text is equivalent to scanning `text` — and it is the
            // string `openerInfo` needs indices into.
            scans.append(scanBraces(t, depth: 0, insideString: false, escaped: false, counter: braceScanCounter))
        }

        var rows: [LogRow] = []
        var index = 0

        while index < lines.count {
            if let block = compactBlock(trimmed[index], scan: scans[index]) {
                rows.append(.block(block, lines: [lines[index]]))
                index += 1
                continue
            }

            if let opener = openerInfo(trimmed[index], scan: scans[index]),
               let found = scanBlock(
                   startingAt: index, opener: opener,
                   lines: lines, stripped: stripped, trimmed: trimmed, scans: scans,
                   counter: braceScanCounter
               ) {
                rows.append(.block(found.block, lines: found.lines))
                index += found.lines.count
                continue
            }

            rows.append(.line(lines[index]))
            index += 1
        }

        return rows
    }

    /// A one-line block: `trimmed` is on its own one complete balanced JSON
    /// object (starts `{`, ends `}`, depth returns to exactly zero without
    /// ever going negative) AND it parses. Returns `nil` otherwise — a
    /// brace-balanced line that is not JSON, e.g. `{ [cause]: Error }`, stays
    /// an ordinary row.
    private static func compactBlock(_ trimmed: String, scan: BraceScan) -> JSONBlock? {
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        guard scan.depth == 0, !scan.wentNegative else { return nil }
        guard let parsed = parseAllowingOneTrailingComma(trimmed) else { return nil }
        return JSONBlock(label: nil, raw: parsed.raw, lineCount: 1, value: parsed.value)
    }

    /// True when `trimmed` opens a multi-line block: it ends in `{`, and
    /// scanning the whole line leaves depth positive (an unclosed `{`)
    /// without ever going negative. Returns the label text before the JSON's
    /// first `{` (nil if there is none) and the JSON-only text of this first
    /// line (from the first `{` onward — the label is not part of it).
    private static func openerInfo(_ trimmed: String, scan: BraceScan) -> (label: String?, jsonHead: String)? {
        guard trimmed.hasSuffix("{") else { return nil }
        guard scan.depth > 0, !scan.wentNegative, let firstOpen = scan.firstOpenIndex else { return nil }

        let labelText = trimmed[..<firstOpen].trimmingCharacters(in: .whitespaces)
        let jsonHead = String(trimmed[firstOpen...])
        return (labelText.isEmpty ? nil : labelText, jsonHead)
    }

    /// Scans forward from `index` (already known to open a block) looking for
    /// the line where brace depth returns to zero, then requires the result
    /// to parse. Returns `nil` — no block, caller falls back to plain rows
    /// one line at a time — when the depth goes negative (malformed), the
    /// closer isn't found within `maxBlockLines`, a line from a different
    /// resource/span arrives first, or the collected text does not parse.
    private static func scanBlock(
        startingAt index: Int,
        opener: (label: String?, jsonHead: String),
        lines: [BufferedLine],
        stripped: [String],
        trimmed: [String],
        scans: [BraceScan],
        counter: BraceScanCounter?
    ) -> (block: JSONBlock, lines: [BufferedLine])? {
        // The opener's own scan is reused rather than rescanning `jsonHead`:
        // everything before the JSON's first `{` is label text that provably
        // contributes nothing to the scan state. It holds no `{` (this IS the
        // first one at depth zero), no `}` (that would have gone negative,
        // which `openerInfo` rejects), and left no open string (a `{` inside
        // a string is never counted, so we could not be looking at one).
        var state = scans[index]
        if state.wentNegative { return nil }

        var raw = [opener.jsonHead]
        var collected = [lines[index]]
        let origin = lines[index].line

        var lineIndex = index
        while state.depth > 0 {
            lineIndex += 1
            guard lineIndex < lines.count, lineIndex - index < maxBlockLines else { return nil }

            let candidate = lines[lineIndex].line
            // The interleaving boundary — see `detect(in:)`'s doc comment.
            guard origin.isSameStream(as: candidate) else { return nil }

            if state.insideString || state.escaped {
                // A JSON string cannot contain a raw newline, so reaching a
                // line boundary mid-string means this is not JSON anyway; the
                // cached clean-entry scan does not apply, so scan for real.
                state = scanBraces(
                    trimmed[lineIndex], depth: state.depth,
                    insideString: state.insideString, escaped: state.escaped,
                    counter: counter
                )
            } else {
                state = advancing(state, by: scans[lineIndex])
            }
            if state.wentNegative { return nil }

            raw.append(stripped[lineIndex])
            collected.append(lines[lineIndex])
        }

        guard let parsed = parseAllowingOneTrailingComma(raw.joined(separator: "\n")) else { return nil }
        let block = JSONBlock(
            label: opener.label, raw: parsed.raw,
            lineCount: collected.count, value: parsed.value
        )
        return (block, collected)
    }

    /// `JSONValue.parse`, retrying exactly once with a single trailing comma
    /// removed.
    ///
    /// Not a general JSON-repair pass — one specific measured shape. A
    /// pretty-printed object nested inside a larger structure closes on
    /// `      },`: the comma belongs to the ENCLOSING object, which the block
    /// never included, so it reads as trailing garbage and the parse fails.
    /// That accounted for 40 of the 48 parse failures over 21,224 live lines
    /// (the `fda-form-2253-form-fields` field list, repeated per field).
    /// Anything else that fails to parse is simply not a block.
    ///
    /// Returns the text that actually parsed, so `JSONBlock.raw` and
    /// `JSONBlock.value` always agree.
    private static func parseAllowingOneTrailingComma(_ raw: String) -> (raw: String, value: JSONValue)? {
        if let value = JSONValue.parse(raw) { return (raw, value) }
        guard let last = raw.lastIndex(where: { !$0.isWhitespace }), raw[last] == "," else { return nil }
        var withoutComma = raw
        withoutComma.remove(at: last)
        guard let value = JSONValue.parse(withoutComma) else { return nil }
        return (withoutComma, value)
    }

    struct BraceScan {
        var depth: Int
        /// The lowest depth reached anywhere during the scan, including the
        /// depth it started at. `wentNegative` derives from this, and it is
        /// what lets a cached clean-entry scan be replayed at a different
        /// starting depth (see `advancing(_:by:)`).
        var minDepth: Int
        var insideString: Bool
        var escaped: Bool
        var firstOpenIndex: String.Index?

        var wentNegative: Bool { minDepth < 0 }
    }

    /// Replays `cached` — a line's scan from a clean (depth 0, not in a
    /// string) entry — on top of `state`. Depth changes are additive and the
    /// in-string/escape state at the line's end depends only on the line
    /// itself, so this is exactly what rescanning that line's characters at
    /// `state.depth` would have produced, without touching them again.
    ///
    /// Only valid when `state` is not mid-string or mid-escape; the caller
    /// checks that and falls back to a live scan otherwise.
    private static func advancing(_ state: BraceScan, by cached: BraceScan) -> BraceScan {
        BraceScan(
            depth: state.depth + cached.depth,
            minDepth: min(state.minDepth, state.depth + cached.minDepth),
            insideString: cached.insideString,
            escaped: cached.escaped,
            firstOpenIndex: nil
        )
    }

    /// One forward pass over `text`, tracking brace depth with an
    /// in-string flag and backslash-escape handling (`\"` inside a string
    /// does not end it, so a `{` inside a quoted string never counts). No
    /// `NSRegularExpression` — this runs over every line in the buffer.
    ///
    /// `firstOpenIndex` records the position of the first `{` encountered
    /// while `depth` was still zero (i.e. the JSON's own opening brace, as
    /// opposed to a nested one) — used by `openerInfo` to split the line
    /// into label text and JSON text.
    private static func scanBraces(
        _ text: String, depth: Int, insideString: Bool, escaped: Bool,
        counter: BraceScanCounter?
    ) -> BraceScan {
        counter?.increment()

        var depth = depth
        var minDepth = depth
        var insideString = insideString
        var escaped = escaped
        var firstOpenIndex: String.Index?

        for i in text.indices {
            let ch = text[i]

            if insideString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    insideString = false
                }
                continue
            }

            switch ch {
            case "\"":
                insideString = true
            case "{":
                if depth == 0, firstOpenIndex == nil {
                    firstOpenIndex = i
                }
                depth += 1
            case "}":
                depth -= 1
                if depth < minDepth { minDepth = depth }
            default:
                break
            }
        }

        return BraceScan(
            depth: depth, minDepth: minDepth,
            insideString: insideString, escaped: escaped,
            firstOpenIndex: firstOpenIndex
        )
    }
}

extension JSONBlock {
    /// Counts character-level brace scans, so `JSONBlockTests` can assert
    /// "every line is scanned exactly once, however many openers fail"
    /// deterministically instead of measuring wall-clock time. See
    /// `InvocationCounter`.
    typealias BraceScanCounter = InvocationCounter

    /// Same as `detect(in:)`, but increments `counter` once per character
    /// scan of a line. Test-only seam.
    static func detect(in lines: [BufferedLine], countingBraceScansInto counter: BraceScanCounter) -> [LogRow] {
        detect(in: lines, braceScanCounter: counter)
    }
}
