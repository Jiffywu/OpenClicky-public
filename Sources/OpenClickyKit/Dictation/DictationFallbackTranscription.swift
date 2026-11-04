import Foundation

/// The second chance for a dictation whose streaming session failed or never delivered its final words: the whole
/// press, kept while the microphone was open, goes through another speech-to-text client in one pass (a batch
/// transcription model, or the on-device recognizer).
public enum DictationFallbackTranscription {
    /// Audio shorter than this (seconds) isn't worth a second pass.
    public static let minimumSeconds = 0.25
    /// The longest press kept for the fallback (seconds).
    public static let maximumSeconds = 600.0

    /// Transcribes recorded PCM with `client`, converting it to the client's format first. Returns nil when the
    /// fallback fails, times out or hears nothing.
    public static func transcribe(_ pcm: Data, format: PCMFormat, with client: any SpeechToTextClient, language: String?,
                                  keyterms: [String], timeout: Double) async -> String? {
        let target = client.inputFormat
        let audio = PCM16Conversion.convert(pcm, from: format, to: target)
        guard Double(audio.count) >= Double(target.bytesPerSecond) * minimumSeconds else { return nil }
        let text: String? = try? await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = try await client.startSession(language: language, keywords: keyterms)
                return try await withTaskCancellationHandler {
                    async let heard = collect(session.events)
                    // Tenth-of-a-second slices, the size live capture delivers.
                    let slice = max(2, (target.bytesPerSecond / 10) & ~1)
                    var offset = 0
                    while offset < audio.count, !Task.isCancelled {
                        let end = min(offset + slice, audio.count)
                        await session.send(audio.subdata(in: offset..<end))
                        offset = end
                    }
                    await session.finish()
                    return try await heard
                } onCancel: {
                    Task { await session.cancel() }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let words = text else { return nil }
        let joined = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// The finals concatenated as they are, plus any interim not yet settled (the stt contract: finals carry their own
    /// leading spaces, so none is added).
    static func collect(_ events: AsyncThrowingStream<TranscriptEvent, Error>) async throws -> String {
        var finals: [String] = []
        var interim = ""
        for try await event in events {
            switch event {
            case .final(let text):
                finals.append(text)
                interim = ""
            case .interim(let text): interim = text
            case .speechStarted, .utteranceEnd: break
            }
        }
        return finals.joined() + interim
    }
}

/// The microphone audio of one press, kept for the fallback. Written from the capture task, read once the press ends.
final class PressAudioRecording: @unchecked Sendable {
    let format: PCMFormat
    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()

    init(format: PCMFormat, maximumSeconds: Double = DictationFallbackTranscription.maximumSeconds) {
        self.format = format
        limit = Int(Double(format.bytesPerSecond) * maximumSeconds)
    }

    func append(_ chunk: Data) {
        lock.withLock {
            let room = limit - buffer.count
            guard room > 0 else { return }
            buffer.append(chunk.count <= room ? chunk : chunk.prefix(room))
        }
    }

    var data: Data { lock.withLock { buffer } }
}

/// Converts 16-bit little-endian PCM between sample rates and channel counts. Channels are averaged down to mono
/// and duplicated back up; the rate changes by linear interpolation, which is enough for speech recognition.
public enum PCM16Conversion {
    public static func convert(_ data: Data, from source: PCMFormat, to target: PCMFormat) -> Data {
        guard source != target, source.channels > 0, target.channels > 0, source.sampleRate > 0, target.sampleRate > 0 else {
            return data
        }
        let mono = monoSamples(data, channels: source.channels)
        guard !mono.isEmpty else { return Data() }
        let resampled: [Int16]
        if source.sampleRate == target.sampleRate {
            resampled = mono
        } else {
            let step = Double(source.sampleRate) / Double(target.sampleRate)
            let count = Int(Double(mono.count) / step)
            resampled = (0..<count).map { index in
                let position = Double(index) * step
                let lower = min(Int(position), mono.count - 1)
                let upper = min(lower + 1, mono.count - 1)
                let fraction = position - Double(lower)
                let value = Double(mono[lower]) + (Double(mono[upper]) - Double(mono[lower])) * fraction
                return Int16(clamping: Int(value.rounded()))
            }
        }
        var output = Data(capacity: resampled.count * target.channels * 2)
        for sample in resampled {
            let bytes = [UInt8(truncatingIfNeeded: UInt16(bitPattern: sample)), UInt8(truncatingIfNeeded: UInt16(bitPattern: sample) >> 8)]
            for _ in 0..<target.channels { output.append(contentsOf: bytes) }
        }
        return output
    }

    static func monoSamples(_ data: Data, channels: Int) -> [Int16] {
        let frameBytes = 2 * channels
        let frames = data.count / frameBytes
        var result = [Int16](repeating: 0, count: frames)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in 0..<frames {
                var sum = 0
                for channel in 0..<channels {
                    let offset = frame * frameBytes + channel * 2
                    let value = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
                    sum += Int(Int16(bitPattern: value))
                }
                result[frame] = Int16(clamping: sum / channels)
            }
        }
        return result
    }
}
