import Foundation

/// Canonical 44-byte RIFF/WAVE files holding 16-bit PCM. Used for batch transcription uploads, recordings and
/// evidence files.
public enum WAVEncoder {
    public static let headerSize = 44

    /// The header for `dataByteCount` bytes of PCM16 in `format`.
    public static func header(format: PCMFormat, dataByteCount: Int) -> Data {
        let channels = max(1, format.channels)
        let blockAlign = channels * 2
        var header = Data(capacity: headerSize)
        header.appendASCII("RIFF")
        header.appendLE(UInt32(clamping: 36 + dataByteCount))
        header.appendASCII("WAVE")
        header.appendASCII("fmt ")
        header.appendLE(UInt32(16))               // fmt chunk size
        header.appendLE(UInt16(1))                // PCM
        header.appendLE(UInt16(channels))
        header.appendLE(UInt32(format.sampleRate))
        header.appendLE(UInt32(format.sampleRate * blockAlign)) // byte rate
        header.appendLE(UInt16(blockAlign))
        header.appendLE(UInt16(16))               // bits per sample
        header.appendASCII("data")
        header.appendLE(UInt32(clamping: dataByteCount))
        return header
    }

    /// A complete WAV file for a PCM16 clip.
    public static func encode(_ pcm: Data, format: PCMFormat) -> Data {
        header(format: format, dataByteCount: pcm.count) + pcm
    }
}

/// A WAV file decoded to OpenClicky's wire format.
public struct DecodedAudio: Sendable, Hashable {
    /// Interleaved little-endian PCM16.
    public var pcm: Data
    public var format: PCMFormat

    public init(pcm: Data, format: PCMFormat) {
        self.pcm = pcm
        self.format = format
    }

    public var frameCount: Int { pcm.count / (2 * max(1, format.channels)) }
    public var duration: TimeInterval { Double(frameCount) / Double(max(1, format.sampleRate)) }
}

/// Reads RIFF/WAVE files: integer PCM (8, 16, 24, 32 bit), IEEE float (32, 64 bit) and WAVE_FORMAT_EXTENSIBLE
/// wrappers of those. Unknown chunks (LIST, fact, …) are skipped. Samples come out as PCM16.
public enum WAVDecoder {
    public static func decode(_ data: Data) throws -> DecodedAudio {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes.ascii(0, 4) == "RIFF", bytes.ascii(8, 4) == "WAVE" else {
            throw AudioIOError.unsupportedWAV("not a RIFF/WAVE file")
        }
        var offset = 12
        var fmt: (tag: UInt16, channels: Int, rate: Int, bits: Int, blockAlign: Int)?
        var payload: Range<Int>?
        while offset + 8 <= bytes.count {
            let id = bytes.ascii(offset, 4)
            let declared = Int(bytes.uint32LE(offset + 4))
            let bodyStart = offset + 8
            // Streaming writers sometimes leave the data size at 0 or 0xFFFFFFFF; take the rest of the file then.
            var size = declared
            if id == "data" && (declared == 0 || declared == 0xFFFF_FFFF || bodyStart + declared > bytes.count) {
                size = bytes.count - bodyStart
            }
            guard bodyStart + size <= bytes.count else { break }
            switch id {
            case "fmt ":
                guard size >= 16 else { throw AudioIOError.unsupportedWAV("fmt chunk too short") }
                var tag = bytes.uint16LE(bodyStart)
                let channels = Int(bytes.uint16LE(bodyStart + 2))
                let rate = Int(bytes.uint32LE(bodyStart + 4))
                let blockAlign = Int(bytes.uint16LE(bodyStart + 12))
                let bits = Int(bytes.uint16LE(bodyStart + 14))
                if tag == 0xFFFE, size >= 40 {
                    // WAVE_FORMAT_EXTENSIBLE: the real format tag is the first two bytes of the sub-format GUID.
                    tag = bytes.uint16LE(bodyStart + 24)
                }
                fmt = (tag, channels, rate, bits, blockAlign)
            case "data":
                payload = bodyStart..<(bodyStart + size)
            default:
                break
            }
            offset = bodyStart + size + (size & 1)
        }
        guard let fmt else { throw AudioIOError.unsupportedWAV("missing fmt chunk") }
        guard let payload else { throw AudioIOError.unsupportedWAV("missing data chunk") }
        guard fmt.channels > 0, fmt.rate > 0 else { throw AudioIOError.unsupportedWAV("\(fmt.channels) channels at \(fmt.rate) Hz") }
        let format = PCMFormat(sampleRate: fmt.rate, channels: fmt.channels)
        let bytesPerSample = max(1, fmt.bits / 8)
        let sampleCount = payload.count / bytesPerSample
        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        let base = payload.lowerBound
        switch (fmt.tag, fmt.bits) {
        case (1, 8):
            for i in 0..<sampleCount { samples.append(Int16((Int(bytes[base + i]) - 128) << 8)) }
        case (1, 16):
            return DecodedAudio(pcm: Data(bytes[payload].prefix(sampleCount * 2)), format: format)
        case (1, 24):
            for i in 0..<sampleCount {
                let p = base + i * 3
                let value = Int32(bitPattern: UInt32(bytes[p]) << 8 | UInt32(bytes[p + 1]) << 16 | UInt32(bytes[p + 2]) << 24)
                samples.append(Int16(truncatingIfNeeded: value >> 16))
            }
        case (1, 32):
            for i in 0..<sampleCount {
                samples.append(Int16(truncatingIfNeeded: Int32(bitPattern: bytes.uint32LE(base + i * 4)) >> 16))
            }
        case (3, 32):
            for i in 0..<sampleCount {
                samples.append(PCMConverter.int16(fromFloat: Float(bitPattern: bytes.uint32LE(base + i * 4))))
            }
        case (3, 64):
            for i in 0..<sampleCount {
                let low = UInt64(bytes.uint32LE(base + i * 8))
                let high = UInt64(bytes.uint32LE(base + i * 8 + 4))
                samples.append(PCMConverter.int16(fromFloat: Float(Double(bitPattern: high << 32 | low))))
            }
        default:
            throw AudioIOError.unsupportedWAV("format tag \(fmt.tag) with \(fmt.bits) bits per sample")
        }
        return DecodedAudio(pcm: PCMConverter.pcm16(fromSamples: samples), format: format)
    }
}

/// Writes a PCM16 WAV file incrementally (for recordings): a placeholder header first, sizes patched on `finish()`.
public final class WAVFileWriter {
    public let url: URL
    public let format: PCMFormat
    public private(set) var dataByteCount = 0
    private let handle: FileHandle
    private var finished = false

    public init(url: URL, format: PCMFormat) throws {
        self.url = url
        self.format = format
        FileManager.default.createFile(atPath: url.path, contents: WAVEncoder.header(format: format, dataByteCount: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ pcm: Data) throws {
        guard !finished, !pcm.isEmpty else { return }
        try handle.write(contentsOf: pcm)
        dataByteCount += pcm.count
    }

    /// Patches the header sizes and closes the file.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAVEncoder.header(format: format, dataByteCount: dataByteCount))
        try handle.close()
    }

    deinit { if !finished { try? finish() } }
}

fileprivate extension Data {
    mutating func appendASCII(_ text: String) { append(contentsOf: Array(text.utf8)) }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    func ascii(_ offset: Int, _ count: Int) -> String {
        guard offset + count <= self.count else { return "" }
        return String(decoding: self[offset..<(offset + count)], as: UTF8.self)
    }

    func uint16LE(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
