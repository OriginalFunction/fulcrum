import Foundation
import Testing
@testable import FulcrumKit

@Test func detectsACompactSingleLineObject() {
    let rows = JSONBlock.detect(in: buffered([line(message: #"{"_aws":{"Timestamp":1786493715538}}"#)]))
    guard case let .block(block, _) = rows.first else { Issue.record("not a block"); return }
    #expect(block.label == nil)
    #expect(block.lineCount == 1)
}

@Test func detectsAPureMultiLineObject() {
    // opener is exactly "{"; closes when depth returns to zero.
    let rows = JSONBlock.detect(in: buffered([
        line(message: "{"),
        line(message: #"  "status": "success","#),
        line(message: #"  "data": { "jobName": "metrics-collection" }"#),
        line(message: "}"),
    ]))
    #expect(rows.count == 1)
    guard case let .block(block, lines) = rows.first else { Issue.record("not a block"); return }
    #expect(block.label == nil)
    #expect(block.lineCount == 4)
    #expect(lines.count == 4)
}

@Test func detectsALabelledBlockAndKeepsItsLabel() {
    let rows = JSONBlock.detect(in: buffered([
        line(message: "res: {"), line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#), line(message: "}"),
    ]))
    guard case let .block(block, lines) = rows.first else { Issue.record("not a block"); return }
    #expect(block.label == "res:")
    #expect(lines.count == 4)
    #expect(block.raw.hasPrefix("{"))   // the label is NOT part of the parsed text
}

@Test func aHeaderLineBeforeABlockStaysItsOwnRow() {
    // "[09:17:29] Triggering metrics-collection..." then "{" ... "}"
    // -> exactly two rows: one .line, one .block. The header is not swallowed.
    let header = line(message: "[09:17:29] Triggering metrics-collection...")
    let rows = JSONBlock.detect(in: buffered([
        header,
        line(message: "{"),
        line(message: #"  "status": "success","#),
        line(message: #"  "data": { "jobName": "metrics-collection" }"#),
        line(message: "}"),
    ]))
    #expect(rows.count == 2)

    guard case let .line(first) = rows[0] else { Issue.record("expected the header to stay a plain line"); return }
    #expect(first.line == header)

    guard case let .block(block, lines) = rows[1] else { Issue.record("expected a block"); return }
    #expect(block.lineCount == 4)
    #expect(lines.count == 4)
}

@Test func bracesInsideStringsDoNotOpenABlock() {
    // THE test that separates depth-counting from naive character counting.
    // A standalone line with an unbalanced `{` in a string must not open a
    // block that then eats the rest of the log.
    let standaloneRows = JSONBlock.detect(in: buffered([
        line(message: #"msg: "unbalanced { brace in text""#),
        line(message: "next line entirely unrelated"),
    ]))
    #expect(standaloneRows.count == 2)
    for row in standaloneRows {
        guard case .line = row else {
            Issue.record("a brace inside a string must not open a block")
            return
        }
    }

    // The sharper case: a `{` inside a string value on a CONTINUATION line,
    // inside an already-open block. A naive character count would treat it
    // as a second, real nesting level and never see depth return to zero at
    // the real closing `}` below — breaking the whole block, not just this
    // line. Depth-with-string-tracking must still close the block at 4 lines.
    let rows = JSONBlock.detect(in: buffered([
        line(message: "{"),
        line(message: #"  "msg": "unbalanced { brace","#),
        line(message: #"  "ok": true"#),
        line(message: "}"),
    ]))
    #expect(rows.count == 1)
    guard case let .block(block, lines) = rows.first else { Issue.record("not a block"); return }
    #expect(block.lineCount == 4)
    #expect(lines.count == 4)
}

@Test func anUnclosedBlockDoesNotSwallowEverythingAfterIt() {
    // A process killed mid-write leaves "{" with no closer. Cap how far a block
    // may run (blocks measured max 8 lines; allow generous headroom) and fall
    // back to plain lines rather than consuming the buffer to its end.
    // A closer that arrives, but only well beyond the cap: if the cap isn't
    // enforced, the scan would eventually reach it and swallow the whole
    // 212-line span into one block. Placing a real "}" here (rather than
    // omitting it) is deliberate — without it, this test would pass for the
    // wrong reason (simply running out of lines), the same way it silently
    // would if the cap were never implemented at all.
    var lines = [line(message: "{")]
    for i in 0..<210 {
        lines.append(line(message: "plain line \(i)"))
    }
    lines.append(line(message: "}"))

    let rows = JSONBlock.detect(in: buffered(lines))

    #expect(rows.count == lines.count)
    for row in rows {
        guard case .line = row else {
            Issue.record("an opener whose closer arrives beyond the cap must not swallow the rest of the buffer")
            return
        }
    }
}

@Test func ordinaryIndentedContinuationsAreNotBlocks() {
    // '    tenant: "contoso"' is pino continuation text, not JSON. Stays a .line.
    let rows = JSONBlock.detect(in: buffered([line(message: #"    tenant: "contoso""#)]))
    guard case .line = rows.first else { Issue.record("expected a plain line"); return }
}

// MARK: - Resource / span boundary

@Test func aBlockDoesNotAbsorbALineFromAnotherResource() {
    // VERBATIM from port 10350: tilt's stream is globally interleaved, so a
    // `platform-backend` block opened by `request: {` had an `nginx-proxy`
    // access-log line land in the middle of it. Absorbed, that line stopped
    // existing as a row of its own — the user simply loses it behind a
    // collapsed block belonging to a different service.
    //
    // The interleaved line here is deliberately NOT that nginx access log,
    // and this is the whole point of the test. An access log does not parse
    // as JSON, so the parseability gate would reject that block on its own
    // and this test would pass with no resource boundary at all — verified
    // by mutation, it did exactly that. The measured sample also contains
    // `login-bff` and `platform-backend` interleaving while BOTH emit pino
    // JSON; a foreign line that is itself a valid JSON field leaves the
    // block perfectly parseable, so nothing but the boundary can catch it.
    let backend = { (message: String) in
        line(message: message, resource: "platform-backend", spanID: "dc:platform-backend")
    }
    let foreign = line(
        message: #"      "url": "/api/session","#,
        resource: "login-bff", spanID: "dc:login-bff"
    )
    let lines = [
        backend("    request: {"),
        backend(#"      "method": "GET","#),
        foreign,
        backend(#"      "statusCode": 304"#),
        backend("    }"),
    ]

    // Absorbed, these five lines are one block whose text parses cleanly as
    // {"method": "GET", "url": "/api/session", "statusCode": 304} — a JSON
    // object no service ever emitted.
    #expect(JSONValue.parse(#"{"method": "GET", "url": "/api/session", "statusCode": 304}"#) != nil)

    #expect(JSONBlock.detect(in: buffered(lines)) == buffered(lines).map(LogRow.line))
}

@Test func aBlockDoesNotAbsorbAnotherSpanOfTheSameResource() {
    // `resource` alone is not a fine enough boundary. 37 resources in the
    // measured 21,224-line capture carried more than one spanID at once — a
    // build stream and a runtime stream, e.g. `build:141` alongside
    // `cmd:management-shared-build:update` — and 88 adjacent line pairs
    // switched span WITHOUT switching resource.
    //
    // Same construction as the resource test above and for the same reason:
    // the interleaved line is valid JSON field text, so the block would parse
    // if it were absorbed. `spanID` is the only thing that distinguishes it.
    let runtime = { (message: String) in
        line(message: message, resource: "management-shared-build", spanID: "cmd:management-shared-build:update")
    }
    let otherSpan = line(
        message: #"  "step": "npm ci","#,
        resource: "management-shared-build", spanID: "build:141"
    )
    let lines = [
        runtime("res: {"),
        runtime(#"  "statusCode": 200,"#),
        otherSpan,
        runtime(#"  "ok": true"#),
        runtime("}"),
    ]

    #expect(JSONBlock.detect(in: buffered(lines)) == buffered(lines).map(LogRow.line))
}

@Test func aBlockDoesNotAbsorbAnotherResourceSharingItsSpanID() {
    // Why `resource` is checked as well as `spanID`, when `spanID` alone
    // already separates every block in the measured capture (175 spans there,
    // not one of them used by two resources).
    //
    // 26 of those 21,224 lines carry spanID `""`. Today they are all
    // tilt-level lines whose `resource` is `""` too, so the two checks still
    // agree — but "the span is empty" is not a promise tilt makes about the
    // future, and the moment two resources share a span (empty or not),
    // `spanID` alone stops separating anything at all. One string comparison
    // closes that.
    let a = line(message: "res: {", resource: "auth-service", spanID: "")
    let foreign = line(message: #"  "tenant": "contoso","#, resource: "login-bff", spanID: "")
    let lines = [
        a,
        line(message: #"  "statusCode": 200,"#, resource: "auth-service", spanID: ""),
        foreign,
        line(message: #"  "ok": true"#, resource: "auth-service", spanID: ""),
        line(message: "}", resource: "auth-service", spanID: ""),
    ]

    #expect(JSONBlock.detect(in: buffered(lines)) == buffered(lines).map(LogRow.line))
}

@Test func aBlockStillFormsWhenEveryLineSharesTheOpenersResourceAndSpan() {
    // The counterweight to the two tests above: a boundary that rejects
    // everything would pass both of them and detect nothing at all.
    let backend = { (message: String) in
        line(message: message, resource: "platform-backend", spanID: "dc:platform-backend")
    }
    let lines = [
        backend("    request: {"),
        backend(#"      "method": "GET","#),
        backend(#"      "statusCode": 304"#),
        backend("    }"),
    ]

    let rows = JSONBlock.detect(in: buffered(lines))

    #expect(rows.count == 1)
    guard case let .block(block, grouped) = rows.first else { Issue.record("not a block"); return }
    #expect(block.label == "request:")
    #expect(grouped == buffered(lines))
}

// MARK: - Parseability is the gate

@Test func aBraceBalancedStackTraceIsNotABlock() {
    // VERBATIM from port 10350, four occurrences in 21,224 lines. Node
    // appends `{` to the last `at ...` frame when the error carries extra
    // properties, and the braces balance perfectly nine lines later — so
    // brace depth alone calls this a block and collapses it to one row. A
    // collapsed stack trace is exactly what a developer most needs to read.
    let api = { (message: String) in
        line(message: message, resource: "ai-api", spanID: "dc:ai-api")
    }
    let lines = [
        api("    at async <anonymous> (/app/api/src/routes/test-runs.routes.ts:95:20) {"),
        api("  [cause]: Error: Connection terminated unexpectedly"),
        api("      at Connection.<anonymous> (/app/api/node_modules/pg/lib/client.js:136:73)"),
        api("      at Object.onceWrapper (node:events:633:28)"),
        api("      at Connection.emit (node:events:519:28)"),
        api("      at Socket.<anonymous> (/app/api/node_modules/pg/lib/connection.js:62:12)"),
        api("      at Socket.emit (node:events:519:28)"),
        api("      at TCP.<anonymous> (node:net:347:12)"),
        api("}"),
    ]

    let rows = JSONBlock.detect(in: buffered(lines))

    #expect(rows.count == lines.count)
    #expect(rows == buffered(lines).map(LogRow.line))
}

@Test func utilInspectOutputIsNotABlock() {
    // `console.log("Loaded config:", obj)` prints util.inspect's format:
    // unquoted keys, single quotes, `undefined`. Brace-balanced, not JSON.
    let lines = [
        line(message: "Loaded config: {"),
        line(message: "  port: 3000,"),
        line(message: "  host: 'localhost',"),
        line(message: "  apiKey: undefined,"),
        line(message: "  nested: { retries: 3 }"),
        line(message: "}"),
    ]

    let rows = JSONBlock.detect(in: buffered(lines))

    #expect(rows == buffered(lines).map(LogRow.line))
}

@Test func everyDetectedBlockParses() {
    // The invariant the two tests above are instances of: a block IS its
    // parsed value, so nothing that fails to parse may be one. Asserted over
    // a mixture so the check cannot pass by detecting no blocks at all.
    let lines = [
        line(message: #"{"_aws":{"Timestamp":1786493715538}}"#),
        line(message: "Loaded config: {"),
        line(message: "  port: 3000"),
        line(message: "}"),
        line(message: "res: {"),
        line(message: #"  "statusCode": 200"#),
        line(message: "}"),
    ]

    let rows = JSONBlock.detect(in: buffered(lines))

    var blocks = 0
    for row in rows {
        guard case let .block(block, _) = row else { continue }
        blocks += 1
        #expect(JSONValue.parse(block.raw) != nil, "detected an unparseable block: \(block.raw)")
        #expect(block.value == JSONValue.parse(block.raw))
    }
    #expect(blocks == 2)
}

@Test func aBlockClosingOnATrailingCommaStillParses() {
    // VERBATIM shape from port 10350 (the fda-form-2253-form-fields field
    // list, repeated once per field): a pretty-printed object nested inside a
    // larger structure closes on `},` — the comma belongs to the ENCLOSING
    // array, which the block never included, so `JSONValue.parse` saw
    // trailing garbage. 40 of the 48 measured parse failures were this one
    // shape; without the fix these lines vanish into unreadable rows.
    let form = { (message: String) in
        line(message: message, resource: "fda-form-2253-form-fields", spanID: "dc:fda-form-2253-form-fields")
    }
    let lines = [
        form("      {"),
        form(#"        "id": "db_nda_bla_nmbr","#),
        form(#"        "value": "","#),
        form(#"        "type": "text""#),
        form("      },"),
    ]

    let rows = JSONBlock.detect(in: buffered(lines))

    #expect(rows.count == 1)
    guard case let .block(block, grouped) = rows.first else { Issue.record("not a block"); return }
    #expect(grouped.count == 5)
    #expect(JSONValue.parse(block.raw) != nil)
    #expect(block.value == .object([
        ("id", .string("db_nda_bla_nmbr")),
        ("value", .string("")),
        ("type", .string("text")),
    ]))
}

@Test func onlyOneTrailingCommaIsForgivenAndNothingElseIs() {
    // The comma trim is one measured case, not a JSON-repair pass. Two
    // trailing commas, or any other malformation, still means "not a block".
    let doubled = JSONBlock.detect(in: buffered([
        line(message: "{"), line(message: #"  "a": 1"#), line(message: "},,"),
    ]))
    #expect(doubled.allSatisfy { if case .line = $0 { true } else { false } })

    let malformed = JSONBlock.detect(in: buffered([
        line(message: "{"), line(message: #"  "a": ,"#), line(message: "}"),
    ]))
    #expect(malformed.allSatisfy { if case .line = $0 { true } else { false } })
}

// MARK: - Bounded rescanning

@Test func everyLineIsCharacterScannedExactlyOnceHoweverManyOpenersFail() {
    // Detection used to rescan up to `maxBlockLines` (200) lines, characters
    // and all, for EVERY opener that failed to close — 5,000 consecutive
    // `res: {` openers cost 5,000 x 200 line scans and measured 0.69s, on the
    // main actor. Counted rather than timed: four wall-clock bounds on this
    // project have already been replaced by deterministic assertions.
    //
    // 400 openers is deliberately above the 200-line cap, so the unbounded
    // version does its full worst-case rescan (400 x 200 = 80,000) rather
    // than merely running out of input.
    let lines = (0..<400).map { _ in line(message: "res: {") }
    let counter = JSONBlock.BraceScanCounter()

    let rows = JSONBlock.detect(in: buffered(lines), countingBraceScansInto: counter)

    #expect(rows.count == lines.count)
    #expect(counter.count == lines.count)
}
