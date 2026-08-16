import Testing
@testable import FulcrumKit

@Test func minimumTiltVersionIsTheVerifiedFloor() {
    #expect(FulcrumKit.minimumTiltVersion == "0.36.3")
}
