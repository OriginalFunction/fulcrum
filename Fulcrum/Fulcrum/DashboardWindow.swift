import SwiftUI
import FulcrumKit

/// The dashboard: projects on the left, the selected project's resources on the
/// right, aggregate counts along the bottom, and — below the resource table,
/// in a resizable split — that project's live log pane.
struct DashboardWindow: View {
    @Bindable var dashboard: DashboardModel
    let settings: SettingsStore
    let actionCoordinator: ResourceActionCoordinator
    let instanceActionCoordinator: InstanceActionCoordinator
    /// Reused, not recreated, so "Start" on a Recent row goes through the
    /// same launch path as the status menu's Open Tiltfile command.
    let tiltLauncher: TiltLauncher

    var body: some View {
        NavigationSplitView {
            SidebarView(dashboard: dashboard, instanceActionCoordinator: instanceActionCoordinator, tiltLauncher: tiltLauncher)
                .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 260)
        } detail: {
            VStack(spacing: 0) {
                InstanceToolbarView(dashboard: dashboard, actionCoordinator: instanceActionCoordinator)
                FilterBarView(dashboard: dashboard)
                VSplitView {
                    ResourceTableView(dashboard: dashboard, actionCoordinator: actionCoordinator)
                        .frame(minHeight: 120)
                    logPane
                        .frame(minHeight: 100, idealHeight: settings.logPaneHeight)
                }
                StatusStripView(dashboard: dashboard)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
        // Appearance is driven solely by DashboardWindowController.observeAppearance()
        // setting NSWindow.appearance. A `.preferredColorScheme` here looks like it would
        // help but breaks the explicit -> System transition: it clears the window's
        // appearance so the chrome follows the system, while the hosted content's body is
        // never re-evaluated and keeps the old scheme. Verified at pixel level.
        //
        // `instanceActionCoordinator.lastFailure` is bound to exactly ONE `.alert`,
        // here at the window level — both `InstanceToolbarView` and `SidebarView`
        // trigger actions on the same coordinator, and binding `.alert` to the same
        // `lastFailure` in both of them (as an earlier version of this did) meant one
        // failure flipped two `isPresented` bindings at once: SwiftUI drops or logs
        // the second presentation, and whichever alert wins calls `clearFailure()`
        // out from under the other. One binding, at the one ancestor common to both,
        // is what makes that structurally impossible instead of just unlikely.
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { instanceActionCoordinator.lastFailure != nil },
                set: { isPresented in if !isPresented { instanceActionCoordinator.clearFailure() } }
            )
        ) {
            Button("OK", role: .cancel) { instanceActionCoordinator.clearFailure() }
        } message: {
            Text(instanceActionCoordinator.lastFailure?.message ?? "")
        }
    }

    /// `LogPaneView` wrapped in a `GeometryReader` that mirrors its rendered
    /// height back into `settings.logPaneHeight` on every change — the only
    /// signal available for "the divider moved": `VSplitView` (SwiftUI's
    /// bridge onto `NSSplitView`) exposes no drag-completion callback of its
    /// own, but a subview's rendered height does change, live, as the user
    /// drags. `idealHeight: settings.logPaneHeight` above is what feeds this
    /// back in on the next launch — the same read-back-on-resize,
    /// seed-on-launch shape `setFrameAutosaveName` uses for the window itself
    /// in `DashboardWindowController`, just without an AppKit-level API to
    /// hand it to.
    private var logPane: some View {
        GeometryReader { geometry in
            LogPaneView(dashboard: dashboard, settings: settings)
                .onChange(of: geometry.size.height) { _, newHeight in
                    settings.logPaneHeight = newHeight
                }
        }
    }
}
