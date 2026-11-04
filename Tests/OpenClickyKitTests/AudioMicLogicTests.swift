import AVFoundation
import Foundation
import Testing
@testable import OpenClickyKit

// MARK: Health monitor (fake clock: plain TimeInterval values)

private let audible: Float = 0.01
private let digitalSilence: Float = 0

@Test func healthyAudioNeverTriggers() {
    var monitor = MicHealthMonitor()
    monitor.started(at: 0)
    var t = 0.0
    while t < 10 {
        monitor.observe(peak: audible, at: t)
        #expect(monitor.check(at: t) == nil)
        t += 0.04
    }
}

@Test func noChunksForTheWindowRebuildsThenFailsOverThenGivesUp() {
    var monitor = MicHealthMonitor()
    monitor.started(at: 100)
    #expect(monitor.check(at: 102.4) == nil)
    #expect(monitor.check(at: 102.5) == .rebuild(.noAudio))
    // Each verdict restarts the window.
    #expect(monitor.check(at: 104.9) == nil)
    #expect(monitor.check(at: 105.0) == .rebuild(.noAudio))
    #expect(monitor.check(at: 107.5) == .failover(.noAudio))
    #expect(monitor.check(at: 110.0) == .rebuild(.noAudio))
    #expect(monitor.check(at: 112.5) == .rebuild(.noAudio))
    #expect(monitor.check(at: 115.0) == .irrecoverable(.noAudio))
    // Reported once.
    #expect(monitor.check(at: 200) == nil)
}

@Test func digitalZerosAreTellApartFromNoChunks() {
    var monitor = MicHealthMonitor()
    monitor.started(at: 0)
    var t = 0.0
    while t < 2.5 {
        monitor.observe(peak: digitalSilence, at: t)
        t += 0.04
    }
    #expect(monitor.check(at: 2.5) == .rebuild(.allZeros))
}

@Test func quietButLiveRoomNoiseCountsAsAudible() {
    var monitor = MicHealthMonitor()
    monitor.started(at: 0)
    // About -70 dBFS of noise: far quieter than speech, far louder than 2 LSB.
    let roomNoise: Float = 0.0003
    var t = 0.0
    while t < 6 {
        monitor.observe(peak: roomNoise, at: t)
        #expect(monitor.check(at: t) == nil)
        t += 0.04
    }
}

@Test func audibleAudioResetsTheRebuildLadder() {
    var monitor = MicHealthMonitor()
    monitor.started(at: 0)
    #expect(monitor.check(at: 2.5) == .rebuild(.noAudio))
    monitor.started(at: 2.6)
    monitor.observe(peak: audible, at: 3)
    #expect(monitor.rebuilds == 0)
    #expect(monitor.check(at: 5.4) == nil)
    #expect(monitor.check(at: 5.5) == .rebuild(.noAudio))
}

@Test func failoverCanBeDisabled() {
    var policy = MicHealthMonitor.Policy()
    policy.maxRebuilds = 1
    policy.allowFailover = false
    var monitor = MicHealthMonitor(policy: policy)
    monitor.started(at: 0)
    #expect(monitor.check(at: 2.5) == .rebuild(.noAudio))
    #expect(monitor.check(at: 5) == .irrecoverable(.noAudio))
}

@Test func resetStartsAFreshPress() {
    var monitor = MicHealthMonitor()
    monitor.started(at: 0)
    _ = monitor.check(at: 2.5)
    _ = monitor.check(at: 5)
    _ = monitor.check(at: 7.5)
    #expect(monitor.failedOver)
    monitor.reset(at: 10)
    #expect(!monitor.failedOver)
    #expect(monitor.rebuilds == 0)
    #expect(monitor.check(at: 12.5) == .rebuild(.noAudio))
}

// MARK: Lifecycle and the Bluetooth hold

@Test func wiredMicClosesWhenThePressEnds() {
    var lifecycle = MicLifecycle(bluetoothHold: 8)
    #expect(lifecycle.start() == .open)
    #expect(lifecycle.isDelivering)
    #expect(lifecycle.start() == .none)
    #expect(lifecycle.stop(at: 1, inputIsBluetooth: false) == .close)
    #expect(lifecycle.state == .closed)
    #expect(lifecycle.stop(at: 2, inputIsBluetooth: false) == .none)
}

@Test func bluetoothMicIsHeldOpenMutedForTheGracePeriod() {
    var lifecycle = MicLifecycle(bluetoothHold: 8)
    #expect(lifecycle.start() == .open)
    #expect(lifecycle.stop(at: 10, inputIsBluetooth: true) == .mute)
    #expect(lifecycle.state == .holding(until: 18))
    #expect(lifecycle.isOpen)
    #expect(!lifecycle.isDelivering)
    #expect(lifecycle.tick(at: 17.9) == .none)
    // A new press inside the hold resumes without reopening the device (no profile flip).
    #expect(lifecycle.start() == .resume)
    #expect(lifecycle.isDelivering)
    #expect(lifecycle.stop(at: 20, inputIsBluetooth: true) == .mute)
    #expect(lifecycle.tick(at: 27.99) == .none)
    #expect(lifecycle.tick(at: 28) == .close)
    #expect(lifecycle.state == .closed)
    #expect(lifecycle.start() == .open)
}

@Test func holdCanBeSkippedOrDisabled() {
    var lifecycle = MicLifecycle(bluetoothHold: 8)
    _ = lifecycle.start()
    #expect(lifecycle.stop(at: 0, inputIsBluetooth: true, allowHold: false) == .close)
    var disabled = MicLifecycle(bluetoothHold: 0)
    _ = disabled.start()
    #expect(disabled.stop(at: 0, inputIsBluetooth: true) == .close)
    var held = MicLifecycle(bluetoothHold: 8)
    _ = held.start()
    _ = held.stop(at: 0, inputIsBluetooth: true)
    #expect(held.close() == .close)
    #expect(held.close() == .none)
}

@Test func transportClassification() {
    #expect(AudioDeviceTransport.bluetooth.isBluetooth)
    #expect(AudioDeviceTransport.bluetoothLE.isBluetooth)
    #expect(!AudioDeviceTransport.builtIn.isBluetooth)
    #expect(!AudioDeviceTransport.usb.isBluetooth)
}

// MARK: The tap pipeline (no hardware: buffers built in memory)

@Test func micTapTurnsHardwareBuffersIntoFixedChunksAtTheTargetRate() async throws {
    let sink = MicSink(format: .speech16k)
    let (stream, continuation) = AsyncStream<MicrophoneCapture.Chunk>.makeStream()
    sink.begin(continuation)
    let stats = LockedValue<[MicTap.ChunkStats]>([])
    // A 48 kHz stereo device; channel 0 carries a tone, channel 1 silence.
    let hardware = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let tap = try MicTap(inputFormat: hardware, target: .speech16k, chunkDuration: 0.04, channel: 0, sink: sink) { stat in
        stats.mutate { $0.append(stat) }
    }
    // One second in 4800-frame buffers (what an AVAudioEngine tap typically hands over).
    for block in 0..<10 {
        let buffer = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for i in 0..<4800 {
            buffer.floatChannelData![0][i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(block * 4800 + i) / 48_000))
            buffer.floatChannelData![1][i] = 0
        }
        tap.process(buffer)
    }
    let flushed = tap.flush()
    sink.finish()

    var chunks: [MicrophoneCapture.Chunk] = []
    for await chunk in stream { chunks.append(chunk) }

    let totalFrames = chunks.reduce(0) { $0 + $1.pcm.count / 2 }
    #expect(abs(totalFrames - 16_000) <= 1)
    // Every chunk but the last is exactly 40 ms; timestamps advance by the audio delivered.
    #expect(chunks.dropLast().allSatisfy { $0.pcm.count == 1280 })
    #expect(chunks.count == Int((Double(totalFrames) / 640).rounded(.up)))
    for (index, chunk) in chunks.enumerated() {
        #expect(abs(chunk.time - Double(index) * 0.04) < 1e-9)
        #expect(chunk.format == .speech16k)
    }
    // The tone came through (channel 0 picked, not averaged with the silent channel).
    let middle = chunks[10]
    #expect(abs(middle.level.rmsDB - (20 * log10(0.5) - 3.01)) < 0.3)
    #expect(stats.get().count + flushed.count == chunks.count)
    #expect(stats.get().allSatisfy { $0.delivered })
}

@Test func micSinkDropsChunksWhenNoPressIsListening() {
    let sink = MicSink(format: .speech16k)
    #expect(sink.yield(Data(count: 640), level: .silent).delivered == false)
    let (stream, continuation) = AsyncStream<MicrophoneCapture.Chunk>.makeStream(bufferingPolicy: .bufferingOldest(2))
    sink.begin(continuation)
    #expect(sink.yield(Data(count: 640), level: .silent) == (true, 0))
    _ = sink.yield(Data(count: 640), level: .silent)
    // The consumer isn't reading and the buffer holds 2: the third is dropped and counted.
    #expect(sink.yield(Data(count: 640), level: .silent) == (true, 1))
    sink.finish()
    withExtendedLifetime(stream) {}
    #expect(sink.yield(Data(count: 640), level: .silent).delivered == false)
}
