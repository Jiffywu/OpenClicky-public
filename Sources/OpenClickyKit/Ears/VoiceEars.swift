import Foundation

/// The voice loop's ears: the stt slot's client for every push-to-talk press, plus what HeyClicky's ears do around it
/// (docs/re/02-voice-pipeline.md §4.2–4.4, docs/latency.md):
///
/// - **Warm socket.** One client is kept across presses, and while the ears were used recently (`Policy.keepWarmAfterUse`,
///   the last use is remembered across launches) a connection is kept open ahead of key-down, refreshed after every
///   press, at launch, on wake and before the provider's idle limit. A press that lands on it skips the connection
///   and setup round trips.
/// - **Press audio kept.** Every chunk of the press is recorded. When the stream fails, or hasn't settled
///   `Policy.finalTimeout` after key-up, the recording goes through the fallbacks in one pass (a batch transcription
///   of the same provider, then the on-device recognizer).
/// - **Refusal switch.** When the stt account refuses for billing, credit or quota, or the provider doesn't serve the
///   user's region (`ProviderDiagnostician`'s `regionUnsupported`), presses go to the alternate recognizer (and
///   fallbacks that don't share the account) for `Policy.refusalSwitch` (ten minutes).
/// - **Per-press timings.** Each press ends with an `EarsPressReport` (`onReport`, `lastReport`, and the session's
///   `EarsPressReporting`, which the turn orchestrator adds to the turn's timings).
///
/// The ears are a `SpeechToTextClient`: hand them to `TurnOrchestrator.Services.speechToText`. Each session streams
/// interim text as the running transcript and ends with one final holding the whole press.
public actor VoiceEars: SpeechToTextClient {
    public struct Policy: Sendable, Hashable {
        /// After key-up, how long the stream may take to settle before the press goes to the fallbacks.
        public var finalTimeout: Duration
        /// The longest all fallbacks together may take.
        public var fallbackTimeout: Duration
        /// How long presses avoid the stt slot after it refused for billing, credit or quota.
        public var refusalSwitch: TimeInterval
        /// Keep a connection open ahead of key-down while the last press is at most this old.
        public var keepWarmAfterUse: TimeInterval
        /// How often the warm connection is checked, and reopened when the provider closed it or it would close
        /// before the next check.
        public var rewarmInterval: Duration

        public init(finalTimeout: Duration = .seconds(3), fallbackTimeout: Duration = .seconds(6), refusalSwitch: TimeInterval = 10 * 60,
                    keepWarmAfterUse: TimeInterval = 15 * 60, rewarmInterval: Duration = .seconds(60)) {
            self.finalTimeout = finalTimeout
            self.fallbackTimeout = fallbackTimeout
            self.refusalSwitch = refusalSwitch
            self.keepWarmAfterUse = keepWarmAfterUse
            self.rewarmInterval = rewarmInterval
        }
    }

    /// A second chance for a press whose stream failed.
    public struct Fallback: Sendable {
        public var name: String
        public var client: any SpeechToTextBatchClient
        /// Bills the same account as the stt slot (skipped while that account is refusing).
        public var sharesPrimaryAccount: Bool

        public init(name: String, client: any SpeechToTextBatchClient, sharesPrimaryAccount: Bool) {
            self.name = name
            self.client = client
            self.sharesPrimaryAccount = sharesPrimaryAccount
        }
    }

    /// A recognizer to stream to: the stt slot's, or the alternate.
    public struct Recognizer: Sendable {
        public var name: String
        public var client: any SpeechToTextClient

        public init(name: String, client: any SpeechToTextClient) {
            self.name = name
            self.client = client
        }
    }

    /// Where the time of the last press is kept, so a relaunch knows whether the ears are in use.
    public struct UsageStore: Sendable {
        public var load: @Sendable () -> Date?
        public var save: @Sendable (Date) -> Void

        public init(load: @escaping @Sendable () -> Date?, save: @escaping @Sendable (Date) -> Void) {
            self.load = load
            self.save = save
        }

        /// Kept in memory only (tests, `occtl`).
        public static func memory(_ initial: Date? = nil) -> UsageStore {
            let box = LockedValue<Date?>(initial)
            return UsageStore(load: { box.get() }, save: { box.set($0) })
        }

        /// Kept in the user defaults under `key` (the app).
        public static func userDefaults(key: String = "openclicky.ears.lastUsedAt.v1") -> UsageStore {
            UsageStore(load: { UserDefaults.standard.object(forKey: key) as? Date },
                       save: { UserDefaults.standard.set($0, forKey: key) })
        }
    }

    /// Why the warm connection is being refreshed (for logs).
    public enum WarmReason: String, Sendable {
        case launch, wake, afterPress = "after press", manual
    }

    public nonisolated let inputFormat: PCMFormat
    public nonisolated let primary: Recognizer
    public nonisolated let alternate: Recognizer?
    private let fallbacks: [Fallback]
    private let policy: Policy
    private let usage: UsageStore
    private let now: @Sendable () -> Date
    private var language: String?
    private var keywords: [String]
    private var refusedUntil: Date?
    private var keepWarmTask: Task<Void, Never>?
    private var reportHandler: (@Sendable (EarsPressReport) -> Void)?
    private var logHandler: (@Sendable (String) -> Void)?
    /// The last finished press.
    public private(set) var lastReport: EarsPressReport?

    /// - Parameters:
    ///   - primary: The stt slot's client (one instance for the life of the ears: it holds the warm connection).
    ///   - alternate: Streams presses while the stt account is refusing (usually the on-device recognizer). Nil sends
    ///     those presses to the fallbacks only.
    ///   - fallbacks: Tried in order on a press's recording when its stream fails.
    ///   - language, keywords: What the first warm connection is opened for; each press's own settings replace them.
    public init(primary: Recognizer, alternate: Recognizer? = nil, fallbacks: [Fallback] = [], policy: Policy = Policy(),
                usage: UsageStore = .memory(), language: String? = nil, keywords: [String] = [],
                now: @escaping @Sendable () -> Date = Date.init) {
        self.primary = primary
        self.alternate = alternate
        self.fallbacks = fallbacks
        self.policy = policy
        self.usage = usage
        self.language = language
        self.keywords = keywords
        self.now = now
        inputFormat = primary.client.inputFormat
    }

    deinit { keepWarmTask?.cancel() }

    /// Every finished press (on the ears' executor; hop to the main actor yourself).
    public func setReportHandler(_ handler: (@Sendable (EarsPressReport) -> Void)?) { reportHandler = handler }

    /// Warm-connection and refusal-switch events, for logs.
    public func setLogHandler(_ handler: (@Sendable (String) -> Void)?) { logHandler = handler }

    // MARK: - SpeechToTextClient

    public func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        self.language = language
        self.keywords = keywords
        let at = now()
        usage.save(at)
        let refusing = isRefusing(at: at)
        let recognizer: Recognizer? = refusing ? alternate : primary
        let usable = refusing ? fallbacks.filter { !$0.sharesPrimaryAccount } : fallbacks
        let session = EarsPressSession(ears: self, recognizer: recognizer, switched: refusing, fallbacks: usable, format: inputFormat,
                                       language: language, keywords: keywords, policy: policy, now: now)
        await session.start()
        return session
    }

    // MARK: - Warm connection

    /// What the next warm connection is opened for, before any press has set it: a warm socket only serves a press with
    /// the same language and keywords (dictation's vocabulary), so a caller that knows them sets them first.
    public func expect(language: String?, keywords: [String]) {
        self.language = language
        self.keywords = keywords
    }

    /// Opens (or keeps) a connection for the next press when the ears were used within `Policy.keepWarmAfterUse`,
    /// and keeps it open while they stay in use. Call at launch and on wake; presses call it themselves.
    public func refresh(_ reason: WarmReason) async {
        guard let warming = primary.client as? any SpeechToTextWarming else { return }
        let at = now()
        guard !isRefusing(at: at), let last = usage.load(), at.timeIntervalSince(last) <= policy.keepWarmAfterUse else {
            stopKeepingWarm()
            return
        }
        await warming.warmUp(language: language, keywords: keywords)
        log("ears: connection opened ahead of the next press (\(reason.rawValue))")
        keepWarm()
    }

    /// Opens a connection for the next press now, whatever the last use (`occtl turn`, onboarding). With `waitUntilReady`
    /// it returns once the provider has set the connection up (true), as it would be long before a real press.
    @discardableResult
    public func warmUpNow(waitUntilReady: Bool = false) async -> Bool {
        usage.save(now())
        await refresh(.manual)
        guard waitUntilReady, let warming = primary.client as? any SpeechToTextWarming else { return false }
        return await warming.waitUntilWarm(language: language, keywords: keywords)
    }

    /// Closes the warm connection and stops refreshing it (engines rebuilt, app quitting).
    public func shutDown() async {
        stopKeepingWarm()
        if let warming = primary.client as? any SpeechToTextWarming { await warming.discardWarmSocket() }
    }

    /// True while presses avoid the stt slot after a billing, quota or region refusal.
    public func isRefusing(at date: Date? = nil) -> Bool {
        guard let refusedUntil else { return false }
        return (date ?? now()) < refusedUntil
    }

    private func keepWarm() {
        guard keepWarmTask == nil else { return }
        let interval = policy.rewarmInterval
        keepWarmTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, await self.rewarmFromTimer() else { return }
            }
        }
    }

    /// Reopens the warm connection if the provider closed it or it would expire before the next tick; false (and the
    /// loop ends) once the ears are out of use.
    private func rewarmFromTimer() async -> Bool {
        guard let warming = primary.client as? any SpeechToTextWarming, !isRefusing(), let last = usage.load(),
              now().timeIntervalSince(last) <= policy.keepWarmAfterUse else {
            keepWarmTask = nil
            return false
        }
        // A connection that would close before the next tick is replaced now (the next tick comes a little after
        // `rewarmInterval`, hence the extra quarter); otherwise presses in that gap would connect cold.
        await warming.warmUp(language: language, keywords: keywords, replacingWithin: Self.rewarmMargin(policy.rewarmInterval))
        return true
    }

    /// How long the warm connection must still have left at a timer tick to be kept until the next one.
    static func rewarmMargin(_ interval: Duration) -> Duration { interval + interval / 4 }

    private func stopKeepingWarm() {
        keepWarmTask?.cancel()
        keepWarmTask = nil
    }

    // MARK: - From the press sessions

    /// Records the press (and a refusal, so the next press already avoids the slot). The connection for the next press
    /// is opened afterwards, off this press's path: the turn doesn't wait for it.
    func pressFinished(_ report: EarsPressReport, refusal: Error?) {
        lastReport = report
        var discard = false
        if let refusal, !isRefusing() {
            refusedUntil = now().addingTimeInterval(policy.refusalSwitch)
            stopKeepingWarm()
            discard = true
            log("ears: \(primary.name) refused \(SpeechRefusal.isRegionRefusal(refusal) ? "in this region" : "for its account") (\(Self.describe(refusal))); using "
                + "\(alternate?.name ?? "the fallbacks") for \(Int(policy.refusalSwitch / 60)) minutes")
        }
        reportHandler?(report)
        let warming = primary.client as? any SpeechToTextWarming
        Task {
            if discard { await warming?.discardWarmSocket() }
            // The press took the warm connection (or opened its own): get one ready for the next press.
            await self.refresh(.afterPress)
        }
    }

    private func log(_ text: String) { logHandler?(text) }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

// MARK: - One press

/// One press through the ears: audio is kept and streamed to the recognizer (held until it connects), interim text is
/// the running transcript, and `finish()` settles the words (streamed, or from the fallbacks) before it returns.
actor EarsPressSession: SpeechToTextSession, EarsPressReporting {
    nonisolated let events: AsyncThrowingStream<TranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    private weak var ears: VoiceEars?
    private let recognizer: VoiceEars.Recognizer?
    private let switched: Bool
    private var fallbacks: [VoiceEars.Fallback]
    private let format: PCMFormat
    private let language: String?
    private let keywords: [String]
    private let policy: VoiceEars.Policy
    private let now: @Sendable () -> Date
    private let recording: PressAudioRecording
    private var report: EarsPressReport
    private var inner: (any SpeechToTextSession)?
    private var innerFormat: PCMFormat?
    private var opening = false
    private var pending: [Data] = []
    private var streamError: Error?
    private var streamEnded = false
    private var finishRequested = false
    private var done = false
    private var finals = ""
    private var interim = ""
    private var shown = ""
    private var refusal: Error?
    private var tasks: [Task<Void, Never>] = []

    init(ears: VoiceEars, recognizer: VoiceEars.Recognizer?, switched: Bool, fallbacks: [VoiceEars.Fallback], format: PCMFormat,
         language: String?, keywords: [String], policy: VoiceEars.Policy, now: @escaping @Sendable () -> Date) {
        (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.ears = ears
        self.recognizer = recognizer
        self.switched = switched
        self.fallbacks = fallbacks
        self.format = format
        self.language = language
        self.keywords = keywords
        self.policy = policy
        self.now = now
        recording = PressAudioRecording(format: format)
        report = EarsPressReport(recognizer: recognizer?.name ?? "batch only", startedAt: now())
    }

    func start() {
        guard let recognizer else { return }
        opening = true
        tasks.append(Task { await self.open(recognizer.client) })
    }

    private func open(_ client: any SpeechToTextClient) async {
        do {
            let session = try await client.startSession(language: language, keywords: keywords)
            guard await stillOpening(session) else { return }
            report.connectedAt = now()
            innerFormat = client.inputFormat
            if let ready = session as? any SpeechToTextSessionReadiness {
                report.warm = await ready.startedWarm
                guard await stillOpening(session) else { return }
                tasks.append(Task { if await ready.waitUntilReady() { self.markReady() } })
            } else {
                report.readyAt = report.connectedAt
            }
            tasks.append(Task { await self.listen(session) })
            // Audio captured while connecting goes first, in order; more can arrive while it is sent.
            while !pending.isEmpty {
                let chunk = pending.removeFirst()
                await session.send(convert(chunk))
                guard await stillOpening(session) else { return }
            }
            inner = session
            opening = false
            if finishRequested { await session.finish() }
        } catch {
            opening = false
            pending.removeAll()
            streamFailed(error)
        }
    }

    /// False, with the session closed, when the press was cancelled or concluded while `open` was suspended:
    /// `cancel()` and `conclude()` only reach `inner`, which isn't set yet, so the session would otherwise stay open.
    private func stillOpening(_ session: any SpeechToTextSession) async -> Bool {
        guard done || Task.isCancelled else { return true }
        opening = false
        pending.removeAll()
        await session.cancel()
        for task in tasks { task.cancel() }  // the ready and listen tasks this open already started
        return false
    }

    private func markReady() {
        if report.readyAt == nil { report.readyAt = now() }
    }

    private func listen(_ session: any SpeechToTextSession) async {
        do {
            for try await event in session.events {
                guard !done else { return }
                switch event {
                case .interim(let text):
                    interim = text
                    heardText()
                case .final(let text):
                    finals += text
                    interim = ""
                    heardText()
                case .speechStarted, .utteranceEnd:
                    continuation.yield(event)
                }
            }
            streamEnded = true
        } catch {
            if !(error is CancellationError) { streamFailed(error) } else { streamEnded = true }
        }
    }

    private func heardText() {
        let running = finals + interim
        if report.firstTextAt == nil, !running.trimmingCharacters(in: .whitespaces).isEmpty { report.firstTextAt = now() }
        // The whole running transcript as the interim: the one final at the end settles all of it.
        guard running != shown else { return }
        shown = running
        continuation.yield(.interim(running))
    }

    private func streamFailed(_ error: Error) {
        guard streamError == nil else { return }
        streamError = error
        report.streamError = VoiceEars.describe(error)
        if !switched, SpeechRefusal.switchesSlot(error) {
            refusal = error
            fallbacks.removeAll { $0.sharesPrimaryAccount }
        }
    }

    private func convert(_ chunk: Data) -> Data {
        guard let innerFormat, innerFormat != format else { return chunk }
        return PCM16Conversion.convert(chunk, from: format, to: innerFormat)
    }

    // MARK: - SpeechToTextSession

    func send(_ pcm: Data) async {
        guard !done, !finishRequested, !pcm.isEmpty else { return }
        recording.append(pcm)
        guard streamError == nil else { return }
        if let inner {
            await inner.send(convert(pcm))
        } else if opening {
            pending.append(pcm)
        }
    }

    func finish() async {
        guard !done, !finishRequested else { return }
        finishRequested = true
        report.finishAt = now()
        if recognizer != nil, streamError == nil {
            if let inner { await inner.finish() }  // still connecting: `open` finishes it once the held audio is sent
            let deadline = ContinuousClock.now + policy.finalTimeout
            while !streamEnded, streamError == nil, !done, !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        guard !done else { return }
        if Task.isCancelled {
            await cancel()
            return
        }
        await conclude()
    }

    func cancel() async {
        guard !done else { return }
        done = true
        report.outcome = .cancelled
        report.finalAt = now()
        report.audioSeconds = DecodedAudio(pcm: recording.data, format: format).duration
        for task in tasks { task.cancel() }
        if let inner { await inner.cancel() }
        continuation.finish()
        await ears?.pressFinished(report, refusal: refusal)
    }

    func pressReport() async -> EarsPressReport { report }

    // MARK: - Settling the words

    private func conclude() async {
        let streamed = (finals + interim).trimmingCharacters(in: .whitespacesAndNewlines)
        let audio = DecodedAudio(pcm: recording.data, format: format)
        report.audioSeconds = audio.duration
        var words = ""
        let healthy = recognizer != nil && streamEnded && streamError == nil
        if healthy {
            words = streamed
            report.outcome = streamed.isEmpty ? .silent : (switched ? .switched : .streamed)
        } else {
            if recognizer != nil, streamError == nil {
                report.streamError = "no settled transcript \(policy.finalTimeout) after key-up"
            }
            if let inner { await inner.cancel() }
            for task in tasks { task.cancel() }
            if let heard = await runFallbacks(audio) {
                words = heard
                report.outcome = heard.isEmpty ? .silent : .fallback
            } else if !streamed.isEmpty {
                words = streamed
                report.outcome = .partial
            } else {
                report.outcome = audio.duration < DictationFallbackTranscription.minimumSeconds ? .silent : .failed
            }
        }
        guard !done else { return }
        done = true
        report.finalAt = now()
        report.startedRefusalSwitch = refusal != nil
        if !words.isEmpty { continuation.yield(.final(words)) }
        if report.outcome == .failed {
            continuation.finish(throwing: streamError ?? ProviderError(provider: report.recognizer, message: "No transcript came back."))
        } else {
            continuation.finish()
        }
        await ears?.pressFinished(report, refusal: refusal)
    }

    /// The first fallback that answers, with its text ("" when it heard nobody); nil when none did.
    private func runFallbacks(_ audio: DecodedAudio) async -> String? {
        guard audio.duration >= DictationFallbackTranscription.minimumSeconds, !fallbacks.isEmpty else { return nil }
        let started = ContinuousClock.now
        let deadline = started + policy.fallbackTimeout
        for fallback in fallbacks {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, !done, !Task.isCancelled else { break }
            let language = self.language, keywords = self.keywords
            let result: Result<String, Error> = await withTaskGroup(of: Result<String, Error>?.self) { group in
                group.addTask {
                    do { return .success(try await fallback.client.transcribe(audio, language: language, keywords: keywords)) } catch {
                        return .failure(error)
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: remaining)
                    return Task.isCancelled ? nil : .failure(ProviderError(provider: fallback.name, message: "timed out"))
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? .failure(CancellationError())
            }
            switch result {
            case .success(let text):
                report.fallback = fallback.name
                report.fallbackMs = VoiceEars.milliseconds(ContinuousClock.now - started)
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .failure(let error):
                let note = "\(fallback.name): \(VoiceEars.describe(error))"
                report.streamError = [report.streamError, "fallback " + note].compactMap { $0 }.joined(separator: "; ")
                if fallback.sharesPrimaryAccount, !switched, refusal == nil, SpeechRefusal.switchesSlot(error) { refusal = error }
            }
        }
        return nil
    }
}

extension VoiceEars {
    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int((Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15).rounded())
    }
}
