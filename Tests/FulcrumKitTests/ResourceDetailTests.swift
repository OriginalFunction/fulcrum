import Foundation
import Testing
@testable import FulcrumKit

private func typedResources() throws -> [Resource] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/uiresources-typed.json",
                                             withExtension: nil))
    let list = try JSONDecoder().decode(UIResourceList.self, from: Data(contentsOf: url))
    return list.items.map(Resource.init(uiResource:))
}

private func resource(named name: String) throws -> Resource {
    try #require(try typedResources().first { $0.name == name })
}

@Test func decodesSpecTypeIntoKind() throws {
    #expect(try resource(named: "slow-build").kind == .local)
    #expect(try resource(named: "never-built").kind == .kubernetes)
}

@Test func tiltfileRowHasNoSpecsAndIsClassifiedByName() throws {
    // The one row that is always present carries no `specs` key. It must not
    // fall through to `.unknown` and it must not crash.
    #expect(try resource(named: "(Tiltfile)").kind == .tiltfile)
}

@Test func computesLastBuildDurationFromSixDigitFractionalTimestamps() throws {
    let slow = try resource(named: "slow-build")
    let duration = try #require(slow.lastBuildDuration)
    // 15:02:36.867858 -> 15:02:40.134921 is 3.267063s
    #expect(abs(duration - 3.267) < 0.01)
}

@Test func subSecondBuildsStillProduceADuration() throws {
    let quick = try resource(named: "(Tiltfile)")
    let duration = try #require(quick.lastBuildDuration)
    #expect(duration > 0 && duration < 1)
}

@Test func resourceWithNoBuildHistoryHasNoDuration() throws {
    #expect(try resource(named: "never-built").lastBuildDuration == nil)
}

@Test func surfacesTheBuildErrorMessage() throws {
    let broken = try resource(named: "broken")
    #expect(broken.buildError == #"Command "exit 1" failed: exit status 1"#)
}

@Test func successfulBuildHasNoErrorMessage() throws {
    #expect(try resource(named: "slow-build").buildError == nil)
}

@Test func formatsShortBuildsWithADecimalPlace() throws {
    // Local resources often build in well under a second; rounding would make
    // every one of them read "0s" and the column would say nothing.
    #expect(try resource(named: "slow-build").lastBuildText == "3.3s")
    #expect(try resource(named: "(Tiltfile)").lastBuildText == "0.0s")
}

@Test func neverBuiltShowsADash() throws {
    #expect(try resource(named: "never-built").lastBuildText == "—")
}
