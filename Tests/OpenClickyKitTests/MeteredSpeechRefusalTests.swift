import Foundation
import Testing
@testable import OpenClickyKit

/// An account refusal keeps its meaning after metering explains it (#51 with #53): the ears switch away from the
/// refusing account for ten minutes, whatever the provider probe said and however the plain explanation is worded.
@Suite struct MeteredSpeechRefusalTests {
    struct Refusal: Sendable, CustomTestStringConvertible {
        var status: Int
        var message: String
        var probeStatus: Int
        var probeBody: String
        var verdict: ProviderVerdict
        var switches: Bool
        var testDescription: String { "HTTP \(status) \"\(message)\" with a \(verdict.rawValue) probe" }
    }

    static let refusals = [
        Refusal(status: 402, message: "", probeStatus: 200, probeBody: #"{"models":[]}"#, verdict: .reachable, switches: true),
        Refusal(status: 403, message: "Billing is disabled for this project", probeStatus: 403, probeBody: #"{"err_code":"FORBIDDEN"}"#,
                verdict: .forbidden, switches: true),
        Refusal(status: 429, message: "Quota exceeded for this project", probeStatus: 429, probeBody: #"{"err_code":"TOO_MANY"}"#,
                verdict: .rateLimited, switches: true),
        Refusal(status: 429, message: "Too many requests, slow down", probeStatus: 429, probeBody: #"{"err_code":"TOO_MANY"}"#,
                verdict: .rateLimited, switches: false),
        Refusal(status: 503, message: "The service is unavailable", probeStatus: 503, probeBody: #"{"err_code":"DOWN"}"#,
                verdict: .providerDown, switches: false),
    ]

    enum Path: String, Sendable, CaseIterable { case open, stream }

    @Test(arguments: refusals, Path.allCases)
    func aMeteredListeningRefusalSwitchesForTenMinutesOnlyForTheAccount(_ refusal: Refusal, _ path: Path) async throws {
        let error = ProviderError(provider: "api.deepgram.com", status: refusal.status, message: refusal.message)
        let base: any SpeechToTextClient = path == .open ? RefusingToOpen(error) : RefusingWhileListening(error)
        let metered = try Self.metered(base, probe: refusal)

        // What the ears receive: the diagnosed error, whose text is the plain explanation.
        let diagnosed = try await Self.failure(of: metered)
        #expect(diagnosed.diagnosis.verdict == refusal.verdict)

        let clock = VoiceEarsTests.TestClock()
        let sameAccount = VoiceEarsTests.FakeBatch(.success("same account heard it"))
        let onDevice = VoiceEarsTests.FakeBatch(.success("on device heard it"))
        let ears = VoiceEarsTests.ears(metered, alternate: SimulatedSpeechToText(text: "second press", chunksPerWord: 1),
                                       fallbacks: [.init(name: "gemini batch", client: sameAccount, sharesPrimaryAccount: true),
                                                   .init(name: "on device", client: onDevice, sharesPrimaryAccount: false)],
                                       clock: clock)
        let first = try await VoiceEarsTests.press(ears)
        guard refusal.switches else {
            #expect(first.report.fallback == "gemini batch")
            #expect(!first.report.startedRefusalSwitch)
            #expect(sameAccount.calls.count == 1)
            #expect(!(await ears.isRefusing()))
            return
        }
        #expect(first.report.fallback == "on device")
        #expect(first.report.startedRefusalSwitch)
        #expect(sameAccount.calls.isEmpty)
        #expect(await ears.isRefusing())

        clock.advance(9 * 60)
        let second = try await VoiceEarsTests.press(ears)
        #expect(second.report.outcome == .switched)
        #expect(second.report.recognizer == "alternate")
        clock.advance(61)
        #expect(!(await ears.isRefusing()))
    }

    @Test(arguments: refusals)
    func aMeteredSameAccountBatchRefusalSwitchesOnlyForTheAccount(_ refusal: Refusal) async throws {
        let error = ProviderError(provider: "api.deepgram.com", status: refusal.status, message: refusal.message)
        let factory = try Self.factory(refusal)
        let resilience = try #require(factory.resilience)
        let batch = MeteredSpeechToTextBatchClient(base: VoiceEarsTests.FakeBatch(.failure(error)),
                                                   identity: try #require(factory.identity(for: .stt, resilience: resilience)),
                                                   resilience: resilience)
        do {
            _ = try await batch.transcribe(DecodedAudio(pcm: Data(count: 32_000), format: .speech16k), language: nil, keywords: [])
            Issue.record("expected the batch to refuse")
        } catch {
            #expect((error as? ProviderUnavailableError)?.diagnosis.verdict == refusal.verdict)
        }

        let ears = VoiceEarsTests.ears(SimulatedSpeechToText(text: "", behavior: .failToStart("socket closed: 1011")),
                                       fallbacks: [.init(name: "gemini batch", client: batch, sharesPrimaryAccount: true),
                                                   .init(name: "on device", client: VoiceEarsTests.FakeBatch(.success("heard it")),
                                                         sharesPrimaryAccount: false)])
        let (_, _, report) = try await VoiceEarsTests.press(ears)
        #expect(report.fallback == "on device")
        #expect(report.startedRefusalSwitch == refusal.switches)
        #expect(await ears.isRefusing() == refusal.switches)
    }

    // MARK: Fixtures

    private static func factory(_ probe: Refusal? = nil) throws -> EngineFactory {
        let replies = Array(repeating: FakeHTTPTransport.Scripted.body(probe?.probeBody ?? "{}", status: probe?.probeStatus ?? 200), count: 4)
        let resilience = ProviderResilience(recorder: nil, diagnostician: ProviderDiagnostician(probe: ProviderProbe(http: FakeHTTPTransport(replies))),
                                            sleep: RecordedSleeps().sleep)
        var config = InfraFixtures.config
        config.slots[.stt] = SlotSelection(provider: "deepgram", model: "nova-3")
        return EngineFactory(config: config, catalog: try ModelCatalog.builtIn(), credentials: InMemoryCredentialStore(["deepgram": "k"]),
                             resilience: resilience)
    }

    private static func metered(_ base: any SpeechToTextClient, probe: Refusal) throws -> MeteredSpeechToTextClient {
        let factory = try factory(probe)
        let resilience = try #require(factory.resilience)
        return MeteredSpeechToTextClient(base: base, identity: try #require(factory.identity(for: .stt, resilience: resilience)),
                                         resilience: resilience)
    }

    private static func failure(of client: any SpeechToTextClient) async throws -> ProviderUnavailableError {
        do {
            let session = try await client.startSession(language: nil, keywords: [])
            for try await _ in session.events {}
        } catch {
            return try #require(error as? ProviderUnavailableError)
        }
        throw ProviderError(provider: "test", message: "the client did not fail")
    }
}

/// Refuses each session as it opens.
private struct RefusingToOpen: SpeechToTextClient {
    let error: ProviderError
    init(_ error: ProviderError) { self.error = error }
    var inputFormat: PCMFormat { .speech16k }
    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession { throw error }
}

/// Opens, then refuses before anything is heard (a socket that is turned down once audio flows).
private struct RefusingWhileListening: SpeechToTextClient {
    let error: ProviderError
    init(_ error: ProviderError) { self.error = error }
    var inputFormat: PCMFormat { .speech16k }
    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession { RefusedSession(error) }
}

private final class RefusedSession: SpeechToTextSession, @unchecked Sendable {
    let events: AsyncThrowingStream<TranscriptEvent, Error>
    init(_ error: ProviderError) {
        events = AsyncThrowingStream { $0.finish(throwing: error) }
    }
    func send(_ pcm: Data) async {}
    func finish() async {}
    func cancel() async {}
}
