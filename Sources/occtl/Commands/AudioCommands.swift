import Foundation
import OpenClickyKit

/// `occtl audio …`: try the audio layer from a terminal: list devices, play OpenClicky's cues, record the mic to a WAV
/// file and play audio files through the speech player, printing the playback timeline as it happens.
enum AudioCommands {
    static let usage = """
        Usage:
          occtl audio devices
          occtl audio tone [start|stop|error|done|all] [--volume 0.7] [--speed 1] [--render out.wav]
          occtl audio record <seconds> <out.wav> [--rate 16000] [--device <uid>] [--echo-cancel] [--play <file>] [--no-prompt]
          occtl audio play <file> [--speed 1] [--chunk-ms 100]
        """

    static let audio = OcctlCommand(name: "audio", usage: "audio <devices|tone|record|play> …  try mic capture, cues and the speech player") { args in
        guard let sub = args.first else { fail(usage) }
        let parsed = Arguments(Array(args.dropFirst()))
        switch sub {
        case "devices": devices()
        case "tone": try await tone(parsed)
        case "record": try await record(parsed)
        case "play": try await play(parsed)
        default: fail(usage)
        }
    }

    // MARK: devices

    static func devices() {
        print("Microphone access for this terminal: \(MicrophoneCapture.authorization)")
        for (title, list) in [("Inputs", AudioDevices.inputs()), ("Outputs", AudioDevices.outputs())] {
            print("\(title):")
            for device in list {
                let isDefault = title == "Inputs" ? device.isDefaultInput : device.isDefaultOutput
                let channels = title == "Inputs" ? device.inputChannels : device.outputChannels
                print("  \(isDefault ? "*" : " ") \(device.name)  [\(device.transport), \(channels) ch, \(Int(device.nominalSampleRate)) Hz]  uid=\(device.uid)")
            }
        }
    }

    // MARK: tone

    static func tone(_ args: Arguments) async throws {
        let cues = cueList(args.positional.first ?? "all")
        let volume = args.float("--volume", default: 0.7)
        let speed = args.float("--speed", default: 1)
        if let path = args.value("--render") {
            try renderCues(cues, volume: volume, speed: speed, to: URL(fileURLWithPath: path))
            return
        }
        let cuePlayer = CuePlayer(volume: volume)
        cuePlayer.player.rate = speed
        let clock = Stopwatch()
        cuePlayer.player.onEvent = { event in print(clock.stamp(describe(event))) }
        print("Playing \(cues.count) cue(s) through SpeechPlayer at \(cuePlayer.player.sampleRate) Hz, volume \(volume), speed \(speed)x.")
        for (position, cue) in cues.enumerated() {
            if position > 0 { try await Task.sleep(for: .milliseconds(350)) }
            print(clock.stamp("cue \(cue.rawValue): \(String(format: "%.3f", cue.duration)) s of audio"))
            cuePlayer.play(cue)
            await cuePlayer.player.waitUntilDrained()
        }
        // Let the device finish the last cue's tail before the process exits.
        try await Task.sleep(for: .milliseconds(150))
    }

    /// Renders cues through the real playback chain in offline mode and writes them to a WAV file.
    static func renderCues(_ cues: [UICue], volume: Float, speed: Float, to url: URL) throws {
        let host = AudioEngineHost(offlineSampleRate: 24_000)
        let player = SpeechPlayer(sampleRate: 24_000, host: host)
        player.rate = speed
        let cuePlayer = CuePlayer(player: player, volume: volume, coldLeadIn: 0, coldLeadInBluetooth: 0)
        let rendered = FrameCounter()
        let stamp = { @Sendable (text: String) in print(String(format: "%7.3fs  ", Double(rendered.value) / 24_000) + text) }
        player.onEvent = { event in stamp(describe(event)) }
        var output: [Float] = []
        func pull(_ frames: Int) throws {
            let buffer = try host.renderOffline(frames: frames)
            output += PCMConverter.monoFloats(from: buffer)
            rendered.value += Int(buffer.frameLength)
            player.poll()
        }
        try pull(2_400)
        for cue in cues {
            stamp("cue \(cue.rawValue): \(String(format: "%.3f", cue.duration)) s of audio")
            cuePlayer.play(cue)
            while !player.isIdle { try pull(256) }
            try pull(7_200) // 0.3 s of silence between cues
        }
        try WAVEncoder.encode(PCMConverter.pcm16(fromFloats: output), format: .speech24k).write(to: url)
        print(String(format: "Wrote %@: %.2f s at 24 kHz, peak %.1f dBFS.", url.path, Double(output.count) / 24_000,
                     Double(AudioLevel.measure(output).peakDB)))
    }

    static func cueList(_ name: String) -> [UICue] {
        switch name {
        case "all": UICue.allCases
        case "start": [.startListening]
        case "stop": [.stopListening]
        case "error": [.error]
        case "done": [.agentDone]
        default: fail("Unknown cue \(name). Use start, stop, error, done or all.")
        }
    }

    // MARK: record

    static func record(_ args: Arguments) async throws {
        guard args.positional.count == 2, let seconds = Double(args.positional[0]), seconds > 0 else { fail(usage) }
        let url = URL(fileURLWithPath: args.positional[1])
        let rate = Int(args.float("--rate", default: 16_000))
        guard rate >= 8_000, rate <= 48_000 else { fail("--rate must be between 8000 and 48000.") }

        switch MicrophoneCapture.authorization {
        case .authorized:
            break
        case .denied, .restricted:
            fail("""
                Microphone access is denied for this terminal app. Allow it in System Settings > Privacy & Security > \
                Microphone, then run the command again.
                """)
        case .notDetermined:
            if args.flag("--no-prompt") {
                fail("Microphone access has not been granted to this terminal app yet. Run without --no-prompt to be asked.")
            }
            print("Asking macOS for microphone access for this terminal app…")
            guard await MicrophoneCapture.requestAccess() else { fail("Microphone access was not granted.") }
        }

        let echoCancel = args.flag("--echo-cancel")
        let host = echoCancel ? AudioEngineHost(voiceProcessing: true, label: "OpenClicky.occtl.duplex") : nil
        let capture = MicrophoneCapture(
            options: .init(format: PCMFormat(sampleRate: rate), deviceUID: args.value("--device"), bluetoothHold: 0),
            host: host)
        let clock = Stopwatch()
        capture.onEvent = { event in print(clock.stamp("mic: \(event)")) }

        // Created before the mic opens so a bad path fails first; the consumer task below owns it from here on.
        let writer = try WAVFileWriter(url: url, format: PCMFormat(sampleRate: rate))
        let chunks = try capture.start()
        print("Recording \(seconds) s at \(rate) Hz mono\(echoCancel ? " with echo cancellation" : "") to \(url.path)…")

        // Optional: speak a file over the recording on the same engine, to hear how much echo cancellation removes.
        var voice: SpeechPlayer?
        if let path = args.value("--play") {
            let clip = try AudioFileLoader.load(URL(fileURLWithPath: path))
            let player = SpeechPlayer(sampleRate: 24_000, host: host)
            player.play(clip.pcm, format: clip.format, line: 0)
            voice = player
        }

        let consumer = Task { () throws -> (frames: Int, peak: Float, sumSquares: Double) in
            var frames = 0
            var peak: Float = 0
            var sumSquares: Double = 0
            var lastMeter = -1.0
            for await chunk in chunks {
                try writer.append(chunk.pcm)
                let count = chunk.pcm.count / 2
                frames += count
                peak = max(peak, chunk.level.peak)
                sumSquares += Double(chunk.level.rms * chunk.level.rms) * Double(count)
                if chunk.time - lastMeter >= 0.1 {
                    lastMeter = chunk.time
                    let bars = Int((capture.level * 40).rounded())
                    let meter = String(repeating: "#", count: bars) + String(repeating: ".", count: 40 - bars)
                    let line = String(format: "\r%6.2fs [%@] %6.1f dBFS", chunk.time, meter, Double(chunk.level.rmsDB))
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
            FileHandle.standardError.write(Data("\n".utf8))
            try writer.finish()
            return (frames, peak, sumSquares)
        }
        try await Task.sleep(for: .seconds(seconds))
        capture.stop(holdBluetooth: false)
        let result = try await consumer.value
        voice?.stop()
        capture.close()

        let duration = Double(result.frames) / Double(rate)
        let rms = result.frames > 0 ? Float((result.sumSquares / Double(result.frames)).squareRoot()) : 0
        print(String(format: "Wrote %@: %.2f s, peak %.1f dBFS, RMS %.1f dBFS.", url.path, duration,
                     Double(AudioLevel.decibels(result.peak)), Double(AudioLevel.decibels(rms))))
        if result.frames == 0 { fail("The microphone delivered no audio.") }
        if result.peak <= 2.0 / 32768 { print("Warning: the recording is digital silence; the input may be muted or dead.") }
    }

    // MARK: play

    static func play(_ args: Arguments) async throws {
        guard let path = args.positional.first else { fail(usage) }
        let clip = try AudioFileLoader.load(URL(fileURLWithPath: path))
        let speed = args.float("--speed", default: 1)
        let chunkMilliseconds = max(1, Int(args.float("--chunk-ms", default: 100)))
        let player = SpeechPlayer(sampleRate: 24_000)
        player.rate = speed
        let clock = Stopwatch()
        player.onEvent = { event in print(clock.stamp(describe(event))) }
        print(String(format: "Playing %@: %.2f s, %d Hz, %d channel(s), in %d ms chunks at %.2fx.", path, clip.duration,
                     clip.format.sampleRate, clip.format.channels, chunkMilliseconds, Double(speed)))

        // Feed it the way a voice streams a line: chunk by chunk.
        let line = player.beginLine(0)
        let frameBytes = 2 * max(1, clip.format.channels)
        let chunkBytes = max(frameBytes, clip.format.sampleRate * chunkMilliseconds / 1000 * frameBytes)
        var offset = 0
        while offset < clip.pcm.count {
            let end = min(offset + chunkBytes, clip.pcm.count)
            player.append(clip.pcm.subdata(in: offset..<end), format: clip.format, to: line)
            offset = end
        }
        player.finishLine(line)
        await player.waitUntilDrained()
        try await Task.sleep(for: .milliseconds(150))
    }

    // MARK: Helpers

    static func describe(_ event: SpeechPlayer.Event) -> String {
        switch event {
        case .lineStarted(let index, let expected):
            "line \(index) started" + (expected.map { String(format: ", expected %.3f s", $0) } ?? "")
        case .lineFinished(let index): "line \(index) finished"
        case .lineCut(let index, let played): String(format: "line %d cut after %.3f s", index, played)
        case .drained: "drained"
        case .stopped: "stopped"
        case .outputRestarted(let reason): "output restarted (\(reason))"
        case .outputFailed(let message): "output failed: \(message)"
        }
    }

    /// Splits `--name value` options and bare flags from positional arguments.
    struct Arguments {
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        static let valueOptions: Set<String> = ["--volume", "--speed", "--render", "--rate", "--device", "--play", "--chunk-ms"]

        init(_ args: [String]) {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if Self.valueOptions.contains(arg) {
                    guard index + 1 < args.count else { fail("\(arg) needs a value.") }
                    options[arg] = args[index + 1]
                    index += 2
                } else if arg.hasPrefix("--") {
                    flags.insert(arg)
                    index += 1
                } else {
                    positional.append(arg)
                    index += 1
                }
            }
        }

        func value(_ name: String) -> String? { options[name] }
        func flag(_ name: String) -> Bool { flags.contains(name) }

        func float(_ name: String, default fallback: Float) -> Float {
            guard let text = options[name] else { return fallback }
            guard let value = Float(text), value.isFinite else { fail("\(name) needs a number, not \(text).") }
            return value
        }
    }

    /// Seconds since the command started, for timeline lines.
    final class Stopwatch: Sendable {
        private let start = ContinuousClock.now
        func stamp(_ text: String) -> String {
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return String(format: "%7.3fs  ", seconds) + text
        }
    }

    final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        var value: Int {
            get { lock.withLock { frames } }
            set { lock.withLock { frames = newValue } }
        }
    }
}
