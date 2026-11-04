import AVFoundation
import Foundation
import Testing
@testable import OpenClickyKit

private func sine(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(sampleRate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

/// Upward zero crossings per second, a cheap frequency estimate.
private func estimatedFrequency(_ samples: [Float], sampleRate: Double) -> Double {
    var crossings = 0
    for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
    return Double(crossings) / (Double(samples.count) / sampleRate)
}

@Test func everyInt16SurvivesAFloatRoundTrip() {
    for value in Int(Int16.min)...Int(Int16.max) {
        let sample = Int16(value)
        #expect(PCMConverter.int16(fromFloat: PCMConverter.float(fromInt16: sample)) == sample)
    }
}

@Test func floatToInt16ClipsAndRounds() {
    #expect(PCMConverter.int16(fromFloat: 0) == 0)
    #expect(PCMConverter.int16(fromFloat: 0.5) == 16384)
    #expect(PCMConverter.int16(fromFloat: -0.5) == -16384)
    #expect(PCMConverter.int16(fromFloat: 1) == 32767)
    #expect(PCMConverter.int16(fromFloat: -1) == -32768)
    #expect(PCMConverter.int16(fromFloat: 1.7) == 32767)
    #expect(PCMConverter.int16(fromFloat: -42) == -32768)
    #expect(PCMConverter.int16(fromFloat: .infinity) == 32767)
    #expect(PCMConverter.int16(fromFloat: -.infinity) == -32768)
    #expect(PCMConverter.int16(fromFloat: .nan) == 0)
    // Rounds to nearest instead of truncating toward zero.
    #expect(PCMConverter.int16(fromFloat: 1.6 / 32768) == 2)
    #expect(PCMConverter.int16(fromFloat: -1.6 / 32768) == -2)
}

@Test func pcm16BytesAreLittleEndian() {
    let data = PCMConverter.pcm16(fromSamples: [1, -2, 0x1234])
    #expect([UInt8](data) == [0x01, 0x00, 0xFE, 0xFF, 0x34, 0x12])
    #expect(PCMConverter.samples(fromPCM16: data) == [1, -2, 0x1234])
    // A dangling half sample is ignored.
    #expect(PCMConverter.samples(fromPCM16: data + Data([0x7F])) == [1, -2, 0x1234])
}

@Test(arguments: [1, 2])
func pcm16DataRoundTripsThroughAFloatBuffer(channels: Int) throws {
    // Includes both extremes; 480 × channels + 2 samples is whole frames for 1 and 2 channels.
    let samples: [Int16] = (0..<(480 * channels)).map { Int16(truncatingIfNeeded: $0 * 997 - 30_000) } + [.max, .min]
    let data = PCMConverter.pcm16(fromSamples: samples)
    let format = PCMFormat(sampleRate: 16_000, channels: channels)
    let buffer = try PCMConverter.floatBuffer(fromPCM16: data, format: format)
    #expect(buffer.format.commonFormat == .pcmFormatFloat32)
    #expect(!buffer.format.isInterleaved)
    #expect(Int(buffer.format.channelCount) == channels)
    #expect(Int(buffer.frameLength) == data.count / (2 * channels))
    #expect(PCMConverter.pcm16(from: buffer) == data)
    // And through an interleaved Int16 buffer.
    let int16Buffer = try PCMConverter.int16Buffer(fromPCM16: data, format: format)
    #expect(PCMConverter.pcm16(from: int16Buffer) == data)
}

@Test func monoDownmixAveragesAndPicksChannels() throws {
    let stereo = PCMConverter.pcm16(fromSamples: [100, 300, -100, -301, 32767, 32767])
    #expect(PCMConverter.samples(fromPCM16: PCMConverter.downmixToMono(stereo, channels: 2)) == [200, -201, 32767])
    let buffer = try PCMConverter.floatBuffer(fromPCM16: stereo, format: PCMFormat(sampleRate: 8000, channels: 2))
    #expect(PCMConverter.monoFloats(from: buffer, channel: 1).map(PCMConverter.int16(fromFloat:)) == [300, -301, 32767])
}

@Test func resampledFrameCountMath() {
    #expect(PCMConverter.resampledFrameCount(48_000, from: 48_000, to: 16_000) == 16_000)
    #expect(PCMConverter.resampledFrameCount(16_000, from: 16_000, to: 24_000) == 24_000)
    #expect(PCMConverter.resampledFrameCount(441, from: 44_100, to: 16_000) == 160)
    #expect(PCMConverter.resampledFrameCount(1_000, from: 44_100, to: 16_000) == 363) // 362.81
    #expect(PCMConverter.resampledFrameCount(3, from: 16_000, to: 24_000) == 5) // 4.5 rounds up
    #expect(PCMConverter.resampledFrameCount(0, from: 16_000, to: 24_000) == 0)
}

/// Streaming conversion in uneven chunks yields the expected total length (± a frame) and keeps the signal.
@Test(arguments: [(48_000.0, 16_000), (44_100.0, 16_000), (16_000.0, 24_000), (24_000.0, 16_000), (48_000.0, 24_000)])
func streamingResamplingKeepsLengthAndPitch(sourceRate: Double, targetRate: Int) throws {
    let input = sine(frequency: 440, sampleRate: sourceRate, seconds: 1)
    let resampler = try PCMResampler(
        from: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)!,
        to: PCMConverter.avFormat(PCMFormat(sampleRate: targetRate)))
    var output = Data()
    var offset = 0
    let sizes = [480, 37, 1024, 4096, 1, 333]
    var turn = 0
    while offset < input.count {
        let size = min(sizes[turn % sizes.count], input.count - offset)
        turn += 1
        let chunk = PCMConverter.floatBuffer(mono: Array(input[offset..<(offset + size)]), sampleRate: sourceRate)
        if let converted = try resampler.convert(chunk) { output += PCMConverter.pcm16(from: converted) }
        offset += size
    }
    if let tail = try resampler.finish() { output += PCMConverter.pcm16(from: tail) }

    let frames = output.count / 2
    let expected = PCMConverter.resampledFrameCount(input.count, from: sourceRate, to: Double(targetRate))
    #expect(abs(frames - expected) <= 1, "got \(frames) frames, expected \(expected)")

    let samples = PCMConverter.floats(fromPCM16: output)
    // Skip the filter's edges, then check pitch and loudness survived.
    let middle = Array(samples[(targetRate / 10)..<(samples.count - targetRate / 10)])
    #expect(abs(estimatedFrequency(middle, sampleRate: Double(targetRate)) - 440) < 3)
    #expect(abs(AudioLevel.measure(middle).rms - Float(0.5 / 2.0.squareRoot())) < 0.01)
}

@Test func oneShotConvertHandlesRateAndChannels() throws {
    let stereo48k = PCMConverter.pcm16(fromFloats: sine(frequency: 300, sampleRate: 48_000, seconds: 0.5).flatMap { [$0, $0] })
    let mono16k = try PCMConverter.convert(stereo48k, from: PCMFormat(sampleRate: 48_000, channels: 2), to: .speech16k)
    #expect(abs(mono16k.count / 2 - 8_000) <= 1)
    // Same format is a no-op.
    #expect(try PCMConverter.convert(mono16k, from: .speech16k, to: .speech16k) == mono16k)
}

@Test func sliceCopiesTheTail() throws {
    let buffer = PCMConverter.floatBuffer(mono: [0, 0.25, 0.5, 0.75], sampleRate: 24_000)
    let tail = try #require(PCMConverter.slice(buffer, from: 1))
    #expect(Int(tail.frameLength) == 3)
    #expect(PCMConverter.monoFloats(from: tail) == [0.25, 0.5, 0.75])
    #expect(PCMConverter.slice(buffer, from: 4) == nil)
}

// MARK: Levels and chunking

@Test func levelsOfKnownSignals() {
    let fullScale = AudioLevel.measure(sine(frequency: 1000, sampleRate: 48_000, seconds: 0.1, amplitude: 1))
    #expect(abs(fullScale.rmsDB - -3.01) < 0.05)
    #expect(abs(fullScale.peak - 1) < 0.001)
    #expect(AudioLevel.measure([Float](repeating: 0, count: 100)) == .silent)
    #expect(AudioLevel.silent.rmsDB == AudioLevel.floorDB)
    #expect(AudioLevel.silent.normalized == 0)
    #expect(AudioLevel.normalized(db: 0) == 1)
    #expect(AudioLevel.normalized(db: -30) == 0.5)
    #expect(AudioLevel.normalized(db: -90) == 0)
    // PCM16 measurement agrees with the float one.
    let pcm = PCMConverter.pcm16(fromFloats: sine(frequency: 1000, sampleRate: 48_000, seconds: 0.1, amplitude: 0.25))
    #expect(abs(AudioLevel.measure(pcm16: pcm).rmsDB - (20 * log10(0.25) - 3.01)) < 0.05)
}

@Test func levelSmootherRisesFastAndFallsSlowly() {
    var smoother = LevelSmoother(attack: 0.5, release: 0.1)
    #expect(smoother.update(1) == 0.5)
    #expect(smoother.update(1) == 0.75)
    let afterDrop = smoother.update(0)
    #expect(abs(afterDrop - 0.675) < 0.0001)
}

@Test func chunkerEmitsFixedChunksWhateverArrives() {
    var chunker = PCM16Chunker(format: .speech16k, duration: 0.04)
    #expect(chunker.chunkBytes == 1280)
    var chunks: [Data] = []
    var fed = Data()
    // Uneven deliveries, including odd byte counts that split a sample.
    for size in [1, 999, 3, 2048, 640, 1281, 7] {
        let piece = Data((0..<size).map { UInt8(truncatingIfNeeded: fed.count + $0) })
        fed += piece
        chunks += chunker.append(piece)
    }
    #expect(chunks.allSatisfy { $0.count == 1280 })
    #expect(chunks.count == fed.count / 1280)
    let rest = chunker.flush()
    let joined = chunks.reduce(Data(), +) + (rest ?? Data())
    #expect(joined == fed.prefix(joined.count))
    #expect((rest?.count ?? 0) % 2 == 0)
    #expect(chunker.flush() == nil)
}
