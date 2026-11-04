import Foundation
import Testing
@testable import OpenClickyKit

@Suite struct InfraDiagnosisTests {
    static let regionBody = #"{"error":{"code":"unsupported_country_region_territory","message":"Country, region, or territory not supported","param":null,"type":"request_forbidden"}}"#

    @Test func probesGoToEachProvidersOwnModelsList() {
        func url(_ dialect: ProviderDialect, _ base: String?) -> String? {
            ProviderProbe.probeURL(for: ProviderConfig(id: "p", dialect: dialect, baseURL: base.flatMap(URL.init(string:))))?.absoluteString
        }
        #expect(url(.openAIRealtime, "wss://api.openai.com/v1/realtime") == "https://api.openai.com/v1/models")
        #expect(url(.openAIResponses, "https://api.openai.com/v1") == "https://api.openai.com/v1/models")
        #expect(url(.openAIChat, "https://openrouter.ai/api/v1/") == "https://openrouter.ai/api/v1/models")
        #expect(url(.anthropicMessages, "https://api.anthropic.com") == "https://api.anthropic.com/v1/models")
        #expect(url(.anthropicMessages, "https://api.anthropic.com/v1") == "https://api.anthropic.com/v1/models")
        #expect(url(.elevenLabsSpeech, "https://api.elevenlabs.io") == "https://api.elevenlabs.io/v1/models")
        #expect(url(.deepgramListen, "wss://api.deepgram.com/v1/listen") == "https://api.deepgram.com/v1/models")
        #expect(url(.geminiLive, "https://generativelanguage.googleapis.com/v1beta") == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")
        #expect(url(.geminiSpeech, nil) == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")
        // A key hidden in a base URL's query never rides along to the probe.
        #expect(url(.openAIChat, "https://gateway.example/v1?key=secret") == "https://gateway.example/v1/models")
        #expect(url(.appleSpeech, nil) == nil)
        #expect(url(.harnessLogin, nil) == nil)
    }

    @Test func probeRequestsUseTheProvidersOwnAuthHeader() {
        let url = URL(string: "https://x/v1/models")!
        let anthropic = ProviderProbe.request(for: ProviderConfig(id: "a", dialect: .anthropicMessages), url: url, apiKey: "k1", timeout: 3)
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "k1")
        #expect(anthropic.httpMethod == "GET")
        #expect(anthropic.timeoutInterval == 3)
        let deepgram = ProviderProbe.request(for: ProviderConfig(id: "d", dialect: .deepgramListen), url: url, apiKey: "k2", timeout: 3)
        #expect(deepgram.value(forHTTPHeaderField: "Authorization") == "Token k2")
        let keyless = ProviderProbe.request(for: ProviderConfig(id: "o", dialect: .openAIRealtime), url: url, apiKey: nil, timeout: 3)
        #expect(keyless.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func probeAnswersAreClassified() {
        let url = URL(string: "https://api.openai.com/v1/models")!
        func verdict(_ outcome: ProviderProbeResult.Outcome) -> ProviderVerdict {
            ProviderProbe.classify(ProviderProbeResult(url: url, outcome: outcome, seconds: 0.1))
        }
        #expect(verdict(.answered(status: 403, body: Self.regionBody, contentType: "application/json")) == .regionUnsupported)
        #expect(verdict(.answered(status: 400, body: #"{"error":{"message":"User location is not supported for the API use.","status":"FAILED_PRECONDITION"}}"#,
                                  contentType: "application/json")) == .regionUnsupported)
        #expect(verdict(.answered(status: 451, body: "", contentType: nil)) == .regionUnsupported)
        #expect(verdict(.answered(status: 401, body: "{}", contentType: "application/json")) == .keyRejected)
        #expect(verdict(.answered(status: 200, body: "{}", contentType: "application/json")) == .reachable)
        #expect(verdict(.answered(status: 403, body: "<html>Access denied by policy</html>", contentType: "text/html")) == .networkBlocked)
        #expect(verdict(.answered(status: 407, body: "", contentType: nil)) == .networkBlocked)
        #expect(verdict(.answered(status: 302, body: "", contentType: nil)) == .networkBlocked)
        #expect(verdict(.answered(status: 503, body: "", contentType: nil)) == .providerDown)
        #expect(verdict(.answered(status: 429, body: "", contentType: nil)) == .rateLimited)
        #expect(verdict(.failed(.notConnectedToInternet)) == .offline)
        #expect(verdict(.failed(.cannotFindHost)) == .networkBlocked)
        #expect(verdict(.failed(.secureConnectionFailed)) == .networkBlocked)
        // A probe that times out can't tell a silent firewall from a slow provider.
        #expect(verdict(.failed(.timedOut)) == .noAnswer)
    }

    @Test func aRegionRefusalIsExplainedPlainly() async {
        let fake = FakeHTTPTransport([.body(Self.regionBody, status: 403)])
        let diagnostician = ProviderDiagnostician(probe: ProviderProbe(http: fake))
        let provider = ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: "wss://api.openai.com/v1/realtime"),
                                      credential: "openai")
        let failure = ProviderError(provider: "api.openai.com", status: 403, message: "The server refused the WebSocket connection (HTTP 403 Forbidden).")
        let diagnosis = await diagnostician.diagnose(provider: provider, apiKey: nil, purpose: .alwaysOnVoice, failure: failure)
        #expect(diagnosis.verdict == .regionUnsupported)
        #expect(diagnosis.providerName == "OpenAI")
        #expect(diagnosis.explanation.hasPrefix("OpenAI doesn't offer its service in your country or region, so always-on voice can't connect."))
        #expect(diagnosis.headline == "OpenAI isn't available in your region.")
        #expect(fake.requests.first?.url?.absoluteString == "https://api.openai.com/v1/models")
    }

    @Test func aBlockedStreamingConnectionToAReachableHostIsNetworkBlockedAndCached() async {
        let fake = FakeHTTPTransport([.body(#"{"data":[]}"#)])
        let diagnostician = ProviderDiagnostician(probe: ProviderProbe(http: fake))
        let provider = ProviderConfig(id: "deepgram", dialect: .deepgramListen, baseURL: URL(string: "wss://api.deepgram.com/v1/listen"))
        let first = await diagnostician.diagnose(provider: provider, apiKey: nil, purpose: .listening, failure: URLError(.cannotConnectToHost))
        #expect(first.verdict == .networkBlocked)
        #expect(first.explanation.contains("This network is blocking api.deepgram.com, so listening can't reach Deepgram."))
        // Within the cache window no second probe is sent (the fake has no second answer; a probe would fail).
        let second = await diagnostician.diagnose(provider: provider, apiKey: nil, purpose: .listening, failure: URLError(.cannotConnectToHost))
        #expect(second.verdict == .networkBlocked)
        #expect(fake.requests.count == 1)
    }

    /// A probe cut short by a cancelled session learns nothing, so it isn't cached: the next failure probes again
    /// and gets the plain reason.
    @Test func aCancelledProbeIsNotCached() async {
        let http = CancelledThenAnswering(body: Self.regionBody, status: 403)
        let diagnostician = ProviderDiagnostician(probe: ProviderProbe(http: http))
        let provider = ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: "wss://api.openai.com/v1/realtime"),
                                      credential: "openai")
        let failure = ProviderError(provider: "api.openai.com", status: 403, message: "The server refused the WebSocket connection (HTTP 403 Forbidden).")
        let first = await diagnostician.diagnose(provider: provider, apiKey: nil, purpose: .alwaysOnVoice, failure: failure)
        #expect(first.verdict == .unknown)
        let second = await diagnostician.diagnose(provider: provider, apiKey: nil, purpose: .alwaysOnVoice, failure: failure)
        #expect(second.verdict == .regionUnsupported)
        #expect(second.probe?.contains("(cached)") == false)
        #expect(http.calls == 2)
    }

    @Test func failuresThatSayWhatHappenedNeedNoProbe() async {
        let fake = FakeHTTPTransport([])
        let diagnostician = ProviderDiagnostician(probe: ProviderProbe(http: fake))
        let provider = ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: URL(string: "https://api.elevenlabs.io"))
        let offline = await diagnostician.diagnose(provider: provider, apiKey: nil, purpose: .voice, failure: URLError(.notConnectedToInternet))
        #expect(offline.verdict == .offline)
        #expect(offline.explanation == "This Mac isn't connected to the internet, so the voice can't reach ElevenLabs.")
        let key = await diagnostician.diagnose(provider: provider, apiKey: nil, purpose: .voice,
                                               failure: ProviderError(provider: "elevenlabs", status: 401, message: "invalid_api_key"))
        #expect(key.verdict == .keyRejected)
        #expect(fake.requests.isEmpty)
        let apple = await diagnostician.diagnose(provider: ProviderConfig(id: "apple", dialect: .appleSpeech), apiKey: nil, purpose: .listening,
                                                 failure: URLError(.cannotConnectToHost))
        #expect(apple.verdict == .onDevice)
    }

    @Test func listeningThatCantOpenSaysWhyInTheNotch() async throws {
        struct Refusing: WebSocketConnector {
            func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
                throw ProviderError(provider: "api.deepgram.com", status: 403, message: "The server refused the WebSocket connection (HTTP 403 Forbidden).")
            }
        }
        let probe = FakeHTTPTransport([.body(#"{"err_code":"FORBIDDEN","err_msg":"Service not available in your region."}"#, status: 403)])
        let resilience = ProviderResilience(recorder: nil, diagnostician: ProviderDiagnostician(probe: ProviderProbe(http: probe)),
                                            sleep: RecordedSleeps().sleep)
        var config = InfraFixtures.config
        config.slots[.stt] = SlotSelection(provider: "deepgram", model: "nova-3")
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn(), credentials: InMemoryCredentialStore(["deepgram": "k"]),
                                    webSocket: Refusing(), resilience: resilience)
        let client = try factory.speechToText()
        do {
            _ = try await client.startSession(language: "en", keywords: [])
            Issue.record("expected a refusal")
        } catch {
            let unavailable = try #require(error as? ProviderUnavailableError)
            #expect(unavailable.diagnosis.verdict == .regionUnsupported)
            let notice = TurnNotice.listeningFailed(error)
            #expect(notice.title == "Deepgram isn't available in your region.")
            #expect(notice.detail?.contains("so listening can't connect") == true)
        }
        #expect(probe.requests.first?.value(forHTTPHeaderField: "Authorization") == "Token k")
    }

    @Test func urlErrorsFoldedIntoAdapterMessagesAreRecognised() {
        let folded = ProviderError(provider: "openai-realtime", message: "Could not connect: The operation couldn’t be completed. (NSURLErrorDomain error -1009.)")
        #expect(ProviderDiagnostician.networkCode(in: folded) == .notConnectedToInternet)
        #expect(ProviderDiagnostician.directVerdict(folded) == .offline)
        #expect(ProviderDiagnostician.networkCode(in: ProviderError(provider: "x", message: "plain")) == nil)
    }

    @Test func otherListeningFailuresStillReadAsADroppedConnection() {
        let notice = TurnNotice.listeningFailed(URLError(.networkConnectionLost))
        #expect(notice.title == TurnNotice.connectionDropped().title)
    }

    @Test func aDiagnosedFailureIsWhatTheBrainSays() {
        let diagnosis = ProviderDiagnosis(providerID: "a", providerName: "Anthropic", host: "api.anthropic.com", purpose: .brain,
                                          verdict: .networkBlocked, probe: nil, failure: "x")
        let spoken = BrainRuntime.failure(for: ProviderUnavailableError(diagnosis: diagnosis, underlying: "x")).spoken
        #expect(spoken == diagnosis.explanation)
        let limit = BrainRuntime.failure(for: UsageLimitError(status: UsageLimitStatus(level: .reached, period: .day, spentUSD: 2, limitUSD: 1, stops: true))).spoken
        #expect(limit.contains("spending limit you set for today"))
    }
}

/// Fails its first request as cancelled, then answers every later one with `body`.
final class CancelledThenAnswering: HTTPTransport, @unchecked Sendable {
    let body: String
    let status: Int
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(body: String, status: Int) {
        self.body = body
        self.status = status
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = lock.withLock { count += 1; return count }
        if call == 1 { throw URLError(.cancelled) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}
