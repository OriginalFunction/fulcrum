import Foundation
import Testing
@testable import FulcrumKit

@Test func preservesObjectKeyOrder() {
    guard case let .object(pairs)? = JSONValue.parse(#"{"z":1,"a":2,"m":3}"#) else {
        Issue.record("did not parse"); return
    }
    #expect(pairs.map(\.0) == ["z", "a", "m"]) // NOT sorted
}

@Test func parsesTheRealAwsBlobShape() {
    // The STRUCTURE is verbatim from a real CloudWatch EMF blob captured off a
    // tilt instance on port 10350 on 2026-08-12 — not a reconstruction. Only the
    // service, namespace and tenant names are fictional; every structural feature
    // the parser is tested on is untouched, which is what this test reads. That
    // shape is what the log pane has to render: nested objects, an array of
    // objects, an array of arrays of strings, a 13-digit integer timestamp,
    // fractional and integer numbers, and a zero.
    let raw = #"""
    {"_aws":{"Timestamp":1786497237169,"CloudWatchMetrics":[{"Namespace":"Northwind/Database","Dimensions":[["Service","Environment"]],"Metrics":[{"Name":"DbQueryDuration","Unit":"Milliseconds"},{"Name":"DbQueryCount","Unit":"Count"},{"Name":"DbQueryError","Unit":"Count"},{"Name":"DbRowCount","Unit":"Count"}]}]},"Service":"northwind-render-service","Environment":"development","DbQueryDuration":0.48,"DbQueryCount":1,"DbQueryError":0,"DbRowCount":1,"QueryName":"unnamed","TenantId":"contoso-master"}
    """#

    guard case let .object(top)? = JSONValue.parse(raw) else {
        Issue.record("did not parse"); return
    }
    #expect(top.map(\.0) == [
        "_aws", "Service", "Environment", "DbQueryDuration", "DbQueryCount",
        "DbQueryError", "DbRowCount", "QueryName", "TenantId",
    ])

    guard case let .object(aws)? = top.first(where: { $0.0 == "_aws" })?.1 else {
        Issue.record("_aws did not parse as an object"); return
    }
    #expect(aws.first?.0 == "Timestamp")
    #expect(aws.first?.1 == .number(1786497237169))

    guard case let .array(metricsBlocks)? = aws.first(where: { $0.0 == "CloudWatchMetrics" })?.1,
          case let .object(firstBlock)? = metricsBlocks.first else {
        Issue.record("CloudWatchMetrics did not parse as an array of objects"); return
    }
    #expect(firstBlock.first?.1 == .string("Northwind/Database"))

    // Dimensions is an array of arrays — the shape most likely to be flattened
    // by a parser that treats nesting loosely.
    guard case let .array(dimensionGroups)? = firstBlock.first(where: { $0.0 == "Dimensions" })?.1,
          case let .array(firstGroup)? = dimensionGroups.first else {
        Issue.record("Dimensions did not parse as an array of arrays"); return
    }
    #expect(firstGroup == [.string("Service"), .string("Environment")])

    guard case let .array(metrics)? = firstBlock.first(where: { $0.0 == "Metrics" })?.1 else {
        Issue.record("Metrics did not parse as an array"); return
    }
    #expect(metrics.count == 4)

    #expect(top.first(where: { $0.0 == "DbQueryDuration" })?.1 == .number(0.48))
    #expect(top.first(where: { $0.0 == "DbQueryError" })?.1 == .number(0))
}

@Test func summaryOfAnObjectNamesItsFirstFields() {
    guard let value = JSONValue.parse(#"{"status":"success","data":{"jobName":"metrics-collection"}}"#) else {
        Issue.record("did not parse"); return
    }
    // Informative and collapsed: field names show, but the nested object
    // is not expanded past one level — that's what makes it a "preview".
    #expect(value.summary(maxLength: 200) == #"{status: "success", data: {…}}"#)
}

@Test func summaryIsTruncatedToItsBudget() {
    let raw = #"{"message":"this is a very long message that will not fit inside a small preview budget at all"}"#
    guard let value = JSONValue.parse(raw) else { Issue.record("did not parse"); return }

    let truncated = value.summary(maxLength: 20)
    #expect(truncated.count == 20)
    #expect(truncated.hasSuffix("…")) // truncation must be visible, not silent
    // What's kept is a genuine prefix of the full rendering, not something
    // invented — dropping only the truncation marker itself.
    let full = value.summary(maxLength: .max)
    #expect(full.hasPrefix(truncated.dropLast()))
    #expect(full.count > truncated.count)
}

@Test func malformedJSONReturnsNilRatherThanPartialTruth() {
    // Truncated mid-write: opening brace and one field, no closer.
    #expect(JSONValue.parse(#"{"status":"success","#) == nil)
    // Unterminated string.
    #expect(JSONValue.parse(#"{"status":"succ"#) == nil)
    // Trailing garbage after an otherwise-complete value.
    #expect(JSONValue.parse(#"{"a":1} garbage"#) == nil)
    // Bracket-type mismatch.
    #expect(JSONValue.parse(#"{"a":1]"#) == nil)
}

@Test func deeplyNestedInputDoesNotOverflowTheStack() {
    // 10,000 nested arrays. A recursive-descent parser without a depth cap
    // crashes the process here (stack overflow, uncatchable by Swift error
    // handling). The cap must reject this outright: the whole parse fails
    // rather than returning a tree silently truncated at the deepest
    // levels, which would be a quiet lie about the data.
    let raw = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
    #expect(JSONValue.parse(raw) == nil)
}

@Test func largeIntegerTimestampDoesNotBecomeScientificNotationInSummary() {
    // The measured _aws blobs carry millisecond Unix timestamps like this
    // one — a 13-digit integer that must round-trip through `summary` as
    // plain digits, not `1.786493715538e+12`.
    guard let value = JSONValue.parse(#"{"Timestamp":1786493715538}"#) else {
        Issue.record("did not parse"); return
    }
    let text = value.summary(maxLength: 200)
    #expect(text == "{Timestamp: 1786493715538}")
    #expect(!text.contains("e+"))
    #expect(!text.contains("e-"))
}

@Test func theDepthCapAdmitsExactlyTheDocumentedNumberOfLevels() {
    // `maxDepth` is documented as 512 levels. `parseValue` is entered with
    // depth 0 for the outermost value, so a `depth <= maxDepth` guard quietly
    // admitted 513 — code and comment disagreeing about the one number the
    // cap exists to state. Pinned from both sides so neither can drift.
    func nested(_ levels: Int) -> String {
        String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
    }
    // Reduced to `Bool` before `#expect` sees it, deliberately. Handing the
    // optional tree straight to the macro means that when the expectation
    // FAILS, swift-testing renders the actual value — and `String(describing:)`
    // over a 513-deep `indirect enum` overflows the stack inside the
    // reflection machinery. Verified: against the pre-fix `depth <= maxDepth`
    // this test killed the whole test process with signal 10 instead of
    // reporting, taking every other test in the run down with it.
    let atTheCap = JSONValue.parse(nested(512)) != nil
    let pastTheCap = JSONValue.parse(nested(513)) == nil
    #expect(atTheCap)
    #expect(pastTheCap)
}

@Test func sixteenDigitIntegersRenderWithoutADecimalPoint() {
    // The integral-formatting range was `abs(n) < 1e15`, which is BELOW
    // `Double`'s exact-integer limit of 2^53 (9007199254740992). Integers in
    // between — nanosecond timestamps, Snowflake-style IDs — fell through to
    // `String(Double)` and printed as `9007199254740992.0`: a decimal point
    // on a value that has none.
    guard let value = JSONValue.parse(#"{"id":1234567890123456,"limit":9007199254740992}"#) else {
        Issue.record("did not parse"); return
    }
    #expect(value.summary(maxLength: 200) == "{id: 1234567890123456, limit: 9007199254740992}")
}

@Test func fractionalNumbersStillRenderWithTheirDecimal() {
    guard let value = JSONValue.parse(#"{"Duration":842.5}"#) else {
        Issue.record("did not parse"); return
    }
    #expect(value.summary(maxLength: 200) == "{Duration: 842.5}")
}

@Test func smallMagnitudeFractionsRenderAsPlainDecimalsNotScientificNotation() {
    // Swift's own `Double` description switches to scientific notation below
    // 1e-4 — `String(0.000001234)` is `"1.234e-06"`. That is Swift's internal
    // representation leaking into a log viewer; a user scanning this pane
    // should see the same plain digits the source line carried.
    guard let value = JSONValue.parse(#"{"Ratio":0.000001234}"#) else {
        Issue.record("did not parse"); return
    }
    let text = value.summary(maxLength: 200)
    #expect(text == "{Ratio: 0.000001234}")
    #expect(!text.contains("e-"))
    #expect(!text.contains("E-"))
}

@Test func smallMagnitudeFractionsInJSONTextAlsoAvoidScientificNotation() {
    // Same rule, `jsonText`'s own call site into `formatNumber` — pinned
    // separately since `jsonTextOfANumberPreservesTheAwsTimestampAsAnInteger`
    // above pins the integral case there but nothing pins the fractional one.
    guard let value = JSONValue.parse(#"{"Ratio":-0.000001234}"#) else {
        Issue.record("did not parse"); return
    }
    let text = value.jsonText(pretty: false)
    #expect(text == #"{"Ratio": -0.000001234}"#)
    #expect(!text.contains("e-"))
}

@Test func mediumMagnitudeIntegralNumbersStillRenderPlainNotScientific() {
    // `1.2e5` parses to the Double 120000 — already handled by the existing
    // integral fast-path (whole number, well under 2^53), not by the new
    // small-magnitude expansion above. Pinned so the two code paths can't
    // drift into disagreeing about this boundary.
    guard let value = JSONValue.parse(#"{"n":1.2e5}"#) else {
        Issue.record("did not parse"); return
    }
    #expect(value.summary(maxLength: 200) == "{n: 120000}")
}

// MARK: - `jsonText` (the "Copy Value" / "Copy JSON" round trip)

@Test func jsonTextRoundTripsThroughParse() {
    // The real coverage: whatever this produces must be valid JSON that
    // parses back to an EQUAL tree, not merely "looks right" for one shape.
    let raw = #"{"a":1,"b":[1,2,"three"],"c":{"nested":true},"d":null,"e":0.48}"#
    guard let value = JSONValue.parse(raw) else { Issue.record("did not parse"); return }

    let compact = value.jsonText(pretty: false)
    guard let reparsedCompact = JSONValue.parse(compact) else {
        Issue.record("re-parse of compact jsonText failed: \(compact)"); return
    }
    #expect(reparsedCompact == value)

    let pretty = value.jsonText(pretty: true)
    guard let reparsedPretty = JSONValue.parse(pretty) else {
        Issue.record("re-parse of pretty jsonText failed: \(pretty)"); return
    }
    #expect(reparsedPretty == value)
}

@Test func jsonTextEscapesSpecialCharactersInStrings() {
    // Newline, an embedded quote, and a backslash — all three must survive
    // the round trip, not just print as valid-looking-but-wrong text.
    guard let value = JSONValue.parse(#"{"msg":"line1\nline2 \"quoted\" \\backslash"}"#) else {
        Issue.record("did not parse"); return
    }
    let text = value.jsonText(pretty: false)
    guard let reparsed = JSONValue.parse(text) else {
        Issue.record("re-parse failed: \(text)"); return
    }
    #expect(reparsed == value)
}

@Test func jsonTextOfEmptyContainersIsCompactRegardlessOfPrettyPrinting() {
    guard let value = JSONValue.parse(#"{"a":{},"b":[]}"#) else { Issue.record("did not parse"); return }
    #expect(value.jsonText(pretty: true) == "{\n  \"a\": {},\n  \"b\": []\n}")
}

@Test func jsonTextPrettyIndentsNestedContainersTwoSpacesPerLevel() {
    guard let value = JSONValue.parse(#"{"a":{"b":1}}"#) else { Issue.record("did not parse"); return }
    #expect(value.jsonText(pretty: true) == "{\n  \"a\": {\n    \"b\": 1\n  }\n}")
}

@Test func jsonTextOfANumberPreservesTheAwsTimestampAsAnInteger() {
    // Same integral-formatting rule `summary` already proves — pinned again
    // here because `jsonText` has its own call site into `formatNumber` and
    // a future refactor could silently split the two.
    guard let value = JSONValue.parse(#"{"Timestamp":1786493715538}"#) else {
        Issue.record("did not parse"); return
    }
    let text = value.jsonText(pretty: false)
    #expect(text == #"{"Timestamp": 1786493715538}"#)
    #expect(!text.contains("e+"))
}
