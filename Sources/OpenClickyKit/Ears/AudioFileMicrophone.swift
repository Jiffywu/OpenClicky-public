import Foundation

/// A microphone that "hears" a recording: while pressed it delivers the recording's PCM in real time, in chunks the
/// size live capture delivers, then silence until the keys are let go. With it the voice loop runs a real stt adapter
/// (through `VoiceEars`) without a microphone or its permission (`occtl turn --in question.wav`, tests).
@MainActor
public final class AudioFileMicrophone: TurnMicrophone {
    public let pcm: Data
    public let format: PCMFormat
    public let chunkDuration: TimeInterval
    /// False delivers the whole recording at once (tests).
    public let realTime: Bool
    public private(set) var starts = 0
    private var continuation: AsyncStream<Data>.Continuation?
    private var ticker: Task<Void, Never>?

    /// - Parameters:
    ///   - pcm: PCM16 in `format`.
    public init(pcm: Data, format: PCMFormat, chunkDuration: TimeInterval = 0.04, realTime: Bool = true) {
        self.pcm = pcm
        self.format = format
        self.chunkDuration = chunkDuration
        self.realTime = realTime
    }

    /// Seconds of speech in the recording.
    public var duration: TimeInterval { Double(pcm.count) / Double(max(1, format.bytesPerSecond)) }

    public func start(format wanted: PCMFormat) throws -> AsyncStream<Data> {
        stop()
        starts += 1
        let audio = PCM16Conversion.convert(pcm, from: format, to: wanted)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        let chunkBytes = max(2, Int(Double(wanted.bytesPerSecond) * chunkDuration) & ~1)
        let interval = chunkDuration
        var offset = 0
        if !realTime {
            // All of it now, so a busy main actor can't shorten the press.
            while offset < audio.count {
                let end = min(offset + chunkBytes, audio.count)
                continuation.yield(audio.subdata(in: offset..<end))
                offset = end
            }
        }
        // Off the main actor, so the pace holds while the app draws.
        let delivered = offset
        ticker = Task.detached {
            var position = delivered
            while position < audio.count, !Task.isCancelled {
                let end = min(position + chunkBytes, audio.count)
                continuation.yield(audio.subdata(in: position..<end))
                position = end
                try? await Task.sleep(for: .seconds(interval))
            }
            // The keys are still held after the words: a quiet room.
            while !Task.isCancelled {
                continuation.yield(Data(count: chunkBytes))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        return stream
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        continuation?.finish()
        continuation = nil
    }

    public var level: Float { continuation == nil ? 0 : 0.3 }
}
