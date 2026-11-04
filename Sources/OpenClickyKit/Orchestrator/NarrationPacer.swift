import Foundation

/// Keeps a drawing in step with the voice beyond line starts: it holds the pen while the narration pauses and tells the
/// drawing how many words have been heard so far.
///
/// - A **gap**: a line finished and the next one hasn't started within `Policy.gap` (the brain is still writing it, or
///   the voice is still synthesizing it). The drawing pauses and carries on when the next line is heard.
/// - A **stall**: a line is playing but its audio stopped advancing for `Policy.stall` (the voice is sending audio more
///   slowly than it plays). The drawing pauses until the audio moves again.
/// - **Spoken words**: a running count across the answer's lines, from the playback position and `CaptionWords`'
///   timing within the line being heard. The count never passes the line's last word before the line finishes, so the
///   engine's `spoken(count)` never ends a line early.
///
/// Feed it the lines as the brain finishes them (`line(_:_:)`), the voice's line starts and finishes, and `tick()` it a
/// few dozen times a second while the narration runs; `finish()` once the narration is over (or cut off).
@MainActor
public final class NarrationPacer {
    public struct Policy: Sendable, Hashable {
        /// Seconds without a line playing, after one finished, before the drawing pauses.
        public var gap: TimeInterval
        /// Seconds a playing line's audio may stand still before the drawing pauses.
        public var stall: TimeInterval
        /// How often `run` ticks.
        public var tickInterval: TimeInterval
        public var wordsPerSecond: Double

        public init(gap: TimeInterval = 0.3, stall: TimeInterval = 0.35, tickInterval: TimeInterval = 0.04, wordsPerSecond: Double = 2.6) {
            self.gap = gap
            self.stall = stall
            self.tickInterval = tickInterval
            self.wordsPerSecond = wordsPerSecond
        }
    }

    /// Why the drawing was paused.
    public enum Hold: String, Sendable, Hashable {
        /// Between lines.
        case gap
        /// The line's audio stopped advancing.
        case stall
    }

    /// What the pacer told the drawing, in order (logs, tests and `occtl turn`'s evidence).
    public enum Beat: Sendable, Hashable, CustomStringConvertible {
        case paused(Hold)
        case resumed
        case spoken(Int)

        public var description: String {
            switch self {
            case .paused(let hold): "paused (\(hold.rawValue))"
            case .resumed: "resumed"
            case .spoken(let count): "spoken \(count)"
            }
        }
    }

    public let policy: Policy
    /// The drawing being paced; may be set after the first lines were heard.
    public var drawing: (any TurnDrawing)? {
        didSet {
            guard let drawing, drawing !== oldValue else { return }
            // A drawing that joins late hears the count so far and whether the pen is held.
            if spoken > 0 { drawing.wordsSpoken(spoken) }
            if hold != nil { drawing.pause() }
        }
    }
    public var onBeat: ((Beat) -> Void)?
    public private(set) var beats: [Beat] = []
    public private(set) var spoken = 0
    public private(set) var hold: Hold?

    private let position: () -> SpeechPlayer.Position?
    private let now: () -> TimeInterval
    private var lines: [Int: String] = [:]
    private var playing: Int?
    private var lastElapsed: TimeInterval = 0
    private var lastProgressAt: TimeInterval = 0
    private var finishedAt: TimeInterval?
    private var finished = false
    private var runner: Task<Void, Never>?

    /// - Parameters:
    ///   - position: Where playback is in the line being heard (`SpeechPlayer.position()`).
    ///   - now: Seconds on any steady clock.
    public init(policy: Policy = Policy(), position: @escaping () -> SpeechPlayer.Position?,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.policy = policy
        self.position = position
        self.now = now
    }

    /// The brain finished line `index`.
    public func line(_ index: Int, _ text: String) { lines[index] = text }

    public func lineStarted(_ index: Int) {
        guard !finished else { return }
        playing = index
        lastElapsed = 0
        lastProgressAt = now()
        finishedAt = nil
        if hold != nil { release() }
    }

    public func lineFinished(_ index: Int) {
        guard !finished else { return }
        if playing == index { playing = nil }
        finishedAt = now()
        if hold == .stall { release() }
        report(words(before: index + 1))
    }

    /// Checks the playback once: a gap or a stall pauses the drawing, audio moving again resumes it, and the words
    /// heard so far go to the drawing.
    public func tick() {
        guard !finished else { return }
        let t = now()
        if let index = playing {
            if let at = position(), at.lineIndex == index {
                if at.elapsed > lastElapsed + 0.004 {
                    lastElapsed = at.elapsed
                    lastProgressAt = t
                    if hold == .stall { release() }
                } else if hold == nil, t - lastProgressAt >= policy.stall {
                    pause(.stall)
                }
                let text = lines[index] ?? ""
                let caption = CaptionWords(text)
                let heard = caption.revealed(elapsed: at.elapsed, duration: at.duration, wordsPerSecond: policy.wordsPerSecond)
                // The last word counts once the line has finished.
                report(words(before: index) + min(heard, max(0, caption.words.count - 1)))
            } else if hold == nil, t - lastProgressAt >= policy.stall {
                // Started but nothing audible yet (or the player moved on without telling us).
                pause(.stall)
            }
        } else if hold == nil, let finishedAt, t - finishedAt >= policy.gap {
            pause(.gap)
        }
    }

    /// The narration is over (heard to the end, or cut off): the pen is never left held.
    public func finish() {
        guard !finished else { return }
        if hold != nil { release() }
        finished = true
        runner?.cancel()
        runner = nil
    }

    /// Ticks every `policy.tickInterval` until `finish()`.
    public func run() {
        guard runner == nil, !finished else { return }
        let interval = policy.tickInterval
        runner = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    // MARK: Helpers

    /// Words in lines `0..<index` (lines not known yet count as none).
    private func words(before index: Int) -> Int {
        guard index > 0 else { return 0 }
        return (0..<index).reduce(0) { $0 + (lines[$1].map { CaptionWords($0).words.count } ?? 0) }
    }

    private func report(_ count: Int) {
        guard count > spoken else { return }
        spoken = count
        drawing?.wordsSpoken(count)
        record(.spoken(count))
    }

    private func pause(_ reason: Hold) {
        hold = reason
        drawing?.pause()
        record(.paused(reason))
    }

    private func release() {
        hold = nil
        drawing?.resume()
        record(.resumed)
    }

    private func record(_ beat: Beat) {
        beats.append(beat)
        onBeat?(beat)
    }
}
