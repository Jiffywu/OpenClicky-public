import Foundation

extension ChatRequest {
    /// About how many bytes this request's body is on the wire: every text part, tool definition and hosted tool, and
    /// each image as base64 (4/3 of its bytes). Provider framing adds a little; the order of magnitude is what matters
    /// for timings (a screenshot-heavy thread is slow to upload and to read).
    public var approximateBodyBytes: Int {
        var total = model.utf8.count
        for message in messages {
            for part in message.content {
                switch part {
                case .text(let text): total += text.utf8.count
                case .image(let data, _): total += (data.count + 2) / 3 * 4
                }
            }
            for call in message.toolCalls { total += call.name.utf8.count + call.arguments.utf8.count }
        }
        for tool in tools { total += tool.name.utf8.count + tool.description.utf8.count + tool.parameters.jsonString().utf8.count }
        for tool in hostedTools { total += tool.jsonString().utf8.count }
        return total
    }
}

extension TurnTimings {
    /// "12 KB", "1.4 MB".
    static func kilobytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return "\(max(1, Int((Double(bytes) / 1_000).rounded()))) KB"
    }
}

/// What the floating latency stats panel shows (Settings → Developer → Floating latency stats): the last turn's
/// steps, its prompt-cache hit, the request size, and the brain session's thread size and compactions. HeyClicky's
/// `ClickyOneBrainStatsHUD`; the panel is left out of OpenClicky's own screenshots.
public struct LatencyHUDContent: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public var label: String
        public var value: String
        /// The headline number (key-up or send to first line heard).
        public var emphasized: Bool

        public init(_ label: String, _ value: String, emphasized: Bool = false) {
            self.label = label
            self.value = value
            self.emphasized = emphasized
        }
    }

    public var title: String
    public var rows: [Row]
    /// The brain session, in one line.
    public var footer: String?

    public init(title: String, rows: [Row], footer: String?) {
        self.title = title
        self.rows = rows
        self.footer = footer
    }

    /// The content for the last turn's `timings` and the brain session's `stats` (either may be missing).
    public static func make(timings: TurnTimings?, stats: BrainSessionStats?) -> LatencyHUDContent {
        guard let timings else {
            return LatencyHUDContent(title: "Latency", rows: [Row("Last turn", "none yet")], footer: stats.map(sessionLine))
        }
        var rows: [Row] = []
        let headline = timings.kind == .voice ? "release → first line heard" : "sent → first line heard"
        for (label, ms) in timings.steps where label != "held" {
            rows.append(Row(label, "\(ms) ms", emphasized: label == headline))
        }
        if let usage = timings.usage {
            let share = usage.inputTokens > 0 ? Int((Double(usage.cachedInputTokens) / Double(usage.inputTokens) * 100).rounded()) : 0
            rows.append(Row("cache", usage.cachedInputTokens > 0 ? "hit, \(share)% of \(UsageFormat.tokens(usage.inputTokens))"
                                : "miss (\(UsageFormat.tokens(usage.inputTokens)) in)"))
        }
        if let bytes = timings.requestBodyBytes { rows.append(Row("request body", TurnTimings.kilobytes(bytes))) }
        if let ears = timings.ears { rows.append(Row("ears", ears.warm ? "warm" : "cold")) }
        let title = "\(timings.kind.rawValue.capitalized) turn" + (timings.model.map { " · \($0)" } ?? "")
        return LatencyHUDContent(title: title, rows: rows, footer: stats.map(sessionLine))
    }

    static func sessionLine(_ stats: BrainSessionStats) -> String {
        "thread \(stats.threadItems) items (\(stats.screenshotsInThread) screenshots) · \(stats.turns) turns · "
            + "\(stats.compactions) compaction\(stats.compactions == 1 ? "" : "s")"
    }
}

extension FeatureFlag {
    /// The floating latency stats panel.
    public static let latencyHUD = FeatureFlag(
        id: "developer.latency-hud", title: "Floating latency stats",
        summary: "Show a small floating panel with the last turn's timings, cache hits, request size and the brain's thread "
            + "size. OpenClicky's own screenshots leave it out.",
        defaultValue: false, group: .developer, replaces: ["ClickyOneBrainStatsHUD"], readBy: "LatencyStatsPanel")
}
