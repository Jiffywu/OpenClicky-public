import Foundation

/// Speaks a turn's `say` lines through the voice slot, one line at a time and in order, into a `SpeechPlayer`, and
/// reports when each line is actually heard (for drawing pace and captions).
///
/// - Lines are synthesized one after another: line 2's request goes out when line 1's audio has all arrived. The
///   player plays them back to back.
/// - Health check: a line whose voice sends no audio within `Policy.firstAudioTimeout` (an open but dead connection),
///   or fails before any audio, makes the narrator reopen the voice (`stopAll()` then `warmUp()`) and send the line
///   again.
/// - Fallback: if that fails too, the line and every line after it are spoken by another configured cloud voice (the
///   `alternate`, when there is one) for `Policy.fallbackPeriod`, then the voice slot is tried again. If the alternate
///   fails as well, the fallback voice (the on-device Apple voice) takes over for the rest of that period.
/// - A line no voice could speak still takes its turn as silence about as long as it would have taken to say, so the
///   drawing keeps its pace and the caption shows.
///
/// The narrator owns the player's `onEvent`; use one narrator per player. Another user of the player (always-on
/// voice) calls `release()` first.
public final class LineNarrator: @unchecked Sendable {
    public struct Policy: Sendable, Hashable {
        /// Seconds a line may take to deliver its first audio before the voice counts as dead.
        public var firstAudioTimeout: TimeInterval
        /// Times a line is sent again on a reopened voice before falling back.
        public var resendAttempts: Int
        /// How long the fallback voice stays in use after the voice slot failed.
        public var fallbackPeriod: TimeInterval
        /// Speaking rate used to size the silence for a line nothing could say.
        public var wordsPerSecond: Double

        public init(firstAudioTimeout: TimeInterval = 5, resendAttempts: Int = 1, fallbackPeriod: TimeInterval = 600,
                    wordsPerSecond: Double = 2.6) {
            self.firstAudioTimeout = firstAudioTimeout
            self.resendAttempts = resendAttempts
            self.fallbackPeriod = fallbackPeriod
            self.wordsPerSecond = wordsPerSecond
        }
    }

    public enum Event: Sendable, Hashable {
        /// The voice delivered the first audio of line `index`, `delay` seconds after the line was handed over.
        case firstAudio(index: Int, delay: TimeInterval)
        case lineStarted(index: Int, expectedDuration: TimeInterval?)
        case lineFinished(index: Int)
        /// Barge-in cut line `index` after `playedAudio` seconds.
        case lineCut(index: Int, playedAudio: TimeInterval)
        /// The voice looked dead on line `index`; it was reopened and the line sent again.
        case reopened(index: Int, reason: String)
        /// The voice slot failed; the fallback voice speaks from line `index` on.
        case fellBack(index: Int, reason: String)
        /// No voice could speak line `index`; it passed as silence.
        case lineFailed(index: Int, reason: String)
        /// Every line handed over so far has been heard.
        case drained
    }

    public let player: SpeechPlayer
    public let policy: Policy
    /// The voice name passed to the voice slot (nil: the slot's default).
    public var voiceName: String? {
        get { lock.withLock { _voiceName } }
        set { lock.withLock { _voiceName = newValue } }
    }

    private let primary: any SpeechOutputClient
    /// The voices tried after the voice slot, in order: the alternate cloud voice, then the fallback.
    private let tiers: [FallbackVoice]
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let lock = NSLock()
    private var _voiceName: String?
    private var fallbackUntil: Date?
    /// Which of `tiers` is speaking while `fallbackUntil` lasts.
    private var fallbackTier = 0
    private var current: Narration?

    /// A voice the narrator falls back to, with the voice name it is asked for (nil: its own default).
    struct FallbackVoice: Sendable {
        var client: any SpeechOutputClient
        var voiceName: String?
    }

    /// - Parameters:
    ///   - voice: The voice slot.
    ///   - fallback: The last resort, usually the on-device Apple voice.
    ///   - alternate: Another configured cloud voice, tried before `fallback` when the voice slot fails (HeyClicky
    ///     falls back to its other cloud provider first). `alternateVoiceName` is the voice it is asked for.
    public init(voice: any SpeechOutputClient, fallback: (any SpeechOutputClient)?, player: SpeechPlayer, voiceName: String? = nil,
                alternate: (any SpeechOutputClient)? = nil, alternateVoiceName: String? = nil,
                policy: Policy = Policy(), now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.primary = voice
        self.hasAlternate = alternate != nil
        self.tiers = [alternate.map { FallbackVoice(client: $0, voiceName: alternateVoiceName) },
                      fallback.map { FallbackVoice(client: $0, voiceName: nil) }].compactMap { $0 }
        self.player = player
        self._voiceName = voiceName
        self.policy = policy
        self.now = now
        self.sleep = sleep
        player.onEvent = { [weak self] event in self?.route(event) }
    }

    /// True while a fallback voice (the alternate or the last resort) is speaking for the voice slot.
    public var isUsingFallback: Bool {
        lock.withLock { fallbackUntil.map { now() < $0 } ?? false }
    }

    /// True while the alternate cloud voice is the one speaking for the voice slot.
    public var isUsingAlternate: Bool {
        hasAlternate && activeClient().tier == 0
    }

    private let hasAlternate: Bool

    /// Opens the voice's connection ahead of the first line (key-down).
    public func warmUp() async {
        await activeClient().client.warmUp()
    }

    /// Starts narrating a new turn. A narration still running is stopped first. `pacing` hears each line start and
    /// finish as it is heard (set or change it later with `Narration.pacing`); `onEvent` gets every event on the
    /// audio queue, in order.
    public func begin(pacing: (any SpeechPacing)? = nil, onEvent: (@Sendable (Event) -> Void)? = nil) -> Narration {
        let previous = lock.withLock { current }
        previous?.stop()
        let narration = Narration(narrator: self, pacing: pacing, onEvent: onEvent)
        lock.withLock { current = narration }
        return narration
    }

    /// Something else is about to play through the same player (always-on voice): stops the current narration, if
    /// any, and stops routing player events to it, so the other user's lines don't reach the last turn's drawing.
    /// The next `begin` takes the player back.
    public func release() {
        let previous = lock.withLock { () -> Narration? in
            defer { current = nil }
            return current
        }
        previous?.stop()
    }

    // MARK: Internals used by Narration

    /// The voice speaking now: the voice slot (tier nil), or fallback tier `n` while the fallback period lasts.
    fileprivate func activeClient() -> (client: any SpeechOutputClient, tier: Int?) {
        let tier = lock.withLock { () -> Int? in
            guard let until = fallbackUntil, now() < until, fallbackTier < tiers.count else { return nil }
            return fallbackTier
        }
        guard let tier else { return (primary, nil) }
        return (tiers[tier].client, tier)
    }

    /// The voice to try after `tier` failed (nil: the voice slot failed), or nil when there is none left.
    fileprivate func nextTier(after tier: Int?) -> Int? {
        let next = tier.map { $0 + 1 } ?? 0
        return next < tiers.count ? next : nil
    }

    fileprivate func client(forTier tier: Int) -> any SpeechOutputClient { tiers[tier].client }

    /// The voice name to ask for: the slot's, or the fallback tier's own.
    fileprivate func voiceName(forTier tier: Int?) -> String? {
        guard let tier else { return voiceName }
        return tiers[tier].voiceName
    }

    /// Fallback tier `tier` speaks until the fallback period ends. The period starts when the voice slot fails; a
    /// later tier taking over (the alternate failed too) keeps it, so the slot is tried again on time.
    fileprivate func activateFallback(tier: Int) {
        lock.withLock {
            if !(fallbackUntil.map { now() < $0 } ?? false) { fallbackUntil = now().addingTimeInterval(policy.fallbackPeriod) }
            fallbackTier = tier
        }
    }

    fileprivate func timestamp() -> Date { now() }

    fileprivate func pause(_ seconds: TimeInterval) async throws { try await sleep(seconds) }

    /// Player events go to the narration that owns the player right now. Called on the audio queue.
    private func route(_ event: SpeechPlayer.Event) {
        let target = lock.withLock { current }
        target?.handle(event)
    }
}

/// What a narration did.
public struct NarrationReport: Sendable, Hashable {
    /// Lines handed to the voice, in order.
    public var queued: [Int] = []
    /// Lines heard starting / finishing.
    public var started: [Int] = []
    public var finished: [Int] = []
    /// The line playing when `stop()` cut it, and how much of it was heard.
    public var cutLine: Int?
    public var playedAudio: TimeInterval = 0
    /// Lines that passed as silence because no voice could speak them.
    public var failedLines: [Int] = []
    /// Lines the fallback voice spoke.
    public var fallbackLines: [Int] = []
    /// Lines sent again on a reopened voice.
    public var resentLines: [Int] = []
    public var stopped = false
    /// Seconds from handing each line to the voice to its first audio.
    public var firstAudioDelays: [Int: TimeInterval] = [:]
    /// Seconds of audio delivered per line.
    public var audioSeconds: [Int: TimeInterval] = [:]

    public init() {}

    /// Whether every queued line was heard to its end.
    public var heardEverything: Bool { !stopped && Set(finished).isSuperset(of: queued) }
}

/// One turn's narration. Hand it lines as the brain finishes them, `close()` when the brain is done, then wait for
/// `waitUntilDone()`; or `stop()` it for barge-in.
public final class Narration: @unchecked Sendable {
    private weak var narrator: LineNarrator?
    private let player: SpeechPlayer
    private let onEvent: (@Sendable (Event) -> Void)?
    private let lock = NSLock()
    private var _pacing: (any SpeechPacing)?
    private var report = NarrationReport()
    private var stopped = false
    private let input: AsyncStream<(Int, String)>.Continuation
    private var worker: Task<Void, Never>?
    private var queuedAt: [Int: Date] = [:]

    public typealias Event = LineNarrator.Event

    fileprivate init(narrator: LineNarrator, pacing: (any SpeechPacing)?, onEvent: (@Sendable (Event) -> Void)?) {
        self.narrator = narrator
        self.player = narrator.player
        self.onEvent = onEvent
        self._pacing = pacing
        let (stream, continuation) = AsyncStream<(Int, String)>.makeStream()
        self.input = continuation
        worker = Task { [weak self] in
            for await (index, text) in stream {
                guard let self, !self.isStopped else { return }
                await self.speak(index, text)
            }
        }
    }

    /// Where line starts and finishes go (the drawing). May be set after lines were queued.
    public var pacing: (any SpeechPacing)? {
        get { lock.withLock { _pacing } }
        set { lock.withLock { _pacing = newValue } }
    }

    public var isStopped: Bool { lock.withLock { stopped } }

    /// The brain finished line `index`.
    public func say(_ index: Int, _ text: String) {
        let accepted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            report.queued.append(index)
            queuedAt[index] = narrator?.timestamp() ?? Date()
            return true
        }
        if accepted { input.yield((index, text)) }
    }

    /// No more lines are coming.
    public func close() { input.finish() }

    /// Waits until every line has been synthesized and heard (or the narration was stopped).
    public func waitUntilDone() async -> NarrationReport {
        await worker?.value
        if !isStopped {
            await player.waitUntilDrained()
            // The player wakes drain waiters just before it hands out the last line's events; give them a moment to
            // arrive so the drawing hears the last line finish before anything else happens.
            for _ in 0..<50 {
                let caughtUp = lock.withLock { stopped || Set(report.finished).isSuperset(of: report.queued) }
                if caughtUp { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return snapshot()
    }

    /// Barge-in: silences the voice at once, cancels the line being synthesized and drops the rest.
    @discardableResult
    public func stop() -> NarrationReport {
        let already = lock.withLock { () -> Bool in
            defer { stopped = true }
            return stopped
        }
        guard !already else { return snapshot() }
        input.finish()
        worker?.cancel()
        let cut = player.stop()
        lock.withLock {
            report.stopped = true
            report.cutLine = cut.cutLine
            report.playedAudio = cut.playedAudio
        }
        return snapshot()
    }

    public func snapshot() -> NarrationReport { lock.withLock { report } }

    // MARK: Player events (audio queue)

    fileprivate func handle(_ event: SpeechPlayer.Event) {
        let pacing: (any SpeechPacing)?
        let forwarded: Event?
        switch event {
        case .lineStarted(let index, let expected):
            pacing = lock.withLock { report.started.append(index); return _pacing }
            pacing?.lineStarted(index, expectedDuration: expected)
            forwarded = .lineStarted(index: index, expectedDuration: expected)
        case .lineFinished(let index):
            pacing = lock.withLock { report.finished.append(index); return _pacing }
            pacing?.lineFinished(index)
            forwarded = .lineFinished(index: index)
        case .lineCut(let index, let played):
            forwarded = .lineCut(index: index, playedAudio: played)
        case .drained:
            forwarded = .drained
        case .stopped, .outputRestarted, .outputFailed:
            forwarded = nil
        }
        if let forwarded { onEvent?(forwarded) }
    }

    // MARK: Speaking one line

    private enum Attempt {
        case delivered
        /// The voice failed after some audio was already playing; what arrived stays.
        case partial
        case silent(String)
        case failed(String)
        case cancelled
    }

    private func speak(_ index: Int, _ text: String) async {
        guard let narrator else { return }
        var (client, tier) = narrator.activeClient()
        var resends = 0
        while !Task.isCancelled, !isStopped {
            let attempt = await synthesize(index, text, with: client, tier: tier)
            switch attempt {
            case .delivered, .partial, .cancelled:
                return
            case .silent(let reason), .failed(let reason):
                if tier == nil, resends < narrator.policy.resendAttempts {
                    resends += 1
                    lock.withLock { report.resentLines.append(index) }
                    onEvent?(.reopened(index: index, reason: reason))
                    await client.stopAll()
                    await client.warmUp()
                    continue
                }
                // The slot (or the alternate) failed: the next voice in line takes this line and the ones after it.
                if let next = narrator.nextTier(after: tier) {
                    narrator.activateFallback(tier: next)
                    onEvent?(.fellBack(index: index, reason: reason))
                    client = narrator.client(forTier: next)
                    tier = next
                    continue
                }
                lock.withLock { report.failedLines.append(index) }
                onEvent?(.lineFailed(index: index, reason: reason))
                speakSilently(index, text, wordsPerSecond: narrator.policy.wordsPerSecond)
                return
            }
        }
    }

    /// One try at a line: audio goes to the player as it arrives. The line begins in the player only when its first
    /// audio arrives, so a try that fails before any audio can be repeated cleanly.
    private func synthesize(_ index: Int, _ text: String, with client: any SpeechOutputClient, tier: Int?) async -> Attempt {
        guard let narrator else { return .cancelled }
        let fallback = tier != nil
        let voice = narrator.voiceName(forTier: tier)
        let timeout = narrator.policy.firstAudioTimeout
        let watch = AttemptWatch()
        let reader = Task { [player] () -> Attempt in
            var handle: SpeechPlayer.Line?
            var frames: [PCMFormat: Int] = [:]
            func close() {
                if let handle { player.finishLine(handle) }
                var seconds = 0.0
                for (format, bytes) in frames { seconds += Double(bytes) / Double(max(1, format.bytesPerSecond)) }
                self.lock.withLock { self.report.audioSeconds[index] = seconds }
            }
            do {
                reading: for try await event in client.speak(text, voice: voice, instructions: nil) {
                    switch event {
                    case .audio(let pcm, let format):
                        guard !pcm.isEmpty else { continue }
                        guard !self.isStopped, !Task.isCancelled else { break reading }
                        if handle == nil {
                            guard watch.claimAudio() else { break reading }
                            handle = player.beginLine(index)
                            let delay = self.lock.withLock { () -> TimeInterval in
                                let delay = narrator.timestamp().timeIntervalSince(self.queuedAt[index] ?? narrator.timestamp())
                                self.report.firstAudioDelays[index] = delay
                                if fallback { self.report.fallbackLines.append(index) }
                                return delay
                            }
                            self.onEvent?(.firstAudio(index: index, delay: delay))
                        }
                        if let handle { player.append(pcm, format: format, to: handle) }
                        frames[format, default: 0] += pcm.count
                    case .lineFinished:
                        break reading
                    }
                }
            } catch is CancellationError {
                close()
                return .cancelled
            } catch {
                close()
                return handle == nil ? .failed(Self.describe(error)) : .partial
            }
            close()
            if handle != nil { return .delivered }
            if watch.timedOut { return .silent("no audio after \(String(format: "%.1f", timeout)) s") }
            if Task.isCancelled || self.isStopped { return .cancelled }
            return .silent("the voice sent no audio")
        }
        let watchdog = Task { [narrator] in
            try? await narrator.pause(timeout)
            guard !Task.isCancelled, watch.timeOut() else { return }
            reader.cancel()
        }
        let attempt = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        watchdog.cancel()
        if case .cancelled = attempt, watch.timedOut, !isStopped { return .silent("no audio after \(String(format: "%.1f", timeout)) s") }
        return attempt
    }

    /// A line nothing could say still takes its turn, as silence about as long as saying it would take.
    private func speakSilently(_ index: Int, _ text: String, wordsPerSecond: Double) {
        guard !isStopped else { return }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let seconds = min(12, max(0.6, Double(words) / max(0.5, wordsPerSecond)))
        let format = PCMFormat(sampleRate: player.sampleRate)
        let silence = Data(count: Int(seconds * Double(format.sampleRate)) * 2)
        player.play(silence, format: format, line: index)
    }

    static func describe(_ error: Error) -> String {
        if let provider = error as? ProviderError { return provider.description }
        return String(describing: error)
    }
}

/// Decides, once, whether a try timed out before its first audio or got audio in time.
private final class AttemptWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var gotAudio = false
    private var expired = false

    /// The first audio arrived; false if the watchdog already gave up on this try.
    func claimAudio() -> Bool {
        lock.withLock {
            if expired { return false }
            gotAudio = true
            return true
        }
    }

    /// The timeout passed; false if audio already arrived.
    func timeOut() -> Bool {
        lock.withLock {
            if gotAudio { return false }
            expired = true
            return true
        }
    }

    var timedOut: Bool { lock.withLock { expired } }
}
