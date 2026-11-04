import AVFoundation
import Foundation
import Testing
@testable import OpenClickyKit

/// Collects events synchronously (they are delivered on the player's queue before `poll()` etc. return).
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpeechPlayer.Event] = []

    func append(_ event: SpeechPlayer.Event) { lock.withLock { events.append(event) } }

    /// Events since the last call.
    func take() -> [SpeechPlayer.Event] {
        lock.withLock {
            defer { events.removeAll() }
            return events
        }
    }
}

private func makePlayer(sampleRate: Double = 24_000) -> (SpeechPlayer, FakeSpeechPlaybackBackend, EventLog) {
    let backend = FakeSpeechPlaybackBackend(sampleRate: sampleRate)
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 3600)
    let log = EventLog()
    player.onEvent = { log.append($0) }
    return (player, backend, log)
}

/// `frames` of a constant value as PCM16 (the value tags which audio got scheduled).
private func pcm(_ frames: Int, value: Int16 = 1000) -> Data {
    PCMConverter.pcm16(fromSamples: [Int16](repeating: value, count: frames))
}

private let fmt24 = PCMFormat.speech24k

@Test func gaplessLinesReportStartAndFinishAtTheirFrames() {
    let (player, backend, log) = makePlayer()
    let line0 = player.beginLine(0)
    player.append(pcm(2400), format: fmt24, to: line0)
    player.append(pcm(2400), format: fmt24, to: line0)
    player.finishLine(line0)
    let line1 = player.beginLine(1)
    player.append(pcm(4800), format: fmt24, to: line1)
    player.finishLine(line1)

    // Everything queued back to back, no explicit start times needed.
    #expect(backend.scheduled.map(\.frames) == [2400, 2400, 4800])
    #expect(backend.scheduled.allSatisfy { $0.at == nil })
    #expect(backend.startCount == 1)

    // Clock at 0: line 0 is audible right away; its whole length was known.
    player.poll()
    #expect(log.take() == [.lineStarted(index: 0, expectedDuration: 0.2)])
    backend.advance(to: 4799)
    player.poll()
    #expect(log.take().isEmpty)
    backend.advance(to: 4800)
    player.poll()
    #expect(log.take() == [.lineFinished(index: 0), .lineStarted(index: 1, expectedDuration: 0.2)])
    #expect(player.position() == SpeechPlayer.Position(lineIndex: 1, elapsed: 0, duration: 0.2))
    backend.advance(to: 7200)
    #expect(player.position() == SpeechPlayer.Position(lineIndex: 1, elapsed: 0.1, duration: 0.2))
    backend.advance(to: 9600)
    player.poll()
    #expect(log.take() == [.lineFinished(index: 1), .drained])
    #expect(player.isIdle)
    // Drained is reported once.
    backend.advance(to: 20_000)
    player.poll()
    #expect(log.take().isEmpty)
}

@Test func starvedStreamPlacesLateAudioAtTheCurrentFrame() {
    let (player, backend, log) = makePlayer()
    let line = player.beginLine(0)
    player.append(pcm(2400), format: fmt24, to: line)
    player.poll()
    // The line started before the voice finished delivering it, so its length was unknown.
    #expect(log.take() == [.lineStarted(index: 0, expectedDuration: nil)])

    // The voice falls behind: the output runs dry at 2400 and keeps going.
    backend.advance(to: 5000)
    player.poll()
    #expect(log.take().isEmpty)
    player.append(pcm(1200), format: fmt24, to: line)
    // Late audio gets an exact start time at the output's earliest frame, not the stale end of queue.
    #expect(backend.scheduled.last == .init(frames: 1200, at: 5000, firstSample: PCMConverter.float(fromInt16: 1000)))
    player.append(pcm(1200), format: fmt24, to: line)
    #expect(backend.scheduled.last?.at == nil) // and the next chunk follows it gaplessly
    player.finishLine(line)

    backend.advance(to: 7399)
    player.poll()
    #expect(log.take().isEmpty)
    backend.advance(to: 7400)
    player.poll()
    #expect(log.take() == [.lineFinished(index: 0), .drained])
}

@Test func leadAndLatencyShiftTheTimeline() {
    let (player, backend, log) = makePlayer()
    backend.leadFrames = 240
    backend.latencyFrames = 480
    let line = player.beginLine(0)
    player.append(pcm(2400), format: fmt24, to: line)
    player.finishLine(line)
    // Queue empty at clock 0 and the output can't start before frame 240: explicit start there.
    #expect(backend.scheduled.first?.at == 240)
    backend.advance(to: 600)   // heard = 600 - 480 = 120 < 240
    player.poll()
    #expect(log.take().isEmpty)
    backend.advance(to: 720)   // heard = 240
    player.poll()
    #expect(log.take() == [.lineStarted(index: 0, expectedDuration: 0.1)])
    backend.advance(to: 240 + 2400 + 480)
    player.poll()
    #expect(log.take() == [.lineFinished(index: 0), .drained])
}

@Test(arguments: [(Float(2), 0.1), (Float(0.5), 0.4), (Float(1.25), 0.16)])
func speedScalesExpectedDuration(rate: Float, expected: TimeInterval) {
    let (player, backend, log) = makePlayer()
    player.rate = rate
    #expect(backend.rate == rate)
    let line = player.play(pcm(4800), format: fmt24, line: 3)
    #expect(line.index == 3)
    player.poll()
    guard case .lineStarted(3, let duration?) = log.take().first else {
        Issue.record("no lineStarted")
        return
    }
    #expect(abs(duration - expected) < 1e-9)
}

@Test func rateIsClamped() {
    let (player, _, _) = makePlayer()
    player.rate = 10
    #expect(player.rate == 2)
    player.rate = 0.1
    #expect(player.rate == 0.5)
}

@Test func laterLinesWaitForEarlierOnes() {
    let (player, backend, log) = makePlayer()
    let line0 = player.beginLine(0)
    let line1 = player.beginLine(1)
    player.append(pcm(1200, value: 1000), format: fmt24, to: line0)
    // The voice synthesizes line 1 ahead; it must not be scheduled in the middle of line 0.
    player.append(pcm(2400, value: 2000), format: fmt24, to: line1)
    player.finishLine(line1)
    #expect(backend.scheduled.count == 1)
    player.append(pcm(1200, value: 1000), format: fmt24, to: line0)
    player.finishLine(line0)
    #expect(backend.scheduled.map(\.frames) == [1200, 1200, 2400])
    #expect(backend.scheduled.map { PCMConverter.int16(fromFloat: $0.firstSample) } == [1000, 1000, 2000])

    player.poll()
    backend.advance(to: 2400)
    player.poll()
    backend.advance(to: 4800)
    player.poll()
    // Line 0 became audible before all of its audio had arrived, so its length was still unknown then.
    #expect(log.take() == [
        .lineStarted(index: 0, expectedDuration: nil), .lineFinished(index: 0),
        .lineStarted(index: 1, expectedDuration: 0.1), .lineFinished(index: 1), .drained,
    ])
}

@Test func emptyLinesStillTakeTheirTurn() {
    let (player, backend, log) = makePlayer()
    let line0 = player.beginLine(0)
    player.append(pcm(2400), format: fmt24, to: line0)
    player.finishLine(line0)
    let empty = player.beginLine(1)
    player.finishLine(empty)
    let line2 = player.beginLine(2)
    player.append(pcm(2400), format: fmt24, to: line2)
    player.finishLine(line2)
    #expect(backend.scheduledFrames == 4800)

    player.poll()
    #expect(log.take() == [.lineStarted(index: 0, expectedDuration: 0.1)])
    backend.advance(to: 2400)
    player.poll()
    #expect(log.take() == [
        .lineFinished(index: 0),
        .lineStarted(index: 1, expectedDuration: 0), .lineFinished(index: 1),
        .lineStarted(index: 2, expectedDuration: 0.1),
    ])
}

@Test func stopCutsTheCurrentLineAndIgnoresStaleAudio() {
    let (player, backend, log) = makePlayer()
    let line0 = player.play(pcm(2400), format: fmt24, line: 0)
    let line1 = player.beginLine(1)
    player.append(pcm(4800), format: fmt24, to: line1)
    let line2 = player.beginLine(2)
    player.append(pcm(1000), format: fmt24, to: line2)
    backend.advance(to: 2400 + 1200)
    player.poll()
    _ = log.take()

    let report = player.stop()
    #expect(report == SpeechPlayer.StopReport(cutLine: 1, playedAudio: 0.05, droppedLines: [2]))
    #expect(log.take() == [.lineCut(index: 1, playedAudio: 0.05), .stopped])
    #expect(backend.flushCount == 1)
    #expect(backend.scheduled.isEmpty)
    #expect(player.isIdle)

    // Chunks still arriving from cancelled synthesis are dropped.
    player.append(pcm(2400), format: fmt24, to: line1)
    player.finishLine(line1)
    player.finishLine(line0)
    #expect(backend.scheduled.isEmpty)

    // The next turn starts cleanly at the output's reset clock.
    let next = player.play(pcm(2400), format: fmt24, line: 0)
    #expect(next.index == 0)
    #expect(backend.scheduled == [.init(frames: 2400, at: nil, firstSample: PCMConverter.float(fromInt16: 1000))])
    player.poll()
    #expect(log.take() == [.lineStarted(index: 0, expectedDuration: 0.1)])
}

@Test func outputRestartResumesFromTheHeardFrame() {
    let (player, backend, log) = makePlayer()
    let line0 = player.beginLine(0)
    player.append(pcm(2400, value: 100), format: fmt24, to: line0)
    player.append(pcm(2400, value: 200), format: fmt24, to: line0)
    player.finishLine(line0)
    player.play(pcm(2400, value: 300), format: fmt24, line: 1)
    backend.advance(to: 3000)
    player.poll()
    _ = log.take()

    // The route changes 3000 frames in: the output lost its queue and counts from 0 again.
    backend.simulateRestart(reason: "headphones unplugged")
    #expect(log.take() == [.outputRestarted(reason: "headphones unplugged")])
    // The unheard 1800 frames of the second chunk and all of line 1 are re-queued at their timeline positions.
    #expect(backend.scheduled == [
        .init(frames: 1800, at: 0, firstSample: PCMConverter.float(fromInt16: 200)),
        .init(frames: 2400, at: 1800, firstSample: PCMConverter.float(fromInt16: 300)),
    ])
    backend.advance(to: 1799)
    player.poll()
    #expect(log.take().isEmpty)
    backend.advance(to: 1800)
    player.poll()
    #expect(log.take() == [.lineFinished(index: 0), .lineStarted(index: 1, expectedDuration: 0.1)])
    backend.advance(to: 4200)
    player.poll()
    #expect(log.take() == [.lineFinished(index: 1), .drained])
}

@Test func outputFailureDropsLinesAndWakesWaiters() async {
    let (player, backend, log) = makePlayer()
    player.play(pcm(2400), format: fmt24, line: 0)
    _ = log.take()
    let waiter = Task { await player.waitUntilDrained() }
    try? await Task.sleep(for: .milliseconds(20))
    backend.simulateFailure("device vanished")
    await waiter.value
    #expect(log.take() == [.outputFailed("device vanished")])
    #expect(player.isIdle)
}

@Test func otherRatesAndStereoAreConvertedToThePlayerFormat() {
    let (player, backend, _) = makePlayer()
    let line = player.beginLine(0)
    // 0.1 s at 16 kHz in uneven chunks → 0.1 s at 24 kHz.
    for size in [160, 800, 640] { player.append(pcm(size), format: .speech16k, to: line) }
    player.finishLine(line)
    #expect(abs(backend.scheduledFrames - 2400) <= 1)

    let stereo = player.beginLine(1)
    player.append(PCMConverter.pcm16(fromSamples: [Int16](repeating: 500, count: 960)), format: PCMFormat(sampleRate: 24_000, channels: 2), to: stereo)
    player.finishLine(stereo)
    #expect(backend.scheduled.last?.frames == 480)
}

@Test func speakConsumesAVoiceStream() async throws {
    let (player, backend, log) = makePlayer()
    let stream = AsyncThrowingStream<SpeechEvent, Error> { continuation in
        continuation.yield(.audio(pcm(1200), fmt24))
        continuation.yield(.audio(pcm(1200), fmt24))
        continuation.yield(.lineFinished)
        continuation.yield(.audio(pcm(9999), fmt24)) // after lineFinished: ignored
        continuation.finish()
    }
    try await player.speak(line: 4, from: stream)
    #expect(backend.scheduledFrames == 2400)
    player.poll()
    #expect(log.take() == [.lineStarted(index: 4, expectedDuration: 0.1)])
}

@Test func waitUntilDrainedReturnsOnDrain() async {
    let (player, backend, _) = makePlayer()
    await player.waitUntilDrained() // idle: returns at once
    player.play(pcm(2400), format: fmt24, line: 0)
    let waiter = Task { await player.waitUntilDrained() }
    try? await Task.sleep(for: .milliseconds(20))
    backend.advance(to: 2400)
    player.poll()
    await waiter.value
    #expect(player.isIdle)
}

@Test func eventStreamMirrorsTheHandler() async {
    let (player, backend, _) = makePlayer()
    let stream = player.events()
    player.play(pcm(2400), format: fmt24, line: 0)
    player.poll()
    backend.advance(to: 2400)
    player.poll()
    var received: [SpeechPlayer.Event] = []
    for await event in stream {
        received.append(event)
        if event == .drained { break }
    }
    #expect(received == [.lineStarted(index: 0, expectedDuration: 0.1), .lineFinished(index: 0), .drained])
}

@Test func idleOutputIsReleasedAndRestartedAtTheCursor() async throws {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 0.05)
    player.play(pcm(2400), format: fmt24, line: 0)
    backend.advance(to: 2400)
    player.poll()
    // The idle timer runs late on a busy machine; wait for the release itself.
    #expect(await waitUntil { backend.releaseCount >= 1 })
    #expect(backend.releaseCount == 1)
    #expect(!backend.isRunning)

    let log = EventLog()
    player.onEvent = { log.append($0) }
    player.play(pcm(2400), format: fmt24, line: 0)
    #expect(backend.startCount == 2)
    // The restarted output counts from 0 again and the line plays from there.
    #expect(backend.scheduled.last?.at == nil)
    player.poll()
    backend.advance(to: 2400)
    player.poll()
    #expect(log.take() == [.lineStarted(index: 0, expectedDuration: 0.1), .lineFinished(index: 0), .drained])
}

/// A pacing receiver like the drawing engine host (only touched on the main actor here).
private final class RecordingPacing: SpeechPacing {
    var calls: [String] = []
    func lineStarted(_ index: Int, expectedDuration: TimeInterval?) { calls.append("start \(index) \(expectedDuration ?? -1)") }
    func lineFinished(_ index: Int) { calls.append("finish \(index)") }
}

@MainActor
@Test func relaysTheTimelineToSpeechPacing() async throws {
    let (player, backend, _) = makePlayer()
    let pacing = RecordingPacing()
    let relay = player.relayTimeline(to: pacing)
    player.play(pcm(2400), format: fmt24, line: 0)
    player.poll()
    backend.advance(to: 2400)
    player.poll()
    _ = await waitUntil { pacing.calls.count >= 2 }
    relay.cancel()
    #expect(pacing.calls == ["start 0 0.1", "finish 0"])
}
