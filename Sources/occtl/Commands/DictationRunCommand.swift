import Foundation
import OpenClickyKit

/// `occtl dictation run <audio file>`: one whole dictation without a microphone or a real text field. The file plays in
/// real time as the press (`--fast`: as fast as possible) through the same pipeline the app uses: the dictation ears
/// for the stt slot (warm connection, kept press audio, refusal switch, fallbacks), the cleanup pass on the brain-fast
/// slot, and `TextInserter` typing into a pretend TextEdit field. Prints each step's time.
extension DictationCommands {
    static func run(_ options: Options) async throws {
        guard let path = options.positional.first else { fail(help) }
        let settings = DictationSettings.load(from: options.value("settings").map { URL(fileURLWithPath: $0) } ?? DictationSettings.defaultURL)
        let config = try EngineCommands.loadConfig(options.value("config"), fallback: .heyClickyLike)
        let catalog = try ModelCatalog.builtIn().merging(config.models)
        let factory = EngineFactory(config: config, catalog: catalog, credentials: CoreCommands.store)
        let language = options.value("language") ?? settings.language

        // The press: the file at the stt slot's rate.
        let format = try TranscribeCommands.sttFormat(factory)
        let pcm = try TranscribeCommands.decode(URL(fileURLWithPath: path), to: format)
        let seconds = Double(pcm.count) / Double(format.bytesPerSecond)
        let ears: VoiceEars
        do {
            ears = try VoiceEars.make(factory: factory, language: language)
        } catch {
            fail("The stt slot can't start: \(error)")
        }
        note("stt: \(ears.primary.name); file: \(String(format: "%.2f", seconds)) s at \(format.sampleRate) Hz")
        // The keywords dictation will send (no saved vocabulary here, the default seeds), so the warm socket matches.
        await ears.expect(language: language, keywords: DictationVocabulary().keyterms(seeds: DictationController.Services.defaultKeytermSeeds))
        if options.flag("warm") {
            let ready = await ears.warmUpNow(waitUntilReady: true)
            note("warm connection \(ready ? "ready" : "not offered by this stt") before key-down")
        }

        // The cleanup pass, as `occtl dictation cleanup` resolves it.
        let choice = DictationCleanupModelChoice.resolve(config: config, cleanup: settings.cleanup, catalog: try? ModelCatalog.builtIn())
        let resolution: DictationCleanupClientResolver.Resolution = options.flag("fake")
            ? .fake(reason: "--fake")
            : DictationCleanupClientResolver.resolve(choice: choice, factory: modelFactory, credentials: CoreCommands.store)
        let cleanupClient: (any LanguageModelClient)?
        switch resolution {
        case .real(let real, let choice):
            cleanupClient = real
            note("cleanup: \(choice.provider.id)/\(choice.model)\(choice.reasoningEffort.map { " (effort \($0))" } ?? "")")
        case .fake(let reason):
            cleanupClient = FakeCleanupModel()
            note("cleanup: FAKE (\(reason))")
        }
        let cleanupOptions = (try? choice.get())?.options(settings.cleanup)
            ?? DictationCleanupOptions(model: "fake", minimumWords: settings.cleanup.minimumWords, timeout: settings.cleanup.timeoutSeconds)

        let cleaner = DictationCleaner(client: settings.cleanup.enabled ? cleanupClient : nil, options: cleanupOptions)
        let outcome = await DictationRun.perform(pcm: pcm, format: format, realTime: !options.flag("fast"), ears: ears,
                                                 cleaner: cleaner, language: language)
        await ears.shutDown()
        outcome.print(json: options.flag("json"))
        if outcome.report?.result != .typed(appName: "TextEdit") { exit(1) }
    }
}

/// What one `occtl dictation run` measured.
struct DictationRunReport: Sendable {
    var report: DictationSessionReport?
    var ears: EarsPressReport?
    var typed: String?
    /// Milliseconds from key-down.
    var firstTextMs: Int?
    var keyUpMs: Int?
    var finishingMs: Int?
    var cleaningMs: Int?
    var insertingMs: Int?
    var doneMs: Int?
    var failure: String?

    func print(json: Bool) {
        let cleanup = report?.cleanup
        if json {
            var object: [String: JSONValue] = [:]
            func put(_ key: String, _ value: Int?) { if let value { object[key] = .number(Double(value)) } }
            put("first_text_ms", firstTextMs)
            put("key_up_ms", keyUpMs)
            put("transcript_ms", finishingMs.flatMap { _ in cleaningMs ?? insertingMs }.flatMap { end in keyUpMs.map { end - $0 } })
            put("cleanup_ms", cleanup?.milliseconds)
            put("done_ms", doneMs)
            object["raw"] = .string(report?.rawTranscript ?? "")
            object["typed"] = .string(typed ?? "")
            object["cleanup_source"] = .string(cleanup.map { DictationCommands.describe($0.source) } ?? "none")
            if let ears { object["ears"] = ears.json(releaseToWordsMs: nil) }
            if let failure { object["failure"] = .string(failure) }
            Swift.print(JSONValue.object(object).jsonString())
            return
        }
        func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "—" }
        Swift.print("key-down → first words      \(ms(firstTextMs))")
        Swift.print("key-down → key-up (file)    \(ms(keyUpMs))")
        if let up = keyUpMs, let settled = cleaningMs ?? insertingMs { Swift.print("key-up → transcript         \(settled - up) ms") }
        Swift.print("cleanup                     \(ms(cleanup?.milliseconds)) (\(cleanup.map { DictationCommands.describe($0.source) } ?? "none"))")
        if let up = keyUpMs, let done = doneMs { Swift.print("key-up → typed              \(done - up) ms") }
        if let ears { Swift.print(ears.logLine(heldMs: keyUpMs, releaseToWordsMs: nil)) }
        Swift.print("heard:  \(report?.rawTranscript ?? "")")
        Swift.print("typed:  \(typed ?? "")")
        if let failure { Swift.print("failed: \(failure)") }
    }
}

/// One dictation through `DictationController` with the file as the microphone and a pretend field that records what is
/// typed into it.
@MainActor
enum DictationRun {
    static func perform(pcm: Data, format: PCMFormat, realTime: Bool, ears: VoiceEars, cleaner: DictationCleaner,
                        language: String?) async -> DictationRunReport {
        let field = PretendTextField()
        let mic = FileDictationAudio(pcm: pcm, format: format, realTime: realTime)
        let services = DictationController.Services(
            focus: field, audio: mic, speechToText: { ears }, cleaner: { cleaner },
            inserter: TextInserter(system: field, pasteRestoreDelay: 0), language: language, learnCorrections: false,
            finalTranscriptTimeout: 6)
        let controller = DictationController(services: services)
        var run = DictationRunReport()
        let start = ContinuousClock.now
        func now() -> Int { VoiceEarsTiming.ms(ContinuousClock.now - start) }
        let (reports, finished) = AsyncStream<DictationSessionReport>.makeStream()
        controller.onSessionFinished = { finished.yield($0) }
        controller.onStatusChange = { status in
            if run.firstTextMs == nil, !status.liveText.trimmingCharacters(in: .whitespaces).isEmpty { run.firstTextMs = now() }
            switch status.phase {
            case .finishing: if run.finishingMs == nil { run.finishingMs = now() }
            case .cleaning: if run.cleaningMs == nil { run.cleaningMs = now() }
            case .inserting: if run.insertingMs == nil { run.insertingMs = now() }
            case .done: if run.doneMs == nil { run.doneMs = now() }
            case .failed(let why): run.failure = why
            default: break
            }
        }
        controller.begin()
        await mic.played()
        run.keyUpMs = now()
        controller.commit()
        for await report in reports {
            run.report = report
            break
        }
        if run.doneMs == nil { run.doneMs = now() }
        run.typed = field.typedText
        run.ears = await ears.lastReport
        return run
    }
}

enum VoiceEarsTiming {
    static func ms(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int((Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15).rounded())
    }
}

/// The audio file as dictation's microphone: chunks of 40 ms, in real time unless asked otherwise, then the stream stays
/// open (silence isn't sent) until the press is let go.
final class FileDictationAudio: DictationAudioInput, @unchecked Sendable {
    let pcm: Data
    let format: PCMFormat
    let realTime: Bool
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var feeder: Task<Void, Never>?
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(pcm: Data, format: PCMFormat, realTime: Bool) {
        self.pcm = pcm
        self.format = format
        self.realTime = realTime
    }

    func start(format: PCMFormat) async throws -> AsyncStream<Data> {
        let audio = format == self.format ? pcm : try PCMConverter.convert(pcm, from: self.format, to: format)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let bytes = max(2, format.bytesPerSecond / 25 / 2 * 2)
        let realTime = realTime
        let feeder = Task { [weak self] in
            var offset = 0
            while offset < audio.count, !Task.isCancelled {
                let end = min(offset + bytes, audio.count)
                continuation.yield(audio.subdata(in: offset..<end))
                offset = end
                if realTime { try? await Task.sleep(for: .milliseconds(40)) }
            }
            self?.finishedPlaying()
        }
        lock.withLock {
            self.continuation = continuation
            self.feeder = feeder
        }
        return stream
    }

    /// Waits until the whole file has gone in.
    func played() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if done { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func finishedPlaying() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            done = true
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }

    func stop() async {
        let (continuation, feeder) = lock.withLock { (self.continuation, self.feeder) }
        feeder?.cancel()
        continuation?.finish()
        finishedPlaying()
    }
}

/// An empty TextEdit document's text area that takes typed text through Accessibility, and nothing else on the Mac.
final class PretendTextField: TextInsertionSystem, FocusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    let pasteboard: any PasteboardAccess = InMemoryPasteboard()
    static let element = FocusElement("pretend-field" as NSString)

    var typedText: String { lock.withLock { value } }

    var focus: CapturedFocus {
        let text = typedText
        let units = text.utf16.count
        let snapshot = FocusSnapshot(appName: "TextEdit", bundleID: "com.apple.TextEdit", processID: 4242, role: "AXTextArea",
                                     subrole: nil, value: text, selection: UTF16Range(location: units, length: 0),
                                     characterCount: units, isValueSettable: true, isSelectedTextSettable: true, url: nil)
        return CapturedFocus(context: FocusContext(snapshot: snapshot), element: Self.element)
    }

    func captureFocus() -> Result<CapturedFocus, FocusReadError> { .success(focus) }
    func isAccessibilityTrusted() -> Bool { true }
    func isSecureEventInputEnabled() -> Bool { false }
    func currentFocus() -> CapturedFocus? { focus }
    func frontmostProcessID() -> Int32? { 4242 }
    func value(of element: FocusElement) -> String? { typedText }
    func setSelectedText(_ text: String, on element: FocusElement) -> Bool {
        lock.withLock { value += text }
        return true
    }
    func setValue(_ newValue: String, caret: Int, on element: FocusElement) -> Bool {
        lock.withLock { value = newValue }
        return true
    }
    func postPaste(to processID: Int32) async -> Bool { false }
    func type(_ text: String, to processID: Int32, shiftNewlines: Bool) -> Bool { false }
}
