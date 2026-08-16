import Foundation
import Testing
@testable import FulcrumKit

@Test func displayNameIsTheTiltfilesParentDirectory() {
    #expect(ProjectIdentity.displayName(forTiltfilePath: "/Users/dev/src/northwind/Tiltfile")
            == "northwind")
}

@Test func displayNameHandlesANonStandardTiltfileName() {
    // `tilt up -f deploy/dev.Tiltfile` — the parent directory is still the project.
    #expect(ProjectIdentity.displayName(forTiltfilePath: "/Users/r/Projects/app/deploy/dev.Tiltfile")
            == "deploy")
}

@Test func displayNameFallsBackWhenThePathIsUnusable() {
    #expect(ProjectIdentity.displayName(forTiltfilePath: "") == nil)
    #expect(ProjectIdentity.displayName(forTiltfilePath: "Tiltfile") == nil)
}

@Test func decodesTiltfileKeyFromAUISessionList() throws {
    let json = """
    {"items":[{"metadata":{"name":"Tiltfile"},
     "status":{"tiltfileKey":"/Users/dev/src/northwind/Tiltfile"}}]}
    """
    let list = try JSONDecoder().decode(UISessionList.self, from: Data(json.utf8))
    #expect(list.items.first?.status.tiltfileKey == "/Users/dev/src/northwind/Tiltfile")
}

/// The single fallback shape every display site defers to when no real name
/// can be resolved. Pinned here so the two call sites (`InstanceStore.displayName`,
/// `RecentProject`'s empty-name guard) can't drift onto their own literals.
@Test func fallbackNameIsPortBased() {
    #expect(ProjectIdentity.fallbackName(forPort: 10350) == "tilt-10350")
}
