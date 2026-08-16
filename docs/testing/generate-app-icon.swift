// Regenerates Fulcrum's macOS app icon in tilt's own logo greens, so the
// companion app reads as belonging to the tool it fronts.
//
//   #70D37B — tilt's lighter green (the logo's letterforms)
//   #20BA31 — tilt's darker green (the logo's notches), and already exactly
//             Fulcrum's dark-mode `status.healthy` role
//
// Draws into an explicit 1x NSBitmapImageRep rather than NSImage.lockFocus():
// on a Retina display lockFocus() gives a 2x backing store, so a 16pt image
// writes 32x32 pixels. The asset catalog compiler then rejects the whole icon
// set for mismatched dimensions — silently, which is how the first attempt
// shipped a placeholder icon with no build error at all.
import AppKit

let tiltLight = NSColor(srgbRed: 0.439, green: 0.827, blue: 0.482, alpha: 1)  // #70D37B
let tiltDeep = NSColor(srgbRed: 0.125, green: 0.729, blue: 0.192, alpha: 1)   // #20BA31

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("cannot allocate \(pixels)px bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)   // 1 point == 1 pixel

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

    let size = CGFloat(pixels)
    let scale = size / 1024.0
    // macOS Big Sur+ icon grid: art occupies 824/1024, corner radius 185/824.
    let inset = 100.0 * scale
    let side = 824.0 * scale
    let squircle = CGRect(x: inset, y: inset, width: side, height: side)

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: squircle, cornerWidth: 185.0 * scale,
                       cornerHeight: 185.0 * scale, transform: nil))
    ctx.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [tiltLight.cgColor, tiltDeep.cgColor] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: squircle.maxY),
                               end: CGPoint(x: 0, y: squircle.minY), options: [])
    }
    ctx.restoreGState()

    // The mark: a beam above a pivot, matching the logo.
    let cx = size / 2
    let markWidth = side * 0.62
    let beamHeight = side * 0.075
    let triHalf = markWidth / 2

    ctx.setFillColor(NSColor.white.cgColor)
    let beam = CGRect(x: cx - markWidth / 2, y: squircle.minY + side * 0.735,
                      width: markWidth, height: beamHeight)
    ctx.addPath(CGPath(roundedRect: beam, cornerWidth: beamHeight * 0.12,
                       cornerHeight: beamHeight * 0.12, transform: nil))
    ctx.fillPath()

    ctx.move(to: CGPoint(x: cx, y: squircle.minY + side * 0.615))
    ctx.addLine(to: CGPoint(x: cx + triHalf, y: squircle.minY + side * 0.20))
    ctx.addLine(to: CGPoint(x: cx - triHalf, y: squircle.minY + side * 0.20))
    ctx.closePath()
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = drawIcon(pixels: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("encode failed at \(pixels)px")
    }
    try! png.write(to: URL(fileURLWithPath: "\(out)/icon_\(pixels).png"))
    print("wrote icon_\(pixels).png at \(rep.pixelsWide)x\(rep.pixelsHigh) px")
}
