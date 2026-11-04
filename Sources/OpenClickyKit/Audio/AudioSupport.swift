import Foundation

/// Errors from OpenClicky's audio layer.
public enum AudioIOError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The user (or an MDM profile) refused microphone access for this app or terminal.
    case microphonePermissionDenied
    /// Nobody has been asked yet; call `MicrophoneCapture.requestAccess()` first.
    case microphonePermissionUndetermined
    case noInputDevice
    /// The input reported a format AVAudioEngine can't capture from (usually 0 Hz or 0 channels: no device or no access).
    case inputFormatInvalid(sampleRate: Double, channels: Int)
    case voiceProcessingUnavailable(String)
    case engineStartFailed(String)
    case converterUnavailable(String)
    case invalidAudioData(String)
    case unsupportedWAV(String)

    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is denied. Allow it in System Settings > Privacy & Security > Microphone."
        case .microphonePermissionUndetermined: "Microphone access hasn't been requested yet."
        case .noInputDevice: "No microphone is connected."
        case .inputFormatInvalid(let rate, let channels):
            "The microphone reported an unusable format (\(Int(rate)) Hz, \(channels) channel(s))."
        case .voiceProcessingUnavailable(let message): "Echo cancellation could not be enabled: \(message)"
        case .engineStartFailed(let message): "The audio engine failed to start: \(message)"
        case .converterUnavailable(let message): "No audio converter for \(message)"
        case .invalidAudioData(let message): "Invalid audio data: \(message)"
        case .unsupportedWAV(let message): "Unsupported WAV file: \(message)"
        }
    }
}

/// A serial queue that knows when it is the current queue, so the audio classes can offer synchronous public
/// methods that are also safe to call from their own callbacks. Every piece of AVAudioEngine state in this module is
/// touched only on one of these.
public final class AudioWorkQueue: @unchecked Sendable {
    public let queue: DispatchQueue
    private let key = DispatchSpecificKey<UInt8>()

    public init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
        queue.setSpecific(key: key, value: 1)
    }

    public var isCurrent: Bool { DispatchQueue.getSpecific(key: key) != nil }

    /// Runs `work` on the queue and waits; runs it inline when already on the queue.
    public func sync<T>(_ work: () throws -> T) rethrows -> T {
        if isCurrent { return try work() }
        return try queue.sync(execute: work)
    }

    public func async(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    public func asyncAfter(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Fans one sequence of values out to any number of `AsyncStream` subscribers.
final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    func stream(bufferingNewest limit: Int = 256) -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(limit))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
        }
        lock.withLock { continuations[id] = continuation }
        return stream
    }

    func yield(_ element: Element) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(element) }
    }

    func finish() {
        let targets = lock.withLock {
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in targets { continuation.finish() }
    }
}

/// A value shared between an audio queue and readers on other threads (the UI reading the mic level).
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

/// Monotonic seconds (unaffected by wall-clock changes), used for health windows and holds.
func audioUptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
