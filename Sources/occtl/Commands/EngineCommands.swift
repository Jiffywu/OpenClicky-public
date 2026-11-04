import AVFAudio
import Foundation
import OpenClickyKit

enum EngineCommands {
    static let engines = OcctlCommand(name: "engines", usage: "engines [config.json]     show which adapter each slot resolves to (no network)") { args in
        if args.first == nil, !FileManager.default.fileExists(atPath: OpenClickyConfig.defaultURL.path) {
            print("No config at \(OpenClickyConfig.defaultURL.path); showing the defaults `occtl init` would write.")
        }
        let config = try loadConfig(args.first, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models),
                                    credentials: CoreCommands.store)
        let width = SlotID.allCases.map(\.rawValue.count).max() ?? 0
        for slot in SlotID.allCases {
            let label = slot.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
            let resolution: EngineResolution
            do {
                resolution = try factory.resolve(slot)
            } catch {
                print("\(label)  (empty\(slot.isOptional ? ", optional" : ""))")
                continue
            }
            let selection = resolution.selection
            var line = "\(label)  \(selection.provider)"
            if let provider = resolution.provider { line += " (\(provider.dialect.rawValue))" }
            line += " \(selection.model)"
            if let voice = selection.voice { line += " voice \(voice)" }
            if let harness = selection.harness, slot == .agent { line += " harness \(harness.rawValue)" }
            line += " -> \(resolution.adapter ?? "no adapter")"
            if resolution.sourceSlot != slot { line += "  [falls back to \(resolution.sourceSlot.rawValue)]" }
            line += "  [\(keyState(resolution.provider))]"
            print(line)
            for issue in resolution.errors { print("    error: \(issue.message)") }
        }
    }

    static let say = OcctlCommand(name: "say", usage: "say [--config c.json] [--apple] [--voice <voice>] [--out f.wav] <text>  speak one line through the voice slot") { args in
        var useApple = false
        var voice: String?
        var configPath: String?
        var outPath: String?
        var words: [String] = []
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--apple": useApple = true
            case "--voice":
                index += 1
                guard index < args.count else { fail("--voice needs a value") }
                voice = args[index]
            case "--config":
                index += 1
                guard index < args.count else { fail("--config needs a value") }
                configPath = args[index]
            case "--out":
                index += 1
                guard index < args.count else { fail("--out needs a value") }
                outPath = args[index]
            default: words.append(args[index])
            }
            index += 1
        }
        let text = words.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("Usage: occtl say [--config c.json] [--apple] [--voice <voice>] [--out f.wav] <text>")
        }

        var config = try loadConfig(configPath, fallback: .heyClickyLike)
        if useApple {
            // The on-device macOS voice: no key, no network.
            let providerID = config.providers.first { $0.dialect == .appleSpeechSynthesis }?.id ?? "apple-voices"
            if config.provider(providerID) == nil {
                config.providers.append(ProviderConfig(id: providerID, dialect: .appleSpeechSynthesis))
            }
            config.slots[.voice] = SlotSelection(provider: providerID, model: "system", voice: voice)
        } else if let voice {
            config.slots[.voice]?.voice = voice
        }

        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models),
                                    credentials: CoreCommands.store)
        let speech = try factory.speechOutput()
        let adapter = try factory.resolve(.voice).adapter ?? "?"
        let started = Date()
        var firstAudio: TimeInterval?
        var chunks = 0
        if let outPath {
            // Write a WAV instead of playing, for quiet checks.
            var pcm = Data()
            var pcmFormat: PCMFormat?
            for try await event in speech.speak(text, voice: nil, instructions: nil) {
                if case .audio(let data, let format) = event {
                    if firstAudio == nil { firstAudio = Date().timeIntervalSince(started) }
                    pcm.append(data)
                    pcmFormat = format
                    chunks += 1
                }
            }
            guard let format = pcmFormat else { fail("No audio came back from \(adapter).") }
            try wav(pcm, format: format).write(to: URL(fileURLWithPath: outPath))
            let seconds = Double(pcm.count) / Double(format.bytesPerSecond)
            print("Wrote \(String(format: "%.1f", seconds)) s (\(format.sampleRate) Hz) in \(chunks) chunks through \(adapter) to \(outPath); first audio after \(String(format: "%.2f", firstAudio ?? 0)) s.")
            return
        }
        let player = PCMPlayer()
        for try await event in speech.speak(text, voice: nil, instructions: nil) {
            switch event {
            case .audio(let data, let format):
                if firstAudio == nil { firstAudio = Date().timeIntervalSince(started) }
                try player.enqueue(data, format: format)
                chunks += 1
            case .lineFinished:
                break
            }
        }
        await player.finish()
        print("Spoke \(String(format: "%.1f", player.seconds)) s of audio in \(chunks) chunks through \(adapter); first audio after \(String(format: "%.2f", firstAudio ?? 0)) s.")
    }

    /// A 16-bit PCM WAV file.
    static func wav(_ pcm: Data, format: PCMFormat) -> Data {
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(format.channels)); le(UInt32(format.sampleRate))
        le(UInt32(format.bytesPerSecond)); le(UInt16(format.channels * 2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// The config at `path`, or the default one. With a fallback, a missing default config uses it instead.
    static func loadConfig(_ path: String?, fallback: OpenClickyConfig? = nil) throws -> OpenClickyConfig {
        let url = path.map { URL(fileURLWithPath: $0) } ?? OpenClickyConfig.defaultURL
        if path == nil, let fallback, !FileManager.default.fileExists(atPath: url.path) { return fallback }
        return try OpenClickyConfig.load(from: url)
    }

    /// Whether the provider's credential is stored, without printing it.
    static func keyState(_ provider: ProviderConfig?) -> String {
        guard let provider else { return "no provider" }
        guard !provider.dialect.isOnDevice, let name = provider.credential else { return "no key needed" }
        do {
            return try CoreCommands.store.secret(named: name)?.isEmpty == false ? "key \(name): stored" : "key \(name): missing"
        } catch {
            return "key \(name): unreadable"
        }
    }
}

/// Plays 16-bit PCM chunks through the default output device as they arrive, the minimum `occtl say` needs.
final class PCMPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pending = DispatchGroup()
    private var format: PCMFormat?
    private var outputFormat: AVAudioFormat?
    private(set) var seconds = 0.0

    struct FormatError: Error, CustomStringConvertible {
        var description: String
    }

    func enqueue(_ data: Data, format: PCMFormat) throws {
        let output = try prepare(for: format)
        let channels = format.channels
        let frames = data.count / (channels * 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)),
              let channelData = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: (frame * channels + channel) * 2, as: Int16.self))
                    channelData[channel][frame] = Float(sample) / 32_768
                }
            }
        }
        seconds += Double(frames) / Double(format.sampleRate)
        pending.enter()
        let pending = pending
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in pending.leave() }
    }

    /// Waits for everything scheduled to be heard, then stops the engine.
    func finish() async {
        let pending = pending
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            pending.notify(queue: .global()) { done.resume() }
        }
        node.stop()
        engine.stop()
    }

    /// Starts the engine at the first chunk's format. Every chunk of one line shares it.
    private func prepare(for format: PCMFormat) throws -> AVAudioFormat {
        if let current = self.format, let outputFormat {
            guard current == format else {
                throw FormatError(description: "The audio format changed mid-line (\(current) to \(format)).")
            }
            return outputFormat
        }
        guard let output = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate),
                                         channels: AVAudioChannelCount(format.channels)) else {
            throw FormatError(description: "Unsupported audio format \(format).")
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: output)
        try engine.start()
        node.play()
        self.format = format
        self.outputFormat = output
        return output
    }
}
