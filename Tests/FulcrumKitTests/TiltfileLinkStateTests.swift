import Foundation
import Testing
@testable import FulcrumKit

// MARK: - The distinction this type exists for

/// The whole point of the type. "No path recorded" and "path recorded, file
/// gone" both stop a project being restarted, and an earlier shape of this
/// code let a view tell them apart only by reading
/// `restartUnavailableReason`'s wording. They are different situations: one
/// is an incomplete record, the other is a fault. Only the fault is flagged.
///
/// Mutating `resolve` to `.broken(path: tiltfilePath ?? "")` — the naive
/// "anything that can't restart is broken" collapse — fails this.
@Test func noRecordedPathIsUnlinkedAndIsNotBroken() {
    let state = TiltfileLinkState.resolve(tiltfilePath: nil, fileExists: { _ in false })
    #expect(state == .unlinked)
    #expect(state.isBroken == false)
    #expect(state.brokenReason == nil)
    #expect(state.path == nil)
}

/// The other half of the same distinction, and the live `detachtest` case:
/// a path IS on record and nothing is there.
@Test func aRecordedPathWithNoFileAtItIsBroken() {
    let state = TiltfileLinkState.resolve(tiltfilePath: "/gone/Tiltfile", fileExists: { _ in false })
    #expect(state == .broken(path: "/gone/Tiltfile"))
    #expect(state.isBroken)
}

@Test func aRecordedPathWithAFileAtItIsLinkedAndUnremarkable() {
    let state = TiltfileLinkState.resolve(tiltfilePath: "/there/Tiltfile", fileExists: { _ in true })
    #expect(state == .linked(path: "/there/Tiltfile"))
    #expect(state.isBroken == false)
    #expect(state.brokenReason == nil)
}

/// `fileExists` must be asked about the recorded path itself, not about some
/// derived or hard-coded one — a check that answers for the wrong path would
/// pass every "always true" / "always false" stub above without ever being
/// correct.
@Test func theExistenceCheckIsAskedAboutTheRecordedPath() {
    var asked: [String] = []
    _ = TiltfileLinkState.resolve(tiltfilePath: "/a/b/My.Tiltfile", fileExists: {
        asked.append($0)
        return true
    })
    #expect(asked == ["/a/b/My.Tiltfile"])
}

/// An `.unlinked` state has no path to check, so it must not perform (or
/// require) an existence check at all.
@Test func noRecordedPathPerformsNoExistenceCheck() {
    var calls = 0
    _ = TiltfileLinkState.resolve(tiltfilePath: nil, fileExists: { _ in
        calls += 1
        return true
    })
    #expect(calls == 0)
}

// MARK: - What the indicator says

/// A broken indicator that does not name the missing file leaves the user
/// with nothing to act on. Mutating `brokenReason` to a generic "This
/// project's Tiltfile is missing." fails this.
@Test func theBrokenReasonNamesTheMissingPath() throws {
    let state = TiltfileLinkState.broken(path: "/private/tmp/detachtest/Tiltfile")
    let reason = try #require(state.brokenReason)
    #expect(reason.contains("/private/tmp/detachtest/Tiltfile"))
    #expect(reason.contains("moved or deleted"))
}

/// Every state that carries a path exposes it, so a Relink or a Reveal has
/// something to start from even when the file is gone.
@Test func bothLinkedAndBrokenExposeTheirPath() {
    #expect(TiltfileLinkState.linked(path: "/a/Tiltfile").path == "/a/Tiltfile")
    #expect(TiltfileLinkState.broken(path: "/b/Tiltfile").path == "/b/Tiltfile")
}
