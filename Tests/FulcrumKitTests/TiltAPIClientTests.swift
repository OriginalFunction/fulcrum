import Foundation
import Testing
@testable import FulcrumKit

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

private func makeInstance() -> TiltInstance {
    TiltInstance(entry: Kubeconfig.Entry(
        name: "tilt-10350",
        port: 10350,
        server: URL(string: "https://127.0.0.1:55501")!,
        certificateAuthorityPEM: Data(),
        token: "token"
    ))
}

@Test func listDecodesResources() async throws {
    let client = TiltAPIClient(instance: makeInstance(),
                               transport: StubTransport(data: try fixtureData("uiresources-list.json")))
    let list = try await client.list()
    #expect(list.items.map(\.metadata.name) == ["(Tiltfile)", "hello", "slow"])
}

@Test func sessionDecodesTheTiltfileKey() async throws {
    let payload = Data("""
    {"items":[{"metadata":{"name":"Tiltfile"},
     "status":{"tiltfileKey":"/Users/dev/src/northwind/Tiltfile"}}]}
    """.utf8)
    let client = TiltAPIClient(instance: makeInstance(), transport: StubTransport(data: payload))
    let session = try await client.session()
    #expect(session.items.first?.status.tiltfileKey == "/Users/dev/src/northwind/Tiltfile")
}

@Test func watchDecodesEveryEventInOrder() async throws {
    let client = TiltAPIClient(instance: makeInstance(),
                               transport: StubTransport(data: try fixtureData("watch-events.ndjson")))
    var kinds: [WatchEvent.Kind] = []
    var names: [String] = []
    for try await event in client.watch(fromResourceVersion: nil) {
        kinds.append(event.type)
        names.append(event.object.metadata.name)
    }
    #expect(kinds == [.added, .added, .modified, .modified, .deleted])
    #expect(names == ["(Tiltfile)", "hello", "hello", "hello", "slow"])
}

@Test func watchSurfacesStatusTransitions() async throws {
    let client = TiltAPIClient(instance: makeInstance(),
                               transport: StubTransport(data: try fixtureData("watch-events.ndjson")))
    var helloStatuses: [String] = []
    for try await event in client.watch(fromResourceVersion: nil)
    where event.object.metadata.name == "hello" {
        helloStatuses.append(event.object.status?.updateStatus ?? "")
    }
    #expect(helloStatuses == ["ok", "in_progress", "error"])
}

@Test func watchSkipsBlankAndUndecodableLines() async throws {
    let payload = Data("""
    {"type":"ADDED","object":{"metadata":{"name":"a"}}}

    not json at all
    {"type":"MODIFIED","object":{"metadata":{"name":"b"}}}
    """.utf8)
    let client = TiltAPIClient(instance: makeInstance(), transport: StubTransport(data: payload))
    var names: [String] = []
    for try await event in client.watch(fromResourceVersion: nil) {
        names.append(event.object.metadata.name)
    }
    #expect(names == ["a", "b"])
}

@Test func watchHandlesEventSplitAcrossReads() async throws {
    // No trailing newline on the final line — the stream ends mid-buffer.
    let payload = Data(#"{"type":"ADDED","object":{"metadata":{"name":"only"}}}"#.utf8)
    let client = TiltAPIClient(instance: makeInstance(), transport: StubTransport(data: payload))
    var names: [String] = []
    for try await event in client.watch(fromResourceVersion: nil) {
        names.append(event.object.metadata.name)
    }
    #expect(names == ["only"])
}
