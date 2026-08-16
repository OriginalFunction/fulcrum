import Foundation
import Testing
@testable import FulcrumKit

/// `RecentProject` is a persisted, Codable value — a corrupt disk write or a
/// future caller could hand it an empty `displayName`. Guarding here, rather
/// than at every call site, is what "never render an empty name" means for
/// the Recent section: this is the one place that promise is kept.
@Test func emptyDisplayNameFallsBackToThePortBasedName() {
    let project = RecentProject(id: "port-10350", displayName: "", lastPort: 10350, lastSeen: Date())
    #expect(project.displayName == "tilt-10350")
}

@Test func aNonEmptyDisplayNameIsPreservedAsGiven() {
    let project = RecentProject(id: "port-10350", displayName: "northwind", lastPort: 10350, lastSeen: Date())
    #expect(project.displayName == "northwind")
}

/// The synthesized `Decodable` would assign an empty `displayName` straight
/// through, bypassing the guard the memberwise initializer applies — this is
/// the realistic corruption path: a valid `recents.json` entry with `""` for
/// `displayName` decodes without error, so the guard must also live in
/// `init(from:)`, not just construction.
@Test func decodingAnEmptyDisplayNameFallsBackToThePortBasedName() throws {
    let json = """
    {"id":"port-10350","displayName":"","lastPort":10350,
     "lastSeen":0,"isPinned":false}
    """
    let project = try JSONDecoder().decode(RecentProject.self, from: Data(json.utf8))
    #expect(project.displayName == "tilt-10350")
}

/// A `recents.json` written before Task 14 has no `tiltfilePath` key at all
/// — that must decode to `nil`, not fail the whole entry, so an existing
/// user's file keeps loading after this update.
@Test func decodingAnEntryWithNoTiltfilePathKeyLeavesItNil() throws {
    let json = """
    {"id":"port-10350","displayName":"northwind","lastPort":10350,
     "lastSeen":0,"isPinned":false}
    """
    let project = try JSONDecoder().decode(RecentProject.self, from: Data(json.utf8))
    #expect(project.tiltfilePath == nil)
}

@Test func tiltfilePathRoundTripsThroughEncodingAndDecoding() throws {
    let project = RecentProject(
        id: "port-10350", displayName: "northwind", lastPort: 10350,
        lastSeen: Date(timeIntervalSince1970: 0), tiltfilePath: "/Users/dev/src/northwind/Tiltfile"
    )
    let data = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(RecentProject.self, from: data)
    #expect(decoded.tiltfilePath == "/Users/dev/src/northwind/Tiltfile")
}
