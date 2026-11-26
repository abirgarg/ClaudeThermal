import AppKit

/// Draws the 8×16pt Control Center–style capsule for the menu bar.
///
/// The image uses a drawing handler, so AppKit rasterizes it at the exact backing
/// scale of whichever display the menu bar is on (crisp on retina and non-retina),
/// and caches the result. We only build a new NSImage when the integer percent changes.
enum PillRenderer {
    static let capsule = NSSize(width: 8, height: 16)
    /// Room around the capsule for the overheat glow.
    static let padding: CGFloat = 3

    static func image(fraction raw: Double) -> NSImage {
        let fraction = min(max(raw, 0), 1)
        let size = NSSize(width: capsule.width + padding * 2, height: capsule.height + padding * 2)
        let style = ThermalPalette.style(for: fraction)

        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: padding, y: padding, width: capsule.width, height: capsule.height)
            let outlinePath = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                                           xRadius: (capsule.width - 1) / 2, yRadius: (capsule.width - 1) / 2)
            outlinePath.lineWidth = 1

            let inner = body.insetBy(dx: 2, dy: 2)
            let innerPath = NSBezierPath(roundedRect: inner, xRadius: inner.width / 2, yRadius: inner.width / 2)
            let fillHeight = fraction > 0 ? max(inner.height * fraction, 1.5) : 0
            let fillRect = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: fillHeight)

            switch style {
            case .template:
                NSColor.black.withAlphaComponent(0.9).setStroke()
                outlinePath.stroke()
                if fillHeight > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    innerPath.addClip()
                    NSColor.black.setFill()
                    fillRect.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }

            case let .heat(color, glow):
                NSGraphicsContext.saveGraphicsState()
                if glow > 0 {
                    let shadow = NSShadow()
                    shadow.shadowColor = color.withAlphaComponent(0.55 + 0.4 * glow)
                    shadow.shadowBlurRadius = 1.5 + 2 * glow
                    shadow.shadowOffset = .zero
                    shadow.set()
                }
                color.withAlphaComponent(0.95).setStroke()
                outlinePath.stroke()
                NSGraphicsContext.restoreGraphicsState()

                NSGraphicsContext.saveGraphicsState()
                innerPath.addClip()
                let top = color.blended(withFraction: 0.25, of: .white) ?? color
                let bottom = color.blended(withFraction: 0.15, of: .black) ?? color
                NSGradient(starting: bottom, ending: top)?.draw(in: fillRect, angle: 90)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = style.isTemplate
        image.accessibilityDescription = "Claude session \(Int((fraction * 100).rounded()))% used"
        return image
    }
}

enum ThermalPalette {
    enum Style {
        case template
        case heat(NSColor, glow: CGFloat)
        var isTemplate: Bool { if case .template = self { return true } else { return false } }
    }

    // Warm amber ramps from honey to deep amber; crimson ramps from hot red to deep crimson.
    static let amberStart = (r: 1.00, g: 0.78, b: 0.25)
    static let amberEnd = (r: 1.00, g: 0.55, b: 0.12)
    static let crimsonStart = (r: 1.00, g: 0.30, b: 0.22)
    static let crimsonEnd = (r: 0.88, g: 0.06, b: 0.20)

    static func style(for f: Double) -> Style {
        switch f {
        case ..<0.55:
            return .template
        case ..<0.80:
            let t = (f - 0.55) / 0.25
            return .heat(lerp(amberStart, amberEnd, t), glow: 0)
        default:
            let t = min((f - 0.80) / 0.20, 1)
            return .heat(lerp(crimsonStart, crimsonEnd, t), glow: CGFloat(0.4 + 0.6 * t))
        }
    }

    /// Color for SwiftUI/panel use at any fraction (monochrome range uses a soft white).
    static func color(for f: Double) -> NSColor {
        if case let .heat(c, _) = style(for: f) { return c }
        return NSColor(white: 0.92, alpha: 1)
    }

    private static func lerp(_ a: (r: Double, g: Double, b: Double),
                             _ b: (r: Double, g: Double, b: Double), _ t: Double) -> NSColor {
        let t = min(max(t, 0), 1)
        return NSColor(srgbRed: a.r + (b.r - a.r) * t,
                       green: a.g + (b.g - a.g) * t,
                       blue: a.b + (b.b - a.b) * t, alpha: 1)
    }
}
