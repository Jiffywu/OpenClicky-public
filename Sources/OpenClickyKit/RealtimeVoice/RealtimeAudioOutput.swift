import Foundation

/// Where the conversation plays the model's voice. The app uses `SpeechPlayerRealtimeOutput`; headless runs and tests
/// use `RecordingRealtimeOutput`, which keeps the audio (for a WAV) and keeps time like a speaker would.
public protocol RealtimeAudioOutput: AnyObject, Sendable {
    /// Queues reply audio (PCM16 in `format`) for an assistant item. Items play in the order they first get audio.
    func enqueue(_ pcm: Data, format: PCMFormat, itemID: String)
    /// No more audio is coming for this item.
    func finishItem(_ itemID: String)
    /// Stops at once and drops everything queued. Reports the item that was playing and how much of it was heard.
    func stop() -> (itemID: String?, heard: TimeInterval)
    /// Audio is queued or playing.
    var isPlaying: Bool { get }
    /// Returns when everything queued so far has played (at once when idle or after `stop()`).
    func waitUntilDrained() async
}

/// The app's voice output: one `SpeechPlayer` line per assistant item, so a barge-in reports exactly how much of the
/// item the user heard (for truncation). Share the microphone's `AudioEngineHost` with the player so echo cancellation
/// hears the voice.
public final class SpeechPlayerRealtimeOutput: RealtimeAudioOutput, @unchecked Sendable {
    public let player: SpeechPlayer
    private let lock = NSLock()
    private var lines: [String: SpeechPlayer.Line] = [:]
    private var itemsByLine: [Int: String] = [:]
    private var nextLine = 0
    private var lastItem: String?

    public init(player: SpeechPlayer) { self.player = player }

    public func enqueue(_ pcm: Data, format: PCMFormat, itemID: String) {
        let line: SpeechPlayer.Line = lock.withLock {
            if let line = lines[itemID] { return line }
            let line = player.beginLine(nextLine)
            itemsByLine[nextLine] = itemID
            nextLine += 1
            lines[itemID] = line
            lastItem = itemID
            return line
        }
        player.append(pcm, format: format, to: line)
    }

    public func finishItem(_ itemID: String) {
        guard let line = lock.withLock({ lines[itemID] }) else { return }
        player.finishLine(line)
    }

    public func stop() -> (itemID: String?, heard: TimeInterval) {
        let report = player.stop()
        return lock.withLock {
            let item = report.cutLine.flatMap { itemsByLine[$0] } ?? (report.droppedLines.isEmpty ? nil : lastItem)
            lines.removeAll()
            itemsByLine.removeAll()
            return (item, report.cutLine == nil ? 0 : report.playedAudio)
        }
    }

    public var isPlaying: Bool { !player.isIdle }

    public func waitUntilDrained() async { await player.waitUntilDrained() }
}

/// Keeps every reply's audio instead of playing it, and keeps time as if a speaker were playing it from the moment it
/// arrives: `isPlaying`, `stop()`'s heard time and `waitUntilDrained()` all follow that clock. With `realTime: false`
/// audio "plays" instantly, so tests and quick runs never wait.
public final class RecordingRealtimeOutput: RealtimeAudioOutput, @unchecked Sendable {
    public struct Segment: Sendable, Hashable {
        public var itemID: String
        public var start: TimeInterval
        public var pcm: Data
        public var format: PCMFormat
        public var duration: TimeInterval { Double(pcm.count) / Double(max(format.bytesPerSecond, 1)) }
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let realTime: Bool
    private var segments: [Segment] = []
    private var playEnd: TimeInterval = 0
    private var cuts: [TimeInterval] = []
    private var format: PCMFormat?
    private var stops = 0

    public init(realTime: Bool = true, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.realTime = realTime
        self.clock = clock
    }

    public func enqueue(_ pcm: Data, format: PCMFormat, itemID: String) {
        lock.withLock {
            let now = clock()
            let start = realTime ? max(now, playEnd) : now
            let segment = Segment(itemID: itemID, start: start, pcm: pcm, format: format)
            segments.append(segment)
            self.format = format
            playEnd = realTime ? start + segment.duration : now
        }
    }

    public func finishItem(_ itemID: String) {}

    public func stop() -> (itemID: String?, heard: TimeInterval) {
        lock.withLock {
            stops += 1
            let now = clock()
            guard realTime, playEnd > now else { return (nil, 0) }
            // The item being heard now, and how far into it the listener is.
            let current = segments.last { $0.start <= now } ?? segments.last
            guard let item = current?.itemID else { return (nil, 0) }
            let itemStart = segments.first { $0.itemID == item }?.start ?? now
            cuts.append(now)
            playEnd = now
            return (item, max(0, now - itemStart))
        }
    }

    public var isPlaying: Bool { lock.withLock { realTime && playEnd > clock() } }

    public func waitUntilDrained() async {
        while true {
            let remaining = lock.withLock { realTime ? playEnd - clock() : 0 }
            if remaining <= 0 { return }
            try? await Task.sleep(for: .milliseconds(Int(min(remaining, 0.25) * 1000) + 1))
            if Task.isCancelled { return }
        }
    }

    public var allSegments: [Segment] { lock.withLock { segments } }
    public var stopCount: Int { lock.withLock { stops } }

    /// Everything received, back to back.
    public var receivedAudio: (pcm: Data, format: PCMFormat?) {
        lock.withLock { (segments.reduce(into: Data()) { $0.append($1.pcm) }, format) }
    }

    /// What a listener would have heard: a segment playing when `stop()` ran is cut off at that moment.
    public var heardAudio: (pcm: Data, format: PCMFormat?) {
        lock.withLock {
            var pcm = Data()
            for segment in segments {
                if let cut = cuts.first(where: { $0 > segment.start }), segment.start + segment.duration > cut {
                    let bytes = Int((cut - segment.start) * Double(segment.format.bytesPerSecond))
                    pcm.append(segment.pcm.prefix(max(0, bytes - bytes % 2)))
                } else {
                    pcm.append(segment.pcm)
                }
            }
            return (pcm, format)
        }
    }
}
