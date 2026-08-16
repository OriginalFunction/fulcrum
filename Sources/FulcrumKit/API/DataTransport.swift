import Foundation

/// Byte-level access to an instance's apiserver.
///
/// Exists so decoding can be tested without TLS: pinning against a self-signed
/// local CA is not reproducible in a unit test, but everything above it is.
public protocol DataTransport: Sendable {
    func data(from url: URL) async throws -> Data
    func bytes(from url: URL) async throws -> AsyncThrowingStream<UInt8, any Error>
}

/// Test double.
public struct StubTransport: DataTransport {
    private let result: Result<Data, any Error>

    public init(data: Data) { self.result = .success(data) }
    public init(error: any Error) { self.result = .failure(error) }

    public func data(from url: URL) async throws -> Data {
        try result.get()
    }

    public func bytes(from url: URL) async throws -> AsyncThrowingStream<UInt8, any Error> {
        let payload = try result.get()
        return AsyncThrowingStream { continuation in
            for byte in payload { continuation.yield(byte) }
            continuation.finish()
        }
    }
}
