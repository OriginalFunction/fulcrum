import Foundation
import Testing
@testable import FulcrumKit

// MARK: - Helpers

extension LogRow {
    /// TEST-ONLY. A one-line row from bare message text.
    ///
    /// Overloads the `.line` case's own name deliberately: the tests below
    /// read as `.line("…")` because what they are stating is "given this
    /// line", and every field a `LogLine` carries other than `message` and
    /// `level` is noise to them. `SeverityScanner` itself only ever takes a
    /// real `LogRow`, built here through a real `LogBuffer` so the row carries
    /// the same identity the pane's rows do.
    static func line(_ message: String, level: LogLevel = .info) -> LogRow {
        .line(buffered(LogLine(
            time: Date(timeIntervalSince1970: 0), resource: "server",
            level: level, source: .runtime, message: message, spanID: ""
        )))
    }
}

/// TEST-ONLY. A `.block` row for `text` (one line, or several separated by
/// `\n`), built by running the real `JSONBlock.detect(in:)` over it.
///
/// Detection rather than a hand-built `JSONBlock` because a hand-built block
/// can carry a `label`/`value` pairing detection would never produce — and
/// then a rule reading `label` could be tested against a shape that cannot
/// occur. Records an issue rather than returning a fake if the text does not
/// detect as exactly one block, so a malformed fixture in a test fails as
/// itself instead of as a severity mismatch somewhere below.
func block(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> LogRow {
    let lines = buffered(
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line(message: String($0)) }
    )
    let rows = JSONBlock.detect(in: lines)
    guard rows.count == 1, case .block = rows[0] else {
        Issue.record("helper: text did not detect as exactly one JSON block", sourceLocation: sourceLocation)
        return .line(lines[0])
    }
    return rows[0]
}

/// The red the corpus's own emitters use: SGR 31, reset with 39.
private func red(_ text: String) -> String { "\u{1B}[31m\(text)\u{1B}[39m" }

// MARK: - Rule 1: json.level

@Test func aParsedBlockWithPinoLevel50IsAnError() {
    // The emitter's own structured claim — the strongest signal.
    let row = block(#"{"level":50,"msg":"x"}"#)
    #expect(SeverityScanner.matchingRule(for: row) == "json.level")
    #expect(SeverityScanner.severity(of: row) == .error)
}

@Test func aParsedBlockWithPinoLevel30IsNotFlagged() {
    // 30 is pino's `info`. The rule reads the scale, not the presence of the
    // field: a block carrying `level` at all must not be enough to tint it.
    let row = block(#"{"level":30,"msg":"listening on 3000"}"#)
    #expect(SeverityScanner.matchingRule(for: row) == nil)
    #expect(SeverityScanner.severity(of: row) == .normal)
}

// MARK: - Rule 2: json.statusCode

@Test func aParsedBlockWithA5xxStatusCodeIsAnError() {
    let row = block(#"{"statusCode":503,"url":"/api/sessions"}"#)
    #expect(SeverityScanner.matchingRule(for: row) == "json.statusCode")
    #expect(SeverityScanner.severity(of: row) == .error)
}

@Test func aParsedBlockWithA4xxStatusCodeIsAWarning() {
    let row = block(#"{"statusCode":404,"url":"/api/sessions"}"#)
    #expect(SeverityScanner.matchingRule(for: row) == "json.statusCode")
    #expect(SeverityScanner.severity(of: row) == .warning)
}

@Test func aParsedBlockWithA2xxStatusCodeIsNotFlagged() {
    // The precision half of the status rule: ALL 22 of the generated corpus's
    // `statusCode` fields are 200 or 304 (16 and 6), and the multi-line
    // `res: {` shape they arrive in is exactly the shape the rule reads.
    let row = block("""
    res: {
      "statusCode": 200,
      "headers": {}
    }
    """)
    #expect(SeverityScanner.matchingRule(for: row) == nil)
    #expect(SeverityScanner.severity(of: row) == .normal)
}

// MARK: - Rule 3: json.err

@Test func aParsedBlockCarryingAnErrObjectIsAnError() {
    let row = block(#"{"msg":"insert failed","err":{"type":"DatabaseError","message":"no partition"}}"#)
    #expect(SeverityScanner.matchingRule(for: row) == "json.err")
    #expect(SeverityScanner.severity(of: row) == .error)
}

@Test func aLabelledErrBlockSpanningSeveralLinesIsAnError() {
    // pino's multi-line shape: detection puts `err:` in the block's LABEL and
    // only the object in its value, so the key this rule looks for is not in
    // `value` at all.
    //
    // SYNTHETIC, and knowingly so: this block parses. The one the live emitter
    // actually writes does not — see
    // `aLivePinoErrBlockNeverReachesThisRuleBecauseItDoesNotParse` directly
    // below, which is the same shape as it really arrives. This test pins the
    // branch's behaviour, not its recall.
    let row = block("""
    err: {
      "type": "DatabaseError",
      "message": "no partition of relation found for row"
    }
    """)
    #expect(SeverityScanner.matchingRule(for: row) == "json.err")
    #expect(SeverityScanner.severity(of: row) == .error)
}

@Test func aLivePinoErrBlockNeverReachesThisRuleBecauseItDoesNotParse() {
    // The shape a live pino-pretty emitter really writes, transcribed from a
    // read-only capture on 2026-08-15 with its identity replaced by the
    // fixture's fictional system and its stack trimmed to two frames. What is
    // load-bearing here is the STRUCTURE -- `"stack":` followed by raw
    // un-quoted text -- and that is reproduced exactly.
    //
    // pino-pretty writes `"stack":` followed by RAW un-quoted text, which is
    // not JSON — so the `err: {` region never parses, `JSONBlock.detect` hands
    // back one `.line` row per line, and the only thing in there that DOES
    // parse is the inner `"$metadata": {`. `json.err`'s label branch is written
    // for the opener at the top of this fixture and never sees it.
    //
    // This is a statement about what the rule does NOT reach. It is not a
    // reason to loosen the parser: the failure still reaches the user, on the
    // `ERROR` header, via `token.severity` — asserted below so the claim is
    // tested rather than promised.
    let lines = [
        "[2026-08-15 08:08:46.256] \(red("ERROR")) (northwind-account-service): Failed to fetch quota",
        "    err: {",
        #"      "type": "QuotaServiceException","#,
        #"      "message": "The security token included in the request is invalid.","#,
        #"      "stack":"#,
        "          InvalidClientTokenId: The security token included in the request is invalid.",
        "              at throwDefaultError (/app/node_modules/@example/client/dist-cjs/index.js:388:20)",
        "              at de_CommandError (/app/node_modules/@example/client-quota/dist-cjs/index.js:7604:14)",
        #"      "name": "InvalidClientTokenId","#,
        #"      "$metadata": {"#,
        #"        "httpStatusCode": 403,"#,
        #"        "attempts": 1"#,
        "      },",
        #"      "Code": "InvalidClientTokenId""#,
        "    }",
    ]
    let rows = JSONBlock.detect(in: buffered(lines.map {
        line(message: $0, resource: "account-service", spanID: "dc:account-service")
    }))

    // One block only, and it is the `$metadata` sub-object — NOT the `err`
    // opener the rule was written for.
    let blocks = rows.compactMap { row -> JSONBlock? in
        guard case let .block(block, _) = row else { return nil }
        return block
    }
    #expect(blocks.map(\.label) == [#""$metadata":"#])

    // So no row here is claimed by `json.err`, at any severity.
    #expect(rows.allSatisfy { SeverityScanner.matchingRule(for: $0) != "json.err" })

    // The failure is still highlighted, by the header's own token.
    let flagged = rows.filter { SeverityScanner.severity(of: $0) >= .error }
    #expect(flagged.count == 1)
    #expect(flagged.first.map { SeverityScanner.matchingRule(for: $0) } == "token.severity")
    #expect(flagged.first.map { ANSI.strip($0.lines[0].line.message).contains("Failed to fetch quota") } == true)
}

@Test func aBlocksErrObjectOutranksItsOwn4xxStatus() {
    // A block's fields are ONE signal, not three ranked ones. This is an
    // ordinary Node error-handler shape — the handler serialises the error it
    // caught and reports the 404 it turned that into — and taking the first
    // field that matched would silently suppress the error object behind the
    // milder status.
    let row = block(#"{"statusCode":404,"err":{"type":"DatabaseError"}}"#)
    #expect(SeverityScanner.matchingRule(for: row) == "json.err")
    #expect(SeverityScanner.severity(of: row) == .error)
}

@Test func aBlockKeepsTheLoudestOfItsFieldsWhicheverOrderTheyAppearIn() {
    // The same claim from the other side: the winner is the highest severity,
    // not the earliest field, and reversing the field order changes nothing.
    for text in [
        #"{"statusCode":404,"level":50,"msg":"x"}"#,
        #"{"level":50,"statusCode":404,"msg":"x"}"#,
    ] {
        #expect(SeverityScanner.matchingRule(for: block(text)) == "json.level", "\(text)")
        #expect(SeverityScanner.severity(of: block(text)) == .error, "\(text)")
    }
}

@Test func severityWordsInsideABlocksStringsDoNotRaiseIt() {
    // A block's text IS a parsed JSON document, so its severity comes from its
    // fields; the words inside its string VALUES are data. Prose first:
    #expect(SeverityScanner.matchingRule(for: block(#"{"msg":"user asked about ERROR codes","id":7}"#)) == nil)
    #expect(SeverityScanner.severity(of: block(#"{"msg":"user asked about ERROR codes","id":7}"#)) == .normal)

    // And the same rule applied where it costs something: this record's `msg`
    // says FATAL, and the row still scores the `.warning` its FIELDS report.
    // These two shapes are structurally identical — a severity word inside a
    // JSON string — so no rule can read one without reading the other. Scoring
    // this `.fatal` would mean scoring the line above `.error`.
    let row = block(#"{"statusCode":404,"msg":"FATAL: shutting down"}"#)
    #expect(SeverityScanner.matchingRule(for: row) == "json.statusCode")
    #expect(SeverityScanner.severity(of: row) == .warning)
}

@Test func aBlockWhoseErrorFieldIsEmptyIsNotFlagged() {
    // Key presence is not the signal — an object value is. `"error": null` is
    // how an emitter says the opposite, and reading presence alone would tint
    // every successful request that reports its error slot as empty.
    let row = block(#"{"msg":"ok","error":null}"#)
    #expect(SeverityScanner.matchingRule(for: row) == nil)
    #expect(SeverityScanner.severity(of: row) == .normal)
}

// MARK: - Rule 4: tilt.level

@Test func tiltsOwnErrorLevelOnTheLineIsHonoured() {
    // Near-inert in practice: tilt reports `info` on all 3,428 lines of the
    // corpus, so this rule has NO corpus validation of its recall —
    // it is unit-tested only, and deliberately so, because it is free to
    // honour and cannot be wrong about what tilt itself said.
    #expect(SeverityScanner.matchingRule(for: .line("Build Failed", level: .error)) == "tilt.level")
    #expect(SeverityScanner.severity(of: .line("Build Failed", level: .error)) == .error)
    #expect(SeverityScanner.severity(of: .line("slow build", level: .warn)) == .warning)
    #expect(SeverityScanner.severity(of: .line("listening on 3000", level: .info)) == .normal)
}

// MARK: - Rule 5: token.severity

@Test func aLeadingSeverityTokenIsFoundWhereverTheEmitterPutsIt() {
    // The measured shapes. Verbatim from the corpus, at stripped columns 15,
    // 26 and 35 — three different prefixes, one rule. (The corpus also carries
    // the same postgres shape at 36, with a five-digit pid.)
    for message in [
        "[17:42:15.845] ERROR: Failed to fetch render presets",
        "[2026-08-15 04:30:45.981] ERROR (northwind-account-service): Failed to fetch quota",
        "2026-08-10 14:45:25.570 UTC [4103] FATAL:  the database system is in recovery mode",
    ] {
        #expect(SeverityScanner.matchingRule(for: .line(message)) == "token.severity", "\(message)")
        #expect(SeverityScanner.severity(of: .line(message)) >= .error, "\(message)")
    }
}

@Test func anAnsiWrappedSeverityTokenIsStillFound() {
    // Six corpus lines from `studio-api` colour the token itself:
    // `ESC[31mERRORESC[39m`. There is no word boundary between `m` and `E`,
    // so a scan over the RAW bytes matches none of them — a silent 24% miss
    // on this rule's only corpus-validated signal. The scan runs on stripped
    // text for exactly this reason.
    let message = "[17:42:15.845] \(red("ERROR")): Failed to fetch render presets"
    #expect(SeverityScanner.matchingRule(for: .line(message)) == "token.severity")
    #expect(SeverityScanner.severity(of: .line(message)) == .error)
}

@Test func aLowerCaseSeverityLabelIsFoundWhenItIsPunctuatedAsALabel() {
    // Upper case only would miss 21 lines of the corpus, ALL of them genuine
    // failures — these four shapes are the ones that occur, and the mutation
    // is measured, not asserted: forcing `wasUpperCase` takes the flagged set
    // from 46 to 25, and 19 of the 21 fall back to `.warning` via `ansi.red`.
    // A lower-case token counts only where the emitter punctuated it as a
    // label: followed by a colon, or bracketed.
    for message in [
        "12:57:46 PM [vite] (client) Pre-transform error: The service was stopped",
        "1:27:46 PM [vite] Internal server error: The service is no longer running",
        "2026/08/15 05:32:58 [error] 23#23: *21841 upstream prematurely closed connection",
        "    error: \"fetch failed\"",
    ] {
        #expect(SeverityScanner.matchingRule(for: .line(message)) == "token.severity", "\(message)")
        #expect(SeverityScanner.severity(of: .line(message)) == .error, "\(message)")
    }

    // Mixed case in label position counts too — Node's own `Error:` prefix.
    #expect(SeverityScanner.severity(of: .line("Error: connect ECONNREFUSED 127.0.0.1:5432")) == .error)
}

@Test func aQuotedSeverityWordIsDataNotAClaim() {
    // A JSON or dict fragment whose block never parsed stays an ordinary
    // `.line` row, and a token inside quotes is DATA there: a field NAMED
    // `error` is not a claim that one occurred (its value may be, which is
    // `json.err`'s job, on the parsed tree), and a quoted message is the same
    // prose-inside-a-string that `severityWordsInsideABlocksStringsDoNotRaiseIt`
    // refuses to read — applied to the line whose block failed to parse rather
    // than to the block that succeeded.
    //
    // Both quote styles: JSON's, and the single quotes of a Python dict repr
    // that this corpus's Flask services can emit.
    for message in [
        #"  "error": null,"#,
        #"{"msg":"ok","error":null,"#,
        #"  "warning": false,"#,
        #"{'status': 'ok', 'error': None}"#,
        #"  'warning': False,"#,
        // The quoted-VALUE form, which is what makes this guard load-bearing
        // rather than a restatement of the colon rule: the colon here really
        // does sit flush against the token.
        #"{"msg":"error: could not connect to upstream","id":7"#,
        #"{'msg': 'error: could not connect to upstream'"#,
    ] {
        #expect(SeverityScanner.matchingRule(for: .line(message)) == nil, "\(message)")
        #expect(SeverityScanner.severity(of: .line(message)) == .normal, "\(message)")
    }
}

@Test func aTokenSeparatedFromItsColonIsNotALabel() {
    // `error       : 0` is a column in an aligned summary reporting ZERO
    // errors. A label is written flush against its colon; whitespace between
    // the two means the colon belongs to a table, not to the token.
    #expect(SeverityScanner.matchingRule(for: .line("error       : 0")) == nil)
    #expect(SeverityScanner.matchingRule(for: .line("warnings    : 0")) == nil)
    // ONE space is already a gap. Pinned separately because a bound of "one
    // space" passes every other case here while still reading an aligned
    // two-column summary as a severity claim.
    #expect(SeverityScanner.matchingRule(for: .line("error : 0")) == nil)
    #expect(SeverityScanner.matchingRule(for: .line("error: connect ECONNREFUSED")) == "token.severity")

    // And the check never WALKS that gap looking for a colon. An earlier
    // version skipped spaces to end of line, which both mis-read the row above
    // and made the lookahead unbounded — 200,000 spaces walked, per candidate,
    // on a scan this file claims looks at most eight characters ahead. The
    // length of the gap must not change the answer.
    let hugeGap = "error" + String(repeating: " ", count: 200_000) + ": 0"
    #expect(SeverityScanner.matchingRule(for: .line(hugeGap)) == nil)
    #expect(SeverityScanner.severity(of: .line(hugeGap)) == .normal)
}

@Test func aWarningTokenIsAWarningAndNotAnError() {
    // Both spellings, and both must stop short of `.error`: the corpus's
    // WARN/WARNING lines are Flask startup boilerplate, a Java handler and a
    // Go cron job, none of which is a failure.
    for message in [
        "WARNING: This is a development server. Do not use it in a production deployment.",
        "[2026-08-15 05:34:46.873] WARN (northwind-catalog-service): Skipping unknown feature key",
    ] {
        #expect(SeverityScanner.matchingRule(for: .line(message)) == "token.severity", "\(message)")
        #expect(SeverityScanner.severity(of: .line(message)) == .warning, "\(message)")
    }
}

@Test func theWordErrorInProseIsNotASeverityClaim() {
    // THE precision test, and the reason a lower-case token has to stand in
    // label position rather than merely appear: the scan is case-insensitive,
    // so "the error" is a candidate on every one of these lines and is
    // rejected only because prose does not punctuate it as a label.
    //
    // The corpus now carries this surface too, which the capture it replaces
    // did not: dropping the label requirement (making `isLabelPosition` return
    // true) takes the corpus's flagged set from 46 to 79 — 33 false positives,
    // every one of them prose, an `"error": null` field, a Python `'error':
    // None`, or an aligned `error       : 0` column. On the captured corpus
    // that same mutation moved NOTHING, so this test was the only evidence the
    // requirement earned its place. It no longer is.
    for message in [
        "recovered from the error gracefully",
        "handled the error and carried on",
        "no error was returned by the upstream",
        "GET /api/errors 200 12ms",
        "metric ERRORS_TOTAL incremented",
    ] {
        #expect(SeverityScanner.matchingRule(for: .line(message)) == nil, "\(message)")
        #expect(SeverityScanner.severity(of: .line(message)) == .normal, "\(message)")
    }
}

@Test func aSeverityTokenFarIntoTheLineIsIgnored() {
    // A body mentioning "ERROR" hundreds of characters in is data, not a
    // severity claim — three genuine `render-api` errors carry
    // `"severity":"ERROR"` at stripped column 650, and they are flagged by
    // `json.level` reading their `"level":50`, not by this rule reaching that
    // far.
    let far = "audit event payload=\(String(repeating: "a", count: 200)) severity=ERROR"
    #expect(SeverityScanner.matchingRule(for: .line(far)) == nil)
    #expect(SeverityScanner.severity(of: .line(far)) == .normal)

    // The same token, same shape, inside the window: what differs between
    // these two rows is the column, and nothing else.
    let near = "audit event severity=ERROR payload=\(String(repeating: "a", count: 200))"
    #expect(SeverityScanner.matchingRule(for: .line(near)) == "token.severity")
}

@Test func theTokenWindowEndsExactlyAtColumnEighty() {
    // Pins the boundary itself, not just its neighbourhood: the window can be
    // widened threefold before `aSeverityTokenFarIntoTheLineIsIgnored` above
    // notices, because that test's token sits at column 231. These two rows
    // differ by ONE column, so any window other than 80 fails one of them.
    let padding = { (columns: Int) in String(repeating: "-", count: columns) }
    #expect(SeverityScanner.matchingRule(for: .line(padding(79) + "ERROR: boom")) == "token.severity")
    #expect(SeverityScanner.matchingRule(for: .line(padding(80) + "ERROR: boom")) == nil)
}

@Test func stackFramesAreNotErrorsOnTheirOwn() {
    // 24 frames for one failure would light up the pane. They inherit their
    // block's severity; alone they are context, not a claim.
    for message in [
        "    at onResFinished (/app/x.js:115:39)",
        "    at async Object.insertUsageEvents (/app/node_modules/pg-pool/index.js:45:11)",
        "  File \"/app/handler.py\", line 88, in process",
    ] {
        #expect(SeverityScanner.matchingRule(for: .line(message)) == nil, "\(message)")
        #expect(SeverityScanner.severity(of: .line(message)) == .normal, "\(message)")
    }
}

// MARK: - Rule 6: ansi.red

@Test func ansiRedOnlyPromotesALineNoOtherRuleMatched() {
    // Weakest signal, and the dirtiest: of the 30 red lines in the corpus,
    // 5 are Flask's `WARNING: This is a development server` startup
    // boilerplate. It may promote a row nothing else matched to `.warning`;
    // it may never reach `.error`, override a rule that fired, or downgrade.
    // (The line below carries no token at all — every red line in the corpus
    // does carry one, so this rule fires on none of them; see
    // `noCorpusRowIsFlaggedByRedAlone`.)
    let plain = LogRow.line(red("connection reset by peer"))
    #expect(SeverityScanner.matchingRule(for: plain) == "ansi.red")
    #expect(SeverityScanner.severity(of: plain) == .warning)

    // A rule that fired keeps both its name and its severity, red or not.
    let tokenAndRed = LogRow.line("[17:42:15.845] \(red("ERROR")): Failed to fetch render presets")
    #expect(SeverityScanner.matchingRule(for: tokenAndRed) == "token.severity")
    #expect(SeverityScanner.severity(of: tokenAndRed) == .error)

    let blockAndRed = block("{\(red(#""level":50,"msg":"x""#))}")
    #expect(SeverityScanner.matchingRule(for: blockAndRed) == "json.level")
    #expect(SeverityScanner.severity(of: blockAndRed) == .error)

    // And red never lifts a row above `.warning` on its own, however much of
    // the line the emitter coloured.
    #expect(SeverityScanner.severity(of: .line(red("FAILED to connect to upstream"))) == .warning)
}

@Test func aRedSpanOfOnlyWhitespaceIsNotASeverityClaim() {
    // A run of red spaces is a separator or a background bar, not a statement
    // about the line.
    #expect(SeverityScanner.matchingRule(for: .line("\(red("   "))build complete")) == nil)
    #expect(SeverityScanner.severity(of: .line("\(red("   "))build complete")) == .normal)
}

@Test func anUncolouredLineIsNotFlagged() {
    // The base case the whole feature rests on: ordinary traffic stays
    // untinted, which is what makes a tint mean something.
    #expect(SeverityScanner.matchingRule(for: .line("GET /healthz 200 1ms")) == nil)
    #expect(SeverityScanner.severity(of: .line("GET /healthz 200 1ms")) == .normal)
}

// MARK: - Cost

@Test func aLineRowIsAnsiDecodedExactlyOnce() {
    // COUNTS the decode rather than timing the scan — this project has
    // replaced seven timing bounds and does not need an eighth.
    //
    // Named for `.line` rows specifically, which is the property that holds:
    // the token rule and the red rule share ONE decode of the line, whether or
    // not anything fires. A `.block` row does not obey this bound, and the
    // test below states what it does obey instead. (This test was originally
    // named `aRowIsAnsiDecodedAtMostOnce`, which was false for exactly that
    // case while all three of its rows dodged it.)
    let untinted = SeverityScanner.ANSIParseCounter()
    _ = SeverityScanner.scan(.line("GET /healthz 200 1ms"), countingANSIParsesInto: untinted)
    #expect(untinted.count == 1)

    let flagged = SeverityScanner.ANSIParseCounter()
    _ = SeverityScanner.scan(
        .line("[17:42:15.845] \(red("ERROR")): Failed to fetch"), countingANSIParsesInto: flagged
    )
    #expect(flagged.count == 1)

    let coloured = SeverityScanner.ANSIParseCounter()
    _ = SeverityScanner.scan(.line(red("connection reset by peer")), countingANSIParsesInto: coloured)
    #expect(coloured.count == 1)
}

@Test func aBlockIsAnsiDecodedOncePerLineOnlyWhenItsFieldsDoNotAnswer() {
    // The real bound for a block, and the one place in this scanner whose cost
    // scales with a row's line count: the red rule has to look at every line
    // of the block, because a block's own text is ANSI-stripped by detection
    // and the colour survives only on the lines it grouped.
    //
    // Nothing is decoded when the block's fields already answer — the JSON
    // rules read `JSONBlock.value`, which detection already parsed.
    let answered = SeverityScanner.ANSIParseCounter()
    _ = SeverityScanner.scan(block(#"{"level":50,"msg":"x"}"#), countingANSIParsesInto: answered)
    #expect(answered.count == 0)

    // And exactly one per line when they do not: this 200 is not a claim, so
    // the row falls through to red.
    let fellThrough = SeverityScanner.ANSIParseCounter()
    _ = SeverityScanner.scan(
        block("""
        res: {
          "statusCode": 200,
          "headers": {}
        }
        """),
        countingANSIParsesInto: fellThrough
    )
    #expect(fellThrough.count == 4)
}

@Test func oneScanAnswersBothQuestions() {
    // `scan` is the single evaluation `severity(of:)` and `matchingRule(for:)`
    // are conveniences over, so a caller needing both — the pane renders the
    // tint and wants the reason — does not evaluate the rules twice.
    let row = LogRow.line("2026-08-10 14:45:25.570 UTC [4103] FATAL:  the database system is in recovery mode")
    let match = SeverityScanner.scan(row)
    #expect(match == SeverityMatch(rule: "token.severity", severity: .fatal))
    #expect(match?.severity == SeverityScanner.severity(of: row))
    #expect(match?.rule == SeverityScanner.matchingRule(for: row))
    // An un-flagged row used to be asserted here as well, which is
    // `anUncolouredLineIsNotFlagged`'s claim rather than this one's — it says
    // nothing about the two conveniences agreeing with one scan. Left to the
    // test named for it.
}

// MARK: - Ordering

@Test func fatalOutranksError() {
    #expect(LogSeverity.fatal > .error)
    #expect(LogSeverity.error > .warning)
    #expect(LogSeverity.warning > .normal)

    // Within a rule, the strongest claim on the line wins rather than the
    // first one scanned: a line carrying both tokens is fatal.
    #expect(SeverityScanner.severity(of: .line("ERROR: connection lost; FATAL: shutting down")) == .fatal)
    // pino's scale agrees: 60 is fatal, 50 is error.
    #expect(SeverityScanner.severity(of: block(#"{"level":60,"msg":"x"}"#)) == .fatal)
    #expect(SeverityScanner.severity(of: block(#"{"level":50,"msg":"x"}"#)) == .error)
}

// MARK: - The corpus

/// One record of `tilt logs --json`, decoded straight into `LogLine`.
///
/// `LogLine` is `Decodable` against tilt's own field names, so the fixture
/// needs no intermediate shape here — unlike `LogCorpusTests`, which decodes
/// into its own struct precisely because it is asserting on fields (`level`,
/// `progressID`) that `LogLine` does not surface. The bundle lookup the two
/// share is `logCorpusRecords()`, in that file. Rows are then built by the
/// real `JSONBlock.detect(in:)`, because a row is what the scanner scores and
/// three of the corpus's errors are only reachable as blocks.
private func loadCorpusRows() throws -> [LogRow] {
    let decoder = JSONDecoder()
    let lines = try logCorpusRecords().map { try decoder.decode(LogLine.self, from: Data($0.utf8)) }
    return JSONBlock.detect(in: buffered(lines))
}

/// Every line the rules flag at `.error` or above across the corpus's 3,428
/// lines, enumerated by hand.
///
/// Deliberately NOT a predicate — an oracle that re-derives "is this an
/// error?" from the same signals the scanner reads would pass for exactly the
/// reason the scanner is wrong. This is the flagged set as a person read it,
/// line by line, and every entry below was checked against the corpus by hand:
/// all 46 are genuine failures (a postgres query error, a lost connection, a
/// failed fetch, a dead vite dev server, a pino-serialised `DatabaseError`),
/// none is ordinary traffic.
///
/// `rule` is part of the expectation because the count alone would survive a
/// rule firing for the wrong reason — the three `render-api` records, for
/// instance, carry BOTH `"level":50` and an `err` object, so they would still
/// be flagged if `json.level` broke entirely.
private let expectedCorpusFlags: [(resource: String, rule: String, contains: String, count: Int)] = [
    // Upper-case tokens. pino's is ANSI-wrapped, at stripped column 15;
    // postgres' sit at 35 (four-digit pid) and 36 (five-digit).
    ("studio-api", "token.severity", "ERROR: Failed to fetch render", 6),
    ("catalog-postgres", "token.severity", "ERROR:  column", 2),
    ("session-postgres", "token.severity", "FATAL:  connection to client lost", 1),
    ("usage-postgres", "token.severity", "ERROR:  no partition of relation", 13),
    // Lower-case tokens in label position — none of these was flagged at all
    // until the token rule started reading them; all 21 were sitting at
    // `.warning` via `ansi.red`, or (the nginx one) at `.normal`. Their columns
    // are 42, 34, 30, 21 and 4 respectively, and 42 is the measurement the
    // 80-column window's headroom is stated against.
    ("catalog-frontend", "token.severity", "Pre-transform error:", 9),
    ("catalog-frontend", "token.severity", "Internal server error:", 7),
    ("portal-client", "token.severity", "http proxy error:", 3),
    ("nginx-edge", "token.severity", "[error] 23#23:", 1),
    ("studio-api", "token.severity", #"error: "fetch failed""#, 1),
    // Compact pino records: `"level":50` at column 1, with the same failure
    // serialised into `err` and a `"severity":"ERROR"` string 650 characters
    // in that the token rule must not reach.
    ("render-api", "json.level", #""level":50"#, 3),
]

/// The test that makes the rules real rather than theoretical: it runs them
/// over the whole corpus and requires the flagged set to be exactly the 46 rows
/// enumerated above, each flagged by the rule named for it.
///
/// A rule that starts flagging ordinary traffic moves the count and fails
/// here; a rule that keeps the count but fires for a different reason moves a
/// name and fails here too.
///
/// ## Synthesized, and what that changes
///
/// The corpus is now generated by `docs/testing/generate-log-corpus.swift`
/// rather than captured, so that a public repository does not carry one
/// company's service topology. Every count in this file was re-derived from the
/// generated fixture. Two things moved and neither is cosmetic:
///
/// * **3,428 lines become 2,854 rows**, where the capture's 3,461 became 3,440.
///   The capture's stride sampling had shredded most multi-line JSON, leaving
///   nearly every line its own row; the generator keeps a block's lines
///   contiguous, so 147 blocks now collapse (against 85), and the block branch
///   of the scanner is exercised far harder. The guard below moved with the
///   measurement rather than the measurement being padded to fit the guard.
/// * **The corpus can now tell precision rules apart that the capture could
///   not.** Dropping the token rule's label requirement moves the flagged set
///   from 46 to 79 on this corpus and moved it not at all on the capture.
///
/// ## What this does NOT validate
///
/// Recall for `json.statusCode`, `tilt.level` and `ansi.red`, and only thinly
/// for `json.err`. The corpus contains ZERO `statusCode` in 500–599 (its 22
/// status fields are 200 and 304) — reproduced deliberately from the capture,
/// which had none either — tilt's own `level` is `info` on all 3,428 lines,
/// every red line is claimed by `token.severity` first (see
/// `noCorpusRowIsFlaggedByRedAlone`), and the only three `err` objects are on
/// records `json.level` claims first. Those four rules are unit-tested against
/// synthetic input above and have no corpus evidence that they fire at all —
/// a green run here must not be read as coverage of them.
@Test func theRulesFlagTheSameFortySixCorpusLinesAndNothingElse() throws {
    let rows = try loadCorpusRows()
    #expect(rows.count > 2_500, "corpus shrank; the false-positive surface below shrank with it")

    let flagged = rows.filter { SeverityScanner.severity(of: $0) >= .error }
    #expect(flagged.count == 46)

    var remaining = flagged
    for expectation in expectedCorpusFlags {
        let matching = remaining.filter { row in
            let first = row.lines[0].line
            return first.resource == expectation.resource
                && ANSI.strip(first.message).contains(expectation.contains)
                && SeverityScanner.matchingRule(for: row) == expectation.rule
        }
        #expect(
            matching.count == expectation.count,
            "\(expectation.resource) / \(expectation.rule) / \(expectation.contains)"
        )
        remaining.removeAll { row in matching.contains { $0.id == row.id } }
    }

    for row in remaining {
        Issue.record("false positive: \(row.lines[0].line.resource): \(ANSI.strip(row.lines[0].line.message).prefix(120))")
    }
}

/// The other half of the corpus check: what the rules leave alone.
///
/// 2,808 of the corpus's 2,854 rows score below `.error`, and the shape most
/// likely to be tinted by mistake is named here rather than left to the count —
/// a stack frame. 212 lines begin with `    at ` or `\tat `, which is the
/// predicate below; 109 match an anchored `at fn (file:l:c)` and 162 contain an
/// `at fn(` anywhere, including inside a JSON `stack` string. Three dialects
/// are represented (node/esbuild, tab-indented Java, and Python's `File "…",
/// line N`), because a rule that reads one of them must read none of them. 24
/// frames tinted for one failure would light up the pane for a single error.
@Test func theRulesLeaveEveryStackFrameAlone() throws {
    let rows = try loadCorpusRows()

    let frames = rows.filter { row in
        let text = ANSI.strip(row.lines[0].line.message)
        return text.hasPrefix("    at ") || text.hasPrefix("\tat ")
    }
    #expect(frames.count >= 25, "the corpus lost its stack frames; this asserts nothing without them")
    for frame in frames {
        #expect(SeverityScanner.severity(of: frame) == .normal, "\(ANSI.strip(frame.lines[0].line.message).prefix(80))")
    }
}

/// `ansi.red` fires on NOTHING in this corpus, and that is the whole
/// assertion.
///
/// All 30 red lines carry a severity token as well — 25 at `.error` (6
/// upper-case `ERROR`, 19 lower-case vite `error:` labels) and 5 Flask
/// `WARNING:` boilerplate at `.warning` — so `token.severity` claims every one
/// of them before red is consulted. That is the precedence the design asks
/// for, and it means red's own recall has no corpus evidence at all: it is
/// unit-tested only.
///
/// Asserting zero is not a vacuous assertion, and this is measured rather than
/// asserted: forcing the token rule to upper case only moves this count from 0
/// to exactly 19, because those 19 vite rows fall back to red. The tripwire
/// points at the regression instead of silently absorbing it.
@Test func noCorpusRowIsFlaggedByRedAlone() throws {
    let rows = try loadCorpusRows()

    let redRows = rows.filter { row in
        row.lines.contains { ANSI.parse($0.line.message).contains { $0.colour == .red || $0.colour == .brightRed } }
    }
    #expect(redRows.count >= 25, "the corpus lost its ANSI colour; this asserts nothing without it")

    let flaggedByRed = redRows.filter { SeverityScanner.matchingRule(for: $0) == "ansi.red" }
    #expect(flaggedByRed.isEmpty)
    // And every red row that another rule DID claim is claimed by the token
    // rule, at `.warning` or above — never left below it.
    for row in redRows {
        #expect(SeverityScanner.matchingRule(for: row) == "token.severity", "\(ANSI.strip(row.lines[0].line.message).prefix(80))")
        #expect(SeverityScanner.severity(of: row) >= .warning)
    }
}
