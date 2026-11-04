import AVFoundation
import Foundation
import Testing
@testable import OpenClickyKit

/// These run the real playback chain (AVAudioSourceNode → AVAudioUnitTimePitch when not at 1x → mixer) in
/// AVAudioEngine's offline manual-rendering mode: no audio hardware, deterministic output.

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SpeechPlayer.Event] = []
    func append(_ event: SpeechPlayer.Event) { lock.withLock { list.append(event) } }
    var all: [SpeechPlayer.Event] { lock.withLock { list } }
}

/// Renders until the player drains (plus a tail) and returns the mono output.
private func render(_ host: AudioEngineHost, _ player: SpeechPlayer, maxSeconds: Double = 2) throws -> [Float] {
    var output: [Float] = []
    var tail = 0
    while output.count < Int(maxSeconds * 24_000) {
        let buffer = try host.renderOffline(frames: 512)
        output += PCMConverter.monoFloats(from: buffer)
        player.poll()
        if player.isIdle { tail += 1 }
        if tail > 8 { break }
    }
    return output
}

/// Runs of (rounded value, start, length) in the output.
private func runs(_ samples: [Float], quantum: Float = 0.05) -> [(value: Float, start: Int, length: Int)] {
    var result: [(Float, Int, Int)] = []
    var start = 0
    for i in 1...samples.count {
        let current = (samples[start] / quantum).rounded() * quantum
        let next = i < samples.count ? (samples[i] / quantum).rounded() * quantum : .nan
        if next != current {
            result.append((current, start, i - start))
            start = i
        }
    }
    return result
}

private func dc(_ frames: Int, _ value: Float) -> Data {
    PCMConverter.pcm16(fromFloats: [Float](repeating: value, count: frames))
}

@Test func realEnginePlaysLinesBackToBackWithoutGaps() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    let events = Events()
    player.onEvent = { events.append($0) }

    let line0 = player.beginLine(0)
    player.append(dc(1200, 0.25), format: .speech24k, to: line0)
    player.append(dc(1200, 0.25), format: .speech24k, to: line0)
    player.finishLine(line0)
    let line1 = player.beginLine(1)
    // Line 1 arrives at 16 kHz and is resampled on the way in.
    player.append(dc(1600, -0.5), format: .speech16k, to: line1)
    player.finishLine(line1)

    let output = try render(host, player)
    let segments = runs(output).filter { $0.length > 40 }
    // Silence, 0.1 s at +0.25, then straight into 0.1 s at -0.5 (the resampler's edges blur a few frames), silence.
    let positive = try #require(segments.first { $0.value == 0.25 })
    let negative = try #require(segments.first { $0.value == -0.5 })
    #expect(abs(positive.length - 2400) <= 2)
    #expect(abs(negative.length - 2400) <= 24)
    let gap = negative.start - (positive.start + positive.length)
    #expect(gap >= 0 && gap <= 12, "gap of \(gap) frames between lines")
    #expect(output[(positive.start + 10)..<(positive.start + positive.length - 10)].allSatisfy { abs($0 - 0.25) < 0.001 })

    let all = events.all
    #expect(all.count == 5)
    #expect(all.first == .lineStarted(index: 0, expectedDuration: 0.1))
    #expect(Array(all.dropFirst().prefix(1)) == [.lineFinished(index: 0)])
    guard all.count == 5, case .lineStarted(1, let duration?) = all[2] else {
        Issue.record("unexpected events \(all)")
        return
    }
    // Resampled from 16 kHz: within a frame of 0.1 s.
    #expect(abs(duration - 0.1) < 1.0 / 24_000)
    #expect(Array(all.suffix(2)) == [.lineFinished(index: 1), .drained])
}

@Test func realEngineStarvedAudioResumesAtAnExactFrame() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    let line = player.beginLine(0)
    player.append(dc(1200, 0.25), format: .speech24k, to: line)
    // Let the output run dry for a while, then deliver more of the same line.
    var output: [Float] = []
    for _ in 0..<12 {
        output += PCMConverter.monoFloats(from: try host.renderOffline(frames: 512))
        player.poll()
    }
    player.append(dc(1200, -0.5), format: .speech24k, to: line)
    player.finishLine(line)
    output += try render(host, player)

    let segments = runs(output).filter { $0.length > 40 }
    let first = try #require(segments.first { $0.value == 0.25 })
    let late = try #require(segments.first { $0.value == -0.5 })
    #expect(first.length == 1200)
    #expect(late.length == 1200, "segments \(segments)")
    #expect(late.start > first.start + first.length) // a real gap: the stream starved
}

@Test func realEngineSpeedChangesDuration() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    player.rate = 2
    // A tone, so the time-pitch unit has something periodic to work with.
    let tone = (0..<12_000).map { 0.4 * Float(sin(2 * Double.pi * 300 * Double($0) / 24_000)) }
    player.play(PCMConverter.pcm16(fromFloats: tone), format: .speech24k, line: 0)
    let output = try render(host, player)
    let loud = output.indices.filter { abs(output[$0]) > 0.05 }
    let span = (loud.last ?? 0) - (loud.first ?? 0)
    // 0.5 s of audio at double speed takes about 0.25 s.
    #expect(abs(Double(span) / 24_000 - 0.25) < 0.04, "rendered span \(Double(span) / 24_000) s")
}

@Test func cuesRenderThroughTheRealChain() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let cues = CuePlayer(player: SpeechPlayer(sampleRate: 24_000, host: host), volume: 1, coldLeadIn: 0, coldLeadInBluetooth: 0)
    cues.play(.startListening)
    let output = try render(host, cues.player)
    let expected = UICue.startListening.samples(sampleRate: 24_000).map {
        PCMConverter.float(fromInt16: PCMConverter.int16(fromFloat: $0))
    }
    let first = try #require(output.firstIndex { abs($0) > 0.001 })
    // The soft attack starts below the detection threshold: find the alignment with the smallest error.
    func error(at start: Int) -> Float {
        guard start >= 0, start + expected.count <= output.count else { return .infinity }
        return zip(output[start..<(start + expected.count)], expected).map { abs($0 - $1) }.max() ?? .infinity
    }
    let start = (max(0, first - 400)...(first + 2)).min { error(at: $0) < error(at: $1) } ?? first
    let maxError = error(at: start)
    #expect(maxError < 0.0005, "max error \(maxError) at offset \(start - first)")
}

// MARK: Timeline accuracy against what the engine actually renders

/// Renders in fixed slices, polling after each, and notes the output frame at which each event was reported.
private final class TimedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(event: SpeechPlayer.Event, frame: Int)] = []
    var frame = 0
    func append(_ event: SpeechPlayer.Event) { lock.withLock { list.append((event, frame)) } }
    var all: [(event: SpeechPlayer.Event, frame: Int)] { lock.withLock { list } }
    func frame(of match: (SpeechPlayer.Event) -> Bool) -> Int? { all.first { match($0.event) }?.frame }
}

private func renderTimed(_ host: AudioEngineHost, _ player: SpeechPlayer, _ timed: TimedEvents, slice: Int,
                         until done: () -> Bool) throws -> [Float] {
    var output: [Float] = []
    var guardFrames = 0
    while !done() && guardFrames < 24_000 * 5 {
        output += PCMConverter.monoFloats(from: try host.renderOffline(frames: slice))
        timed.frame += slice
        guardFrames += slice
        player.poll()
    }
    return output
}

private func tone(_ frames: Int, amplitude: Float = 0.4, hz: Double = 300) -> Data {
    PCMConverter.pcm16(fromFloats: (0..<frames).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 24_000)) })
}

@Test func realEngineEventsLandInTheSliceWhereTheAudioIs() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    let timed = TimedEvents()
    player.onEvent = { timed.append($0) }
    let slice = 256
    // The engine is already running when the voice starts, at a frame that isn't slice-aligned in timeline terms.
    var output = PCMConverter.monoFloats(from: try host.renderOffline(frames: 1000))
    timed.frame = 1000

    let line0 = player.beginLine(0)
    player.append(dc(4800, 0.25), format: .speech24k, to: line0)
    player.finishLine(line0)
    let line1 = player.beginLine(1)
    player.append(dc(2400, -0.5), format: .speech24k, to: line1)
    player.finishLine(line1)
    output += try renderTimed(host, player, timed, slice: slice) { player.isIdle }

    let segments = runs(output).filter { $0.length > 40 }
    let first = try #require(segments.first { $0.value == 0.25 })
    let second = try #require(segments.first { $0.value == -0.5 })
    #expect(first.start == 1000 && first.length == 4800 && second.start == 5800 && second.length == 2400)

    // Each event is reported by the poll right after the slice in which its audio boundary was rendered.
    func check(_ event: SpeechPlayer.Event, boundary: Int) {
        guard let frame = timed.frame(of: { $0 == event }) else {
            Issue.record("missing \(event)")
            return
        }
        #expect(frame - slice < boundary && boundary <= frame, "\(event) at \(frame), audio boundary at \(boundary)")
    }
    // `boundary` is the output frame that must have been rendered: a line's first frame for its start, and the first
    // frame after it for its finish.
    check(.lineStarted(index: 0, expectedDuration: 0.2), boundary: first.start + 1)
    check(.lineFinished(index: 0), boundary: first.start + first.length + 1)
    check(.lineStarted(index: 1, expectedDuration: 0.1), boundary: second.start + 1)
    check(.lineFinished(index: 1), boundary: second.start + second.length + 1)
}

@Test(arguments: [Float(1.5), Float(0.75)])
func realEngineTimelineAtOtherSpeedsAccountsForTheTimePitchDelay(rate: Float) throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    player.rate = rate
    let timed = TimedEvents()
    player.onEvent = { timed.append($0) }
    let slice = 256
    var output = PCMConverter.monoFloats(from: try host.renderOffline(frames: 2400))
    timed.frame = 2400
    player.play(tone(12_000), format: .speech24k, line: 0)
    output += try renderTimed(host, player, timed, slice: slice) { player.isIdle }
    output += PCMConverter.monoFloats(from: try host.renderOffline(frames: 4800))

    let loud = output.indices.filter { abs(output[$0]) > 0.05 }
    let firstLoud = try #require(loud.first)
    let lastLoud = try #require(loud.last)
    let started = try #require(timed.frame { if case .lineStarted = $0 { true } else { false } })
    let finished = try #require(timed.frame(of: { $0 == .lineFinished(index: 0) }))
    // Within a slice plus a few milliseconds; without the delay correction the events come 50–80 ms early.
    let tolerance = slice + 120
    #expect(abs(started - firstLoud) <= tolerance, "started at \(started), audio from \(firstLoud)")
    #expect(abs(finished - lastLoud) <= tolerance, "finished at \(finished), audio until \(lastLoud)")
    #expect(abs(Double(lastLoud - firstLoud) / 24_000 - 0.5 / Double(rate)) < 0.03)
}

@Test func stopLeavesNoTailFromTheTimePitchUnit() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    player.rate = 1.5
    player.play(tone(24_000), format: .speech24k, line: 0)
    var before: [Float] = []
    for _ in 0..<20 {
        before += PCMConverter.monoFloats(from: try host.renderOffline(frames: 256))
        player.poll()
    }
    #expect(before.contains { abs($0) > 0.1 }, "the tone was playing")
    let report = player.stop()
    #expect(report.cutLine == 0)
    let after = PCMConverter.monoFloats(from: try host.renderOffline(frames: 4800))
    let peak = after.map(abs).max() ?? 0
    #expect(peak < 0.01, "audio kept playing after stop (peak \(peak))")
}

@Test func offlineRenderAcceptsRequestsLongerThanOneSlice() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    player.play(dc(9000, 0.25), format: .speech24k, line: 0)
    let buffer = try host.renderOffline(frames: 10_000)
    #expect(buffer.frameLength == 10_000)
    let output = PCMConverter.monoFloats(from: buffer)
    #expect(output[0..<9000].allSatisfy { abs($0 - 0.25) < 0.001 })
    #expect(output[9000...].allSatisfy { $0 == 0 })
}

// MARK: The source node's queue

@Test func sourceTimelinePlacesBuffersByFrameAndRendersSilenceBetween() {
    let timeline = SourceTimeline()
    func buffer(_ value: Float, _ frames: Int) -> AVAudioPCMBuffer {
        PCMConverter.floatBuffer(mono: [Float](repeating: value, count: frames), sampleRate: 24_000)
    }
    timeline.schedule(buffer(0.1, 100), at: nil)        // 0..<100
    timeline.schedule(buffer(0.2, 50), at: nil)         // 100..<150, right behind
    timeline.schedule(buffer(0.3, 100), at: 200)        // explicit, leaving a gap 150..<200
    var out = [Float](repeating: 9, count: 128)
    var rendered: [Float] = []
    for _ in 0..<3 {
        let audible = out.withUnsafeMutableBufferPointer { timeline.render(into: $0.baseAddress!, frames: 128, hostTime: 0) }
        #expect(audible)
        rendered += out
    }
    #expect(rendered[0..<100].allSatisfy { $0 == 0.1 })
    #expect(rendered[100..<150].allSatisfy { $0 == 0.2 })
    #expect(rendered[150..<200].allSatisfy { $0 == 0 })
    #expect(rendered[200..<300].allSatisfy { $0 == 0.3 })
    #expect(rendered[300..<384].allSatisfy { $0 == 0 })
    #expect(timeline.renderedFrames == 384)
    #expect(timeline.lastRender?.start == 256)

    // A buffer placed in the past starts at the next unrendered frame instead.
    timeline.schedule(buffer(0.4, 10), at: 5)
    _ = out.withUnsafeMutableBufferPointer { timeline.render(into: $0.baseAddress!, frames: 128, hostTime: 0) }
    #expect(out[0..<10].allSatisfy { $0 == 0.4 } && out[10...].allSatisfy { $0 == 0 })

    timeline.reset()
    #expect(timeline.renderedFrames == 0 && timeline.lastRender == nil)
    let audible = out.withUnsafeMutableBufferPointer { timeline.render(into: $0.baseAddress!, frames: 128, hostTime: 0) }
    #expect(!audible)
}

@Test func timePitchDelayIsMeasuredForEachSpeed() throws {
    let fast = try TimePitchCalibration.measure(rate: 2, sampleRate: 24_000, outputRate: 48_000)
    let slow = try TimePitchCalibration.measure(rate: 0.5, sampleRate: 24_000, outputRate: 48_000)
    // Tens of milliseconds of audio either way (measured 40–100 ms on macOS 27).
    for frames in [fast, slow] { #expect(frames > 240 && frames < 4800, "\(frames) frames") }
}

@Test func aLineAfterSilenceStartsOnlyOnceItIsRendered() throws {
    let host = AudioEngineHost(offlineSampleRate: 24_000)
    let player = SpeechPlayer(sampleRate: 24_000, host: host)
    let timed = TimedEvents()
    player.onEvent = { timed.append($0) }
    player.play(dc(480, 0.25), format: .speech24k, line: 0)
    var output = try renderTimed(host, player, timed, slice: 256) { player.isIdle }
    // The output keeps running, silent, for a while before the next line arrives.
    output += PCMConverter.monoFloats(from: try host.renderOffline(frames: 1000))
    timed.frame += 1000
    player.poll()
    player.play(dc(480, -0.5), format: .speech24k, line: 1)
    #expect(timed.frame(of: { if case .lineStarted(1, _) = $0 { true } else { false } }) == nil,
            "line 1 must not count as started before any of it was rendered")
    output += try renderTimed(host, player, timed, slice: 256) { player.isIdle }
    let late = try #require(runs(output).first { $0.value == -0.5 })
    let started = try #require(timed.frame { if case .lineStarted(1, _) = $0 { true } else { false } })
    #expect(started - 256 < late.start + 1 && late.start + 1 <= started)
}
