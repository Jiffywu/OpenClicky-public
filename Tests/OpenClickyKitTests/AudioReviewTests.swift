import AVFoundation
import Foundation
import Testing
@testable import OpenClickyKit

// Regression tests for problems found reviewing the audio layer. Each one fails without its fix.

private final class Log<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    func append(_ item: Element) { lock.withLock { items.append(item) } }
    var all: [Element] { lock.withLock { items } }
    func take() -> [Element] {
        lock.withLock {
            defer { items.removeAll() }
            return items
        }
    }
}

private func pcm(_ frames: Int, value: Int16 = 1000) -> Data {
    PCMConverter.pcm16(fromSamples: [Int16](repeating: value, count: frames))
}

private func dc(_ frames: Int, _ value: Float) -> Data {
    PCMConverter.pcm16(fromFloats: [Float](repeating: value, count: frames))
}

// MARK: Scheduling race

@Test func aRenderCycleRacingTheSchedulerDoesNotSkewTheTimeline() {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 3600)
    let log = Log<SpeechPlayer.Event>()
    player.onEvent = { log.append($0) }
    let line = player.beginLine(0)
    player.append(pcm(2400), format: .speech24k, to: line)
    player.poll()
    #expect(log.take() == [.lineStarted(index: 0, expectedDuration: nil)])

    // The queue is exactly dry, so the player appends behind the previous buffer; but the output renders one more
    // cycle before the buffer reaches its queue, so the audio really starts at 2656, not 2400.
    backend.advance(to: 2400)
    player.poll()
    backend.renderBeforeNextSchedule(frames: 256)
    player.append(pcm(1200), format: .speech24k, to: line)
    player.finishLine(line)

    backend.advance(to: 2656 + 1200 - 1)
    player.poll()
    #expect(log.take().isEmpty, "the line was reported finished while its last 256 frames were still playing")
    backend.advance(to: 2656 + 1200)
    player.poll()
    #expect(log.take() == [.lineFinished(index: 0), .drained])
}

@Test func aRestartRacingTheSchedulerKeepsLineBoundariesOnTheAudio() {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 3600)
    let log = Log<SpeechPlayer.Event>()
    player.onEvent = { log.append($0) }
    player.play(pcm(2400, value: 100), format: .speech24k, line: 0)
    player.play(pcm(2400, value: 300), format: .speech24k, line: 1)
    backend.advance(to: 1200)
    player.poll()
    _ = log.take()

    // The route changes; the new output renders a cycle before the unheard audio is queued again.
    backend.renderBeforeNextSchedule(frames: 512)
    backend.simulateRestart()
    _ = log.take()
    // Line 0's remaining 1200 frames start at 512 on the new clock, so line 1 starts at 1712.
    backend.advance(to: 1711)
    player.poll()
    #expect(log.take().isEmpty)
    backend.advance(to: 1712)
    player.poll()
    #expect(log.take() == [.lineFinished(index: 0), .lineStarted(index: 1, expectedDuration: 0.1)])
}

// MARK: Impossible formats

@Test func audioWithAnImpossibleSampleRateIsRejectedInsteadOfCrashing() throws {
    // Converting from 0 Hz used to divide by zero while sizing the output buffer and trap.
    let bad = PCMFormat(sampleRate: 0)
    #expect(throws: AudioIOError.self) {
        try PCMResampler(from: PCMConverter.avFormat(bad), to: PCMConverter.avFormat(.speech16k))
    }
    #expect(throws: AudioIOError.self) { try PCMConverter.convert(pcm(160), from: bad, to: .speech16k) }
    #expect(throws: AudioIOError.self) { try PCMConverter.convert(pcm(160), from: .speech16k, to: PCMFormat(sampleRate: -8_000)) }

    // A voice that reports a bogus format loses that chunk, not the app.
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 3600)
    let line = player.beginLine(0)
    player.append(pcm(2400), format: bad, to: line)
    player.append(pcm(2400), format: PCMFormat(sampleRate: -24_000), to: line)
    #expect(backend.scheduled.isEmpty)
    player.append(pcm(2400), format: .speech24k, to: line)
    player.finishLine(line)
    #expect(backend.scheduledFrames == 2400)

    // A capture asked for an impossible format fails to build its converter instead of trapping on the tap thread.
    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    #expect(throws: AudioIOError.self) {
        try MicTap(inputFormat: input, target: bad, chunkDuration: 0.04, channel: nil, sink: MicSink(format: bad)) { _ in }
    }
}

// MARK: A failed rebuild must not orphan the other clients

/// A stand-in for MicrophoneCapture / the speech output on a shared host.
private final class ProbeClient: AudioEngineClient, @unchecked Sendable {
    var needsEngine: Bool
    var needsInput: Bool
    let starts = Log<String?>()
    let failures = Log<String>()

    init(needsEngine: Bool, needsInput: Bool = false) {
        self.needsEngine = needsEngine
        self.needsInput = needsInput
    }

    func attach(to engine: AVAudioEngine) throws { _ = engine.mainMixerNode }
    func detach(from engine: AVAudioEngine) {}
    func engineDidStart(rebuildReason: String?) { starts.append(rebuildReason) }
    func engineDidFail(_ message: String) { failures.append(message) }
}

@Test func aMicThatFailsToOpenDoesNotTakeTheSharedOutputDownWithIt() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let speaker = ProbeClient(needsEngine: true)
    let mic = ProbeClient(needsEngine: false, needsInput: true)
    host.work.sync {
        host.register(speaker)
        host.register(mic)
    }
    try host.work.sync { _ = try host.acquire(input: false) }
    #expect(speaker.starts.take() == [nil])

    // A press: the mic needs an input-capable engine, the running one is torn down, and the new one fails to start.
    host.work.sync {
        mic.needsEngine = true
        host.injectedBuildFailures = 1
        #expect(throws: AudioIOError.self) { try host.acquire(input: true) }
        // MicrophoneCapture.start backs out the way it does on any error.
        mic.needsEngine = false
        host.releaseIfUnused()
    }
    host.work.sync {} // let queued recovery run

    // The speaker was still playing through that engine: it must get one back (and be told it was rebuilt).
    #expect(host.work.sync { host.engine != nil })
    let starts = speaker.starts.take()
    #expect(starts.count == 1 && starts.first! != nil, "speaker saw \(starts)")
    #expect(mic.failures.all.isEmpty)
}

@Test func whenTheEngineCannotComeBackOnlyActiveClientsAreFailed() async throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    host.work.sync { host.retryDelay = 0.01 }
    let speaker = ProbeClient(needsEngine: true)
    let idleMic = ProbeClient(needsEngine: false, needsInput: true)
    let mic = ProbeClient(needsEngine: false, needsInput: true)
    host.work.sync {
        host.register(speaker)
        host.register(idleMic)
        host.register(mic)
    }
    try host.work.sync { _ = try host.acquire(input: false) }
    host.work.sync {
        mic.needsEngine = true
        host.injectedBuildFailures = 10
        _ = try? host.acquire(input: true)
        mic.needsEngine = false
        host.releaseIfUnused()
    }
    _ = await waitUntil { !speaker.failures.all.isEmpty }
    #expect(speaker.failures.all.count == 1)
    // A closed microphone has no session to give up and must not report a failure.
    #expect(idleMic.failures.all.isEmpty)
    #expect(mic.failures.all.isEmpty)
}

@Test func aSpeechLineSurvivesAFailedMicrophoneOpenOnASharedHost() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    let events = Log<SpeechPlayer.Event>()
    player.onEvent = { events.append($0) }
    let mic = ProbeClient(needsEngine: false, needsInput: true)
    host.work.sync { host.register(mic) }

    player.play(dc(12_000, 0.25), format: .speech24k, line: 0) // 0.5 s
    var output = PCMConverter.monoFloats(from: try host.renderOffline(frames: 2_400))
    player.poll()

    host.work.sync {
        mic.needsEngine = true
        host.injectedBuildFailures = 1
        _ = try? host.acquire(input: true)
        mic.needsEngine = false
        host.releaseIfUnused()
    }
    for _ in 0..<40 {
        output += PCMConverter.monoFloats(from: try host.renderOffline(frames: 512))
        player.poll()
        if player.isIdle { break }
    }

    let voiced = output.filter { abs($0 - 0.25) < 0.01 }.count
    // All 0.5 s of the line is heard (resumed where the listener was), not just the 0.1 s before the failure.
    #expect(abs(voiced - 12_000) <= 2, "heard \(voiced) of 12000 frames")
    let all = events.all
    #expect(all.contains { if case .outputRestarted = $0 { true } else { false } })
    #expect(Array(all.suffix(2)) == [.lineFinished(index: 0), .drained])
}

// MARK: A dropped player leaves nothing behind on a shared host

@Test func droppingAPlayerOnASharedHostSilencesAndDetachesIt() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let other = SpeechPlayer(sampleRate: 24_000, host: host)
    var player: SpeechPlayer? = SpeechPlayer(sampleRate: 24_000, host: host)
    player?.play(dc(24_000, 0.25), format: .speech24k, line: 0) // 1 s
    let before = PCMConverter.monoFloats(from: try host.renderOffline(frames: 2_400))
    #expect(before.contains { abs($0 - 0.25) < 0.01 })
    let nodesWhilePlaying = host.work.sync { host.engine?.attachedNodes.count ?? 0 }

    // The app replaces the player without calling stop(): the rest of its line must not keep playing from a node
    // nobody owns, and the engine must not be held for it.
    player = nil
    host.work.sync {} // let the release run
    #expect(host.work.sync { host.engine } == nil, "the engine was kept running for a player that no longer exists")

    other.play(dc(2_400, -0.5), format: .speech24k, line: 0)
    let after = PCMConverter.monoFloats(from: try host.renderOffline(frames: 9_600))
    #expect(!after.contains { abs($0 - 0.25) < 0.01 }, "the dropped player's audio kept playing")
    #expect(after.filter { abs($0 + 0.5) < 0.01 }.count == 2_400)
    #expect(host.work.sync { host.engine?.attachedNodes.count ?? 0 } < nodesWhilePlaying)
}

// MARK: Microphone choice on a running shared engine

@Test func aMicrophoneChosenWhileTheSharedEngineRunsIsUsedByTheNextPress() {
    typealias Host = AudioEngineHost
    // The echo-cancelling engine is running for the voice with the old mic's input; the user picked another mic.
    #expect(Host.reuse(hasEngine: true, isRunning: true, hasInput: true, inputPin: "usb-mic", preferredPin: "headset",
                       wantsInput: true) == .build(reason: "microphone selection changed"))
    #expect(Host.reuse(hasEngine: true, isRunning: true, hasInput: true, inputPin: "usb-mic", preferredPin: nil,
                       wantsInput: true) == .build(reason: "microphone selection changed"))
    // The voice itself doesn't care which mic is pinned.
    #expect(Host.reuse(hasEngine: true, isRunning: true, hasInput: true, inputPin: "usb-mic", preferredPin: "headset",
                       wantsInput: false) == .reuse)
    // Unchanged choice: a press reuses the running engine (no glitch in the voice).
    #expect(Host.reuse(hasEngine: true, isRunning: true, hasInput: true, inputPin: nil, preferredPin: nil,
                       wantsInput: true) == .reuse)
    #expect(Host.reuse(hasEngine: true, isRunning: true, hasInput: false, inputPin: nil, preferredPin: nil,
                       wantsInput: true) == .build(reason: "input needed"))
    #expect(Host.reuse(hasEngine: true, isRunning: false, hasInput: true, inputPin: nil, preferredPin: nil,
                       wantsInput: false) == .build(reason: "engine stopped"))
    #expect(Host.reuse(hasEngine: false, isRunning: false, hasInput: false, inputPin: nil, preferredPin: nil,
                       wantsInput: true) == .build(reason: nil))
}

// MARK: Cancellation

@Test func cancellingAWaitForDrainReturnsWithoutStoppingTheVoice() async throws {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 3600)
    player.play(pcm(2400), format: .speech24k, line: 0)
    let finished = Log<Bool>()
    let waiter = Task {
        await player.waitUntilDrained()
        finished.append(Task.isCancelled)
    }
    try await Task.sleep(for: .milliseconds(20))
    waiter.cancel()
    _ = await waitUntil { !finished.all.isEmpty }
    #expect(finished.all == [true], "a cancelled waitUntilDrained() kept waiting")
    #expect(!player.isIdle) // only the wait ended; the line still plays

    // Already cancelled before waiting: returns at once. (Polled, not awaited, so a regression fails instead of hanging.)
    _ = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await player.waitUntilDrained()
        finished.append(true)
    }
    _ = await waitUntil { finished.all.count >= 2 }
    #expect(finished.all.count == 2, "an already-cancelled waitUntilDrained() waited")

    // Uncancelled waiters still wait for the drain.
    let patient = Task { await player.waitUntilDrained() }
    backend.advance(to: 2400)
    player.poll()
    await patient.value
    #expect(player.isIdle)
}
