import Foundation

/// Loudness of a block of samples, for the waveform, the input meter and the silent-mic check.
public struct AudioLevel: Sendable, Hashable {
    /// Root-mean-square amplitude, 0…1 (full-scale sine ≈ 0.707).
    public var rms: Float
    /// Largest absolute sample, 0…1.
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silent = AudioLevel(rms: 0, peak: 0)

    /// The floor used for dB values of silence.
    public static let floorDB: Float = -120

    public var rmsDB: Float { Self.decibels(rms) }
    public var peakDB: Float { Self.decibels(peak) }

    /// 0…1 for drawing: -60 dBFS RMS (a quiet room) maps to 0 and 0 dBFS to 1, linear in dB between.
    public var normalized: Float { Self.normalized(db: rmsDB) }

    public static func normalized(db: Float, floor: Float = -60) -> Float {
        min(1, max(0, (db - floor) / -floor))
    }

    public static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0 ? max(floorDB, 20 * log10(amplitude)) : floorDB
    }

    public static func measure(_ samples: some Collection<Float>) -> AudioLevel {
        guard !samples.isEmpty else { return .silent }
        var sumSquares: Double = 0
        var peak: Float = 0
        for sample in samples {
            let value = sample.isFinite ? sample : 0
            sumSquares += Double(value * value)
            peak = max(peak, abs(value))
        }
        return AudioLevel(rms: Float((sumSquares / Double(samples.count)).squareRoot()), peak: min(peak, 1))
    }

    /// Level of little-endian PCM16 bytes (all channels together).
    public static func measure(pcm16 data: Data) -> AudioLevel {
        let samples = PCMConverter.samples(fromPCM16: data)
        guard !samples.isEmpty else { return .silent }
        var sumSquares: Double = 0
        var peak: Int = 0
        for sample in samples {
            let value = Int(sample)
            sumSquares += Double(value * value)
            peak = max(peak, abs(value))
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot() / 32768
        return AudioLevel(rms: Float(rms), peak: min(1, Float(peak) / 32768))
    }
}

/// Eases a level for display: rises quickly with speech, falls slowly so the waveform doesn't flicker.
public struct LevelSmoother: Sendable, Hashable {
    /// Fraction of the gap closed per update when the level rises / falls.
    public var attack: Float
    public var release: Float
    public private(set) var value: Float = 0

    public init(attack: Float = 0.6, release: Float = 0.2) {
        self.attack = attack
        self.release = release
    }

    public mutating func update(_ target: Float) -> Float {
        let factor = target > value ? attack : release
        value += (target - value) * factor
        if value < 0.0005 { value = 0 }
        return value
    }

    public mutating func reset() { value = 0 }
}

/// Re-slices a PCM16 byte stream into fixed-duration chunks (whole frames), whatever sizes it arrives in.
public struct PCM16Chunker: Sendable {
    public let format: PCMFormat
    /// Bytes per emitted chunk.
    public let chunkBytes: Int
    private var pending = Data()

    public init(format: PCMFormat, duration: TimeInterval) {
        self.format = format
        let frameBytes = 2 * max(1, format.channels)
        let frames = max(1, Int((Double(format.sampleRate) * duration).rounded()))
        chunkBytes = frames * frameBytes
    }

    /// Bytes held until the next chunk is complete.
    public var pendingByteCount: Int { pending.count }

    public mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var chunks: [Data] = []
        var start = pending.startIndex
        while pending.endIndex - start >= chunkBytes {
            chunks.append(Data(pending[start..<(start + chunkBytes)]))
            start += chunkBytes
        }
        if start != pending.startIndex { pending = Data(pending[start...]) }
        return chunks
    }

    /// The partial chunk left at the end of a stream (whole frames only), or nil.
    public mutating func flush() -> Data? {
        let frameBytes = 2 * max(1, format.channels)
        let usable = pending.count - pending.count % frameBytes
        defer { pending = Data() }
        return usable > 0 ? Data(pending.prefix(usable)) : nil
    }
}
