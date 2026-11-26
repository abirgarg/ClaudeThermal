import Foundation

/// A calibration sample: the weighted usage that was in a window at the moment
/// Claude Code reported a rate limit.
struct CalibrationPoint {
    let key: String // reset epoch (or block start), so repeated events in one window dedupe
    let kind: RateLimitEvent.Kind
    let value: Double
}

/// Pure window math. No I/O, no state, easy to reason about.
enum UsageEngine {
    struct Block {
        let start: Date
        let end: Date
    }

    struct Ceilings {
        var session: Double
        var weekly: Double
        var sessionPoints: Int
        var weeklyPoints: Int
    }

    /// Chains windows the way Claude's limits do: a window opens at the first
    /// message sent after the previous one closed and lasts `duration`. When a
    /// rate-limit event told us the exact reset time, that window wins.
    static func blocks(for sorted: [UsageEntry], duration: TimeInterval, anchors: [Block]) -> [Block] {
        var result: [Block] = []
        var current: Block?
        for e in sorted {
            if let c = current, e.timestamp < c.end { continue }
            let t = e.timestamp
            let anchored = anchors.first { $0.start <= t && t < $0.end }
            let block = anchored ?? Block(start: t, end: t.addingTimeInterval(duration))
            result.append(block)
            current = block
        }
        return result
    }

    static func anchors(from events: [RateLimitEvent], kind: RateLimitEvent.Kind, duration: TimeInterval) -> [Block] {
        var seen = Set<TimeInterval>()
        return events
            .filter { $0.kind == kind }
            .compactMap { $0.resetsAt }
            .filter { seen.insert($0.timeIntervalSince1970).inserted }
            .sorted()
            .map { Block(start: $0.addingTimeInterval(-duration), end: $0) }
    }

    static func calibrationPoints(sorted: [UsageEntry], events: [RateLimitEvent],
                                  sessionBlocks: [Block], weeklyBlocks: [Block]) -> [CalibrationPoint] {
        var byKey: [String: CalibrationPoint] = [:]
        for ev in events {
            let duration = ev.kind == .session ? Limits.sessionDuration : Limits.weekDuration
            let window: Block
            if let reset = ev.resetsAt {
                window = Block(start: reset.addingTimeInterval(-duration), end: ev.timestamp)
            } else {
                let blocks = ev.kind == .session ? sessionBlocks : weeklyBlocks
                guard let b = blocks.last(where: { $0.start <= ev.timestamp && ev.timestamp < $0.end }) else { continue }
                window = Block(start: b.start, end: ev.timestamp)
            }
            let used = sum(sorted, from: window.start, to: window.end)
            guard used >= 5_000 else { continue } // usage mostly elsewhere (claude.ai); not a useful sample
            let key = "\(ev.kind.rawValue):\(Int((ev.resetsAt ?? window.start).timeIntervalSince1970))"
            // Several events per window: the earliest hit is the true ceiling.
            if let existing = byKey[key], existing.value <= used { continue }
            byKey[key] = CalibrationPoint(key: key, kind: ev.kind, value: used)
        }
        return Array(byKey.values)
    }

    static func sum(_ sorted: [UsageEntry], from: Date, to: Date) -> Double {
        var total = 0.0
        for e in sorted where e.timestamp >= from && e.timestamp <= to { total += e.weighted }
        return total
    }

    /// `liveSession` / `liveWeek`: the exact windows Anthropic reported. When given,
    /// the token breakdown and velocity are computed over them instead of the guessed windows.
    static func snapshot(entries: [UsageEntry], events: [RateLimitEvent], ceilings: Ceilings, now: Date,
                         liveSession: Block? = nil, liveWeek: Block? = nil) -> UsageSnapshot {
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        var snap = UsageSnapshot()
        snap.computedAt = now
        snap.sessionCeiling = ceilings.session
        snap.weeklyCeiling = ceilings.weekly
        snap.sessionCalibrationPoints = ceilings.sessionPoints
        snap.weeklyCalibrationPoints = ceilings.weeklyPoints

        // 5-hour session
        let sAnchors = anchors(from: events, kind: .session, duration: Limits.sessionDuration)
        let sBlocks = blocks(for: sorted, duration: Limits.sessionDuration, anchors: sAnchors)
        var active = sBlocks.last.flatMap { now < $0.end ? $0 : nil }
        // A limit hit whose reset is still ahead means we're pinned at 100%,
        // even if no message has landed in that window yet.
        // (Anchors only exist for windows in which a limit was hit.)
        if let pinned = sAnchors.last(where: { $0.start <= now && now < $0.end }) {
            active = pinned
            snap.rateLimited = true
        }
        if let live = liveSession, now < live.end {
            active = live
        }

        if let block = active {
            snap.sessionStart = block.start
            snap.sessionResetsAt = block.end
            var velocitySum = 0.0
            let velocityFrom = now.addingTimeInterval(-Limits.velocityWindow)
            for e in sorted where e.timestamp >= block.start && e.timestamp < block.end {
                snap.sessionUsed += e.weighted
                snap.breakdown.add(e)
                snap.messageCount += 1
                if e.timestamp >= velocityFrom { velocitySum += e.weighted }
            }
            let minutes = min(Limits.velocityWindow, max(now.timeIntervalSince(block.start), 60)) / 60
            snap.velocityPerMinute = velocitySum / minutes
            let remaining = snap.sessionCeiling - snap.sessionUsed
            if snap.velocityPerMinute > 0, remaining > 0, !snap.rateLimited {
                let eta = now.addingTimeInterval(remaining / snap.velocityPerMinute * 60)
                if eta < block.end { snap.projectedFullAt = eta }
            }
        }

        // 7-day window
        let wAnchors = anchors(from: events, kind: .weekly, duration: Limits.weekDuration)
        let wBlocks = blocks(for: sorted, duration: Limits.weekDuration, anchors: wAnchors)
        if let week = wBlocks.last, now < week.end {
            snap.weeklyResetsAt = week.end
            snap.weeklyUsed = sum(sorted, from: week.start, to: now)
        }
        if let pinned = wAnchors.last(where: { $0.start <= now && now < $0.end }) {
            snap.weeklyResetsAt = pinned.end
            snap.weeklyUsed = max(snap.weeklyUsed, snap.weeklyCeiling)
        }
        if let live = liveWeek, now < live.end {
            snap.weeklyResetsAt = live.end
            snap.weeklyUsed = sum(sorted, from: live.start, to: now)
        }
        return snap
    }

    static func sessionBlocksAndWeekly(entries sorted: [UsageEntry], events: [RateLimitEvent]) -> ([Block], [Block]) {
        let s = blocks(for: sorted, duration: Limits.sessionDuration,
                       anchors: anchors(from: events, kind: .session, duration: Limits.sessionDuration))
        let w = blocks(for: sorted, duration: Limits.weekDuration,
                       anchors: anchors(from: events, kind: .weekly, duration: Limits.weekDuration))
        return (s, w)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Persists calibration samples in UserDefaults so they outlive Claude Code's
/// log retention, and resolves the effective ceilings.
///
/// Overrides (optional):
///   defaults write app.claudethermal.ClaudeThermal SessionCeiling -float 2000000
///   defaults write app.claudethermal.ClaudeThermal WeeklyCeiling -float 20000000
final class CalibrationStore {
    private let defaults: UserDefaults
    private let key = "calibration.points.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func merge(_ points: [CalibrationPoint]) {
        guard !points.isEmpty else { return }
        let existing = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        var stored = existing
        for p in points { stored[p.key] = min(stored[p.key] ?? .infinity, p.value) }
        // Keep the most recent N per kind.
        var trimmed: [String: Double] = [:]
        for kind in [RateLimitEvent.Kind.session, .weekly] {
            let prefix = kind.rawValue + ":"
            let recent = stored.filter { $0.key.hasPrefix(prefix) }
                .sorted { epoch($0.key) > epoch($1.key) }
                .prefix(Limits.maxCalibrationPoints)
            for (k, v) in recent { trimmed[k] = v }
        }
        if trimmed != existing { defaults.set(trimmed, forKey: key) }
    }

    func ceilings() -> UsageEngine.Ceilings {
        let stored = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let sessionVals = stored.filter { $0.key.hasPrefix("session:") }.map(\.value)
        let weeklyVals = stored.filter { $0.key.hasPrefix("weekly:") }.map(\.value)

        let sessionOverride = defaults.double(forKey: "SessionCeiling")
        let weeklyOverride = defaults.double(forKey: "WeeklyCeiling")

        let session = sessionOverride > 0 ? sessionOverride
            : UsageEngine.median(sessionVals) ?? Limits.defaultSessionCeiling
        let weekly = weeklyOverride > 0 ? weeklyOverride
            : UsageEngine.median(weeklyVals) ?? session * Limits.weeklyMultiplier
        return .init(session: session, weekly: weekly,
                     sessionPoints: sessionOverride > 0 ? 0 : sessionVals.count,
                     weeklyPoints: weeklyOverride > 0 ? 0 : weeklyVals.count)
    }

    private func epoch(_ key: String) -> Int {
        Int(key.split(separator: ":").last ?? "0") ?? 0
    }
}
