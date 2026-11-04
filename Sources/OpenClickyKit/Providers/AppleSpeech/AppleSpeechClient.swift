// Apple Speech, on device: the stt slot for dialect "apple-speech". No API key, no network calls of our own.
//
// Engines:
// - macOS 26+: SpeechAnalyzer + SpeechTranscriber (see AppleSpeechAnalyzerBackend.swift).
// - Fallback: SFSpeechRecognizer + SFSpeechAudioBufferRecognitionRequest (see AppleSpeechRecognizerBackend.swift).
//
// Primary documentation (Apple Developer, fetched 2026-10-30) and the installed MacOSX27.0 SDK's Speech headers and
// Speech.swiftinterface:
// - https://developer.apple.com/documentation/speech/speechanalyzer
// - https://developer.apple.com/documentation/speech/speechtranscriber
// - https://developer.apple.com/documentation/speech/sfspeechrecognizer/requestauthorization(_:)
// - https://developer.apple.com/documentation/speech/sfspeechrecognizer/authorizationstatus()
// - https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest
// - https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings
//
// Authorization: requestAuthorization "causes the system to prompt the user" when the status is notDetermined, and
// the app crashes if its Info.plist lacks NSSpeechRecognitionUsageDescription. That permission belongs to
// SFSpeechRecognizer. Apple's SpeechAnalyzer pages don't mention it, and on macOS 27.2 SpeechAnalyzer +
// SpeechTranscriber transcribed live audio in a process whose status was notDetermined and that had no usage
// string. So the adapter asks for permission only before falling back to SFSpeechRecognizer. An explicit "no"
// (denied by the user, or restricted by Screen Time or a profile) is still honoured for both engines.
import Foundation
import Speech

/// Which Apple engine a session runs on.
public enum AppleSpeechEngine: String, Sendable, CaseIterable {
    /// SpeechAnalyzer on macOS 26+ when it supports the language, otherwise SFSpeechRecognizer.
    case automatic
    /// Always SFSpeechRecognizer.
    case speechRecognizer
}

/// On-device speech-to-text with Apple's Speech framework.
public struct AppleSpeechClient: SpeechToTextClient {
    public let inputFormat: PCMFormat = .speech16k

    private let providerID: String
    private let engine: AppleSpeechEngine
    private let promptsForAuthorization: Bool
    private let authorizer: any SpeechRecognitionAuthorizing
    private let backends: AppleSpeechBackendFactory

    /// - Parameters:
    ///   - context: Only `provider.id` is used (for error messages). On-device dialects ignore the API key, base URL
    ///     and transports.
    ///   - engine: `.automatic` prefers SpeechAnalyzer where available.
    ///   - promptsForAuthorization: When SFSpeechRecognizer is needed and the user hasn't decided yet, ask (shows
    ///     the system prompt). When false, such sessions fail with a ProviderError instead, for callers that ask
    ///     during onboarding. SpeechAnalyzer sessions don't ask.
    public init(context: ProviderContext, engine: AppleSpeechEngine = .automatic, promptsForAuthorization: Bool = true) {
        self.init(context: context, engine: engine, promptsForAuthorization: promptsForAuthorization,
                  authorizer: SystemSpeechRecognitionAuthorizer(providerID: context.provider.id))
    }

    init(context: ProviderContext, engine: AppleSpeechEngine, promptsForAuthorization: Bool,
         authorizer: any SpeechRecognitionAuthorizing, backends: AppleSpeechBackendFactory = .system) {
        self.providerID = context.provider.id
        self.engine = engine
        self.promptsForAuthorization = promptsForAuthorization
        self.authorizer = authorizer
        self.backends = backends
    }

    public func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        // A refusal the user (or an administrator) already made covers transcription by either engine.
        if let refusal = Self.refusal(authorizer.status(), provider: providerID) { throw refusal }
        let locale = Self.locale(for: language)
        let strings = Self.contextualStrings(from: keywords)
        let backend = try await makeBackend(locale: locale, contextualStrings: strings)
        do {
            return try AppleSpeechSession(providerID: providerID, inputFormat: inputFormat, backend: backend)
        } catch {
            backend.cancel()
            throw error
        }
    }

    private func makeBackend(locale: Locale, contextualStrings: [String]) async throws -> any AppleSpeechBackend {
        var analyzerFailure: (any Error)?
        if engine == .automatic {
            do {
                if let analyzer = try await backends.analyzer(locale, contextualStrings) { return analyzer }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Assets couldn't be installed or the analyzer failed to start (for example offline on first
                // use). SFSpeechRecognizer may still have an on-device model for this language.
                analyzerFailure = error
            }
        }
        try Task.checkCancellation()
        do {
            // Only SFSpeechRecognizer needs the speech-recognition permission, so ask for it only now.
            try await Self.authorize(provider: providerID, authorizer: authorizer, prompt: promptsForAuthorization)
            try Task.checkCancellation()
            return try backends.recognizer(locale, contextualStrings, providerID)
        } catch let error as ProviderError {
            guard let analyzerFailure else { throw error }
            // Both engines failed: say why SpeechAnalyzer couldn't be used too, or that cause is lost.
            var combined = error
            combined.message += " (SpeechAnalyzer couldn't be used either: "
                + "\(AppleSpeechErrors.wrap(analyzerFailure, provider: providerID).message))"
            throw combined
        }
    }

    // MARK: - Seams (internal for tests)

    /// nil or blank means the user's current locale. Accepts BCP 47 ("en-US") and ICU ("en_US") identifiers.
    static func locale(for language: String?) -> Locale {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
            return .current
        }
        return Locale(identifier: language)
    }

    /// Trimmed, non-empty, de-duplicated, and capped at the 100 phrases Apple recommends at most
    /// (https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings).
    static func contextualStrings(from keywords: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == 100 { break }
        }
        return result
    }

    /// SFSpeechRecognizer's requirement: authorized, asking first when undecided and `prompt` allows it.
    static func authorize(provider: String, authorizer: any SpeechRecognitionAuthorizing, prompt: Bool) async throws {
        var status = authorizer.status()
        if status == .notDetermined, prompt {
            status = try await authorizer.request()
        }
        if let refusal = refusal(status, provider: provider) { throw refusal }
        if status == .notDetermined {
            throw ProviderError(provider: provider, message: "Speech recognition permission has not been "
                + "granted yet. Allow OpenClicky to use speech recognition, then try again.")
        }
    }

    /// The error for a decision against speech recognition, or nil when there is none.
    static func refusal(_ status: SpeechRecognitionAuthorization, provider: String) -> ProviderError? {
        switch status {
        case .denied:
            ProviderError(provider: provider, message: "Speech recognition permission was denied. Allow "
                + "OpenClicky in System Settings > Privacy & Security > Speech Recognition, then try again.")
        case .restricted:
            ProviderError(provider: provider, message: "Speech recognition is restricted on this Mac "
                + "(for example by Screen Time or a device management profile).")
        case .authorized, .notDetermined:
            nil
        }
    }
}

// MARK: - Engines

/// Builds the two engines. The system factory talks to Speech; tests substitute scripted engines so they never
/// start a recognizer, reserve a language or download a model.
struct AppleSpeechBackendFactory: Sendable {
    /// SpeechAnalyzer, or nil when it can't serve this Mac or language (the client then falls back).
    var analyzer: @Sendable (_ locale: Locale, _ contextualStrings: [String]) async throws -> (any AppleSpeechBackend)?
    /// SFSpeechRecognizer. Called only once speech recognition is authorized.
    var recognizer: @Sendable (_ locale: Locale, _ contextualStrings: [String], _ provider: String) throws
        -> any AppleSpeechBackend

    static let system = AppleSpeechBackendFactory(
        analyzer: { locale, contextualStrings in
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                return try await AppleSpeechAnalyzerBackend.make(locale: locale, contextualStrings: contextualStrings)
            }
            #endif
            return nil
        },
        recognizer: { locale, contextualStrings, provider in
            try AppleSpeechRecognizerBackend(locale: locale, contextualStrings: contextualStrings, provider: provider)
        })
}

// MARK: - Authorization

enum SpeechRecognitionAuthorization: Sendable, Equatable {
    case notDetermined, denied, restricted, authorized
}

/// The authorization seam: the real one talks to SFSpeechRecognizer; tests substitute a fake so they never prompt.
protocol SpeechRecognitionAuthorizing: Sendable {
    func status() -> SpeechRecognitionAuthorization
    /// Ask the user. Only called when `status()` is `.notDetermined`.
    func request() async throws -> SpeechRecognitionAuthorization
}

struct SystemSpeechRecognitionAuthorizer: SpeechRecognitionAuthorizing {
    static let usageDescriptionKey = "NSSpeechRecognitionUsageDescription"
    let providerID: String

    func status() -> SpeechRecognitionAuthorization {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    func request() async throws -> SpeechRecognitionAuthorization {
        // requestAuthorization crashes a process whose Info.plist lacks the usage string (occtl, test runners).
        guard Bundle.main.object(forInfoDictionaryKey: Self.usageDescriptionKey) != nil else {
            throw ProviderError(provider: providerID, message: "Speech recognition permission has not been "
                + "granted, and this process can't ask for it: its Info.plist has no \(Self.usageDescriptionKey).")
        }
        return await withCheckedContinuation { continuation in
            // "The system does not guarantee the execution of this block on your app's main dispatch queue."
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.map(status))
            }
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechRecognitionAuthorization {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
