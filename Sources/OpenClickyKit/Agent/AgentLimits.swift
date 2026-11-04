import Foundation

/// How far a background job may go on its own. The manager enforces the step cap, the wall clock, the
/// unanswered-question fallback, the idle end and the cleanup; the harnesses get the command timeout and the
/// compaction threshold in their own settings. Every field is optional in the config (`agentLimits`), so a partial
/// object only changes what it names.
public struct AgentLimits: Codable, Sendable, Hashable {
    /// Tool steps (commands, file edits, MCP and web calls) one run may take before it is stopped.
    public var maxStepsPerRun: Int
    /// Wall-clock seconds one run may take before it is stopped.
    public var maxRunSeconds: TimeInterval
    /// Seconds one shell command may run (Claude Code enforces it; Codex is told in its instructions).
    public var commandTimeoutSeconds: TimeInterval
    /// A job that waits on the user (a question in its report) this long without an answer carries on with its best
    /// assumption and says what it assumed. Zero turns this off.
    public var assumeAfterSeconds: TimeInterval
    /// A job left waiting on the user this long is ended (it no longer shows as waiting), and a harness still open
    /// this long after its last event is closed.
    public var idleEndSeconds: TimeInterval
    /// Scratch files, event logs and task screenshots of jobs untouched this many days are removed. Deliverables
    /// (output/), reports, notes and the job record stay.
    public var cleanupAfterDays: Int
    /// Estimated context tokens at which the harness compacts its conversation (Codex
    /// `model_auto_compact_token_limit`; Claude Code compacts on its own schedule).
    public var compactionTokens: Int

    public init(maxStepsPerRun: Int = 120, maxRunSeconds: TimeInterval = 30 * 60, commandTimeoutSeconds: TimeInterval = 300,
                assumeAfterSeconds: TimeInterval = 30 * 60, idleEndSeconds: TimeInterval = 6 * 3600, cleanupAfterDays: Int = 30,
                compactionTokens: Int = 160_000) {
        self.maxStepsPerRun = maxStepsPerRun
        self.maxRunSeconds = maxRunSeconds
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.assumeAfterSeconds = assumeAfterSeconds
        self.idleEndSeconds = idleEndSeconds
        self.cleanupAfterDays = cleanupAfterDays
        self.compactionTokens = compactionTokens
    }

    private enum CodingKeys: String, CodingKey {
        case maxStepsPerRun, maxRunSeconds, commandTimeoutSeconds, assumeAfterSeconds, idleEndSeconds, cleanupAfterDays, compactionTokens
    }

    public init(from decoder: Decoder) throws {
        let defaults = AgentLimits()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxStepsPerRun = try container.decodeIfPresent(Int.self, forKey: .maxStepsPerRun) ?? defaults.maxStepsPerRun
        maxRunSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .maxRunSeconds) ?? defaults.maxRunSeconds
        commandTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .commandTimeoutSeconds) ?? defaults.commandTimeoutSeconds
        assumeAfterSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .assumeAfterSeconds) ?? defaults.assumeAfterSeconds
        idleEndSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .idleEndSeconds) ?? defaults.idleEndSeconds
        cleanupAfterDays = try container.decodeIfPresent(Int.self, forKey: .cleanupAfterDays) ?? defaults.cleanupAfterDays
        compactionTokens = try container.decodeIfPresent(Int.self, forKey: .compactionTokens) ?? defaults.compactionTokens
    }

    /// The limits as the job's instructions state them.
    var instructionLines: [String] {
        var lines: [String] = []
        if maxStepsPerRun > 0 { lines.append("- You have about \(maxStepsPerRun) tool steps per task. Plan for fewer; if you run low, stop and report what you have.") }
        if maxRunSeconds > 0 { lines.append("- A task may take up to \(Self.phrase(maxRunSeconds)). Past that it is stopped, so report before then.") }
        if commandTimeoutSeconds > 0 {
            lines.append("- A shell command may run for up to \(Self.phrase(commandTimeoutSeconds)). Split longer work, or run it in the background and check on it.")
        }
        return lines
    }

    static func phrase(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 120 { return "\(Int(seconds)) seconds" }
        if minutes < 120 { return "\(minutes) minutes" }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? "\(Int(hours)) hours" : String(format: "%.1f hours", hours)
    }
}
