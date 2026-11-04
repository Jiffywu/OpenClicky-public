import AVFAudio
import Foundation
import OpenClickyKit

/// `occtl transcribe`: plays an audio file into the stt slot as if it were a push-to-talk press, so a speech-to-text
/// adapter can be checked end to end without a microphone (or a microphone permission).
enum TranscribeCommands {
    static let transcribe = OcctlCommand(
        name: "transcribe",
        usage: "transcribe [--config c.json] [--language xx-XX] [--keyword k]… [--fast] [--save-pcm f.wav] <audio file>  stream a file through the stt slot"
    ) { args in
        var configPath: String?
        var language: String?
        var keywords: [String] = []
        var fast = false
        var savePath: String?
        var files: [String] = []
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--config": configPath = value("--config")
            case "--language": language = value("--language")
            case "--keyword": keywords.append(value("--keyword"))
            case "--fast": fast = true
            case "--save-pcm": savePath = value("--save-pcm")
            default: files.append(args[index])
            }
            index += 1
        }
        guard files.count == 1 else {
            fail("Usage: occtl transcribe [--config c.json] [--language xx-XX] [--keyword k]… [--fast] [--save-pcm f.wav] <audio file>")
        }

        let config = try EngineCommands.loadConfig(configPath, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models),
                                    credentials: CoreCommands.store)
        let adapter = (try? factory.resolve(.stt).adapter) ?? nil
        // Decode before building the engine, so --save-pcm works (and shows what would be sent) without a key.
        let format = try sttFormat(factory)
        let pcm = try decode(URL(fileURLWithPath: files[0]), to: format)
        let seconds = Double(pcm.count) / Double(format.bytesPerSecond)
        if let savePath {
            try EngineCommands.wav(pcm, format: format).write(to: URL(fileURLWithPath: savePath))
            print("Saved \(String(format: "%.2f", seconds)) s of \(format.sampleRate) Hz mono PCM16 to \(savePath).")
        }

        let client = try factory.speechToText()
        let started = ContinuousClock.now
        let session = try await client.startSession(language: language, keywords: keywords)
        let reader = Task { () throws -> (String, Duration?, [TranscriptEvent]) in
            var finals = ""
            var firstText: Duration?
            var events: [TranscriptEvent] = []
            for try await event in session.events {
                events.append(event)
                switch event {
                case .interim(let text):
                    if firstText == nil, !text.isEmpty { firstText = ContinuousClock.now - started }
                    FileHandle.standardError.write(Data("\r\u{1B}[K… \(finals)\(text)".utf8))
                case .final(let text):
                    if firstText == nil, !text.isEmpty { firstText = ContinuousClock.now - started }
                    finals += text
                    FileHandle.standardError.write(Data("\r\u{1B}[K… \(finals)".utf8))
                case .speechStarted, .utteranceEnd:
                    break
                }
            }
            FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
            return (finals, firstText, events)
        }

        // About 100 ms per send, in real time unless --fast, like a held talk key.
        let chunkBytes = max(format.bytesPerSecond / 10 / 2 * 2, 2)
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            await session.send(pcm.subdata(in: offset..<end))
            offset = end
            if !fast { try await Task.sleep(for: .milliseconds(100)) }
        }
        let released = ContinuousClock.now
        await session.finish()
        let (transcript, firstText, events) = try await reader.value
        let afterRelease = ContinuousClock.now - released
        print("Transcript: \(transcript.isEmpty ? "(nothing heard)" : transcript)")
        let interims = events.filter { if case .interim = $0 { true } else { false } }.count
        let finals = events.filter { if case .final = $0 { true } else { false } }.count
        print("\(String(format: "%.2f", seconds)) s of audio through \(adapter ?? "the stt slot"): \(interims) interim and \(finals) final events; "
            + "first text after \(firstText.map(describe) ?? "-"), final \(describe(afterRelease)) after release.")
    }

    /// The format the stt slot's adapter wants, without building it (no credential needed).
    static func sttFormat(_ factory: EngineFactory) throws -> PCMFormat {
        do {
            return try factory.speechToText().inputFormat
        } catch EngineFactoryError.missingCredential, EngineFactoryError.unreadableCredential {
            return .speech16k  // every network stt adapter so far takes 16 kHz mono
        }
    }

    /// Any file AVAudioFile can read, converted to 16-bit little-endian PCM in `format`.
    static func decode(_ url: URL, to format: PCMFormat) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(format.sampleRate),
                                         channels: AVAudioChannelCount(format.channels), interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: output) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(file.length, 1)))!
        try file.read(into: input)
        let ratio = output.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)!
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw conversionError ?? CocoaError(.fileReadCorruptFile) }
        let bytes = Int(converted.frameLength) * format.channels * 2
        guard let samples = converted.int16ChannelData else { throw CocoaError(.fileReadCorruptFile) }
        return Data(bytes: samples[0], count: bytes)
    }

    static func describe(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f s", seconds)
    }
}
