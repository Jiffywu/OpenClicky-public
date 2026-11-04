import Foundation
import Testing
@testable import OpenClickyKit

/// Records the waits a retry asked for, without waiting.
final class RecordedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [TimeInterval] = []
    var all: [TimeInterval] { lock.withLock { waits } }
    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] wait in lock.withLock { waits.append(wait) } }
    }
}

/// A transport that throws the scripted errors first, then answers from a fake.
final class FailingFirstTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error]
    let fake: FakeHTTPTransport
    private(set) var attempts = 0

    init(errors: [Error], then responses: [FakeHTTPTransport.Scripted]) {
        self.errors = errors
        fake = FakeHTTPTransport(responses)
    }

    private func nextError() -> Error? {
        lock.withLock {
            attempts += 1
            return errors.isEmpty ? nil : errors.removeFirst()
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let error = nextError() { throw error }
        return try await fake.data(for: request)
    }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        if let error = nextError() { throw error }
        return try await fake.stream(for: request)
    }
}

@Suite struct InfraRetryTests {
    static let request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)

    @Test func backoffGrowsIsCappedAndStopsAtTheBudget() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.5, maxDelay: 1.5, maxTotalWait: 2.5, jitter: 0.2)
        let failure = RetryableFailure(.status(503))
        #expect(policy.delay(before: 2, after: failure, waited: 0, random: 0) == 0.5)
        #expect(policy.delay(before: 3, after: failure, waited: 0.5, random: 0) == 1.0)
        // Capped at maxDelay, and jitter only shortens.
        #expect(policy.delay(before: 4, after: failure, waited: 1.0, random: 0) == 1.5)
        #expect(policy.delay(before: 2, after: failure, waited: 0, random: 1)! == 0.4)
        // Past the attempt count or the total budget: give up.
        #expect(policy.delay(before: 5, after: failure, waited: 0, random: 0) == nil)
        #expect(policy.delay(before: 4, after: failure, waited: 1.5, random: 0) == nil)
        #expect(RetryPolicy.none.delay(before: 2, after: failure, waited: 0, random: 0) == nil)
    }

    @Test func retryAfterIsHonouredOrTheCallGivesUp() {
        let policy = RetryPolicy.brain
        #expect(policy.delay(before: 2, after: RetryableFailure(.status(429), retryAfter: 2), waited: 0, random: 0.5) == 2)
        // Longer than the policy will wait for one retry: the turn fails now instead of hanging.
        #expect(policy.delay(before: 2, after: RetryableFailure(.status(429), retryAfter: 30), waited: 0, random: 0) == nil)
    }

    @Test func retryAfterHeadersAndBodiesAreRead() {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: Self.request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        #expect(ProviderRetry.retryAfter(response(["retry-after-ms": "1500"])) == 1.5)
        #expect(ProviderRetry.retryAfter(response(["Retry-After": "3"])) == 3)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = "Tue, 14 Nov 2023 22:13:30 GMT" // 10 s after `now`
        #expect(ProviderRetry.retryAfter(response(["Retry-After": date]), now: now) == 10)
        let gemini = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"17s"}]}}"#
        #expect(ProviderRetry.retryAfter(response([:]), body: gemini) == 17)
        #expect(ProviderRetry.retryAfter(response([:])) == nil)
    }

    @Test func whichFailuresAreRetried() {
        #expect(ProviderRetry.classify(ProviderError(provider: "a", status: 529, message: "overloaded")) != nil)
        #expect(ProviderRetry.classify(ProviderError(provider: "a", status: 503, message: "")) != nil)
        #expect(ProviderRetry.classify(ProviderError(provider: "a", status: 400, message: "bad")) == nil)
        #expect(ProviderRetry.classify(ProviderError(provider: "a", status: 401, message: "key")) == nil)
        // Out of quota: waiting doesn't help.
        #expect(ProviderRetry.classify(ProviderError(provider: "a", status: 429,
                                                     message: #"{"error":{"code":"insufficient_quota"}}"#)) == nil)
        #expect(ProviderRetry.classify(URLError(.networkConnectionLost)) != nil)
        #expect(ProviderRetry.classify(URLError(.notConnectedToInternet)) == nil)
        #expect(ProviderRetry.classify(URLError(.timedOut)) == nil)
        #expect(ProviderRetry.classify(CancellationError()) == nil)
    }

    @Test func anOverloadedProviderIsTriedAgainAndTheAnswerStreamsWhole() async throws {
        let fake = FakeHTTPTransport([
            .body(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529),
            .sse(AnthropicMessagesTests.basicStream),
        ])
        let sleeps = RecordedSleeps()
        let transport = RetryingHTTPTransport(base: fake, policy: .brain, sleep: sleeps.sleep, random: { 0 })
        let body = try await transport.checkedStream(for: Self.request, provider: "anthropic")
        var text = ""
        for try await chunk in body { text += String(decoding: chunk, as: UTF8.self) }
        #expect(text == AnthropicMessagesTests.basicStream)
        #expect(fake.requests.count == 2)
        #expect(sleeps.all == [0.6])
    }

    @Test func retryAfterIsWaitedForOnData() async throws {
        let fake = FakeHTTPTransport([
            .init(status: 429, headers: ["retry-after": "2"], chunks: [Data("slow down".utf8)]),
            .body(#"{"ok":true}"#),
        ])
        let sleeps = RecordedSleeps()
        let transport = RetryingHTTPTransport(base: fake, policy: .brain, sleep: sleeps.sleep)
        let data = try await transport.checkedData(for: Self.request, provider: "x")
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        #expect(sleeps.all == [2])
    }

    @Test func whenRetriesRunOutTheProvidersOwnAnswerReachesTheAdapter() async throws {
        let fake = FakeHTTPTransport([
            .body("busy 1", status: 503), .body("busy 2", status: 503), .body("busy 3", status: 503),
        ])
        let transport = RetryingHTTPTransport(base: fake, policy: .brain, sleep: RecordedSleeps().sleep)
        do {
            _ = try await transport.checkedStream(for: Self.request, provider: "anthropic")
            Issue.record("expected a failure")
        } catch let error as ProviderError {
            #expect(error.status == 503)
            #expect(error.message == "busy 3")
        }
        #expect(fake.requests.count == 3)
    }

    @Test func refusalsThatWontPassAreNotRetried() async throws {
        for (status, body) in [(400, "bad request"), (401, "invalid x-api-key"), (429, #"{"error":{"code":"insufficient_quota"}}"#)] {
            let fake = FakeHTTPTransport([.body(body, status: status), .body("{}")])
            let transport = RetryingHTTPTransport(base: fake, policy: .brain, sleep: RecordedSleeps().sleep)
            await #expect(throws: ProviderError.self) { _ = try await transport.checkedStream(for: Self.request, provider: "p") }
            #expect(fake.requests.count == 1)
        }
    }

    @Test func aDroppedConnectionBeforeTheAnswerIsTriedAgain() async throws {
        let transport = FailingFirstTransport(errors: [URLError(.networkConnectionLost)], then: [.body("{}")])
        let retrying = RetryingHTTPTransport(base: transport, policy: .voice, sleep: RecordedSleeps().sleep)
        _ = try await retrying.checkedData(for: Self.request, provider: "p")
        #expect(transport.attempts == 2)
        // Offline doesn't pass in a second: thrown at once.
        let offline = FailingFirstTransport(errors: [URLError(.notConnectedToInternet)], then: [.body("{}")])
        await #expect(throws: URLError.self) {
            _ = try await RetryingHTTPTransport(base: offline, policy: .voice, sleep: RecordedSleeps().sleep).checkedData(for: Self.request, provider: "p")
        }
        #expect(offline.attempts == 1)
    }

    @Test func sessionOpensAreRetriedOnRefusalsThatPass() async throws {
        let attempts = InfraCounter()
        let value = try await ProviderRetry.run(policy: .realtime, host: "api.openai.com", sleep: RecordedSleeps().sleep) {
            if attempts.next() == 1 { throw ProviderError(provider: "api.openai.com", status: 503, message: "refused (HTTP 503)") }
            return "open"
        }
        #expect(value == "open")
        #expect(attempts.value == 2)
    }

    @Test func theFactoryRetriesTheBrainAndMetersTheTurn() async throws {
        let fake = FakeHTTPTransport([
            .body(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529),
            .sse(AnthropicMessagesTests.basicStream),
        ])
        let collector = UsageCollector()
        let resilience = ProviderResilience(recorder: collector, sleep: RecordedSleeps().sleep)
        let factory = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["anthropic": "test-not-a-key"]), http: fake, resilience: resilience)
        let client = try factory.languageModel(for: .brain)
        #expect(EngineFactory.unwrapped(client) is AnthropicMessagesClient)
        let reply = try await UsageContext.$current.withValue(UsageContext(surface: .typedTurn, turnID: "turn-1")) {
            try await client.completeReply(ChatRequest(model: "claude-haiku-5-5", messages: [.user(.text("hi"))]))
        }
        #expect(reply.text == "Hello! Grüße 👋")
        #expect(fake.requests.count == 2)
        let record = try #require(collector.records.first)
        #expect(collector.records.count == 1)
        #expect(record.slot == "brain")
        #expect(record.surface == "typed turn")
        #expect(record.turn == "turn-1")
        #expect(record.provider == "anthropic")
        #expect(record.inputTokens == 25 && record.outputTokens == 15)
        // Haiku 5.5: $0.10 in and $0.50 out per million tokens.
        #expect(abs((record.costUSD ?? 0) - 0.000_01) < 1e-12)
    }

    @Test func withoutResilienceTheFactoryBuildsBareAdapters() throws {
        let factory = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["anthropic": "k", "elevenlabs": "k"]), resilience: nil)
        #expect(try factory.languageModel(for: .brain) is AnthropicMessagesClient)
        #expect(try factory.speechOutput() is ElevenLabsSpeechClient)
        #expect(try factory.speechToText() is AppleSpeechClient)
    }
}

final class InfraCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

enum InfraFixtures {
    static let config = OpenClickyConfig(
        providers: [
            ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic"),
            ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: URL(string: "https://api.elevenlabs.io"), credential: "elevenlabs"),
            ProviderConfig(id: "deepgram", dialect: .deepgramListen, baseURL: URL(string: "wss://api.deepgram.com/v1/listen"), credential: "deepgram"),
            ProviderConfig(id: "apple-speech", dialect: .appleSpeech),
        ],
        slots: [.stt: SlotSelection(provider: "apple-speech", model: "on-device"),
                .voice: SlotSelection(provider: "elevenlabs", model: "eleven_flash_v2_5", voice: "voice-id"),
                .brain: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5")])
}
