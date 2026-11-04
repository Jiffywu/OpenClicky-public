import Foundation
import Testing
@testable import OpenClickyKit

/// Speaks a fixed tone-free buffer per line and records which voices were asked for.
final class HomeFakeSpeech: SpeechOutputClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [(text: String, voice: String?)] = []
    let bytesPerLine: Int
    let fail: Bool

    init(bytesPerLine: Int = 48_000, fail: Bool = false) {
        self.bytesPerLine = bytesPerLine
        self.fail = fail
    }

    func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
        lock.withLock { requests.append((text, voice)) }
        let bytes = bytesPerLine, fail = self.fail
        return AsyncThrowingStream { continuation in
            if fail {
                continuation.finish(throwing: ProviderError(provider: "fake", status: 401, message: "invalid key"))
                return
            }
            let half = bytes / 2
            continuation.yield(.audio(Data(repeating: 1, count: half), .speech24k))
            continuation.yield(.audio(Data(repeating: 2, count: bytes - half), .speech24k))
            continuation.yield(.lineFinished)
            continuation.finish()
        }
    }
}

/// Streams a scripted reply.
struct HomeFakeModel: LanguageModelClient {
    var chunks: [String]
    var error: (any Error)?
    let seen = HomeRequestLog()

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        seen.append(request)
        let chunks = self.chunks, error = self.error
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(.textDelta(chunk)) }
            if let error {
                continuation.finish(throwing: error)
                return
            }
            continuation.yield(.usage(TokenUsage(inputTokens: 120, cachedInputTokens: 0, outputTokens: 30)))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}

final class HomeRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ChatRequest] = []
    func append(_ request: ChatRequest) { lock.withLock { requests.append(request) } }
    var all: [ChatRequest] { lock.withLock { requests } }
}

@Test func voicePreviewsRenderThroughTheVoiceSlotToCachedWAVs() async throws {
    let folder = HomeTemporaryFolder("voices")
    let speech = HomeFakeSpeech()
    let renderer = VoicePreviewRenderer(cacheIdentity: "elevenlabs-speech|elevenlabs|eleven_flash_v2_5", cacheDirectory: folder.url) { speech }
    let first = try await renderer.render(voice: "EXAVITQu4vr4xnSDxMaL")
    #expect(!first.fromCache)
    #expect(first.duration == 1.0)
    #expect(first.format == .speech24k)
    let file = try #require(first.fileURL)
    let decoded = try WAVDecoder.decode(Data(contentsOf: file))
    #expect(decoded.pcm == first.pcm)
    #expect(decoded.format == .speech24k)
    #expect(file.lastPathComponent.hasPrefix("EXAVITQu4vr4xnSDxMaL-"))

    let again = try await renderer.render(voice: "EXAVITQu4vr4xnSDxMaL")
    #expect(again.fromCache)
    #expect(speech.requests.count == 1, "the second preview comes from the cache")
    _ = try await renderer.render(voice: "other voice/../x")
    #expect(speech.requests.map(\.voice) == ["EXAVITQu4vr4xnSDxMaL", "other voice/../x"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).allSatisfy { !$0.contains("/") && $0.hasSuffix(".wav") })

    // Another provider or model never reuses the clip.
    let other = VoicePreviewRenderer(cacheIdentity: "openai-speech|openai|gpt-4o-mini-tts", cacheDirectory: folder.url) { speech }
    #expect(other.cached(voice: "EXAVITQu4vr4xnSDxMaL") == nil)
}

@Test func voicePreviewFailuresSurfaceTheProviderError() async {
    let renderer = VoicePreviewRenderer(cacheIdentity: "x", cacheDirectory: nil) { HomeFakeSpeech(fail: true) }
    await #expect(throws: ProviderError.self) { try await renderer.render(voice: "a") }
    let silent = VoicePreviewRenderer(cacheIdentity: "x", cacheDirectory: nil) { HomeFakeSpeech(bytesPerLine: 0) }
    await #expect(throws: VoicePreviewError.noAudio("b")) { try await silent.render(voice: "b") }
}

@Test func voiceCatalogListsFixedAndAccountVoices() async throws {
    let catalog = try ModelCatalog.builtIn()
    let realtime = VoiceCatalog.fixedOptions(for: catalog.models(named: "gpt-realtime-2.1-mini").first)
    #expect(realtime?.map(\.id).contains("cedar") == true)
    #expect(realtime?.first { $0.id == "cedar" }?.name == "Cedar")
    #expect(VoiceCatalog.fixedOptions(for: catalog.models(named: "eleven_flash_v2_5").first) == nil)

    let http = FakeHTTPTransport([.body("""
    {"voices":[{"voice_id":"v2","name":"zed","category":"premade","labels":{}},
               {"voice_id":"v1","name":"Aria","labels":{"accent":"American","description":"calm","use_case":"narration"}},
               {"name":"no id"}]}
    """)])
    let context = ProviderContext(provider: ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: URL(string: "https://api.elevenlabs.io"),
                                                           credential: "elevenlabs"), apiKey: "test-key", http: http)
    let voices = try await VoiceCatalog.elevenLabsVoices(context: context)
    #expect(voices.map(\.id) == ["v1", "v2"])
    #expect(voices.first?.detail == "calm, American, narration")
    #expect(voices.last?.detail == "premade")
    #expect(http.requests.first?.url?.absoluteString == "https://api.elevenlabs.io/v1/voices")
    #expect(http.requests.first?.value(forHTTPHeaderField: "xi-api-key") == "test-key")
}

@Test func voiceSettingsClampAndRoundTrip() throws {
    let folder = HomeTemporaryFolder("voices")
    let url = folder.path("voice.json")
    #expect(VoiceSettings.load(from: url) == VoiceSettings())
    try VoiceSettings(speed: 1.25, languages: ["en", "fr"]).save(to: url)
    #expect(VoiceSettings.load(from: url) == VoiceSettings(speed: 1.25, languages: ["en", "fr"]))
    try VoiceSettings(speed: 9).save(to: url)
    #expect(VoiceSettings.load(from: url).speed == 2)
    #expect(VoiceSettings.label(forSpeed: 1) == "Normal")
    #expect(VoiceSettings.label(forSpeed: 0.75) == "0.75x")
}

@Test func sentenceSplitterCutsAtSentenceEnds() {
    var splitter = SentenceSplitter()
    #expect(splitter.feed("It costs 3.5 dollars. Mr. Smith").isEmpty == false)
    #expect(splitter.feed(" said so, e.g. here! Done") == ["Mr. Smith said so, e.g. here!"])
    #expect(splitter.finish() == ["Done"])
    var lines = SentenceSplitter()
    #expect(lines.feed("First\nSecond? ") == ["First", "Second?"])
}

@Test func typedChatSendsThroughTheBrainAndRecordsTheTurn() async throws {
    let folder = HomeTemporaryFolder("chat")
    let clock = HomeClock()
    let history = HistoryStore(directory: folder.url, now: clock.function)
    let model = HomeFakeModel(chunks: ["A gyroscope keeps ", "its axis steady. It resists ", "tilting."])
    let brain = StandInTextBrain(client: model, model: "claude-haiku-5-5", extraSystemSections: { ["<active_skills>\n- Physics tutor\n</active_skills>"] })
    let chat = TypedChatController(brain: brain, history: history, clock: clock.function)
    let events = HomeEventLog()
    let turn = await chat.send("  What is a gyroscope? ", onEvent: { events.append($0) })

    #expect(turn.words == "What is a gyroscope?")
    #expect(turn.source == .text)
    #expect(turn.spokenLines == ["A gyroscope keeps its axis steady.", "It resists tilting."])
    #expect(turn.outcome == .completed)
    #expect(turn.model == "claude-haiku-5-5")
    #expect(turn.usage == HistoryUsage(input: 120, cached: 0, output: 30))
    #expect(events.all.filter { if case .sayLine = $0 { true } else { false } }.count == 2)
    #expect(try history.turns(in: turn.sessionID) == [turn])

    let request = try #require(model.seen.all.first)
    #expect(request.messages.first?.role == .system)
    #expect(request.messages.first?.text.contains("<active_skills>") == true)
    #expect(request.messages.last?.text == "What is a gyroscope?")

    // The follow-up carries the thread and lands in the same conversation.
    clock.advance(30)
    await brain.recordOutcome("[App] the user read the answer in Home")
    let followUp = await chat.send("And a gimbal?")
    #expect(followUp.sessionID == turn.sessionID)
    let second = try #require(model.seen.all.last)
    #expect(second.messages.count == 4)
    #expect(second.messages.last?.text == "[App] the user read the answer in Home\n\nAnd a gimbal?")

    await chat.startNewConversation()
    let fresh = await chat.send("New topic")
    #expect(fresh.sessionID != turn.sessionID)
    #expect(model.seen.all.last?.messages.count == 2, "a new conversation starts with an empty thread")
}

@Test func typedChatPicksUpARecentConversationAndRecordsFailures() async throws {
    let folder = HomeTemporaryFolder("chat")
    let clock = HomeClock()
    let history = HistoryStore(directory: folder.url, now: clock.function)
    try history.append(HomeHistoryFixtures.turn("old", session: "earlier", at: clock.now, words: "Hi", lines: ["Hello."]))
    clock.advance(600)
    let failing = StandInTextBrain(client: HomeFakeModel(chunks: ["Partial"], error: ProviderError(provider: "anthropic", status: 529, message: "overloaded")),
                                   model: "claude-haiku-5-5")
    let chat = TypedChatController(brain: failing, history: history, clock: clock.function)
    #expect(chat.currentSessionID() == "earlier")
    let turn = await chat.send("Still there?")
    #expect(turn.outcome == .failed)
    #expect(turn.errorDetail?.contains("529") == true)
    #expect(turn.replyText == "I couldn't reach the brain model just now.")
    #expect(history.session("earlier")?.turnCount == 2)

    // After a long quiet spell, typing starts a new conversation.
    clock.advance(7 * 3600)
    let later = TypedChatController(brain: failing, history: history, clock: clock.function)
    #expect(later.currentSessionID() != "earlier")
}

final class HomeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TurnEvent] = []
    func append(_ event: TurnEvent) { lock.withLock { events.append(event) } }
    var all: [TurnEvent] { lock.withLock { events } }
}

@Test func aConversationPickedUpFromTheHistoryGivesTheBrainItsEarlierTurns() async throws {
    let folder = HomeTemporaryFolder("chat")
    let clock = HomeClock()
    let history = HistoryStore(directory: folder.url, now: clock.function)
    try history.append(HomeHistoryFixtures.turn("t1", session: "vpn", at: clock.now, words: "What does a VPN do?",
                                                 lines: ["It encrypts your traffic.", "Sites see the server's address."]))
    var failed = HomeHistoryFixtures.turn("t2", session: "vpn", at: clock.now.addingTimeInterval(5), words: "Still there?", lines: [])
    failed.outcome = .failed
    failed.errorSpoken = "I couldn't reach the brain model just now."
    try history.append(failed)
    clock.advance(60)

    // A new process (occtl, or the app after a relaunch) continues the recent conversation.
    let model = HomeFakeModel(chunks: ["Not really."])
    let brain = StandInTextBrain(client: model, model: "claude-haiku-5-5")
    let chat = TypedChatController(brain: brain, history: history, clock: clock.function)
    let turn = await chat.send("Does it make my internet faster?")
    #expect(turn.sessionID == "vpn")
    let request = try #require(model.seen.all.last)
    #expect(request.messages.map(\.role) == [.system, .user, .assistant, .user])
    #expect(request.messages[1].text == "What does a VPN do?")
    #expect(request.messages[2].text == "It encrypts your traffic. Sites see the server's address.")
    #expect(request.messages.last?.text == "Does it make my internet faster?")
}

@Test func switchingConversationsNeverMixesTheirThreads() async throws {
    let folder = HomeTemporaryFolder("chat")
    let clock = HomeClock()
    let history = HistoryStore(directory: folder.url, now: clock.function)
    try history.append(HomeHistoryFixtures.turn("b1", session: "cameras", at: clock.now, words: "How does a camera work?",
                                                 lines: ["Light hits a sensor."]))
    clock.advance(60)
    let model = HomeFakeModel(chunks: ["Sure."])
    let brain = StandInTextBrain(client: model, model: "claude-haiku-5-5")
    let chat = TypedChatController(brain: brain, history: history, clock: clock.function)

    await chat.startNewConversation(id: "gardening")
    _ = await chat.send("When should I plant tomatoes?")
    #expect(model.seen.all.last?.messages.count == 2)

    // Picking an older conversation in Home: the brain gets that conversation, not the one it was just in.
    chat.resume(sessionID: "cameras")
    let camera = await chat.send("And a phone camera?")
    #expect(camera.sessionID == "cameras")
    let texts = try #require(model.seen.all.last).messages.map(\.text)
    #expect(texts.dropFirst() == ["How does a camera work?", "Light hits a sensor.", "And a phone camera?"])
    #expect(!texts.contains("When should I plant tomatoes?"))

    // Going back restores the first conversation from the history.
    chat.resume(sessionID: "gardening")
    _ = await chat.send("Do they need full sun?")
    let back = try #require(model.seen.all.last).messages.map(\.text)
    #expect(back.dropFirst() == ["When should I plant tomatoes?", "Sure.", "Do they need full sun?"])
}
