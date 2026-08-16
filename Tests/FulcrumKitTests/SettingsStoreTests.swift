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
