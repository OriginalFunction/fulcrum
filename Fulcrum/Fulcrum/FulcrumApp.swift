import SwiftUI
import AppKit
import FulcrumKit

@main
struct FulcrumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(settings: delegate.settings,
                         notificationPresenter: delegate.notificationPresenter,
                         notifications: delegate.notifications)
        }
        // The only `Scene` in this app is `Settings` — there is no
        // `WindowGroup`, so this is the sole place SwiftUI's own command
        // machinery has to attach the app's standard File menu to. Replacing
        // `.newItem` (File > New, normally Cmd+N) rather than adding a fresh
        // `CommandMenu` is what makes a File menu with real content exist at
        // all; an empty `CommandGroup` addition to an unused menu would not
        // surface one. This is a real SwiftUI `Button` action, wired by
        // SwiftUI itself — not `NSApp.sendAction`, which has silently
        // no-op'd on this project before (see `MenuBarController.openSettings`).
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Tiltfile…") {
                    delegate.openTiltfilePanelAndLaunch()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    private lazy var model = AppModel(settings: settings)
    let recents = RecentsStore(storage: RecentsStore.defaultStorage())
    private(set) lazy var dashboard = DashboardModel(appModel: model, recents: recents)
    /// Located once and shared by both coordinators below — `TiltBinary.locate()`
    /// walks `PATH` and a handful of fallback locations, and there is no reason
    /// to repeat that work (or log "tilt binary not found" twice) for two
    /// coordinators that both need the same answer.
    private lazy var tiltActions = makeTiltActions()
    /// Row actions (trigger, enable/disable) go through this. `TiltActions`
    /// is nil when `TiltBinary.locate()` finds no tilt install — the
    /// coordinator turns that into every action control disabling itself
    /// rather than the app crashing or silently no-oping on click.
    private(set) lazy var actionCoordinator = ResourceActionCoordinator(actions: tiltActions)
    /// Instance-level actions (reload Tiltfile, enable/disable all, Tilt
    /// Down) for the dashboard's toolbar and the sidebar's context menu.
    private(set) lazy var instanceActionCoordinator = InstanceActionCoordinator(actions: tiltActions)
    /// Starts a new `tilt up`. One instance shared by the status menu's Open
    /// Tiltfile command, the app menu's ⌘O, and the sidebar's "Start" on a
    /// Recent row (`SidebarView`, via `DashboardWindowController` /
    /// `DashboardWindow`) — there is exactly one launch path, not one per
    /// call site.
    private let tiltLauncher = TiltLauncher()
    /// The `UserNotifications` half of the notification feature — see
    /// `NotificationPresenter`. Held here for the app's whole lifetime
    /// because it owns the `UNUserNotificationCenter` delegate, which that
    /// class holds strongly and the center itself holds only weakly.
    private(set) lazy var notificationPresenter = NotificationPresenter()
    /// Decides what actually gets delivered, when the permission prompt is
    /// allowed to appear, and where a click lands. Fed from
    /// `InstanceSupervisor.onResourcesUpdated` in `reconcile(with:)` — the
    /// app's existing observation path, not a second polling loop.
    private(set) lazy var notifications = NotificationCoordinator(
        settings: settings,
        delivering: notificationPresenter,
        isViewingInstance: { [weak self] port in self?.isViewingInstance(port) ?? false },
        focusResource: { [weak self] resourceName, port in
            self?.focusResource(named: resourceName, onInstanceWithPort: port)
        }
    )
    /// Owns `NSApp.setActivationPolicy` for the whole app. Both window
    /// controllers report their opens and closes into it rather than flipping
    /// the policy themselves, so neither can drop the Dock icon out from under
    /// the other — and neither has to guess whether a window that is currently
    /// closing still counts. See `WindowPresence`.
    private let activationPolicy = ActivationPolicyController()
    private(set) lazy var dashboardWindow = DashboardWindowController(
        dashboard: dashboard,
        settings: settings,
        actionCoordinator: actionCoordinator,
        instanceActionCoordinator: instanceActionCoordinator,
        tiltLauncher: tiltLauncher,
        activationPolicy: activationPolicy
    )
    /// The About window — see `AboutView`/`AboutWindowController`. Created
    /// lazily on first "About Fulcrum" click, same as `dashboardWindow`.
    private lazy var aboutWindow = AboutWindowController(activationPolicy: activationPolicy)
    private var menuBar: MenuBarController?
    private var discovery: Discovery?
    private var supervisors: [TiltInstance.InstanceID: InstanceSupervisor] = [:]
    private var discoveryTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Installs the notification-click delegate and READS the current
        // permission. It does not request one — see `NotificationPresenter.start()`
        // and `NotificationCoordinator`'s doc comment on why a prompt at
        // launch is the one thing this feature must never do.
        notificationPresenter.start()
        notificationPresenter.onActivation = { [weak self] target in
            self?.notifications.handleActivation(target)
        }

        // Forces `tiltActions` (lazy) to resolve now, off the one search it
        // already performs — see its own doc comment — rather than this
        // running a second, independent `TiltBinary.locate()`. Feeds the
        // status menu's "tilt not installed" vs "installed, nothing
        // running" distinction; see `AppModel.tiltInstalled`.
        model.tiltInstalled = tiltActions != nil

        menuBar = MenuBarController(
            model: model,
            openDashboardAction: { [weak self] in
                self?.dashboardWindow.show()
            },
            focusResourceAction: { [weak self] resourceName, port in
                self?.focusResource(named: resourceName, onInstanceWithPort: port)
            },
            selectInstanceAction: { [weak self] port in
                self?.dashboard.selectedSidebarID = "port-\(port)"
                self?.dashboardWindow.show()
            },
            openTiltfileAction: { [weak self] in
                self?.openTiltfilePanelAndLaunch()
            },
            aboutAction: { [weak self] in
                self?.aboutWindow.show()
            },
            checkForUpdatesAction: {
                // Deliberately NOT Sparkle — see `MenuBarController`'s doc
                // comment on the "Check for Updates…" item for why.
                NSWorkspace.shared.open(AboutView.downloadPageURL)
            }
        )
        startDiscovery()
    }

    /// The app's one and only "take me to this resource" route: select the
    /// instance, clear anything hiding the row, point the log pane at it, and
    /// bring the dashboard forward. Both the status menu's failure rows and a
    /// clicked notification come through here, rather than each assembling
    /// its own version — a second selection concept has already caused a real
    /// bug on this project.
    private func focusResource(named resourceName: String, onInstanceWithPort port: Int) {
        dashboard.focus(resource: resourceName, onInstanceWithPort: port)
        dashboardWindow.show()
    }

    /// Whether the user is, right now, looking at the project running on
    /// `port` — the dashboard frontmost in an active app, showing that
    /// instance. `NotificationCoordinator` suppresses notifications for it;
    /// see its doc comment for why the bar is this high and not merely "a
    /// window is open somewhere".
    private func isViewingInstance(_ port: Int) -> Bool {
        dashboardWindow.isFrontmost && dashboard.selectedInstance?.webPort == port
    }

    /// Re-reads the notification permission whenever Fulcrum comes forward.
    /// macOS never tells an app that its permission changed, so without this
    /// the Settings pane could keep showing a denial notice the user has just
    /// resolved (or, worse, stay silent about one they just created).
    func applicationDidBecomeActive(_ notification: Notification) {
        notificationPresenter.refreshAuthorization()
    }

    /// Presents the Tiltfile-open panel and, if the user chose one, starts
    /// it — the one entry point both the status menu's "Open Tiltfile…" and
    /// the app menu's ⌘O call, so there is exactly one launch path rather
    /// than each wiring up its own. See `OpenTiltfileCommand`.
    func openTiltfilePanelAndLaunch() {
        guard let url = OpenTiltfileCommand.presentOpenPanel() else { return }
        Task { await OpenTiltfileCommand.launch(tiltfilePath: url.path, using: tiltLauncher) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        discoveryTask?.cancel()
        supervisors.values.forEach { $0.stop() }
        // The log pane's `tilt logs --follow` child is not a supervisor and
        // outlives the dashboard window closing (it survives that too, until
        // `DashboardWindowController.windowWillClose` stops it) — quitting
        // must stop it explicitly or it leaks past the app's own exit.
        dashboard.logPane.follow(nil)
    }

    /// Locates `tilt` and builds the real, process-shelling `TiltActions`, or
    /// returns nil when no install was found. Logged rather than surfaced as
    /// a UI error at launch — the dashboard row controls are where a user
    /// actually notices and needs to act on this, via
    /// `ResourceActionCoordinator.isAvailable`.
    private func makeTiltActions() -> TiltActions? {
        guard let binary = TiltBinary.locate() else {
            NSLog("Fulcrum: tilt binary not found — resource actions are disabled")
            return nil
        }
        return TiltActions(runner: ProcessCommandRunner(), binary: binary)
    }

    private func startDiscovery() {
        guard let watcher = DispatchSourceConfigWatcher() else {
            NSLog("Fulcrum: cannot watch ~/.tilt-dev — is tilt installed?")
            return
        }
        let discovery = Discovery(watcher: watcher, probe: HTTPLivenessProbe())
        self.discovery = discovery

        // `[weak self]`, with `self` re-derived inside the loop, matching
        // `Discovery.start()` and `InstanceSupervisor.start()`. This task
        // spends nearly all its life suspended on `discovery.stream`, and a
        // strong capture would hold `AppDelegate` alive across every one of
        // those suspensions. Harmless today only because `AppDelegate` is
        // immortal — which is exactly the reasoning that let a retain cycle of
        // this shape ship on this project once already, so the shape does not
        // get to stay just because this instance happens to survive.
        discoveryTask = Task { @MainActor [weak self] in
            await discovery.start()
            let initial = await discovery.instances()
            self?.reconcile(with: initial)
            for await instances in discovery.stream {
                // Re-derived per iteration, not bound once above the loop: a
                // single `guard let self` outside would hold a strong
                // reference for the whole loop and be no better than the
                // strong capture it replaced.
                guard let self else { return }
                self.reconcile(with: instances)
            }
        }
    }

    /// Keeps one supervisor alive per store, started and stopped with it.
    private func reconcile(with instances: [TiltInstance]) {
        // Anything we ever see gets remembered, including projects started from a
        // terminal, so the sidebar's Recent section fills itself.
        instances.forEach(recents.remember)

        model.sync(with: instances)
        // `model.sync(with:)` just resolved `dashboard.selectedInstance` fresh
        // against the new instance set — if the log pane's followed instance
        // was the one that just disappeared (or the whole project stopped),
        // this re-points it (or stops it) immediately, rather than leaving a
        // `tilt logs --follow` child running for a project that's gone until
        // the dashboard window's view next happens to re-render.
        dashboard.followSelectedInstanceLogs()

        let liveIDs = Set(instances.map(\.id))
        for (id, supervisor) in supervisors where !liveIDs.contains(id) {
            supervisor.stop()
            supervisors.removeValue(forKey: id)
        }
        for store in model.stores where supervisors[store.instance.id] == nil {
            let port = store.instance.webPort
            // Mirrors a resolved project name into Recent so a stopped
            // project keeps showing it — there is no live apiserver left to
            // re-ask once the instance is gone.
            let supervisor = InstanceSupervisor(
                store: store,
                // Every applied list and every watch event, straight into the
                // notification decision. The alias-aware display name is used
                // so the banner calls the project what the user calls it.
                onResourcesUpdated: { [weak self] updated in
                    guard let self else { return }
                    notifications.observe(
                        resources: updated.resources,
                        forPort: updated.instance.webPort,
                        instanceName: updated.displayName(aliases: model.aliases)
                    )
                },
                onResolved: { [weak self] path, name in
                    self?.recents.updateResolvedName(name, tiltfilePath: path, forPort: port)
                }
            )
            supervisors[store.instance.id] = supervisor
            supervisor.start()
        }
    }
}
