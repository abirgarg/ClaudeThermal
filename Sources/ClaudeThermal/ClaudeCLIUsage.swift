import Foundation

/// Asks Claude Code itself for the exact `/usage` numbers by running
///   claude -p /usage --output-format json --no-session-persistence
///
/// That's a local command: no model call, $0, no transcript saved. Claude Code uses its
/// own login, so this app never reads credentials. It's exact; the status line bridge
/// only gets whole-number, rounded-down percentages from response headers.
enum ClaudeCLIUsage {
    static func fetch(timeout: TimeInterval = 30) -> LiveUsage? {
        guard let binary = claudeBinary() else { return nil }

        let workDir = LiveUsage.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence"]
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard process.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["result"] as? String
        else { return nil }
        return parse(text, now: Date())
    }

    /// Parses lines like:
    ///   Current session: 12% used · resets Nov 27 at 2:40am (America/New_York)
    ///   Current week (all models): 2% used · resets Dec 4 at 12:30am (America/New_York)
    static func parse(_ text: String, now: Date) -> LiveUsage? {
        var five: LiveUsage.Window?
        var week: LiveUsage.Window?
        for line in text.split(separator: "\n").map(String.init) {
            let lower = line.lowercased()
            guard let pct = percent(in: line) else { continue }
            let window = LiveUsage.Window(fraction: min(max(pct / 100, 0), 1),
                                          resetsAt: ResetParser.parse(line, relativeTo: now))
            if lower.hasPrefix("current session") {
                five = window
            } else if lower.hasPrefix("current week (all models)") || (week == nil && lower.hasPrefix("current week")) {
                week = window
            }
        }
        guard five != nil || week != nil else { return nil }
        return LiveUsage(fiveHour: five, sevenDay: week, writtenAt: now)
    }

    private static let percentRegex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)%\s*used"#)

    private static func percent(in line: String) -> Double? {
        let ns = line as NSString
        guard let m = percentRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Double(ns.substring(with: m.range(at: 1)))
    }

    /// Apps launched from Finder don't get your shell PATH, so check the usual install spots,
    /// then ask a login shell once.
    private static func claudeBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

extension LiveUsage {
    /// Combines two readings window by window: a later reset means a newer window, and
    /// within the same window usage never goes down, so the higher reading is the fresher one.
    static func merge(_ a: LiveUsage?, _ b: LiveUsage?) -> LiveUsage? {
        guard let a else { return b }
        guard let b else { return a }
        func pick(_ x: Window?, _ y: Window?) -> Window? {
            guard let x else { return y }
            guard let y else { return x }
            let rx = x.resetsAt?.timeIntervalSince1970 ?? 0
            let ry = y.resetsAt?.timeIntervalSince1970 ?? 0
            if abs(rx - ry) > 120 { return rx > ry ? x : y } // different windows
            return x.fraction >= y.fraction ? x : y
        }
        return LiveUsage(fiveHour: pick(a.fiveHour, b.fiveHour),
                         sevenDay: pick(a.sevenDay, b.sevenDay),
                         writtenAt: max(a.writtenAt, b.writtenAt))
    }
}
