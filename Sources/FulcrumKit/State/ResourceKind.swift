import Foundation

/// What kind of thing a tilt resource is, for the table's Type column.
///
/// tilt reports this as `status.specs[].type` — a short lowercase token. The
/// mapping is deliberately total: an unrecognised token becomes `.unknown`
/// rather than failing, because tilt can add spec types in a release and a
/// dashboard that refuses to draw is worse than one that shows a dash.
public enum ResourceKind: String, Sendable, CaseIterable {
    case local
    case kubernetes
    case dockerCompose
    case image
    /// The `(Tiltfile)` pseudo-resource, which carries no `specs` at all.
    case tiltfile
    case unknown

    public init(specType: String?) {
        switch specType {
        case "local": self = .local
        case "k8s": self = .kubernetes
        case "dc": self = .dockerCompose
        case "image": self = .image
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .local: "local"
        case .kubernetes: "k8s"
        case .dockerCompose: "compose"
        case .image: "image"
        case .tiltfile: "Tiltfile"
        case .unknown: "—"
        }
    }
}
