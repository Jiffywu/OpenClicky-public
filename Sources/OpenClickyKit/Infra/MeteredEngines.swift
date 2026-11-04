import Foundation

// The wrappers `ProviderResilience` puts around engines: they pass everything through unchanged, count what each call
// used for the ledger, refuse calls past a stopping limit, and open sessions through `ProviderResilience.open` (retries
// and plain explanations). `base` is the adapter itself, for code that needs its concrete type.

/// A language model whose replies are metered.
public struct MeteredLanguageModelClient: LanguageModelClient {
    public let base: any LanguageModelClient
    let identity: EngineFactory.EngineIdentity
    let resilience: ProviderResilience

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let base = base, identity = identity, resilience = resilience
        return AsyncThrowingStream { continuation in
            let task = Task {
                var usage: TokenUsage?
                var reported = false
                var started = false
                var outputCharacters = 0
                var meter = identity
                meter.model = request.model.isEmpty ? identity.model : request.model
                // Written before the stream ends, so a caller that exits right after the reply still has it recorded.
                func flush() {
                    if let usage, let recorder = resilience.recorder { meter.record(UsageMeasure(usage), recorder: recorder) }
                    usage = nil
                }
                // Adapters report usage only when the reply completes, but a reply that was cancelled (a barge-in, a
                // new press) or failed after the provider began it was still billed for its input and what it had
                // written. Record an estimate, so the totals and a stopping limit count it. A request refused before
                // any reply (an HTTP error) wasn't billed and isn't recorded.
                func flushEstimate(cancelled: Bool) {
                    guard !reported, started || cancelled, let recorder = resilience.recorder else { return }
                    reported = true
                    meter.record(UsageMeasure(inputTokens: Self.estimatedInputTokens(request), outputTokens: (outputCharacters + 3) / 4),
                                 estimated: true, recorder: recorder)
                }
                do {
                    try resilience.checkLimit()
                    for try await event in base.stream(request) {
                        started = true
                        switch event {
                        case .usage(let value): usage = value; reported = true
                        case .textDelta(let text), .reasoningDelta(let text): outputCharacters += text.count
                        case .toolCallDelta(_, _, let fragment): outputCharacters += fragment.count
                        default: break
                        }
                        continuation.yield(event)
                    }
                    flush()
                    // A cancelled stream ends quietly rather than throwing.
                    if Task.isCancelled { flushEstimate(cancelled: true) }
                    continuation.finish()
                } catch {
                    flush()
                    if !(error is UsageLimitError) { flushEstimate(cancelled: Task.isCancelled || error is CancellationError) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tokens a typical screenshot costs, for estimates.
    static let estimatedImageTokens = 1_600

    /// A rough count of a request's input tokens, for a reply that stopped before the provider reported its usage:
    /// about four characters a token for text (system prompt, messages, tool calls and definitions) and a typical
    /// screenshot's tokens for each image.
    static func estimatedInputTokens(_ request: ChatRequest) -> Int {
        var characters = 0
        var images = 0
        for message in request.messages {
            for part in message.content {
                switch part {
                case .text(let text): characters += text.count
                case .image: images += 1
                }
            }
            for call in message.toolCalls { characters += call.name.count + call.arguments.count }
        }
        for tool in request.tools { characters += tool.name.count + tool.description.count + tool.parameters.jsonString().count }
        return (characters + 3) / 4 + images * estimatedImageTokens
    }

    /// One step of Anthropic's computer tool (a take-over drive) sent through `anthropic`, the adapter inside this
    /// client: refused past a stopping limit, and the reply's tokens written to the ledger under the take-over surface
    /// (keeping the current turn, when there is one).
    public func computerUseStep(_ request: AnthropicComputerUseRequest,
                                on anthropic: AnthropicMessagesClient, surface: UsageSurface = .takeover) async throws -> AnthropicComputerUseReply {
        try resilience.checkLimit()
        let reply = try await anthropic.computerUseStep(request)
        if let usage = reply.usage, let recorder = resilience.recorder {
            var meter = identity
            meter.model = request.model.isEmpty ? identity.model : request.model
            UsageContext.$current.withValue(UsageContext(surface: surface, turnID: UsageContext.current.turnID)) {
                meter.record(UsageMeasure(usage), recorder: recorder)
            }
        }
        return reply
    }
}

/// A voice whose lines are metered (characters sent, seconds of audio back). Lines on a WebSocket voice that fail
/// before any audio are retried as the slot's policy allows; HTTP voices are retried by their transport.
public struct MeteredSpeechOutputClient: SpeechOutputClient {
    public let base: any SpeechOutputClient
    let identity: EngineFactory.EngineIdentity
    let resilience: ProviderResilience

    public func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
        let base = base, identity = identity, resilience = resilience
        let retries = identity.provider.dialect.opensOverWebSocket
        return AsyncThrowingStream { continuation in
            let task = Task {
                var bytes = 0
                var seconds = 0.0
                var recorded = false
                // Characters are billed once synthesis started; a line refused outright cost nothing. Written before
                // the stream ends (and when a cancelled line stops), so nothing is lost when the caller exits.
                func flush(started: Bool) {
                    guard !recorded, started || bytes > 0, let recorder = resilience.recorder else { return }
                    recorded = true
                    identity.record(UsageMeasure(audioSeconds: seconds, characters: text.count), recorder: recorder)
                }
                defer { flush(started: false) }
                do {
                    try resilience.checkLimit()
                    var attempt = 1
                    var waited: TimeInterval = 0
                    while true {
                        do {
                            for try await event in base.speak(text, voice: voice, instructions: instructions) {
                                if case .audio(let data, let format) = event {
                                    bytes += data.count
                                    seconds += Double(data.count) / Double(max(1, format.bytesPerSecond))
                                }
                                continuation.yield(event)
                            }
                            flush(started: true)
                            continuation.finish()
                            return
                        } catch {
                            guard retries, bytes == 0, !Task.isCancelled, let failure = ProviderRetry.classify(error),
                                  let wait = resilience.policy(for: .voice).delay(before: attempt + 1, after: failure, waited: waited,
                                                                                  random: resilience.random()) else { throw error }
                            attempt += 1
                            waited += wait
                            resilience.log("voice: retrying \(identity.provider.id) in \(String(format: "%.2f", wait)) s after \(failure.label)")
                            try await resilience.sleep(wait)
                        }
                    }
                } catch {
                    flush(started: false)
                    guard bytes == 0 else { continuation.finish(throwing: error); return }
                    continuation.finish(throwing: await resilience.explain(error, slot: .voice, provider: identity.provider, apiKey: identity.apiKey))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func warmUp() async { await base.warmUp() }
    public func stopAll() async { await base.stopAll() }
}

/// Listening whose sessions open with retries and plain explanations, and whose audio is metered.
public struct MeteredSpeechToTextClient: SpeechToTextClient {
    public let base: any SpeechToTextClient
    let identity: EngineFactory.EngineIdentity
    let resilience: ProviderResilience

    public var inputFormat: PCMFormat { base.inputFormat }

    public func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        try resilience.checkLimit()
        let base = base
        let session = try await resilience.open(slot: .stt, provider: identity.provider, apiKey: identity.apiKey) {
            try await base.startSession(language: language, keywords: keywords)
        }
        return MeteredSpeechToTextSession(base: session, format: base.inputFormat, identity: identity, resilience: resilience)
    }
}

/// A metered client that retains the base client's optional warm-connection support.
struct MeteredWarmingSpeechToTextClient: SpeechToTextWarming {
    let client: MeteredSpeechToTextClient
    let warming: any SpeechToTextWarming
    var inputFormat: PCMFormat { client.inputFormat }
    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        try await client.startSession(language: language, keywords: keywords)
    }
    func warmUp(language: String?, keywords: [String]) async { await warming.warmUp(language: language, keywords: keywords) }
    func warmUp(language: String?, keywords: [String], replacingWithin margin: Duration) async {
        await warming.warmUp(language: language, keywords: keywords, replacingWithin: margin)
    }
    func waitUntilWarm(language: String?, keywords: [String]) async -> Bool { await warming.waitUntilWarm(language: language, keywords: keywords) }
    func discardWarmSocket() async { await warming.discardWarmSocket() }
}

/// A whole-recording Gemini fallback priced under its actual transcription model.
struct MeteredSpeechToTextBatchClient: SpeechToTextBatchClient {
    let base: any SpeechToTextBatchClient
    let identity: EngineFactory.EngineIdentity
    let resilience: ProviderResilience
    func transcribe(_ audio: DecodedAudio, language: String?, keywords: [String]) async throws -> String {
        try resilience.checkLimit()
        defer {
            if let recorder = resilience.recorder {
                identity.record(UsageMeasure(audioSeconds: Double(audio.pcm.count) / Double(max(1, audio.format.bytesPerSecond))), recorder: recorder)
            }
        }
        do { return try await base.transcribe(audio, language: language, keywords: keywords) }
        catch { throw await resilience.explain(error, slot: .stt, provider: identity.provider, apiKey: identity.apiKey) }
    }
}

/// A listening session that counts the audio sent. The record is made when the session finishes or is cancelled,
/// inside whatever turn did that (so it lands on the turn that heard it).
///
/// Some providers' sockets open lazily (the upgrade is refused only once audio flows), so a session whose events fail
/// before anything was heard is explained the same way a refused open is.
public final class MeteredSpeechToTextSession: SpeechToTextSessionReadiness, @unchecked Sendable {
    public let base: any SpeechToTextSession
    public let events: AsyncThrowingStream<TranscriptEvent, Error>
    private let format: PCMFormat
    private let identity: EngineFactory.EngineIdentity
    private let resilience: ProviderResilience
    private let relay: Task<Void, Never>
    private let lock = NSLock()
    private var bytes = 0
    private var recorded = false

    init(base: any SpeechToTextSession, format: PCMFormat, identity: EngineFactory.EngineIdentity, resilience: ProviderResilience) {
        self.base = base
        self.format = format
        self.identity = identity
        self.resilience = resilience
        let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        events = stream
        let source = base.events
        relay = Task {
            var heard = false
            do {
                for try await event in source {
                    heard = true
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                guard !heard else { continuation.finish(throwing: error); return }
                continuation.finish(throwing: await resilience.explain(error, slot: .stt, provider: identity.provider, apiKey: identity.apiKey))
            }
        }
        continuation.onTermination = { [relay] _ in relay.cancel() }
    }

    public var startedWarm: Bool {
        get async { await (base as? any SpeechToTextSessionReadiness)?.startedWarm ?? false }
    }

    public func waitUntilReady() async -> Bool {
        guard let ready = base as? any SpeechToTextSessionReadiness else { return true }
        return await ready.waitUntilReady()
    }

    public func send(_ pcm: Data) async {
        lock.withLock { bytes += pcm.count }
        await base.send(pcm)
    }

    public func finish() async {
        await base.finish()
        recordOnce()
    }

    public func cancel() async {
        await base.cancel()
        relay.cancel()
        recordOnce()
    }

    private func recordOnce() {
        let sent: Int? = lock.withLock {
            guard !recorded else { return nil }
            recorded = true
            return bytes
        }
        guard let sent, let recorder = resilience.recorder else { return }
        identity.record(UsageMeasure(audioSeconds: Double(sent) / Double(max(1, format.bytesPerSecond))), recorder: recorder)
    }

    deinit {
        // A session dropped without finish or cancel still used what it heard.
        recordOnce()
    }
}

/// Always-on voice whose sessions open with retries and plain explanations, and whose replies are metered.
public struct MeteredRealtimeVoiceClient: RealtimeVoiceClient {
    public let base: any RealtimeVoiceClient
    let identity: EngineFactory.EngineIdentity
    let resilience: ProviderResilience

    public var model: String { base.model }

    public func connect(_ configuration: RealtimeSessionConfiguration) async throws -> any RealtimeVoiceSession {
        try resilience.checkLimit()
        let base = base
        let session = try await resilience.open(slot: .realtimeVoice, provider: identity.provider, apiKey: identity.apiKey) {
            try await base.connect(configuration)
        }
        return MeteredRealtimeVoiceSession(base: session, identity: identity, resilience: resilience)
    }
}

/// A realtime session that writes each finished reply's tokens to the ledger. Everything else passes straight through.
public final class MeteredRealtimeVoiceSession: RealtimeVoiceSession, @unchecked Sendable {
    public let base: any RealtimeVoiceSession
    public let events: AsyncThrowingStream<RealtimeVoiceEvent, Error>
    private let relay: Task<Void, Never>

    init(base: any RealtimeVoiceSession, identity: EngineFactory.EngineIdentity, resilience: ProviderResilience) {
        self.base = base
        var identity = identity
        identity.model = base.model
        let (stream, continuation) = AsyncThrowingStream<RealtimeVoiceEvent, Error>.makeStream()
        events = stream
        let source = base.events
        relay = Task {
            do {
                for try await event in source {
                    if case .responseFinished(let summary) = event, let usage = summary.usage, let recorder = resilience.recorder {
                        identity.record(UsageMeasure(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                                                     audioInputTokens: usage.inputAudioTokens, audioOutputTokens: usage.outputAudioTokens),
                                        recorder: recorder)
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { [relay] _ in relay.cancel() }
    }

    public var inputFormat: PCMFormat { base.inputFormat }
    public var outputFormat: PCMFormat { base.outputFormat }
    public var features: RealtimeFeatures { base.features }
    public var model: String { base.model }

    public func sendAudio(_ pcm: Data) async { await base.sendAudio(pcm) }
    public func endAudioTurn() async { await base.endAudioTurn() }
    public func clearAudio() async { await base.clearAudio() }
    public func addText(_ text: String, respond: Bool) async { await base.addText(text, respond: respond) }
    public func addImage(_ data: Data, mimeType: String, caption: String?) async { await base.addImage(data, mimeType: mimeType, caption: caption) }
    public func sendToolResult(_ result: RealtimeToolResult) async { await base.sendToolResult(result) }
    public func createResponse(instructions: String?) async { await base.createResponse(instructions: instructions) }
    public func interrupt(itemID: String?, heard: TimeInterval?, clearInput: Bool) async {
        await base.interrupt(itemID: itemID, heard: heard, clearInput: clearInput)
    }
    public func discardUserTurn(itemID: String) async { await base.discardUserTurn(itemID: itemID) }
    public func updateInstructions(_ instructions: String) async { await base.updateInstructions(instructions) }
    public func close() async {
        await base.close()
        relay.cancel()
    }
}

/// Counts lookup requests (web and image search, quotes) by service.
public struct MeteredLookupTransport: HTTPTransport {
    public let base: any HTTPTransport
    let recorder: any UsageRecording
    let prices: PriceBook
    let client: String

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await base.data(for: request)
        note(request, status: result.1.statusCode)
        return result
    }

    public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await stream(for: request, mode: .lines)
    }

    public func stream(for request: URLRequest, mode: HTTPStreamMode) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let result = try await base.stream(for: request, mode: mode)
        note(request, status: result.1.statusCode)
        return result
    }

    private func note(_ request: URLRequest, status: Int) {
        // A refused request isn't billed.
        guard (200..<300).contains(status), let (provider, kind) = Self.service(for: request.url) else { return }
        let context = UsageContext.current
        let price = prices.servicePrice(provider)
        let measure = UsageMeasure(requests: 1)
        recorder.record(UsageRecord(slot: UsageRecord.lookupsSlot, surface: (context.surface ?? .lookups).rawValue, provider: provider,
                                    model: kind, turn: context.turnID, client: client, measure: measure,
                                    costUSD: price?.cost(of: measure), estimate: price?.estimate))
    }

    /// The service and kind of lookup a URL is, from its host and path.
    static func service(for url: URL?) -> (provider: String, kind: String)? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        if host.hasSuffix("search.brave.com") { return ("brave", path.contains("image") ? "image-search" : "web-search") }
        if host.hasSuffix("exa.ai") { return ("exa", "web-search") }
        if host.hasSuffix("tavily.com") { return ("tavily", "web-search") }
        if host.hasSuffix("twelvedata.com") { return ("twelve-data", "quotes") }
        if host.hasSuffix("wikimedia.org") { return ("wikimedia-commons", "image-search") }
        return (host, "lookup")
    }
}
