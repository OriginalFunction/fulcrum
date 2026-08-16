import Foundation
import Yams

/// A parsed kubeconfig, filtered to the entries tilt writes.
///
/// tilt registers one cluster/context/user triple per running instance. The
/// `server` URL points at the apiserver on a *different*, randomly chosen port —
/// the context name is the only place the web port appears, in one of two shapes:
///
/// - `tilt-<webPort>` when the instance was started with an explicit `--port`.
/// - `tilt-default` when it was not, which is the ordinary `tilt up`. The web
///   port is then the documented `--port` default, 10350.
public struct Kubeconfig: Sendable {
    public struct Entry: Sendable, Equatable {
        /// Context name, e.g. `tilt-10360`.
        public let name: String
        /// The tilt web UI port, parsed from `name`.
        public let port: Int
        /// The apiserver URL, on its own random port.
        public let server: URL
        /// PEM bundle, decoded from `certificate-authority-data`.
        public let certificateAuthorityPEM: Data
        /// Bearer token for this instance.
        public let token: String
    }

    public let tiltEntries: [Entry]

    public enum ParseError: Error, Equatable {
        case malformedYAML
    }

    private static let contextPrefix = "tilt-"

    /// tilt's own `--port` default. Only one instance can occupy it — tilt exits
    /// with "you already have another process on port 10350" rather than falling
    /// back to another port — so `tilt-default` always denotes exactly this port.
    private static let defaultWebPort = 10350

    /// The web port a context name denotes, or nil if the name encodes none.
    private static func webPort(forContextNamed name: String) -> Int? {
        guard name.hasPrefix(contextPrefix) else { return nil }
        let suffix = name.dropFirst(contextPrefix.count)
        return suffix == "default" ? defaultWebPort : Int(suffix)
    }

    public static func parse(yaml: String) throws -> Kubeconfig {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ParseError.malformedYAML
        }

        let clusters = namedMap(root["clusters"], valueKey: "cluster")
        let users = namedMap(root["users"], valueKey: "user")
        let contexts = namedMap(root["contexts"], valueKey: "context")

        let entries: [Entry] = contexts.compactMap { name, context in
            guard let port = webPort(forContextNamed: name),
                  let clusterName = context["cluster"] as? String,
                  let userName = context["user"] as? String,
                  let cluster = clusters[clusterName],
                  let user = users[userName],
                  let serverString = cluster["server"] as? String,
                  let server = URL(string: serverString),
                  let token = user["token"] as? String,
                  let caString = cluster["certificate-authority-data"] as? String,
                  let caPEM = Data(base64Encoded: caString)
            else { return nil }

            // The kubeconfig is written non-atomically by tilt. A read caught mid-write could
            // yield a cluster block with server and token but CA not yet written, or CA with
            // invalid encoding. Dropping such entries prevents downstream from confusing
            // "incomplete write" with "successfully parsed entry without CA", which cannot pin TLS.

            return Entry(name: name,
                         port: port,
                         server: server,
                         certificateAuthorityPEM: caPEM,
                         token: token)
        }

        return Kubeconfig(tiltEntries: entries.sorted { $0.port < $1.port })
    }

    /// kubeconfig uses `[{name: x, <valueKey>: {...}}]`; flatten to `[x: {...}]`.
    private static func namedMap(_ raw: Any?, valueKey: String) -> [String: [String: Any]] {
        guard let list = raw as? [[String: Any]] else { return [:] }
        return list.reduce(into: [:]) { result, element in
            guard let name = element["name"] as? String,
                  let value = element[valueKey] as? [String: Any] else { return }
            result[name] = value
        }
    }
}
