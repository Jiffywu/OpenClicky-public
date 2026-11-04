import Foundation
import Testing
@testable import OpenClickyKit

/// Always-on voice (#5): a session swapped in place when Gemini announces it will close (goAway) or the voice changes,
/// the muted-output notice, and the Gemini Live resumption wire. Fake sessions and a scripted socket only.
@Suite(.timeLimit(.minutes(1)))
struct AlwaysOnSessionSwapTests {
    /// Opens fake sessions and records the configuration each was opened with.
    final class Sessions: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [(session: FakeRealtimeVoiceSession, configuration: RealtimeSessionConfiguration)] = []
        private var _voice = "Kore"
        private var _failNext = false
        private var _connectDelay: Duration?
        private var _connectsStarted = 0
        private var _inputFormats: [String: PCMFormat] = [:]
        var voice: String {
            get { lock.withLock { _voice } }
            set { lock.withLock { _voice = newValue } }
        }
        /// How long each connect takes from now on (a real handshake), nil for at once.
        var connectDelay: Duration? {
            get { lock.withLock { _connectDelay } }
            set { lock.withLock { _connectDelay = newValue } }
        }
        /// Connects begun, including ones still on their way.
        var connectsStarted: Int { lock.withLock { _connectsStarted } }
        /// The input format of sessions opened with a voice (another provider or model), 24 kHz otherwise.
        var inputFormats: [String: PCMFormat] {
            get { lock.withLock { _inputFormats } }
            set { lock.withLock { _inputFormats = newValue } }
        }
        var failNext: Bool {
            get { lock.withLock { _failNext } }
            set { lock.withLock { _failNext = newValue } }
        }
        var all: [FakeRealtimeVoiceSession] { lock.withLock { opened.map(\.session) } }
        var configurations: [RealtimeSessionConfiguration] { lock.withLock { opened.map(\.configuration) } }

        func connect(_ configuration: RealtimeSessionConfiguration) throws -> any RealtimeVoiceSession {
            let fail = lock.withLock { () -> Bool in
                defer { _failNext = false }
                return _failNext
            }
            if fail { throw ProviderError(provider: "fake", message: "no room") }
            let format = configuration.voice.flatMap { voice in lock.withLock { _inputFormats[voice] } } ?? .speech24k
            let session = FakeRealtimeVoiceSession(inputFormat: format)
            lock.withLock { opened.append((session, configuration)) }
            return session
        }

        func connectSlowly(_ configuration: RealtimeSessionConfiguration) async throws -> any RealtimeVoiceSession {
            let delay = lock.withLock { () -> Duration? in
                _connectsStarted += 1
                return _connectDelay
            }
            if let delay { try await Task.sleep(for: delay) }
            return try connect(configuration)
        }
    }

    /// A mic that sends 10 ms of quiet-but-not-silent audio every 10 ms (so the gate forwards it).
    final class TickingMic: RealtimeMicrophone, @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var started: [PCMFormat] = []
        /// The format of every start, in order.
        var formats: [PCMFormat] { lock.withLock { started } }
        func start(format: PCMFormat) throws -> AsyncStream<Data> {
            lock.withLock { started.append(format) }
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            let bytes = format.bytesPerSecond / 100 / 2 * 2
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(Data(repeating: 1, count: bytes))
                    try? await Task.sleep(for: .milliseconds(10))
                }
                continuation.finish()
            }
            lock.withLock { self.task = task }
            return stream
        }
        func stop() { lock.withLock { task }?.cancel() }
    }

    static func controller(_ sessions: Sessions, margin: Duration = .milliseconds(300),
                           mic: TickingMic = TickingMic()) -> AlwaysOnVoiceController {
        var environment = AlwaysOnVoiceController.Environment(
            connect: { try await sessions.connectSlowly($0) },
            configuration: { _ in
                RealtimeSessionConfiguration(instructions: "Be brief.", voice: sessions.voice, resumable: true)
            },
            toolbox: RealtimeToolbox([]),
            makeOutput: { RecordingRealtimeOutput() },
            microphone: mic, outputRoute: { .headphones })
        environment.goAwayMargin = margin
        environment.idlePoll = .milliseconds(10)
        return AlwaysOnVoiceController(environment: environment)
    }

    static func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// A whole reply on `session`: the turn, a response with audio and its transcript.
    static func reply(on session: FakeRealtimeVoiceSession, turn: Int, words: String, answer: String) {
        session.emit(.userSpeechStopped)
        session.emit(.userTurnCommitted(itemID: "u\(turn)"))
        session.emit(.userTranscript(text: words, isFinal: true, itemID: "u\(turn)"))
        session.emit(.responseStarted(responseID: "r\(turn)"))
        session.emit(.audio(Data(count: 4_800), itemID: "a\(turn)"))
        session.emit(.assistantTranscriptDelta(answer, itemID: "a\(turn)"))
        session.emit(.responseFinished(RealtimeResponseSummary(responseID: "r\(turn)", status: .completed, itemIDs: ["a\(turn)"], transcript: answer)))
    }

    static func closed(_ session: FakeRealtimeVoiceSession) -> Bool { session.sent.contains(.close) }

    /// Notes sent to `session` without asking for a reply.
    static func notes(_ session: FakeRealtimeVoiceSession) -> [String] {
        session.sent.compactMap { if case .text(let text, false) = $0 { text } else { nil } }
    }

    /// The notch's view of a controller, from its updates.
    final class DisplayLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _display = AlwaysOnDisplay(state: .on)
        private var task: Task<Void, Never>?
        var display: AlwaysOnDisplay { lock.withLock { _display } }
        init(_ controller: AlwaysOnVoiceController) {
            task = Task { [weak self] in
                for await update in controller.updates {
                    guard let self else { return }
                    self.lock.withLock { self._display.apply(update) }
                }
            }
        }
        deinit { task?.cancel() }
    }

    // MARK: goAway

    @Test func goAwayOpensAResumingSessionAndSwapsAfterTheTurnBeforeTheOldOneCloses() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions)
        #expect(await controller.start() == .on)
        let first = try #require(sessions.all.first)
        #expect(sessions.configurations.first?.resumable == true)
        first.emit(.resumable(handle: "handle-1"))
        // The user is mid-turn when the provider says it will close in 2 s.
        first.emit(.userSpeechStarted)
        #expect(await Self.waitUntil { await controller.currentConversation?.currentState == .userSpeaking })
        let announced = ContinuousClock.now
        first.emit(.goingAway(timeLeft: .seconds(2)))

        // The replacement opens at once, from the provider's handle…
        #expect(await Self.waitUntil { sessions.all.count == 2 })
        let second = sessions.all[1]
        #expect(sessions.configurations[1].resumptionHandle == "handle-1")
        #expect(sessions.configurations[1].instructions == "Be brief.")
        // …but the turn in progress finishes on the old session.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!Self.closed(first))
        #expect(await controller.replacements.isEmpty)
        Self.reply(on: first, turn: 1, words: "what's the weather", answer: "Sunny all day.")

        // At the pause the new session takes over, well before the old one's time is up.
        #expect(await Self.waitUntil { Self.closed(first) })
        #expect(ContinuousClock.now - announced < .seconds(2))
        #expect(await controller.replacements == [.goingAway])
        #expect(await controller.state == .on)
        let old = try #require(await controller.currentConversation)
        #expect(old.session === second)
        // The old session's turn was heard in full; the mic now feeds the new session.
        let before = second.sentAudioBytes
        #expect(await Self.waitUntil { second.sentAudioBytes > before })
        // The new session resumed from before that turn, so it is told the exchange that finished on the old one.
        #expect(await Self.waitUntil { !Self.notes(second).isEmpty })
        let caughtUp = Self.notes(second).joined()
        #expect(caughtUp.contains("User: what's the weather"))
        #expect(caughtUp.contains("You: Sunny all day."))
        // Its end doesn't count as a drop: no third session.
        try await Task.sleep(for: .milliseconds(100))
        #expect(sessions.all.count == 2)
        await controller.stop()
    }

    @Test func withoutAHandleTheNewSessionIsToldTheRecentConversation() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions)
        _ = await controller.start()
        let first = try #require(sessions.all.first)
        first.emit(.userSpeechStarted)
        Self.reply(on: first, turn: 1, words: "remind me about the dentist", answer: "Okay, Thursday at three.")
        #expect(await Self.waitUntil { await controller.currentConversation?.isIdle == true })
        first.emit(.goingAway(timeLeft: .seconds(5)))
        #expect(await Self.waitUntil { Self.closed(first) })
        let carried = sessions.configurations[1]
        #expect(carried.resumptionHandle == nil)
        #expect(carried.instructions.hasPrefix("Be brief."))
        #expect(carried.instructions.contains("User: remind me about the dentist"))
        #expect(carried.instructions.contains("You: Okay, Thursday at three."))
        // Nothing was said after the new session opened, so it gets no catch-up note.
        try await Task.sleep(for: .milliseconds(50))
        #expect(Self.notes(sessions.all[1]).isEmpty)
        await controller.stop()
    }

    @Test func aTurnThatRunsPastTheDeadlineStillMovesBeforeTheOldSessionCloses() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions, margin: .milliseconds(200))
        _ = await controller.start()
        let first = try #require(sessions.all.first)
        let log = DisplayLog(controller)
        first.emit(.userSpeechStarted)  // and never stops
        #expect(await Self.waitUntil { await controller.currentConversation?.currentState == .userSpeaking })
        #expect(await Self.waitUntil { log.display.voice == .userSpeaking })
        let announced = ContinuousClock.now
        first.emit(.goingAway(timeLeft: .milliseconds(600)))
        #expect(await Self.waitUntil { Self.closed(first) })
        let waited = ContinuousClock.now - announced
        #expect(waited >= .milliseconds(350) && waited < .milliseconds(600))
        #expect(await controller.replacements == [.goingAway])
        // The notch follows the new session, which is listening, not the turn cut off on the old one.
        #expect(await Self.waitUntil { log.display.voice == .listening })
        #expect(log.display.status == nil)
        #expect(!log.display.canInterrupt)
        await controller.stop()
    }

    @Test func ifTheOldSessionDropsFirstTheReplacementTakesOverWithoutAReconnect() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions)
        _ = await controller.start()
        let first = try #require(sessions.all.first)
        let log = DisplayLog(controller)
        first.emit(.userSpeechStarted)
        first.emit(.goingAway(timeLeft: .seconds(3)))
        #expect(await Self.waitUntil { sessions.all.count == 2 })
        first.finish(throwing: ProviderError(provider: "gemini", message: "closed early"))
        #expect(await Self.waitUntil { await controller.replacements == [.goingAway] })
        #expect(await controller.currentConversation?.session === sessions.all[1])
        #expect(await controller.state == .on)
        #expect(sessions.all.count == 2)
        // The notch doesn't keep saying it is reconnecting once the new session is in.
        #expect(await Self.waitUntil { log.display.voice == .listening })
        #expect(log.display.notch(stopHint: nil)?.title == "Always-on · listening")
        await controller.stop()
    }

    // MARK: Voice change

    @Test func aVoiceChangeRestartsTheSessionAtTheNextPause() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions)
        _ = await controller.start()
        let first = try #require(sessions.all.first)
        first.emit(.userSpeechStarted)  // a turn in progress
        #expect(await Self.waitUntil { await controller.currentConversation?.currentState == .userSpeaking })

        sessions.voice = "Puck"
        await controller.voiceChanged()
        #expect(await controller.isStale)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sessions.all.count == 1)  // nothing is cut off mid-turn

        Self.reply(on: first, turn: 1, words: "hello", answer: "Hi there.")
        #expect(await Self.waitUntil { Self.closed(first) })
        #expect(sessions.configurations.last?.voice == "Puck")
        #expect(sessions.configurations.last?.instructions.contains("You: Hi there.") == true)
        #expect(await controller.replacements == [.voiceChanged])
        #expect(await !controller.isStale)
        #expect(await controller.state == .on)
        await controller.stop()
    }

    @Test func aVoiceChangeThatCantOpenANewSessionStaysStaleAndKeepsTheOldOne() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions)
        _ = await controller.start()
        let first = try #require(sessions.all.first)
        sessions.failNext = true
        await controller.voiceChanged()
        #expect(await controller.isStale)
        #expect(await controller.currentConversation?.session === first)
        #expect(!Self.closed(first))
        #expect(await controller.state == .on)
        await controller.stop()
    }

    @Test func aVoiceChangeWaitsForAPauseAgainWhenATurnStartsDuringTheConnect() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions)
        _ = await controller.start()
        let first = try #require(sessions.all.first)
        sessions.connectDelay = .milliseconds(300)
        sessions.voice = "Puck"
        await controller.voiceChanged()
        // Idle, so the new session starts opening; the user starts talking while it does.
        #expect(await Self.waitUntil { sessions.connectsStarted == 2 })
        first.emit(.userSpeechStarted)
        #expect(await Self.waitUntil { await controller.currentConversation?.currentState == .userSpeaking })
        #expect(await Self.waitUntil { sessions.all.count == 2 })
        let second = sessions.all[1]

        // Open, but the turn on the old session isn't cut off.
        try await Task.sleep(for: .milliseconds(150))
        #expect(!Self.closed(first))
        #expect(await controller.currentConversation?.session === first)
        Self.reply(on: first, turn: 1, words: "what time is it", answer: "Ten past four.")
        #expect(await Self.waitUntil { Self.closed(first) })
        #expect(await controller.currentConversation?.session === second)
        // That turn happened after the new session was set up, so it is told about it.
        #expect(await Self.waitUntil { !Self.notes(second).isEmpty })
        #expect(Self.notes(second).joined().contains("User: what time is it"))
        #expect(await controller.replacements == [.voiceChanged])
        await controller.stop()
    }

    @Test func aProviderChangeRestartsTheMicInTheNewSessionsFormat() async throws {
        let sessions = Sessions()
        sessions.inputFormats = ["Puck": .speech16k]  // another provider, which hears at 16 kHz
        let mic = TickingMic()
        let controller = Self.controller(sessions, mic: mic)
        _ = await controller.start()
        let first = try #require(sessions.all.first)
        #expect(mic.formats == [.speech24k])
        sessions.voice = "Puck"
        await controller.voiceChanged()
        #expect(await Self.waitUntil { Self.closed(first) })
        let second = sessions.all[1]
        #expect(second.inputFormat == .speech16k)
        #expect(await Self.waitUntil { mic.formats == [.speech24k, .speech16k] })
        let before = second.sentAudioBytes
        #expect(await Self.waitUntil { second.sentAudioBytes > before })
        #expect(await controller.state == .on)

        // A change that keeps the format keeps the mic running.
        sessions.voice = "Charon"
        sessions.inputFormats = ["Charon": .speech16k]
        await controller.voiceChanged()
        #expect(await Self.waitUntil { Self.closed(second) })
        #expect(mic.formats == [.speech24k, .speech16k])
        await controller.stop()
    }

    @Test func aVoiceChangeDuringAGoAwayReplacementIsAppliedAfterIt() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions)
        _ = await controller.start()
        let first = try #require(sessions.all.first)
        first.emit(.userSpeechStarted)
        #expect(await Self.waitUntil { await controller.currentConversation?.currentState == .userSpeaking })
        first.emit(.goingAway(timeLeft: .seconds(3)))
        #expect(await Self.waitUntil { sessions.all.count == 2 })
        // The replacement already opened with the old voice when the user picks a new one.
        sessions.voice = "Puck"
        await controller.voiceChanged()
        #expect(await controller.isStale)
        Self.reply(on: first, turn: 1, words: "hello", answer: "Hi there.")
        #expect(await Self.waitUntil { Self.closed(first) })
        #expect(sessions.configurations[1].voice == "Kore")
        // Once it has taken over, it is replaced in turn with the new voice.
        #expect(await Self.waitUntil { sessions.all.count == 3 })
        #expect(sessions.configurations.dropFirst(2).first?.voice == "Puck")
        #expect(await Self.waitUntil { await controller.replacements == [.goingAway, .voiceChanged] })
        #expect(await !controller.isStale)
        #expect(await controller.currentConversation?.session === sessions.all.dropFirst(2).first)
        await controller.stop()
    }

    @Test func conversationsAreReleasedOnceTheyEnd() async throws {
        let sessions = Sessions()
        let controller = Self.controller(sessions)
        _ = await controller.start()
        weak var first = await controller.currentConversation
        #expect(first != nil)
        sessions.voice = "Puck"
        await controller.voiceChanged()
        #expect(await Self.waitUntil { await controller.replacements == [.voiceChanged] })
        weak var second = await controller.currentConversation
        #expect(await Self.waitUntil { first == nil })
        await controller.stop()
        #expect(await Self.waitUntil { second == nil })
    }

    // MARK: Gemini Live resumption wire

    @Test func geminiAsksForResumptionHandlesAndResumesFromOne() async throws {
        let socket = RealtimeVoiceGeminiTests.acceptingSocket()
        let session = try await RealtimeVoiceGeminiTests.connect(socket, configuration: RealtimeSessionConfiguration(
            instructions: "Be brief.", resumable: true))
        #expect(RealtimeVoiceGeminiTests.sent(socket, "setup").first?["sessionResumption"] == [:])
        let events = RealtimeVoiceOpenAITests.Events(session)
        socket.pushJSON(["sessionResumptionUpdate": ["newHandle": "h-42", "resumable": true]])
        socket.pushJSON(["sessionResumptionUpdate": ["newHandle": "h-43", "resumable": false]])
        #expect(await Self.waitUntil { events.all.count >= 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.all == [.resumable(handle: "h-42")])
        await session.close()

        let resumed = RealtimeVoiceGeminiTests.acceptingSocket()
        let again = try await RealtimeVoiceGeminiTests.connect(resumed, configuration: RealtimeSessionConfiguration(
            instructions: "Be brief.", resumable: true, resumptionHandle: "h-42"))
        #expect(RealtimeVoiceGeminiTests.sent(resumed, "setup").first?["sessionResumption"] == ["handle": "h-42"])
        await again.close()

        // Sessions that don't ask for it send no resumption config at all.
        let plain = RealtimeVoiceGeminiTests.acceptingSocket()
        let third = try await RealtimeVoiceGeminiTests.connect(plain)
        #expect(RealtimeVoiceGeminiTests.sent(plain, "setup").first?["sessionResumption"] == nil)
        await third.close()
    }

    @Test func theConversationKeepsTheLatestHandle() async throws {
        let session = FakeRealtimeVoiceSession()
        let conversation = RealtimeConversation(session: session, output: RecordingRealtimeOutput())
        let run = Task { await conversation.run() }
        session.emit(.resumable(handle: "a"))
        session.emit(.resumable(handle: "b"))
        #expect(await Self.waitUntil { await conversation.resumptionHandle == "b" })
        await conversation.close()
        _ = await run.value
    }
}

// MARK: - Muted output

@MainActor
@Test func aReplyIntoAMutedMacIsCopiedAndTheUnmuteNoticeShows() async throws {
    let rig = AlwaysOnRig()
    let output = FakeOutputVolume(OutputVolumeState(deviceName: "Headphones", muted: true, volume: 0.6))
    let clipboard = InMemoryPasteboard()
    let guardian = MutedOutputGuard(output: output, pasteboard: clipboard)
    rig.loop.mutedGuard = guardian
    var notices: [AudioNotice] = []
    rig.loop.onUnheardReply = { notices.append($0) }
    rig.loop.start()
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    let session = try #require(rig.session)

    session.emit(.userSpeechStarted)
    session.emit(.userSpeechStopped)
    session.emit(.userTurnCommitted(itemID: "u1"))
    session.emit(.responseStarted(responseID: "r1"))
    session.emit(.audio(Data(count: 9_600), itemID: "a1"))
    session.emit(.assistantTranscriptDelta("The meeting moved to four.", itemID: "a1"))
    session.emit(.responseFinished(RealtimeResponseSummary(responseID: "r1", status: .completed, itemIDs: ["a1"],
                                                           transcript: "The meeting moved to four.")))
    #expect(await rig.waitUntil { !notices.isEmpty })
    let notice = try #require(notices.first)
    #expect(notice.kind == .outputMuted)
    #expect(notice.actions == [.unmute])
    #expect(guardian.lastCopied == "The meeting moved to four.")
    #expect(output.log.isEmpty)  // nothing touched the volume

    // Unmuted again: the next reply is heard and nothing is copied.
    output.current?.muted = false
    session.emit(.userSpeechStarted)
    session.emit(.userSpeechStopped)
    session.emit(.userTurnCommitted(itemID: "u2"))
    session.emit(.responseStarted(responseID: "r2"))
    session.emit(.audio(Data(count: 9_600), itemID: "a2"))
    session.emit(.responseFinished(RealtimeResponseSummary(responseID: "r2", status: .completed, itemIDs: ["a2"], transcript: "Done.")))
    try await Task.sleep(for: .milliseconds(300))
    #expect(notices.count == 1)
    rig.loop.stop()
    #expect(await rig.waitUntil { !rig.loop.isActive })
}

@MainActor
@Test func aVoiceChangeReachesTheRunningAlwaysOnSession() async throws {
    let rig = AlwaysOnRig()
    rig.loop.start()
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    let first = try #require(rig.session)
    rig.loop.voiceChanged()
    #expect(await rig.waitUntil { rig.shared.sessions.count == 2 })
    #expect(first.sent.contains(.close))
    #expect(rig.loop.display.state == .on)
    #expect(rig.logs.contains("voice changed: always-on session marked stale"))
    rig.loop.stop()
    #expect(await rig.waitUntil { !rig.loop.isActive })
}
