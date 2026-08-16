import Testing
@testable import FulcrumKit

@Test func prefersAnExplicitEnvironmentOverride() {
    let found = TiltBinary.locate(fileExists: { _ in true },
                                  environment: ["FULCRUM_TILT_PATH": "/custom/tilt"])
    #expect(found?.path == "/custom/tilt")
}

@Test func findsHomebrewOnAppleSiliconWhenPathIsBare() {
    let found = TiltBinary.locate(fileExists: { $0 == "/opt/homebrew/bin/tilt" },
                                  environment: ["PATH": "/usr/bin:/bin"])
    #expect(found?.path == "/opt/homebrew/bin/tilt")
}

@Test func findsIntelHomebrew() {
    #expect(TiltBinary.locate(fileExists: { $0 == "/usr/local/bin/tilt" },
                              environment: [:])?.path == "/usr/local/bin/tilt")
}

@Test func findsUserLocalBinUnderTheInjectedHomeNotAHardcodedOne() {
    let found = TiltBinary.locate(
        fileExists: { $0 == "/custom/home/.local/bin/tilt" },
        environment: ["HOME": "/custom/home"]
    )
    #expect(found?.path == "/custom/home/.local/bin/tilt")
}

@Test func returnsNilWhenTiltIsNotInstalled() {
    #expect(TiltBinary.locate(fileExists: { _ in false }, environment: [:]) == nil)
}

@Test func anOverridePointingAtNothingDoesNotMaskARealInstall() {
    let found = TiltBinary.locate(fileExists: { $0 == "/opt/homebrew/bin/tilt" },
                                  environment: ["FULCRUM_TILT_PATH": "/gone/tilt"])
    #expect(found?.path == "/opt/homebrew/bin/tilt")
}
