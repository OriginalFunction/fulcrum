import Foundation

/// Read-only client for one tilt instance's apiserver.
public struct TiltAPIClient: Sendable {
    private let instance: TiltInstance
    private let transport: any DataTransport

    private static let resourcePath = "/apis/tilt.dev/v1alpha1/uiresources"
    private static let sessionPath = "/apis/tilt.dev/v1alpha1/uisessions"

    public init(instance: TiltInstance, transport: any DataTransport) {
        self.instance = instance
        self.transport = transport
    }

    public init(instance: TiltInstance) {
        self.init(instance: instance, transport: URLSessionTransport(instance: instance))
    }

    public func list() async throws -> UIResourceList {
        let data = try await transport.data(from: instance.server.appending(path: Self.resourcePath))
        return try JSONDecoder().decode(UIResourceList.self, from: data)
    }

    public func session() async throws -> UISessionList {
        let data = try await transport.data(from: instance.server.appending(path: Self.sessionPath))
        return try JSONDecoder().decode(UISessionList.self, from: data)
    }

    /// Streams watch events as newline-delimited JSON.
    ///
    /// Undecodable lines are skipped rather than terminating the stream — a single
    /// malformed event must not take down a live connection.
    public func watch(fromResourceVersion resourceVersion: String?) -> AsyncThrowingStream<WatchEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var components = URLComponents(
                        url: instance.server.appending(path: Self.resourcePath),
                        resolvingAgainstBaseURL: false
                    )!
                    var query = [URLQueryItem(name: "watch", value: "true")]
                    if let resourceVersion {
                        query.append(URLQueryItem(name: "resourceVersion", value: resourceVersion))
                    }
                    components.queryItems = query

                    let decoder = JSONDecoder()
                    var line = Data()

                    let byteStream = try await transport.bytes(from: components.url!)
                    // Defensive, not a fix for an observed bug: `transport` is only
                    // *syntactically* used above, to obtain `byteStream`, so in
                    // principle ARC's last-use release could deallocate it as soon as
                    // that call returns, before the loop below starts iterating. A
                    // controlled A/B test (with vs. without this line, class-backed
                    // transport, real per-byte suspension) showed no measurable
                    // difference — the transport survived the full iteration either
                    // way. Kept anyway: `withExtendedLifetime` is the documented tool
                    // for exactly this hazard, and costs nothing even if the hazard
                    // never materializes in practice.
                    defer { withExtendedLifetime(transport) {} }

                    for try await byte in byteStream {
                        guard byte != UInt8(ascii: "\n") else {
                            emit(line, decoder: decoder, into: continuation)
                            line.removeAll(keepingCapacity: true)
                            continue
                        }
                        line.append(byte)
                    }
                    // The final line may arrive without a trailing newline.
                    emit(line, decoder: decoder, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func emit(
        _ line: Data,
        decoder: JSONDecoder,
        into continuation: AsyncThrowingStream<WatchEvent, any Error>.Continuation
    ) {
        guard !line.isEmpty, let event = try? decoder.decode(WatchEvent.self, from: line) else { return }
        continuation.yield(event)
    }
}
