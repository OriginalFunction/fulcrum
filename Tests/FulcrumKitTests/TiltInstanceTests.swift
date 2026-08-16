import Foundation
import Testing
@testable import FulcrumKit

private func entry(port: Int, server: String, token: String) -> Kubeconfig.Entry {
    Kubeconfig.Entry(name: "tilt-\(port)",
                     port: port,
                     server: URL(string: server)!,
                     certificateAuthorityPEM: Data("pem".utf8),
                     token: token)
}

@Test func buildsInstanceFromEntry() {
    let instance = TiltInstance(entry: entry(port: 10350, server: "https://127.0.0.1:5501", token: "t1"))
    #expect(instance.webPort == 10350)
    #expect(instance.webURL.absoluteString == "http://localhost:10350")
}

@Test func samePortDifferentTokenIsADifferentInstance() {
    let before = TiltInstance(entry: entry(port: 10350, server: "https://127.0.0.1:5501", token: "old"))
    let after = TiltInstance(entry: entry(port: 10350, server: "https://127.0.0.1:5501", token: "new"))
    #expect(before.id != after.id)
}

@Test func identicalServerAndTokenIsTheSameInstance() {
    let a = TiltInstance(entry: entry(port: 10350, server: "https://127.0.0.1:5501", token: "t"))
    let b = TiltInstance(entry: entry(port: 10350, server: "https://127.0.0.1:5501", token: "t"))
    #expect(a.id == b.id)
}

@Test func stubProbeReportsConfiguredLiveness() async {
    let instance = TiltInstance(entry: entry(port: 10350, server: "https://127.0.0.1:5501", token: "t"))
    let probe = StubLivenessProbe(alive: false)
    #expect(await probe.isAlive(instance) == false)
}
