import AVFoundation
import Foundation

/// OpenClicky's own interface sounds, synthesized in code (no sound files): short tonal cues for the moments the
/// user can't see, e.g. the mic opening while their eyes are on another app.
public enum UICue: String, CaseIterable, Sendable, Hashable {
    /// The microphone is live: a quick rising fifth.
    case startListening
    /// The press ended and the request is on its way: a falling fourth, softer.
    case stopListening
    /// Something failed: two low notes stepping down, with a slight sag on the second.
    case error
    /// A background job finished: a bright three-note bell arpeggio.
    case agentDone
    /// A background job started: a quick upward glide into a soft high note, like something taking off.
    case agentLaunch
    /// A background job is waiting on the user: two even bell notes, the second repeating the first a step up.
    case agentNeedsYou

    /// Mono samples at `sampleRate`, peak-normalized, starting and ending at silence.
    public func samples(sampleRate: Double) -> [Float] {
        CueSynthesizer.render(recipe, sampleRate: sampleRate)
    }

    /// The cue as PCM16 at `sampleRate`, scaled by `volume`.
    public func pcm16(sampleRate: Int, volume: Float = 1) -> Data {
        let gain = min(max(volume, 0), 1)
        return PCMConverter.pcm16(fromFloats: samples(sampleRate: Double(sampleRate)).map { $0 * gain })
    }

    public var duration: TimeInterval { recipe.duration }

    var recipe: CueSynthesizer.Recipe {
        // Partials are (frequency ratio, relative gain). Bright cues get a little 2nd/3rd harmonic so they cut
        // through speech; the bell uses inharmonic partials.
        let soft: [CueSynthesizer.Partial] = [.init(1, 1), .init(2, 0.22), .init(3, 0.06)]
        let hollow: [CueSynthesizer.Partial] = [.init(1, 1), .init(3, 0.12), .init(5, 0.04)]
        let bell: [CueSynthesizer.Partial] = [.init(1, 1), .init(2, 0.12), .init(2.76, 0.08), .init(5.4, 0.03)]
        switch self {
        case .startListening:
            return .init(peak: 0.5, notes: [
                .init(frequency: 587.33, start: 0, length: 0.085, gain: 0.8, attack: 0.004, decay: 0.06, partials: soft),
                .init(frequency: 880.00, start: 0.06, length: 0.15, gain: 1, attack: 0.004, decay: 0.07, partials: soft),
            ])
        case .stopListening:
            return .init(peak: 0.42, notes: [
                .init(frequency: 880.00, start: 0, length: 0.075, gain: 0.8, attack: 0.004, decay: 0.055, partials: soft),
                .init(frequency: 659.26, start: 0.055, length: 0.14, gain: 1, attack: 0.004, decay: 0.065, partials: soft),
            ])
        case .error:
            return .init(peak: 0.45, notes: [
                .init(frequency: 311.13, start: 0, length: 0.12, gain: 1, attack: 0.006, decay: 0.12, partials: hollow),
                .init(frequency: 277.18, endFrequency: 261.63, start: 0.14, length: 0.18, gain: 1, attack: 0.006, decay: 0.14, partials: hollow),
            ])
        case .agentDone:
            return .init(peak: 0.45, notes: [
                .init(frequency: 1046.50, start: 0, length: 0.40, gain: 0.7, attack: 0.003, decay: 0.16, partials: bell),
                .init(frequency: 1318.51, start: 0.075, length: 0.40, gain: 0.75, attack: 0.003, decay: 0.16, partials: bell),
                .init(frequency: 1567.98, start: 0.15, length: 0.55, gain: 0.9, attack: 0.003, decay: 0.2, partials: bell),
            ])
        case .agentLaunch:
            return .init(peak: 0.4, notes: [
                .init(frequency: 523.25, endFrequency: 1046.50, start: 0, length: 0.16, gain: 0.7, attack: 0.01, decay: 0.2, partials: soft),
                .init(frequency: 1567.98, start: 0.13, length: 0.24, gain: 0.8, attack: 0.004, decay: 0.09, partials: bell),
            ])
        case .agentNeedsYou:
            return .init(peak: 0.45, notes: [
                .init(frequency: 987.77, start: 0, length: 0.26, gain: 0.85, attack: 0.003, decay: 0.12, partials: bell),
                .init(frequency: 1108.73, start: 0.2, length: 0.36, gain: 0.9, attack: 0.003, decay: 0.15, partials: bell),
            ])
        }
    }
}

/// Additive synthesis of short notes: each note is a sum of sine partials under a raised-cosine attack, an
/// exponential decay and a raised-cosine release, so every cue starts and ends at zero (no clicks).
enum CueSynthesizer {
    struct Partial: Hashable {
        var ratio: Double
        var gain: Double
        init(_ ratio: Double, _ gain: Double) {
            self.ratio = ratio
            self.gain = gain
        }
    }

    struct Note: Hashable {
        var frequency: Double
        /// Glide target (exponential) over the note, if any.
        var endFrequency: Double?
        var start: TimeInterval
        var length: TimeInterval
        var gain: Double
        var attack: TimeInterval
        /// Time constant of the exponential decay.
        var decay: TimeInterval
        var partials: [Partial]

        init(frequency: Double, endFrequency: Double? = nil, start: TimeInterval, length: TimeInterval, gain: Double,
             attack: TimeInterval, decay: TimeInterval, partials: [Partial]) {
            self.frequency = frequency
            self.endFrequency = endFrequency
            self.start = start
            self.length = length
            self.gain = gain
            self.attack = attack
            self.decay = decay
            self.partials = partials
        }
    }

    struct Recipe: Hashable {
        /// Peak amplitude after normalization (0.5 ≈ -6 dBFS).
        var peak: Float
        var notes: [Note]

        var duration: TimeInterval { notes.map { $0.start + $0.length }.max() ?? 0 }
    }

    static let releaseTime: TimeInterval = 0.012

    static func render(_ recipe: Recipe, sampleRate: Double) -> [Float] {
        let total = Int((recipe.duration * sampleRate).rounded(.up)) + 1
        var mix = [Double](repeating: 0, count: total)
        for note in recipe.notes {
            let first = Int((note.start * sampleRate).rounded())
            let count = Int((note.length * sampleRate).rounded())
            var phases = [Double](repeating: 0, count: note.partials.count)
            let glide = note.endFrequency.map { $0 / note.frequency } ?? 1
            for i in 0..<count where first + i < total {
                let t = Double(i) / sampleRate
                let frequency = note.frequency * pow(glide, t / note.length)
                let attack = t < note.attack ? 0.5 * (1 - cos(Double.pi * t / note.attack)) : 1
                let remaining = note.length - t
                let release = remaining < releaseTime ? 0.5 * (1 - cos(Double.pi * max(remaining, 0) / releaseTime)) : 1
                let envelope = note.gain * attack * exp(-t / note.decay) * release
                var sample = 0.0
                for (k, partial) in note.partials.enumerated() {
                    phases[k] += 2 * Double.pi * frequency * partial.ratio / sampleRate
                    if phases[k] > 2 * Double.pi { phases[k] -= 2 * Double.pi }
                    sample += partial.gain * sin(phases[k])
                }
                mix[first + i] += envelope * sample
            }
        }
        let peak = mix.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return mix.map { Float($0) } }
        let scale = Double(recipe.peak) / peak
        return mix.map { Float($0 * scale) }
    }
}

/// Plays UI cues through their own `SpeechPlayer` (so they never wait behind speech). On a cold output the first cue
/// gets a short lead-in of silence, longer on Bluetooth, so the device's wake-up doesn't swallow its start.
///
/// Once used, the output stays warm for `freshnessWindow` seconds (the player keeps its device open that long after
/// the last cue), so cues in a burst of use start at once. Sleep and an output-device change close or move the
/// device; `rewarmAfterWake()` and `rewarmAfterOutputChange()` open it again, but only while the window is fresh.
/// The window counts awake time only (`awakeClock`), so a cue just before the lid closes is still fresh on wake however
/// long the Mac slept; a wall clock would always have run past it. Nothing here opens a device before the first use.
public final class CuePlayer: @unchecked Sendable {
    public let player: SpeechPlayer
    private let volumeBox: LockedValue<Float>
    private let lineCounter = LockedValue<Int>(0)
    private let cache = LockedValue<[UICue: Data]>([:])
    private let lastUse = LockedValue<TimeInterval?>(nil)
    private let clock: @Sendable () -> TimeInterval

    /// Seconds of silence before a cue on a cold output, wired and Bluetooth.
    public let coldLeadIn: TimeInterval
    public let coldLeadInBluetooth: TimeInterval
    /// Seconds after the last cue or warm-up that the output stays open and counts as fresh.
    public let freshnessWindow: TimeInterval

    public init(player: SpeechPlayer? = nil, host: AudioEngineHost? = nil, volume: Float = 0.7,
                coldLeadIn: TimeInterval = 0.03, coldLeadInBluetooth: TimeInterval = 0.2, freshnessWindow: TimeInterval = 30,
                clock: @escaping @Sendable () -> TimeInterval = CuePlayer.awakeClock) {
        self.player = player ?? SpeechPlayer(sampleRate: 24_000, host: host)
        self.volumeBox = LockedValue(min(max(volume, 0), 1))
        self.coldLeadIn = coldLeadIn
        self.coldLeadInBluetooth = coldLeadInBluetooth
        self.freshnessWindow = max(0, freshnessWindow)
        self.clock = clock
        // The player releases its device this long after its last line, which is what keeps the output warm.
        self.player.idleTimeout = max(self.player.idleTimeout, self.freshnessWindow)
    }

    /// Seconds the Mac has been awake since boot: it stands still while the Mac sleeps.
    public static let awakeClock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// A cue or warm-up happened within `freshnessWindow` seconds of awake time.
    public var isFresh: Bool {
        guard let last = lastUse.get() else { return false }
        return clock() - last <= freshnessWindow
    }

    /// The Mac woke: the output was stopped while asleep. Warms it again if cues were in use; returns whether it did.
    @discardableResult
    public func rewarmAfterWake() -> Bool { rewarmIfFresh() }

    /// The default output device changed (headphones plugged in, AirPods connected): warms the new one if cues were in
    /// use; returns whether it did.
    @discardableResult
    public func rewarmAfterOutputChange() -> Bool { rewarmIfFresh() }

    private func rewarmIfFresh() -> Bool {
        guard isFresh else { return false }
        wake()
        return true
    }

    public var volume: Float {
        get { volumeBox.get() }
        set {
            volumeBox.set(min(max(newValue, 0), 1))
            cache.set([:])
        }
    }

    /// Plays `cue` now (after any cue still playing). Returns the line it plays as.
    @discardableResult
    public func play(_ cue: UICue) -> SpeechPlayer.Line {
        let format = PCMFormat(sampleRate: player.sampleRate)
        var pcm = Data()
        if !player.isOutputRunning {
            let bluetooth = AudioDevices.defaultOutput()?.transport.isBluetooth == true
            let lead = bluetooth ? coldLeadInBluetooth : coldLeadIn
            pcm = Data(count: Int(lead * Double(format.sampleRate)) * 2)
        }
        pcm += audio(for: cue)
        lastUse.set(clock())
        let index = lineCounter.mutate { counter in
            defer { counter += 1 }
            return counter
        }
        return player.play(pcm, format: format, line: index)
    }

    /// Plays the cue once the microphone is actually delivering (a Bluetooth route switch would otherwise eat it).
    /// Returns false (and plays nothing) if the mic didn't start within `timeout`.
    @discardableResult
    public func playWhenRunning(_ cue: UICue, mic: MicrophoneCapture, timeout: TimeInterval = 1.5) async -> Bool {
        guard await mic.waitUntilRunning(timeout: timeout) else { return false }
        play(cue)
        return true
    }

    /// Wakes the output device ahead of time (e.g. at key-down) so the next cue starts promptly, and starts a new
    /// freshness window.
    public func warmUp() {
        lastUse.set(clock())
        wake()
    }

    private func wake() {
        let line = player.beginLine(-1)
        player.finishLine(line)
    }

    /// Synthesizes `cues` now (at launch) so the first press doesn't wait for it. Opens no device.
    public func preload(_ cues: [UICue] = UICue.allCases) {
        for cue in cues { _ = audio(for: cue) }
    }

    /// The cues whose audio is ready.
    public var preloaded: Set<UICue> { Set(cache.get().keys) }

    private func audio(for cue: UICue) -> Data {
        if let cached = cache.get()[cue] { return cached }
        let pcm = cue.pcm16(sampleRate: player.sampleRate, volume: volumeBox.get())
        cache.mutate { $0[cue] = pcm }
        return pcm
    }
}

/// Loads audio files as PCM16: WAV directly, anything else Core Audio reads (AIFF, CAF, MP3, M4A…) via AVAudioFile.
public enum AudioFileLoader {
    public static func load(_ url: URL) throws -> DecodedAudio {
        if url.pathExtension.lowercased() == "wav", let data = try? Data(contentsOf: url),
           let decoded = try? WAVDecoder.decode(data) {
            return decoded
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(file.length, 1))) else {
            throw AudioIOError.invalidAudioData("could not allocate \(file.length) frames")
        }
        try file.read(into: buffer)
        return DecodedAudio(pcm: PCMConverter.pcm16(from: buffer),
                            format: PCMFormat(sampleRate: Int(format.sampleRate.rounded()), channels: Int(format.channelCount)))
    }
}
