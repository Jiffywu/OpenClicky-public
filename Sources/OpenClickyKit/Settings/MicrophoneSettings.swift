import Foundation

/// Settings → Microphone: which input OpenClicky listens on. `~/Library/Application Support/OpenClicky/microphone.json`.
/// The device is stored by its CoreAudio UID, which survives reboots and reconnects.
public struct MicrophoneSettings: Codable, Sendable, Equatable {
    /// nil follows the system's default input.
    public var deviceUID: String?

    public init(deviceUID: String? = nil) {
        self.deviceUID = deviceUID
    }

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("microphone.json")
    }

    public static func load(from url: URL = defaultURL) -> MicrophoneSettings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MicrophoneSettings.self, from: $0) } ?? MicrophoneSettings()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The input the picker shows as in use, given the saved choice and the inputs connected now.
public struct MicrophoneChoice: Sendable, Equatable {
    /// The device capture will open (nil when the Mac has no input at all).
    public var effective: AudioDeviceInfo?
    /// True when the saved device is connected and used.
    public var usesSavedDevice: Bool
    /// Why the saved choice isn't in use, or a hint about the device.
    public var note: String?

    public static func resolve(savedUID: String?, inputs: [AudioDeviceInfo]) -> MicrophoneChoice {
        let systemDefault = inputs.first(where: \.isDefaultInput) ?? inputs.first
        guard let savedUID else {
            return MicrophoneChoice(effective: systemDefault, usesSavedDevice: false, note: hint(for: systemDefault))
        }
        if let saved = inputs.first(where: { $0.uid == savedUID }) {
            return MicrophoneChoice(effective: saved, usesSavedDevice: true, note: hint(for: saved))
        }
        let fallback = systemDefault.map { "the system default (\($0.name))" } ?? "the system default"
        return MicrophoneChoice(effective: systemDefault, usesSavedDevice: false,
                                note: "The microphone you picked isn't connected; OpenClicky uses \(fallback) until it is.")
    }

    static func hint(for device: AudioDeviceInfo?) -> String? {
        guard let device else { return "No microphone is connected." }
        if device.transport.isBluetooth {
            return "\(device.name) is Bluetooth: opening its microphone switches the headset to call quality, so OpenClicky keeps it open for a few seconds between questions."
        }
        return nil
    }
}

/// "Test microphone": a few seconds of input levels and a plain verdict.
public struct MicrophoneTestAnalyzer: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// Speech-level sound arrived.
        case heard
        /// Only faint sound: the mic works but is far away, muted in hardware or turned down.
        case quiet
        /// Digital silence: a dead route, a muted aggregate device, or no microphone permission.
        case silent
        /// Nothing arrived at all.
        case noAudio
    }

    /// RMS loudness (dBFS) a voice at normal distance comfortably exceeds.
    public var speechThresholdDB: Float = -38
    /// Peak at or below which a chunk is digital silence (two 16-bit LSBs, as `MicHealthMonitor` uses).
    public var silenceThreshold: Float = 2.0 / 32768

    public private(set) var chunks = 0
    public private(set) var loudestDB: Float = AudioLevel.floorDB
    public private(set) var peak: Float = 0

    public init() {}

    public mutating func add(_ level: AudioLevel) {
        chunks += 1
        loudestDB = max(loudestDB, level.rmsDB)
        peak = max(peak, level.peak)
    }

    public var verdict: Verdict {
        if chunks == 0 { return .noAudio }
        if peak <= silenceThreshold { return .silent }
        return loudestDB >= speechThresholdDB ? .heard : .quiet
    }

    /// What the page says after the test.
    public func message(deviceName: String?) -> String {
        let device = deviceName ?? "the microphone"
        switch verdict {
        case .heard: return "Heard you clearly on \(device)."
        case .quiet: return String(format: "Only faint sound reached %@ (loudest %.0f dB). Move closer, check its volume in System Settings → Sound, or pick another microphone.", device, loudestDB)
        case .silent: return "\(device) sent only silence. Check that it isn't muted, and that OpenClicky has Microphone access in System Settings → Privacy & Security."
        case .noAudio: return "No audio arrived from \(device). Try another microphone, or check Microphone access in System Settings → Privacy & Security."
        }
    }
}

/// Where a microphone test reads levels from. The app uses `MicrophoneCapture`; tests use a stream of fixed levels.
public protocol MicrophoneTestSource: Sendable {
    /// Opens the input and delivers one level per chunk until `stop()`.
    func start() throws -> AsyncStream<AudioLevel>
    func stop()
}

public enum MicrophoneTest {
    public struct Result: Sendable, Equatable {
        public var analyzer: MicrophoneTestAnalyzer
        public var failure: String?

        public var verdict: MicrophoneTestAnalyzer.Verdict { analyzer.verdict }
    }

    /// Listens for `duration` seconds (or until the stream ends) and reports what arrived. `onLevel` gets each level,
    /// for a live meter.
    public static func run(source: any MicrophoneTestSource, duration: TimeInterval = 3,
                           onLevel: @escaping @Sendable (AudioLevel) -> Void = { _ in }) async -> Result {
        let levels: AsyncStream<AudioLevel>
        do {
            levels = try source.start()
        } catch {
            return Result(analyzer: MicrophoneTestAnalyzer(), failure: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        let collector = Task { () -> MicrophoneTestAnalyzer in
            var analyzer = MicrophoneTestAnalyzer()
            for await level in levels {
                analyzer.add(level)
                onLevel(level)
                if Task.isCancelled { break }
            }
            return analyzer
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, duration) * 1_000_000_000))
            source.stop()
        }
        let analyzer = await collector.value
        timer.cancel()
        source.stop()
        return Result(analyzer: analyzer, failure: nil)
    }
}

/// Levels from `MicrophoneCapture` for a microphone test on one device (needs Microphone permission).
public final class CaptureMicrophoneTestSource: MicrophoneTestSource, @unchecked Sendable {
    private let capture: MicrophoneCapture

    public init(deviceUID: String?) {
        capture = MicrophoneCapture(options: MicrophoneCapture.Options(deviceUID: deviceUID, bluetoothHold: 0))
    }

    public var deviceName: String? { capture.device?.name }

    public func start() throws -> AsyncStream<AudioLevel> {
        let chunks = try capture.start()
        return AsyncStream { continuation in
            let pump = Task {
                for await chunk in chunks { continuation.yield(chunk.level) }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public func stop() { capture.close() }
}
