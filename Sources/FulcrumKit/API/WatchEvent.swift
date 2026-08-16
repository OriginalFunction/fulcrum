import Foundation

/// One line of a Kubernetes-style watch stream.
public struct WatchEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case added = "ADDED"
        case modified = "MODIFIED"
        case deleted = "DELETED"
        case bookmark = "BOOKMARK"
        case error = "ERROR"
    }

    public var type: Kind
    public var object: UIResource
}
