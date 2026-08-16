import Foundation
import Testing
@testable import FulcrumKit

@Test func resourceFilterMatchesTheFieldNotTheCLI() {
    // Positional CLI filtering is broken in live tilt v0.36.3 — verified:
    // `tilt logs ... server` returned lines for "(Tiltfile)" and "quick" too.
    // This client-side filter, matching the `resource` field exactly, is the
    // only thing that makes per-resource log viewing correct.
    let lines = [
        line(message: "a", resource: "server"),
        line(message: "b", resource: "(Tiltfile)"),
        line(message: "c", resource: "quick"),
        line(message: "d", resource: "server"),
    ]
    let filter = LogFilter(resource: "server")
    #expect(filter.apply(to: lines).map(\.message) == ["a", "d"])
}

@Test func resourceFilterExcludesTiltLevelMessages() {
    // Tilt-level messages ("Tilt started on http://localhost:10350/") carry
    // resource: "". Filtering for a specific resource must not surface them
    // — they belong to no resource, not to whichever one is selected.
    let lines = [
        line(message: "started", resource: ""),
        line(message: "a", resource: "server"),
    ]
    let filter = LogFilter(resource: "server")
    #expect(filter.apply(to: lines).map(\.message) == ["a"])
}

@Test func noResourceFilterShowsTiltLevelMessagesToo() {
    // When no resource is selected (nil), tilt-level messages are not hidden
    // — they show alongside every resource's lines.
    let lines = [
        line(message: "started", resource: ""),
        line(message: "a", resource: "server"),
    ]
    let filter = LogFilter()
    #expect(filter.apply(to: lines).map(\.message) == ["started", "a"])
}

@Test func plainQueryIsCaseInsensitiveSubstring() {
    let lines = [
        line(message: "Connection refused"),
        line(message: "listening on :8080"),
        line(message: "CONNECTION reset"),
    ]
    let filter = LogFilter(query: "connection")
    #expect(filter.apply(to: lines).map(\.message) == ["Connection refused", "CONNECTION reset"])
}

@Test func regexQueryMatches() {
    let lines = [
        line(message: "GET /healthz 200"),
        line(message: "POST /widgets 500"),
        line(message: "GET /widgets 404"),
    ]
    let filter = LogFilter(query: #"^GET .* (200|404)$"#, isRegex: true)
    #expect(filter.apply(to: lines).map(\.message) == ["GET /healthz 200", "GET /widgets 404"])
}

@Test func anInvalidRegexYieldsNoMatchesAndAFlagRatherThanCrashing() {
    // The user types "(" on the way to "(foo|bar)". On that keystroke the
    // pattern is invalid — this must never crash, never throw to the caller,
    // and never silently fall back to substring matching (which would show
    // confusing results mid-type).
    let lines = [line(message: "has an ( in it"), line(message: "plain")]
    let filter = LogFilter(query: "(", isRegex: true)
    #expect(filter.isRegexInvalid)
    #expect(filter.apply(to: lines).isEmpty)
}

@Test func sourceFilterSeparatesBuildFromRuntime() {
    let lines = [
        line(message: "compiling", source: .build),
        line(message: "listening", source: .runtime),
    ]
    let filter = LogFilter(source: .build)
    #expect(filter.apply(to: lines).map(\.message) == ["compiling"])
}

@Test func filtersCompose() {
    // Every excluded line is excluded by exactly ONE of the three clauses, so
    // each clause is load-bearing on its own. The fixture this replaces put
    // the word "server" in both the message and the resource of everything it
    // kept, which made query and resource redundant: deleting the resource
    // check from `matchPredicate` left this test green.
    let lines = [
        line(message: "server info", resource: "server", source: .runtime),
        line(message: "server other", resource: "server", source: .runtime),
        // Wrong source only — right resource, and the query matches.
        line(message: "server build info", resource: "server", source: .build),
        // Wrong resource only — right source, and the query matches.
        line(message: "server info from elsewhere", resource: "other", source: .runtime),
        // Query miss only — right resource, right source.
        line(message: "listening on :8080", resource: "server", source: .runtime),
    ]
    let filter = LogFilter(query: "server", source: .runtime, resource: "server")
    #expect(filter.apply(to: lines).map(\.message) == ["server info", "server other"])
}

// MARK: - Row-based filtering (JSON blocks matched and kept as units)

@Test func aQueryMatchingOneLineOfABlockKeepsTheWholeBlock() {
    // THE test for this plan, in the user's own words: searching for
    // `statusCode` used to match only `"statusCode": 200,` and lose the
    // `res:` header line above it — the only place the correlation ID,
    // method and URL live. Query "statusCode" against a realistic
    // `res: { … }` block must return the ENTIRE block, header included, not
    // just the single matching line.
    let blockLines = [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#),
        line(message: "}"),
    ]
    let rows = JSONBlock.detect(in: buffered(blockLines))
    let filter = LogFilter(query: "statusCode")

    let result = filter.apply(to: rows)

    #expect(result.count == 1)
    guard case let .block(block, matchedLines) = result.first else {
        Issue.record("the whole block should have survived, not just the matching line")
        return
    }
    #expect(block.label == "res:")
    // Every line the block spans, in order — not just the one containing
    // "statusCode". Losing the header line here is exactly the bug this
    // plan exists to fix.
    #expect(matchedLines.map(\.line) == blockLines)
}

@Test func aNonMatchingBlockIsDroppedEntirely() {
    let blockLines = [
        line(message: "res: {"),
        line(message: #"  "statusCode": 200,"#),
        line(message: #"  "headers": {}"#),
        line(message: "}"),
    ]
    let rows = JSONBlock.detect(in: buffered(blockLines))
    let filter = LogFilter(query: "nothing in this block says that")

    #expect(filter.apply(to: rows).isEmpty)
}

@Test func aPlainLineRowIsFilteredIdenticallyToTheLineOverload() {
    // `.line` rows must not behave differently just because they arrived
    // through the row-based overload — same predicate, same answer.
    let rows: [LogRow] = [
        .line(buffered(line(message: "Connection refused"))),
        .line(buffered(line(message: "listening on :8080"))),
    ]
    let filter = LogFilter(query: "connection")

    let result = filter.apply(to: rows)
    guard case let .line(matched) = result.first, result.count == 1 else {
        Issue.record("expected exactly one matching .line row")
        return
    }
    #expect(matched.line.message == "Connection refused")
}

@Test func regexIsCompiledOnceNotPerLineForRowsToo() {
    // The row-based overload shares the same compile-once seam as
    // `apply(to lines:)` — see that test below for the full rationale.
    // Regression guard specifically for the rows path: a naive
    // implementation that re-derived its own regex handling per row (rather
    // than reusing `matchPredicate`) would compile once per ROW, not once
    // per call.
    var lines: [LogLine] = []
    for i in 1...5_000 {
        lines.append(line(message: "request \(i) status=200 path=/widgets/\(i)"))
    }
    let rows: [LogRow] = buffered(lines).map(LogRow.line)
    let counter = LogFilter.CompilationCounter()

    let filter = LogFilter(query: #"status=\d+"#, isRegex: true)
    _ = filter.apply(to: rows, countingRegexCompilationsInto: counter)
    #expect(counter.count == 1)
}

@Test func regexIsCompiledOnceNotPerLine() {
    // 24,128 lines / 5.7 MB arrived in 20s from one live instance, and this
    // filter runs over the whole buffer on every keystroke. A fresh
    // `NSRegularExpression` per line is the naive shape and makes typing
    // feel broken; compiling once per call to `apply(to:)` is the fix.
    //
    // This used to assert on `ContinuousClock` elapsed time, but that flaked
    // under swift-testing's parallel execution: the same compile-once
    // implementation measured 4-5ms on an idle machine and 15.4ms on a
    // loaded one (observed in a full-suite run), both real measurements of
    // the same code, neither a regression. A naive per-line compile measures
    // 24-28ms idle — so any fixed millisecond bound sits in a narrowing gap
    // between two moving numbers. Counting compilations instead of timing
    // them can't flake with machine load, and still catches the naive shape
    // (confirmed: swapping in a per-line compile fails this test with
    // `counter.count == 5000`).
    var lines: [LogLine] = []
    for i in 1...5_000 {
        lines.append(line(message: "request \(i) status=200 path=/widgets/\(i)"))
    }
    let counter = LogFilter.CompilationCounter()

    var filter = LogFilter(query: #"status=\d+"#, isRegex: true)
    _ = filter.apply(to: lines, countingRegexCompilationsInto: counter)
    #expect(counter.count == 1)

    // A query change must recompile — this isn't "never recompile", it's
    // "not once per line".
    filter.query = #"status=\d{3}"#
    _ = filter.apply(to: lines, countingRegexCompilationsInto: counter)
    #expect(counter.count == 2)
}

// MARK: - Errors only
//
// The severity gate at the FILTER level. `LogPaneModelTests` covers what the
// pane does with it; these state the composition rules the filter itself
// owns — chiefly that the gate runs after record grouping, and that no
// overload of `apply` may quietly ignore the field.

@Test func errorsOnlyKeepsRowsAtErrorOrAboveAndNothingElse() {
    let rows: [ScoredRow] = [
        .init(scoring: .line(buffered(line(message: "GET /healthz 200")))),
        .init(scoring: .line(buffered(line(message: "WARN: disk at 80%")))),
        .init(scoring: .line(buffered(line(message: "ERROR: boom")))),
        .init(scoring: .line(buffered(line(message: "FATAL: shutting down")))),
    ]

    let kept = LogFilter(errorsOnly: true).apply(to: rows)
    #expect(kept.map { $0.lines.map(\.line.message).joined() } == ["ERROR: boom", "FATAL: shutting down"])
    // Off, the same rows all survive — so the assertion above is the gate
    // firing, not the fixture being small.
    #expect(LogFilter().apply(to: rows).count == 4)
}

@Test func errorsOnlyIsHonouredByTheUnscoredOverloadToo() {
    // `apply(to rows: [LogRow])` has no severities handed to it, so the
    // tempting implementation is one that ignores `errorsOnly` — a field
    // this type advertises and one of its two row overloads silently drops.
    // It scores the rows itself instead.
    let rows: [LogRow] = [
        .line(buffered(line(message: "GET /healthz 200"))),
        .line(buffered(line(message: "ERROR: boom"))),
    ]

    let kept = LogFilter(errorsOnly: true).apply(to: rows)
    #expect(kept.flatMap { $0.lines.map(\.line.message) } == ["ERROR: boom"])
}

@Test func errorsOnlyRunsAfterRecordGroupingNotBeforeIt() {
    // ORDER IS THE CLAIM. A pino record is a header line plus indented
    // continuations; here the header is the failure and the continuations are
    // ordinary text. The query matches only a CONTINUATION, so the record has
    // to be formed for anything to survive at all — and the header is what
    // opens the record.
    //
    // Gate first and it is the CONTINUATIONS that go, not the header: the
    // header is the only failing row, so it is all the gate leaves — and the
    // query matches none of it, so `LogRecord.group` has nothing to form a
    // record around and the result is empty. Gate last and the record forms,
    // the query keeps it whole, and the gate then leaves the failing header.
    // Two orders, two different answers, on the same three rows.
    //
    // (In general the gate can also take a header — `LogFilter`'s own doc
    // comment states that case, where the failure is a continuation and the
    // header is ordinary. On THIS fixture it is the other way round, and the
    // comment here used to describe the general case as if it were this one.)
    let recordLines = [
        line(message: "[01:13:52] ERROR: request failed", resource: "api", spanID: "dc:api"),
        line(message: "    url: /api/invoke", resource: "api", spanID: "dc:api"),
        line(message: "    responseTime: 12", resource: "api", spanID: "dc:api"),
    ]
    let rows = JSONBlock.detect(in: buffered(recordLines)).map(ScoredRow.init(scoring:))
    #expect(rows.map(\.severity) == [.error, .normal, .normal])

    let kept = LogFilter(query: "responseTime", errorsOnly: true).apply(to: rows)
    #expect(kept.flatMap { $0.lines.map(\.line.message) } == ["[01:13:52] ERROR: request failed"])
}
