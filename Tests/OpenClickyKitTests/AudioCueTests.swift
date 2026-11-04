import Foundation
import Testing
@testable import OpenClickyKit

private func crossingRate(_ samples: ArraySlice<Float>, sampleRate: Double) -> Double {
    var crossings = 0
    var previous = samples.first ?? 0
    for sample in samples.dropFirst() {
        if previous < 0 && sample >= 0 { crossings += 1 }
        previous = sample
    }
    return Double(crossings) / (Double(samples.count) / sampleRate)
}

@Test(arguments: UICue.allCases)
func cuesAreShortCleanAndNormalized(cue: UICue) {
    let rate = 24_000.0
    let samples = cue.samples(sampleRate: rate)
    #expect(cue.duration > 0.1 && cue.duration < 0.8)
    #expect(abs(samples.count - Int((cue.duration * rate).rounded(.up)) - 1) <= 1)
    let allFinite = samples.allSatisfy { $0.isFinite }
    #expect(allFinite)
    let peak = samples.map(abs).max() ?? 0
    #expect(abs(peak - cue.recipe.peak) < 1e-4)
    // Starts and ends at silence, and no sample-to-sample jumps (clicks).
    #expect(abs(samples.first!) < 0.005)
    #expect(abs(samples.last!) < 0.005)
    let biggestStep = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    #expect(biggestStep < 0.35)
    // Deterministic, and rendered at any rate.
    #expect(cue.samples(sampleRate: rate) == samples)
    #expect(abs(cue.samples(sampleRate: 16_000).count - Int((cue.duration * 16_000).rounded(.up)) - 1) <= 1)
    // PCM16 with volume.
    let full = cue.pcm16(sampleRate: 24_000)
    #expect(full.count == samples.count * 2)
    let half = AudioLevel.measure(pcm16: cue.pcm16(sampleRate: 24_000, volume: 0.5))
    #expect(abs(half.peak - cue.recipe.peak / 2) < 0.001)
}

@Test func cuesSoundDifferent() {
    let rate = 24_000.0
    let start = UICue.startListening.samples(sampleRate: rate)
    let stop = UICue.stopListening.samples(sampleRate: rate)
    let error = UICue.error.samples(sampleRate: rate)
    let done = UICue.agentDone.samples(sampleRate: rate)
    #expect(Set([start.count, stop.count, error.count, done.count]).count == 4)

    // Start rises, stop falls.
    let startHead = crossingRate(start[0..<1200], sampleRate: rate)
    let startTail = crossingRate(start[2400..<4000], sampleRate: rate)
    #expect(startHead < startTail)
    let stopHead = crossingRate(stop[0..<1200], sampleRate: rate)
    let stopTail = crossingRate(stop[2400..<4000], sampleRate: rate)
    #expect(stopHead > stopTail)
    // Error is low, done is high.
    #expect(crossingRate(error[...], sampleRate: rate) < 400)
    #expect(crossingRate(done[0..<6000], sampleRate: rate) > 900)
}

@Test func cuePlayerAddsALeadInOnlyWhenTheOutputIsCold() {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 3600)
    let cues = CuePlayer(player: player, volume: 1, coldLeadIn: 0.05, coldLeadInBluetooth: 0.05)
    let first = cues.play(.startListening)
    let cueFrames = UICue.startListening.samples(sampleRate: 24_000).count
    #expect(first.index == 0)
    #expect(backend.scheduledFrames == 1200 + cueFrames)
    let second = cues.play(.stopListening)
    #expect(second.index == 1)
    #expect(backend.scheduled.last?.frames == UICue.stopListening.samples(sampleRate: 24_000).count)
}

@Test func cuePlayerVolumeScalesTheAudio() {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 3600)
    let cues = CuePlayer(player: player, volume: 0.25, coldLeadIn: 0, coldLeadInBluetooth: 0)
    cues.play(.agentDone)
    cues.volume = 2 // clamped to 1
    #expect(cues.volume == 1)
}

// MARK: - Keeping the cue output warm

/// Awake seconds since boot, as `CuePlayer.awakeClock` reads them.
private final class CueClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 1_000
    func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    var uptime: TimeInterval { lock.withLock { now } }
}

@Test func cueOutputStaysWarmForTheFreshnessWindow() {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 5)
    let clock = CueClock()
    let cues = CuePlayer(player: player, volume: 1, coldLeadIn: 0, coldLeadInBluetooth: 0, freshnessWindow: 30, clock: { clock.uptime })
    #expect(player.idleTimeout == 30, "the player keeps its device open for the whole window")
    #expect(!cues.isFresh && backend.startCount == 0)
    cues.play(.startListening)
    #expect(cues.isFresh)
    clock.advance(29)
    #expect(cues.isFresh)
    clock.advance(2)
    #expect(!cues.isFresh)
    // A key-down warm-up starts a new window.
    cues.warmUp()
    #expect(cues.isFresh)
}

@Test func cueOutputIsWarmedAgainAfterWakeOnlyWhileFresh() {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 5)
    let clock = CueClock()
    let cues = CuePlayer(player: player, volume: 1, coldLeadIn: 0, coldLeadInBluetooth: 0, freshnessWindow: 30, clock: { clock.uptime })
    // Never used: waking opens nothing.
    #expect(!cues.rewarmAfterWake())
    #expect(backend.startCount == 0)
    cues.play(.stopListening)
    let starts = backend.startCount
    #expect(starts == 1)
    // Asleep, however long: the system stopped the output, and only the awake seconds around the sleep count.
    backend.release()
    clock.advance(10)
    #expect(cues.rewarmAfterWake())
    #expect(backend.startCount == starts + 1 && player.isOutputRunning)
    // Long after the last cue, a wake leaves the device closed.
    backend.release()
    clock.advance(60)
    #expect(!cues.rewarmAfterWake())
    #expect(backend.startCount == starts + 1)
}

@Test func cueFreshnessCountsAwakeTimeSoALongSleepDoesNotUseUpTheWindow() {
    // The wake re-warm only means something if the hours asleep don't count: the default clock is the Mac's awake
    // time (it stands still during sleep), not the wall clock.
    let uptime = ProcessInfo.processInfo.systemUptime
    #expect(abs(CuePlayer.awakeClock() - uptime) < 5)
    let cues = CuePlayer(player: SpeechPlayer(backend: FakeSpeechPlaybackBackend(), pollInterval: nil, idleTimeout: 5),
                         volume: 1, coldLeadIn: 0, coldLeadInBluetooth: 0, freshnessWindow: 30)
    cues.warmUp()
    #expect(cues.isFresh)
}

@Test func cueOutputIsWarmedOnANewOutputDeviceWhileFresh() {
    let backend = FakeSpeechPlaybackBackend()
    let player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 5)
    let clock = CueClock()
    let cues = CuePlayer(player: player, volume: 1, coldLeadIn: 0, coldLeadInBluetooth: 0, freshnessWindow: 30, clock: { clock.uptime })
    #expect(!cues.rewarmAfterOutputChange(), "no device is opened before cues are used")
    #expect(backend.startCount == 0)
    cues.warmUp()
    backend.release() // the host moved to the new device and the old output stopped
    clock.advance(5)
    #expect(cues.rewarmAfterOutputChange())
    #expect(backend.startCount == 2 && player.isOutputRunning)
}
