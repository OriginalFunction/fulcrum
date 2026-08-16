import Foundation
import Testing
@testable import FulcrumKit

@Test func queryMatchesResourceNameCaseInsensitively() {
    var f = ResourceFilter(); f.query = "REDIS"
    #expect(f.apply(to: [res("ai-redis"), res("auth-service")]).map(\.name) == ["ai-redis"])
}

@Test func queryMatchesAsSubstringNotJustPrefix() {
    var f = ResourceFilter(); f.query = "redis"
    #expect(f.apply(to: [res("ai-redis-worker"), res("auth-service")]).map(\.name) == ["ai-redis-worker"])
}

@Test func queryDoesNotMatchGroupNameOnly() {
    // tilt's own filter box is name-only; a resource whose group matches but
    // whose name does not must be excluded.
    var f = ResourceFilter(); f.query = "auth"
    let items = [res("ai-redis", group: "auth"), res("auth-service", group: "ai")]
    #expect(f.apply(to: items).map(\.name) == ["auth-service"])
}

@Test func anEmptyQueryKeepsEverything() {
    #expect(ResourceFilter().apply(to: [res("a"), res("b")]).count == 2)
}

@Test func disabledResourcesAreHiddenUnlessAskedFor() {
    let items = [res("on", disabled: false), res("off", disabled: true)]
    #expect(ResourceFilter().apply(to: items).map(\.name) == ["on"])
    var f = ResourceFilter(); f.showDisabled = true
    #expect(f.apply(to: items).count == 2)
}

@Test func alertsOnTopLiftsErrorsWithoutDroppingAnything() {
    var f = ResourceFilter(); f.alertsOnTop = true
    let out = f.apply(to: [res("ok1", health: .ok), res("bad", health: .error), res("ok2", health: .ok)])
    #expect(out.first?.name == "bad")
    #expect(out.count == 3)
}

/// A 2-element same-band case (as in the brief's original example) would
/// pass even against a naive `sorted(by:)` with no index tiebreak, because
/// Swift's sort falls back to an in-practice-stable insertion sort for tiny
/// arrays — the test would look like it verifies stability while actually
/// verifying nothing. Twelve same-band elements is enough to push past that
/// threshold and make an unstable implementation visibly reorder them.
@Test func alertsOnTopPreservesRelativeOrderWithinEachBand() {
    var f = ResourceFilter(); f.alertsOnTop = true
    let okNames = (0..<12).map { "ok\($0)" }
    let items = okNames.map { res($0, health: .ok) } + [res("bad", health: .error)]
    let out = f.apply(to: items)
    #expect(out.map(\.name) == ["bad"] + okNames)
}

@Test func alertsOnTopWithMultipleErrorsPreservesOrderInBothBands() {
    var f = ResourceFilter(); f.alertsOnTop = true
    let items =
        (0..<12).map { res("ok\($0)", health: .ok) }
            + [res("bad1", health: .error), res("bad2", health: .error)]
    let out = f.apply(to: items)
    #expect(out.map(\.name) == ["bad1", "bad2"] + (0..<12).map { "ok\($0)" })
}

@Test func filtersComposeQueryDisabledAndAlertsOnTop() {
    var f = ResourceFilter()
    f.query = "svc"
    f.showDisabled = false
    f.alertsOnTop = true
    let items = [
        res("svc-a", health: .ok),
        res("svc-b", health: .error),
        res("svc-c", disabled: true),
        res("other", health: .error),
    ]
    #expect(f.apply(to: items).map(\.name) == ["svc-b", "svc-a"])
}
