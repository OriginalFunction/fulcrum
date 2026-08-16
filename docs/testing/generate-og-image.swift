// Generates the social preview card for fulcrum.originalfunction.com.
//
// 1200x630 is the size Open Graph consumers (iMessage, Slack, X, LinkedIn)
// crop to; anything smaller gets upscaled and looks soft. Drawn rather than
// screenshotted so the wordmark and the app's own greens stay in step with
// docs/testing/generate-app-icon.swift.
//
// Uses an explicit 1x NSBitmapImageRep, not NSImage.lockFocus(): on a Retina
// display lockFocus() gives a 2x backing store, so the output would silently
// be 2400x1260.
import AppKit

let tiltLight = NSColor(srgbRed: 0.439, green: 0.827, blue: 0.482, alpha: 1)  // #70D37B
let tiltDeep = NSColor(srgbRed: 0.125, green: 0.729, blue: 0.192, alpha: 1)   // #20BA31
let page = NSColor(srgbRed: 0.055, green: 0.067, blue: 0.078, alpha: 1)       // #0E1114
let ink = NSColor(srgbRed: 0.929, green: 0.941, blue: 0.953, alpha: 1)        // #EDF0F3
let muted = NSColor(srgbRed: 0.596, green: 0.635, blue: 0.678, alpha: 1)      // #98A2AD

let W = 1200.0, H = 630.0

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("cannot allocate bitmap") }
rep.size = NSSize(width: W, height: H)   // 1 point == 1 pixel

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

ctx.setFillColor(page.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

// The mark, at the app icon's proportions: a beam above a pivot.
let side = 132.0
let markX = 96.0, markY = H - 96.0 - side
let squircle = CGRect(x: markX, y: markY, width: side, height: side)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: squircle, cornerWidth: side * 0.2245,
                   cornerHeight: side * 0.2245, transform: nil))
ctx.clip()
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [tiltLight.cgColor, tiltDeep.cgColor] as CFArray,
                             locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: squircle.maxY),
                           end: CGPoint(x: 0, y: squircle.minY), options: [])
}
ctx.restoreGState()

ctx.setFillColor(NSColor.white.cgColor)
let beamW = side * 0.62, beamH = side * 0.075
let cx = squircle.midX
let beam = CGRect(x: cx - beamW / 2, y: squircle.minY + side * 0.735,
                  width: beamW, height: beamH)
ctx.addPath(CGPath(roundedRect: beam, cornerWidth: beamH * 0.12,
                   cornerHeight: beamH * 0.12, transform: nil))
ctx.fillPath()
ctx.move(to: CGPoint(x: cx, y: squircle.minY + side * 0.615))
ctx.addLine(to: CGPoint(x: cx + beamW / 2, y: squircle.minY + side * 0.20))
ctx.addLine(to: CGPoint(x: cx - beamW / 2, y: squircle.minY + side * 0.20))
ctx.closePath()
ctx.fillPath()

func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight, colour: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: colour,
    ]
    NSAttributedString(string: text, attributes: attributes)
        .draw(at: NSPoint(x: x, y: y))
}

draw("Fulcrum", x: 96, y: 268, size: 104, weight: .bold, colour: ink)
draw("Your tilt instances, in the macOS menu bar.",
     x: 100, y: 196, size: 40, weight: .regular, colour: muted)
draw("Free · macOS 14 or later · Signed and notarized",
     x: 100, y: 96, size: 27, weight: .medium, colour: tiltLight)

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments[1]
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("encode failed")
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) at \(rep.pixelsWide)x\(rep.pixelsHigh) px")
