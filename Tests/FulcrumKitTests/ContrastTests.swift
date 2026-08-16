import Foundation
import Testing

/// Guards the spec's Testing section: "an automated contrast assertion over
/// the asset catalog's semantic pairs — cheap and specifically prevents the
/// light-mode contrast problem from recurring." That problem recurred once
/// already on this branch (`text.secondary` shipped at 3.51:1 against white,
/// below the 4.5:1 floor) and was only caught by a human reading a contrast
/// table by hand.
///
/// This reads the asset catalog's `.colorset` JSON directly rather than
/// linking AppKit/SwiftUI — `FulcrumKit` must not import either, and the
/// colours are plain sRGB hex components on disk regardless.
///
/// Only text-shaped roles are asserted: `text.primary` and `text.secondary`
/// against `surface`, in both appearances. Status chip colours are
/// deliberately excluded — the spec exempts them, because a filled square
/// carries no text-contrast requirement.
enum ContrastFixtures {
    /// The asset catalog lives in the Xcode project, not the package, so it
    /// is reached via a path relative to this file rather than a package
    /// resource. If this ever proves too brittle (the app target's directory
    /// structure moves, or CI checks out the package alone without the
    /// Xcode project alongside it), the fix is to make the colours the
    /// source of truth in `FulcrumKit` itself — e.g. generate or hand-write
    /// a small Swift table the asset catalog is built from — rather than
    /// leaving this test silently unable to find its fixtures. A contrast
    /// test that cannot fail is worse than no test.
    static let colorsDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ContrastTests.swift -> FulcrumKitTests/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> repo root
            .appendingPathComponent("Fulcrum/Fulcrum/Assets.xcassets/Colors")
    }()

    struct SRGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// The two universal-idiom colours in a `.colorset`: the default (light)
    /// entry, and the one whose `appearances` names dark luminosity.
    static func lightAndDark(colorset name: String) throws -> (light: SRGB, dark: SRGB) {
        let url = colorsDirectory
            .appendingPathComponent("\(name).colorset")
            .appendingPathComponent("Contents.json")

        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("""
                Contrast fixture not found at \(url.path). This must fail loudly, \
                not silently pass with zero assertions — see ContrastFixtures.colorsDirectory.
                """)
            throw ContrastFixtureError.missing(url.path)
        }

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let colors = try #require(json?["colors"] as? [[String: Any]])

        var light: SRGB?
        var dark: SRGB?
        for entry in colors {
            guard let color = entry["color"] as? [String: Any],
                  let components = color["components"] as? [String: String],
                  let srgb = srgb(from: components)
            else { continue }

            let appearances = entry["appearances"] as? [[String: String]]
            let isDark = appearances?.contains {
                $0["appearance"] == "luminosity" && $0["value"] == "dark"
            } ?? false

            if isDark {
                dark = srgb
            } else {
                light = srgb
            }
        }

        guard let light, let dark else {
            Issue.record("'\(name)' colorset is missing a light or dark universal entry.")
            throw ContrastFixtureError.incomplete(name)
        }
        return (light, dark)
    }

    private static func srgb(from components: [String: String]) -> SRGB? {
        guard let red = hexComponent(components["red"]),
              let green = hexComponent(components["green"]),
              let blue = hexComponent(components["blue"])
        else { return nil }
        return SRGB(red: red, green: green, blue: blue)
    }

    private static func hexComponent(_ raw: String?) -> Double? {
        guard var raw else { return nil }
        if raw.hasPrefix("0x") { raw.removeFirst(2) }
        guard let value = UInt8(raw, radix: 16) else { return nil }
        return Double(value) / 255.0
    }

    enum ContrastFixtureError: Error {
        case missing(String)
        case incomplete(String)
    }

    /// WCAG 2.x relative luminance.
    static func relativeLuminance(_ color: SRGB) -> Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(color.red)
             + 0.7152 * linearize(color.green)
             + 0.0722 * linearize(color.blue)
    }

    /// WCAG 2.x contrast ratio: the lighter luminance over the darker, both
    /// offset by 0.05, always >= 1.
    static func contrastRatio(_ a: SRGB, _ b: SRGB) -> Double {
        let lumA = relativeLuminance(a)
        let lumB = relativeLuminance(b)
        let lighter = max(lumA, lumB)
        let darker = min(lumA, lumB)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// The spec's floor for body text.
private let minimumTextContrast = 4.5

@Test func textPrimaryMeetsContrastFloorAgainstSurfaceInLightMode() throws {
    let text = try ContrastFixtures.lightAndDark(colorset: "text.primary")
    let surface = try ContrastFixtures.lightAndDark(colorset: "surface")
    let ratio = ContrastFixtures.contrastRatio(text.light, surface.light)
    #expect(ratio >= minimumTextContrast, "text.primary vs surface, light: \(ratio):1")
}

@Test func textPrimaryMeetsContrastFloorAgainstSurfaceInDarkMode() throws {
    let text = try ContrastFixtures.lightAndDark(colorset: "text.primary")
    let surface = try ContrastFixtures.lightAndDark(colorset: "surface")
    let ratio = ContrastFixtures.contrastRatio(text.dark, surface.dark)
    #expect(ratio >= minimumTextContrast, "text.primary vs surface, dark: \(ratio):1")
}

@Test func textSecondaryMeetsContrastFloorAgainstSurfaceInLightMode() throws {
    let text = try ContrastFixtures.lightAndDark(colorset: "text.secondary")
    let surface = try ContrastFixtures.lightAndDark(colorset: "surface")
    let ratio = ContrastFixtures.contrastRatio(text.light, surface.light)
    #expect(ratio >= minimumTextContrast, "text.secondary vs surface, light: \(ratio):1")
}

@Test func textSecondaryMeetsContrastFloorAgainstSurfaceInDarkMode() throws {
    let text = try ContrastFixtures.lightAndDark(colorset: "text.secondary")
    let surface = try ContrastFixtures.lightAndDark(colorset: "surface")
    let ratio = ContrastFixtures.contrastRatio(text.dark, surface.dark)
    #expect(ratio >= minimumTextContrast, "text.secondary vs surface, dark: \(ratio):1")
}
