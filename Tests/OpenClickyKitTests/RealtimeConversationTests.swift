import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

/// A clock tests move by hand.
final class ManualSeconds: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(_ start: TimeInterval = 100) { value = start }
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    var function: @Sendable () -> TimeInterval { { [self] in self.now } }
}

/// A microphone a test feeds by hand.
final class ManualMicrophone: RealtimeMicrophone, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var startedFormats: [PCMFormat] = []
    private(set) var stops = 0

    func start(format: PCMFormat) throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lock.withLock {
            self.continuation = continuation
            startedFormats.append(format)
        }
        return stream
    }

    func stop() {
        lock.withLock {
            stops += 1
            continuation?.finish()
            continuation = nil
        }
    }

    func push(_ pcm: Data) { lock.withLock { continuation }?.yield(pcm) }
    var isStarted: Bool { lock.withLock { continuation != nil } }
}

/// PCM16 mono of a sine at `amplitude` (0…1).
func speechTone(seconds: Double, rate: Int = 24_000, amplitude: Double = 0.3) -> Data {
    let count = Int(Double(rate) * seconds)
    let samples = (0..<count).map { Int16(sin(2 * .pi * 220 * Double($0) / Double(rate)) * amplitude * 32_000) }
    return PCMConverter.pcm16(fromSamples: samples)
}

@Suite struct RealtimeEchoGateTests {
    static let format = PCMFormat.speech24k
    static let frame = 0.04

    @Test func withHeadphonesEverythingIsForwarded() {
        var gate = RealtimeEchoGate(route: .headphones)
        gate.assistantStartedSpeaking(at: 0)
        #expect(!gate.isGated(at: 0.1))
        #expect(gate.process(speechTone(seconds: Self.frame), format: Self.format, at: 0.1) == .forward)
        #expect(gate.process(Data(count: 1_920), format: Self.format, at: 0.14) == .forward)
        #expect(gate.turnSpeech > 0.03)
    }

    @Test func onSpeakersTheMicIsMutedWhileTheVoicePlaysAndForAShortRingOut() {
        var gate = RealtimeEchoGate(route: .speakers)
        gate.assistantStartedSpeaking(at: 0)
        // Echo at a moderate level never adds up to a barge-in.
        for step in 0..<30 {
            #expect(gate.process(speechTone(seconds: Self.frame, amplitude: 0.01), format: Self.format, at: Double(step) * Self.frame) == .mute)
        }
        gate.assistantStoppedSpeaking(at: 2)
        #expect(gate.process(speechTone(seconds: Self.frame, amplitude: 0.01), format: Self.format, at: 2.2) == .mute)
        #expect(gate.process(speechTone(seconds: Self.frame, amplitude: 0.01), format: Self.format, at: 2.6) == .forward)
        #expect(gate.turnSpeech < 0.1)
    }

    @Test func loudSustainedSpeechOverTheVoiceIsABargeInWithItsPrefix() {
        var gate = RealtimeEchoGate(route: .speakers)
        gate.assistantStartedSpeaking(at: 0)
        var decisions: [RealtimeEchoGate.MicDecision] = []
        var time = 0.0
        for _ in 0..<12 {
            decisions.append(gate.process(speechTone(seconds: Self.frame, amplitude: 0.5), format: Self.format, at: time))
            time += Self.frame
        }
        let index = try! #require(decisions.firstIndex { if case .bargeIn = $0 { true } else { false } })
        #expect(decisions[..<index].allSatisfy { $0 == .mute })
        // 0.35 s of loud speech at 40 ms per frame: the ninth frame opens the gate.
        #expect(index == 8)
        guard case .bargeIn(let prefix) = decisions[index] else { return }
        // Up to 0.3 s of the muted frames before it.
        #expect(prefix.count == 7 * 1_920)
        #expect(!gate.assistantSpeaking)
        #expect(decisions[(index + 1)...].allSatisfy { $0 == .forward })
    }

    @Test func committedTurnsNeedRealSpeech() {
        var gate = RealtimeEchoGate(route: .headphones)
        _ = gate.process(Data(count: 9_600), format: Self.format, at: 0)
        #expect(gate.evaluateCommit() == .discard(reason: "only 0.00 s of speech-like audio"))
        _ = gate.process(speechTone(seconds: 0.5), format: Self.format, at: 1)
        #expect(gate.evaluateCommit() == .keep)
        #expect(gate.turnSpeech == 0)
    }

    @Test func outputRoutesAreClassified() {
        #expect(AudioOutputRoute.classify(transport: .bluetooth, name: "Jeff's AirPods Pro") == .headphones)
        #expect(AudioOutputRoute.classify(transport: .builtIn, name: "MacBook Air Speakers") == .speakers)
        #expect(AudioOutputRoute.classify(transport: .builtIn, name: "External Headphones") == .headphones)
        #expect(AudioOutputRoute.classify(transport: .builtIn, name: "Built-in Output", dataSource: "Headphones") == .headphones)
        #expect(AudioOutputRoute.classify(transport: .hdmi, name: "LG UltraFine") == .speakers)
        #expect(AudioOutputRoute.classify(transport: .usb, name: "USB Audio") == .headphones)
        #expect(AudioOutputRoute.classify(transport: .virtual, name: "BlackHole") == .unknown)
        #expect(AudioOutputRoute.classify(transport: nil, name: nil) == .unknown)
        #expect(AudioOutputRoute.speakers.leaksIntoMicrophone && AudioOutputRoute.unknown.leaksIntoMicrophone)
        #expect(!AudioOutputRoute.headphones.leaksIntoMicrophone)
    }

    @Test func tripleTapsAreCountedAndToldApartFromDoubleTaps() {
        var counter = ModifierTapCounter()
        var time = 0.0
        func tap() -> Int? {
            counter.keyDown(at: time)
            time += 0.08
            let count = counter.keyUp(at: time)
            time += 0.15
            return count
        }
        #expect(tap() == 1 && tap() == 2 && tap() == 3)
        #expect(counter.settle(at: time) == nil)  // could still grow
        #expect(counter.settle(at: time + 0.5) == 3)
        #expect(counter.count == 0)

        time += 2
        #expect(tap() == 1 && tap() == 2)
        #expect(counter.settle(at: time + 0.5) == 2)

        // A long hold, a typed key or a long gap breaks the sequence.
        time += 2
        #expect(tap() == 1)
        counter.keyDown(at: time)
        #expect(counter.keyUp(at: time + 0.6) == nil)
        #expect(counter.count == 0)
        time += 2
        #expect(tap() == 1)
        counter.interrupted()
        #expect(tap() == 1)
        time += 1
        #expect(tap() == 1)
    }
}

@Suite struct RealtimeConversationTests {
    static func make(route: AudioOutputRoute = .headphones, tools: [RealtimeTool]? = nil,
                     features: RealtimeFeatures = RealtimeFeatures(imageInput: true, truncatesToHeardAudio: true, deletesItems: true, updatesInstructions: true))
        -> (RealtimeConversation, FakeRealtimeVoiceSession, RecordingRealtimeOutput, ManualSeconds) {
        let clock = ManualSeconds()
        let session = FakeRealtimeVoiceSession(features: features)
        let output = RecordingRealtimeOutput(realTime: true, clock: clock.function)
        let dispatcher = tools.map { RealtimeToolDispatcher(tools: $0) }
        let conversation = RealtimeConversation(session: session, output: output, dispatcher: dispatcher,
                                                options: .init(route: route), clock: clock.function)
        return (conversation, session, output, clock)
    }

    static func collect(_ conversation: RealtimeConversation) -> UpdateLog {
        let log = UpdateLog()
        Task { for await update in conversation.updates { log.add(update) } }
        return log
    }

    @Test func aTurnPlaysTheReplyAndKeepsTheTranscriptInOrder() async throws {
        let (conversation, session, output, clock) = Self.make()
        let log = Self.collect(conversation)
        let run = Task { await conversation.run() }
        await conversation.feedMicrophone(speechTone(seconds: 0.5))
        session.emit(.userSpeechStarted)
        session.emit(.userTurnCommitted(itemID: "u1"))
        session.emit(.responseStarted(responseID: "r1"))
        session.emit(.audio(speechTone(seconds: 0.5), itemID: "a1"))
        session.emit(.assistantTranscriptDelta("Hello!", itemID: "a1"))
        session.emit(.responseFinished(RealtimeResponseSummary(responseID: "r1", status: .completed, itemIDs: ["a1"], transcript: "Hello!")))
        // The user's transcript arrives after the reply, as Gemini's often does.
        session.emit(.userTranscript(text: "Hi there", isFinal: true, itemID: "u1"))
        #expect(await waitUntil { log.contains(.userCaption("Hi there", isFinal: true)) })
        #expect(output.isPlaying)
        #expect(await conversation.currentState == .speaking)
        clock.advance(1)
        #expect(await waitUntil { log.contains(.state(.listening)) })
        #expect(await conversation.transcript == [
            RealtimeTranscriptLine(role: .user, text: "Hi there"), RealtimeTranscriptLine(role: .assistant, text: "Hello!"),
        ])
        #expect(session.sentAudioBytes == 24_000)
        #expect(output.heardAudio.pcm.count == 24_000)
        #expect(log.contains(.assistantCaption("Hello!")))
        await conversation.close()
        _ = await run.value
        #expect(await waitUntil { log.contains(.ended(error: nil)) })
    }

    @Test func theServerHearingTheUserOverTheReplyIsABargeInWithTruncation() async throws {
        let (conversation, session, output, clock) = Self.make()
        let log = Self.collect(conversation)
        let run = Task { await conversation.run() }
        session.emit(.responseStarted(responseID: "r1"))
        session.emit(.audio(speechTone(seconds: 2), itemID: "a1"))
        #expect(await waitUntil { output.isPlaying })
        clock.advance(0.75)
        session.emit(.userSpeechStarted)
        #expect(await waitUntil { session.sent.contains { if case .interrupt = $0 { true } else { false } } })
        #expect(session.sent.contains(.interrupt(itemID: "a1", heard: 0.75, clearInput: false)))
        #expect(!output.isPlaying)
        #expect(await waitUntil { log.contains(.bargeIn(heard: 0.75)) })
        // Audio of the cut item that was still on its way is dropped.
        session.emit(.audio(speechTone(seconds: 1), itemID: "a1"))
        session.emit(.responseFinished(RealtimeResponseSummary(responseID: "r1", status: .interrupted, itemIDs: ["a1"])))
        #expect(await waitUntil { log.contains { if case .responseFinished = $0 { true } else { false } } })
        #expect(output.allSegments.count == 1)
        #expect(await conversation.bargeIns == 1)
        await conversation.close()
        _ = await run.value
    }

    @Test func onSpeakersTheGateMutesEchoAndOpensForTheUser() async throws {
        let (conversation, session, output, clock) = Self.make(route: .speakers)
        let run = Task { await conversation.run() }
        session.emit(.responseStarted(responseID: "r1"))
        session.emit(.audio(speechTone(seconds: 3), itemID: "a1"))
        #expect(await waitUntil { output.isPlaying })
        // Quiet echo: muted (silence goes to the provider instead).
        for _ in 0..<5 {
            clock.advance(0.04)
            await conversation.feedMicrophone(speechTone(seconds: 0.04, amplitude: 0.01))
        }
        #expect(session.sentSilentAudioBytes == 5 * 1_920)
        // The user talks over it: the gate opens, the voice stops and the prefix goes out.
        for _ in 0..<10 {
            clock.advance(0.04)
            await conversation.feedMicrophone(speechTone(seconds: 0.04, amplitude: 0.5))
        }
        #expect(!output.isPlaying)
        #expect(session.sent.contains { if case .interrupt(itemID: "a1", heard: _, clearInput: false) = $0 { true } else { false } })
        // Eight loud frames went out as silence before the gate opened; the 0.28 s prefix re-sends seven of them with
        // the ninth, then the tenth follows as it is.
        #expect(session.sentSilentAudioBytes == 13 * 1_920)
        #expect(session.sentAudioBytes - session.sentSilentAudioBytes == 9 * 1_920)
        #expect(await conversation.bargeIns == 1)
        await conversation.close()
        _ = await run.value
    }

    @Test func aTurnWithoutSpeechIsDropped() async throws {
        let (conversation, session, _, _) = Self.make()
        let log = Self.collect(conversation)
        let run = Task { await conversation.run() }
        await conversation.feedMicrophone(Data(count: 4_800))
        session.emit(.userSpeechStarted)
        session.emit(.userTurnCommitted(itemID: "u-noise"))
        #expect(await waitUntil { session.sent.contains(.discard("u-noise")) })
        #expect(await waitUntil { log.contains { if case .discardedTurn = $0 { true } else { false } } })
        #expect(await conversation.discardedTurns == 1)

        // Gemini can't delete items, so nothing is discarded there.
        let (other, otherSession, _, _) = Self.make(features: RealtimeFeatures(imageInput: true, truncatesToHeardAudio: false,
                                                                               deletesItems: false, updatesInstructions: false))
        let otherRun = Task { await other.run() }
        otherSession.emit(.userTurnCommitted(itemID: "g1"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!otherSession.sent.contains(.discard("g1")))
        await conversation.close()
        await other.close()
        _ = await run.value
        _ = await otherRun.value
    }

    @Test func toolCallsGoToTheDispatcherAndHeldActionsRunAfterTheReplyIsHeard() async throws {
        let ran = LockedFlag()
        let action = RealtimeTool(spec: ToolSpec(name: "open_thing", description: "", parameters: ["type": "object"]),
                                  statusLabel: "Opening…") { call in
            RealtimeToolOutcome(output: ["status": "opened", "deferred": true], succeeded: true,
                                deferred: RealtimeDeferredWork(name: call.name, callID: call.callID) {
                                    ran.set()
                                    return "[App] open_thing did not work (failed)."
                                })
        }
        let (conversation, session, output, clock) = Self.make(tools: [action])
        let log = Self.collect(conversation)
        let run = Task { await conversation.run() }
        session.emit(.responseStarted(responseID: "r1"))
        session.emit(.audio(speechTone(seconds: 0.5), itemID: "a1"))
        session.emit(.toolCall(RealtimeToolCall(callID: "c1", name: "open_thing", arguments: "{}")))
        #expect(await waitUntil { !session.toolResults.isEmpty })
        #expect(await waitUntil { log.contains(.status("Opening…")) })
        session.emit(.responseFinished(RealtimeResponseSummary(responseID: "r1", status: .completed, itemIDs: ["a1"],
                                                                 toolCalls: [RealtimeToolCall(callID: "c1", name: "open_thing", arguments: "{}")])))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!ran.isSet)  // still speaking
        clock.advance(1)
        #expect(await waitUntil { ran.isSet })
        #expect(await waitUntil { session.sent.contains(.text("[App] open_thing did not work (failed).", respond: false)) })
        #expect(await waitUntil { log.contains(.deferredActionFailed("[App] open_thing did not work (failed).")) })
        #expect(!output.isPlaying)
        #expect(await conversation.transcript.contains(RealtimeTranscriptLine(role: .tool, text: "open_thing({})")))
        await conversation.close()
        _ = await run.value
    }

    @Test func withoutToolsCallsAreAnsweredNotImplemented() async throws {
        let (conversation, session, _, _) = Self.make()
        let run = Task { await conversation.run() }
        session.emit(.toolCall(RealtimeToolCall(callID: "c1", name: "anything", arguments: "{}")))
        #expect(await waitUntil { session.toolResults.count == 1 })
        #expect(session.toolResults[0].output["status"] == "not_implemented")
        await conversation.close()
        _ = await run.value
    }

    @Test func escapeStopsTheVoiceAndDropsBufferedInput() async throws {
        let (conversation, session, output, clock) = Self.make()
        let run = Task { await conversation.run() }
        session.emit(.responseStarted(responseID: "r1"))
        session.emit(.audio(speechTone(seconds: 2), itemID: "a1"))
        #expect(await waitUntil { output.isPlaying })
        clock.advance(0.5)
        await conversation.interrupt()
        #expect(session.sent.contains(.interrupt(itemID: "a1", heard: 0.5, clearInput: true)))
        #expect(!output.isPlaying)
        #expect(await conversation.currentState == .listening)
        await conversation.close()
        _ = await run.value
    }

    @Test func aFailedSessionEndsTheConversationWithItsError() async throws {
        let (conversation, session, _, _) = Self.make()
        let log = Self.collect(conversation)
        let run = Task { await conversation.run() }
        session.emit(.goingAway(timeLeft: .seconds(5)))
        session.finish(throwing: ProviderError(provider: "gemini-live", message: "gone"))
        let error = await run.value
        #expect((error as? ProviderError)?.message == "gone")
        #expect(await waitUntil { log.contains { if case .ended(let text) = $0 { text?.contains("gone") == true } else { false } } })
        #expect(log.contains { if case .warning(let text) = $0 { text.contains("5") } else { false } })
    }

    @Test func theSimulatedServerRunsAWholeExchangeHeadlessly() async throws {
        let client = SimulatedRealtimeVoiceClient(replyText: "Done.", replySeconds: 0.2)
        let shot = TurnScreenshot(jpeg: Data([0xFF, 0xD8]), label: "main display", isCursorScreen: true,
                                  pixelSize: CGSize(width: 10, height: 10), displayFrame: .zero)
        let toolbox = RealtimeToolbox.standard(screen: StaticRealtimeScreenSource(screenshot: shot), brain: nil)
        let session = try await client.connect(RealtimeSessionConfiguration(instructions: "x", tools: toolbox.specs))
        let output = RecordingRealtimeOutput(realTime: false)
        let conversation = RealtimeConversation(session: session, output: output, dispatcher: toolbox.dispatcher())
        let run = Task { await conversation.run() }
        let microphone = FileRealtimeMicrophone(pcm: speechTone(seconds: 0.6, rate: 16_000), format: .speech16k, realTime: false,
                                                trailingSilence: .seconds(1))
        for await chunk in try microphone.start(format: session.inputFormat) { await conversation.feedMicrophone(chunk) }
        #expect(await waitUntil { output.receivedAudio.pcm.count == 2 * Int(0.2 * 24_000) })
        let transcript = await conversation.transcript
        #expect(transcript.map(\.role) == [.user, .tool, .assistant])
        #expect(transcript.last?.text == "Done. I looked at your main display.")
        await conversation.close()
        _ = await run.value
    }
}

final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [RealtimeConversationUpdate] = []
    func add(_ update: RealtimeConversationUpdate) { lock.withLock { updates.append(update) } }
    var all: [RealtimeConversationUpdate] { lock.withLock { updates } }
    func contains(_ update: RealtimeConversationUpdate) -> Bool { all.contains(update) }
}

extension UpdateLog {
    func contains(_ predicate: (RealtimeConversationUpdate) -> Bool) -> Bool { all.contains(where: predicate) }
}

@Suite struct AlwaysOnVoiceTests {
    final class Harness: @unchecked Sendable {
        let microphone = ManualMicrophone()
        private let lock = NSLock()
        private var sessions: [FakeRealtimeVoiceSession] = []
        private var configurations: [RealtimeSessionConfiguration] = []
        var route: AudioOutputRoute = .headphones
        var failConnect = false

        var all: [FakeRealtimeVoiceSession] { lock.withLock { sessions } }
        var configs: [RealtimeSessionConfiguration] { lock.withLock { configurations } }

        func environment(requireHeadphones: Bool = true, maxReconnects: Int = 1) -> AlwaysOnVoiceController.Environment {
            AlwaysOnVoiceController.Environment(
                connect: { configuration in
                    if self.failConnect { throw ProviderError(provider: "fake", message: "no network") }
                    let session = FakeRealtimeVoiceSession(inputFormat: .speech16k)
                    self.lock.withLock {
                        self.sessions.append(session)
                        self.configurations.append(configuration)
                    }
                    return session
                },
                configuration: { route in
                    RealtimeSessionConfiguration(instructions: "x", turnDetection: .serverVAD(route == .headphones ? .headphones : .speakers))
                },
                toolbox: RealtimeToolbox([]),
                makeOutput: { RecordingRealtimeOutput(realTime: false) },
                microphone: microphone, outputRoute: { self.route }, requireHeadphones: requireHeadphones,
                maxReconnects: maxReconnects)
        }
    }

    @Test func itRefusesToStartOnSpeakersUnlessAllowed() async {
        let harness = Harness()
        harness.route = .speakers
        let controller = AlwaysOnVoiceController(environment: harness.environment())
        let state = await controller.toggle()
        guard case .refused(let reason) = state else { Issue.record("expected a refusal, got \(state)"); return }
        #expect(reason.contains("headphones"))
        #expect(harness.all.isEmpty)

        let lenient = AlwaysOnVoiceController(environment: harness.environment(requireHeadphones: false))
        #expect(await lenient.toggle() == .on)
        #expect(harness.configs.first?.turnDetection == .serverVAD(.speakers))
        await lenient.stop()
    }

    @Test func toggleTurnsItOnStreamsTheMicAndTurnsItOff() async throws {
        let harness = Harness()
        let controller = AlwaysOnVoiceController(environment: harness.environment())
        let states = StateLog()
        Task { for await update in controller.updates { if case .state(let state) = update { states.add(state) } } }
        #expect(await controller.toggle() == .on)
        #expect(harness.microphone.startedFormats == [.speech16k])
        let session = try #require(harness.all.first)
        harness.microphone.push(speechTone(seconds: 0.1, rate: 16_000))
        #expect(await waitUntil { session.sentAudioBytes == 3_200 })
        #expect(await controller.currentConversation != nil)

        #expect(await controller.toggle() == .off)
        #expect(session.sent.last == .close)
        #expect(harness.microphone.stops >= 1)
        #expect(await waitUntil { states.all == [.starting, .on, .off] })
    }

    @Test func aFailedConnectIsReported() async {
        let harness = Harness()
        harness.failConnect = true
        let controller = AlwaysOnVoiceController(environment: harness.environment())
        let state = await controller.start()
        guard case .failed(let reason) = state else { Issue.record("expected failure, got \(state)"); return }
        #expect(reason.contains("no network"))
        #expect(!state.isActive)
    }

    @Test func aDroppedSessionIsReopenedThenGivenUpOn() async throws {
        let harness = Harness()
        let controller = AlwaysOnVoiceController(environment: harness.environment(maxReconnects: 1))
        #expect(await controller.start() == .on)
        harness.all[0].finish(throwing: ProviderError(provider: "fake", message: "goAway"))
        #expect(await waitUntil { harness.all.count == 2 })
        #expect(await realtimeEventually { await controller.state == .on })
        harness.all[1].finish(throwing: ProviderError(provider: "fake", message: "goAway again"))
        var final: AlwaysOnState = .on
        for _ in 0..<400 {
            final = await controller.state
            if case .failed = final { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .failed(let reason) = final else { Issue.record("expected failure, got \(final)"); return }
        #expect(reason.contains("goAway again"))
    }

    @Test func movingSoundToTheSpeakersEndsIt() async {
        let harness = Harness()
        let controller = AlwaysOnVoiceController(environment: harness.environment())
        #expect(await controller.start() == .on)
        harness.route = .speakers
        await controller.outputRouteChanged()
        guard case .refused = await controller.state else { Issue.record("expected a refusal"); return }
        #expect(harness.all[0].sent.last == .close)
    }
}

/// Polls an async condition (an actor's state) until it holds or the hang guard passes.
func realtimeEventually(_ limit: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !(await condition()) {
        if ContinuousClock.now >= deadline { return await condition() }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AlwaysOnState] = []
    func add(_ state: AlwaysOnState) { lock.withLock { states.append(state) } }
    var all: [AlwaysOnState] { lock.withLock { states } }
}

@Suite struct RealtimeSlotTests {
    static let providers: [ProviderConfig] = [
        ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: "wss://api.openai.com/v1/realtime"), credential: "openai"),
        ProviderConfig(id: "gemini-live", dialect: .geminiLive, baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta"), credential: "gemini"),
        ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: URL(string: "https://api.elevenlabs.io"), credential: "elevenlabs"),
    ]
    static let keys = InMemoryCredentialStore(["openai": "sk-x", "gemini": "g-x", "elevenlabs": "e-x"])

    static func factory(_ slots: [SlotID: SlotSelection]) throws -> EngineFactory {
        EngineFactory(config: OpenClickyConfig(providers: providers, slots: slots), catalog: try ModelCatalog.builtIn(),
                      credentials: keys, http: FakeHTTPTransport([]), webSocket: FakeWebSocket())
    }

    @Test func theFactoryBuildsBothRealtimeAdapters() throws {
        let openAI = try Self.factory([.realtimeVoice: SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1", voice: "marin")])
        let client = try #require(try openAI.realtimeVoice() as? OpenAIRealtimeVoiceClient)
        #expect(client.model == "gpt-realtime-2.1" && client.defaultVoice == "marin")
        #expect(try openAI.resolve(.realtimeVoice).adapter == "OpenAIRealtimeVoiceClient")
        #expect(try openAI.resolve(.realtimeVoice).errors.isEmpty)

        let gemini = try Self.factory([.realtimeVoice: SlotSelection(provider: "gemini-live", model: "gemini-3.8-live", voice: "Kore")])
        let geminiClient = try #require(try gemini.realtimeVoice() as? GeminiLiveVoiceClient)
        #expect(geminiClient.model == "gemini-3.8-live" && geminiClient.defaultVoice == "Kore")
        #expect(try gemini.resolve(.realtimeVoice).adapter == "GeminiLiveVoiceClient")
        #expect(try gemini.resolve(.realtimeVoice).errors.isEmpty)
        #expect(EngineFactory.adapterName(for: .geminiLive, slot: .stt) == "GeminiLiveSpeechToTextClient")
    }

    @Test func theSlotRejectsWhatCantHoldAConversation() throws {
        let empty = try Self.factory([:])
        #expect(throws: EngineFactoryError.slotEmpty(.realtimeVoice)) { _ = try empty.realtimeVoice() }
        // A transcription model is the wrong kind; a TTS provider can't serve it at all.
        let transcriber = try Self.factory([.realtimeVoice: SlotSelection(provider: "gemini-live", model: "gemini-3.5-transcribe-live")])
        #expect(!(try transcriber.resolve(.realtimeVoice).errors.isEmpty))
        let tts = try Self.factory([.realtimeVoice: SlotSelection(provider: "elevenlabs", model: "eleven_flash_v2_5")])
        #expect(throws: EngineFactoryError.self) { _ = try tts.realtimeVoice() }
    }

    @Test func geminiLiveFillsTheRealtimeSlotButNotTheLineVoice() throws {
        let catalog = try ModelCatalog.builtIn()
        #expect(ProviderDialect.geminiLive.canFill(.realtimeVoice) && ProviderDialect.geminiLive.canFill(.stt))
        #expect(!ProviderDialect.geminiLive.canFill(.voice))
        #expect(ProviderDialect.openAIRealtime.canFill(.voice) && ProviderDialect.openAIRealtime.canFill(.realtimeVoice))
        #expect(!ProviderDialect.elevenLabsSpeech.canFill(.realtimeVoice))
        let candidates = catalog.candidates(for: .realtimeVoice, dialect: .geminiLive).map(\.id)
        #expect(candidates == ["gemini-3.8-live", "gemini-3.8-live-extended-thinking"])
        #expect(catalog.candidates(for: .stt, dialect: .geminiLive).map(\.id) == ["gemini-3.5-transcribe-live"])
        let model = try #require(catalog.model("gemini-3.8-live", servedBy: .geminiLive))
        #expect(model.has(.imageInput) && model.has(.toolCalling) && model.voices?.contains("Kore") == true)
        #expect(catalog.model("gpt-realtime-2.1", servedBy: .openAIRealtime)?.has(.imageInput) == true)

        let config = OpenClickyConfig(providers: Self.providers, slots: [
            .stt: SlotSelection(provider: "gemini-live", model: "gemini-3.5-transcribe-live"),
            .voice: SlotSelection(provider: "gemini-live", model: "gemini-3.8-live"),
            .brain: SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1"),
            .agent: SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1"),
        ])
        let voiceErrors = ConfigValidator(catalog: catalog).validate(config).filter { $0.slot == .voice && $0.severity == .error }
        #expect(voiceErrors.map(\.message) == ["Provider \"gemini-live\" speaks gemini-live, which OpenClicky can't use for the voice slot."])
    }

    @Test func theExampleConfigsValidate() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/examples/config-realtime-gemini.json")
        let config = try OpenClickyConfig.load(from: url)
        let errors = ConfigValidator(catalog: try ModelCatalog.builtIn()).validate(config).filter { $0.severity == .error }
        #expect(errors.isEmpty)
        #expect(config.slots[.realtimeVoice] == SlotSelection(provider: "gemini-live", model: "gemini-3.8-live", voice: "Kore"))
    }

    @Test func instructionsMentionOnlyTheToolsOffered() {
        let bare = RealtimeInstructions.alwaysOn(now: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        #expect(!bare.contains("capture_screen") && !bare.contains("send_to_higher_model"))
        #expect(bare.contains("It is Thursday 1 January 1970, 00:00 ("))
        let full = RealtimeInstructions.alwaysOn(userName: "Jeff", memory: "- Likes tea",
                                                 toolNames: [RealtimeToolName.captureScreen, RealtimeToolName.sendToHigherModel, MemoryTools.save])
        #expect(full.contains("capture_screen") && full.contains("send_to_higher_model") && full.contains("memory tools"))
        #expect(full.contains("Jeff") && full.contains("Likes tea"))
        #expect(RealtimeInstructions.interview(answers: 4).contains("exactly 4 answers"))
        #expect(RealtimeInstructions.interviewProgress(asked: ["What do you do?"], answered: 3, total: 4).contains("closing question about AI agents"))
        #expect(RealtimeInstructions.interviewProgress(asked: [], answered: 4, total: 4).contains("three-sentence close now"))
    }
}
