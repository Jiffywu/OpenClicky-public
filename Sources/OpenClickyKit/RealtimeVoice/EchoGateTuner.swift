import Foundation

/// Offline tuning for `RealtimeEchoGate` (docs/audio-robustness.md). It plays a recorded reply into a modelled room
/// (the speaker-to-mic coupling, a few early reflections, an echo canceller's residual and a noise floor), lets a
/// recorded user talk over it, feeds the mixed "mic" through the gate frame by frame, and measures what matters: did
/// the voice alone ever open the gate (a false barge-in), and how long after the user started did it open.
///
/// The room is a model, not a measurement: it ranks settings and catches regressions, and the chosen values still need
/// a person in a real room (docs/audio-robustness.md lists the checks).
public enum EchoGateTuner {
    /// How the voice reaches the mic.
    public struct Room: Sendable, Hashable {
        public var name: String
        /// Echo level relative to the voice as played (dB). Laptop speakers near the mic at a normal volume: about -6.
        public var couplingDB: Float
        /// How much the echo canceller removes (dB); 0 without one.
        public var cancellationDB: Float
        /// Room noise, RMS dBFS.
        public var noiseDB: Float
        /// Speaker-to-mic delay plus output latency, seconds.
        public var delay: TimeInterval

        public init(name: String, couplingDB: Float, cancellationDB: Float, noiseDB: Float = -62, delay: TimeInterval = 0.03) {
            self.name = name
            self.couplingDB = couplingDB
            self.cancellationDB = cancellationDB
            self.noiseDB = noiseDB
            self.delay = delay
        }

        /// Laptop speakers with no echo cancellation, at two volumes.
        public static let speakersRaw = [Room(name: "speakers, loud", couplingDB: -4, cancellationDB: 0),
                                         Room(name: "speakers, normal", couplingDB: -10, cancellationDB: 0)]
        /// The same with the voice-processing canceller (it typically removes 25-35 dB; the weak case is kept).
        public static let speakersCancelled = [Room(name: "cancelled, weak AEC, loud", couplingDB: -4, cancellationDB: 22),
                                               Room(name: "cancelled, AEC, loud", couplingDB: -4, cancellationDB: 28),
                                               Room(name: "cancelled, AEC, normal", couplingDB: -10, cancellationDB: 28)]
    }

    public struct Scenario: Sendable, Hashable {
        public var room: Room
        /// The user's speech level at the mic, RMS dBFS over its voiced part (nil: nobody talks, echo only).
        public var userLevelDB: Float?
        /// Seconds into the reply the user starts talking.
        public var userStartsAt: TimeInterval

        public init(room: Room, userLevelDB: Float?, userStartsAt: TimeInterval = 1.0) {
            self.room = room
            self.userLevelDB = userLevelDB
            self.userStartsAt = userStartsAt
        }
    }

    public struct Outcome: Sendable, Hashable {
        /// The gate opened before the user said anything (or with nobody talking).
        public var falseBargeIn: Bool
        /// Seconds from the user's first voiced sound to the gate opening.
        public var latency: TimeInterval?
        /// The user talked over the reply and the gate never opened.
        public var missed: Bool
    }

    /// One mixed mic signal, ready to run through any number of gate settings.
    public struct Take: Sendable {
        /// 40 ms PCM16 frames of the mic and their start times.
        var frames: [(time: TimeInterval, pcm: Data)]
        var format: PCMFormat
        var onset: TimeInterval?
        var replyEnd: TimeInterval
    }

    /// Mixes one scenario into frames. `reply` and `user` are mono samples at `sampleRate`.
    public static func take(reply: [Float], user: [Float], sampleRate: Int, scenario: Scenario) -> Take {
        let rate = Double(sampleRate)
        let mic = mix(reply: reply, user: user, sampleRate: sampleRate, scenario: scenario)
        let onset = scenario.userLevelDB == nil ? nil : firstVoiced(user, sampleRate: sampleRate).map { scenario.userStartsAt + $0 }
        let frame = sampleRate / 25
        var frames: [(TimeInterval, Data)] = []
        var start = 0
        while start < mic.count {
            let end = min(mic.count, start + frame)
            frames.append((Double(start) / rate, PCMConverter.pcm16(fromFloats: Array(mic[start..<end]))))
            start = end
        }
        return Take(frames: frames, format: PCMFormat(sampleRate: sampleRate), onset: onset, replyEnd: Double(reply.count) / rate)
    }

    /// Runs one take through the gate: the voice starts at 0 and stops at the reply's end.
    public static func evaluate(_ settings: RealtimeEchoGate.Settings, _ take: Take) -> Outcome {
        var gate = RealtimeEchoGate(route: .speakers, settings: settings)
        gate.assistantStartedSpeaking(at: 0)
        let frameSeconds = 0.04
        for (time, pcm) in take.frames {
            if time >= take.replyEnd, gate.assistantSpeaking { gate.assistantStoppedSpeaking(at: take.replyEnd) }
            if case .bargeIn = gate.process(pcm, format: take.format, at: time) {
                let at = time + frameSeconds
                guard let onset = take.onset, at > onset else { return Outcome(falseBargeIn: true, latency: nil, missed: false) }
                return Outcome(falseBargeIn: false, latency: at - onset, missed: false)
            }
        }
        // Talking only after the reply ended isn't a barge-in; talking over it and never getting in is a miss.
        let talkedOver = take.onset.map { $0 < take.replyEnd } ?? false
        return Outcome(falseBargeIn: false, latency: nil, missed: talkedOver)
    }

    /// Runs one scenario.
    public static func run(_ settings: RealtimeEchoGate.Settings, reply: [Float], user: [Float], sampleRate: Int,
                           scenario: Scenario) -> Outcome {
        evaluate(settings, take(reply: reply, user: user, sampleRate: sampleRate, scenario: scenario))
    }

    /// One row of a sweep: a candidate's worst case over every scenario.
    public struct Row: Sendable, Hashable {
        public var settings: RealtimeEchoGate.Settings
        public var falseBargeIns: Int
        public var misses: Int
        public var runs: Int
        public var worstLatency: TimeInterval?
        public var meanLatency: TimeInterval?

        /// Safe (no false barge-in, no miss), then fastest.
        public static func better(_ a: Row, _ b: Row) -> Bool {
            let aBad = a.falseBargeIns * 1000 + a.misses, bBad = b.falseBargeIns * 1000 + b.misses
            if aBad != bBad { return aBad < bBad }
            return (a.worstLatency ?? .infinity, a.meanLatency ?? .infinity) < (b.worstLatency ?? .infinity, b.meanLatency ?? .infinity)
        }
    }

    /// Every candidate over every reply × user × scenario; rows sorted best first.
    public static func sweep(candidates: [RealtimeEchoGate.Settings], replies: [[Float]], users: [[Float]], sampleRate: Int,
                             scenarios: [Scenario]) -> [Row] {
        var takes: [Take] = []
        for reply in replies {
            for scenario in scenarios {
                for user in scenario.userLevelDB == nil ? [[]] : users {
                    takes.append(take(reply: reply, user: user, sampleRate: sampleRate, scenario: scenario))
                }
            }
        }
        return candidates.map { settings in
            var row = Row(settings: settings, falseBargeIns: 0, misses: 0, runs: 0, worstLatency: nil, meanLatency: nil)
            var latencies: [TimeInterval] = []
            for take in takes {
                let outcome = evaluate(settings, take)
                row.runs += 1
                if outcome.falseBargeIn { row.falseBargeIns += 1 }
                if outcome.missed { row.misses += 1 }
                if let latency = outcome.latency { latencies.append(latency) }
            }
            row.worstLatency = latencies.max()
            row.meanLatency = latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
            return row
        }.sorted(by: Row.better)
    }

    /// A grid of candidates around the gate's knobs.
    public static func grid(levels: [Float], speech: [TimeInterval], windows: [TimeInterval] = [0.6, 0.8],
                            settle: TimeInterval) -> [RealtimeEchoGate.Settings] {
        var out: [RealtimeEchoGate.Settings] = []
        for level in levels {
            for duration in speech {
                for window in windows where window > duration {
                    out.append(RealtimeEchoGate.Settings(bargeInLevelDB: level, bargeInSpeech: duration, bargeInWindow: window,
                                                         settleWindow: settle))
                }
            }
        }
        return out
    }

    // MARK: The room model

    /// The mic signal: echo of the reply (delayed, with three early reflections, scaled by the coupling and the
    /// canceller), the user scaled to their level from `userStartsAt`, and deterministic noise.
    static func mix(reply: [Float], user: [Float], sampleRate: Int, scenario: Scenario) -> [Float] {
        let rate = Double(sampleRate)
        let room = scenario.room
        let userStart = Int(scenario.userStartsAt * rate)
        let length = max(reply.count + Int(0.4 * rate), scenario.userLevelDB == nil ? 0 : userStart + user.count) + Int(0.2 * rate)
        var mic = [Float](repeating: 0, count: length)
        let echoGain = decibels(room.couplingDB - room.cancellationDB)
        let taps: [(TimeInterval, Float)] = [(0, 1), (0.018, 0.4), (0.045, 0.22), (0.09, 0.1)]
        for (offset, gain) in taps {
            let shift = Int((room.delay + offset) * rate)
            for (index, sample) in reply.enumerated() where index + shift < length {
                mic[index + shift] += sample * echoGain * gain
            }
        }
        if let level = scenario.userLevelDB, !user.isEmpty {
            let voiced = voicedRMS(user, sampleRate: sampleRate)
            let gain = voiced > 0 ? decibels(level) / voiced : 0
            for (index, sample) in user.enumerated() where userStart + index < length {
                mic[userStart + index] += sample * gain
            }
        }
        var noise = NoiseSource(seed: 0x5eed)
        let noiseGain = decibels(room.noiseDB) * Float(3).squareRoot()
        for index in mic.indices { mic[index] += noise.next() * noiseGain }
        return mic.map { min(1, max(-1, $0)) }
    }

    /// Seconds into `samples` of the first 10 ms block louder than -45 dBFS RMS.
    static func firstVoiced(_ samples: [Float], sampleRate: Int) -> TimeInterval? {
        let block = max(1, sampleRate / 100)
        var start = 0
        while start < samples.count {
            let level = AudioLevel.measure(samples[start..<min(samples.count, start + block)])
            if level.rmsDB > -45 { return Double(start) / Double(sampleRate) }
            start += block
        }
        return nil
    }

    /// RMS over the 10 ms blocks louder than -45 dBFS (the speech, not the pauses).
    static func voicedRMS(_ samples: [Float], sampleRate: Int) -> Float {
        let block = max(1, sampleRate / 100)
        var sum: Double = 0
        var count = 0
        var start = 0
        while start < samples.count {
            let slice = samples[start..<min(samples.count, start + block)]
            if AudioLevel.measure(slice).rmsDB > -45 {
                for sample in slice { sum += Double(sample * sample) }
                count += slice.count
            }
            start += block
        }
        return count == 0 ? 0 : Float((sum / Double(count)).squareRoot())
    }

    static func decibels(_ db: Float) -> Float { pow(10, db / 20) }

    /// Uniform noise in -1…1 from a fixed seed, so every run sees the same room.
    struct NoiseSource {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) & 0xFFFFFF) / Float(0x7FFFFF) - 1
        }
    }
}
