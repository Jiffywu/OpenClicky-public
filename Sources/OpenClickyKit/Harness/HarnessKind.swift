import Foundation

/// Agent programs that can run OpenClicky's background jobs. Each harness has its own config format and
/// login; OpenClicky generates that config from the agent slot and passes credentials as environment variables.
public enum HarnessKind: String, Codable, Sendable, CaseIterable {
    /// OpenAI Codex CLI (`codex`), the harness HeyClicky bundles.
    case codex
    /// Anthropic Claude Code (`claude`).
    case claudeCode = "claude-code"

    /// Provider dialects the harness can talk to.
    public var supportedDialects: Set<ProviderDialect> {
        switch self {
        case .codex: [.openAIResponses, .openAIChat]
        case .claudeCode: [.anthropicMessages]
        }
    }

    /// Executable name looked up on PATH (overridable in config).
    public var executableName: String {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude"
        }
    }
}
