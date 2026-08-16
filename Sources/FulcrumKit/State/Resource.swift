import Foundation

/// A tilt resource as Fulcrum displays it.
public struct Resource: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let health: ResourceHealth
    public let order: Int
    public let isDisabled: Bool
    public let kind: ResourceKind
    /// Wall time of the most recent build, or nil if it has never built.
    public let lastBuildDuration: TimeInterval?
    /// The most recent build's failure message, if it failed.
    public let buildError: String?
    /// The resource's group, taken from its single `metadata.labels` entry.
    /// tilt's observed shape is exactly one label whose key equals its
    /// value; `nil` when no labels are present at all.
    public let group: String?
    /// Names of the resources this one is waiting on before it can build.
    /// Empty when the resource is not currently blocked.
    public let waitingOn: [String]
    /// Why this resource is blocked, e.g. `"waiting-for-dep"`. `nil` when
    /// not blocked.
    public let waitingReason: String?
    /// Endpoint URLs tilt reports for this resource. Entries tilt sends that
    /// fail to parse as a `URL` are dropped rather than failing the whole
    /// resource.
    public let endpoints: [URL]

    /// The instant this resource most recently became ready, or `nil` when
    /// there is nothing currently up for the uptime column to show.
    ///
    /// Derived from the `Ready` condition, not `UpToDate` — a successful
    /// rebuild commonly re-stamps both at the same instant, but `UpToDate`
    /// describes the build finishing, not the resource actually running.
    /// `nil` in three cases: `runtimeStatus == "not_applicable"` (one-shot
    /// `local_resource` commands and `(Tiltfile)` itself have no runtime to
    /// be up), no `Ready` condition has been reported yet, or `Ready` is
    /// currently `"False"` — the last of which must not fall back to "since
    /// it last succeeded".
    public let readySince: Date?

    /// tilt writes RFC3339 with six fractional digits (`...:40.168097Z`).
    /// Parsing must be told to expect them — a parser that ignores fractional
    /// seconds returns nil on every one of these, and every duration in the
    /// table would silently read "never built".
    ///
    /// `ISO8601FormatStyle` rather than `ISO8601DateFormatter` because it is a
    /// value type and genuinely `Sendable`, so this needs no concurrency
    /// escape hatch to live as a `static let`.
    private static let timestampParser = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The name tilt gives its own pseudo-resource, which carries no `specs`.
    static let tiltfileName = "(Tiltfile)"

    public init(uiResource: UIResource) {
        let status = uiResource.status
        let disabled = status?.disableStatus?.state == "Disabled"
        let name = uiResource.metadata.name

        self.name = name
        self.isDisabled = disabled
        self.order = status?.order ?? .max
        self.health = ResourceHealth.derive(
            update: status?.updateStatus,
            runtime: status?.runtimeStatus,
            isDisabled: disabled
        )

        self.kind = name == Self.tiltfileName
            ? .tiltfile
            : ResourceKind(specType: status?.specs?.first?.type)

        let lastBuild = status?.buildHistory?.first
        self.buildError = lastBuild?.error
        self.lastBuildDuration = Self.duration(of: lastBuild)

        // Sorted so a hypothetical future multi-label resource resolves
        // deterministically rather than depending on dictionary order; every
        // resource observed so far carries exactly one label.
        self.group = uiResource.metadata.labels?.keys.sorted().first

        self.waitingOn = status?.waiting?.on?.compactMap(\.name) ?? []
        self.waitingReason = status?.waiting?.reason

        // `URL(string:)` alone is too permissive: it happily percent-encodes
        // "not a url" into a scheme-less relative URL instead of failing.
        // Requiring a scheme rejects that while still accepting every real
        // endpoint link, which is always absolute (`http://...`).
        self.endpoints = status?.endpointLinks?.compactMap { link -> URL? in
            guard let text = link.url, let url = URL(string: text), url.scheme != nil else { return nil }
            return url
        } ?? []

        self.readySince = Self.readySince(status: status)
    }

    /// The resource table's status chip label. Unlike `SidebarItem.statusLabel`,
    /// `health` here is never absent — a `Resource` only exists once tilt has
    /// reported on it — so this is a direct pass-through describing this one
    /// resource's own health.
    public var statusLabel: String { health.label }

    /// The Last build column's text.
    ///
    /// Lives here rather than in the view because it is logic with edge cases
    /// worth testing, and `FulcrumKit` is where testable things go. Sub-second
    /// builds are common for local resources, so short durations keep a decimal
    /// place instead of every quick build reading "0s".
    public var lastBuildText: String {
        guard let lastBuildDuration else { return "—" }
        if lastBuildDuration < 10 { return String(format: "%.1fs", lastBuildDuration) }
        if lastBuildDuration < 60 { return String(format: "%.0fs", lastBuildDuration) }
        let minutes = Int(lastBuildDuration) / 60
        let seconds = Int(lastBuildDuration) % 60
        return "\(minutes)m \(seconds)s"
    }

    private static func readySince(status: UIResource.Status?) -> Date? {
        guard status?.runtimeStatus != "not_applicable" else { return nil }
        guard let ready = status?.conditions?.first(where: { $0.type == "Ready" }),
              ready.status == "True",
              let time = ready.lastTransitionTime
        else { return nil }
        return try? timestampParser.parse(time)
    }

    private static func duration(of build: UIResource.BuildRecord?) -> TimeInterval? {
        guard let build,
              let startText = build.startTime, let finishText = build.finishTime,
              let start = try? timestampParser.parse(startText),
              let finish = try? timestampParser.parse(finishText)
        else { return nil }
        return finish.timeIntervalSince(start)
    }
}
