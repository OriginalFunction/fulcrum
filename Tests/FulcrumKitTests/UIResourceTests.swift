import Foundation
import Testing
@testable import FulcrumKit

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

@Test func decodesListWithAllItems() throws {
    let list = try JSONDecoder().decode(UIResourceList.self, from: fixtureData("uiresources-list.json"))
    #expect(list.items.count == 3)
    #expect(list.metadata.resourceVersion == "57")
}

@Test func decodesStatusFields() throws {
    let list = try JSONDecoder().decode(UIResourceList.self, from: fixtureData("uiresources-list.json"))
    let slow = try #require(list.items.first { $0.metadata.name == "slow" })
    #expect(slow.status?.runtimeStatus == "ok")
    #expect(slow.status?.updateStatus == "not_applicable")
    #expect(slow.status?.disableStatus?.state == "Enabled")
    #expect(slow.status?.order == 3)
}

@Test func toleratesMissingStatus() throws {
    let json = Data("""
    {"kind":"UIResourceList","metadata":{"resourceVersion":"1"},
     "items":[{"metadata":{"name":"bare"}}]}
    """.utf8)
    let list = try JSONDecoder().decode(UIResourceList.self, from: json)
    #expect(list.items.first?.status == nil)
}

@Test func stubTransportReturnsConfiguredData() async throws {
    let transport = StubTransport(data: Data("hello".utf8))
    let received = try await transport.data(from: URL(string: "https://example.com")!)
    #expect(String(data: received, encoding: .utf8) == "hello")
}

@Test func stubTransportThrowsConfiguredError() async {
    struct Boom: Error {}
    let transport = StubTransport(error: Boom())
    await #expect(throws: Boom.self) {
        _ = try await transport.data(from: URL(string: "https://example.com")!)
    }
}
