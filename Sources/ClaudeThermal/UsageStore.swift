import AppKit
import Combine
import Foundation

/// Publishes one merged snapshot:
///  • percentages and reset times come from Claude Code's own plan-usage numbers
///    (saved by the status line bridge to ~/.claude/thermal/usage.json), when available;
///  • token breakdown and burn velocity come from this Mac's Claude Code logs;
///  • without the bridge file, everything falls back to the log estimate.
///
/// Nothing polls and nothing touches the network: one FSEvents stream on ~/.claude
/// drives everything, plus a one-shot timer at the next window reset.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()

    nonisolated static var claudeDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    nonisolated static var projectsRoot: URL { claudeDir.appendingPathComponent("projects") }

    private let queue = DispatchQueue(label: "app.claudethermal.usage", qos: .utility)
    private let worker: Worker
    private var watcher: LogWatcher?
    private var boundaryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private var logSnapshot = UsageSnapshot()
    private var bridgeLive: LiveUsage?   // status line bridge: continuous, whole-number, rounded down
    private var exactLive: LiveUsage?    // `claude -p /usage`: exact, fetched on demand
    private var live: LiveUsage? { LiveUsage.merge(bridgeLive, exactLive) }
    private let liveEnabled = !CommandLine.arguments.contains("--logs-only")

    private let cliQueue = DispatchQueue(label: "app.claudethermal.cli", qos: .utility)
    private var exactInFlight = false
    private var lastExactAttempt = Date.distantPast

    init() {
        worker = Worker(root: Self.projectsRoot)
    }

    func start() {
        let projectsPath = Self.projectsRoot.path + "/"
        let livePath = LiveUsage.fileURL.path
        // Watch ~/.claude (or its nearest existing ancestor) so both the logs and
        // the bridge file are covered by a single stream.
        var watchPath = Self.claudeDir.path
        while !FileManager.default.fileExists(atPath: watchPath), watchPath != "/" {
            watchPath = (watchPath as NSString).deletingLastPathComponent
        }

        let worker = self.worker
        watcher = LogWatcher(root: watchPath, queue: queue) { [weak self] change in
            var logsChanged = false
            var liveChanged = false
            switch change {
            case .rescan:
                worker.rescan()
                logsChanged = true
                liveChanged = true
            case .files(let paths):
                let logs = paths.filter { $0.hasPrefix(projectsPath) && $0.hasSuffix(".jsonl") }
                if !logs.isEmpty {
                    worker.ingest(logs)
                    logsChanged = true
                }
                liveChanged = paths.contains(livePath)
            }
            guard logsChanged || liveChanged else { return }
            let newLive = liveChanged ? LiveUsage.load() : nil
            let snap = worker.compute()
            Task { @MainActor in
                if liveChanged {
                    self?.applyLive(newLive)
                    self?.refreshExact(minInterval: 5 * 60) // Claude Code is active: correct the rounding now and then
                }
                self?.applyLogs(snap)
            }
        }
        watcher?.start()

        queue.async { [weak self] in
            worker.rescan()
            let initialLive = LiveUsage.load()
            let snap = worker.compute()
            Task { @MainActor in
                self?.applyLive(initialLive)
                self?.applyLogs(snap)
            }
        }
        refreshExact(minInterval: 0)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recompute()
                self?.refreshExact(minInterval: 0)
            }
        }
    }

    /// For `--render-preview` only: show a fixed demo snapshot.
    func showPreview(_ demo: UsageSnapshot) { snapshot = demo }

    /// Called when the panel opens: recompute against the current clock and fetch exact numbers.
    func panelWillOpen() {
        recompute()
        refreshExact(minInterval: 60)
    }

    /// Runs `claude -p /usage` off the main thread (~3 s, ~1 s CPU). Never on a timer loop:
    /// only at launch, wake, panel open, window resets, and during active Claude Code use.
    private func refreshExact(minInterval: TimeInterval) {
        let now = Date()
        guard liveEnabled, !exactInFlight, now.timeIntervalSince(lastExactAttempt) >= minInterval else { return }
        exactInFlight = true
        lastExactAttempt = now
        cliQueue.async { [weak self] in
            let result = ClaudeCLIUsage.fetch()
            Task { @MainActor in
                guard let self else { return }
                self.exactInFlight = false
                if let result { self.exactLive = result }
                self.applyLive(nil)
                self.publish()
            }
        }
    }

    /// Recompute with the current clock (no re-parse). Cheap: a few thousand entries.
    func recompute() {
        let worker = self.worker
        queue.async { [weak self] in
            let snap = worker.compute()
            Task { @MainActor in self?.applyLogs(snap) }
        }
    }

    // MARK: Live usage (from the status line bridge)

    private func applyLive(_ usage: LiveUsage?) {
        guard liveEnabled else { return }
        if let usage { bridgeLive = usage } // keep the last good reading if the file is mid-rewrite
        // The weekly window resets on a fixed 7-day schedule: remember it so the log
        // fallback stays aligned to the real week even when live data is stale.
        if let weeklyReset = live?.sevenDay?.resetsAt {
            UserDefaults.standard.set(weeklyReset.timeIntervalSince1970, forKey: Worker.weeklyAnchorKey)
        }
        // Hand the exact windows to the log worker so the token breakdown covers the same span.
        let now = Date()
        let session = live?.validSession(at: now)?.resetsAt.map {
            UsageEngine.Block(start: $0.addingTimeInterval(-Limits.sessionDuration), end: $0)
        }
        let week = live?.validWeek(at: now)?.resetsAt.map {
            UsageEngine.Block(start: $0.addingTimeInterval(-Limits.weekDuration), end: $0)
        }
        let worker = self.worker
        queue.async {
            worker.liveSession = session
            worker.liveWeek = week
        }
    }

    // MARK: Merge + publish

    private func applyLogs(_ snap: UsageSnapshot) {
        logSnapshot = snap
        publish()
    }

    /// `--simulate 86` pins the session at 86% to preview the hot states.
    private let simulatedFraction: Double? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--simulate"), i + 1 < args.count, let v = Double(args[i + 1]) else { return nil }
        return v / 100
    }()

    private func publish() {
        let now = Date()
        var s = logSnapshot
        s.liveMissing = liveEnabled && live == nil

        if liveEnabled, let live {
            if let five = live.validSession(at: now) {
                s.liveFetchedAt = live.writtenAt
                s.liveSessionFraction = five.fraction
                if let reset = five.resetsAt {
                    s.sessionResetsAt = reset
                    s.sessionStart = reset.addingTimeInterval(-Limits.sessionDuration)
                }
                // "Full in": this Mac's burn rate, converted to percent using this window's
                // tokens-per-percent ratio from the live number.
                s.projectedFullAt = nil
                if five.fraction > 0.01, five.fraction < 1, s.sessionUsed > 0, s.velocityPerMinute > 0 {
                    let fractionPerMinute = s.velocityPerMinute * five.fraction / s.sessionUsed
                    let eta = now.addingTimeInterval((1 - five.fraction) / fractionPerMinute * 60)
                    if eta < (s.sessionResetsAt ?? .distantFuture) { s.projectedFullAt = eta }
                }
                s.rateLimited = five.fraction >= 1
            }
            if let week = live.validWeek(at: now) {
                s.liveFetchedAt = s.liveFetchedAt ?? live.writtenAt
                s.liveWeeklyFraction = week.fraction
                if let reset = week.resetsAt { s.weeklyResetsAt = reset }
            }
        }

        if let f = simulatedFraction {
            s.liveSessionFraction = f
            s.rateLimited = false
        }
        snapshot = s
        scheduleBoundaryTimer(for: s)
    }

    /// One-shot timer at the next window reset so the pill drops back without polling.
    private func scheduleBoundaryTimer(for snap: UsageSnapshot) {
        boundaryTimer?.invalidate()
        let candidates = [snap.sessionResetsAt, snap.weeklyResetsAt].compactMap { $0 }.filter { $0 > Date() }
        guard let next = candidates.min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(2), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyLive(nil) // expire live windows that just reset
                self.recompute()
                self.refreshExact(minInterval: 0)
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }
}

/// Background-queue state. Only touched from `UsageStore.queue`
/// (or synchronously from the `--dump` CLI path).
final class Worker: @unchecked Sendable {
    let root: URL
    let parser = LogParser()
    let calibration = CalibrationStore()
    var liveSession: UsageEngine.Block?
    var liveWeek: UsageEngine.Block?
    private var lastPrune = Date.distantPast

    init(root: URL) { self.root = root }

    func rescan() { parser.fullScan(root: root) }

    func ingest(_ paths: Set<String>) {
        for p in paths { parser.ingest(path: p) }
    }

    func compute(now: Date = Date()) -> UsageSnapshot {
        if now.timeIntervalSince(lastPrune) > 3600 {
            parser.prune(now: now)
            lastPrune = now
        }
        let entries = Array(parser.entries.values)
        let events = Array(parser.events.values)
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        let (sBlocks, wBlocks) = UsageEngine.sessionBlocksAndWeekly(entries: sorted, events: events)
        calibration.merge(UsageEngine.calibrationPoints(
            sorted: sorted, events: events, sessionBlocks: sBlocks, weeklyBlocks: wBlocks))
        return UsageEngine.snapshot(entries: sorted, events: events,
                                    ceilings: calibration.ceilings(), now: now,
                                    liveSession: liveSession, liveWeek: liveWeek ?? projectedWeek(now: now))
    }

    static let weeklyAnchorKey = "weekly.resetAnchor"

    /// The current week on the schedule last reported by Claude Code (anchor + n·7 days).
    private func projectedWeek(now: Date) -> UsageEngine.Block? {
        let anchor = UserDefaults.standard.double(forKey: Self.weeklyAnchorKey)
        guard anchor > 0 else { return nil }
        let week = Limits.weekDuration
        let steps = ((now.timeIntervalSince1970 - anchor) / week).rounded(.down) + 1
        let end = Date(timeIntervalSince1970: anchor + max(steps, 0) * week)
        return UsageEngine.Block(start: end.addingTimeInterval(-week), end: end)
    }
}
