import AppKit
import SwiftUI
import FulcrumKit

/// The app's semantic colour roles.
///
/// Every colour in the UI resolves through here, and every role has a light and
/// a dark variant in the asset catalog. That is what makes System mode free:
/// views never name a hex value, so the system swaps the whole palette when the
/// appearance changes without any code path being involved.
///
/// Dark borrows tilt's own palette so the two tools agree on what green means.
/// Light is derived rather than reused, because tilt's green measures about
/// 2.4:1 on white against a 4.5:1 floor for text.
// Colours are looked up via the compiler-generated `ColorResource` symbols
// (`Color(.surface)`, not `Color("surface")`). A misspelled string literal
// compiles cleanly and silently renders an undefined colour at runtime — the
// same silent-failure shape that shipped a placeholder app icon to
// Applications twice on this project. A misspelled generated symbol is a
// build error instead. Do not "simplify" this back to string lookups.
enum Theme {
    static let surface = Color(.surface)
    static let chrome = Color(.chrome)
    static let separator = Color(.separator)
    static let textPrimary = Color(.textPrimary)
    static let textSecondary = Color(.textSecondary)

    static func color(for health: ResourceHealth) -> Color {
        switch health {
        case .error: Color(.statusError)
        case .building: Color(.statusBuilding)
        case .pending: Color(.statusPending)
        case .ok: Color(.statusHealthy)
        case .disabled: Color(.statusDisabled)
        }
    }

    /// A project that is not running. Deliberately shares `status.disabled`'s grey:
    /// both mean "no signal", and they never appear in the same list — `nil` health
    /// is a sidebar/project state, `.disabled` a table/resource one. Distinct from
    /// healthy, which is the distinction that has needed fixing twice here.
    static let unknown = Color(.statusDisabled)

    /// A project whose recorded Tiltfile is no longer on disk (see
    /// `TiltfileLinkState.broken`). Reuses the EXISTING `status.error` role
    /// rather than adding a colour: a missing Tiltfile is a fault the user
    /// has to fix, which is the same thing red already means everywhere else
    /// in this app, and a new role would need light and dark variants
    /// verified in the compiled `Assets.car` — a silently-discarded asset set
    /// has shipped here twice. Distinct from both `color(for: .ok)`'s green
    /// and `unknown`'s grey, which is the distinction that matters on a
    /// stopped row.
    static let broken = Color(.statusError)

    /// The row background for a resource the menu bar just jumped the user
    /// to. `Color.accentColor` rather than one of the status colours above —
    /// this is a navigation cue, not a health signal, and reusing e.g.
    /// `.statusBuilding`'s amber would read as "this resource is building"
    /// to anyone who has learned the table's own colour language.
    static let focusHighlight = Color.accentColor.opacity(0.18)

    /// A log line's severity tint, reusing the identical `statusError`/
    /// `statusPending` assets `color(for:)` uses for resource health — both
    /// domains mean the same thing by "error" and "warning", so this is a
    /// second call site for those roles, not a second set of assets.
    static func color(for level: LogLevel) -> Color {
        switch level {
        case .error: Color(.statusError)
        case .warn: Color(.statusPending)
        case .info, .other: textSecondary
        }
    }

    /// Maps an ANSI SGR colour (`ANSI.parse(_:)`'s `Span.colour`) to a
    /// dashboard colour role, for the log pane's `AttributedString`
    /// rendering (see `LogPaneView`). `nil` — no SGR colour set — and
    /// black/white both resolve to the pane's own ordinary text roles rather
    /// than new assets: build-tool output that never colours a line should
    /// look like ordinary log text, in both appearances, not like something
    /// this mapping forgot. The six new `ansi.*` assets exist only for the
    /// six hues without an existing role to reuse (red/green/yellow/blue
    /// already have one via `color(for:)`'s two overloads above; magenta and
    /// cyan did not). "Bright" variants collapse onto the same role as their
    /// standard counterpart — this pane distinguishes ANSI *hues*, not the
    /// standard/bright intensity split, which real tilt build output does
    /// not lean on for meaning.
    static func color(forAnsi colour: ANSI.Colour?) -> Color {
        switch colour {
        case nil, .white, .brightWhite: textPrimary
        case .black, .brightBlack: textSecondary
        case .red, .brightRed: Color(.ansiRed)
        case .green, .brightGreen: Color(.ansiGreen)
        case .yellow, .brightYellow: Color(.ansiYellow)
        case .blue, .brightBlue: Color(.ansiBlue)
        case .magenta, .brightMagenta: Color(.ansiMagenta)
        case .cyan, .brightCyan: Color(.ansiCyan)
        }
    }

    /// The same roles as `color(for:)`, as `NSColor`, for AppKit surfaces —
    /// currently the status dots in the menu bar's menus.
    ///
    /// Resolved from the identical asset-catalog entries through the generated
    /// `ColorResource` symbols, so the two colour languages cannot drift: a menu
    /// dot and its table row always agree on what green means, in both
    /// appearances.
    static func nsColor(for health: ResourceHealth) -> NSColor {
        switch health {
        case .error: NSColor(resource: .statusError)
        case .building: NSColor(resource: .statusBuilding)
        case .pending: NSColor(resource: .statusPending)
        case .ok: NSColor(resource: .statusHealthy)
        case .disabled: NSColor(resource: .statusDisabled)
        }
    }

    /// A project with no health signal yet. Mirrors `unknown` above.
    static let nsUnknown = NSColor(resource: .statusDisabled)
}

extension AppearanceMode {
    /// Drives both the window's chrome and, via `NSHostingView`'s inherited
    /// `effectiveAppearance`, its hosted SwiftUI content — see
    /// `DashboardWindowController.observeAppearance()`, the sole appearance path.
    /// nil means "follow the system".
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }

    /// The Settings window's own appearance path — NOT `nsAppearance` above.
    /// `DashboardWindowController` owns a raw `NSWindow` it constructs itself
    /// (see that type's doc comment on why: `openWindowWithID:` and
    /// `showSettingsWindow:` have both been reproduced silently no-op'ing on
    /// this project), so it has to set `.appearance` on that window by hand.
    /// Settings is different: it is a genuine SwiftUI `Settings` scene
    /// (`FulcrumApp.body`), reached only by finding and invoking the app
    /// menu's own "Settings…" item (`MenuBarController.openSettings`) —
    /// there is no `NSWindow` this app ever constructs or holds a reference
    /// to for it. `preferredColorScheme(_:)` is that scene's own equivalent:
    /// per Apple's documentation it "propagates the value up through the
    /// view hierarchy to the enclosing presentation, like a sheet or a
    /// window," which for a `Settings` scene's root view is the window
    /// SwiftUI creates on our behalf. `nil` means "follow the system", same
    /// as `nsAppearance` above.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}
