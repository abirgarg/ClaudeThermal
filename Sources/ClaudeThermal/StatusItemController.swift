import AppKit
import Combine
import SwiftUI

/// Owns the menu bar pill and the hover panel.
///
/// Hover logic: entering the pill schedules a show after 120 ms; leaving the pill
/// or the panel schedules a hide after 120 ms. Any re-entry cancels the pending
/// action, so brief cursor slips (or the trip from pill to panel) never flicker.
/// Clicking the pill pins the panel open until you click elsewhere.
@MainActor
final class StatusItemController: NSResponder {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: UsageStore
    private let loginItem: LoginItemManager
    private let presentation = PanelPresentation()
    private var panel: HoverPanel?
    private var cancellables = Set<AnyCancellable>()

    private let debounce: TimeInterval = 0.12
    private var pendingShow: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var overButton = false
    private var overPanel = false
    private var pinned = false
    private var isShown = false
    private var hideGeneration = 0
    private var clock: Timer?
    private var outsideClickMonitor: Any?
    private var lastRenderedPercent = -1
    private var lastRenderedStyle = ""

    init(store: UsageStore, loginItem: LoginItemManager) {
        self.store = store
        self.loginItem = loginItem
        super.init()
        configureButton()
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in self?.render(snap) }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Pill

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = PillRenderer.image(fraction: 0)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePinned)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        lastRenderedPercent = 0
        lastRenderedStyle = "t"
    }

    /// Re-rasterizes only when the visible percent (or color band) changes.
    private func render(_ snap: UsageSnapshot) {
        let pct = Int((snap.sessionFraction * 100).rounded())
        let style = snap.rateLimited ? "r" : "\(snap.thermal)"
        if isShown, let panel {
            // Content height can change (e.g. live data arriving); keep the panel snug under the pill.
            DispatchQueue.main.async { [weak self] in self?.position(panel) }
        }
        guard pct != lastRenderedPercent || style != lastRenderedStyle else { return }
        lastRenderedPercent = pct
        lastRenderedStyle = style
        statusItem.button?.image = PillRenderer.image(fraction: snap.sessionFraction)
        statusItem.button?.toolTip = isShown ? nil : "Claude session \(pct)% · \(snap.thermal.title)"
    }

    // MARK: Hover tracking (pill)

    override func mouseEntered(with event: NSEvent) {
        overButton = true
        cancelHide()
        guard !isShown else { return }
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.overButton else { return }
            self.show()
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        overButton = false
        pendingShow?.cancel()
        scheduleHide()
    }

    private func panelHoverChanged(_ inside: Bool) {
        overPanel = inside
        if inside { cancelHide() } else { scheduleHide() }
    }

    private func scheduleHide() {
        guard isShown, !pinned else { return }
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.overButton, !self.overPanel, !self.pinned else { return }
            self.hide()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func cancelHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    /// Opens the panel pinned (used by `--open-panel` for screenshots / debugging).
    func openPinned() { togglePinned() }

    @objc private func togglePinned() {
        if isShown && pinned {
            pinned = false
            hide()
        } else {
            pinned = true
            pendingShow?.cancel()
            show()
            installOutsideClickMonitor()
        }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pinned = false
                if !self.overButton && !self.overPanel { self.hide() }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    // MARK: Panel

    private func makePanel() -> HoverPanel {
        let view = PanelView(store: store, presentation: presentation, loginItem: loginItem) {
            NSApp.terminate(nil)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize

        let container = TrackingContainerView(frame: NSRect(origin: .zero, size: size))
        container.onHoverChange = { [weak self] inside in self?.panelHoverChanged(inside) }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        let p = HoverPanel(contentRect: NSRect(origin: .zero, size: size))
        p.contentView = container
        return p
    }

    private func show() {
        hideGeneration += 1
        cancelHide()
        store.panelWillOpen() // refresh live numbers, velocity, countdown
        loginItem.refresh()
        presentation.now = Date()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)

        if !isShown {
            isShown = true
            statusItem.button?.toolTip = nil
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            presentation.isPresented = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            } completionHandler: {
                Task { @MainActor in panel.invalidateShadow() }
            }
            startClock()
        } else {
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard isShown, let panel else { return }
        isShown = false
        pinned = false
        removeOutsideClickMonitor()
        stopClock()
        hideGeneration += 1
        let generation = hideGeneration
        presentation.isPresented = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.hideGeneration == generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func position(_ panel: HoverPanel) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let content = panel.contentView!
        let hosting = content.subviews.first
        let size = hosting?.fittingSize ?? content.frame.size

        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// 1 Hz clock for the countdown — runs only while the panel is visible.
    private func startClock() {
        stopClock()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.presentation.now = Date() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }
}
