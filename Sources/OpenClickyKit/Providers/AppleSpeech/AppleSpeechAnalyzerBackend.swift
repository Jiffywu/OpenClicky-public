// SpeechAnalyzer/SpeechTranscriber first shipped in the macOS 26 SDK (Swift 6.2). Older toolchains compile only the
// SFSpeechRecognizer fallback.
#if compiler(>=6.2)
import AVFAudio
import Foundation
import Speech

/// The preferred engine on macOS 26+: `SpeechAnalyzer` running a `SpeechTranscriber`, fed by an `AsyncStream` of
/// `AnalyzerInput` and analysing autonomously (`start(inputSequence:)`).
///
/// Docs relied on (checked against the MacOSX27.0 SDK's Speech.swiftinterface):
/// - https://developer.apple.com/documentation/speech/speechanalyzer ("Analyze audio from audio buffers",
///   "Analyze autonomously", "Finish analysis", "Respond to errors")
/// - https://developer.apple.com/documentation/speech/speechtranscriber and .../speechtranscriber/isavailable
/// - https://developer.apple.com/documentation/speech/speechtranscriber/preset ("progressiveTranscription":
///   volatile + fast results, "Configuration for immediate transcription of live audio")
/// - https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocale(equivalentto:)
/// - https://developer.apple.com/documentation/speech/assetinventory and
///   .../assetinventory/assetinstallationrequest(supporting:)
/// - https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat(compatiblewith:)
/// - https://developer.apple.com/documentation/speech/analyzerinput
/// - https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput()
/// - https://developer.apple.com/documentation/speech/speechanalyzer/cancelandfinishnow()
/// - https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal
/// - https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings
@available(macOS 26, *)
final class AppleSpeechAnalyzerBackend: AppleSpeechBackend, @unchecked Sendable {
    // @unchecked: `bufferFormat` (AVAudioFormat) is immutable; the analyzer is an actor, the transcriber, the
    // AsyncStream continuation and AnalyzerInput are Sendable; `tasks` is guarded by `lock`.
    let bufferFormat: AVAudioFormat
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false

    private init(bufferFormat: AVAudioFormat, analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber,
                 input: AsyncStream<AnalyzerInput>.Continuation) {
        self.bufferFormat = bufferFormat
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.input = input
    }

    /// Builds a running analyzer, or returns nil when SpeechTranscriber can't serve this Mac or language (the
    /// caller then falls back to SFSpeechRecognizer). Installs the language's model assets if they're missing,
    /// which downloads them from Apple the first time.
    static func make(locale: Locale, contextualStrings: [String]) async throws -> AppleSpeechAnalyzerBackend? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)

        // "If the current status is .installed, returns nil, indicating that nothing further needs to be done."
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        // nil "if the specified modules require you to install additional assets".
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return nil
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let context = analysisContext(contextualStrings: contextualStrings) {
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            try await analyzer.start(inputSequence: stream)
            return AppleSpeechAnalyzerBackend(bufferFormat: format, analyzer: analyzer, transcriber: transcriber,
                                              input: continuation)
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Keywords go in the `.general` contextual-strings tag. Apple's docs describe contextual strings for
    /// DictationTranscriber ("With the DictationTranscriber module, you can use this property…") and say nothing
    /// either way for SpeechTranscriber, so with SpeechTranscriber this is a best-effort hint that may be ignored.
    /// Run live on macOS 27.2, setContext accepted it, but "OpenClicky" was still transcribed as "open clicky".
    static func analysisContext(contextualStrings: [String]) -> AnalysisContext? {
        guard !contextualStrings.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualStrings
        return context
    }

    func start(reporting handler: @escaping @Sendable (AppleSpeechBackendEvent) -> Void) {
        let transcriber = self.transcriber
        let task = Task {
            do {
                for try await result in transcriber.results {
                    handler(.result(text: String(result.text.characters), isFinal: result.isFinal))
                }
                // Result streams terminate once the analyzer finishes (after finalizeAndFinishThroughEndOfInput).
                handler(.finished)
            } catch {
                handler(.failed(error))
            }
        }
        let cancelNow: Bool = lock.withLock {
            tasks.append(task)
            return stopped
        }
        if cancelNow { task.cancel() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func endAudio() {
        input.finish()
        let analyzer = self.analyzer
        // Waits for the input stream to drain, finalizes the volatile range, then finishes, which ends
        // `transcriber.results`. Its errors also surface through the results stream ("the same error … is thrown
        // from all waiting methods and result streams"), so the start(reporting:) task reports them.
        let task = Task { _ = try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        let cancelNow: Bool = lock.withLock {
            tasks.append(task)
            return stopped
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let running: [Task<Void, Never>] = lock.withLock {
            stopped = true
            return tasks
        }
        input.finish()
        running.forEach { $0.cancel() }
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
#endif
