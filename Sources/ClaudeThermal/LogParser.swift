import Foundation

/// Incremental parser for Claude Code `.jsonl` transcripts.
///
/// Each file is read from the byte offset where the previous read stopped, so a
/// change to a 50 MB transcript costs only the newly appended lines. Not thread
/// safe: call it from a single serial queue.
final class LogParser {
    private struct FileState {
        var offset: UInt64
        var inode: UInt64
    }

    /// Deduplicated by `message.id|requestId`: Claude Code writes one line per
    /// content block, each repeating the same usage object.
    private(set) var entries: [String: UsageEntry] = [:]
    private(set) var events: [String: RateLimitEvent] = [:]
    private var files: [String: FileState] = [:]

    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    private static let needles: [[UInt8]] = [
        Array("\"usage\"".utf8),
        Array("rate_limit".utf8),
        Array("limit reached".utf8),
    ]

    // MARK: Scanning

    func fullScan(root: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-Limits.horizon)
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let mtime = values?.contentModificationDate, mtime < cutoff { continue }
            ingest(path: url.path, now: now)
        }
    }

    func ingest(path: String, now: Date = Date()) {
        guard path.hasSuffix(".jsonl") else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            files[path] = nil // deleted
            return
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        var state = files[path] ?? FileState(offset: 0, inode: inode)
        if state.inode != inode || size < state.offset {
            state = FileState(offset: 0, inode: inode) // replaced or truncated
        }
        guard size > state.offset, let handle = FileHandle(forReadingAtPath: path) else {
            files[path] = state
            return
        }
        defer { try? handle.close() }

        let cutoff = now.addingTimeInterval(-Limits.horizon)
        do {
            try handle.seek(toOffset: state.offset)
            var carry = Data()
            var done = false
            while !done {
                // Drain each chunk's autoreleased buffers immediately; otherwise the
                // initial scan holds every file's bytes until the queue block ends.
                try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else {
                        done = true
                        return
                    }
                    carry.append(chunk)
                    let consumed = processLines(in: carry, cutoff: cutoff)
                    state.offset += UInt64(consumed)
                    carry = consumed == carry.count ? Data() : carry.subdata(in: consumed..<carry.count)
                }
            }
            // Whatever is left in `carry` is a partial line still being written;
            // it is re-read from `state.offset` on the next change.
        } catch {
            // Leave offset where it got to; next event retries.
        }
        files[path] = state
    }

    /// Drops entries older than the horizon so memory stays bounded.
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Limits.horizon)
        entries = entries.filter { $0.value.timestamp >= cutoff }
        events = events.filter { $0.value.timestamp >= cutoff }
    }

    // MARK: Line handling

    /// Processes every complete line; returns the number of bytes consumed.
    private func processLines(in data: Data, cutoff: Date) -> Int {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var start = 0
            let count = raw.count
            while start < count {
                guard let nl = memchr(base + start, 0x0A, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(nl))
                let len = end - start
                if len > 0, Self.containsNeedle(base + start, len) {
                    autoreleasepool {
                        // No-copy view: the bytes are only read during this call.
                        let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                        count: len, deallocator: .none)
                        handle(line: line, cutoff: cutoff)
                    }
                }
                start = end + 1
            }
            return start
        }
    }

    private static func containsNeedle(_ ptr: UnsafeRawPointer, _ len: Int) -> Bool {
        for needle in needles {
            let hit = needle.withUnsafeBytes { n in memmem(ptr, len, n.baseAddress, n.count) }
            if hit != nil { return true }
        }
        return false
    }

    private func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private func handle(line: Data, cutoff: Date) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ts = date(obj["timestamp"] as? String), ts >= cutoff
        else { return }
        let message = obj["message"] as? [String: Any]

        // Usage
        if obj["type"] as? String == "assistant",
           let message,
           let usage = message["usage"] as? [String: Any],
           (message["model"] as? String) != "<synthetic>" {
            let entry = UsageEntry(
                timestamp: ts,
                input: Self.int(usage["input_tokens"]),
                output: Self.int(usage["output_tokens"]),
                cacheCreate: Self.int(usage["cache_creation_input_tokens"]),
                cacheRead: Self.int(usage["cache_read_input_tokens"])
            )
            if entry.input + entry.output + entry.cacheCreate + entry.cacheRead > 0 {
                let msgID = message["id"] as? String ?? (obj["uuid"] as? String ?? UUID().uuidString)
                let key = msgID + "|" + (obj["requestId"] as? String ?? "")
                if let existing = entries[key] {
                    // Streaming duplicates: keep the most complete numbers.
                    entries[key] = UsageEntry(
                        timestamp: min(existing.timestamp, ts),
                        input: max(existing.input, entry.input),
                        output: max(existing.output, entry.output),
                        cacheCreate: max(existing.cacheCreate, entry.cacheCreate),
                        cacheRead: max(existing.cacheRead, entry.cacheRead)
                    )
                } else {
                    entries[key] = entry
                }
            }
        }

        // Rate-limit events
        let isRateLimit = (obj["error"] as? String) == "rate_limit"
        let isApiError = (obj["isApiErrorMessage"] as? Bool) == true
        guard isRateLimit || isApiError, let text = Self.text(of: message) else { return }
        let lower = text.lowercased()
        guard isRateLimit || lower.contains("limit reached") || lower.contains("hit your") else { return }

        let kind: RateLimitEvent.Kind = (lower.contains("weekly") || lower.contains("week")) ? .weekly : .session
        let event = RateLimitEvent(timestamp: ts, kind: kind, resetsAt: ResetParser.parse(text, relativeTo: ts))
        let key = (obj["uuid"] as? String) ?? "\(ts.timeIntervalSince1970)|\(text)"
        events[key] = event
    }

    private static func int(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }

    private static func text(of message: [String: Any]?) -> String? {
        guard let message else { return nil }
        if let s = message["content"] as? String { return s }
        if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: " ")
        }
        return nil
    }
}

/// Parses reset times out of limit messages:
///   "You've hit your 5-hour limit · resets 2:50pm (America/New_York)"
///   "You've hit your weekly limit · resets Dec 3, 5pm (America/New_York)"
///   "Claude AI usage limit reached|1732050000"
enum ResetParser {
    private static let regex = try! NSRegularExpression(
        pattern: #"resets\s+(?:(?:at\s+)?([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?"#,
        options: [.caseInsensitive]
    )

    static func parse(_ text: String, relativeTo eventTime: Date) -> Date? {
        // Legacy "...|<epoch seconds>"
        if let bar = text.lastIndex(of: "|"),
           let epoch = Double(text[text.index(after: bar)...].trimmingCharacters(in: .whitespacesAndNewlines)),
           epoch > 1_000_000_000 {
            return Date(timeIntervalSince1970: epoch)
        }

        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        guard let hourStr = group(3), var hour = Int(hourStr), let ampm = group(5)?.lowercased() else { return nil }
        let minute = Int(group(4) ?? "0") ?? 0
        hour = hour % 12 + (ampm == "pm" ? 12 : 0)

        let tz = group(6).flatMap { TimeZone(identifier: $0.trimmingCharacters(in: .whitespaces)) } ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        if let monthName = group(1), let dayStr = group(2), let day = Int(dayStr),
           let month = monthIndex(monthName) {
            var comps = DateComponents()
            comps.year = cal.component(.year, from: eventTime)
            comps.month = month; comps.day = day; comps.hour = hour; comps.minute = minute
            guard var date = cal.date(from: comps) else { return nil }
            if date < eventTime.addingTimeInterval(-86400) {
                date = cal.date(byAdding: .year, value: 1, to: date) ?? date
            }
            return date
        }

        guard var date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: eventTime) else { return nil }
        if date <= eventTime { date = cal.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    private static func monthIndex(_ name: String) -> Int? {
        let prefix = name.prefix(3).lowercased()
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return months.firstIndex(of: prefix).map { $0 + 1 }
    }
}
