import Foundation
import Testing
@testable import FulcrumKit

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func parsesBothTiltEntries() throws {
    let config = try Kubeconfig.parse(yaml: fixture("tilt-config.yaml"))
    #expect(config.tiltEntries.count == 2)
}

@Test func contextNameEncodesWebPortNotServerPort() throws {
    let config = try Kubeconfig.parse(yaml: fixture("tilt-config.yaml"))
    let entry = try #require(config.tiltEntries.first { $0.name == "tilt-10360" })
    #expect(entry.port == 10360)
    #expect(entry.server.port == 55501)
}

@Test func pairsTokenWithMatchingUser() throws {
    let config = try Kubeconfig.parse(yaml: fixture("tilt-config.yaml"))
    let entry = try #require(config.tiltEntries.first { $0.name == "tilt-10360" })
    #expect(entry.token.hasPrefix("pH5aSRrD"))
}

@Test func decodesCertificateAuthorityToPEM() throws {
    let config = try Kubeconfig.parse(yaml: fixture("tilt-config.yaml"))
    let entry = try #require(config.tiltEntries.first)
    let pem = try #require(String(data: entry.certificateAuthorityPEM, encoding: .utf8))
    #expect(pem.contains("BEGIN CERTIFICATE"))
}

@Test func ignoresNonTiltContexts() throws {
    let yaml = """
    apiVersion: v1
    clusters:
    - cluster:
        server: https://example.com
      name: production
    contexts:
    - context:
        cluster: production
        user: production
      name: production
    kind: Config
    users:
    - name: production
      user:
        token: abc
    """
    let config = try Kubeconfig.parse(yaml: yaml)
    #expect(config.tiltEntries.isEmpty)
}

@Test func emptyConfigYieldsNoEntries() throws {
    let yaml = """
    apiVersion: v1
    clusters: null
    contexts: null
    current-context: ""
    kind: Config
    users: null
    """
    let config = try Kubeconfig.parse(yaml: yaml)
    #expect(config.tiltEntries.isEmpty)
}

@Test func dropsEntryWithMissingCertificateAuthority() throws {
    let yaml = """
    apiVersion: v1
    clusters:
    - cluster:
        server: https://127.0.0.1:55501
      name: tilt-10360
    contexts:
    - context:
        cluster: tilt-10360
        user: tilt-10360
      name: tilt-10360
    kind: Config
    users:
    - name: tilt-10360
      user:
        token: pH5aSRrD-CU-OCmyxkmPdxBiVVsWUu7uUvhFfvqhPDXBkcUHOjM
    """
    let config = try Kubeconfig.parse(yaml: yaml)
    #expect(config.tiltEntries.isEmpty)
}

@Test func dropsEntryWithInvalidBase64CertificateAuthority() throws {
    let yaml = """
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: "!!!not-base64!!!"
        server: https://127.0.0.1:55501
      name: tilt-10360
    contexts:
    - context:
        cluster: tilt-10360
        user: tilt-10360
      name: tilt-10360
    kind: Config
    users:
    - name: tilt-10360
      user:
        token: pH5aSRrD-CU-OCmyxkmPdxBiVVsWUu7uUvhFfvqhPDXBkcUHOjM
    """
    let config = try Kubeconfig.parse(yaml: yaml)
    #expect(config.tiltEntries.isEmpty)
}

/// Any base64 that decodes is enough here — the parser checks decodability, and
/// pinning against a real certificate is exercised in TiltAPIClientTests.
private let placeholderCA =
    "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJmYWtlCi0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K"

/// `tilt up` with no `--port` registers its context as `tilt-default`, never
/// `tilt-10350` — the port appears in the name only when the flag is passed.
/// That is the ordinary way to start tilt, so dropping these entries left
/// Fulcrum blind to most real instances.
///
/// Mapping it to 10350 is unambiguous: tilt refuses to start a second instance
/// on the default port ("Tilt cannot start because you already have another
/// process on port 10350"), so at most one `tilt-default` exists at a time and
/// its web port is always the documented `--port` default.
@Test func defaultContextResolvesToTheDefaultWebPort() throws {
    let yaml = """
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: \(placeholderCA)
        server: https://127.0.0.1:62599
      name: tilt-default
    contexts:
    - context:
        cluster: tilt-default
        user: tilt-default
      name: tilt-default
    kind: Config
    users:
    - name: tilt-default
      user:
        token: pH5aSRrD-CU-OCmyxkmPdxBiVVsWUu7uUvhFfvqhPDXBkcUHOjM
    """
    let config = try Kubeconfig.parse(yaml: yaml)
    let entry = try #require(config.tiltEntries.first)
    #expect(entry.name == "tilt-default")
    #expect(entry.port == 10350)
}

/// Only the exact name `tilt-default` carries an implied port. A suffix that is
/// neither an integer nor `default` names something we cannot address, so it is
/// still dropped rather than guessed at.
@Test func unrecognisedTiltSuffixIsStillDropped() throws {
    let yaml = """
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: \(placeholderCA)
        server: https://127.0.0.1:62600
      name: tilt-staging
    contexts:
    - context:
        cluster: tilt-staging
        user: tilt-staging
      name: tilt-staging
    kind: Config
    users:
    - name: tilt-staging
      user:
        token: pH5aSRrD-CU-OCmyxkmPdxBiVVsWUu7uUvhFfvqhPDXBkcUHOjM
    """
    let config = try Kubeconfig.parse(yaml: yaml)
    #expect(config.tiltEntries.isEmpty)
}
