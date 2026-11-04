import Foundation

/// Microphone audio for dictation. The app supplies one backed by the capture engine; tests feed scripted chunks.
public protocol DictationAudioInput: Sendable {
    /// Opens the microphone and returns 16-bit PCM chunks in `format`. The stream finishes after `stop()`.
    /// Must be restartable: `start` may be called again after `stop`.
    func start(format: PCMFormat) async throws -> AsyncStream<Data>
    func stop() async
    /// Current input level from 0 to 1, for the HUD.
    func level() -> Float
}

extension DictationAudioInput {
    public func level() -> Float { 0 }
}

/// How a dictation ended, in terms the HUD can show.
public enum DictationResult: Sendable, Equatable {
    case typed(appName: String?)
    case copiedToClipboard(InsertionFailure)
    case refused(InsertionRefusal)
    case nothingHeard
    case cancelled
}

/// What the HUD shows.
public struct DictationStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case listening
        /// Waiting for the last words from speech-to-text.
        case finishing
        case cleaning
        case inserting
        case done(DictationResult)
        case failed(String)
    }

    public var phase: Phase
    public var engagement: DictationEngagement
    /// Words heard so far (settled text plus the provisional tail).
    public var liveText: String
    /// The app the text is going to, once focus has been read.
    public var appName: String?
    /// Where the field is on screen (Accessibility coordinates), so the HUD can sit next to it.
    public var fieldFrame: FocusFrame?

    public init(phase: Phase = .idle, engagement: DictationEngagement = .idle, liveText: String = "", appName: String? = nil,
                fieldFrame: FocusFrame? = nil) {
        self.phase = phase
        self.engagement = engagement
        self.liveText = liveText
        self.appName = appName
        self.fieldFrame = fieldFrame
    }
}

/// Everything about one finished dictation, for logging and tests.
public struct DictationSessionReport: Sendable {
    public var rawTranscript: String
    /// The streaming session failed or lost its final words and the fallback transcription supplied the text.
    public var heardByFallback: Bool = false
    public var cleanup: DictationCleanupResult?
    public var insertion: InsertionReport?
    public var focus: CapturedFocus?
    public var result: DictationResult
}

/// Talk-to-type. Drives one dictation at a time from key gestures: capture the focused field, stream the microphone
/// into the stt slot's session, clean the transcript with a fast language-model pass, type it into the field,
/// archive it, and later learn from any fixes the user makes.
///
/// The speech session opens at key-down together with the microphone. In the app the client is a `VoiceEars` for
/// dictation, so a connection kept warm since the last dictation is taken over, the press audio is kept while the
/// connection opens, and refusals or a dropped stream go to its fallbacks.
@MainActor
public final class DictationController {
    public struct Services: Sendable {
        public var focus: any FocusReading
        public var audio: any DictationAudioInput
        /// The stt slot's client, built when a dictation starts; nil when none is configured.
        public var speechToText: @Sendable () -> (any SpeechToTextClient)?
        /// A second speech-to-text client for presses the streaming session lost (it failed, or its final words
        /// never came): the press's audio is kept and transcribed again in one pass. Nil turns the fallback off.
        public var fallbackSpeechToText: @Sendable () -> (any SpeechToTextClient)?
        /// The cleanup pass; nil (or a cleaner without a client) means only the local tidy runs.
        public var cleaner: @Sendable () -> DictationCleaner?
        public var inserter: TextInserter
        public var vocabulary: DictationVocabularyStore?
        public var archive: DictationTranscriptArchive?
        public var language: String?
        /// Always-present keyterms (the product name, the user's name).
        public var keytermSeeds: [String]
        /// The seeds every dictation starts with.
        public static let defaultKeytermSeeds = ["OpenClicky"]
        public var learnCorrections: Bool
        /// Seconds to wait for the final transcript after the key is released.
        public var finalTranscriptTimeout: Double
        /// Seconds the fallback transcription may take.
        public var fallbackTimeout: Double
        /// Seconds after typing before the field is re-read to learn corrections.
        public var learnDelay: Double
        /// Seconds the result stays on the HUD.
        public var resultDisplaySeconds: Double
        /// Waits until the user lets go of the dictation keys, so they don't mix into synthesized shortcuts.
        public var waitForKeysReleased: @Sendable () async -> Void
        public var now: @Sendable () -> Date

        public init(focus: any FocusReading, audio: any DictationAudioInput,
                    speechToText: @escaping @Sendable () -> (any SpeechToTextClient)?,
                    cleaner: @escaping @Sendable () -> DictationCleaner?, inserter: TextInserter,
                    vocabulary: DictationVocabularyStore? = nil, archive: DictationTranscriptArchive? = nil,
                    language: String? = nil, keytermSeeds: [String] = Services.defaultKeytermSeeds, learnCorrections: Bool = true,
                    finalTranscriptTimeout: Double = 4, learnDelay: Double = 12, resultDisplaySeconds: Double = 1.6,
                    fallbackSpeechToText: @escaping @Sendable () -> (any SpeechToTextClient)? = { nil },
                    fallbackTimeout: Double = 20,
                    waitForKeysReleased: @escaping @Sendable () async -> Void = {},
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.focus = focus
            self.audio = audio
            self.speechToText = speechToText
            self.fallbackSpeechToText = fallbackSpeechToText
            self.fallbackTimeout = fallbackTimeout
            self.cleaner = cleaner
            self.inserter = inserter
            self.vocabulary = vocabulary
            self.archive = archive
            self.language = language
            self.keytermSeeds = keytermSeeds
            self.learnCorrections = learnCorrections
            self.finalTranscriptTimeout = finalTranscriptTimeout
            self.learnDelay = learnDelay
            self.resultDisplaySeconds = resultDisplaySeconds
            self.waitForKeysReleased = waitForKeysReleased
            self.now = now
        }
    }

    public var services: Services
    public private(set) var status = DictationStatus() {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((DictationStatus) -> Void)?
    public var onSessionFinished: ((DictationSessionReport) -> Void)?
    /// Words learned from the user's fixes (for a "learned" notice).
    public var onLearned: (([LearnedCorrection]) -> Void)?
    /// Called when the streaming speech session fails or ends on its own while the key is still held, before the
    /// controller decides whether to stop or keep recording for the fallback. Lets tests wait for that moment.
    var onSpeechSessionLost: ((any Error) -> Void)?

    private var machine: DictationEngagementMachine
    private var timers: [DictationEngagementMachine.Timer: Task<Void, Never>] = [:]
    private var live: LiveSession?
    private var audioStop: Task<Void, Never>?
    private var lastPipeline: Task<Void, Never>?
    private var latestPipelineID: UUID?
    private var resetTask: Task<Void, Never>?
    private var pendingLearn: PendingLearn?

    public init(services: Services, timing: DictationEngagementMachine.Timing = .init(), allowsDoubleTapLock: Bool = true) {
        self.services = services
        self.machine = DictationEngagementMachine(timing: timing, allowsDoubleTapLock: allowsDoubleTapLock)
    }

    /// True while the microphone is open for a dictation.
    public var isCapturing: Bool { live != nil }

    public var engagementMachine: DictationEngagementMachine { machine }

    /// Whether a quick double tap locks dictation on (hands-free). Takes effect from the next press.
    public var allowsDoubleTapLock: Bool {
        get { machine.allowsDoubleTapLock }
        set { machine.allowsDoubleTapLock = newValue }
    }

    // MARK: Key gestures

    /// Feed key events (from the app's key monitor) and timer firings through the engagement rules.
    public func handle(_ input: DictationEngagementMachine.Input) {
        for effect in machine.handle(input) { apply(effect) }
    }

    private func apply(_ effect: DictationEngagementMachine.Effect) {
        switch effect {
        case .startCapture: begin(engagement: .holding)
        case .commit: commit()
        case .discard: discard()
        case .engagementChanged(let engagement):
            if live != nil { status.engagement = engagement }
        case .schedule(let timer, let delay):
            timers[timer]?.cancel()
            timers[timer] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.timers[timer] = nil
                self?.handle(.timerFired(timer))
            }
        case .cancelTimer(let timer):
            timers[timer]?.cancel()
            timers[timer] = nil
        }
    }

    // MARK: Direct control

    /// Opens the microphone and starts a speech session. A dictation already listening is dropped.
    public func begin(engagement: DictationEngagement = .holding) {
        if let previous = live { cancel(previous) }
        resetTask?.cancel()
        runPendingLearn()
        guard let client = services.speechToText() else {
            show(DictationStatus(phase: .failed("Speech to text isn't set up. Choose a model for the stt slot in Settings.")))
            return
        }
        let reader = services.focus
        let session = LiveSession(focusTask: Task.detached { Self.keyDownFocus(reader) })
        session.fallback = services.fallbackSpeechToText()
        live = session
        status = DictationStatus(phase: .listening, engagement: engagement)

        let audio = services.audio
        let vocabulary = services.vocabulary
        let seeds = services.keytermSeeds
        let language = services.language
        let stopping = audioStop
        session.runTask = Task { [weak self] in
            defer {
                session.audioReady.signal()
                session.completion.signal()
            }
            do {
                await stopping?.value
                let keyterms = await vocabulary?.load().keyterms(seeds: seeds) ?? DictationVocabulary().keyterms(seeds: seeds)
                session.keyterms = keyterms
                // The speech session opens at key-down, alongside the microphone: a warm client (`VoiceEars`) hands
                // over the connection it kept open, and audio waits in the relay (and in the ears) until it's ready.
                let opening = Task { try await client.startSession(language: language, keywords: keyterms) }
                let microphone: AsyncStream<Data>
                do {
                    microphone = try await audio.start(format: client.inputFormat)
                } catch {
                    session.microphoneFailed = true
                    session.audioReady.signal()
                    opening.cancel()
                    Task { try? await opening.value.cancel() }
                    throw error
                }
                session.audioReady.signal()
                // Audio flows through a relay so the press can be kept for the fallback even when the speech
                // session never connects.
                let recording = session.fallback == nil ? nil : PressAudioRecording(format: client.inputFormat)
                session.recording = recording
                let (chunks, relay) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
                session.recorder = Task.detached {
                    for await chunk in microphone {
                        recording?.append(chunk)
                        relay.yield(chunk)
                    }
                    relay.finish()
                }
                if Task.isCancelled { Task { try? await opening.value.cancel() } }
                try Task.checkCancellation()
                let stt = try await opening.value
                session.stt = stt
                if session.cancelled {
                    await stt.cancel()
                    return
                }
                session.pump = Task.detached {
                    for await chunk in chunks { await stt.send(chunk) }
                    if !Task.isCancelled { await stt.finish() }
                }
                for try await event in stt.events {
                    switch event {
                    case .interim(let text): session.interim = text
                    case .final(let text):
                        session.finals.append(text)
                        session.interim = ""
                    case .speechStarted, .utteranceEnd: break
                    }
                    self?.liveTextChanged(session)
                }
                // The session closed on its own while the user is still talking (the provider hung up cleanly).
                // Words spoken from here on would be lost without a word, so treat it like a dropped session.
                if !Task.isCancelled, !session.cancelled, let self, self.live === session {
                    throw DictationSpeechSessionEnded()
                }
            } catch {
                guard !session.cancelled else { return }
                session.error = error
                guard let self, self.live === session else { return }
                self.onSpeechSessionLost?(error)
                // The speech session failed while the user is still talking. Without a fallback, stop now and keep
                // what was heard (or say what went wrong) instead of listening into the void. With one, keep
                // recording until the release and transcribe the whole press again.
                if session.fallback == nil || session.microphoneFailed { self.commit() }
            }
        }
        Task { [weak self] in
            let focus = await session.focusTask.value
            guard let self, self.live === session, let context = focus?.context else { return }
            self.status.appName = context.appName
            self.status.fieldFrame = context.frame
        }
    }

    /// Stops listening and types what was said.
    public func commit() {
        guard let session = live else { return }
        live = nil
        let stopping = stopAudio(after: session)
        let previous = lastPipeline
        let id = UUID()
        latestPipelineID = id
        status = DictationStatus(phase: .finishing, engagement: .idle, liveText: status.liveText, appName: status.appName,
                                 fieldFrame: status.fieldFrame)
        lastPipeline = Task { [weak self] in
            await stopping.value
            await self?.finish(session, id: id, after: previous)
        }
    }

    /// Stops listening and throws the audio away.
    public func discard() {
        guard let session = live else { return }
        live = nil
        cancel(session)
        show(DictationStatus(phase: .idle))
    }

    /// Escape: drop a dictation that is listening.
    public func cancelActive() {
        handle(.cancel)
        if live != nil { discard() }
    }

    // MARK: Pipeline

    private func finish(_ session: LiveSession, id: UUID, after previous: Task<Void, Never>?) async {
        let services = self.services
        let completed = await session.waitForTranscript(timeout: services.finalTranscriptTimeout)
        if !completed {
            session.cancelled = true
            session.runTask?.cancel()
            session.pump?.cancel()
            await session.stt?.cancel()
        } else if session.error != nil {
            // The streaming session failed or hung up; nothing more will come from it. Release it now rather than
            // leave the audio pump waiting on its finish.
            session.pump?.cancel()
            await session.stt?.cancel()
        }
        var raw = Self.transcript(finals: session.finals, interim: session.interim)
        var heardByFallback = false
        if session.error != nil || !completed, let fallback = session.fallback, let recording = session.recording {
            // The microphone is already stopped, so the recorder has seen every chunk once it ends.
            await session.recorder?.value
            let keyterms = session.keyterms.isEmpty
                ? (await services.vocabulary?.load() ?? DictationVocabulary()).keyterms(seeds: services.keytermSeeds)
                : session.keyterms
            if let text = await DictationFallbackTranscription.transcribe(
                recording.data, format: recording.format, with: fallback, language: services.language, keyterms: keyterms,
                timeout: services.fallbackTimeout) {
                raw = text
                heardByFallback = true
            }
        }
        var focus = await session.focusTask.value
        // A field that wasn't there at key-down (the app was still building its Accessibility tree) is read again
        // now, but only if it is in the app that was in front when dictation started. Accessibility calls can block
        // for as long as a slow app takes to answer, so the read runs off the main actor.
        if focus?.element == nil {
            let reader = services.focus
            let late = await Task.detached { try? reader.captureFocus().get() }.value
            if let late, focus == nil || late.context.processID == focus?.context.processID { focus = late }
        }

        guard !raw.isEmpty else {
            let result: DictationResult = .nothingHeard
            if let error = session.error {
                showFromPipeline(id, DictationStatus(phase: .failed("Couldn't transcribe: \(error)")))
            } else {
                showFromPipeline(id, DictationStatus(phase: .done(result)))
            }
            onSessionFinished?(DictationSessionReport(rawTranscript: "", heardByFallback: false, cleanup: nil, insertion: nil,
                                                      focus: focus, result: result))
            return
        }

        let vocabulary = await services.vocabulary?.load() ?? DictationVocabulary()
        let corrected = vocabulary.applyCorrections(to: raw)
        // Words meant for a password field, or spoken while some app has Secure Event Input on (a password prompt
        // in a terminal), never go to a model; insertion will refuse them anyway.
        let isSecure = focus?.context.isSecure == true || services.inserter.system.isSecureEventInputEnabled()
        let cleaner = (isSecure ? nil : services.cleaner()) ?? DictationCleaner(client: nil, options: DictationCleanupOptions(model: ""))
        if cleaner.client != nil, !cleaner.shouldSkip(corrected) {
            updateFromPipeline(id) { $0.phase = .cleaning }
        }
        let keyterms = session.keyterms.isEmpty ? vocabulary.keyterms(seeds: services.keytermSeeds) : session.keyterms
        let cleanup = await cleaner.clean(corrected, context: focus?.context, vocabulary: keyterms)

        // Text is typed in the order it was spoken.
        await previous?.value
        updateFromPipeline(id) { $0.phase = .inserting }
        await services.waitForKeysReleased()
        let report = await services.inserter.insert(cleanup.text, into: focus)
        let result = Self.result(of: report)

        if let archive = services.archive, report.copiedToClipboard || Self.wasTyped(report) {
            let context = report.target?.context ?? focus?.context
            let entry = DictationTranscriptArchive.Entry(
                at: services.now(), app: context?.appName, bundleID: context?.bundleID, text: cleanup.text,
                raw: raw == cleanup.text ? nil : raw, outcome: Self.wasTyped(report) ? "typed" : "clipboard")
            try? await archive.append(entry)
        }
        if services.learnCorrections, Self.wasTyped(report) { scheduleLearning(report) }

        showFromPipeline(id, DictationStatus(phase: .done(result), appName: report.appName ?? focus?.context.appName,
                                             fieldFrame: report.target?.context.frame ?? focus?.context.frame))
        onSessionFinished?(DictationSessionReport(rawTranscript: raw, heardByFallback: heardByFallback, cleanup: cleanup,
                                                  insertion: report, focus: focus, result: result))
    }

    /// The transcript as the stt contract defines it: the finals concatenated as they are (each final carries its own
    /// leading space where the language needs one, so none is added here), then any interim not yet settled. Runs of
    /// whitespace collapse to one space and the ends are trimmed.
    nonisolated static func transcript(finals: [String], interim: String) -> String {
        (finals.joined() + interim).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The field at key-down. When the app is known but its focused element isn't, a placeholder keeps the app, so
    /// the text can't later land in a different app.
    nonisolated static func keyDownFocus(_ reader: any FocusReading) -> CapturedFocus? {
        switch reader.captureFocus() {
        case .success(let focus):
            return focus
        case .failure(.noFocusedElement(let appName, let processID?)):
            return CapturedFocus(context: FocusContext(appName: appName, processID: processID, isEditable: false), element: nil)
        case .failure:
            return nil
        }
    }

    static func wasTyped(_ report: InsertionReport) -> Bool {
        if case .inserted = report.outcome { return true }
        return false
    }

    static func result(of report: InsertionReport) -> DictationResult {
        switch report.outcome {
        case .inserted: .typed(appName: report.appName)
        case .copiedToClipboard(let reason): .copiedToClipboard(reason)
        case .refused(let refusal): .refused(refusal)
        case .nothingToInsert: .nothingHeard
        }
    }

    // MARK: Learning from edits

    private struct PendingLearn {
        var report: InsertionReport
        var timer: Task<Void, Never>
    }

    private func scheduleLearning(_ report: InsertionReport) {
        guard let target = report.target, target.element != nil, target.context.isValueReadable else { return }
        runPendingLearn()
        let delay = services.learnDelay
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.runPendingLearn()
        }
        pendingLearn = PendingLearn(report: report, timer: timer)
    }

    /// Re-reads the field the last dictation typed into, records any vocabulary fixes the user made, and returns them.
    @discardableResult
    public func learnNow() async -> [LearnedCorrection] {
        let found = collectPendingCorrections()
        if !found.isEmpty, let store = services.vocabulary {
            try? await store.update { vocabulary in for correction in found { vocabulary.learn(correction) } }
        }
        return found
    }

    private func runPendingLearn() {
        guard pendingLearn != nil else { return }
        // Read the field now, before another dictation changes it; save in the background.
        let found = collectPendingCorrections()
        guard !found.isEmpty else { return }
        let store = services.vocabulary
        Task { try? await store?.update { vocabulary in for correction in found { vocabulary.learn(correction) } } }
    }

    private func collectPendingCorrections() -> [LearnedCorrection] {
        guard let pending = pendingLearn else { return [] }
        pendingLearn = nil
        pending.timer.cancel()
        guard let target = pending.report.target, let element = target.element,
              let now = services.inserter.system.value(of: element),
              let region = CorrectionLearner.editedRegion(now: now, beforeText: target.context.beforeText,
                                                          afterText: target.context.afterText,
                                                          insertedLength: pending.report.insertedText.count)
        else { return [] }
        let found = CorrectionLearner.corrections(inserted: pending.report.insertedText, edited: region, now: services.now())
        if !found.isEmpty { onLearned?(found) }
        return found
    }

    // MARK: Helpers

    private func liveTextChanged(_ session: LiveSession) {
        guard live === session else { return }
        status.liveText = Self.transcript(finals: session.finals, interim: session.interim)
    }

    private func cancel(_ session: LiveSession) {
        session.cancelled = true
        session.runTask?.cancel()
        session.pump?.cancel()
        session.recorder?.cancel()
        let stt = session.stt
        let stopping = stopAudio(after: session)
        Task {
            await stopping.value
            await stt?.cancel()
        }
    }

    /// Stops the microphone once the session's start attempt is over (a release can beat the microphone opening),
    /// after any earlier stop. The next session's start waits for this task.
    private func stopAudio(after session: LiveSession) -> Task<Void, Never> {
        let previous = audioStop
        let audio = services.audio
        let ready = session.audioReady
        let task = Task {
            await previous?.value
            await ready.wait()
            await audio.stop()
        }
        audioStop = task
        return task
    }

    private func show(_ newStatus: DictationStatus) {
        status = newStatus
        scheduleReset()
    }

    private func showFromPipeline(_ id: UUID, _ newStatus: DictationStatus) {
        guard live == nil, latestPipelineID == id else { return }
        show(newStatus)
    }

    private func updateFromPipeline(_ id: UUID, _ change: (inout DictationStatus) -> Void) {
        guard live == nil, latestPipelineID == id else { return }
        change(&status)
    }

    private func scheduleReset() {
        resetTask?.cancel()
        guard status.phase != .idle else { return }
        let delay = services.resultDisplaySeconds
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.live == nil else { return }
            self.status = DictationStatus()
        }
    }
}

/// The speech session finished on its own before the user let go of the dictation keys.
struct DictationSpeechSessionEnded: Error, CustomStringConvertible {
    var description: String { "The speech session ended before you finished speaking." }
}

/// One dictation while the microphone is open.
@MainActor
final class LiveSession {
    let focusTask: Task<CapturedFocus?, Never>
    var runTask: Task<Void, Never>?
    var pump: Task<Void, Never>?
    var stt: (any SpeechToTextSession)?
    /// Copies microphone audio into the relay the speech session reads, and into `recording`.
    var recorder: Task<Void, Never>?
    var fallback: (any SpeechToTextClient)?
    var recording: PressAudioRecording?
    var microphoneFailed = false
    var keyterms: [String] = []
    var finals: [String] = []
    var interim = ""
    var error: (any Error)?
    var cancelled = false
    var transcriptTimedOut = false
    /// Signalled once the microphone start has returned or failed.
    let audioReady = Completion()
    /// Signalled when the speech session has ended.
    let completion = Completion()

    init(focusTask: Task<CapturedFocus?, Never>) { self.focusTask = focusTask }

    /// Waits for the speech session to end; false if it didn't within `timeout` seconds.
    func waitForTranscript(timeout: Double) async -> Bool {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            // The session may have ended just before the timer ran; that is not a timeout.
            guard !Task.isCancelled, let self, !self.completion.isDone else { return }
            self.transcriptTimedOut = true
            self.completion.signal()
        }
        await completion.wait()
        timer.cancel()
        return !transcriptTimedOut
    }
}

/// A one-shot signal that any number of waiters can await.
@MainActor
final class Completion {
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isDone: Bool { done }

    func signal() {
        guard !done else { return }
        done = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if done { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
