import Foundation
import Testing
@testable import FulcrumKit

/// Every `LogLine` message the rows cover, in order.
///
/// Assertions here are made on messages rather than on `LogRow`s directly
/// wherever a failure is plausible: handing a `LogRow` holding a `JSONValue`
/// to `#expect` makes swift-testing reflect over the tree to render the
/// failure, which killed the whole test process with signal 10 on the last
/// task. Where whole-row identity genuinely is the claim, the comparison is
/// reduced to a `Bool` first for the same reason.
private func messages(_ rows: [LogRow]) -> [String] {
    rows.flatMap { $0.lines.map(\.line.message) }
}

/// The verbatim `login-bff` request the whole task exists for: a pino header
/// line carrying the correlation ID, method and URL, followed by the
/// indented continuation lines that elaborate it. Captured shape confirmed
/// against port 10350 — the header is a SEPARATE log record from the `req:`
/// and `res:` blocks, which is exactly why grouping the blocks alone left
/// the user's reported pain unfixed.
private func loginBFFRequest() -> [LogLine] {
    [
        "[01:13:52] INFO (northwind-account-service): 8fe3c125-7b0c-4534-a56e-eee247a33951 GET /api/auth/check",
        "    req: {",
        #"      "method": "GET","#,
        #"      "url": "/api/auth/check","#,
        #"      "headers": {"#,
        #"        "user-agent": "curl/8.7.1""#,
        "      }",
        "    }",
        #"    correlationId: "8fe3c125-7b0c-4534-a56e-eee247a33951""#,
        "    res: {",
        #"      "statusCode": 304,"#,
        #"      "headers": {}"#,
        "    }",
        "    responseTime: 2",
    ].map { line(message: $0, resource: "login-bff", spanID: "dc:login-bff") }
}

/// Verbatim from `platform-backend` on port 10350 — a self-contained
/// single-line CloudWatch EMF blob, which the block detector turns into a
/// compact `.block` row.
private let awsBlob = #"{"_aws":{"Timestamp":1786497403764,"CloudWatchMetrics":[{"Namespace":"Northwind/Database","Dimensions":[["Service","Environment"]],"Metrics":[{"Name":"DbQueryDuration","Unit":"Milliseconds"}]}]},"Service":"northwind-catalog-service","DbQueryDuration":7,"TenantId":"contoso"}"#

@Test func aMatchKeepsTheHeaderThatExplainsIt() {
    // THE test for this plan. Query "statusCode" appears only inside the
    // `res:` block. Grouping the block alone — everything before this task —
    // returned that block and nothing else, so the header carrying the
    // correlation ID, method and URL was still lost: the user's actual
    // reported pain. The whole record must survive.
    let lines = loginBFFRequest()
    let rows = JSONBlock.detect(in: buffered(lines))

    let result = LogFilter(query: "statusCode").apply(to: rows)

    #expect(messages(result) == lines.map(\.message))
    #expect(messages(result).first?.contains("GET /api/auth/check") == true)
}

@Test func anUnfilteredPaneIsNotGrouped() {
    // The scope decision, pinned: record grouping affects SEARCH ONLY. With
    // no filter the pane must render exactly what it renders today — same
    // rows, same count, same order, and no records formed. That containment
    // is the entire reason a heuristic was acceptable here: a misjudged
    // record can only ever affect what survives a search, and clearing the
    // search box always restores the verbatim stream.
    //
    // THE ASSERTION THAT DOES THE WORK IS THE GROUPING COUNT, not the rows.
    // Comparing output to input cannot see this property at all: with no
    // criterion set the predicate matches every line, so every record is
    // kept whole and `LogRecord.group(rows).flatMap { $0 }` IS `rows`.
    // Deleting the guard in `LogFilter.applyCounting(to rows:...)` left this
    // test, `aMatchKeepsTheHeaderThatExplainsIt` and
    // `groupingNeverLosesOrReordersRows` all passing — three green tests for
    // a property with no guard behind it. Counting the pass is what closes
    // that: grouping ran zero times, or this fails.
    //
    // Its counterweight is `groupingNeverLosesOrReordersRows` below: this
    // test asserts grouping did NOT run, so it can say nothing about what
    // grouping does when it does run.
    let lines = loginBFFRequest()
        + [line(message: awsBlob, resource: "platform-backend", spanID: "dc:platform-backend")]
        + [line(message: "plain tilt-level message", resource: "", spanID: "")]
    let rows = JSONBlock.detect(in: buffered(lines))

    let counter = LogFilter.RecordGroupingCounter()
    let result = LogFilter().apply(to: rows, countingRecordGroupingsInto: counter)

    #expect(counter.count == 0)
    #expect(result.count == rows.count)
    #expect(messages(result) == lines.map(\.message))
    // Reduced to `Bool` before `#expect` sees it — see `messages(_:)`.
    let identical = result == rows
    #expect(identical)
}

@Test func onlyATextQueryFormsRecords() {
    // The two intents, pinned side by side. A text query means "find this
    // thing and show me its context", so it groups: the `res:` block's
    // header comes back with it. A literal filter (source, here) means "show
    // me only lines matching this field, exactly" — grouping there would
    // pull a record's other rows back in even though they don't match,
    // which does not read as context, it reads as a filter that does not
    // work.
    //
    // Both halves are asserted by COUNTING the grouping pass as well as by
    // its result, because the result alone is ambiguous in the source case:
    // a record whose rows all share one source survives grouping unchanged.
    let lines = [
        line(message: "[01:13:52] INFO (northwind-account-service): GET /api/auth/check",
             resource: "login-bff", source: .runtime, spanID: "dc:login-bff"),
        line(message: "    res: { \"statusCode\": 304 }",
             resource: "login-bff", source: .runtime, spanID: "dc:login-bff"),
        line(message: "Compiling login-bff...",
             resource: "login-bff", source: .build, spanID: "dc:login-bff-build"),
        line(message: "    correlationId: \"8fe3c125\"",
             resource: "login-bff", source: .runtime, spanID: "dc:login-bff"),
    ]
    let rows = JSONBlock.detect(in: buffered(lines))

    // A text query GROUPS: "statusCode" appears only on the indented
    // continuation, and the header above it comes back too.
    let queryCounter = LogFilter.RecordGroupingCounter()
    let queried = LogFilter(query: "statusCode")
        .apply(to: rows, countingRecordGroupingsInto: queryCounter)
    #expect(queryCounter.count == 1)
    #expect(messages(queried) == [lines[0].message, lines[1].message])

    // A source filter DOES NOT: the `.build` line's own record carries
    // `.runtime` continuations, and none of them may come back with it.
    let sourceCounter = LogFilter.RecordGroupingCounter()
    let sourced = LogFilter(source: .build)
        .apply(to: rows, countingRecordGroupingsInto: sourceCounter)
    #expect(sourceCounter.count == 0)
    #expect(messages(sourced) == [lines[2].message])
    #expect(sourced.allSatisfy { $0.lines.allSatisfy { $0.line.source == .build } })
}

@Test func aWhitespaceOnlyQueryIsNoQueryAtAll() {
    // A search field holding only spaces LOOKS empty. Before it was
    // trimmed the spaces were matched literally: `"   "` kept 9,794 of
    // 21,718 lines captured live, and grouped what survived, with nothing on
    // screen to explain either. It has to
    // behave exactly like the empty field it appears to be: no filtering,
    // no grouping — and, since it is not a pattern, not a pattern that can
    // be invalid either.
    let lines = loginBFFRequest()
        + [line(message: "plain tilt-level message", resource: "", spanID: "")]
    let rows = JSONBlock.detect(in: buffered(lines))

    let counter = LogFilter.RecordGroupingCounter()
    let filter = LogFilter(query: "   ")
    let result = filter.apply(to: rows, countingRecordGroupingsInto: counter)

    #expect(counter.count == 0)
    let identical = result == rows
    #expect(identical)
    // The line-based overload agrees — one query, one meaning.
    #expect(filter.apply(to: lines) == lines)
    #expect(!LogFilter(query: " \t ", isRegex: true).isRegexInvalid)
}

@Test func aResourceWithNoHeadersIsUntouched() {
    // nginx-proxy emits no header lines at all, so every one of its lines is
    // its own record and grouping does nothing to it.
    //
    // The trap: a real nginx access line CONTAINS a bracketed timestamp
    // mid-line. An unanchored header pattern makes all 266 measured nginx
    // lines record headers. The indented third line is deliberate and
    // load-bearing — without a continuation to absorb, an unanchored pattern
    // still yields one-row records and this test would pass for the wrong
    // reason. What it discriminates is what the pattern does to the line
    // ABOVE it, not the continuation's own text.
    let lines = [
        line(
            message: #"169.254.169.254 - - [12/Aug/2026:01:13:52 +0000] "GET /x HTTP/1.1" 304 0"#,
            resource: "nginx-proxy", spanID: "dc:nginx-proxy"
        ),
        line(
            message: #"169.254.169.254 - - [12/Aug/2026:01:13:53 +0000] "GET /y HTTP/1.1" 200 12"#,
            resource: "nginx-proxy", spanID: "dc:nginx-proxy"
        ),
        line(
            message: "  upstream timed out while reading response header from upstream",
            resource: "nginx-proxy", spanID: "dc:nginx-proxy"
        ),
    ]
    let rows = JSONBlock.detect(in: buffered(lines))

    let records = LogRecord.group(rows)
    #expect(records.count == 3)
    #expect(records.allSatisfy { $0.count == 1 })

    // Observably: matching the indented line must not drag the access line
    // above it into the results.
    let result = LogFilter(query: "upstream timed out").apply(to: rows)
    #expect(messages(result) == ["  upstream timed out while reading response header from upstream"])
}

@Test func aBracketedPrefixThatIsNotATimestampIsNotAHeader() {
    // Measured on port 10350: `management-client` prefixes 377 lines of
    // proxied HTML with `[readiness probe: success]`. That is a leading
    // bracketed field containing a colon — a header pattern asking only for
    // "starts with `[`, has a `]`, has a `:`" swallows every one of them and
    // starts a record at each. A timestamp starts with a digit.
    let lines = [
        line(
            message: "[readiness probe: success] <!doctype html>",
            resource: "management-client", spanID: "localserve:67"
        ),
        line(
            message: "  VITE v6.3.5  ready in 227 ms",
            resource: "management-client", spanID: "localserve:67"
        ),
    ]
    let rows = JSONBlock.detect(in: buffered(lines))

    #expect(LogRecord.group(rows).count == 2)

    let result = LogFilter(query: "VITE").apply(to: rows)
    #expect(messages(result) == ["  VITE v6.3.5  ready in 227 ms"])
}

@Test func aRecordStopsAtTheNextHeader() {
    // A record's continuations are the CONTIGUOUS indented lines that follow
    // it. The next header starts a new record and must not be dragged in by
    // a match on the previous one's continuation.
    let lines = [
        line(message: "[2026-08-12 01:15:41.959] INFO (northwind-console-service): Job execution started",
             resource: "tenant-service", spanID: "dc:tenant-service"),
        line(message: #"    jobName: "metrics-collection""#,
             resource: "tenant-service", spanID: "dc:tenant-service"),
        line(message: "[2026-08-12 01:16:18.110] INFO (northwind-console-service): Job execution started",
             resource: "tenant-service", spanID: "dc:tenant-service"),
        line(message: #"    jobName: "activity-snapshot""#,
             resource: "tenant-service", spanID: "dc:tenant-service"),
    ]
    let rows = JSONBlock.detect(in: buffered(lines))

    let records = LogRecord.group(rows)
    #expect(records.map(\.count) == [2, 2])

    let result = LogFilter(query: "activity-snapshot").apply(to: rows)
    #expect(messages(result) == [lines[2].message, lines[3].message])
}

@Test func aRecordStopsAtAResourceOrSpanBoundary() {
    // tilt's stream is globally interleaved, so the line physically after a
    // header routinely comes from somewhere else entirely. Same boundary the
    // block detector already enforces, for the same reason — and each half
    // of it is discriminated on its own here: the first arrangement differs
    // ONLY in resource, the second ONLY in spanID.
    let differsOnlyByResource = [
        line(message: "[2026-08-12 01:15:41.992] INFO (northwind-catalog-service): GET /metrics/users complete",
             resource: "platform-backend", spanID: "shared-span"),
        line(message: "    responseTime: 3", resource: "tenant-service", spanID: "shared-span"),
    ]
    let byResource = JSONBlock.detect(in: buffered(differsOnlyByResource))
    #expect(LogRecord.group(byResource).map(\.count) == [1, 1])
    #expect(
        messages(LogFilter(query: "responseTime").apply(to: byResource))
            == ["    responseTime: 3"]
    )

    let differsOnlyBySpan = [
        line(message: "[2026-08-12 01:15:41.992] INFO (northwind-catalog-service): GET /metrics/users complete",
             resource: "platform-backend", spanID: "dc:platform-backend"),
        line(message: "    responseTime: 3", resource: "platform-backend", spanID: "build:141"),
    ]
    let bySpan = JSONBlock.detect(in: buffered(differsOnlyBySpan))
    #expect(LogRecord.group(bySpan).map(\.count) == [1, 1])
    #expect(
        messages(LogFilter(query: "responseTime").apply(to: bySpan))
            == ["    responseTime: 3"]
    )
}

@Test func linesBeforeAnyHeaderStandAlone() {
    // The measured `_aws` EMF blobs arrive BEFORE any header, from the same
    // resource and span as the header that follows, and are self-contained
    // JSON. A record only ever extends FORWARD from its header; nothing gets
    // absorbed backwards into one.
    let lines = [
        line(message: awsBlob, resource: "platform-backend", spanID: "dc:platform-backend"),
        line(message: "[2026-08-12 01:15:41.992] INFO (northwind-catalog-service): GET /metrics/users complete",
             resource: "platform-backend", spanID: "dc:platform-backend"),
        line(message: "    responseTime: 3", resource: "platform-backend", spanID: "dc:platform-backend"),
    ]
    let rows = JSONBlock.detect(in: buffered(lines))

    let records = LogRecord.group(rows)
    #expect(records.map(\.count) == [1, 2])

    let result = LogFilter(query: "responseTime").apply(to: rows)
    #expect(messages(result) == [lines[1].message, lines[2].message])
}

@Test func aRecordTakesOnlyIndentedContinuations() {
    // "Continuation" means indented, NOT merely "isn't a header". Measured
    // on port 10350: `platform-backend` emits pino records and self-contained
    // `_aws` EMF blobs on the same resource and span, and the blobs sit at
    // column zero — they belong to no record, whichever side of one they
    // land on. A rule of "anything from this stream until the next header"
    // absorbs them, and then a search for the blob's own contents drags in
    // an unrelated request that merely preceded it.
    let lines = [
        line(message: "[2026-08-12 01:15:41.992] INFO (northwind-catalog-service): GET /metrics/users complete",
             resource: "platform-backend", spanID: "dc:platform-backend"),
        line(message: "    responseTime: 3", resource: "platform-backend", spanID: "dc:platform-backend"),
        line(message: awsBlob, resource: "platform-backend", spanID: "dc:platform-backend"),
        line(message: "    orphaned continuation", resource: "platform-backend", spanID: "dc:platform-backend"),
    ]
    let rows = JSONBlock.detect(in: buffered(lines))

    // The blob stands alone, and the indented line after it does NOT rejoin
    // the record above the blob — continuations have to be contiguous.
    #expect(LogRecord.group(rows).map(\.count) == [2, 1, 1])

    let result = LogFilter(query: "GET /metrics/users").apply(to: rows)
    #expect(messages(result) == [lines[0].message, lines[1].message])
}

@Test func groupingNeverLosesOrReordersRows() {
    // Counterweight to `anUnfilteredPaneIsNotGrouped`, which asserts the
    // grouping pass never RAN and so can say nothing about what it does when
    // it does. Grouping is a partition: every row lands in exactly one
    // record, and concatenating the records gives the input back — same
    // rows, same order, none dropped, none duplicated. A pass that lost the
    // blank line, merged two records or emitted them out of order fails
    // here even though every "the record survived" test above still passes.
    let lines = loginBFFRequest().map {
        LogLine(time: $0.time, resource: "svc", level: $0.level, source: $0.source,
                message: $0.message, spanID: $0.spanID)
    } + [
        line(message: awsBlob, resource: "svc", spanID: "dc:platform-backend"),
        line(message: "", resource: "svc", spanID: "dc:platform-backend"),
        line(message: "    orphan continuation with no header", resource: "svc", spanID: "dc:platform-backend"),
    ]
    let rows = JSONBlock.detect(in: buffered(lines))

    let flattened = LogRecord.group(rows).flatMap { $0 }
    #expect(flattened.count == rows.count)
    // Reduced to `Bool` before `#expect` sees it — see `messages(_:)`.
    let partitioned = flattened == rows
    #expect(partitioned)

    // And through the filter, where grouping is actually reached: `.` as a
    // regex matches any line with a character in it, so every record but the
    // blank line's comes back, whole and in order. A text query, not the
    // resource filter this used to use — since the level/source/resource
    // split, only a text query reaches grouping at all.
    let result = LogFilter(query: ".", isRegex: true).apply(to: rows)
    let expected = rows.filter { row in row.lines.contains { !$0.line.message.isEmpty } }
    let survivedWhole = result == expected
    #expect(survivedWhole)
    #expect(result.count == rows.count - 1)
}
