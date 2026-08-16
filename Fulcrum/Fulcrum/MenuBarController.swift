import AppKit
import FulcrumKit
import Observation

/// Owns the status item and rebuilds its menu on demand.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let openDashboardAction: @MainActor () -> Void
    /// Selects `port`'s instance, brings `resourceName` into view (clearing
    /// any filter or collapsed group that would hide it), and opens the
    /// dashboard. Backs both `.failure` rows and, once an instance's
    /// submenu is built, its individual `.resource` rows.
    private let focusResourceAction: @MainActor (_ resourceName: String, _ port: Int) -> Void
    /// Selects `port`'s instance (with no specific resource) and opens the
    /// dashboard. Backs an `.instance` row when it has no groups to show as
    /// a submenu.
    private let selectInstanceAction: @MainActor (_ port: Int) -> Void
    /// Presents the Tiltfile open panel and starts it. Backs `.openTiltfile`
    /// — the status menu is the always-available surface for this, since
    /// Fulcrum's own main menu bar only exists while the dashboard window is
    /// open. See `OpenTiltfileCommand`, which this and the app menu's ⌘O
    /// both ultimately call.
    private let openTiltfileAction: @MainActor () -> Void
    /// Shows the About window. See `AboutView`/`AboutWindowController` — the
    /// status menu is this command's only home for the same reason
    /// `openTiltfileAction` lives here: the app's own main menu bar only
    /// exists while the dashboard window is open.
    private let aboutAction: @MainActor () -> Void
    /// Opens the download page — deliberately NOT Sparkle. A real in-app
    /// updater is its own plan with its own signing/notarization story;
    /// shipping a manual "go look at the download page" link is honest about
    /// where the app actually is, which a half-built auto-updater would not
    /// be. This is the interim, until that plan exists.
    private let checkForUpdatesAction: @MainActor () -> Void

    init(
        model: AppModel,
        openDashboardAction: @escaping @MainActor () -> Void,
        focusResourceAction: @escaping @MainActor (_ resourceName: String, _ port: Int) -> Void,
        selectInstanceAction: @escaping @MainActor (_ port: Int) -> Void,
        openTiltfileAction: @escaping @MainActor () -> Void,
        aboutAction: @escaping @MainActor () -> Void,
        checkForUpdatesAction: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.openDashboardAction = openDashboardAction
        self.focusResourceAction = focusResourceAction
        self.selectInstanceAction = selectInstanceAction
        self.openTiltfileAction = openTiltfileAction
        self.aboutAction = aboutAction
        self.checkForUpdatesAction = checkForUpdatesAction
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        observeIcon()
    }

    /// Re-render the icon whenever anything it derives from changes.
    ///
    /// `withObservationTracking`'s `onChange` fires at most once per registration,
    /// so continuous observation requires re-arming inside the handler itself —
    /// this is the standard Observation framework pattern, not accidental
    /// recursion. The re-arm is dispatched via `Task { @MainActor in ... }`
    /// rather than called synchronously, so there is no growing call stack: each
    /// firing is a fresh, independent hop onto the main actor's queue.
    ///
    /// The `[weak self]` capture only needs to cover the outer `onChange`
    /// closure. `self` read inside the nested `Task` closure resolves through
    /// that same weak capture rather than establishing a second, strong one —
    /// verified empirically (see task-14-report.md) by mutating an `@Observable`
    /// model through several re-arm cycles and confirming `deinit` runs
    /// immediately once the last strong reference is dropped, with no further
    /// re-registration occurring afterward.
    private func observeIcon() {
        withObservationTracking {
            if let button = statusItem.button {
                IconRenderer.apply(model.iconState, to: button)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
    }

    // Rebuilt at open time from a snapshot — NSMenu cannot restructure while visible.
    //
    // "Check for Updates…" and "About Fulcrum" are spliced in here, directly
    // ahead of Quit, rather than living in `MenuDescriptor.Item` — unlike
    // every other row in this menu, neither depends on any `AppModel` state
    // (no health, no connection, no tilt-installed check), so there is no
    // decision here for `MenuDescriptor` to own and test; it is pure static
    // rendering, which belongs entirely in this app-target file.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in MenuDescriptor.build(from: model) {
            if case .quit = item {
                menu.addItem(.separator())
                menu.addItem(checkForUpdatesItem())
                menu.addItem(aboutItem())
            }
            menu.addItem(makeItem(item))
        }
    }

    /// `instancePort` is threaded through recursive calls so a `.resource`
    /// leaf — which carries no port of its own, see `MenuDescriptor.Item` —
    /// can still route its click to the right instance. Only ever nil at the
    /// top level, where `.resource`/`.group` never appear: `MenuDescriptor.build`
    /// emits them solely inside an `.instance`'s `groups`, and this function
    /// always supplies the enclosing instance's port when it recurses into them.
    private func makeItem(_ item: MenuDescriptor.Item, instancePort: Int? = nil) -> NSMenuItem {
        switch item {
        case .separator:
            return .separator()

        case let .status(text):
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            return entry

        case let .failure(instanceName, port, resourceName):
            let entry = NSMenuItem(title: resourceName,
                                   action: #selector(focusResource(_:)),
                                   keyEquivalent: "").targeting(self)
            entry.toolTip = instanceName
            entry.image = dot(for: .error)
            entry.representedObject = MenuFocusTarget(resourceName: resourceName, port: port)
            return entry

        case let .instance(name, port, summary, health, groups):
            let entry = NSMenuItem(title: name,
                                   action: #selector(selectInstance(_:)),
                                   keyEquivalent: "").targeting(self)
            entry.image = dot(for: health)
            entry.toolTip = summary
            entry.representedObject = port
            // A connecting (or perpetually failing) instance has no resources
            // yet; an empty submenu would be a dead end the user can open
            // onto nothing, so it renders as a plain row instead.
            if !groups.isEmpty {
                let submenu = NSMenu()
                for group in groups {
                    submenu.addItem(makeItem(MenuDescriptor.groupItem(for: group), instancePort: port))
                }
                entry.submenu = submenu
            }
            return entry

        case let .group(name, summary, resources):
            let entry = NSMenuItem(title: name ?? "Ungrouped", action: nil, keyEquivalent: "")
            entry.toolTip = groupSummaryText(summary)
            let submenu = NSMenu()
            for resourceItem in MenuDescriptor.resourceItems(for: resources) {
                submenu.addItem(makeItem(resourceItem, instancePort: instancePort))
            }
            entry.submenu = submenu
            return entry

        case let .resource(name, health):
            let entry = NSMenuItem(title: name,
                                   action: #selector(focusResource(_:)),
                                   keyEquivalent: "").targeting(self)
            entry.image = dot(for: health)
            // Defensive only: `makeItem` never reaches this case without an
            // `instancePort` in practice, since `.resource` items only ever
            // come from `resourceItems(for:)` called above with one supplied.
            // Without a port to route to, disable rather than click to nowhere.
            if let instancePort {
                entry.representedObject = MenuFocusTarget(resourceName: name, port: instancePort)
            } else {
                entry.target = nil
                entry.action = nil
            }
            return entry

        case .openDashboard:
            return NSMenuItem(title: "Open Dashboard",
                              action: #selector(openDashboard),
                              keyEquivalent: "d").targeting(self)

        case let .openTiltfile(disabledReason):
            // `action: nil` is what actually disables this — see `unbuilt`'s
            // doc comment: `NSMenu.autoenablesItems` would silently
            // re-enable it if only `isEnabled` were set.
            let entry = NSMenuItem(title: "Open Tiltfile…",
                                   action: disabledReason == nil ? #selector(openTiltfile) : nil,
                                   keyEquivalent: "").targeting(self)
            entry.toolTip = disabledReason
            return entry

        case .recent:
            return unbuilt("Recent",
                           promise: "Projects you have run before, ready to restart. Not built yet.")

        case .settings:
            return NSMenuItem(title: "Settings…",
                              action: #selector(openSettings),
                              keyEquivalent: ",").targeting(self)

        case .quit:
            return NSMenuItem(title: "Quit Fulcrum",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        }
    }

    /// A group row's tooltip, tilt's own header shape (`×2 ⚙2 ⊘1 ✓45/49`) —
    /// error, pending, and disabled counts only when non-zero, rendered from
    /// the same `ResourceSummary` the dashboard's `GroupCounts` view draws, so
    /// the two cannot describe one rollup with two different vocabularies. A
    /// previous review found surfaces diverging over exactly this kind of
    /// per-surface count — see
    /// `theStatusStripAndTheGroupHeadersNeverReportDifferentCounts`.
    ///
    /// The `⊘` term is reachable, and this is where the menu differs from the
    /// dashboard on purpose: `MenuDescriptor` hands this every resource the
    /// instance has, disabled included, whereas the dashboard shows disabled
    /// rows only with *Show disabled* on. `⊘N` is precisely the difference
    /// between the two totals. See `MenuDescriptor.instanceGroups(for:)` for
    /// why the menu reports true totals rather than tracking a per-window
    /// filter it has no way to display — and note that the term shipped dead
    /// once, under a comment much like this one that claimed otherwise;
    /// `theMenusCountsMatchTheDashboardShowingEverything` is what now fails if
    /// it goes dead again.
    private func groupSummaryText(_ summary: ResourceSummary) -> String {
        var parts: [String] = []
        if summary.error > 0 { parts.append("×\(summary.error)") }
        if summary.pending > 0 { parts.append("⚙\(summary.pending)") }
        if summary.disabled > 0 { parts.append("⊘\(summary.disabled)") }
        parts.append("✓\(summary.healthy)/\(summary.total)")
        return parts.joined(separator: " ")
    }

    private func dot(for health: ResourceHealth?) -> NSImage? {
        guard let health else {
            // Not yet assessed — no resources have ever been listed for this
            // instance. Must render distinctly from every real health value,
            // not silently collapse into `.ok`'s green dot.
            return tinted("questionmark.circle", Theme.nsUnknown)
        }
        let symbol = switch health {
        case .error: "exclamationmark.triangle.fill"
        case .building: "circle.lefthalf.filled"
        case .pending: "circle.dashed"
        case .disabled: "circle"
        case .ok: "circle.fill"
        }
        return tinted(symbol, Theme.nsColor(for: health))
    }

    /// An SF Symbol in one of the app's status colours.
    ///
    /// `isTemplate = false` is the whole trick. `NSImage(systemSymbolName:)`
    /// hands back a template image, and AppKit renders those monochrome —
    /// which is mandatory for the status *item*'s own icon in the menu bar, but
    /// not for images inside menu *items*, where colour is allowed and carries
    /// the health at a glance. Leaving it templated is why these rendered as
    /// flat black circles.
    private func tinted(_ symbolName: String, _ color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    /// A feature whose plan has not landed yet. Shown rather than hidden so the menu's
    /// final shape is visible from the start, but labelled so it reads as "not yet"
    /// rather than "broken" — a permanently greyed item with no explanation is the
    /// worst of both.
    ///
    /// `action: nil` is what actually disables these: `NSMenu.autoenablesItems` is on
    /// by default and recomputes enablement at display time, so setting `isEnabled`
    /// here would be silently overwritten.
    private func unbuilt(_ title: String, promise: String) -> NSMenuItem {
        let entry = NSMenuItem(title: "\(title) — coming soon", action: nil, keyEquivalent: "")
        entry.toolTip = promise
        return entry
    }

    private func aboutItem() -> NSMenuItem {
        NSMenuItem(title: "About Fulcrum", action: #selector(showAbout), keyEquivalent: "").targeting(self)
    }

    private func checkForUpdatesItem() -> NSMenuItem {
        NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").targeting(self)
    }

    @objc private func openDashboard() {
        openDashboardAction()
    }

    @objc private func openTiltfile() {
        openTiltfileAction()
    }

    @objc private func showAbout() {
        aboutAction()
    }

    @objc private func checkForUpdates() {
        checkForUpdatesAction()
    }

    @objc private func focusResource(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MenuFocusTarget else { return }
        focusResourceAction(target.resourceName, target.port)
    }

    @objc private func selectInstance(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? Int else { return }
        selectInstanceAction(port)
    }

    /// `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` looks
    /// like the standard way to open a SwiftUI `Settings` scene, and it even returns
    /// `true` — some responder in the chain claims the selector — but in an
    /// `LSUIElement` accessory app built with `@NSApplicationDelegateAdaptor` no window
    /// ever appears. This was reproduced directly (not just suspected): same null
    /// result with `LSUIElement` false, with activate-then-send and send-then-activate,
    /// with the send deferred a run-loop turn, and after forcing `.regular` activation
    /// policy. Do not "simplify" this back to `sendAction` — it silently no-ops.
    ///
    /// The menu item SwiftUI actually installs for a `Settings` scene carries the
    /// action `menuAction:`, not `showSettingsWindow:`, so the reliable way to trigger
    /// it is to find that item in the app menu and invoke it directly.
    ///
    /// Matching by action is tried first because it is the only locale- and
    /// version-independent signal: pre-Sonoma macOS titles this item "Preferences…",
    /// and a localized build translates it. The title match is a fallback for the
    /// case where SwiftUI changes the selector out from under us. If both miss, this
    /// does nothing rather than crashing — a dead menu item beats a dead app.
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }

        let settingsAction = Selector(("menuAction:"))
        let index = appMenu.items.firstIndex { $0.action == settingsAction }
            ?? appMenu.items.firstIndex { item in
                item.title.hasPrefix("Settings") || item.title.hasPrefix("Preferences")
            }

        guard let index else { return }
        appMenu.performActionForItem(at: index)
    }
}

private extension NSMenuItem {
    func targeting(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}

/// Carried on a `.failure`/`.resource` `NSMenuItem`'s `representedObject` so
/// `focusResource(_:)` has both the resource name and the instance it
/// belongs to without re-parsing either out of a display string.
private struct MenuFocusTarget {
    let resourceName: String
    let port: Int
}
