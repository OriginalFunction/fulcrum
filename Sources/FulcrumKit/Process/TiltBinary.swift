import Foundation

/// Locates the `tilt` executable without trusting the process's inherited `PATH`.
///
/// A GUI app launched from Finder or the Dock inherits launchd's `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), which excludes `/opt/homebrew/bin` — where
/// Homebrew installs `tilt` on Apple Silicon. Launching Fulcrum from a terminal
/// masks this because the terminal's shell `PATH` is inherited instead. Every
/// action that shells out to `tilt` depends on this resolving correctly.
public enum TiltBinary {
    /// Search order: `FULCRUM_TILT_PATH` override, then each `PATH` entry in
    /// order, then the known-good fallbacks. The first existing file wins. An
    /// override pointing at a nonexistent file does not mask a real install
    /// further down the search order.
    ///
    /// Both dependencies are injected so the search order is testable without
    /// touching the real disk or process environment.
    public static func locate(
        fileExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
            // A directory named `tilt` sitting on `PATH` is not an executable;
            // treating it as a match would select it here and only fail
            // confusingly later, when `Process` tries to launch it.
            return !isDirectory.boolValue
        },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["FULCRUM_TILT_PATH"], fileExists(override) {
            return URL(fileURLWithPath: override)
        }

        let pathEntries = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in pathEntries {
            let candidate = directory + "/tilt"
            if fileExists(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        var fallbacks = ["/opt/homebrew/bin/tilt", "/usr/local/bin/tilt"]
        if let home = environment["HOME"] {
            fallbacks.append(home + "/.local/bin/tilt")
        }

        for candidate in fallbacks {
            if fileExists(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }
}
