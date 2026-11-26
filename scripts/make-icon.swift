// Renders the ClaudeThermal logo.
//   swift scripts/make-icon.swift
// Writes assets/logo.png (1024px) and Resources/AppIcon.icns.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }

        // macOS-style rounded tile
        let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let drop = NSShadow()
        drop.shadowColor = NSColor.black.withAlphaComponent(0.35)
        drop.shadowBlurRadius = 28 * s
        drop.shadowOffset = NSSize(width: 0, height: -12 * s)
        drop.set()
        NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
            NSColor(srgbRed: 0.06, green: 0.06, blue: 0.09, alpha: 1),
        ])?.draw(in: tile, angle: -90)
        // Warm bloom behind the pill
        NSGradient(colors: [
            NSColor(srgbRed: 1.0, green: 0.35, blue: 0.18, alpha: 0.38),
            NSColor(srgbRed: 1.0, green: 0.35, blue: 0.18, alpha: 0),
        ])?.draw(fromCenter: NSPoint(x: 512 * s, y: 380 * s), radius: 0,
                 toCenter: NSPoint(x: 512 * s, y: 380 * s), radius: 420 * s, options: [])
        NSGraphicsContext.restoreGraphicsState()

        // The pill
        let body = r(382, 222, 260, 580)
        let outline = NSBezierPath(roundedRect: body, xRadius: 130 * s, yRadius: 130 * s)
        outline.lineWidth = 24 * s

        let inner = body.insetBy(dx: 44 * s, dy: 44 * s)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: inner.width / 2, yRadius: inner.width / 2)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * 0.72)

        // Glow
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor(srgbRed: 1.0, green: 0.25, blue: 0.2, alpha: 0.9)
        glow.shadowBlurRadius = 70 * s
        glow.shadowOffset = .zero
        glow.set()
        innerPath.addClip()
        NSColor(srgbRed: 1.0, green: 0.3, blue: 0.2, alpha: 1).setFill()
        fill.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Heat gradient fill: crimson at the bottom, amber, then honey
        NSGraphicsContext.saveGraphicsState()
        innerPath.addClip()
        NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 0.86, green: 0.05, blue: 0.20, alpha: 1), 0.0),
            (NSColor(srgbRed: 1.00, green: 0.32, blue: 0.20, alpha: 1), 0.40),
            (NSColor(srgbRed: 1.00, green: 0.58, blue: 0.14, alpha: 1), 0.75),
            (NSColor(srgbRed: 1.00, green: 0.80, blue: 0.30, alpha: 1), 1.0)
        )?.draw(in: fill, angle: 90)
        // Specular stripe
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX + inner.width * 0.18, y: inner.minY + 20 * s,
                                         width: inner.width * 0.16, height: fill.height - 40 * s),
                     xRadius: 12 * s, yRadius: 12 * s).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        outline.stroke()
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
try fm.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
try png(drawIcon(size: 1024), pixels: 1024).write(to: root.appendingPathComponent("assets/logo.png"))

let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(drawIcon(size: CGFloat(base)), pixels: base)
        .write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(drawIcon(size: CGFloat(base * 2)), pixels: base * 2)
        .write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote assets/logo.png and Resources/AppIcon.icns" : "iconutil failed")
