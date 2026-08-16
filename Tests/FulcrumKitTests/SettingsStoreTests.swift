import Foundation
import Testing
@testable import FulcrumKit

@MainActor
private func freshDefaults() -> UserDefaults {
    TestUserDefaults.fresh()
}

@Test @MainActor func defaultsMatchTheSpec() {
    let store = SettingsStore(defaults: freshDefaults())
    #expect(store.iconMode == .worstStateHealth)
    #expect(store.failuresInMenu == .auto)
    #expect(store.appearance == .system)
    #expect(store.logPaneAppearance == .followTheme)
    #expect(store.jsonPresentation == .inline)
    #expect(store.logScrollback == .lines1000)
    #expect(store.logPaneHeight == 220)
    #expect(store.launchAtLogin == false)
    #expect(store.alertsOnTop == false)
    #expect(store.showDisabled == false)
}

@Test @MainActor func settingsPersistToDefaults() {
    let defaults = freshDefaults()
    let store = SettingsStore(defaults: defaults)
    store.iconMode = .instanceCount
    store.failuresInMenu = .always
    store.appearance = .dark
    store.logPaneAppearance = .alwaysDark
    store.jsonPresentation = .detailPane
    store.logScrollback = .lines5000
    store.logPaneHeight = 340
    store.launchAtLogin = true
    store.alertsOnTop = true
    store.showDisabled = true

    let reloaded = SettingsStore(defaults: defaults)
    #expect(reloaded.iconMode == .instanceCount)
    #expect(reloaded.failuresInMenu == .always)
    #expect(reloaded.appearance == .dark)
    #expect(reloaded.logPaneAppearance == .alwaysDark)
    #expect(reloaded.jsonPresentation == .detailPane)
    #expect(reloaded.logScrollback == .lines5000)
    #expect(reloaded.logPaneHeight == 340)
    #expect(reloaded.launchAtLogin == true)
    #expect(reloaded.alertsOnTop == true)
    #expect(reloaded.showDisabled == true)
}

@Test @MainActor func unknownStoredValueFallsBackToDefault() {
    let defaults = freshDefaults()
    defaults.set("nonsense", forKey: "iconMode")
    #expect(SettingsStore(defaults: defaults).iconMode == .worstStateHealth)
}

@Test func allIconModesAreEnumerable() {
    #expect(MenuBarIconMode.allCases.count == 4)
    #expect(FailuresInMenu.allCases.count == 3)
}

@Test @MainActor func unknownStoredJSONPresentationFallsBackToInline() {
    let defaults = freshDefaults()
    defaults.set("nonsense", forKey: "jsonPresentation")
    #expect(SettingsStore(defaults: defaults).jsonPresentation == .inline)
}

@Test @MainActor func unknownStoredLogScrollbackFallsBackToTheDefault() {
    let defaults = freshDefaults()
    defaults.set("nonsense", forKey: "logScrollback")
    #expect(SettingsStore(defaults: defaults).logScrollback == .lines1000)
}

@Test func everyScrollbackChoiceIsAMeasuredPointOnTheCostCurve() {
    // The four choices are not a designer's round numbers: each one is a
    // capacity `hangprobe` was actually run at, at a fixed 6 lines/sec into a
    // full buffer. There is deliberately no free-form field and nothing above
    // 5,000 — a capacity nobody measured is a capacity whose cost the
    // settings copy cannot state. If a fifth choice is ever added, it has to
    // be measured first, and this assertion is where that gets noticed.
    #expect(LogScrollback.allCases.map(\.lineCount) == [500, 1_000, 2_500, 5_000])
}

@Test @MainActor func theDefaultScrollbackIsTheLargestChoiceThatCostsNothing() {
    // Two claims, both off the measured curve, and the reason the default is
    // 1,000 rather than the 5,000 that shipped:
    //
    //  * 1,000 lines measures 99.7%/99.2% main-thread availability across
    //    two runs, against 5,000's 90.9%/90.2% at the same arrival rate.
    //  * It is below `LogPaneModel.floodedOccupancy`, so it never selects the
    //    slower publish interval. The whole reason this preference exists is
    //    that af1e601's 500ms of pane lag is permanent once the buffer fills;
    //    a default that quietly re-imposed it would have missed the point.
    let store = SettingsStore(defaults: TestUserDefaults.fresh())
    #expect(store.logScrollback == .lines1000)
    #expect(store.logScrollback.lineCount < LogPaneModel.floodedOccupancy)
    #expect(LogScrollback.lines2500.lineCount >= LogPaneModel.floodedOccupancy,
            "the next choice up does reach the threshold — which is what makes 1,000 the largest that does not")
}

@Test @MainActor func onlyTheChoicesThatCanReachTheThresholdWarnAboutTheSlowerUpdate() {
    // The copy under the picker promises "fully responsive" on the small
    // choices and warns about updating twice a second on the large ones.
    // Which promise a choice makes is not editorial: it follows exactly from
    // whether its capacity can reach `LogPaneModel.floodedOccupancy`, and
    // this is what keeps the two from drifting apart.
    for choice in LogScrollback.allCases {
        let canReachTheThreshold = choice.lineCount >= LogPaneModel.floodedOccupancy
        #expect(choice.detail.contains("twice a second") == canReachTheThreshold,
                "\(choice.title) warns about the slower update when and only when it can select it")
        #expect(choice.detail.contains("fully responsive") == !canReachTheThreshold,
                "\(choice.title) promises full responsiveness when and only when it can keep it")
    }
}
