import Foundation

/// A discovered tilt instance.
public struct TiltInstance: Sendable, Identifiable, Equatable {
    /// Identity is `(server, token)`, not port. tilt regenerates both on every
    /// start, so a restart on the same port is a genuinely new instance.
    public struct InstanceID: Hashable, Sendable {
        let server: URL
        let token: String
    }

    public let id: InstanceID
    public let webPort: Int
    public let server: URL
    public let certificateAuthorityPEM: Data
    public let token: String

    /// The tilt web UI, which lives on the port encoded in the context name.
    public var webURL: URL {
        URL(string: "http://localhost:\(webPort)")!
    }

    public init(entry: Kubeconfig.Entry) {
        self.id = InstanceID(server: entry.server, token: entry.token)
        self.webPort = entry.port
        self.server = entry.server
        self.certificateAuthorityPEM = entry.certificateAuthorityPEM
        self.token = entry.token
    }
}
