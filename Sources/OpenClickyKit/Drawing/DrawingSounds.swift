import Foundation
import QuartzCore

/// The sounds of drawing, synthesized in code (no sound files): a texture while the pen moves (`felt` on the screen,
/// `pencil` on a card, `writing` for words, `eraser`) and short accents (a gel pill popping in, tape, a key tap, a
/// bell for a target, the `sfx()` accents). The engine sends a recipe for each mark (`DrawingEvent.sound`).
public enum DrawingSounds {
    public static let textures: Set<String> = ["felt", "pencil", "writing", "eraser"]
    public static let accents: Set<String> = ["gel-pop", "badge-pop", "button-appear", "paper", "tape", "tap", "highlighter",
                                               "slide", "page-clear", "pen-flick", "type-keys", "copy-tick", "target-ping",
                                               "tada", "ding", "nope", "stamp", "sparkle", "whoosh", "boing", "page-turn"]

    /// Mono samples for one mark, starting at the mark's start, peak about -10 dBFS.
    public static func samples(for recipe: DrawingSoundRecipe, sampleRate: Double) -> [Float] {
        var out: [Float] = []
        func add(_ part: [Float], at offset: Double, gain: Float) {
            let first = max(0, Int(offset * sampleRate))
            if out.count < first + part.count { out += [Float](repeating: 0, count: first + part.count - out.count) }
            for i in 0..<part.count { out[first + i] += part[i] * gain }
        }
        if let texture = recipe.texture, recipe.duration > 0.02 {
            add(Self.texture(texture, duration: min(recipe.duration, 4), sampleRate: sampleRate, seed: seed(recipe)), at: 0, gain: 1)
        }
        for accent in recipe.accents { add(Self.accent(accent.id, sampleRate: sampleRate), at: accent.at, gain: 1) }
        return out
    }

    /// Every recipe mixed onto one track from `start` (host-clock seconds) for `duration` seconds.
    public static func mix(_ recipes: [DrawingSoundRecipe], from start: Double, duration: Double, sampleRate: Double) -> [Float] {
        let total = max(1, Int(duration * sampleRate))
        var track = [Float](repeating: 0, count: total)
        for recipe in recipes {
            let first = Int((recipe.at - start) * sampleRate)
            let part = samples(for: recipe, sampleRate: sampleRate)
            for (i, sample) in part.enumerated() where first + i >= 0 && first + i < total { track[first + i] += sample }
        }
        // Soft limit so stacked sounds never clip.
        return track.map { Float(tanh(Double($0) * 1.2) / 1.2) }
    }

    // MARK: Textures (filtered noise shaped like the pen's motion)

    static func texture(_ name: String, duration: Double, sampleRate: Double, seed: UInt64) -> [Float] {
        var noise = Noise(seed: seed)
        let count = Int(duration * sampleRate)
        var low = 0.0, low2 = 0.0
        var out = [Float](repeating: 0, count: count)
        // (low-pass cut-off, high-pass cut-off, stroke rhythm in Hz, gain)
        let shape: (Double, Double, Double, Double) = switch name {
        case "pencil": (6000, 1600, 11, 0.10)
        case "writing": (4500, 900, 13, 0.10)
        case "eraser": (900, 120, 5, 0.16)
        default: (2800, 350, 7, 0.13)   // felt
        }
        let a1 = 1 - exp(-2 * Double.pi * shape.0 / sampleRate), a2 = 1 - exp(-2 * Double.pi * shape.1 / sampleRate)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let x = noise.next()
            low += a1 * (x - low)
            low2 += a2 * (low - low2)
            let band = low - low2
            // The pen presses and lifts: a rhythm of soft swells, faded in and out at the ends.
            let rhythm = 0.55 + 0.45 * abs(sin(Double.pi * shape.2 * t))
            let edge = min(1, t / 0.03, (duration - t) / 0.06)
            var gain = shape.3 * rhythm * max(0, edge)
            if name == "writing" {
                // Letters: short scratches about 14 a second.
                let phase = (t * 14).truncatingRemainder(dividingBy: 1)
                gain *= phase < 0.45 ? 1 : 0.25
            }
            out[i] = Float(band * gain * 4)
        }
        return out
    }

    // MARK: Accents

    private static let soft: [CueSynthesizer.Partial] = [.init(1, 1), .init(2, 0.2), .init(3, 0.05)]
    private static let bell: [CueSynthesizer.Partial] = [.init(1, 1), .init(2, 0.12), .init(2.76, 0.08), .init(5.4, 0.03)]

    static func accent(_ id: String, sampleRate: Double) -> [Float] {
        func notes(_ peak: Float, _ list: [CueSynthesizer.Note]) -> [Float] {
            CueSynthesizer.render(.init(peak: peak, notes: list), sampleRate: sampleRate)
        }
        func note(_ f: Double, to end: Double? = nil, at start: Double = 0, length: Double, decay: Double, partials: [CueSynthesizer.Partial] = soft,
                  gain: Double = 1) -> CueSynthesizer.Note {
            .init(frequency: f, endFrequency: end, start: start, length: length, gain: gain, attack: 0.003, decay: decay, partials: partials)
        }
        switch id {
        case "gel-pop": return notes(0.22, [note(700, to: 1250, length: 0.07, decay: 0.03)])
        case "badge-pop": return notes(0.22, [note(950, to: 1500, length: 0.06, decay: 0.025)])
        case "button-appear": return notes(0.2, [note(784, length: 0.09, decay: 0.05), note(1175, at: 0.06, length: 0.14, decay: 0.07)])
        case "target-ping": return notes(0.22, [note(1568, length: 0.4, decay: 0.15, partials: bell)])
        case "ding": return notes(0.3, [note(1319, length: 0.7, decay: 0.25, partials: bell)])
        case "tada": return notes(0.3, [note(523, length: 0.18, decay: 0.1), note(659, at: 0.09, length: 0.18, decay: 0.1),
                                       note(784, at: 0.18, length: 0.2, decay: 0.12), note(1047, at: 0.27, length: 0.45, decay: 0.2, partials: bell)])
        case "nope": return notes(0.28, [note(330, length: 0.12, decay: 0.1), note(262, to: 247, at: 0.14, length: 0.2, decay: 0.15)])
        case "sparkle": return notes(0.2, [2093.0, 2637, 3136, 4186].enumerated().map { note($1, at: Double($0) * 0.045, length: 0.18, decay: 0.07, partials: bell) })
        case "boing": return notes(0.28, [note(196, to: 523, length: 0.12, decay: 0.2), note(523, to: 262, at: 0.11, length: 0.28, decay: 0.2)])
        case "stamp":
            let thud = notes(0.35, [note(90, to: 60, length: 0.16, decay: 0.06, partials: [.init(1, 1), .init(1.5, 0.3)])])
            return mixInto(thud, burst(length: 0.012, cut: 3000, gain: 0.2, sampleRate: sampleRate, seed: 7))
        case "tape": return swish(length: 0.16, low: 5000, high: 1500, gain: 0.12, buzz: 55, sampleRate: sampleRate, seed: 3)
        case "paper", "page-turn": return swish(length: 0.28, low: 3500, high: 500, gain: 0.1, buzz: 0, sampleRate: sampleRate, seed: 5)
        case "slide": return swish(length: 0.35, low: 1800, high: 250, gain: 0.08, buzz: 0, sampleRate: sampleRate, seed: 9)
        case "whoosh", "page-clear": return swish(length: id == "page-clear" ? 0.6 : 0.4, low: 2500, high: 200, gain: 0.12, buzz: 0, sampleRate: sampleRate, seed: 11)
        case "highlighter": return swish(length: 0.3, low: 7000, high: 2500, gain: 0.07, buzz: 0, sampleRate: sampleRate, seed: 13)
        case "tap", "pen-flick": return burst(length: id == "tap" ? 0.01 : 0.02, cut: 4000, gain: 0.18, sampleRate: sampleRate, seed: 17)
        case "copy-tick": return mixInto(burst(length: 0.008, cut: 5000, gain: 0.18, sampleRate: sampleRate, seed: 19),
                                         burst(length: 0.008, cut: 5000, gain: 0.15, sampleRate: sampleRate, seed: 23), at: 0.07, sampleRate: sampleRate)
        case "type-keys":
            var keys: [Float] = []
            for k in 0..<6 { keys = mixInto(keys, burst(length: 0.008, cut: 4500, gain: 0.15, sampleRate: sampleRate, seed: UInt64(29 + k)), at: Double(k) * 0.085, sampleRate: sampleRate) }
            return keys
        default: return []
        }
    }

    private static func burst(length: Double, cut: Double, gain: Double, sampleRate: Double, seed: UInt64) -> [Float] {
        var noise = Noise(seed: seed)
        let count = max(1, Int(length * sampleRate))
        let a = 1 - exp(-2 * Double.pi * cut / sampleRate)
        var low = 0.0
        return (0..<count).map { i in
            low += a * (noise.next() - low)
            return Float(low * gain * 3 * exp(-Double(i) / (Double(count) * 0.35)))
        }
    }

    private static func swish(length: Double, low lowCut: Double, high highCut: Double, gain: Double, buzz: Double, sampleRate: Double, seed: UInt64) -> [Float] {
        var noise = Noise(seed: seed)
        let count = Int(length * sampleRate)
        let a1 = 1 - exp(-2 * Double.pi * lowCut / sampleRate), a2 = 1 - exp(-2 * Double.pi * highCut / sampleRate)
        var l1 = 0.0, l2 = 0.0
        return (0..<count).map { i in
            let t = Double(i) / Double(max(1, count))
            l1 += a1 * (noise.next() - l1)
            l2 += a2 * (l1 - l2)
            var env = sin(Double.pi * t)
            if buzz > 0 { env *= 0.6 + 0.4 * sin(2 * Double.pi * buzz * Double(i) / sampleRate) }
            return Float((l1 - l2) * env * gain * 5)
        }
    }

    private static func mixInto(_ base: [Float], _ part: [Float], at offset: Double = 0, sampleRate: Double = 24_000) -> [Float] {
        var out = base
        let first = Int(offset * sampleRate)
        if out.count < first + part.count { out += [Float](repeating: 0, count: first + part.count - out.count) }
        for i in 0..<part.count { out[first + i] += part[i] }
        return out
    }

    private static func seed(_ recipe: DrawingSoundRecipe) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for byte in (recipe.mark ?? "").utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return h
    }

    /// A small deterministic noise source (xorshift), so the same drawing always sounds the same.
    struct Noise {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 2_000_001) / 1_000_000 - 1
        }
    }
}

/// Plays a drawing's sound recipes as the marks are drawn, through its own speech players (never queued behind the
/// voice). Recipes arrive ahead of their moment; each plays when its mark starts on the drawing's clock. Textures and
/// accents play on separate players that share one output, so an accent due while a texture plays sounds on time
/// rather than after it. Busy stretches are thinned: at most one texture at a time, and accents no closer than 50 ms
/// apart.
@MainActor
public final class DrawingSoundPlayer {
    /// Plays the pen textures.
    public let player: SpeechPlayer
    /// Plays the accents (pops, taps, bells), beside the textures.
    public let accentPlayer: SpeechPlayer
    public var volume: Float
    public var isEnabled = true
    /// The `drawing.sounds` flag is read at each sound; nil (tests) leaves only `isEnabled`.
    public var flags: FeatureFlagStore?
    private var line = 0
    private var textureUntil: Double = 0
    /// When the accents scheduled lately play (host-clock seconds), the last 64.
    private var accentTimes: [Double] = []
    /// Sounds waiting for their moment; each takes itself out once it has played.
    private var pending: [Int: Task<Void, Never>] = [:]
    private var nextSound = 0
    /// Moves on at every `stopAll()`: a sound scheduled before it never plays.
    private var generation = 0

    /// `player` and `accentPlayer` default to two players on one new output.
    public init(player: SpeechPlayer? = nil, accentPlayer: SpeechPlayer? = nil, volume: Float = 0.35) {
        var host: AudioEngineHost?
        func made(sampleRate: Int) -> SpeechPlayer {
            let shared = host ?? AudioEngineHost(label: "OpenClicky.drawingSounds")
            host = shared
            return SpeechPlayer(sampleRate: sampleRate, host: shared)
        }
        let texturePlayer = player ?? made(sampleRate: 24_000)
        self.player = texturePlayer
        self.accentPlayer = accentPlayer ?? made(sampleRate: texturePlayer.sampleRate)
        self.volume = volume
    }

    /// Play `recipe` when its moment comes. `now` is the drawing's clock (`DrawingPainter.now()`).
    public func schedule(_ recipe: DrawingSoundRecipe, now: Double) {
        guard isEnabled, volume > 0, flags?.isOn(.drawingSounds) ?? true else { return }
        var recipe = recipe
        if recipe.texture != nil {
            if recipe.at < textureUntil { recipe.texture = nil } else { textureUntil = recipe.at + recipe.duration }
        }
        // By distance, not order: the next line's recipes can come due before the last line's (its length was a guess).
        recipe.accents = recipe.accents.filter { accent in
            let at = recipe.at + accent.at
            guard !accentTimes.contains(where: { abs(at - $0) < 0.05 }) else { return false }
            accentTimes.append(at)
            if accentTimes.count > 64 { accentTimes.removeFirst(accentTimes.count - 64) }
            return true
        }
        guard recipe.texture != nil || !recipe.accents.isEmpty else { return }
        var texture = recipe, accents = recipe
        texture.accents = []
        accents.texture = nil
        let delay = max(0, recipe.at - now)
        let gain = volume, generation = generation
        let id = nextSound
        nextSound += 1
        pending[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.pending[id] = nil
            if texture.texture != nil { self.play(texture, on: self.player, gain: gain) }
            if !accents.accents.isEmpty { self.play(accents, on: self.accentPlayer, gain: gain) }
        }
    }

    private func play(_ recipe: DrawingSoundRecipe, on player: SpeechPlayer, gain: Float) {
        let samples = DrawingSounds.samples(for: recipe, sampleRate: Double(player.sampleRate)).map { $0 * gain }
        guard !samples.isEmpty else { return }
        line += 1
        _ = player.play(PCMConverter.pcm16(fromFloats: samples), format: PCMFormat(sampleRate: player.sampleRate), line: line)
    }

    /// Stop everything scheduled and playing (the drawing was cancelled or cleared).
    public func stopAll() {
        generation += 1
        for task in pending.values { task.cancel() }
        pending.removeAll()
        textureUntil = 0
        accentTimes.removeAll()
        _ = player.stop()
        _ = accentPlayer.stop()
    }
}
