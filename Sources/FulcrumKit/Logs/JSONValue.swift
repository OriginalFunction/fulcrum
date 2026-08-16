import Foundation

/// A parsed JSON tree for a `JSONBlock.raw` string.
///
/// Object fields are an ORDERED array of pairs, not a `Dictionary`.
/// `JSONSerialization`/`[String: Any]` both lose key order, and a log whose
/// fields reshuffle between renders is unreadable — the user is scanning
/// these to debug, and stable field order is how they find something twice.
public indirect enum JSONValue: Sendable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

extension JSONValue: Equatable {
    // Hand-written: `[(String, JSONValue)]` cannot get a synthesized
    // `Equatable` conformance because a tuple type is not itself `Equatable`
    // (no protocol conformance exists for tuples), even though the free
    // `==` operator for two tuples of `Equatable` elements does exist and
    // is used below.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(l), .object(r)):
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(l), .array(r)):
            return l == r
        case let (.string(l), .string(r)):
            return l == r
        case let (.number(l), .number(r)):
            return l == r
        case let (.bool(l), .bool(r)):
            return l == r
        case (.null, .null):
            return true
        default:
            return false
        }
    }
}

extension JSONValue {
    /// Caps how many container levels (`object`/`array`) the recursive-
    /// descent parser will descend into. A parser without a cap crashes the
    /// whole process on deeply nested input (e.g. 10,000 nested arrays) via
    /// stack overflow — a crash Swift's `do`/`catch` cannot intercept. 512
    /// is generous headroom above anything a real log line produces while
    /// stopping recursion far short of the depth that overflows the stack.
    ///
    /// On hitting the cap, the ENTIRE parse fails (returns `nil`) rather
    /// than returning a tree that is silently truncated at the deepest
    /// levels — a tree missing its deepest levels without saying so would
    /// be a quiet lie about the data. The pane falls back to showing the
    /// raw text instead, which is honest about not having parsed it.
    ///
    /// Read as an exact count: `parseValue(depth:)` is entered with `depth`
    /// 0 for the outermost value, so the guard is `depth < maxDepth` and
    /// exactly 512 container levels are admitted — the 513th fails. (`<=`
    /// on a zero-based depth would have admitted 513 while this comment
    /// claimed 512.)
    private static let maxDepth = 512

    /// Parses `raw` (expected to be `JSONBlock.raw`, already ANSI-stripped
    /// and starting at the first `{`) into a tree. Returns `nil` for any
    /// malformed input — including truncated blocks from a process killed
    /// mid-write — rather than inventing structure for a partial parse.
    public static func parse(_ raw: String) -> JSONValue? {
        var parser = Parser(raw)
        guard let value = parser.parseValue(depth: 0) else { return nil }
        parser.skipWhitespace()
        guard parser.isAtEnd else { return nil }
        return value
    }

    /// Hand-rolled recursive-descent scanner over UTF-8 bytes. Not
    /// `JSONDecoder`/`JSONSerialization` — both erase object key order.
    private struct Parser {
        let bytes: [UInt8]
        var index: Int = 0

        init(_ s: String) { bytes = Array(s.utf8) }

        var isAtEnd: Bool { index >= bytes.count }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let b = peek(), b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                index += 1
            }
        }

        mutating func parseValue(depth: Int) -> JSONValue? {
            guard depth < JSONValue.maxDepth else { return nil }
            skipWhitespace()
            guard let b = peek() else { return nil }
            switch b {
            case UInt8(ascii: "{"):
                return parseObject(depth: depth)
            case UInt8(ascii: "["):
                return parseArray(depth: depth)
            case UInt8(ascii: "\""):
                return parseString().map(JSONValue.string)
            case UInt8(ascii: "t"):
                return parseLiteral("true", .bool(true))
            case UInt8(ascii: "f"):
                return parseLiteral("false", .bool(false))
            case UInt8(ascii: "n"):
                return parseLiteral("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return parseNumber()
            default:
                return nil
            }
        }

        mutating func parseObject(depth: Int) -> JSONValue? {
            index += 1 // consume '{'
            skipWhitespace()
            var pairs: [(String, JSONValue)] = []
            if peek() == UInt8(ascii: "}") {
                index += 1
                return .object(pairs)
            }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else { return nil }
                guard let key = parseString() else { return nil }
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = parseValue(depth: depth + 1) else { return nil }
                pairs.append((key, value))
                skipWhitespace()
                guard let b = peek() else { return nil }
                if b == UInt8(ascii: ",") {
                    index += 1
                    continue
                } else if b == UInt8(ascii: "}") {
                    index += 1
                    return .object(pairs)
                } else {
                    return nil
                }
            }
        }

        mutating func parseArray(depth: Int) -> JSONValue? {
            index += 1 // consume '['
            skipWhitespace()
            var items: [JSONValue] = []
            if peek() == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                guard let value = parseValue(depth: depth + 1) else { return nil }
                items.append(value)
                skipWhitespace()
                guard let b = peek() else { return nil }
                if b == UInt8(ascii: ",") {
                    index += 1
                    continue
                } else if b == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                } else {
                    return nil
                }
            }
        }

        /// Parses a JSON string literal starting at the current `"`.
        /// Accumulates unescaped runs as byte ranges and decodes them as
        /// UTF-8 in one shot (rather than appending byte-by-byte), so
        /// multi-byte characters in the source are not corrupted.
        mutating func parseString() -> String? {
            guard peek() == UInt8(ascii: "\"") else { return nil }
            index += 1
            var result = ""
            var runStart = index
            while true {
                guard index < bytes.count else { return nil } // unterminated
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    if index > runStart {
                        result += String(decoding: bytes[runStart..<index], as: UTF8.self)
                    }
                    index += 1
                    return result
                } else if b == UInt8(ascii: "\\") {
                    if index > runStart {
                        result += String(decoding: bytes[runStart..<index], as: UTF8.self)
                    }
                    index += 1
                    guard index < bytes.count else { return nil }
                    let esc = bytes[index]
                    index += 1
                    switch esc {
                    case UInt8(ascii: "\""): result.append("\"")
                    case UInt8(ascii: "\\"): result.append("\\")
                    case UInt8(ascii: "/"): result.append("/")
                    case UInt8(ascii: "b"): result.append(Character(Unicode.Scalar(0x08)))
                    case UInt8(ascii: "f"): result.append(Character(Unicode.Scalar(0x0C)))
                    case UInt8(ascii: "n"): result.append("\n")
                    case UInt8(ascii: "r"): result.append("\r")
                    case UInt8(ascii: "t"): result.append("\t")
                    case UInt8(ascii: "u"):
                        guard let code = readHex4() else { return nil }
                        if (0xD800...0xDBFF).contains(code) {
                            guard index + 1 < bytes.count,
                                  bytes[index] == UInt8(ascii: "\\"),
                                  bytes[index + 1] == UInt8(ascii: "u") else { return nil }
                            index += 2
                            guard let low = readHex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                            let combined = 0x10000 + (Int(code) - 0xD800) * 0x400 + (Int(low) - 0xDC00)
                            guard let scalar = Unicode.Scalar(combined) else { return nil }
                            result.append(Character(scalar))
                        } else if (0xDC00...0xDFFF).contains(code) {
                            return nil // unpaired low surrogate
                        } else if let scalar = Unicode.Scalar(code) {
                            result.append(Character(scalar))
                        } else {
                            return nil
                        }
                    default:
                        return nil
                    }
                    runStart = index
                } else if b < 0x20 {
                    return nil // raw control characters are not valid in a JSON string
                } else {
                    index += 1
                }
            }
        }

        mutating func readHex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = Self.hexDigit(bytes[index]) else { return nil }
                value = value << 4 | UInt32(digit)
                index += 1
            }
            return value
        }

        static func hexDigit(_ b: UInt8) -> UInt8? {
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
            default: return nil
            }
        }

        mutating func parseNumber() -> JSONValue? {
            let start = index
            if peek() == UInt8(ascii: "-") { index += 1 }
            guard let first = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { return nil }
            if first == UInt8(ascii: "0") {
                index += 1
            } else {
                while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { index += 1 }
            }
            if peek() == UInt8(ascii: ".") {
                index += 1
                guard let d = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(d) else { return nil }
                while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { index += 1 }
            }
            if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
                index += 1
                if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
                guard let d = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(d) else { return nil }
                while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { index += 1 }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(text) else { return nil }
            return .number(value)
        }

        mutating func parseLiteral(_ text: String, _ value: JSONValue) -> JSONValue? {
            let literalBytes = Array(text.utf8)
            guard index + literalBytes.count <= bytes.count else { return nil }
            for i in 0..<literalBytes.count where bytes[index + i] != literalBytes[i] {
                return nil
            }
            index += literalBytes.count
            return value
        }
    }
}

extension JSONValue {
    /// The collapsed one-line preview shown before a block is expanded,
    /// e.g. `{status: "success", data: {…}}`. Named fields (not just
    /// "Object") because this is what a user scans to decide whether to
    /// expand — an uninformative preview defeats the point of collapsing.
    ///
    /// Nested containers below the top level render as `{…}`/`[…]` rather
    /// than recursing fully; the summary is a preview, not the full tree.
    /// If the rendered text exceeds `maxLength`, it is cut and an ellipsis
    /// appended — truncation is visible, never a silently shortened value
    /// that looks complete.
    public func summary(maxLength: Int) -> String {
        let full = Self.previewText(self, topLevel: true)
        guard full.count > maxLength else { return full }
        let marker = "…"
        let keep = max(0, maxLength - marker.count)
        return String(full.prefix(keep)) + marker
    }

    private static func previewText(_ value: JSONValue, topLevel: Bool) -> String {
        switch value {
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            guard topLevel else { return "{…}" }
            let fields = pairs.map { "\($0.0): \(previewText($0.1, topLevel: false))" }
            return "{" + fields.joined(separator: ", ") + "}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            guard topLevel else { return "[…]" }
            let fields = items.map { previewText($0, topLevel: false) }
            return "[" + fields.joined(separator: ", ") + "]"
        case .string(let s):
            return "\"\(s)\""
        case .number(let n):
            return formatNumber(n)
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        }
    }

    /// Formats a number for display without ever falling back to
    /// scientific notation for ordinary log values. Real `_aws` blobs carry
    /// millisecond Unix timestamps like `1786493715538` — 13 digits, well
    /// within the ~15-16 significant decimal digits a `Double` represents
    /// exactly (up to 2^53 ≈ 9.007e15) — and those must read as a plain
    /// integer, not `1.786493715538e+12`. Non-integer values fall back to
    /// `Double`'s own description, which Swift keeps in fixed notation for
    /// the range of magnitudes real log values (durations, ratios) fall
    /// in; it only switches to scientific notation for magnitudes far
    /// outside what this pane's inputs measured.
    ///
    /// The integral cutoff is 2^53 — the largest magnitude at which every
    /// integer is still exactly representable as a `Double` — not a round
    /// `1e15`. A 16-digit integer such as a nanosecond timestamp or a
    /// Snowflake-style ID sits between the two, and at `1e15` it fell
    /// through to `String(Double)` and printed as `9007199254740992.0`: a
    /// decimal point on a value that has none. Above 2^53 the `Double` no
    /// longer holds the integer exactly, so printing it as a bare integer
    /// would assert a precision that is not there; `String(Double)` is the
    /// honest rendering from that point on.
    private static let largestExactIntegralDouble = 9_007_199_254_740_992.0 // 2^53

    private static func formatNumber(_ n: Double) -> String {
        guard n.isFinite else { return n.isNaN ? "NaN" : (n > 0 ? "Infinity" : "-Infinity") }
        if n == n.rounded(), abs(n) <= largestExactIntegralDouble {
            return String(Int64(n))
        }
        let text = String(n)
        // Swift's own `Double` description switches to scientific notation
        // below 1e-4 (e.g. `String(0.000001234)` is `"1.234e-06"`) — that is
        // Swift's internal representation leaking into a log viewer, not
        // something a real `_aws` blob's fractional fields (durations,
        // ratios) should render as. Only NEGATIVE exponents are expanded
        // here: those are exactly the small-magnitude case this pane's users
        // hit (a ratio, a duration in seconds), and the ordinary
        // `String(Double)` fixed-notation range this function already relied
        // on for everything else (0.48, 842.5, …) never has an `e` in it, so
        // this branch only ever fires for magnitudes below 1e-4.
        //
        // Reformatted by re-anchoring the decimal point on Swift's own
        // mantissa digits, not by re-rendering through `%f` — `%f` at a fixed
        // precision would either truncate or pad with digits `Double`'s own
        // shortest-round-trip algorithm never produced, silently asserting
        // more (or less) precision than is actually there.
        guard let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return text }
        let mantissa = text[text.startIndex..<eIndex]
        let exponentText = text[text.index(after: eIndex)...]
        guard let exponent = Int(exponentText), exponent < 0 else { return text }
        return expandToPlainDecimal(mantissa: String(mantissa), exponent: exponent)
    }

    /// Rewrites a normalized scientific-notation mantissa (Swift always
    /// prints exactly one digit before the point, e.g. `"1.234"` or `"-1"`)
    /// as a plain `"0.000..."` decimal, given the (negative) power of ten
    /// `exponent` that mantissa was scaled by.
    private static func expandToPlainDecimal(mantissa: String, exponent: Int) -> String {
        var digits = mantissa
        let isNegative = digits.hasPrefix("-")
        if isNegative { digits.removeFirst() }
        let parts = digits.split(separator: ".", maxSplits: 1)
        let wholeDigitCount = parts.first?.count ?? 0
        let allDigits = parts.joined()
        let leadingZeros = String(repeating: "0", count: max(0, -exponent - wholeDigitCount))
        let result = "0." + leadingZeros + allDigits
        return isNegative ? "-" + result : result
    }
}

extension JSONValue {
    /// Renders this value back to JSON text — the log pane's "Copy Value"
    /// context menu on an individual tree node (`JSONTreeView`, the Fulcrum
    /// app target) and "Copy JSON" both need real, pasteable text, not
    /// `summary(maxLength:)`'s truncated preview. Unlike `summary`, this
    /// recurses all the way down and is never cut short.
    ///
    /// `pretty` (default `true`) indents nested containers two spaces per
    /// level, the way a developer would format it by hand; `false` is one
    /// compact line.
    ///
    /// Numbers reuse `formatNumber` — the identical integral-vs-`Double`
    /// formatting `summary` uses, so a copied `_aws` millisecond timestamp
    /// reads as plain digits here too, not scientific notation.
    public func jsonText(pretty: Bool = true) -> String {
        Self.render(self, indent: 0, pretty: pretty)
    }

    private static func render(_ value: JSONValue, indent: Int, pretty: Bool) -> String {
        let childPad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: indent) : ""
        let nl = pretty ? "\n" : ""
        let sep = pretty ? ",\n" : ","

        switch value {
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            let fields = pairs.map { key, fieldValue in
                "\(childPad)\"\(escapeJSONString(key))\": \(render(fieldValue, indent: indent + 1, pretty: pretty))"
            }
            return "{\(nl)" + fields.joined(separator: sep) + "\(nl)\(closePad)}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let entries = items.map { "\(childPad)\(render($0, indent: indent + 1, pretty: pretty))" }
            return "[\(nl)" + entries.joined(separator: sep) + "\(nl)\(closePad)]"
        case .string(let s):
            return "\"\(escapeJSONString(s))\""
        case .number(let n):
            return formatNumber(n)
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        }
    }

    /// Escapes a string for JSON output. `JSONValue.Parser.parseString()`
    /// rejects raw control bytes inside a string literal on the way IN
    /// (`b < 0x20` returns `nil`) — this is that guard's mirror image on the
    /// way out, `\u{...}`-escaping the same characters rather than emitting
    /// them literally, so copied text always round-trips back through
    /// `JSONValue.parse`.
    private static func escapeJSONString(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}
