import AVFAudio
import Foundation

// Audio plumbing for the Apple Speech adapter: OpenClicky hands the stt slot little-endian PCM16 `Data` (see
// `PCMFormat`); the Speech framework wants `AVAudioPCMBuffer`s, and `SpeechAnalyzer` additionally wants them in
// exactly the format `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` names, because "the analyzer does
// not perform audio conversion" (https://developer.apple.com/documentation/speech/analyzerinput).

/// Turns arbitrary slices of PCM16 bytes into whole-frame `AVAudioPCMBuffer`s. Capture can hand us chunks that end
/// mid-sample (an odd byte) or mid-frame (stereo); the leftover bytes are carried into the next chunk.
struct PCM16BufferAssembler {
    let pcmFormat: PCMFormat
    /// Int16, interleaved, at the session's sample rate and channel count; the layout of the incoming bytes.
    let audioFormat: AVAudioFormat
    private var carry = Data()

    init?(format: PCMFormat) {
        guard format.sampleRate > 0, format.channels > 0,
              let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(format.sampleRate),
                                              channels: AVAudioChannelCount(format.channels), interleaved: true)
        else { return nil }
        self.pcmFormat = format
        self.audioFormat = audioFormat
    }

    private var bytesPerFrame: Int { 2 * pcmFormat.channels }

    /// Bytes held back because they don't yet make a whole frame.
    var pendingByteCount: Int { carry.count }

    /// Appends bytes and returns a buffer holding every whole frame now available, or nil if there is none yet.
    mutating func append(_ data: Data) -> AVAudioPCMBuffer? {
        carry.append(data)
        let frames = carry.count / bytesPerFrame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.int16ChannelData?[0]
        else { return nil }
        let usedBytes = frames * bytesPerFrame
        carry.withUnsafeBytes { raw in
            // Interleaved Int16: channel 0's pointer addresses all samples in order. Decode explicitly as
            // little-endian rather than memcpy, so the result never depends on host byte order or alignment.
            for sample in 0..<(usedBytes / 2) {
                let lo = UInt16(raw[sample * 2])
                let hi = UInt16(raw[sample * 2 + 1])
                channel[sample] = Int16(bitPattern: lo | (hi << 8))
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        carry = Data(carry.dropFirst(usedBytes))
        return buffer
    }

    /// Drops a trailing partial frame (it cannot be played or recognised) and resets.
    mutating func reset() { carry.removeAll() }
}

/// Converts buffers from the capture layout to whatever a recognizer asks for, keeping resampler state between
/// calls so a stream split into chunks converts the same as one long buffer. Not thread-safe; callers serialise.
final class PCMBufferConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
    }

    private var ratio: Double { outputFormat.sampleRate / inputFormat.sampleRate }

    /// Converts one input buffer. May return several buffers, or none while a resampler is still priming.
    func convert(_ input: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        var supplied = false
        return try drain(expectedFrames: input.frameLength) { status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
    }

    /// Flushes whatever the converter is still holding (resampler tail) at the end of the stream.
    func flush() throws -> [AVAudioPCMBuffer] {
        try drain(expectedFrames: 0) { status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func drain(expectedFrames: AVAudioFrameCount,
                       input: (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) throws -> [AVAudioPCMBuffer] {
        var outputs: [AVAudioPCMBuffer] = []
        // Generous capacity so one pass normally consumes the whole input; loop in case it doesn't.
        let capacity = AVAudioFrameCount((Double(expectedFrames) * ratio).rounded(.up)) + 1024
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw AppleSpeechAudioError.cannotAllocateBuffer
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in input(outStatus) }
            if status == .error {
                throw error ?? AppleSpeechAudioError.conversionFailed
            }
            if output.frameLength > 0 { outputs.append(output) }
            // `.haveData`: the output filled up and more may be waiting. Anything else means input ran dry or ended.
            guard status == .haveData else { break }
        }
        return outputs
    }
}

enum AppleSpeechAudioError: Error, CustomStringConvertible {
    case cannotAllocateBuffer
    case conversionFailed
    case unsupportedConversion(from: String, to: String)

    var description: String {
        switch self {
        case .cannotAllocateBuffer: "could not allocate an audio buffer"
        case .conversionFailed: "audio format conversion failed"
        case .unsupportedConversion(let from, let to): "cannot convert audio from \(from) to \(to)"
        }
    }
}
