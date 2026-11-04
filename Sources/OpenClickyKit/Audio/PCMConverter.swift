import AVFoundation
import Foundation

/// Conversions between OpenClicky's wire format (`Data` holding little-endian 16-bit PCM, interleaved) and
/// AVAudioEngine buffers, plus sample-rate conversion.
///
/// Scaling convention: Int16 → Float divides by 32768, Float → Int16 multiplies by 32768, rounds to nearest and clips
/// to [-32768, 32767]. With one factor both ways every Int16 value survives a round trip exactly; +1.0 clips to 32767.
public enum PCMConverter {
    // MARK: Samples

    @inlinable
    public static func float(fromInt16 sample: Int16) -> Float { Float(sample) / 32768 }

    /// Float → Int16 with clipping. NaN becomes silence.
    @inlinable
    public static func int16(fromFloat sample: Float) -> Int16 {
        guard !sample.isNaN else { return 0 }
        let scaled = (sample * 32768).rounded()
        if scaled >= 32767 { return .max }
        if scaled <= -32768 { return .min }
        return Int16(scaled)
    }

    /// Little-endian PCM16 bytes → samples. A trailing odd byte is ignored.
    public static func samples(fromPCM16 data: Data) -> [Int16] {
        let count = data.count / 2
        var samples = [Int16](repeating: 0, count: count)
        guard count > 0 else { return samples }
        samples.withUnsafeMutableBytes { destination in
            _ = data.copyBytes(to: destination.bindMemory(to: UInt8.self), count: count * 2)
        }
        if Int16(littleEndian: 1) != 1 {
            for index in samples.indices { samples[index] = Int16(littleEndian: samples[index]) }
        }
        return samples
    }

    /// Samples → little-endian PCM16 bytes.
    public static func pcm16(fromSamples samples: [Int16]) -> Data {
        if Int16(littleEndian: 1) == 1 {
            return samples.withUnsafeBytes { Data($0) }
        }
        return samples.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }

    public static func floats(fromPCM16 data: Data) -> [Float] {
        samples(fromPCM16: data).map(float(fromInt16:))
    }

    public static func pcm16(fromFloats floats: [Float]) -> Data {
        pcm16(fromSamples: floats.map(int16(fromFloat:)))
    }

    /// Averages interleaved channels of PCM16 into one.
    public static func downmixToMono(_ data: Data, channels: Int) -> Data {
        guard channels > 1 else { return data }
        let samples = samples(fromPCM16: data)
        let frames = samples.count / channels
        var mono = [Int16](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum = 0
            for channel in 0..<channels { sum += Int(samples[frame * channels + channel]) }
            mono[frame] = Int16(clamping: (sum + (sum >= 0 ? channels / 2 : -channels / 2)) / channels)
        }
        return pcm16(fromSamples: mono)
    }

    // MARK: Formats

    /// The AVAudioFormat for a PCMFormat: interleaved Int16 (the wire format) or deinterleaved Float32 (what
    /// AVAudioEngine nodes process).
    public static func avFormat(_ format: PCMFormat, float: Bool = false) -> AVAudioFormat {
        if float {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(format.sampleRate),
                                 channels: AVAudioChannelCount(max(1, format.channels)), interleaved: false)!
        }
        return AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(format.sampleRate),
                             channels: AVAudioChannelCount(max(1, format.channels)), interleaved: true)!
    }

    // MARK: Buffers

    /// PCM16 bytes → a deinterleaved Float32 buffer at the same rate and channel count.
    public static func floatBuffer(fromPCM16 data: Data, format: PCMFormat) throws -> AVAudioPCMBuffer {
        let channels = max(1, format.channels)
        guard format.sampleRate > 0 else { throw AudioIOError.invalidAudioData("sample rate 0") }
        let samples = samples(fromPCM16: data)
        let frames = samples.count / channels
        guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat(format, float: true),
                                            frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
            throw AudioIOError.invalidAudioData("could not allocate \(frames) frames")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let destination = buffer.floatChannelData else { return buffer }
        for channel in 0..<channels {
            let out = destination[channel]
            for frame in 0..<frames { out[frame] = float(fromInt16: samples[frame * channels + channel]) }
        }
        return buffer
    }

    /// A deinterleaved Float32 buffer from mono samples.
    public static func floatBuffer(mono samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let out = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { out.update(from: base, count: samples.count) }
            }
        }
        return buffer
    }

    /// Any Float32 / Int16 / Int32 PCM buffer → interleaved little-endian PCM16 bytes (same rate and channels).
    public static func pcm16(from buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return Data() }
        var samples = [Int16](repeating: 0, count: frames * channels)
        let stride = buffer.stride
        let interleaved = buffer.format.isInterleaved
        func index(_ frame: Int, _ channel: Int) -> (Int, Int) {
            interleaved ? (0, frame * stride + channel) : (channel, frame * stride)
        }
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return Data() }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let (plane, offset) = index(frame, channel)
                    samples[frame * channels + channel] = int16(fromFloat: data[plane][offset])
                }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return Data() }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let (plane, offset) = index(frame, channel)
                    samples[frame * channels + channel] = data[plane][offset]
                }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return Data() }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let (plane, offset) = index(frame, channel)
                    samples[frame * channels + channel] = Int16(truncatingIfNeeded: data[plane][offset] >> 16)
                }
            }
        default:
            return Data()
        }
        return pcm16(fromSamples: samples)
    }

    /// Mono Float32 samples from a Float32 buffer: one chosen channel, or the average of all channels.
    public static func monoFloats(from buffer: AVAudioPCMBuffer, channel: Int? = nil) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData else { return [] }
        let stride = buffer.stride
        let interleaved = buffer.format.isInterleaved
        func sample(_ frame: Int, _ channel: Int) -> Float {
            interleaved ? data[0][frame * stride + channel] : data[channel][frame * stride]
        }
        if let channel, channel < channels {
            return (0..<frames).map { sample($0, channel) }
        }
        if channels == 1 { return (0..<frames).map { sample($0, 0) } }
        let scale = 1 / Float(channels)
        return (0..<frames).map { frame in
            var sum: Float = 0
            for channel in 0..<channels { sum += sample(frame, channel) }
            return sum * scale
        }
    }

    /// A copy of frames `from..<buffer.frameLength` of a deinterleaved Float32 buffer.
    public static func slice(_ buffer: AVAudioPCMBuffer, from start: Int) -> AVAudioPCMBuffer? {
        let total = Int(buffer.frameLength)
        let count = total - start
        guard start >= 0, count > 0, let source = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
              let destination = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel].advanced(by: start), count: count)
        }
        return out
    }

    // MARK: Resampling

    /// Frames a complete stream of `frames` input frames becomes after rate conversion (rounded to nearest).
    public static func resampledFrameCount(_ frames: Int, from sourceRate: Double, to targetRate: Double) -> Int {
        guard sourceRate > 0 else { return 0 }
        return Int((Double(frames) * targetRate / sourceRate).rounded())
    }

    /// An output buffer large enough for one conversion call (the converter can release frames it held back).
    static func outputCapacity(forInputFrames frames: Int, from sourceRate: Double, to targetRate: Double) -> AVAudioFrameCount {
        guard sourceRate > 0, targetRate > 0, frames > 0 else { return 64 }
        return AVAudioFrameCount(Int((Double(frames) * targetRate / sourceRate).rounded(.up)) + 64)
    }

    /// One-shot conversion of a whole PCM16 clip to another rate / channel count.
    public static func convert(_ data: Data, from source: PCMFormat, to target: PCMFormat) throws -> Data {
        if source == target { return data }
        var input = data
        var sourceFormat = source
        if target.channels == 1 && source.channels > 1 {
            input = downmixToMono(data, channels: source.channels)
            sourceFormat = PCMFormat(sampleRate: source.sampleRate, channels: 1)
            if sourceFormat == target { return input }
        }
        let resampler = try PCMResampler(from: avFormat(sourceFormat), to: avFormat(target))
        let buffer = try int16Buffer(fromPCM16: input, format: sourceFormat)
        var out = Data()
        if let converted = try resampler.convert(buffer) { out += pcm16(from: converted) }
        if let tail = try resampler.finish() { out += pcm16(from: tail) }
        return out
    }

    /// PCM16 bytes → an interleaved Int16 buffer (no sample conversion).
    public static func int16Buffer(fromPCM16 data: Data, format: PCMFormat) throws -> AVAudioPCMBuffer {
        let channels = max(1, format.channels)
        let frames = data.count / (2 * channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat(format), frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
            throw AudioIOError.invalidAudioData("could not allocate \(frames) frames")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if frames > 0, let destination = buffer.int16ChannelData?[0] {
            let samples = samples(fromPCM16: data)
            samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: frames * channels) }
        }
        return buffer
    }
}

/// Streaming format and sample-rate conversion on top of AVAudioConverter. Feed buffers as they arrive; the converter
/// keeps filter state between calls so chunk boundaries don't click. Call `finish()` at the end of a stream to get
/// the frames the filter still holds; the resampler is then ready for a new stream.
///
/// Not thread-safe: use one per stream, from one thread at a time.
public final class PCMResampler {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        // AVAudioFormat accepts 0 Hz or negative rates; AVAudioConverter would then convert garbage (or the capacity
        // math would divide by zero), so refuse them here.
        guard input.sampleRate.isFinite, input.sampleRate > 0, output.sampleRate.isFinite, output.sampleRate > 0,
              input.channelCount > 0, output.channelCount > 0 else {
            throw AudioIOError.converterUnavailable("\(input) → \(output)")
        }
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioIOError.converterUnavailable("\(input) → \(output)")
        }
        // Zero-latency priming: output starts aligned with input, and the tail is released by finish().
        converter.primeMethod = .normal
        if input.sampleRate != output.sampleRate {
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        self.converter = converter
        self.inputFormat = input
        self.outputFormat = output
    }

    /// Converts one buffer; returns whatever output is ready (nil if none yet).
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        try run(buffer, endOfStream: false)
    }

    /// Ends the stream: returns the frames still inside the converter and resets it.
    public func finish() throws -> AVAudioPCMBuffer? {
        defer { converter.reset() }
        return try run(nil, endOfStream: true)
    }

    public func reset() { converter.reset() }

    private func run(_ input: AVAudioPCMBuffer?, endOfStream: Bool) throws -> AVAudioPCMBuffer? {
        let inputFrames = Int(input?.frameLength ?? 0)
        let capacity = PCMConverter.outputCapacity(forInputFrames: max(inputFrames, 256),
                                                   from: inputFormat.sampleRate, to: outputFormat.sampleRate)
        var pieces: [AVAudioPCMBuffer] = []
        var supplied = input == nil || inputFrames == 0
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AudioIOError.invalidAudioData("could not allocate converter output")
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if !supplied, let input {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                throw AudioIOError.converterUnavailable(error?.localizedDescription ?? "conversion failed")
            }
            if out.frameLength > 0 { pieces.append(out) }
            // .haveData means the output buffer filled up and more is waiting.
            if status != .haveData { break }
        }
        return Self.concatenate(pieces, format: outputFormat)
    }

    static func concatenate(_ pieces: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if pieces.isEmpty { return nil }
        if pieces.count == 1 { return pieces[0] }
        let total = pieces.reduce(0) { $0 + Int($1.frameLength) }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        var offset = 0
        for piece in pieces {
            let pieceList = UnsafeMutableAudioBufferListPointer(piece.mutableAudioBufferList)
            let bytes = Int(piece.frameLength) * bytesPerFrame
            for (index, buffer) in pieceList.enumerated() where index < list.count {
                guard let source = buffer.mData, let destination = list[index].mData else { continue }
                destination.advanced(by: offset).copyMemory(from: source, byteCount: bytes)
            }
            offset += bytes
        }
        out.frameLength = AVAudioFrameCount(total)
        return out
    }
}
