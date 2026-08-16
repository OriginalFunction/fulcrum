import AppKit
import FulcrumKit

/// The one place a Tiltfile gets opened and launched from Fulcrum.
///
/// Three surfaces reach this: the status menu's "Open Tiltfile…" (the
/// always-available one — Fulcrum is an accessory app whose main menu bar
/// only exists while the dashboard window is open), the app menu's ⌘O for
/// when the dashboard is open, and the sidebar's "Start" on a Recent row.
/// All three call `launch(tiltfilePath:using:)` — there is exactly one
/// launch path, and exactly one place a failure becomes an alert, so the
/// three can never drift into showing different copy for the same
/// `TiltLaunchError`.
@MainActor
enum OpenTiltfileCommand {
    private static let lastDirectoryKey = "OpenTiltfileCommand.lastDirectory"

    /// Presents a panel restricted to files literally named `Tiltfile` or
    /// ending `.Tiltfile` (tilt's own convention for a secondary Tiltfile,
    /// e.g. `docs/testing/jsonlab.Tiltfile`), defaulting to the last
    /// directory a Tiltfile was opened from. Returns `nil` if the user
    /// cancelled.
    ///
    /// `.runModal()`, not a sheet: the status menu's call site has no window
    /// to attach a sheet to, and the app-menu ⌘O call site should behave
    /// identically rather than the panel's presentation depending on which
    /// of the two triggered it.
    static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a Tiltfile"
        // `NSOpenPanel` has no "filename glob" filter API — `allowedContentTypes`
        // matches by UTI/extension, and neither fits an extensionless file
        // named exactly `Tiltfile`. Filtering the displayed listing directly,
        // via the delegate, is the mechanism that actually exists for this.
        panel.delegate = TiltfilePanelDelegate.shared
        if let lastDirectory {
            panel.directoryURL = lastDirectory
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        lastDirectory = url.deletingLastPathComponent()
        return url
    }

    /// Launches `tiltfilePath` through `launcher` and, on failure, reports
    /// the cause visibly rather than doing nothing — this project's
    /// recurring failure mode. The message comes from
    /// `tiltActionFailureMessage(for:)`, the single mapping shared with
    /// `ResourceActionCoordinator` and `InstanceActionCoordinator`, so a
    /// `TiltLaunchError` reads with the same care as any `TiltActionError`
    /// (tilt's own stderr, verbatim, for the busy-port race) without a
    /// second, parallel mapping to keep in sync.
    ///
    /// A plain modal `NSAlert` (mirroring `presentConfirmation` in
    /// `InstanceToolbarView.swift`) rather than a SwiftUI `.alert` bound to
    /// some view's state: the status menu's call site may have no dashboard
    /// window mounted at all, so an alert that only works when a window's
    /// view happens to be presented is not "an alert on failure", it is
    /// "an alert on failure sometimes."
    static func launch(tiltfilePath: String, using launcher: TiltLauncher) async {
        do {
            try await launcher.launch(tiltfilePath: tiltfilePath)
        } catch {
            presentFailureAlert(for: error)
        }
    }

    private static func presentFailureAlert(for error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't Start Tilt"
        alert.informativeText = tiltActionFailureMessage(for: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static var lastDirectory: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: lastDirectoryKey) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: lastDirectoryKey) }
    }
}

/// Restricts `NSOpenPanel`'s listing to `Tiltfile` itself, anything ending
/// `.Tiltfile`, or a directory (so the user can still navigate into one).
/// A stateless singleton: the delegate only ever answers this one yes/no
/// question, so one instance can back every panel `presentOpenPanel()`
/// shows without needing a fresh one per call.
@MainActor
private final class TiltfilePanelDelegate: NSObject, NSOpenSavePanelDelegate {
    static let shared = TiltfilePanelDelegate()

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue { return true }
        let name = url.lastPathComponent
        return name == "Tiltfile" || name.hasSuffix(".Tiltfile")
    }
}
