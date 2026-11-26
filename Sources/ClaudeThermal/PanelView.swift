import SwiftUI

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var presentation: PanelPresentation
    @ObservedObject var loginItem: LoginItemManager
    /// Offscreen renders can't sample the desktop, so previews use a solid stand-in for the glass.
    var solidBackground = false
    var onQuit: () -> Void

    static let width: CGFloat = 320
    private let corner: CGFloat = 18

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 14) {
            header(s)
            divider
            sessionSection(s)
            divider
            weeklySection(s)
            divider
            footer
        }
        .padding(16)
        .frame(width: Self.width)
        .background {
            if solidBackground {
                LinearGradient(colors: [Color(white: 0.17), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
            } else {
                VisualEffectBackground(material: .hudWindow)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .scaleEffect(presentation.isPresented ? 1 : 0.94, anchor: .top)
        .opacity(presentation.isPresented ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: presentation.isPresented)
        .environment(\.colorScheme, .dark)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
    }

    // MARK: Header

    private func header(_ s: UsageSnapshot) -> some View {
        let tint = Color(nsColor: ThermalPalette.color(for: s.sessionFraction))
        return HStack(alignment: .center, spacing: 12) {
            MiniPill(fraction: s.sessionFraction)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.rateLimited ? "Rate limited" : s.thermal.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(s.thermal == .cool ? .primary : tint)
                Text("Claude Code · 5-hour session")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int((s.sessionFraction * 100).rounded()))%")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(s.thermal == .cool ? .primary : tint)
                .shadow(color: s.thermal == .overheating ? tint.opacity(0.6) : .clear, radius: 8)
                .contentTransition(.numericText())
        }
    }

    // MARK: 5-hour session

    private func sessionSection(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("5-HOUR SESSION", trailing: s.liveSessionFraction != nil
                         ? liveLabel(s)
                         : "est. \(Format.tokens(s.sessionUsed)) / \(Format.tokens(s.sessionCeiling))")

            ThermalBar(fraction: s.sessionFraction)
                .frame(height: 10)

            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                Text(resetLine(s))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                StatCell(title: "Input", value: Format.tokens(Double(s.breakdown.input)), detail: nil)
                StatCell(title: "Output", value: Format.tokens(Double(s.breakdown.output)), detail: nil)
                StatCell(title: "Cached", value: Format.tokens(Double(s.breakdown.cached)),
                         detail: "w \(Format.tokens(Double(s.breakdown.cacheCreate))) · r \(Format.tokens(Double(s.breakdown.cacheRead)))")
            }

            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(s.velocityPerMinute > 0
                                     ? Color(nsColor: ThermalPalette.color(for: max(s.sessionFraction, 0.6)))
                                     : .secondary)
                Text("Burn velocity")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(velocityLine(s))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    private func liveLabel(_ s: UsageSnapshot) -> String {
        guard let at = s.liveFetchedAt else { return "● Live" }
        let age = presentation.now.timeIntervalSince(at)
        if age < 60 { return "● Live" }
        return "● Synced \(Format.duration(age)) ago"
    }

    private func resetLine(_ s: UsageSnapshot) -> String {
        guard let reset = s.sessionResetsAt else { return "No active session — window starts with your next message" }
        let remaining = max(reset.timeIntervalSince(presentation.now), 0)
        return "Resets in \(Format.duration(remaining)) • \(Format.clock(reset))"
    }

    private func velocityLine(_ s: UsageSnapshot) -> String {
        guard s.velocityPerMinute > 0.5 else { return "Idle" }
        var line = "\(Format.tokens(s.velocityPerMinute))/min"
        if let eta = s.projectedFullAt {
            line += " · full in \(Format.duration(max(eta.timeIntervalSince(presentation.now), 0)))"
        }
        return line
    }

    // MARK: Weekly

    private func weeklySection(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("WEEKLY LIMIT", trailing: "\(Int((s.weeklyFraction * 100).rounded()))%")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(Color(nsColor: ThermalPalette.color(for: s.weeklyFraction)).opacity(0.9))
                        .frame(width: max(geo.size.width * s.weeklyFraction, s.weeklyFraction > 0 ? 4 : 0))
                }
            }
            .frame(height: 5)
            HStack {
                Text("7-day window")
                Spacer()
                if let reset = s.weeklyResetsAt {
                    Text("Resets \(Format.dayClock(reset))")
                } else {
                    Text("No usage in the last 7 days")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Text(calibrationLine(s))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func calibrationLine(_ s: UsageSnapshot) -> String {
        if s.isLive {
            return "% straight from Claude Code · tokens & velocity from this Mac's logs"
        }
        if s.liveMissing {
            return "Estimating from logs · run ./build.sh setup-statusline for exact %"
        }
        if s.sessionCalibrationPoints > 0 {
            let n = s.sessionCalibrationPoints
            return "Ceiling auto-calibrated from \(n) rate-limit hit\(n == 1 ? "" : "s")"
        }
        return "Claude Pro baseline · auto-adjusts on first rate-limit hit"
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if solidBackground {
                // Offscreen renders can't draw AppKit's switch; draw a look-alike for previews.
                HStack(spacing: 8) {
                    Text("Launch at Login").font(.system(size: 12))
                    Capsule().fill(Color.accentColor).frame(width: 26, height: 15)
                        .overlay(alignment: .trailing) { Circle().fill(.white).padding(1.5) }
                }
            } else {
                Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })) {
                    Text("Launch at Login").font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!loginItem.isAvailable)
                .help(loginItem.statusNote ?? "")
            }

            if !solidBackground, let note = loginItem.statusNote {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: onQuit) {
                Text("Quit").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }

    private func sectionLabel(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            Spacer()
            if trailing.hasPrefix("● ") {
                (Text("● ").foregroundColor(.green) + Text(trailing.dropFirst(2)).foregroundColor(.secondary))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
            } else {
                Text(trailing).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Components

/// The full monochrome → amber → crimson gradient, revealed up to the fill level.
struct ThermalBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                LinearGradient(stops: [
                    .init(color: Color(white: 0.85), location: 0),
                    .init(color: Color(white: 0.92), location: 0.45),
                    .init(color: Color(red: 1.0, green: 0.78, blue: 0.25), location: 0.55),
                    .init(color: Color(red: 1.0, green: 0.55, blue: 0.12), location: 0.78),
                    .init(color: Color(red: 1.0, green: 0.30, blue: 0.22), location: 0.82),
                    .init(color: Color(red: 0.88, green: 0.06, blue: 0.20), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: w)
                .frame(width: max(w * fraction, fraction > 0 ? 10 : 0), alignment: .leading)
                .clipShape(Capsule())
                .shadow(color: fraction >= 0.8 ? Color.red.opacity(0.55) : .clear, radius: 6)
                // Threshold ticks at 55% and 80%
                ForEach([0.55, 0.80], id: \.self) { t in
                    Rectangle().fill(.black.opacity(0.35)).frame(width: 1).offset(x: w * t)
                }
            }
            .animation(.easeOut(duration: 0.4), value: fraction)
        }
    }
}

struct StatCell: View {
    var title: String
    var value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail ?? " ").font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// SwiftUI twin of the menu bar capsule, used in the header.
struct MiniPill: View {
    var fraction: Double

    var body: some View {
        let tint = Color(nsColor: ThermalPalette.color(for: fraction))
        ZStack(alignment: .bottom) {
            Capsule().strokeBorder(tint.opacity(0.9), lineWidth: 1.5)
            GeometryReader { geo in
                VStack { Spacer(minLength: 0)
                    Capsule().fill(tint)
                        .frame(height: max(geo.size.height * fraction, fraction > 0 ? 4 : 0))
                }
            }
            .padding(3.5)
        }
        .frame(width: 14, height: 28)
        .shadow(color: fraction >= 0.8 ? tint.opacity(0.7) : .clear, radius: 5)
    }
}

// MARK: - Formatting

enum Format {
    static func tokens(_ v: Double) -> String {
        switch v {
        case 1_000_000...: return String(format: v >= 10_000_000 ? "%.0fM" : "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: v >= 100_000 ? "%.0fk" : "%.1fk", v / 1_000)
        default: return String(format: "%.0f", v)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t.rounded(.up)))s" }
        let minutes = Int((t / 60).rounded(.up)) // never show "0m" while time remains
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dayClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d jmm")
        return f
    }()

    static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }
    static func dayClock(_ d: Date) -> String { dayClockFormatter.string(from: d) }
}
