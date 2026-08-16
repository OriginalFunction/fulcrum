import Foundation

/// Strips and interprets the ANSI SGR (Select Graphic Rendition) escape
/// sequences that show up in tilt log message bodies — build tool output is
/// frequently colourised, and a raw `\u{1B}[32m` on screen is a bug, not a
/// cosmetic detail.
///
/// This is the hot path for the whole log pane (tens of thousands of lines
/// parsed per session), so it is a single forward pass over the string with
/// no `NSRegularExpression` and no intermediate arrays beyond the spans it
/// returns.
public enum ANSI {
    /// A colour SGR can select. Only the 8 standard and 8 "bright" foreground
    /// colours are modelled — the ones actually observed and the ones this
    /// codebase commits to rendering distinctly. 256-colour and truecolour
    /// sequences are recognised (so their bytes are consumed and removed)
    /// but do not resolve to a `Colour`.
    public enum Colour: Sendable, Equatable {
        case black, red, green, yellow, blue, magenta, cyan, white
        case brightBlack, brightRed, brightGreen, brightYellow
        case brightBlue, brightMagenta, brightCyan, brightWhite
    }

    /// A run of text that shares one rendition state. Consecutive spans are
    /// only split where the state actually changes, so plain text with no
    /// escapes at all decodes to exactly one span.
    public struct Span: Sendable, Equatable {
        public let text: String
        public let colour: Colour?
        public let bold: Bool

        public init(text: String, colour: Colour?, bold: Bool) {
            self.text = text
            self.colour = colour
            self.bold = bold
        }
    }

    private static let standardColours: [Colour] = [
        .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white
    ]

    private static let brightColours: [Colour] = [
        .brightBlack, .brightRed, .brightGreen, .brightYellow,
        .brightBlue, .brightMagenta, .brightCyan, .brightWhite
    ]

    /// `raw` with every escape sequence removed — the displayable text and
    /// nothing else. One shared definition rather than a private copy per
    /// caller (`JSONBlock.detect`, `LogRecord.group`), so "what a line
    /// actually says" cannot come to mean two different things in two places.
    static func strip(_ raw: String) -> String {
        parse(raw).map(\.text).joined()
    }

    /// Parses `raw` into displayable spans, discarding every escape byte.
    ///
    /// Recognises CSI SGR sequences (`ESC [ <params> m`) for colour and
    /// bold. Any other CSI sequence (cursor movement, 256-colour/truecolour
    /// extended selectors, anything unrecognised) is consumed and dropped
    /// without changing the current rendition state — never rendered, never
    /// passed through as text. A lone `ESC` not followed by `[`, or a CSI
    /// sequence truncated at end-of-string, is likewise dropped rather than
    /// causing the parser to hang or crash.
    public static func parse(_ raw: String) -> [Span] {
        var spans: [Span] = []
        var buffer = ""
        var colour: Colour?
        var bold = false

        func flush() {
            guard !buffer.isEmpty else { return }
            spans.append(Span(text: buffer, colour: colour, bold: bold))
            buffer = ""
        }

        var index = raw.startIndex
        let end = raw.endIndex

        while index < end {
            let ch = raw[index]
            guard ch == "\u{1B}" else {
                buffer.append(ch)
                index = raw.index(after: index)
                continue
            }

            // Consumed the ESC itself; everything below either finds a
            // complete sequence to interpret or abandons this attempt —
            // either way the ESC byte itself never reaches `buffer`.
            index = raw.index(after: index)

            guard index < end, raw[index] == "[" else {
                // Not a CSI sequence (lone ESC, or ESC followed by
                // something we don't handle, e.g. OSC's "]"). Drop just
                // the ESC and let whatever follows be reprocessed normally.
                continue
            }
            index = raw.index(after: index)

            var params = ""
            while index < end, isParameterOrIntermediateByte(raw[index]) {
                params.append(raw[index])
                index = raw.index(after: index)
            }

            guard index < end else {
                // Truncated at end-of-string: stop cleanly rather than loop
                // or throw. Whatever is already in `buffer` still gets
                // flushed after the loop.
                break
            }

            guard isFinalByte(raw[index]) else {
                // Malformed (not truncated, just not a valid final byte).
                // Abandon this escape attempt without consuming the
                // unexpected byte, and resume scanning from here.
                continue
            }

            let final = raw[index]
            index = raw.index(after: index)

            if final == "m" {
                flush()
                applySGR(params, colour: &colour, bold: &bold)
            }
            // Any other final byte (cursor movement etc.) — the whole
            // sequence is already consumed; simply not applied.
        }

        flush()
        return spans
    }

    /// CSI parameter bytes (`0x30`–`0x3F`: digits, `;`, `:`, and friends)
    /// and intermediate bytes (`0x20`–`0x2F`) — everything between `[` and
    /// the final byte, per ECMA-48.
    private static func isParameterOrIntermediateByte(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (0x20...0x3F).contains(scalar.value)
    }

    /// CSI final bytes (`0x40`–`0x7E`): the letter that ends the sequence,
    /// e.g. `m` for SGR, `A` for cursor-up.
    private static func isFinalByte(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (0x40...0x7E).contains(scalar.value)
    }

    /// Applies an SGR parameter list (already stripped of the `ESC[` … `m`
    /// wrapper) to the running `colour`/`bold` state.
    private static func applySGR(_ params: String, colour: inout Colour?, bold: inout Bool) {
        // An empty parameter list ("\u{1B}[m") means reset, same as "0".
        let codes = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)

        var i = 0
        while i < codes.count {
            defer { i += 1 }
            guard let code = Int(codes[i]) else { continue }

            switch code {
            case 0:
                colour = nil
                bold = false
            case 1:
                bold = true
            case 22:
                bold = false
            case 39:
                colour = nil
            case 30...37:
                colour = standardColours[code - 30]
            case 90...97:
                colour = brightColours[code - 90]
            case 38, 48:
                // Extended foreground/background colour (256-colour or
                // truecolour) — unsupported. Consume the parameters that
                // belong to it so they are not misread as separate codes;
                // leave the current colour untouched either way.
                if i + 1 < codes.count, codes[i + 1] == "5" {
                    i += 2 // "5" + one palette index
                } else if i + 1 < codes.count, codes[i + 1] == "2" {
                    i += 4 // "2" + R + G + B
                }
            default:
                break // unrecognised SGR code — ignore, state unchanged
            }
        }
    }
}
