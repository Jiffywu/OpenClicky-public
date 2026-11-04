import Foundation

extension VoiceEars {
    /// The ears for the user's stt slot: its client (kept for warm connections), its batch side as the first fallback,
    /// and the on-device recognizer as the last fallback and as the alternate while the slot's account is refusing.
    /// Throws when the stt slot can't be built (empty, invalid, or missing its key).
    ///
    /// - Parameter onDevice: The on-device recognizer; by default Apple Speech that never asks for permission itself
    ///   (where it would need Speech Recognition permission and doesn't have it, that fallback fails quietly).
    public static func make(factory: EngineFactory, policy: Policy = Policy(), usage: UsageStore = .memory(),
                            language: String? = nil, keywords: [String] = [],
                            onDevice: (any SpeechToTextClient)? = VoiceEars.appleOnDevice()) throws -> VoiceEars {
        let resolution = try factory.resolve(.stt)
        let client = try factory.speechToText()
        let dialect = resolution.provider?.dialect
        let primary = Recognizer(name: "\(resolution.selection.provider) / \(resolution.selection.model)", client: client)
        var fallbacks: [Fallback] = []
        var alternate: Recognizer?
        if dialect == .appleSpeech {
            // Already on device: a failed stream is heard once more by the same recognizer.
            fallbacks.append(Fallback(name: "\(primary.name) (again, in one pass)", client: StreamingReplayBatchClient(client: client),
                                      sharesPrimaryAccount: false))
        } else {
            if let batch = try? factory.speechToTextBatch() {
                let name = (batch as? GeminiTranscriptionClient).map { "\(resolution.selection.provider) / \($0.model)" }
                    ?? "\(primary.name) (again, in one pass)"
                fallbacks.append(Fallback(name: name, client: batch, sharesPrimaryAccount: !(dialect?.isOnDevice ?? false)))
            }
            if let onDevice {
                fallbacks.append(Fallback(name: "Apple Speech (on device)", client: StreamingReplayBatchClient(client: onDevice),
                                          sharesPrimaryAccount: false))
                alternate = Recognizer(name: "Apple Speech (on device)", client: onDevice)
            }
        }
        return VoiceEars(primary: primary, alternate: alternate, fallbacks: fallbacks, policy: policy, usage: usage,
                         language: language, keywords: keywords)
    }

    /// Apple's on-device recognizer, set never to show the Speech Recognition prompt in the middle of a press.
    public static func appleOnDevice() -> any SpeechToTextClient {
        AppleSpeechClient(context: ProviderContext(provider: ProviderConfig(id: "apple-speech", dialect: .appleSpeech), apiKey: nil),
                          promptsForAuthorization: false)
    }
}
