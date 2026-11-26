import Foundation

/// Plan usage as Claude Code itself sees it (the same numbers as `/usage`), including
/// claude.ai and other devices.
///
/// Claude Code hands these numbers to its status line command; `scripts/statusline-bridge.sh`
/// saves them to ~/.claude/thermal/usage.json. This app only reads that file: it never
/// touches your login or the network.
struct LiveUsage {
    struct Window {
        var fraction: Double // 0...1
        var resetsAt: Date?
    }
    var fiveHour: Window?
    var sevenDay: Window?
    var writtenAt: Date

    static var fileURL: URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("thermal/usage.json")
    }

    static func load(from url: URL = fileURL) -> LiveUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> LiveUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = obj[key] as? [String: Any],
                  let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return Window(fraction: min(max(pct / 100, 0), 1), resetsAt: date(w["resets_at"]))
        }
        let written = date(obj["written_at"]) ?? Date()
        let usage = LiveUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), writtenAt: written)
        return usage.fiveHour == nil && usage.sevenDay == nil ? nil : usage
    }

    /// Accepts epoch seconds, epoch milliseconds, or ISO 8601.
    private static func date(_ any: Any?) -> Date? {
        if let n = any as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        guard let s = any as? String else { return nil }
        if let v = Double(s) { return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// A window's percentage stays true until it resets (unless used elsewhere since,
    /// which Claude Code reports the next time it runs).
    func validSession(at now: Date) -> Window? {
        guard let w = fiveHour else { return nil }
        if let r = w.resetsAt { return r > now ? w : nil }
        return now.timeIntervalSince(writtenAt) < Limits.sessionDuration ? w : nil
    }

    func validWeek(at now: Date) -> Window? {
        guard let w = sevenDay else { return nil }
        if let r = w.resetsAt { return r > now ? w : nil }
        return now.timeIntervalSince(writtenAt) < 86400 ? w : nil
    }
}
