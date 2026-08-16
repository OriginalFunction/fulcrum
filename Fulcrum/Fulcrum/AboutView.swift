import SwiftUI
import AppKit

/// The status menu's "About Fulcrum" window: name, version, build number,
/// and a link to the download site — the first thirty seconds' way of
/// answering "what version am I running" when someone reports a problem.
/// Reachable only from the status menu (see `MenuBarController`), since
/// Fulcrum's own main menu bar exists solely while the dashboard window is
/// open — an accessory app has no other place this could live that is
/// always available.
struct AboutView: View {
    /// The app's home on the web — also where "Check for Updates…" sends the
    /// user. See `MenuBarController`'s doc comment on that command for why
    /// it opens this page rather than running an in-app auto-update.
    static let downloadPageURL = URL(string: "https://fulcrum.originalfunction.com")!

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
            }
            Text("Fulcrum")
                .font(.title2.weight(.semibold))
            Text("Version \(shortVersion) (\(buildNumber))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("fulcrum.originalfunction.com", destination: Self.downloadPageURL)
                .font(.callout)
        }
        .padding(24)
        .frame(width: 280)
    }
}
