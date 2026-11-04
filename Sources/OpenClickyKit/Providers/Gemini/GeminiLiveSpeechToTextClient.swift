// Gemini Live push-to-talk transcription for the stt slot (dialect "gemini-live"), the way HeyClicky's "ears" use
// Gemini Live: one socket per press, manual activity markers, interim and final input transcription, and an optional
// socket opened ahead of key-down. HeyClicky reaches Gemini through its own server with a minted token; OpenClicky
// connects with the user's own API key. Wire details and doc links are in GeminiLiveWire.swift.

import Foundation

/// Streams 16 kHz PCM16 to the Gemini Live API (`BidiGenerateContent`) and turns its input transcription into
/// transcript events.
public struct GeminiLiveSpeechToTextClient: SpeechToTextClient {
    public static let defaultEndpoint = GeminiLiveWire.defaultEndpoint
    /// Google's dedicated Live transcription model.
    public static let defaultModel = "gemini-3.5-transcribe-live"

    /// How final transcription text is joined (see `GeminiLiveTranscriptMapper`).
    public enum TranscriptJoining: Sendable, Hashable {
        /// Segments for transcription models, fragments for Live agent models.
        case automatic
        /// Each final is a whole speech segment; a space separates segments.
        case segments
        /// Finals are pieces of one running transcript, appended exactly as sent.
        case fragments
    }

    public struct Options: Sendable, Hashable {
        /// How long a socket may take to answer `setup`.
        public var setupTimeout: Duration
        /// The longest `finish()` waits for the settled transcript; the last interim becomes final text after it.
        public var finalTimeout: Duration
        /// After `activityEnd`, how long to wait after a final that leaves nothing unsettled before ending.
        public var settleDelay: Duration
        /// After `activityEnd`, how long to wait when nothing was unsettled at key-up (Gemini heard nothing, or every
        /// word was already final) and no new text arrives. Any interim after key-up waits for its final instead.
        public var quietFinishTimeout: Duration
        /// How long a socket opened by `warmUp` stays open unused. Live connections last about 10 minutes.
        public var warmSocketLifetime: Duration
        /// Open the next press's socket as soon as a press takes one (HeyClicky keeps its ears warm after use).
        public var rewarmAfterUse: Bool
        /// `inputAudioTranscription.mode`: "VERBATIM" (Gemini's default) or "SMART" (cleaned up). Nil sends none.
        public var transcriptionMode: String?
        public var joining: TranscriptJoining

        public init(setupTimeout: Duration = .seconds(10), finalTimeout: Duration = .seconds(5),
                    settleDelay: Duration = .milliseconds(250), quietFinishTimeout: Duration = .milliseconds(1_500),
                    warmSocketLifetime: Duration = .seconds(120), rewarmAfterUse: Bool = false,
                    transcriptionMode: String? = nil, joining: TranscriptJoining = .automatic) {
            self.setupTimeout = setupTimeout
            self.finalTimeout = finalTimeout
            self.settleDelay = settleDelay
            self.quietFinishTimeout = quietFinishTimeout
            self.warmSocketLifetime = warmSocketLifetime
            self.rewarmAfterUse = rewarmAfterUse
            self.transcriptionMode = transcriptionMode
            self.joining = joining
        }
    }

    let context: ProviderContext
    public let model: String
    public let options: Options
    private let warm = GeminiLiveWarmSlot()

    public init(context: ProviderContext, model: String = GeminiLiveSpeechToTextClient.defaultModel, options: Options = Options()) {
        self.context = context
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
        self.options = options
    }

    public var inputFormat: PCMFormat { GeminiLiveWire.inputFormat }

    /// Starts a press. Uses the socket `warmUp` opened if it was for the same language and keywords and is still
    /// alive; otherwise connects now and holds audio until Gemini is ready.
    public func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        let key = WarmKey(language: language, keywords: keywords)
        if let session = await warm.take(key) {
            if await session.activate() {
                rewarmIfWanted(key)
                return session
            }
            await session.cancel()
        }
        let session = try await open(key, active: true)
        rewarmIfWanted(key)
        return session
    }

    /// Opens a socket and sends `setup` ahead of the next press, so key-down skips the connection and setup round
    /// trips. The socket closes after `Options.warmSocketLifetime` if no press takes it. Errors are dropped: the press
    /// then connects as usual.
    public func warmUp(language: String?, keywords: [String]) async {
        await warmUp(language: language, keywords: keywords, replacingWithin: .zero)
    }

    /// Like `warmUp`, but also replaces a warm socket that `Options.warmSocketLifetime` closes within `margin`. The
    /// new socket is stored before the old one is closed, so a press always finds one.
    public func warmUp(language: String?, keywords: [String], replacingWithin margin: Duration) async {
        let key = WarmKey(language: language, keywords: keywords)
        if await warm.holdsUsable(key, lastingAtLeast: margin) { return }
        guard let session = try? await open(key, active: false) else { return }
        await warm.store(session, key: key, lifetime: options.warmSocketLifetime)
    }

    /// Waits until the socket `warmUp` opened for these settings has finished setting up; false when there is none
    /// or it failed.
    public func waitUntilWarm(language: String?, keywords: [String]) async -> Bool {
        await warm.waitUntilReady(WarmKey(language: language, keywords: keywords))
    }

    /// Closes the socket `warmUp` opened, if any.
    public func discardWarmSocket() async {
        await warm.clear()
    }

    /// Whether a usable warm socket for these settings is open (for tests and diagnostics).
    func hasWarmSocket(language: String?, keywords: [String]) async -> Bool {
        await warm.holdsUsable(WarmKey(language: language, keywords: keywords))
    }

    private func rewarmIfWanted(_ key: WarmKey) {
        guard options.rewarmAfterUse else { return }
        let client = self
        Task { await client.warmUp(language: key.language, keywords: key.vocabulary) }
    }

    private func open(_ key: WarmKey, active: Bool) async throws -> GeminiLiveSession {
        let connection: any WebSocketConnection
        do {
            connection = try await context.webSocket.connect(makeRequest())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiLiveSession.providerError(error, provider: context.provider.id)
        }
        let session = GeminiLiveSession(connection: connection, provider: context.provider.id, options: options,
                                        setup: setupMessage(key), joining: joining)
        await session.begin(active: active)
        return session
    }

    // MARK: - Request

    /// The WebSocket upgrade request: endpoint, provider headers and the API key header (never the URL).
    func makeRequest() -> URLRequest {
        var request = URLRequest(url: GeminiLiveWire.endpoint(base: context.provider.baseURL))
        for (name, value) in context.provider.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let key = context.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }

    var family: GeminiLiveWire.ModelFamily { .of(model) }

    var joining: GeminiLiveTranscriptMapper.Joining {
        switch options.joining {
        case .segments: .segments
        case .fragments: .fragments
        case .automatic: family == .transcription ? .segments : .fragments
        }
    }

    func setupMessage(language: String?, keywords: [String]) -> JSONValue {
        setupMessage(WarmKey(language: language, keywords: keywords))
    }

    private func setupMessage(_ key: WarmKey) -> JSONValue {
        GeminiLiveWire.setup(model: model, family: family, language: key.language, vocabulary: key.vocabulary,
                             mode: options.transcriptionMode?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The settings baked into a socket's `setup`; a warm socket only serves a press with the same ones.
struct WarmKey: Sendable, Hashable {
    var language: String?
    var vocabulary: [String]

    init(language: String?, keywords: [String]) {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.vocabulary = Self.vocabulary(keywords)
    }

    /// Trimmed, non-empty, de-duplicated terms, capped at the documented 1,000.
    static func vocabulary(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for keyword in keywords {
            let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == GeminiLiveWire.maxVocabularyTerms { break }
        }
        return terms
    }
}

/// Holds at most one socket opened ahead of key-down.
actor GeminiLiveWarmSlot {
    private var entry: (key: WarmKey, session: GeminiLiveSession, expiry: Task<Void, Never>, expiresAt: ContinuousClock.Instant)?

    deinit {
        if let entry {
            entry.expiry.cancel()
            let session = entry.session
            Task { await session.cancel() }
        }
    }

    /// Hands over the warm session if it matches and is still usable; otherwise closes it.
    func take(_ key: WarmKey) async -> GeminiLiveSession? {
        guard let current = entry else { return nil }
        entry = nil
        current.expiry.cancel()
        if current.key == key, await current.session.isReusable { return current.session }
        await current.session.cancel()
        return nil
    }

    func waitUntilReady(_ key: WarmKey) async -> Bool {
        guard let current = entry, current.key == key else { return false }
        return await current.session.waitUntilReady()
    }

    /// True when the warm session matches, is usable and stays open for at least `remaining` more.
    func holdsUsable(_ key: WarmKey, lastingAtLeast remaining: Duration = .zero) async -> Bool {
        guard let current = entry, current.key == key, ContinuousClock.now + remaining < current.expiresAt else { return false }
        return await current.session.isReusable
    }

    func store(_ session: GeminiLiveSession, key: WarmKey, lifetime: Duration) async {
        let previous = entry
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            await self?.expire(session)
        }
        entry = (key, session, expiry, ContinuousClock.now + lifetime)
        if let previous {
            previous.expiry.cancel()
            await previous.session.cancel()
        }
    }

    func clear() async {
        guard let current = entry else { return }
        entry = nil
        current.expiry.cancel()
        await current.session.cancel()
    }

    private func expire(_ session: GeminiLiveSession) async {
        guard let current = entry, current.session === session else { return }
        entry = nil
        await session.cancel()
    }
}

// MARK: - Redaction

/// `context` carries the API key, and Swift's default description of a struct prints every stored property, so
/// `print(client)`, `"\(client)"` or `dump(client)` would show the key. Describe the client without it.
extension GeminiLiveSpeechToTextClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let key = (context.apiKey?.isEmpty == false) ? "set" : "none"
        return "GeminiLiveSpeechToTextClient(provider: \(context.provider.id), model: \(model), apiKey: \(key))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["provider": context.provider.id, "model": model, "options": options], displayStyle: .struct)
    }
}
