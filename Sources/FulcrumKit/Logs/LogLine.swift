import Foundation

/// One line from tilt's log stream (`/api/log/stream`, or `tilt logs`),
/// decoded from its JSON shape.
///
/// Verified against live tilt v0.36.3:
/// `{"time":"2026-08-11T18:27:47+08:00","resource":"server","level":"info",
///  "message":"tick","spanID":"localserve:1","progressID":"","buildEvent":"",
///  "source":"runtime"}`. `progressID` and `buildEvent` are decoded off but
/// not surfaced here — nothing in the log pane currently needs them.
public struct LogLine: Sendable, Equatable, Hashable {
    public let time: Date
    public let resource: String
    public let level: LogLevel
    public let source: LogSource
    public let message: String
    public let spanID: String

    public init(time: Date, resource: String, level: LogLevel, source: LogSource, message: String, spanID: String) {
        self.time = time
        self.resource = resource
        self.level = level
        self.source = source
        self.message = message
        self.spanID = spanID
    }
}

extension LogLine {
    /// Whether `other` came from the same emitting stream as this line —
    /// same `resource` AND same `spanID`.
    ///
    /// THE boundary for every construct that spans more than one line, and
    /// deliberately one definition rather than one per construct:
    /// `JSONBlock.detect` uses it to stop a block absorbing an interleaved
    /// line, and `LogRecord.group` uses it to stop a record doing the same.
    /// tilt's log stream is globally interleaved, so consecutive lines
    /// routinely come from different resources — 3 blocks swallowed 23
    /// foreign lines in the measured sample before this existed.
    ///
    /// `spanID` is strictly finer than `resource` (37 resources in the
    /// sample carried more than one span, and 88 adjacent line pairs
    /// switched span without switching resource), but 26 lines carry an
    /// EMPTY `spanID`, so `resource` stays as the backstop. See
    /// `JSONBlock.detect(in:)`'s doc comment for the full derivation.
    func isSameStream(as other: LogLine) -> Bool {
        resource == other.resource && spanID == other.spanID
    }
}

extension LogLine: Decodable {
    private enum CodingKeys: String, CodingKey {
        case time, resource, level, source, message, spanID
    }

    /// tilt's log timestamps are RFC3339 with NO fractional seconds and a
    /// real zone offset (`2026-08-11T18:27:47+08:00`) — the user's local
    /// zone, not UTC. This is a DIFFERENT shape from the apiserver's
    /// timestamps (`...:40.168097Z`, six fractional digits, always `Z`; see
    /// `Resource.timestampParser`). A parser configured for one returns nil
    /// on the other, so this format needs its own `static let` rather than
    /// reusing `Resource`'s.
    ///
    /// `ISO8601FormatStyle` rather than `ISO8601DateFormatter` because it is
    /// a value type and genuinely `Sendable`, so this needs no concurrency
    /// escape hatch to live as a `static let`.
    private static let timestampParser = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let timeText = try container.decode(String.self, forKey: .time)
        guard let time = try? Self.timestampParser.parse(timeText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .time, in: container,
                debugDescription: "Unrecognised log timestamp format: \(timeText)"
            )
        }
        self.time = time

        self.resource = try container.decode(String.self, forKey: .resource)
        self.level = try container.decode(LogLevel.self, forKey: .level)
        self.source = try container.decode(LogSource.self, forKey: .source)
        self.message = try container.decode(String.self, forKey: .message)
        self.spanID = try container.decode(String.self, forKey: .spanID)
    }
}

/// A log line's severity, as tilt's `--level` flag reports it.
///
/// A 24,128-line sample carried only `level: "info"`, but the CLI's
/// `--level` flag already accepts `warn` and `error` — the closed set is
/// deliberately NOT inferred from that sample. `.other` keeps a level a
/// future tilt release introduces from silently dropping the line.
public enum LogLevel: RawRepresentable, Sendable, Equatable, Hashable {
    case info
    case warn
    case error
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "info": self = .info
        case "warn": self = .warn
        case "error": self = .error
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .info: "info"
        case .warn: "warn"
        case .error: "error"
        case .other(let value): value
        }
    }
}

extension LogLevel: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// Which channel a log line came from, as tilt reports it.
///
/// Observed values: `build`, `runtime`, and `""` for tilt-level messages not
/// attached to any resource build or runtime. `.other` keeps an unrecognised
/// future value from silently dropping the line, same rationale as `LogLevel`.
public enum LogSource: RawRepresentable, Sendable, Equatable, Hashable {
    case build
    case runtime
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "build": self = .build
        case "runtime": self = .runtime
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .build: "build"
        case .runtime: "runtime"
        case .other(let value): value
        }
    }
}

extension LogSource: Decodable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}
