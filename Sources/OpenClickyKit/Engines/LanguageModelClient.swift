import Foundation

/// One piece of message content. Images are sent inline; providers encode them as their dialect requires.
public enum ContentPart: Sendable, Hashable {
    case text(String)
    case image(data: Data, mimeType: String)
}

public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// The arguments as JSON text, exactly as the model produced them.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatMessage: Sendable, Hashable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: [ContentPart]
    /// Assistant messages: tool calls the model made.
    public var toolCalls: [ToolCall]
    /// Tool messages: which call this result answers.
    public var toolCallID: String?
    /// Assistant messages: opaque items the provider needs back verbatim to continue the conversation (OpenAI's
    /// encrypted reasoning items, Anthropic's signed thinking blocks). Copy them from `ChatEvent.providerItems` (or
    /// use `ChatReply`) and store them with the message; never edit them. Only the adapter whose dialect matches
    /// `providerDialect` replays them, and only while the message's text and tool calls still match what the model
    /// produced; every other adapter ignores them.
    public var providerItems: [JSONValue]
    /// The dialect (`ProviderDialect` raw value) of the adapter that produced `providerItems`.
    public var providerDialect: String?
    /// Assistant messages: OpenAI's `phase` label, `"commentary"` for an intermediate update (a preamble before tool
    /// calls) or `"final_answer"`. Sent back on the assistant message so the model does not mistake a preamble for
    /// its answer. Nil when the provider gave none; other dialects ignore it.
    public var phase: String?
    /// Tool messages: the result reports a failure (Anthropic's `tool_result.is_error`).
    public var isError: Bool

    public init(role: Role, content: [ContentPart], toolCalls: [ToolCall] = [], toolCallID: String? = nil,
                providerItems: [JSONValue] = [], providerDialect: String? = nil, phase: String? = nil, isError: Bool = false) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.providerItems = providerItems
        self.providerDialect = providerDialect
        self.phase = phase
        self.isError = isError
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: [.text(text)]) }
    public static func user(_ parts: ContentPart...) -> ChatMessage { .init(role: .user, content: parts) }
    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> ChatMessage {
        .init(role: .assistant, content: text.isEmpty ? [] : [.text(text)], toolCalls: toolCalls)
    }
    /// An assistant message carrying the provider's opaque items (see `providerItems`).
    public static func assistant(_ text: String, toolCalls: [ToolCall] = [], providerItems: [JSONValue],
                                 providerDialect: String?, phase: String? = nil) -> ChatMessage {
        .init(role: .assistant, content: text.isEmpty ? [] : [.text(text)], toolCalls: toolCalls,
              providerItems: providerItems, providerDialect: providerDialect, phase: phase)
    }
    public static func tool(callID: String, result: String) -> ChatMessage {
        .init(role: .tool, content: [.text(result)], toolCallID: callID)
    }
    /// A tool result that may report a failure.
    public static func tool(callID: String, result: String, isError: Bool) -> ChatMessage {
        .init(role: .tool, content: [.text(result)], toolCallID: callID, isError: isError)
    }

    /// All text parts joined.
    public var text: String {
        content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    /// The provider items to replay for an adapter speaking `dialect`: empty unless this message's items came from
    /// that dialect.
    public func providerItems(for dialect: String) -> [JSONValue] {
        providerDialect == dialect ? providerItems : []
    }
}

public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON Schema for the arguments object.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    /// "low" / "medium" / "high" … as the model's catalog entry lists; nil = provider default.
    public var reasoningEffort: String?
    public var maxOutputTokens: Int?
    public var temperature: Double?
    /// Where the caller wants the provider to cache the prompt. Nil asks for nothing. Providers that cache
    /// automatically (OpenAI) ignore it; Anthropic needs it to cache at all.
    public var promptCache: PromptCacheHint?
    /// Tools the provider runs itself, as the raw `tools` entries its dialect expects (e.g.
    /// `HostedWebSearch.toolDefinition(for:)`), sent after the function tools. Adapters whose dialect has no hosted
    /// tools (OpenAI-compatible chat) leave them out.
    public var hostedTools: [JSONValue]
    /// Whether the model thinks before it answers, where the provider sets that apart from the effort (Anthropic).
    /// Nil keeps the adapter's default. Dialects without such a switch ignore it.
    public var thinking: ThinkingMode?

    public init(model: String, messages: [ChatMessage], tools: [ToolSpec] = [], reasoningEffort: String? = nil,
                maxOutputTokens: Int? = nil, temperature: Double? = nil, promptCache: PromptCacheHint? = nil,
                hostedTools: [JSONValue] = [], thinking: ThinkingMode? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.promptCache = promptCache
        self.hostedTools = hostedTools
        self.thinking = thinking
    }
}

/// Thinking before the answer, for providers that switch it separately from the effort.
public enum ThinkingMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// The model decides how much to think and streams a readable summary of it as reasoning text (Anthropic's
    /// adaptive thinking with `display: "summarized"`).
    case summarized
    /// The model thinks as much as with `summarized`, but nothing of it is streamed back (`display: "omitted"`). The
    /// answer starts sooner: on Claude Haiku 5.5 a voice turn's first line came about 1.4 s earlier, because the
    /// summary holds the answer text back until it is written (docs/latency.md).
    case hidden
    /// No thinking: the answer starts at once, but drawings get simpler. Anthropic accepts this only at effort high or
    /// below on the models that allow it at all (Claude Haiku 5.5 does; Claude Opus 5.5 and Sonnet 5.5 refuse it).
    case off
}

/// Prompt-cache breakpoints a caller asks for. A provider cache matches on a prefix (tools, then system, then
/// messages), so a breakpoint caches everything up to and including the block it is on.
public struct PromptCacheHint: Sendable, Hashable {
    /// Cache the tools and the system prompt (they should be byte-identical from request to request).
    public var system: Bool
    /// Cache the conversation up to and including `messages[index]`, e.g. the last message of the thread when a
    /// placeholder follows it (cache prewarming). Nil sets no such breakpoint.
    public var throughMessage: Int?
    /// Let the provider cache the whole request up to its last block (Anthropic's automatic caching), which suits a
    /// conversation that grows by appending.
    public var automatic: Bool

    public init(system: Bool = true, throughMessage: Int? = nil, automatic: Bool = false) {
        self.system = system
        self.throughMessage = throughMessage
        self.automatic = automatic
    }

    /// The stable prefix plus the growing conversation: what each turn of a chat wants.
    public static let conversation = PromptCacheHint(system: true, automatic: true)
}

public struct TokenUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    /// Input tokens written to the provider's prompt cache by this request (part of `inputTokens`). Zero when the
    /// provider doesn't report it.
    public var cacheWriteTokens: Int

    public init(inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public enum FinishReason: String, Sendable { case stop, toolCalls = "tool_calls", length, contentFilter = "content_filter", other }

/// What a streaming chat call yields. Text arrives as deltas; each tool call arrives once, complete, when the
/// model has finished writing its arguments (adapters assemble provider-specific argument deltas).
public enum ChatEvent: Sendable, Hashable {
    case textDelta(String)
    case reasoningDelta(String)
    /// A tool call's arguments are still streaming in. Lets the drawing engine start on a program early.
    case toolCallDelta(id: String, name: String, argumentsFragment: String)
    case toolCall(ToolCall)
    case usage(TokenUsage)
    /// Opaque items the provider needs back verbatim on the next request (encrypted reasoning, signed thinking),
    /// sent once at the end of the reply, before `.usage` and `.finished`, and only when there are any. Store them on
    /// the assistant message as `providerItems` with `providerDialect: dialect` (`ChatReply` does this).
    case providerItems(dialect: String, items: [JSONValue])
    case finished(FinishReason)
}

public struct ProviderError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public var provider: String
    public var status: Int?
    public var message: String

    public init(provider: String, status: Int? = nil, message: String) {
        self.provider = provider
        self.status = status
        self.message = message
    }

    public var description: String { "\(provider)\(status.map { " HTTP \($0)" } ?? ""): \(message)" }

    /// So `localizedDescription` (which adapters use when wrapping errors) reads like `description`.
    public var errorDescription: String? { description }
}

/// A streaming chat client for one provider dialect. Fills the brain slot, and the agent slot's model checks.
public protocol LanguageModelClient: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

extension LanguageModelClient {
    /// Collects a whole reply: its text and tool calls.
    public func complete(_ request: ChatRequest) async throws -> (text: String, toolCalls: [ToolCall], usage: TokenUsage?) {
        let reply = try await completeReply(request)
        return (reply.text, reply.toolCalls, reply.usage)
    }

    /// Collects a whole reply, including the provider items and phase to keep with it. `reply.message` is the
    /// assistant message to append to the conversation.
    public func completeReply(_ request: ChatRequest) async throws -> ChatReply {
        var reply = ChatReply()
        for try await event in stream(request) { reply.apply(event) }
        return reply
    }
}

/// A reply assembled from `ChatEvent`s, for callers that stream and also need the message to send back next turn.
public struct ChatReply: Sendable, Hashable {
    public var text = ""
    public var reasoning = ""
    public var toolCalls: [ToolCall] = []
    public var usage: TokenUsage?
    public var finishReason: FinishReason?
    public var providerItems: [JSONValue] = []
    public var providerDialect: String?
    /// The phase of the reply's last assistant message item, when the provider labels them (OpenAI Responses).
    public var phase: String?

    public init() {}

    public mutating func apply(_ event: ChatEvent) {
        switch event {
        case .textDelta(let delta): text += delta
        case .reasoningDelta(let delta): reasoning += delta
        case .toolCallDelta: break
        case .toolCall(let call): toolCalls.append(call)
        case .usage(let value): usage = value
        case .providerItems(let dialect, let items):
            providerDialect = dialect
            providerItems = items
            phase = items.last { $0["type"]?.stringValue == "message" && $0["phase"]?.stringValue != nil }?["phase"]?.stringValue
        case .finished(let reason): finishReason = reason
        }
    }

    /// The assistant message for the conversation history, carrying the provider items so the next request can
    /// replay them.
    public var message: ChatMessage {
        .assistant(text, toolCalls: toolCalls, providerItems: providerItems, providerDialect: providerDialect, phase: phase)
    }
}
