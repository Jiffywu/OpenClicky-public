import Foundation

/// Times one brain request step by step, to see where a voice turn's wait goes: the response head, the provider's
/// first event, thinking, the first answer text, the first program line and the first complete `say()` line. Also
/// counts the prompt's tokens per part. `occtl latency brain` drives it (docs/latency.md).
///
/// For Anthropic it reads the raw event stream, so thinking shows even when its text is omitted; for other dialects it
/// times the adapter's `ChatEvent`s (no response head, and thinking only when the provider streams it).
public enum BrainLatencyProbe {
    /// One timed request. Milliseconds count from just before the request is sent.
    public struct Timing: Sendable, Hashable {
        public var label: String
        public var headersMs: Int?
        /// The provider's first event (Anthropic's `message_start`): the response is under way.
        public var firstEventMs: Int?
        public var thinkingStartMs: Int?
        public var thinkingEndMs: Int?
        /// The first answer text, fences included.
        public var firstTextMs: Int?
        /// The first program text after the fence (what the drawing gets first: the orchestrator's "first token").
        public var firstCodeMs: Int?
        /// The first complete `say()` line (what the voice gets first).
        public var firstLineMs: Int?
        public var finishedMs: Int?
        public var usage: TokenUsage?
        /// Characters of thinking text received (zero when the provider omits it).
        public var thinkingCharacters = 0
        public var program = ""
        public var lines: [String] = []
        public var error: String?

        public init(label: String) { self.label = label }

        public var json: JSONValue {
            var object: [String: JSONValue] = ["label": .string(label), "program": .string(program),
                                               "lines": .array(lines.map { .string($0) }),
                                               "thinking_chars": .number(Double(thinkingCharacters))]
            let marks: [(String, Int?)] = [("headers_ms", headersMs), ("first_event_ms", firstEventMs),
                                           ("thinking_start_ms", thinkingStartMs), ("thinking_end_ms", thinkingEndMs),
                                           ("first_text_ms", firstTextMs), ("first_code_ms", firstCodeMs),
                                           ("first_line_ms", firstLineMs), ("finished_ms", finishedMs)]
            for (key, value) in marks { if let value { object[key] = .number(Double(value)) } }
            if let usage {
                object["usage"] = ["input": .number(Double(usage.inputTokens)), "cached": .number(Double(usage.cachedInputTokens)),
                                   "cache_write": .number(Double(usage.cacheWriteTokens)), "output": .number(Double(usage.outputTokens))]
            }
            if let error { object["error"] = .string(error) }
            return .object(object)
        }
    }

    /// Sends `request` once (streaming) and times it. An Anthropic client inside the usage meter is timed on its raw
    /// stream too (the meter isn't charged for these probe requests).
    public static func time(_ request: ChatRequest, on client: any LanguageModelClient, label: String) async -> Timing {
        if let anthropic = EngineFactory.unwrapped(client) as? AnthropicMessagesClient {
            return await timeAnthropic(request, on: anthropic, label: label)
        }
        var timing = Timing(label: label)
        var answer = AnswerTimer()
        let clock = ContinuousClock()
        let start = clock.now
        func ms() -> Int { Self.milliseconds(clock.now - start) }
        var reply = ChatReply()
        do {
            for try await event in client.stream(request) {
                reply.apply(event)
                if timing.firstEventMs == nil { timing.firstEventMs = ms() }
                switch event {
                case .reasoningDelta(let text):
                    if timing.thinkingStartMs == nil { timing.thinkingStartMs = ms() }
                    timing.thinkingCharacters += text.count
                case .textDelta(let text):
                    if timing.thinkingStartMs != nil, timing.thinkingEndMs == nil { timing.thinkingEndMs = ms() }
                    if timing.firstTextMs == nil { timing.firstTextMs = ms() }
                    answer.feed(text, at: ms(), into: &timing)
                default: break
                }
            }
        } catch {
            timing.error = String(describing: error)
        }
        answer.finish(at: ms(), into: &timing)
        timing.finishedMs = ms()
        timing.usage = reply.usage
        return timing
    }

    /// The raw Anthropic stream, so an omitted thinking block still shows when it starts and stops.
    static func timeAnthropic(_ request: ChatRequest, on client: AnthropicMessagesClient, label: String) async -> Timing {
        var timing = Timing(label: label)
        var answer = AnswerTimer()
        var decoder = AnthropicStreamDecoder(provider: client.context.provider.id)
        var thinkingBlocks = Set<Int>()
        let clock = ContinuousClock()
        let start = clock.now
        func ms() -> Int { Self.milliseconds(clock.now - start) }
        do {
            let (chunks, response) = try await client.context.http.stream(for: client.makeURLRequest(request))
            timing.headersMs = ms()
            guard (200..<300).contains(response.statusCode) else {
                throw await AnthropicMessagesClient.httpError(status: response.statusCode, body: chunks, provider: client.context.provider.id)
            }
            for try await event in chunks.serverSentEvents() {
                let payload = try? JSONValue.parse(event.data)
                let type = payload?["type"]?.stringValue ?? event.event ?? ""
                if timing.firstEventMs == nil, type != "ping" { timing.firstEventMs = ms() }
                if type == "content_block_start", payload?["content_block"]?["type"]?.stringValue == "thinking",
                   let index = payload?["index"]?.intValue {
                    thinkingBlocks.insert(index)
                    if timing.thinkingStartMs == nil { timing.thinkingStartMs = ms() }
                }
                if type == "content_block_stop", let index = payload?["index"]?.intValue, thinkingBlocks.contains(index) {
                    timing.thinkingEndMs = ms()
                }
                for chatEvent in try decoder.consume(event) {
                    switch chatEvent {
                    case .reasoningDelta(let text): timing.thinkingCharacters += text.count
                    case .textDelta(let text):
                        if timing.firstTextMs == nil { timing.firstTextMs = ms() }
                        answer.feed(text, at: ms(), into: &timing)
                    case .usage(let usage): timing.usage = usage
                    default: break
                    }
                }
                if decoder.isComplete { break }
            }
        } catch {
            timing.error = String(describing: error)
        }
        answer.finish(at: ms(), into: &timing)
        timing.finishedMs = ms()
        return timing
    }

    /// Follows the answer text the way the brain runtime does (fence stripped, prose lines held, say() lines pulled
    /// out), marking the first program text and the first whole line.
    struct AnswerTimer {
        var fence = ProgramFenceStripper()
        var filter = ProgramLineFilter()
        var extractor = SayLineExtractor()

        mutating func feed(_ text: String, at ms: Int, into timing: inout Timing) {
            take(filter.feed(fence.feed(text)), at: ms, into: &timing)
        }

        mutating func finish(at ms: Int, into timing: inout Timing) {
            take(filter.feed(fence.finish()) + filter.finish(), at: ms, into: &timing)
        }

        private mutating func take(_ code: String, at ms: Int, into timing: inout Timing) {
            guard !code.isEmpty else { return }
            if timing.firstCodeMs == nil { timing.firstCodeMs = ms }
            timing.program += code
            for line in extractor.feed(code) {
                if timing.firstLineMs == nil { timing.firstLineMs = ms }
                timing.lines.append(line.text)
            }
        }
    }

    // MARK: - Prompt size

    /// Input tokens `request` would use, from Anthropic's free token-counting endpoint
    /// (https://platform.claude.com/docs/en/build-with-claude/token-counting). Caching hints and output settings are
    /// left out; they don't change the count.
    public static func countTokens(_ request: ChatRequest, on client: AnthropicMessagesClient) async throws -> Int {
        var plain = request
        plain.promptCache = nil
        plain.reasoningEffort = nil
        plain.thinking = nil
        guard case .object(var body) = client.requestBody(plain) else { return 0 }
        body["stream"] = nil
        body["max_tokens"] = nil
        var headers = ["anthropic-version": client.effectiveAPIVersion]
        if let key = client.context.apiKey, !key.isEmpty { headers["x-api-key"] = key }
        let url = client.messagesURL.appendingPathComponent("count_tokens")
        let (data, response) = try await client.context.http.data(for: client.context.jsonRequest(url, body: .object(body), headers: headers))
        let payload = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard (200..<300).contains(response.statusCode), let tokens = payload["input_tokens"]?.intValue else {
            throw AnthropicStreamDecoder.streamError(payload, provider: client.context.provider.id, status: response.statusCode)
        }
        return tokens
    }

    /// One part of the prompt and the input tokens it adds.
    public struct PromptPart: Sendable, Hashable {
        public var name: String
        public var characters: Int
        public var tokens: Int
    }

    /// Tokens per part of `request`: each system section, the tool definitions, the earlier thread and this turn's
    /// message (notes, screenshot and words). Sections are counted as the difference they make on their own, so the
    /// parts add up to about the whole (a few tokens of framing differ).
    public static func promptParts(of request: ChatRequest, sections: [(name: String, text: String)],
                                   on client: AnthropicMessagesClient) async throws -> (parts: [PromptPart], total: Int) {
        let probe = ChatMessage.user(.text("."))
        func count(system: String?, tools: [ToolSpec], messages: [ChatMessage]) async throws -> Int {
            var trial = request
            trial.messages = (system.map { [ChatMessage.system($0)] } ?? []) + messages
            trial.tools = tools
            trial.hostedTools = []
            return try await countTokens(trial, on: client)
        }
        let baseline = try await count(system: nil, tools: [], messages: [probe])
        var parts: [PromptPart] = []
        for section in sections {
            let tokens = try await count(system: section.text, tools: [], messages: [probe]) - baseline
            parts.append(PromptPart(name: "system: " + section.name, characters: section.text.count, tokens: tokens))
        }
        let toolChars = request.tools.reduce(0) { $0 + $1.name.count + $1.description.count + $1.parameters.jsonString().count }
        let toolTokens = try await count(system: nil, tools: request.tools, messages: [probe]) - baseline
        parts.append(PromptPart(name: "tool definitions (\(request.tools.count))", characters: toolChars, tokens: toolTokens))
        let conversation = request.messages.filter { $0.role != .system }
        let system = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let total = try await countTokens(request, on: client)
        if conversation.count > 1 {
            let thread = Array(conversation.dropLast())
            let threadTokens = try await count(system: nil, tools: [], messages: thread + [probe]) - baseline
            parts.append(PromptPart(name: "earlier thread (\(thread.count) messages)", characters: thread.reduce(0) { $0 + $1.text.count },
                                    tokens: threadTokens))
        }
        if let turn = conversation.last {
            let withTurn = try await count(system: system, tools: request.tools, messages: conversation)
            let withoutTurn = try await count(system: system, tools: request.tools, messages: Array(conversation.dropLast()) + [probe])
            parts.append(PromptPart(name: "this turn (notes, screenshot, words)", characters: turn.text.count, tokens: withTurn - withoutTurn))
        }
        return (parts, total)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int((Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15).rounded())
    }
}
