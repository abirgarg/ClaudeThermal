import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let loginItem = LoginItemManager()
    private let notifier = OverheatNotifier()
    private var controller: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusItemController(store: store, loginItem: loginItem)
        notifier.requestAuthorizationOnFirstLaunch()
        store.$snapshot
            .dropFirst() // skip the empty placeholder before the first scan
            .sink { [notifier] snap in notifier.evaluate(snap) }
            .store(in: &cancellables)
        store.start()
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [controller] in controller?.openPinned() }
        }
    }
}

/// `ClaudeThermal --dump` prints what the app would show, then exits.
func dumpAndExit() -> Never {
    let worker = Worker(root: UsageStore.projectsRoot)
    let started = Date()
    worker.rescan()
    let s = worker.compute()
    let elapsed = Date().timeIntervalSince(started)
    let pct = { (f: Double) in String(format: "%.1f%%", f * 100) }
    print("""
    ClaudeThermal — \(UsageStore.projectsRoot.path)
      parsed \(worker.parser.entries.count) responses, \(worker.parser.events.count) rate-limit events in \(String(format: "%.2fs", elapsed))
    5-hour session: \(pct(s.sessionFraction)) [\(s.thermal.title)\(s.rateLimited ? ", rate limited" : "")]
      used \(Format.tokens(s.sessionUsed)) / ceiling \(Format.tokens(s.sessionCeiling)) (\(s.sessionCalibrationPoints) calibration points)
      window \(s.sessionStart.map(Format.dayClock) ?? "—") → \(s.sessionResetsAt.map(Format.dayClock) ?? "—")
      in \(Format.tokens(Double(s.breakdown.input))) · out \(Format.tokens(Double(s.breakdown.output))) · cache w \(Format.tokens(Double(s.breakdown.cacheCreate))) · cache r \(Format.tokens(Double(s.breakdown.cacheRead))) · \(s.messageCount) responses
      velocity \(Format.tokens(s.velocityPerMinute))/min, full at \(s.projectedFullAt.map(Format.clock) ?? "—")
    Weekly: \(pct(s.weeklyFraction)) — \(Format.tokens(s.weeklyUsed)) / \(Format.tokens(s.weeklyCeiling)), resets \(s.weeklyResetsAt.map(Format.dayClock) ?? "—")
    """)
    let now = Date()
    if let live = LiveUsage.load() {
        let five = live.validSession(at: now), week = live.validWeek(at: now)
        print("""
        Live from Claude Code (\(LiveUsage.fileURL.path), written \(Format.clock(live.writtenAt))):
          5-hour: \(five.map { pct($0.fraction) } ?? "expired/none"), resets \(five?.resetsAt.map(Format.dayClock) ?? "—")
          weekly: \(week.map { pct($0.fraction) } ?? "expired/none"), resets \(week?.resetsAt.map(Format.dayClock) ?? "—")
        """)
    } else {
        print("Live from Claude Code: not set up (run ./build.sh setup-statusline)")
    }
    if let exact = ClaudeCLIUsage.fetch() {
        print("""
        Exact from `claude -p /usage`:
          5-hour: \(exact.fiveHour.map { pct($0.fraction) } ?? "—"), resets \(exact.fiveHour?.resetsAt.map(Format.dayClock) ?? "—")
          weekly: \(exact.sevenDay.map { pct($0.fraction) } ?? "—"), resets \(exact.sevenDay?.resetsAt.map(Format.dayClock) ?? "—")
        """)
    } else {
        print("Exact from `claude -p /usage`: unavailable")
    }
    exit(0)
}

/// `ClaudeThermal --render-pills <dir>` writes @4x PNGs of the pill at several levels.
func renderPillsAndExit(to dir: String) -> Never {
    for pct in [0, 25, 54, 55, 67, 79, 80, 90, 100] {
        let img = PillRenderer.image(fraction: Double(pct) / 100)
        let scale: CGFloat = 4
        let px = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.18, alpha: 1).setFill() // dark menu bar backdrop
        NSRect(origin: .zero, size: img.size).fill()
        if img.isTemplate {
            // Approximate how AppKit tints templates on a dark menu bar.
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(origin: .zero, size: img.size))
        } else {
            img.draw(in: NSRect(origin: .zero, size: img.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/pill-\(pct).png"))
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump") { dumpAndExit() }
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated { renderPreviewAndExit(to: dir) }
}
if CommandLine.arguments.contains("--login-status") {
    print("SMAppService.mainApp.status =", SMAppService.mainApp.status.rawValue,
          "(0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound)")
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-pills"), i + 1 < CommandLine.arguments.count {
    renderPillsAndExit(to: CommandLine.arguments[i + 1])
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
