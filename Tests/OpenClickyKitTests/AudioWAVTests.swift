import Foundation
import Testing
@testable import OpenClickyKit

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Test func wavHeaderBytesForSixteenKilohertzMono() {
    let header = WAVEncoder.header(format: .speech16k, dataByteCount: 32_000)
    #expect(header.count == 44)
    #expect(hex(header) == [
        "52494646", "247d0000", "57415645",   // "RIFF", 36 + 32000, "WAVE"
        "666d7420", "10000000", "0100", "0100", // "fmt ", 16, PCM, 1 channel
        "803e0000", "007d0000", "0200", "1000", // 16000 Hz, 32000 bytes/s, block 2, 16 bits
        "64617461", "007d0000",               // "data", 32000
    ].joined())
}

@Test func wavHeaderBytesForStereoAndEmptyData() {
    let header = WAVEncoder.header(format: PCMFormat(sampleRate: 44_100, channels: 2), dataByteCount: 0)
    #expect(hex(header) == [
        "52494646", "24000000", "57415645",
        "666d7420", "10000000", "0100", "0200",
        "44ac0000", "10b10200", "0400", "1000",  // 44100 Hz, 176400 bytes/s, block 4
        "64617461", "00000000",
    ].joined())
}

@Test(arguments: [PCMFormat.speech16k, .speech24k, PCMFormat(sampleRate: 44_100, channels: 2)])
func wavEncodeDecodeRoundTrip(format: PCMFormat) throws {
    let pcm = PCMConverter.pcm16(fromSamples: (0..<(format.channels * 1000)).map { Int16(truncatingIfNeeded: $0 &* 7919) })
    let file = WAVEncoder.encode(pcm, format: format)
    #expect(file.count == 44 + pcm.count)
    let decoded = try WAVDecoder.decode(file)
    #expect(decoded.format == format)
    #expect(decoded.pcm == pcm)
    #expect(decoded.frameCount == 1000)
}

/// Builds a WAV by hand: an arbitrary fmt chunk, extra chunks, then data.
private func wav(tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16, extensible: Bool = false,
                 extraChunk: Bool = false, payload: Data) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    let blockAlign = channels * bits / 8
    var fmt = le(extensible ? UInt16(0xFFFE) : tag) + le(channels) + le(rate) + le(rate * UInt32(blockAlign)) + le(blockAlign) + le(bits)
    if extensible {
        fmt += le(UInt16(22)) + le(bits) + le(UInt32(0)) + le(tag) + Data(repeating: 0xAA, count: 14)
    }
    var body = Data("WAVE".utf8) + Data("fmt ".utf8) + le(UInt32(fmt.count)) + fmt
    if extraChunk {
        // An odd-sized LIST chunk exercises the pad byte.
        body += Data("LIST".utf8) + le(UInt32(3)) + Data([1, 2, 3, 0])
    }
    body += Data("data".utf8) + le(UInt32(payload.count)) + payload
    return Data("RIFF".utf8) + le(UInt32(body.count)) + body
}

@Test func decodesFloatTwentyFourBitEightBitAndExtensible() throws {
    let floats: [Float] = [0, 0.5, -0.5, 1.5]
    let floatPayload = floats.reduce(Data()) { $0 + withUnsafeBytes(of: $1.bitPattern.littleEndian) { Data($0) } }
    let float32 = try WAVDecoder.decode(wav(tag: 3, channels: 1, rate: 24_000, bits: 32, extraChunk: true, payload: floatPayload))
    #expect(float32.format == .speech24k)
    #expect(PCMConverter.samples(fromPCM16: float32.pcm) == [0, 16384, -16384, 32767])

    // 24-bit: 0x123456 and -2 (0xFFFFFE) keep their top 16 bits.
    let int24 = try WAVDecoder.decode(wav(tag: 1, channels: 1, rate: 16_000, bits: 24, payload: Data([0x56, 0x34, 0x12, 0xFE, 0xFF, 0xFF])))
    #expect(PCMConverter.samples(fromPCM16: int24.pcm) == [0x1234, -1])

    let int8 = try WAVDecoder.decode(wav(tag: 1, channels: 1, rate: 8_000, bits: 8, payload: Data([128, 255, 0])))
    #expect(PCMConverter.samples(fromPCM16: int8.pcm) == [0, 127 << 8, -128 << 8])

    let pcm = PCMConverter.pcm16(fromSamples: [1, 2, 3, 4])
    let extensible = try WAVDecoder.decode(wav(tag: 1, channels: 2, rate: 48_000, bits: 16, extensible: true, payload: pcm))
    #expect(extensible.format == PCMFormat(sampleRate: 48_000, channels: 2))
    #expect(extensible.pcm == pcm)
}

@Test func rejectsNonWAVAndUnsupportedEncodings() {
    #expect(throws: AudioIOError.self) { try WAVDecoder.decode(Data("not a wav file at all".utf8)) }
    #expect(throws: AudioIOError.self) {
        try WAVDecoder.decode(wav(tag: 2, channels: 1, rate: 8_000, bits: 4, payload: Data([0, 0]))) // ADPCM
    }
    // Header with no data chunk.
    let headerOnly = WAVEncoder.header(format: .speech16k, dataByteCount: 0).prefix(36)
    #expect(throws: AudioIOError.self) { try WAVDecoder.decode(Data(headerOnly)) }
}

@Test func streamingWriterPatchesSizes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-wav-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try WAVFileWriter(url: url, format: .speech16k)
    let parts = (0..<5).map { part in PCMConverter.pcm16(fromSamples: (0..<320).map { Int16(part * 1000 + $0) }) }
    for part in parts { try writer.append(part) }
    try writer.finish()
    let file = try Data(contentsOf: url)
    #expect(file.prefix(44) == WAVEncoder.header(format: .speech16k, dataByteCount: 3200))
    #expect(try WAVDecoder.decode(file).pcm == parts.reduce(Data(), +))
}
