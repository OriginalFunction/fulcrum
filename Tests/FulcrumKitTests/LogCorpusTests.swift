import Foundation
import Testing
@testable import FulcrumKit

/// One record from `tilt logs --json`. Tilt's own field names are kept as-is
/// (rather than flattening to a bare message string) because the severity
/// rules this corpus exists to validate -- not written yet, this fixture
/// comes first -- read tilt's `level` field directly.
///
/// This type lives in the test target only. It is a fixture-loading helper,
/// not a severity predicate: it does not decide what counts as an error, it
/// only proves the corpus still has the shape later rules will need.
private struct LogCorpusLine: Decodable {
    let time: String
    let resource: String
    let level: String
    let message: String
    let spanID: String
    let progressID: String
    let buildEvent: String
    let source: String
}

/// TEST-ONLY. The committed corpus fixture, one JSONL record per element,
/// undecoded.
///
/// Not `private`: `SeverityScannerTests` loads the same fixture, and the only
/// part of that which differs is the DECODE TARGET — this file decodes into
/// `LogCorpusLine` because it asserts on fields (`progressID`, tilt's `level`)
/// that `LogLine` does not surface, while the scanner's tests decode straight
/// into `LogLine` and run real detection over the result. Both of those are
/// justified; the bundle lookup underneath them was simply duplicated, and a
/// second copy is a second place to fix when the fixture moves.
func logCorpusRecords() throws -> [Substring] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/log-corpus.jsonl", withExtension: nil))
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true)
}

private func loadLogCorpus() throws -> [LogCorpusLine] {
    let decoder = JSONDecoder()
    return try logCorpusRecords().map { try decoder.decode(LogCorpusLine.self, from: Data($0.utf8)) }
}

/// SYNTHESIZED, not captured. Every count in this file was re-derived on
/// 2026-08-16 from the output of `docs/testing/generate-log-corpus.swift`, and
/// describes a generated corpus modelled on a real one — not a recording of
/// anyone's traffic.
///
/// The fixture was, until this commit, 3,461 lines captured verbatim from the
/// developer's own running project. Nothing secret survived that capture (the
/// JWTs were redacted and re-verified), but the file still carried a commercial
/// product's internal hostnames, service names, tenant slugs, live project and
/// version ids, API route shapes and database table names — and this repository
/// is about to be public. The generator reproduces every SHAPE the rules read
/// and none of the identity: the system it describes is named after Northwind,
/// Contoso and Fabrikam under the reserved `.test` TLD, and is fictional.
///
/// Measured on the generated corpus: **3,428 total lines**, 3 pino `level:50`
/// records, 22 `statusCode` fields (16 × 200, 6 × 304) and **0** in 500–599.
/// That last absence is deliberate rather than accidental — the capture it
/// replaces contained no 5xx either, and reproducing the gap keeps
/// `json.statusCode`'s recall honestly documented as unit-tested only. The
/// generator makes adding one a three-line change if that is ever wanted.
///
/// The `err` count needs its form stated, because the two forms are different
/// signals and only one of them is what `json.err`'s label branch was written
/// for. The LABEL form — a line ending in `err: {`, which is how pino's
/// pretty-printer splits a serialised error across lines — occurs **0** times
/// here, matching the capture, where it was unreachable because pino-pretty
/// writes raw un-quoted stack text that never parses. What the fixture has is
/// 3 INLINE `"err":{` keys, all inside compact one-line JSON records that also
/// carry `"level":50` (fixture lines 1043, 2147, 3324), so `json.level` reports
/// them on the tie and `json.err` is never the rule named. An earlier version
/// of this comment said "3 `err: {` block openers", which counted the inline
/// form under the label form's name and made a rule look corpus-validated that
/// this fixture cannot validate at all — see `SeverityScanner.jsonErrorObject`.
///
/// Stack frames are counted three ways because the number depends entirely on
/// the predicate, and a bare count invites a later reader to trust the wrong
/// one. On the generated corpus: **109** lines match a frame anchored at the
/// start (`^\s+at fn (file:l:c)`), **162** contain an `at fn(` anywhere —
/// including tab-indented Java frames and the three compact pino records whose
/// embedded JSON `stack` string holds its own frames — and **212** begin with
/// `    at ` or `\tat `, which is the predicate
/// `theRulesLeaveEveryStackFrameAlone` actually uses. The severity rules must
/// leave all of them alone: 24 frames tinted for one failure would light up the
/// pane for a single error.
///
/// The severity-token count below is a plain substring match on `"ERROR"` /
/// `"FATAL"` (`String.contains`), deliberately not a word-boundary regex --
/// a word-boundary scan measures 19 on this fixture, but it silently misses
/// the 6 lines from `studio-api` where the token is ANSI-wrapped
/// (`ESC[31mERRORESC[39m`), because the escape codes sit inside what would
/// otherwise be the word boundary. The substring predicate catches those
/// too and measures 25 — the same 25 the capture measured, because the
/// generator reproduces that split exactly.
///
/// Thresholds below sit under those measurements. The old cushion existed to
/// absorb variance from a re-capture on a different day; a generated corpus has
/// no such variance — regenerating an unchanged generator is byte-identical —
/// so the cushion now exists only to absorb a deliberate edit to the generator
/// that adds or removes a few lines, while still failing loudly if an edit
/// silently drops most of the interesting ones. That failure mode is the entire
/// reason this fixture exists ahead of the rules it validates.
@Test func theCorpusStillContainsTheSignalsTheRulesAreValidatedAgainst() throws {
    let lines = try loadLogCorpus()

    #expect(lines.count > 3_000, "too small to show false positives against ordinary traffic")

    let severityTokenLines = lines.filter { $0.message.contains("ERROR") || $0.message.contains("FATAL") }
    #expect(severityTokenLines.count >= 20, "lost most of the ERROR/FATAL-bearing lines")

    #expect(lines.contains { $0.message.contains("no partition of relation") })
}

/// A later rule uses the emitter's own ANSI red (SGR 31) as a weak severity
/// signal, so a generator that "cleaned up" escape sequences before they ever
/// reached the fixture would silently destroy that signal. This test only
/// checks that ANSI escape *characters* are still present after decode -- 356
/// lines measured on the generated corpus, against 348 on the capture it
/// replaces -- it does not verify any specific sequence round-trips
/// byte-for-byte; that would need pinning an exact known sequence rather than
/// counting presence, which this test does not do. tilt JSON-escapes ESC as a
/// six-character sequence (backslash, u, 0, 0, 1, b) rather than a raw 0x1B
/// byte, and the generator writes that same six-character form, so what is on
/// disk is what tilt would have written; `JSONDecoder` turns it back into the
/// real escape character on decode, which is what this checks for.
@Test func theCorpusStillContainsAnsiEscapeCharacters() throws {
    let lines = try loadLogCorpus()
    let esc = Character(UnicodeScalar(0x1B))

    let ansiLines = lines.filter { $0.message.contains(esc) }
    #expect(ansiLines.count >= 100, "ANSI escapes were stripped or lost during capture/trim")
}

/// Confirms the fixture is tilt's own JSONL shape, not a flattened list of
/// message strings -- every record decodes with its `level` field intact,
/// which is what a later rule reading tilt's `level` field directly depends
/// on, and traffic is attributed to many distinct resources rather than one.
/// 42 distinct `resource` values on the generated corpus (41 named plus the
/// empty one below), against 39 plus the empty one on the capture it replaces.
///
/// `resource` and `spanID` are allowed to be empty: tilt itself emits global,
/// unattributed system lines this way (e.g. `[Docker Prune] removed ...`
/// lines carry `"resource":"","spanID":""`), so requiring every line to carry
/// a resource would be asserting something false about real tilt output. The
/// generator emits 5 such lines for exactly that reason.
@Test func theCorpusKeepsTiltsOwnFieldsIntact() throws {
    let lines = try loadLogCorpus()

    #expect(lines.allSatisfy { !$0.level.isEmpty })
    #expect(Set(lines.map(\.resource)).count > 5, "expected traffic from many distinct resources, not one")
}
