@preconcurrency import AVFoundation
import OpenClickyKit

/// The default microphone for dictation: AVAudioEngine's input, converted to 16-bit mono PCM at the speech
/// session's rate. The shared capture engine from the audio subsystem can replace it through `DictationAudioInput`.
/// Opening it asks for Microphone permission the first time.
final class DictationMicrophone: DictationAudioInput, @unchecked Sendable {
    enum MicrophoneError: Error, CustomStringConvertible {
        case noInputDevice
        case unsupportedFormat
        case accessDenied

        var description: String {
            switch self {
            case .noInputDevice: "No microphone is available."
            case .unsupportedFormat: "The microphone's audio format can't be converted for speech recognition."
            case .accessDenied: "Microphone access is off for OpenClicky. Turn it on in System Settings → Privacy & Security → Microphone."
            }
        }
    }

    /// Guards `engine` and `continuation`. The audio tap never takes it: stopping the engine can wait for a tap
    /// callback in flight, so the engine is always stopped outside this lock.
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<Data>.Continuation?
    /// The tap's level, behind its own lock.
    private let levelLock = NSLock()
    private var currentLevel: Float = 0
    /// The input to open (Settings → Microphone); nil follows the system default. Read under `lock`.
    private var chosenUID: String?

    init(deviceUID: String? = nil) { chosenUID = deviceUID }

    var deviceUID: String? {
        get { lock.withLock { chosenUID } }
        set { lock.withLock { chosenUID = newValue } }
    }

    func start(format: PCMFormat) async throws -> AsyncStream<Data> {
        // A denied microphone records silence rather than failing, which would read as "didn't catch that".
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw MicrophoneError.accessDenied
        default: break
        }
        await stop()
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        try lock.withLock {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            if let uid = chosenUID, let device = AudioDevices.device(uid: uid), device.inputChannels > 0, let unit = input.audioUnit {
                // Pin the input to the chosen device before reading its format; if it fails the system default is used.
                var id = device.id
                _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                         &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw MicrophoneError.noInputDevice }
            guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(format.sampleRate),
                                             channels: AVAudioChannelCount(format.channels), interleaved: true),
                  let converter = AVAudioConverter(from: inputFormat, to: target) else { throw MicrophoneError.unsupportedFormat }
            let tap = TapConverter(converter: converter, target: target, continuation: continuation) { [weak self] level in
                self?.setLevel(level)
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in tap.process(buffer) }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
            self.engine = engine
            self.continuation = continuation
        }
        return stream
    }

    func stop() async {
        let (engine, continuation) = lock.withLock {
            defer {
                self.engine = nil
                self.continuation = nil
            }
            return (self.engine, self.continuation)
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        continuation?.finish()
        setLevel(0)
    }

    func level() -> Float { levelLock.withLock { currentLevel } }

    private func setLevel(_ level: Float) { levelLock.withLock { currentLevel = level } }
}

/// Runs on the audio thread: measures the level and converts each buffer to the target format.
private final class TapConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    let continuation: AsyncStream<Data>.Continuation
    let reportLevel: @Sendable (Float) -> Void

    init(converter: AVAudioConverter, target: AVAudioFormat, continuation: AsyncStream<Data>.Continuation,
         reportLevel: @escaping @Sendable (Float) -> Void) {
        self.converter = converter
        self.target = target
        self.continuation = continuation
        self.reportLevel = reportLevel
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            // Speech sits around 0.01–0.2 RMS; spread that over the bars.
            reportLevel(min(1, rms * 8))
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let bytes = Int(output.frameLength) * Int(target.channelCount) * MemoryLayout<Int16>.size
        continuation.yield(Data(bytes: samples, count: bytes))
    }
}
