import Foundation

/// One deduplicated assistant API response with its token usage.
struct UsageEntry {
    let timestamp: Date
    var input: Int
    var output: Int
    var cacheCreate: Int
    var cacheRead: Int

    /// Output-equivalent tokens, weighted by relative API price
    /// (input = 1/5 of output, cache write = 1.25x input, cache read = 0.1x input).
    var weighted: Double {
        Double(output) * Weights.output
            + Double(input) * Weights.input
            + Double(cacheCreate) * Weights.cacheCreate
            + Double(cacheRead) * Weights.cacheRead
    }
}

enum Weights {
    static let output = 1.0
    static let input = 0.2
    static let cacheCreate = 0.25
    static let cacheRead = 0.02
}

/// A "You've hit your 5-hour limit · resets 2:50pm (America/New_York)" style event from the logs.
struct RateLimitEvent {
    enum Kind: String { case session, weekly }
    let timestamp: Date
    let kind: Kind
    let resetsAt: Date?
}

struct TokenBreakdown {
    var input = 0, output = 0, cacheCreate = 0, cacheRead = 0
    var cached: Int { cacheCreate + cacheRead }

    mutating func add(_ e: UsageEntry) {
        input += e.input; output += e.output
        cacheCreate += e.cacheCreate; cacheRead += e.cacheRead
    }
}

enum ThermalState {
    case cool, warming, overheating

    init(fraction: Double) {
        switch fraction {
        case ..<0.55: self = .cool
        case ..<0.80: self = .warming
        default: self = .overheating
        }
    }

    var title: String {
        switch self {
        case .cool: "Cool"
        case .warming: "Warming"
        case .overheating: "Overheating"
        }
    }
}

/// Everything the UI needs, computed off the main thread.
struct UsageSnapshot {
    // 5-hour session
    var sessionUsed: Double = 0
    var sessionCeiling: Double = Limits.defaultSessionCeiling
    var sessionStart: Date?
    var sessionResetsAt: Date?
    var breakdown = TokenBreakdown()
    var messageCount = 0
    var velocityPerMinute: Double = 0
    var projectedFullAt: Date?
    var rateLimited = false

    // 7-day
    var weeklyUsed: Double = 0
    var weeklyCeiling: Double = Limits.defaultSessionCeiling * Limits.weeklyMultiplier
    var weeklyResetsAt: Date?

    // calibration
    var sessionCalibrationPoints = 0
    var weeklyCalibrationPoints = 0

    // Live numbers from Claude Code (via the status line bridge). They take precedence over the log estimate.
    var liveSessionFraction: Double?
    var liveWeeklyFraction: Double?
    var liveFetchedAt: Date?
    var liveMissing = false

    var computedAt = Date()

    var isLive: Bool { liveSessionFraction != nil || liveWeeklyFraction != nil }

    var sessionFraction: Double {
        if let live = liveSessionFraction { return live }
        if rateLimited { return 1 }
        guard sessionCeiling > 0 else { return 0 }
        return min(max(sessionUsed / sessionCeiling, 0), 1)
    }

    var weeklyFraction: Double {
        if let live = liveWeeklyFraction { return live }
        guard weeklyCeiling > 0 else { return 0 }
        return min(max(weeklyUsed / weeklyCeiling, 0), 1)
    }

    var thermal: ThermalState { ThermalState(fraction: sessionFraction) }
}

enum Limits {
    static let sessionDuration: TimeInterval = 5 * 3600
    static let weekDuration: TimeInterval = 7 * 86400
    /// Claude Pro baseline: ~45k weighted output-equivalent tokens per 5h.
    static let defaultSessionCeiling: Double = 45_000
    static let weeklyMultiplier: Double = 10
    static let velocityWindow: TimeInterval = 30 * 60
    /// How far back logs are read (two weeks lets the 7-day window chain correctly).
    static let horizon: TimeInterval = 15 * 86400
    static let maxCalibrationPoints = 8
}
