import Foundation

/// Provider-hosted web search: instead of OpenClicky calling a search API and handing results back as a tool output,
/// the brain's own provider searches inside the model call and cites what it found. Chosen in services.json with
/// web-search provider `brain-hosted`.
///
/// Trade-offs, as documented on 2026-10-30:
/// - OpenAI Responses (`openai-responses`): add `{"type": "web_search"}` to `tools`
///   (https://developers.openai.com/api/docs/guides/tools-web-search). Optional `search_context_size` low | medium |
///   high, `user_location{type: "approximate", country, city, region, timezone}`, `filters.allowed_domains` (up to
///   100). Output carries `web_search_call` items and `url_citation` annotations. The legacy `web_search_preview`
///   type lacks `filters`. Not every model supports it (e.g. not gpt-5 at minimal reasoning).
/// - Anthropic Messages (`anthropic-messages`): add `{"type": "web_search_20250305", "name": "web_search", "max_uses": N}`
///   (https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool). Optional `allowed_domains` or
///   `blocked_domains` (not both), `user_location{type: "approximate", …}`. Results come back as `server_tool_use` and
///   `web_search_tool_result` blocks whose `encrypted_content` must be sent back unchanged on later turns. Billed at
///   $10 per 1,000 searches plus tokens. The newer `web_search_20260209` / `web_search_20260318` versions default to
///   dynamic filtering through code execution, which adds latency a spoken answer does not want, so the basic
///   version is used.
/// - OpenAI-compatible chat (`openai-chat`) and the speech dialects have no hosted search: use a search API.
///
/// The brain can pass this definition through `ChatRequest.hostedTools` (`ToolRegistry.hostedWebSearch`), and
/// `LookupTools` leaves its own `web_search` function out when hosted search is chosen. It stays switched off: live
/// on Claude Haiku 5.5 (docs/evidence/feat-brain-runtime, run 7) the model answered in cited prose after the search
/// instead of continuing its program, and the thread does not yet keep the provider's search blocks, so a later
/// round can't see that it searched. Turning it on needs the Anthropic adapter to keep `server_tool_use` and
/// `web_search_tool_result` blocks with the message.
public enum HostedWebSearch {
    /// Whether the brain runtime sends `hostedSearchTool(for:)` to its provider. While false, choosing `brain-hosted`
    /// leaves web search off and Settings says so.
    public static let brainPassesHostedTools = false

    /// The `tools` entry that turns on hosted search for a dialect, or nil when the dialect has none.
    public static func toolDefinition(for dialect: ProviderDialect, maxUses: Int = 5, allowedDomains: [String] = [],
                                      countryCode: String? = nil, timeZone: String? = nil) -> JSONValue? {
        var location: [String: JSONValue] = [:]
        if let countryCode = LookupText.nonEmpty(countryCode), countryCode.count == 2 { location["country"] = .string(countryCode.uppercased()) }
        if let timeZone = LookupText.nonEmpty(timeZone) { location["timezone"] = .string(timeZone) }
        if !location.isEmpty { location["type"] = "approximate" }
        let domains = allowedDomains.compactMap(LookupText.nonEmpty)

        switch dialect {
        case .openAIResponses:
            var tool: [String: JSONValue] = ["type": "web_search"]
            if !domains.isEmpty { tool["filters"] = ["allowed_domains": .array(domains.prefix(100).map { .string($0) })] }
            if !location.isEmpty { tool["user_location"] = .object(location) }
            return .object(tool)
        case .anthropicMessages:
            var tool: [String: JSONValue] = ["type": "web_search_20250305", "name": "web_search", "max_uses": .number(Double(max(maxUses, 1)))]
            if !domains.isEmpty { tool["allowed_domains"] = .array(domains.map { .string($0) }) }
            if !location.isEmpty { tool["user_location"] = .object(location) }
            return .object(tool)
        default:
            return nil
        }
    }

    /// Whether a brain on this dialect can search by itself.
    public static func isSupported(by dialect: ProviderDialect) -> Bool { toolDefinition(for: dialect) != nil }
}
