import Foundation
import Testing
@testable import FulcrumKit

@Test func decodesTheVerifiedLineShape() throws {
    let json = #"{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"tick","spanID":"localserve:1","progressID":"","buildEvent":"","source":"runtime"}"#
    let line = try JSONDecoder().decode(LogLine.self, from: Data(json.utf8))
    #expect(line.resource == "server")
    #expect(line.level == .info)
    #expect(line.source == .runtime)
    #expect(line.message == "tick")
}

@Test func aTiltLevelMessageHasAnEmptyResource() throws {
    // Tilt-level messages such as "Tilt started on http://localhost:10350/"
    // arrive with resource: "" — not attached to any particular resource.
    let json = #"{"time":"2026-08-11T18:27:47+08:00","resource":"","level":"info","message":"Tilt started on http://localhost:10350/","spanID":"","progressID":"","buildEvent":"","source":"runtime"}"#
    let line = try JSONDecoder().decode(LogLine.self, from: Data(json.utf8))
    #expect(line.resource == "")
    #expect(line.message == "Tilt started on http://localhost:10350/")
}

@Test func anUnknownLevelIsPreservedNotDropped() throws {
    // level: "trace" -> .other("trace"), and the line still decodes rather
    // than being dropped by a closed enum.
    let json = #"{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"trace","message":"x","spanID":"","progressID":"","buildEvent":"","source":"runtime"}"#
    let line = try JSONDecoder().decode(LogLine.self, from: Data(json.utf8))
    #expect(line.level == .other("trace"))
}

@Test func anUnknownSourceIsPreservedNotDropped() throws {
    // source: "exec" -> .other("exec"), and the line still decodes rather
    // than being dropped by a closed enum — same rationale as LogLevel's
    // fallback, mirrored here since the spec required both.
    let json = #"{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"x","spanID":"","progressID":"","buildEvent":"","source":"exec"}"#
    let line = try JSONDecoder().decode(LogLine.self, from: Data(json.utf8))
    #expect(line.source == .other("exec"))
}

@Test func timestampsCarryTheirZoneOffset() throws {
    // "+08:00" is the user's zone; a parser that assumed "Z" would shift
    // every line 8 hours.
    let json = #"{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info","message":"tick","spanID":"","progressID":"","buildEvent":"","source":"runtime"}"#
    let line = try JSONDecoder().decode(LogLine.self, from: Data(json.utf8))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
    let expected = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 18, minute: 27, second: 47))
    )

    #expect(line.time == expected)
}

@Test func logLineTimestampsHaveNoFractionalSecondsUnlikeApiserverTimestamps() throws {
    // Log timestamps: "2026-08-11T18:27:47+08:00" — no fractional seconds, a
    // zone offset. Apiserver timestamps: "...:40.168097Z" — six fractional
    // digits, "Z" (see Resource.swift). A parser configured for one returns
    // nil for the other, so this proves LogLine decodes its own shape...
    let logJSON = #"{"time":"2026-08-11T18:27:47+08:00","resource":"","level":"info","message":"x","spanID":"","progressID":"","buildEvent":"","source":"runtime"}"#
    #expect(throws: Never.self) {
        try JSONDecoder().decode(LogLine.self, from: Data(logJSON.utf8))
    }

    // ...and rejects the apiserver's fractional-seconds shape rather than
    // silently misparsing it, which is what would happen if the two were
    // ever mixed up.
    let apiserverStyleJSON = #"{"time":"2026-08-11T18:27:47.168097Z","resource":"","level":"info","message":"x","spanID":"","progressID":"","buildEvent":"","source":"runtime"}"#
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(LogLine.self, from: Data(apiserverStyleJSON.utf8))
    }
}
