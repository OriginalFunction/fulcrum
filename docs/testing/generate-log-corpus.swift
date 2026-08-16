// Generates Tests/FulcrumKitTests/Fixtures/log-corpus.jsonl -- the SYNTHESIZED
// log corpus the severity rules are validated against.
//
//   swift docs/testing/generate-log-corpus.swift [output-path]
//
// ## Why this exists rather than a capture
//
// The fixture used to be 3,461 lines captured verbatim from one developer's
// running project (docs/testing/capture-log-corpus.sh, still here, still how
// the shapes below were learned). Nothing secret survived that capture -- the
// JWTs were redacted -- but the file still carried a commercial product's
// microservice topology: internal hostnames, service names, tenant slugs, live
// project and version ids, API route shapes and database table names. This repo
// is public. Public git history is permanent.
//
// So the corpus is now GENERATED: same shapes, invented identity. The system
// below is fictional and deliberately signposted as such -- it is named after
// Northwind, Contoso and Fabrikam, the canonical fictional companies of sample
// data, under the RFC 6761 `.test` TLD, which can never resolve.
//
// ## What faithfulness means here
//
// `SeverityScanner`'s rules key on STRUCTURE -- a numeric pino `level`, an HTTP
// `statusCode` field, a severity token near the start of a line, the emitter's
// own red -- and never on anyone's service names. So a synthesis that keeps the
// structure keeps every test meaningful. The structure that had to survive,
// each measured off the original capture and reproduced below:
//
//   * The emitter formats: pino with and without a service name, postgres,
//     nginx access and error logs, the vite dev server, Flask/werkzeug
//     boilerplate, Java/jetty, Go/zap, redis, docker build output, and tilt's
//     own unattributed `[Docker Prune]` lines (empty `resource` AND `spanID` --
//     real tilt does this, and `theCorpusKeepsTiltsOwnFieldsIntact` depends on
//     it).
//   * Severity tokens at their real ANSI-STRIPPED columns: 0 (Flask), 4 (a pino
//     continuation key), 15 (pino without a service name), 19 (jetty), 21
//     (nginx), 24 (zap), 26 (pino with a service name), 30/34/42 (three vite
//     shapes), 35/36 (postgres). That spread is WHY `SeverityScanner` scans a
//     leading window instead of anchoring at column zero, and 42 is why the
//     window is 80 rather than 40.
//   * ANSI escapes in tilt's own JSON-encoded form (``, never a raw 0x1B
//     byte), including six lines that wrap the token itself in red
//     (`ESC[31mERRORESC[39m`) -- the exact shape that defeats a word-boundary
//     scan over raw bytes.
//   * Embedded JSON: compact one-line pino records carrying `"level":50`,
//     `"statusCode"` and an inline `"err":{…}`; multi-line `res: {` / `req: {`
//     blocks; stack traces both as their own lines and inside a JSON `stack`
//     string; and a `"severity":"ERROR"` far enough into a payload that the
//     token rule must not reach it.
//   * The FALSE-POSITIVE surface, which matters as much as the true positives:
//     CloudWatch EMF blocks whose metric is literally named `ErrorCount` with
//     value 0, `"error": null` keys, aligned `error       : 0` summary columns,
//     lower-case `errors` in routes and metric names, and prose containing the
//     word "error". A corpus of only errors proves nothing about precision.
//
// ## Determinism
//
// Byte-identical output for the same source. All randomness comes from the
// SplitMix64 below, seeded by `corpusSeed`; nothing reads the clock, the
// environment, the filesystem, or an unseeded RNG, and nothing iterates a
// Dictionary or Set. Regenerating an unchanged generator produces a zero-line
// diff, so a real change to the fixture is always visible as one.
//
// ## Adding a shape
//
// Add it to the emitter that produces it (or add an emitter), then re-run this
// script and re-derive the counts pinned in `LogCorpusTests.swift` and
// `SeverityScannerTests.swift`. Do NOT hand-edit the .jsonl -- the next
// regeneration silently discards it. If the new shape SHOULD be flagged, add it
// to `expectedCorpusFlags`; if it should not, adding it here and watching the
// corpus test stay green is exactly the precision evidence this fixture exists
// to provide.

import Foundation

// MARK: - Determinism

/// The one source of randomness. Change it and every id, port, duration and
/// interleaving below changes together -- which is a fixture-wide rewrite, not
/// a refresh, so there is no reason to.
let corpusSeed: UInt64 = 0xC0FF_EE15_600D_1DEA

/// SplitMix64. Chosen because it is four lines, has no hidden state, and
/// produces the same stream on every platform and every Swift version --
/// `SystemRandomNumberGenerator` guarantees none of that.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

var rng = SplitMix64(seed: corpusSeed)

func roll(_ range: ClosedRange<Int>) -> Int {
    let span = UInt64(range.upperBound - range.lowerBound + 1)
    return range.lowerBound + Int(rng.next() % span)
}

func pick<T>(_ options: [T]) -> T { options[Int(rng.next() % UInt64(options.count))] }

/// Lower-case hex of `digits` length -- container ids, span ids, correlation
/// fragments. Random-looking by construction and therefore not identifying.
func hex(_ digits: Int) -> String {
    let alphabet = Array("0123456789abcdef")
    return String((0..<digits).map { _ in alphabet[Int(rng.next() % 16)] })
}

func uuidish() -> String {
    "\(hex(8))-\(hex(4))-\(hex(4))-\(hex(4))-\(hex(12))"
}

/// A base36-ish opaque id. Deliberately NOT the `prefix_14chars` shape the
/// captured corpus used: an id FORMAT carries identity too, so this uses a
/// hyphen and a shorter body.
func opaqueID(_ prefix: String) -> String {
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    return prefix + "-" + String((0..<8).map { _ in alphabet[Int(rng.next() % 36)] })
}

// MARK: - The fictional system
//
// Every name a reader could mistake for someone's real system lives in this
// one block. Northwind, Contoso and Fabrikam are the canonical fictional
// companies of sample data; `.test` is reserved by RFC 6761 and never resolves.

let primaryOrg = "contoso"
let secondaryOrg = "fabrikam"
let studioOrg = "studio-internal"

let brand = "northwind"
let rootDomain = "northwind.test"
let appHost = "\(primaryOrg).\(rootDomain)"
let adminHost = "admin.\(rootDomain)"
let studioHost = "studio.internal.\(rootDomain)"
let apiHost = "api.\(rootDomain)"
let wildcardHost = "*.\(rootDomain)"

let catalogService = "northwind-catalog-service"
let accountService = "northwind-account-service"
let consoleService = "northwind-console-service"
let renderService = "northwind-render-service"
let meterPackage = "@northwind/meter"

let javaPackage = "com.northwind.render"
let repoRoot = "/Users/dev/src/northwind"
let bridgeIP = "172.28.0.1"

/// The three tables the corpus names. `render_usage_events` is partitioned by
/// `sampled_at`, which is what the postgres failure below is about.
let usageTable = "render_usage_events"
let grantsTable = "session_grants"
let jobsTable = "render_jobs"

/// Routes. `/api/v2/...` throughout, with nouns that belong to the fictional
/// product rather than to any real one.
let readRoutes = [
    "/api/v2/me/entitlements",
    "/api/v2/items",
    "/api/v2/attributes/sets?scope=item&key=item_detail_panel",
    "/api/v2/orgs/\(primaryOrg)/settings",
    "/api/v2/presets",
    "/api/v2/notes?unread=true",
    "/api/v2/errors?since=1h",  // lower-case `errors` in a route: NOT a claim.
]

let renderRoutes = [
    "/api/v2/render/poster-frame",
    "/api/v2/render/contact-sheet",
    "/api/v2/render/waveform",
]

// MARK: - Records

/// tilt stamps every record in a `tilt logs --json` dump with the time of the
/// DUMP, not of the line, so all 3,461 records of the captured fixture carried
/// one identical timestamp. Reproduced, because `LogLine` decodes this field
/// and a fixture that varied it would be modelling something tilt does not do.
let captureTime = "2026-08-16T09:15:32+08:00"

struct Record {
    var resource: String
    var message: String
    var spanID: String
    var progressID: String = ""
    var buildEvent: String = ""
    var source: String = "runtime"
}

/// Escapes exactly as Go's `encoding/json` does, which is what tilt uses:
/// `<`, `>` and `&` become `<`, `>`, `&`, and every other
/// control character becomes lower-case `\u00xx`. That is why an ESC arrives as
/// the six characters `` rather than a raw 0x1B byte, and
/// `theCorpusStillContainsAnsiEscapeCharacters` is a statement about what
/// `JSONDecoder` turns those six back into.
func jsonEscaped(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.unicodeScalars.count + 16)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "<": out += "\\u003c"
        case ">": out += "\\u003e"
        case "&": out += "\\u0026"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

/// Field order matches tilt's own output, which `LogCorpusLine` decodes by name
/// and a human reads by position.
func encode(_ record: Record) -> String {
    "{\"time\":\"\(captureTime)\""
        + ",\"resource\":\"\(jsonEscaped(record.resource))\""
        + ",\"level\":\"info\""
        + ",\"message\":\"\(jsonEscaped(record.message))\""
        + ",\"spanID\":\"\(jsonEscaped(record.spanID))\""
        + ",\"progressID\":\"\(jsonEscaped(record.progressID))\""
        + ",\"buildEvent\":\"\(jsonEscaped(record.buildEvent))\""
        + ",\"source\":\"\(record.source)\"}"
}

// MARK: - ANSI

let esc = "\u{1B}"
func sgr(_ code: Int, _ text: String, reset: Int = 39) -> String {
    "\(esc)[\(code)m\(text)\(esc)[\(reset)m"
}
func red(_ text: String) -> String { sgr(31, text) }
func cyan(_ text: String) -> String { sgr(36, text) }
func blue(_ text: String) -> String { sgr(34, text) }
func magenta(_ text: String) -> String { sgr(35, text) }
func dim(_ text: String) -> String { sgr(2, text, reset: 22) }

// MARK: - Streams
//
// An emitter produces CHUNKS: runs of consecutive lines from one resource. The
// chunk is the unit of interleaving, so a multi-line `res: {` block stays
// contiguous and still detects as one `JSONBlock` after the streams are merged,
// exactly as it does in a real tilt dump.

struct Stream {
    var name: String
    var chunks: [[Record]]
}

var streams: [Stream] = []

/// Runs `body` until it has produced at least `lines` lines, then stops on the
/// next chunk boundary. Line budgets rather than chunk counts because the
/// corpus's shape is "this resource is 35% of the traffic", and a chunk's
/// length varies with what it is saying.
func emit(_ name: String, lines budget: Int, _ body: () -> [Record]) {
    var chunks: [[Record]] = []
    var produced = 0
    while produced < budget {
        let chunk = body()
        guard !chunk.isEmpty else { continue }
        chunks.append(chunk)
        produced += chunk.count
    }
    streams.append(Stream(name: name, chunks: chunks))
}

/// For a fixed, hand-written scene: emitted verbatim, in order, one chunk.
func emitFixed(_ name: String, _ chunks: [[Record]]) {
    streams.append(Stream(name: name, chunks: chunks))
}

// MARK: - Shared fragments

func timestampMillis() -> String {
    String(format: "%02d:%02d:%02d.%03d", roll(0...23), roll(0...59), roll(0...59), roll(0...999))
}

func dateTimeMillis() -> String {
    String(
        format: "2026-08-15 %02d:%02d:%02d.%03d",
        roll(0...23), roll(0...59), roll(0...59), roll(0...999)
    )
}

func clockAMPM() -> String {
    let hour = roll(1...12)
    return String(format: "%d:%02d:%02d %@", hour, roll(0...59), roll(0...59), pick(["AM", "PM"]))
}

/// pino-pretty's continuation lines: four spaces, a key, a colon, a value.
/// These are NOT JSON -- `JSONBlock.detect` leaves them as `.line` rows -- and
/// they are where the `error: "fetch failed"` shape lives.
func pinoField(_ key: String, _ value: String, coloured: Bool = false) -> String {
    coloured ? "    \(magenta(key)): \(value)" : "    \(key): \(value)"
}

// MARK: - Emitter: pino with a service name (token column 26)
//
// `[2026-08-15 05:32:17.780] DEBUG (northwind-catalog-service): …`
// Uncoloured, as pino-pretty runs inside a container with no TTY. The bulk of
// the corpus. Its continuation lines carry the multi-line `req: {` / `res: {`
// blocks whose `statusCode` fields are every one of the corpus's status fields.

func pinoHeader(_ service: String, _ level: String, _ message: String) -> String {
    "[\(dateTimeMillis())] \(level) (\(service)): \(message)"
}

func resBlock(status: Int) -> [String] {
    [
        "    res: {",
        "      \"statusCode\": \(status),",
        "      \"headers\": {",
        "        \"content-type\": \"application/json\",",
        "        \"content-length\": \"\(roll(120...9000))\"",
        "      }",
        "    }",
    ]
}

func reqBlock(method: String, route: String) -> [String] {
    [
        "    req: {",
        "      \"id\": \"\(roll(1...9000))\",",
        "      \"method\": \"\(method)\",",
        "      \"url\": \"\(route)\",",
        "      \"headers\": {",
        "        \"host\": \"\(appHost)\",",
        "        \"user-agent\": \"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36\"",
        "      }",
        "    }",
    ]
}

func catalogBackendChunk() -> [Record] {
    let span = "dc:catalog-backend"
    func line(_ text: String) -> Record {
        Record(resource: "catalog-backend", message: text, spanID: span)
    }

    switch roll(0...9) {
    case 0, 1, 2:
        // A permission evaluation, the noisiest thing in the real corpus:
        // a header plus a dozen pino continuation lines, several of which are
        // indented text that only LOOKS like JSON.
        var out = [line(pinoHeader(catalogService, "DEBUG", "Permission evaluation completed"))]
        out += [
            pinoField("subjectId", "\"\(opaqueID("usr"))\""),
            pinoField("resourceId", "\"\(opaqueID("itm"))\""),
            pinoField("decision", "\"Allow\""),
            "    roleIds: [",
            "      \"role_editor\",",
            "      \"role_reviewer\"",
            "    ]",
            pinoField("scopePoliciesCount", "\(roll(0...4))"),
            pinoField("resourceMatches", "true"),
            "    matched: [",
            "      {",
            "        \"actions\": [",
            "          \"item:read\",",
            "          \"item:comment\"",
            "        ],",
            "        \"effect\": \"Allow\",",
            "        \"resource\": \"nrn:*:*/*\"",
            "      }",
            "    ]",
            pinoField("elapsedMs", "\(roll(0...12))"),
        ].map(line)
        return out

    case 3, 4:
        // A served request: header, req block, res block. The res block is a
        // labelled `res: {` that detection collapses, and its `statusCode` is
        // 200 or 304 -- never 5xx. The captured corpus contained ZERO 5xx in
        // 3,461 lines, and that absence is reproduced deliberately: it is why
        // `json.statusCode`'s recall is documented as unit-tested only.
        let route = pick(readRoutes)
        let status = pick([200, 200, 200, 304])
        var out = [
            line(pinoHeader(
                catalogService, "INFO",
                "\(uuidish()) GET \(route) completed in \(roll(1...240))ms"
            ))
        ]
        out += reqBlock(method: "GET", route: route).map(line)
        out += resBlock(status: status).map(line)
        return out

    case 5:
        // The false-positive surface, stated by an emitter that means the
        // opposite: an error slot reported as empty, and a summary column whose
        // colon belongs to the alignment rather than to the word.
        return [
            line(pinoHeader(catalogService, "INFO", "Reconciliation sweep finished")),
            line("    swept: \(roll(20...400))"),
            line("    repaired: 0"),
            line("    error       : 0"),
            line("    warnings    : 0"),
            line("    \"error\": null,"),
            line("    \"warning\": false,"),
        ]

    case 6:
        // Prose that contains the word "error" and is not a claim that one
        // occurred. The captured corpus had no sentence like this, so the
        // token rule's case-insensitivity could not be distinguished from a
        // rule that reads any occurrence. Now it can.
        return [
            line(pinoHeader(
                catalogService, "INFO",
                "recovered from the error and retried the upload without further incident"
            )),
            line(pinoHeader(
                catalogService, "INFO", "no error was returned by the upstream on retry \(roll(2...4))"
            )),
            line(pinoField("errors_total", "\(roll(0...3))")),
        ]

    case 7:
        return [
            line(pinoHeader(catalogService, "DEBUG", "Resource policies cache hit")),
            line(pinoField("orgSlug", "\"\(pick([primaryOrg, secondaryOrg]))\"")),
            line(pinoField("entries", "\(roll(1...60))")),
            line(pinoField("ttlMs", "\(roll(1000...60000))")),
        ]

    case 8:
        return [
            line(pinoHeader(catalogService, "INFO", "SSE client connected")),
            line(pinoField("orgSlug", "\"\(primaryOrg)\"")),
            line(pinoField("subjectId", "\"\(opaqueID("usr"))\"")),
            line(pinoHeader(catalogService, "INFO", "SSE client disconnected")),
            line(pinoField("afterMs", "\(roll(200...90000))")),
        ]

    default:
        // Docker build output that tilt attributes to the resource it is
        // building: `source: "build"`, and a `progressID` on some of it.
        let step = roll(1...11)
        let instruction = pick([
            "WORKDIR /app [cached]",
            "RUN --mount=type=cache,target=/root/.npm npm ci [cached]",
            "COPY --from=builder /app/server/dist ./server/dist",
            "FROM docker.io/library/node:jod@sha256:" + hex(64),
        ])
        return [
            Record(
                resource: "catalog-backend",
                message: "     [builder \(step)/11] \(instruction)",
                spanID: "build:\(roll(300...700))",
                progressID: "[builder \(step)/11]",
                source: "build"
            )
        ]
    }
}

// MARK: - Emitter: pino WITHOUT a service name (token column 15)
//
// `[17:29:12.835] DEBUG: New client connected`, ANSI-coloured, because this one
// runs with a TTY. Six of its lines colour the token itself -- `ESC[31mERROR
// ESC[39m` -- which is the shape that defeats a word-boundary scan over raw
// bytes and the reason `SeverityScanner` scans the STRIPPED text.

func studioAPIOrdinaryChunk() -> [Record] {
    let span = "dc:studio-api"
    func line(_ text: String) -> Record {
        Record(resource: "studio-api", message: text, spanID: span)
    }
    let table = pick([jobsTable, grantsTable])
    return [
        line("[\(timestampMillis())] \(blue("DEBUG")): \(cyan("Executed query"))"),
        line(pinoField("query", "\"SELECT COUNT(*) as count FROM \(table) t \"", coloured: true)),
        line(pinoField("rows", "\(roll(0...40))", coloured: true)),
        line(pinoField("elapsed", "\(roll(0...30))", coloured: true)),
        line(pinoField("service", "\"studio-api\"", coloured: true)),
        line(pinoField("env", "\"development\"", coloured: true)),
    ]
}

/// The six ANSI-wrapped `ERROR` lines and the one `error: "fetch failed"`
/// continuation, hand-written because their exact form is what several tests
/// quote. The token sits at stripped column 15 on the headers and column 4 on
/// the continuation.
func studioAPIFailureChunks() -> [[Record]] {
    let span = "dc:studio-api"
    func line(_ text: String) -> Record {
        Record(resource: "studio-api", message: text, spanID: span)
    }
    let subjects = [
        "Failed to fetch render presets",
        "Failed to fetch render options",
        "Failed to fetch render presets",
        "Failed to fetch render options",
        "Failed to fetch render presets",
        "Failed to fetch render options",
    ]
    var chunks: [[Record]] = []
    for (index, subject) in subjects.enumerated() {
        var chunk = [line("[\(timestampMillis())] \(red("ERROR")): \(cyan(subject))")]
        // Exactly one of the six carries the follow-up field, matching the
        // captured corpus. Its colon is flush against the token, which is the
        // only reason a lower-case token counts.
        if index == 0 {
            chunk.append(line("    error: \"fetch failed\""))
        }
        chunks.append(chunk)
    }
    return chunks
}

// MARK: - Emitter: postgres (token columns 35 and 36)
//
// `2026-08-15 03:37:38.423 UTC [80318] ERROR:  no partition of relation …`
// The two-space gap after the colon is postgres', not a typo. A failing INSERT
// is followed by DETAIL and a tab-indented STATEMENT, none of which is a claim
// on its own.

func postgresLine(_ resource: String, pid: Int, tag: String, text: String) -> Record {
    Record(
        resource: resource,
        message: "\(dateTimeMillis()) UTC [\(pid)] \(tag):  \(text)",
        spanID: "dc:\(resource)"
    )
}

func usagePostgresFailureChunk() -> [Record] {
    let pid = roll(80000...99999)
    let resource = "usage-postgres"
    return [
        postgresLine(
            resource, pid: pid, tag: "ERROR",
            text: "no partition of relation \"\(usageTable)\" found for row"
        ),
        postgresLine(
            resource, pid: pid, tag: "DETAIL",
            text: "Partition key of the failing row contains (sampled_at) = "
                + "(2026-08-15 \(String(format: "%02d:%02d:%02d", roll(0...23), roll(0...59), roll(0...59)))+00)."
        ),
        Record(resource: resource, message: "\t  INSERT INTO \(usageTable) (", spanID: "dc:\(resource)"),
        Record(resource: resource, message: "\t    sampled_at, org_slug, capability, worker, engine,", spanID: "dc:\(resource)"),
        Record(resource: resource, message: "\t    units_in, units_out, frames,", spanID: "dc:\(resource)"),
        Record(resource: resource, message: "\t    cost_cents, rate_card_rev,", spanID: "dc:\(resource)"),
        Record(resource: resource, message: "\t    elapsed_ms, failure_class, agent_version", spanID: "dc:\(resource)"),
        Record(resource: resource, message: "\t  )", spanID: "dc:\(resource)"),
        Record(resource: resource, message: "\t  VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)", spanID: "dc:\(resource)"),
    ]
}

func postgresHousekeepingChunk(_ resource: String) -> [Record] {
    let pid = roll(10...99)
    return [
        postgresLine(
            resource, pid: pid, tag: "LOG",
            text: "checkpoint complete: wrote \(roll(10...900)) buffers (\(roll(0...9)).\(roll(0...9))%); "
                + "0 WAL file(s) added, 0 removed, \(roll(0...3)) recycled; "
                + "write=\(roll(0...9)).\(roll(100...999)) s, sync=0.00\(roll(1...9)) s"
        )
    ]
}

// MARK: - Emitter: nginx
//
// An access log that is pure ordinary traffic, plus ONE `[error]` line at
// stripped column 21 -- lower case, bracketed, which is the other label form
// the case-insensitive token rule reads.

func nginxAccessChunk() -> [Record] {
    let route = pick(readRoutes + [
        "/assets/index-\(hex(8)).js",
        "/assets/logo.svg",
        "/api/v2/items/\(opaqueID("itm"))/revisions/\(opaqueID("rev"))",
        "/api/v2/notes/\(opaqueID("note"))/ack",
        "/api/v2/session/renew",
        "/api/v2/events/live?token=<REDACTED-TOKEN>&orgSlug=\(primaryOrg)",
    ])
    let status = pick([200, 200, 200, 304, 204])
    let referer = pick([
        "http://\(appHost)/",
        "http://\(appHost)/items/\(opaqueID("itm"))",
        "-",
    ])
    return [
        Record(
            resource: "nginx-edge",
            message: "\(bridgeIP) - - [15/Aug/2026:\(String(format: "%02d:%02d:%02d", roll(0...23), roll(0...59), roll(0...59))) +0000] "
                + "\"\(pick(["GET", "GET", "GET", "POST", "OPTIONS"])) \(route) HTTP/1.1\" \(status) \(roll(0...90000)) "
                + "\"\(referer)\" \"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36\"",
            spanID: "dc:nginx-edge"
        )
    ]
}

// MARK: - Emitter: the vite dev server (token columns 30, 34 and 42)
//
// Three failure shapes at three different columns, all lower case, all red, all
// genuine. Together with the nginx one they are the 21 lines that were reaching
// only `.warning` via `ansi.red` before the token rule started reading
// lower-case labels -- and column 42 is the measurement the 80-column window
// has its headroom over.

func vitePrefix(_ clock: String) -> String {
    "\(dim(clock)) \(esc)[31m\(esc)[1m[vite]\(esc)[22m\(esc)[39m"
}

func viteHealthyPrefix(_ clock: String) -> String {
    "\(dim(clock)) \(esc)[36m\(esc)[1m[vite]\(esc)[22m\(esc)[39m"
}

func viteHmrChunk(_ resource: String, span: String) -> [Record] {
    let file = pick([
        "/src/pages/ItemDetail.tsx",
        "/src/contexts/SessionContext.tsx",
        "/src/components/PresetPicker.tsx",
        "/src/api/items.ts",
    ])
    return [
        Record(
            resource: resource,
            message: "\(viteHealthyPrefix(clockAMPM())) \(esc)[90m\(esc)[2m(client)\(esc)[22m\(esc)[39m "
                + "\(sgr(32, "hmr update "))\(dim(file))",
            spanID: span
        )
    ]
}

func viteReadinessChunk() -> [Record] {
    let span = "dc:catalog-frontend"
    func line(_ text: String) -> Record {
        Record(resource: "catalog-frontend", message: text, spanID: span)
    }
    return [
        line("[readiness probe: success] <!doctype html>"),
        line("[readiness probe: success] <html lang=\"en\">"),
        line("[readiness probe: success]     <head>"),
        line("[readiness probe: success]         <title>Northwind</title>"),
        line("[readiness probe: success]         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\" />"),
        line("[readiness probe: success]     </head>"),
        line("[readiness probe: success]     <body>"),
        line("[readiness probe: success]         <div id=\"root\"></div>"),
        line("[readiness probe: success]     </body>"),
        line("[readiness probe: success] </html>"),
        line(""),
    ]
}

/// The esbuild frames that follow a vite `Internal server error`. Four-space
/// indented `at fn (file:line:col)` -- context for a failure, never a claim of
/// one, which is what `theRulesLeaveEveryStackFrameAlone` is about.
func esbuildFrames() -> [String] {
    let base = "\(repoRoot)/\(brand)-catalog-service/client/node_modules/esbuild/lib/main.js"
    return [
        "    at \(base):718:38",
        "    at responseCallbacks.<computed> (\(base):603:9)",
        "    at Socket.afterClose (\(base):594:28)",
        "    at Socket.emit (node:events:521:24)",
        "    at endReadableNT (node:internal/streams/readable:1735:12)",
        "    at process.processTicksAndRejections (node:internal/process/task_queues:90:21)",
    ]
}

/// The vite failure cascade: an esbuild restart takes the dev server down and
/// every in-flight transform reports it. 9 `Pre-transform error` + 7 `Internal
/// server error`, matching the captured corpus's split.
func viteFailureChunks() -> [[Record]] {
    let span = "dc:catalog-frontend"
    func line(_ text: String) -> Record {
        Record(resource: "catalog-frontend", message: text, spanID: span)
    }
    var chunks: [[Record]] = []

    // Eight `(client) Pre-transform error:` at stripped column 42 -- the
    // largest genuine token column in the corpus, and the one the 80-column
    // window's headroom is measured against.
    let clock = "12:57:46 PM"
    for index in 0..<8 {
        let detail = index == 7 ? "The service is no longer running: write EPIPE" : "The service was stopped"
        var chunk = [line(
            "\(vitePrefix(clock)) \(esc)[31m\(esc)[2m(client)\(esc)[22m\(esc)[39m Pre-transform error: \(detail)"
        )]
        if index == 2 {
            chunk.append(line(
                "  File: \(cyan("\(repoRoot)/\(brand)-catalog-service/client/src/items/detail/PresetPanel.tsx"))"
            ))
        }
        chunks.append(chunk)
    }

    // Seven `Internal server error:` at stripped column 34, the middle shape.
    // The first carries the esbuild stack that follows it in a real cascade.
    for index in 0..<7 {
        let detail = index < 3 ? "The service was stopped" : "The service is no longer running"
        var chunk = [line("\(vitePrefix("1:27:46 PM")) \(red("Internal server error: \(detail)"))")]
        if index == 0 {
            chunk += esbuildFrames().map(line)
        }
        chunks.append(chunk)
    }

    // And one `Pre-transform error:` without the `(client)` tag, at column 32.
    chunks.append([line("\(vitePrefix("1:31:35 PM")) Pre-transform error: The service is no longer running")])

    return chunks
}

/// The dev-server proxy giving up on a long-lived SSE connection. Column 30,
/// and the query string is where the capture script's JWT redaction earned its
/// keep -- reproduced here as a placeholder so the shape survives without any
/// token, real or synthetic, ever being written.
func viteProxyFailureChunks() -> [[Record]] {
    let span = "dc:portal-client"
    // A FIXED two-digit hour, not `clockAMPM()`: a one-digit hour shifts the
    // token one column left, and these three lines exist to pin a column.
    let clocks = ["10:21:53 AM", "10:21:57 AM", "10:22:01 AM"]
    return clocks.map { clock in
        [Record(
            resource: "portal-client",
            message: "\(vitePrefix(clock)) "
                + "\(red("http proxy error: /api/v2/events/live?token=<REDACTED-TOKEN>&orgSlug=\(primaryOrg)"))",
            spanID: span
        )]
    }
}

// MARK: - Emitter: Flask / werkzeug
//
// The five red `WARNING:` lines. Printed on every startup of every Flask
// resource, forever, and entirely benign -- which is the measured reason
// `ansi.red` may promote a row no further than `.warning`.

func flaskStartupChunk(_ resource: String, port: Int) -> [Record] {
    func line(_ text: String) -> Record {
        Record(resource: resource, message: text, spanID: "dc:\(resource)")
    }
    return [
        line(" * Serving Flask app 'app'"),
        line(" * Debug mode: off"),
        line("\(esc)[31m\(esc)[1mWARNING: This is a development server. Do not use it in a production "
            + "deployment. Use a production WSGI server instead.\(esc)[0m"),
        line(" * Running on all addresses (0.0.0.0)"),
        line(" * Running on http://127.0.0.1:\(port)"),
        line("Press CTRL+C to quit"),
    ]
}

func flaskAccessChunk(_ resource: String) -> [Record] {
    [Record(
        resource: resource,
        message: "127.0.0.1 - - [15/Aug/2026 \(String(format: "%02d:%02d:%02d", roll(0...23), roll(0...59), roll(0...59)))] "
            + "\"\(pick(["GET /health", "POST /invoke", "GET /ready"])) HTTP/1.1\" 200 -",
        spanID: "dc:\(resource)"
    )]
}

/// A Python worker's own dict repr, single-quoted -- the other quote style the
/// token rule has to treat as data, and one `'error': None` that names a field
/// rather than claiming one.
func pythonResultChunk(_ resource: String) -> [Record] {
    func line(_ text: String) -> Record {
        Record(resource: resource, message: text, spanID: "dc:\(resource)")
    }
    return [
        line("{'status': 'ok', 'error': None}"),
        line("  'frames': \(roll(1...400)),"),
        line("  'elapsed_ms': \(roll(20...9000)),"),
        line("  'warning': False,"),
        line("}"),
    ]
}

// MARK: - Emitter: CloudWatch EMF
//
// Compact one-line JSON that `JSONBlock.detect` collapses to a single block
// row, carrying a metric literally NAMED `ErrorCount` whose value is 0. This is
// the false-positive surface a naive substring rule detonates on, and the
// reason the fixture's precision half is worth as much as its recall half.

func emfChunk(_ resource: String, service: String, span: String) -> [Record] {
    let route = pick(readRoutes)
    let status = pick([200, 200, 304])
    let body = "{\"_aws\":{\"Timestamp\":\(roll(1786000000000...1786999999999)),"
        + "\"CloudWatchMetrics\":[{\"Namespace\":\"Northwind/HTTP\","
        + "\"Dimensions\":[[\"Service\",\"Environment\"]],"
        + "\"Metrics\":[{\"Name\":\"RequestDuration\",\"Unit\":\"Milliseconds\"},"
        + "{\"Name\":\"RequestCount\",\"Unit\":\"Count\"},"
        + "{\"Name\":\"ErrorCount\",\"Unit\":\"Count\"},"
        + "{\"Name\":\"ClientErrorCount\",\"Unit\":\"Count\"}]}]},"
        + "\"Service\":\"\(service)\",\"Environment\":\"development\","
        + "\"RequestDuration\":\(roll(1...4000)).\(roll(10...99)),\"RequestCount\":1,"
        + "\"ErrorCount\":0,\"ClientErrorCount\":0,"
        + "\"Route\":\"\(route)\",\"Method\":\"GET\",\"StatusCode\":\(status),"
        + "\"StatusClass\":\"\(status / 100)xx\",\"CorrelationId\":\"\(uuidish())\"}"
    return [Record(resource: resource, message: body, spanID: span)]
}

func meteringEMFChunk(_ resource: String, span: String) -> [Record] {
    let body = "{\"_aws\": {\"Timestamp\": \(roll(1786000000000...1786999999999)), "
        + "\"CloudWatchMetrics\": [{\"Namespace\": \"Northwind/Metering\", "
        + "\"Dimensions\": [[\"org_slug\"], [\"org_slug\", \"capability\"], [\"capability\"]], "
        + "\"Metrics\": [{\"Name\": \"frames\", \"Unit\": \"Count\"}, "
        + "{\"Name\": \"cost_cents\", \"Unit\": \"None\"}, "
        + "{\"Name\": \"elapsed_ms\", \"Unit\": \"Milliseconds\"}, "
        + "{\"Name\": \"event_count\", \"Unit\": \"Count\"}, "
        + "{\"Name\": \"error_count\", \"Unit\": \"Count\"}]}]}, "
        + "\"org_slug\": \"\(pick([primaryOrg, secondaryOrg, "unknown"]))\", "
        + "\"capability\": \"\(pick(["render.poster", "render.waveform", "ocr.page"]))\", "
        + "\"worker\": \"render_worker\", \"frames\": \(roll(1...40)), "
        + "\"cost_cents\": 0.\(roll(100...900)), \"elapsed_ms\": \(roll(100...9000)), "
        + "\"event_count\": 1, \"error_count\": 0}"
    return [Record(resource: resource, message: body, spanID: span)]
}

// MARK: - Emitter: the compact pino error record (`"level":50`)
//
// The only rows in the corpus that `json.level` claims, and the only ones
// reachable at all as a `.block`. Each carries:
//   * `"level":50`, which is what flags it;
//   * an inline `"err":{…}` object, so `json.err` is evaluated and correct on
//     it -- and never the rule NAMED, because a tie keeps the earlier rule;
//   * a `"stack"` string with `\n    at …` frames inside it, so the corpus has
//     a stack trace that is DATA inside a JSON value rather than its own lines;
//   * a `"severity":"ERROR"` far enough into the line that the token rule must
//     not reach it. Measured at stripped column 656 in the captured corpus and
//     reproduced past 600 here -- these are genuine errors flagged by their
//     `level` field, and the token rule reaching that far would also reach
//     every payload that merely quotes the word.

func meterFailureChunks() -> [[Record]] {
    let span = "dc:render-api"
    return (0..<3).map { _ in
        let stack = "error: no partition of relation \\\"\(usageTable)\\\" found for row"
            + "\\n    at /app/node_modules/pg-pool/index.js:45:11"
            + "\\n    at process.processTicksAndRejections (node:internal/process/task_queues:103:5)"
            + "\\n    at async writeSql (/app/node_modules/\(meterPackage)/dist/sinks/sql.js:15:5)"
            + "\\n    at async Promise.allSettled (index 0)"
            + "\\n    at async Object.emit (/app/node_modules/\(meterPackage)/dist/meter.js:58:25)"
        let body = "{\"level\":50,\"time\":\(roll(1786000000000...1786999999999)),"
            + "\"pid\":\(roll(100...900)),\"hostname\":\"\(hex(12))\",\"name\":\"\(meterPackage)\","
            + "\"err\":{\"type\":\"DatabaseError\","
            + "\"message\":\"no partition of relation \\\"\(usageTable)\\\" found for row\","
            + "\"stack\":\"\(stack)\",\"length\":239,\"name\":\"error\",\"severity\":\"ERROR\","
            + "\"code\":\"23514\",\"detail\":\"Partition key of the failing row contains (sampled_at) = "
            + "(2026-08-15 05:25:17.659+00).\",\"schema\":\"public\",\"table\":\"\(usageTable)\","
            + "\"file\":\"execPartition.c\",\"line\":\"328\",\"routine\":\"ExecFindPartition\"},"
            + "\"event\":{\"sampled_at\":\"2026-08-15T05:25:17.659Z\",\"org_slug\":\"\(primaryOrg)\","
            + "\"capability\":\"render.poster\",\"worker\":\"render_worker\",\"engine\":\"ffmpeg\","
            + "\"subject_id\":null,\"item_id\":null,\"request_id\":\"\(uuidish())\","
            + "\"units_in\":\(roll(100...900)),\"units_out\":\(roll(100...900)),\"frames\":null,"
            + "\"cost_cents\":0,\"rate_card_rev\":\"fallback\",\"elapsed_ms\":\(roll(1000...20000)),"
            + "\"failure_class\":null,\"agent_version\":\"0.1.0\"},\"sink_index\":0,"
            + "\"msg\":\"meter sink write failed; reconciliation will repair\"}"
        return [Record(resource: "render-api", message: body, spanID: span)]
    }
}

/// A Node rejection logged at INFO by its own handler, followed by frames.
/// Nothing in it is a severity CLAIM -- there is no token, no red, no level
/// field -- so the whole chunk must stay untinted. That is the shape the
/// anchored `at fn (file:line:col)` count is measured over.
func nodeStackChunk(_ resource: String, service: String) -> [Record] {
    let span = "dc:\(resource)"
    func line(_ text: String) -> Record { Record(resource: resource, message: text, spanID: span) }
    return [
        line(pinoHeader(service, "INFO", "unhandled rejection captured by the process handler")),
        line("    at onResFinished (/app/node_modules/pino-http/logger.js:115:39)"),
        line("    at async Object.insertUsageEvents (/app/node_modules/pg-pool/index.js:45:11)"),
        line("    at async writeSql (/app/src/sinks/sql.js:15:5)"),
        line("    at Socket.emit (node:events:521:24)"),
        line("    at TCP.onStreamRead (node:internal/stream_base_commons:216:20)"),
        line("    at process.processTicksAndRejections (node:internal/process/task_queues:90:21)"),
    ]
}

/// A Python traceback, the third frame dialect the corpus carries. `File "…",
/// line N, in fn` is not an `at` frame and is not a token either.
func pythonTracebackChunk(_ resource: String) -> [Record] {
    let span = "dc:\(resource)"
    func line(_ text: String) -> Record { Record(resource: resource, message: text, spanID: span) }
    return [
        line("Traceback (most recent call last):"),
        line("  File \"/app/handler.py\", line \(roll(20...200)), in process"),
        line("    result = render(job)"),
        line("  File \"/app/render.py\", line \(roll(20...200)), in render"),
        line("    return backend.encode(job.frames)"),
        line("TimeoutError: encode did not complete within 30s"),
    ]
}

// MARK: - Emitter: Java / jetty (token column 19)

func jettyChunk(_ resource: String) -> [Record] {
    func line(_ text: String) -> Record {
        Record(resource: resource, message: text, spanID: "dc:\(resource)")
    }
    let thread = "[qtp\(roll(1000000000...1999999999))-\(roll(20...40))]"
    return [
        line("\(thread) INFO \(javaPackage).LocalServer - [INFO] Field extractor response: {"),
        line("      {"),
        line("        \"id\": \"db_asset_title\","),
        line("        \"type\": \"select\","),
        line("        \"value\": \"\""),
        line("      },"),
        line("      {"),
        line("        \"id\": \"db_review_flag\","),
        line("        \"type\": \"checkbox\""),
        line("      }"),
        line("}"),
    ]
}

/// The one jetty WARN, at stripped column 19. Not a failure -- a fallback --
/// which is why the token rule must stop at `.warning` for it.
func jettyWarningChunk() -> [Record] {
    [Record(
        resource: "label-form-fields",
        message: "[qtp\(roll(1000000000...1999999999))-\(roll(20...40))] WARN \(javaPackage).FieldsHandler - "
            + "⚠️ File not found at /app/datastores/shared/templates/label-latest.pdf, falling back to bundled template",
        spanID: "dc:label-form-fields"
    )]
}

/// A tab-indented Java stack trace, and the corpus's largest single run of
/// frames. Its own emitter graded the underlying exception INFO; the frames
/// carry no claim at all, and none of them may be tinted.
func jettyStackChunk() -> [Record] {
    let resource = "label-generate"
    func line(_ text: String) -> Record {
        Record(resource: resource, message: text, spanID: "dc:\(resource)")
    }
    var out = [line("javax.crypto.BadPaddingException: Given final block not properly padded")]
    out += [
        "\tat java.base/com.sun.crypto.provider.CipherCore.unpad(Unknown Source)",
        "\tat java.base/com.sun.crypto.provider.CipherCore.doFinal(Unknown Source)",
        "\tat java.base/javax.crypto.Cipher.doFinal(Unknown Source)",
        "\tat org.example.pdf.kernel.crypto.AesDecryptor.finish(AesDecryptor.java:64)",
        "\tat org.example.pdf.kernel.pdf.PdfString.decodeContent(PdfString.java:269)",
        "\tat org.example.pdf.kernel.pdf.PdfOutputStream.write(PdfOutputStream.java:222)",
        "\tat org.example.pdf.kernel.pdf.PdfWriter.flushObject(PdfWriter.java:253)",
        "\tat org.example.pdf.kernel.pdf.PdfDocument.close(PdfDocument.java:1079)",
        "\tat \(javaPackage).GenerateHandler.fillTemplate(GenerateHandler.java:369)",
        "\tat \(javaPackage).GenerateHandler.handleRequest(GenerateHandler.java:126)",
        "\tat \(javaPackage).LocalServer$InvokeServlet.doPost(LocalServer.java:73)",
        "\tat jakarta.servlet.http.HttpServlet.service(HttpServlet.java:520)",
        "\tat org.eclipse.jetty.servlet.ServletHolder.handle(ServletHolder.java:764)",
        "\tat org.eclipse.jetty.servlet.ServletHandler.doHandle(ServletHandler.java:529)",
        "\tat org.eclipse.jetty.server.handler.ScopedHandler.nextHandle(ScopedHandler.java:221)",
        "\tat org.eclipse.jetty.server.session.SessionHandler.doHandle(SessionHandler.java:1580)",
        "\tat org.eclipse.jetty.server.handler.ContextHandler.doHandle(ContextHandler.java:1381)",
        "\tat org.eclipse.jetty.server.handler.ScopedHandler.nextScope(ScopedHandler.java:176)",
        "\tat org.eclipse.jetty.server.Server.handle(Server.java:563)",
        "\tat org.eclipse.jetty.server.HttpChannel.handle(HttpChannel.java:501)",
        "\tat org.eclipse.jetty.server.HttpConnection.onFillable(HttpConnection.java:287)",
        "\tat org.eclipse.jetty.io.FillInterest.fillable(FillInterest.java:100)",
        "\tat org.eclipse.jetty.util.thread.QueuedThreadPool.runJob(QueuedThreadPool.java:969)",
        "\tat org.eclipse.jetty.util.thread.QueuedThreadPool$Runner.run(QueuedThreadPool.java:1149)",
        "\tat java.base/java.lang.Thread.run(Unknown Source)",
    ].map(line)
    return out
}

// MARK: - Emitter: Go / zap (token column 24)
//
// Tab-separated, and its WARN is a cron job noting a missing optional index.

func zapWarningChunk() -> [Record] {
    [Record(
        resource: "gateway-ui",
        message: "\(dateTimeMillis())\tWARN\tgithub.com/example/gateway-ui/internal/cron/reindex.go:41"
            + "\tLog file manager not available for incremental index",
        spanID: "dc:gateway-ui"
    )]
}

func zapInfoChunk() -> [Record] {
    [Record(
        resource: "gateway-ui",
        message: "\(dateTimeMillis())\tINFO\tgithub.com/example/gateway-ui/internal/cron/reindex.go:\(roll(20...90))"
            + "\t\(pick(["Starting incremental index", "Index complete", "Cron scheduler started"]))",
        spanID: "dc:gateway-ui"
    )]
}

// MARK: - Emitter: nginx's own error log (token column 21)

func nginxErrorChunk() -> [Record] {
    [Record(
        resource: "nginx-edge",
        message: "2026/08/15 05:32:58 [error] 23#23: *21841 upstream prematurely closed connection "
            + "while reading upstream, client: \(bridgeIP), server: \(wildcardHost), "
            + "request: \"GET /api/v2/events/live HTTP/1.1\", upstream: \"http://172.28.0.9:8080/api/v2/events/live\", "
            + "host: \"\(appHost)\"",
        spanID: "dc:nginx-edge"
    )]
}

// MARK: - Emitter: tilt's own unattributed lines
//
// Empty `resource` AND empty `spanID`. Real tilt emits its global system lines
// this way, so `theCorpusKeepsTiltsOwnFieldsIntact` deliberately does NOT
// require every record to name a resource -- that would be asserting something
// false about tilt.

func dockerPruneChunks() -> [[Record]] {
    let bodies = [
        "[Docker Prune] removed 55 caches, reclaimed 1.396GB",
        "[Docker Prune] removed 4 caches, reclaimed 48.04MB",
        "[Docker Prune] removed 16 images, reclaimed 10.01GB",
        "[Docker Prune] removed 14 images, reclaimed 7.194GB",
        "[Docker Prune] removed 2 images, reclaimed 462.1MB",
    ]
    return bodies.map { [Record(resource: "", message: $0, spanID: "")] }
}

// MARK: - Emitter: the Tiltfile's own banner

func tiltfileChunks() -> [[Record]] {
    func line(_ text: String) -> Record {
        Record(resource: "(Tiltfile)", message: text, spanID: "", source: "build")
    }
    let banner = [
        "Loading Tiltfile at: \(repoRoot)/Tiltfile",
        "✅ Northwind Development Environment Started!",
        "",
        "🌐 Web:",
        "   • App: http://\(appHost)",
        "   • Admin: http://\(adminHost)",
        "   • Studio: http://\(studioHost)  (org \(studioOrg))",
        "   • API: http://\(apiHost)",
        "",
        "🤖 Render service:",
        "   • Poster frames: http://localhost:3401/invoke",
        "   • Contact sheets: http://localhost:3400/invoke",
        "   • Waveforms: http://localhost:3200/invoke",
        "",
        "💾 Databases (each service has its own):",
        "   • Each service uses its own local-compose.yml",
        "",
        "💡 Tips:",
        "   • `tilt trigger <resource>` re-runs one resource",
        "   • Logs stream to the pane on the right",
        "",
    ]
    return banner.map { [line($0)] }
}

// MARK: - Emitter: assorted small resources

func redisChunk(_ resource: String) -> [Record] {
    [Record(
        resource: resource,
        message: "1:M \(roll(10...28)) Aug 2026 \(timestampMillis()) * "
            + pick([
                "Background saving terminated with success",
                "DB saved on disk",
                "Background saving started by pid \(roll(10...99))",
            ]),
        spanID: "dc:\(resource)"
    )]
}

func buildStepChunk(_ resource: String) -> [Record] {
    let step = roll(1...4)
    return [Record(
        resource: resource,
        message: "\(blue("STEP \(step)/4"))\(esc)[0m — "
            + pick(["Building", "Pushing", "Deploying", "Waiting for readiness"]),
        spanID: "cmd:\(resource):update",
        source: "build"
    )]
}

func tailerChunk() -> [Record] {
    [Record(
        resource: "metrics-collector",
        message: "[tailer] Attached to container: \(pick([catalogService, accountService, renderService])) (\(hex(12)))",
        spanID: "dc:metrics-collector"
    )]
}

func triggerChunk() -> [Record] {
    let span = "dc:account-metrics-trigger"
    let job = pick(["usage-rollup", "activity-snapshot"])
    func line(_ text: String) -> Record {
        Record(resource: "account-metrics-trigger", message: text, spanID: span)
    }
    return [
        line("[\(String(format: "%02d:%02d:%02d", roll(0...23), roll(0...59), roll(0...59)))] Triggering \(job)..."),
        line("{"),
        line("  \"status\": \"success\","),
        line("  \"message\": \"Job \(job) triggered successfully\","),
        line("  \"data\": {"),
        line("    \"jobName\": \"\(job)\","),
        line("    \"triggeredAt\": \"2026-08-15T\(String(format: "%02d:%02d:%02d", roll(0...23), roll(0...59), roll(0...59))).427Z\""),
        line("  }"),
        line("}"),
    ]
}

func genericServiceChunk(_ resource: String, service: String) -> [Record] {
    let span = "dc:\(resource)"
    func line(_ text: String) -> Record { Record(resource: resource, message: text, spanID: span) }
    let route = pick(readRoutes + renderRoutes)
    return [
        line(pinoHeader(service, "INFO", "\(uuidish()) GET \(route) completed in \(roll(1...300))ms")),
        line(pinoField("orgSlug", "\"\(pick([primaryOrg, secondaryOrg]))\"")),
        line(pinoField("correlationId", "\"\(uuidish())\"")),
        line(pinoField("cacheHit", pick(["true", "false"]))),
    ]
}

/// A long array of opaque session ids -- the shape that made up most of the
/// captured corpus's two biggest resources. Nothing here is a signal; it is
/// bulk, and bulk is what makes a false positive visible.
func sessionListChunk(_ resource: String) -> [Record] {
    let span = "dc:\(resource)"
    func line(_ text: String) -> Record { Record(resource: resource, message: text, spanID: span) }
    var out = [line(pinoHeader(accountService, "DEBUG", "Active session scan")), line("    sessionIds: [")]
    for _ in 0..<roll(6...14) {
        out.append(line("      \"sess-\(hex(6))-\(hex(9))\","))
    }
    out.append(line("      \"sess-\(hex(6))-\(hex(9))\""))
    out.append(line("    ]"))
    out.append(line(pinoField("count", "\(roll(4...20))")))
    return out
}

// MARK: - Build the corpus
//
// Line budgets mirror the captured corpus's traffic mix: two chatty pino
// backends dominate, everything else is a long tail. The signal-bearing scenes
// are emitted at fixed counts because the tests enumerate them.

// --- The bulk.
emit("catalog-backend", lines: 1_045) { catalogBackendChunk() }
emit("portal-bff", lines: 620) { sessionListChunk("portal-bff") }
emit("session-service", lines: 340) { sessionListChunk("session-service") }
emit("console-bff", lines: 150) {
    switch roll(0...4) {
    case 0, 1, 3: emfChunk("console-bff", service: consoleService, span: "dc:console-bff")
    case 2: nodeStackChunk("console-bff", service: consoleService)
    default: genericServiceChunk("console-bff", service: consoleService)
    }
}
emit("account-service", lines: 130) {
    switch roll(0...4) {
    case 0, 1, 3: emfChunk("account-service", service: accountService, span: "dc:account-service")
    case 2: nodeStackChunk("account-service", service: accountService)
    default: genericServiceChunk("account-service", service: accountService)
    }
}
emit("account-metrics-trigger", lines: 90) { triggerChunk() }
emit("nginx-edge", lines: 86) { nginxAccessChunk() }
emit("console-client", lines: 110) { viteHmrChunk("console-client", span: "dc:console-client") }
emit("catalog-frontend", lines: 60) { viteReadinessChunk() }
emit("label-generate", lines: 50) { jettyStackChunk() }
emit("render-api", lines: 50) {
    roll(0...1) == 0
        ? meteringEMFChunk("render-api", span: "dc:render-api")
        : genericServiceChunk("render-api", service: renderService)
}
emit("label-form-fields", lines: 30) { jettyChunk("label-form-fields") }
emit("schema-lambda", lines: 32) { flaskAccessChunk("schema-lambda") }
emit("datasource-server", lines: 30) { genericServiceChunk("datasource-server", service: catalogService) }
emit("ocr-worker", lines: 26) {
    roll(0...2) == 0 ? pythonTracebackChunk("ocr-worker") : pythonResultChunk("ocr-worker")
}
emit("poster-worker", lines: 24) { pythonResultChunk("poster-worker") }
// The corpus's densest ANSI source: every one of these six lines is coloured,
// which is what keeps the escape count near the captured corpus's 348.
emit("studio-api", lines: 168) { studioAPIOrdinaryChunk() }
emit("northwind-sdk", lines: 22) { buildStepChunk("northwind-sdk") }
emit("console-shared-build", lines: 18) { buildStepChunk("console-shared-build") }
emit("thumb-worker", lines: 16) { flaskAccessChunk("thumb-worker") }
emit("metrics-collector", lines: 16) { tailerChunk() }
emit("gateway-ui", lines: 12) { zapInfoChunk() }
emit("audit-api", lines: 10) { genericServiceChunk("audit-api", service: consoleService) }
emit("queue-redis", lines: 10) { redisChunk("queue-redis") }
emit("catalog-postgres", lines: 6) { postgresHousekeepingChunk("catalog-postgres") }
emit("render-redis", lines: 8) { redisChunk("render-redis") }
emit("catalog-shared-build", lines: 5) { buildStepChunk("catalog-shared-build") }
emit("usage-postgres-quiet", lines: 4) { postgresHousekeepingChunk("usage-postgres") }
emit("session-postgres-quiet", lines: 3) { postgresHousekeepingChunk("session-postgres") }
emit("studio-postgres", lines: 3) { postgresHousekeepingChunk("studio-postgres") }
emit("account-dynamodb", lines: 2) {
    [Record(resource: "account-dynamodb", message: "InMemory:\tfalse", spanID: "dc:account-dynamodb")]
}
emit("flow-builder", lines: 2) {
    [Record(resource: "flow-builder", message: "  ➜  Local:   http://localhost:3800/", spanID: "dc:flow-builder")]
}
emit("studio-client", lines: 2) { viteHmrChunk("studio-client", span: "dc:studio-client") }
emit("catalog-pgadmin", lines: 1) {
    [Record(
        resource: "catalog-pgadmin",
        message: "postfix/postlog: starting the Postfix mail system",
        spanID: "dc:catalog-pgadmin"
    )]
}

// --- Flask startup boilerplate: five resources, five red WARNING lines.
for (index, worker) in ["image-worker", "clip-worker", "doc-worker", "intake-worker", "audio-worker"].enumerated() {
    emitFixed(worker, [flaskStartupChunk(worker, port: 3300 + index)])
}

// --- The signal-bearing scenes, at the counts the tests enumerate.
emitFixed("studio-api-failures", studioAPIFailureChunks())
emitFixed("catalog-frontend-failures", viteFailureChunks())
emitFixed("portal-client-failures", viteProxyFailureChunks())
emitFixed("nginx-edge-failure", [nginxErrorChunk()])
emitFixed("render-api-failures", meterFailureChunks())
emitFixed("usage-postgres-failures", (0..<13).map { _ in usagePostgresFailureChunk() })
emitFixed("catalog-postgres-failures", [
    [postgresLine(
        "catalog-postgres", pid: roll(4000...4999), tag: "ERROR",
        text: "column \"positions\" does not exist at character 16"
    )],
    [postgresLine(
        "catalog-postgres", pid: roll(4000...4999), tag: "ERROR",
        text: "column \"position\" does not exist at character 25"
    )],
])
// A five-digit pid, deliberately: postgres' token column is 35 with a
// four-digit pid and 36 with a five-digit one, and the corpus needs both.
emitFixed("session-postgres-failure", [
    [postgresLine("session-postgres", pid: roll(90000...99999), tag: "FATAL", text: "connection to client lost")]
])
emitFixed("jetty-warning", [jettyWarningChunk()])
emitFixed("zap-warnings", (0..<3).map { _ in zapWarningChunk() })
emitFixed("pino-warning", [[Record(
    resource: "catalog-backend",
    message: pinoHeader(catalogService, "WARN", "Skipping unknown feature key from control plane"),
    spanID: "dc:catalog-backend"
)]])
emitFixed("docker-prune", dockerPruneChunks())
emitFixed("tiltfile", tiltfileChunks())

// MARK: - Interleave
//
// A real `tilt logs` dump is many resources talking at once, and the capture
// script's stride sampling shuffled them further -- so a corpus emitted one
// resource at a time would not exercise `JSONBlock.detect`'s grouping the way
// the pane does. Chunks are spread across the file by position-within-stream,
// which keeps each stream's own order and each chunk's contiguity while
// interleaving the streams.

struct Placement {
    var key: Int
    var streamIndex: Int
    var chunkIndex: Int
}

var placements: [Placement] = []
for (streamIndex, stream) in streams.enumerated() {
    let total = stream.chunks.count
    for chunkIndex in 0..<total {
        // Position within this stream, scaled to a common 0...1_000_000 axis,
        // plus a small seeded jitter so the result does not read as a perfect
        // round robin. Integer arithmetic throughout: deterministic on every
        // platform, unlike a float sort key.
        let base = (chunkIndex + 1) * 1_000_000 / total
        placements.append(Placement(
            key: base + roll(-2500...2500), streamIndex: streamIndex, chunkIndex: chunkIndex
        ))
    }
}

// Every tie-breaker is explicit because Swift's sort is not stable.
placements.sort {
    if $0.key != $1.key { return $0.key < $1.key }
    if $0.streamIndex != $1.streamIndex { return $0.streamIndex < $1.streamIndex }
    return $0.chunkIndex < $1.chunkIndex
}

var out: [String] = []
for placement in placements {
    for record in streams[placement.streamIndex].chunks[placement.chunkIndex] {
        out.append(encode(record))
    }
}

// MARK: - Write

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Tests/FulcrumKitTests/Fixtures/log-corpus.jsonl"

// LF only, and a trailing newline, matching what tilt writes.
let text = out.joined(separator: "\n") + "\n"
do {
    try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("failed to write \(outputPath): \(error)\n".utf8))
    exit(1)
}

print("wrote \(out.count) lines to \(outputPath)")
