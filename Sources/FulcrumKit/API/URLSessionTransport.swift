import Foundation

/// Real transport. Pins to the instance's CA and sends its bearer token.
public final class URLSessionTransport: DataTransport {
    private let instance: TiltInstance
    private let session: URLSession

    public init(instance: TiltInstance) {
        self.instance = instance
        self.session = URLSession(
            configuration: .ephemeral,
            delegate: PinnedTrustDelegate(caPEM: instance.certificateAuthorityPEM),
            delegateQueue: nil
        )
    }

    /// `URLSession` retains system resources (its delegate, connection pool) independently
    /// of ARC until `invalidateAndCancel()` is called. Without this, every fresh transport —
    /// e.g. one per liveness probe — leaks a session for the app's lifetime. Safe to call on
    /// a session with no outstanding tasks.
    deinit {
        session.invalidateAndCancel()
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(instance.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func data(from url: URL) async throws -> Data {
        let (data, _) = try await session.data(for: request(url))
        return data
    }

    public func bytes(from url: URL) async throws -> AsyncThrowingStream<UInt8, any Error> {
        let (byteStream, _) = try await session.bytes(for: request(url))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await byte in byteStream { continuation.yield(byte) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pins TLS validation to the instance's own CA.
///
/// `URLSessionDelegate` itself requires `Sendable`. `anchors` is a `let` array of
/// `SecCertificate` — an immutable CF type with no `Sendable` conformance in the
/// `Security` overlay — so the compiler cannot verify this automatically; `@unchecked`
/// asserts what's actually true: `anchors` is fixed at construction and never mutated.
private final class PinnedTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let anchors: [SecCertificate]

    init(caPEM: Data) {
        self.anchors = PinnedTrustDelegate.certificates(fromPEM: caPEM)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              !anchors.isEmpty
        else { return (.performDefaultHandling, nil) }

        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// Splits a PEM bundle into DER certificates. tilt's CA data contains two.
    private static func certificates(fromPEM pem: Data) -> [SecCertificate] {
        guard let text = String(data: pem, encoding: .utf8) else { return [] }
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"

        return text.components(separatedBy: begin).dropFirst().compactMap { block in
            guard let body = block.components(separatedBy: end).first else { return nil }
            let base64 = body.filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: base64) else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }
}
