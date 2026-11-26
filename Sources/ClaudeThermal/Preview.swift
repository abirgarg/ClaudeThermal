import AppKit
import SwiftUI

/// `ClaudeThermal --render-preview DIR` renders README images from demo data
/// (never your real usage): the panel and the pill at three heat levels.
@MainActor
func renderPreviewAndExit(to dir: String) -> Never {
    let now = Date()
    var demo = UsageSnapshot()
    demo.liveSessionFraction = 0.72
    demo.liveWeeklyFraction = 0.34
    demo.liveFetchedAt = now
    demo.sessionResetsAt = now.addingTimeInterval(1 * 3600 + 42 * 60 + 30)
    demo.sessionStart = demo.sessionResetsAt!.addingTimeInterval(-Limits.sessionDuration)
    demo.weeklyResetsAt = now.addingTimeInterval(3 * 86400 + 5 * 3600)
    demo.breakdown = TokenBreakdown(input: 412, output: 58_300, cacheCreate: 214_000, cacheRead: 4_100_000)
    demo.sessionUsed = 1_200_000
    demo.velocityPerMinute = 6_200
    demo.projectedFullAt = now.addingTimeInterval(48 * 60)

    let store = UsageStore()
    store.showPreview(demo)
    let presentation = PanelPresentation()
    presentation.isPresented = true
    presentation.now = now

    let panel = PanelView(store: store, presentation: presentation, loginItem: LoginItemManager(),
                          solidBackground: true, onQuit: {})
        .padding(28)
    let renderer = ImageRenderer(content: panel)
    renderer.scale = 2
    write(renderer.nsImage, to: "\(dir)/panel.png")

    // Pills on a dark menu bar strip
    let pills = HStack(spacing: 28) {
        ForEach([0.30, 0.67, 0.92], id: \.self) { f in
            VStack(spacing: 10) {
                Image(nsImage: tinted(PillRenderer.image(fraction: f)))
                    .resizable().interpolation(.high)
                    .frame(width: 14 * 3, height: 22 * 3)
                Text(ThermalState(fraction: f).title + " · \(Int(f * 100))%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
    .padding(.horizontal, 36).padding(.vertical, 24)
    .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.13)))
    let pillRenderer = ImageRenderer(content: pills)
    pillRenderer.scale = 2
    write(pillRenderer.nsImage, to: "\(dir)/pills.png")

    print("Wrote \(dir)/panel.png and \(dir)/pills.png")
    exit(0)
}

/// Template images render black outside the menu bar; tint them white like a dark menu bar does.
@MainActor
private func tinted(_ image: NSImage) -> NSImage {
    guard image.isTemplate else { return image }
    return NSImage(size: image.size, flipped: false) { r in
        image.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
}

@MainActor
private func write(_ image: NSImage?, to path: String) {
    guard let image, let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        print("Failed to render \(path)")
        return
    }
    try? data.write(to: URL(fileURLWithPath: path))
}
