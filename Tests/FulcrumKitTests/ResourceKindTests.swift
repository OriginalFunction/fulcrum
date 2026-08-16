import Testing
@testable import FulcrumKit

@Test func mapsTiltSpecTypesToKinds() {
    #expect(ResourceKind(specType: "local") == .local)
    #expect(ResourceKind(specType: "k8s") == .kubernetes)
    #expect(ResourceKind(specType: "dc") == .dockerCompose)
    #expect(ResourceKind(specType: "image") == .image)
}

@Test func unrecognisedSpecTypeIsUnknownNotACrash() {
    // tilt may add spec types; an unknown one must degrade, not fail.
    #expect(ResourceKind(specType: "something-new") == .unknown)
}

@Test func absentSpecTypeIsUnknown() {
    // The `(Tiltfile)` row has no specs at all. Callers map it to .tiltfile
    // explicitly by name; this init only sees the missing type.
    #expect(ResourceKind(specType: nil) == .unknown)
}

@Test func displayNamesAreShortEnoughForATableColumn() {
    #expect(ResourceKind.local.displayName == "local")
    #expect(ResourceKind.kubernetes.displayName == "k8s")
    #expect(ResourceKind.dockerCompose.displayName == "compose")
    #expect(ResourceKind.image.displayName == "image")
    #expect(ResourceKind.tiltfile.displayName == "Tiltfile")
    #expect(ResourceKind.unknown.displayName == "—")
}
