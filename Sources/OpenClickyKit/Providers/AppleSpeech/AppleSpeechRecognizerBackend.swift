import AVFAudio
import Foundation
import Speech

/// The fallback engine: `SFSpeechRecognizer` fed by an `SFSpeechAudioBufferRecognitionRequest`. Used before macOS
/// 26, when `SpeechTranscriber` is unavailable on this Mac or for the language, or when its assets can't be
/// installed.
///
/// Docs relied on:
/// - https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest ("You must call
///   endAudio() explicitly to stop the speech recognition process.")
/// - https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition
/// - https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
/// - https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/shouldreportpartialresults
/// - https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings
/// - https://developer.apple.com/documentation/speech/sfspeechrecognizer/recognitiontask(with:resulthandler:)
/// - https://developer.apple.com/documentation/speech/sfspeechrecognitionresult/isfinal
final class AppleSpeechRecognizerBackend: AppleSpeechBackend, @unchecked Sendable {
    // @unchecked: the Speech objects are not Sendable. `recognizer` and `request` are immutable after init and
    // used only through calls the framework documents for use from capture threads (append/endAudio). `task` is
    // guarded by `lock`.
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var stopped = false

    let bufferFormat: AVAudioFormat

    init(locale: Locale, contextualStrings: [String], provider: String) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw ProviderError(provider: provider,
                                message: "Apple Speech has no recognizer for language \"\(locale.identifier)\"")
        }
        guard recognizer.isAvailable else {
            throw ProviderError(provider: provider,
                                message: "Apple Speech recognition for \"\(locale.identifier)\" is unavailable right now")
        }
        // Handlers default to the main queue; use a private serial queue so results never wait on the UI.
        let queue = OperationQueue()
        queue.name = "OpenClicky.AppleSpeech.results"
        queue.maxConcurrentOperationCount = 1
        recognizer.queue = queue

        let request = SFSpeechAudioBufferRecognitionRequest()
        Self.configure(request, supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
                       contextualStrings: contextualStrings)
        self.recognizer = recognizer
        self.request = request
        // "The preferred audio format for optimal speech recognition"; the session converts PCM16 into it.
        self.bufferFormat = request.nativeAudioFormat
    }

    /// Request settings, separated so tests can check them without starting a recognizer.
    ///
    /// On-device: the request "only honors [requiresOnDeviceRecognition] if supportsOnDeviceRecognition is also
    /// true"; when the recognizer can't run on device for this language, Apple's servers do the recognition.
    static func configure(_ request: SFSpeechAudioBufferRecognitionRequest, supportsOnDeviceRecognition: Bool,
                          contextualStrings: [String]) {
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = supportsOnDeviceRecognition
        request.contextualStrings = contextualStrings
        request.addsPunctuation = true
    }

    func start(reporting handler: @escaping @Sendable (AppleSpeechBackendEvent) -> Void) {
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                handler(.result(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
                if result.isFinal {
                    handler(.finished)
                    return
                }
            }
            // Includes "no speech detected" after endAudio(); surfaced as a ProviderError like any other.
            if let error { handler(.failed(error)) }
        }
        let cancelNow: Bool = lock.withLock {
            self.task = task
            return stopped
        }
        if cancelNow { task.cancel() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func endAudio() {
        request.endAudio()
    }

    func cancel() {
        let task: SFSpeechRecognitionTask? = lock.withLock {
            stopped = true
            return self.task
        }
        request.endAudio()
        task?.cancel()
    }
}
