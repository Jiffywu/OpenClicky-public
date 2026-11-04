import Foundation

/// The places where HeyClicky gets a model through its own server, and where OpenClicky lets the user pick one.
/// Everything else in the app is fixed code.
public enum SlotID: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    /// Live dictation and talk-key transcription (HeyClicky 1.1.2: Gemini Live "ears" with a batch fallback;
    /// earlier builds: Deepgram nova-3; Apple Speech as the offline fallback).
    case stt
    /// Speaks the brain's lines aloud (HeyClicky: OpenAI gpt-realtime-2.1-mini, the "mouth").
    case voice
    /// Reads the screen and the user's words, answers, points and writes drawing programs
    /// (HeyClicky: GPT-6.1 Sol through `/brain/turn`).
    case brain
    /// Fast, cheap text work: dictation cleanup, thread compaction, session memory notes, job titles
    /// (HeyClicky: server-side, Claude Haiku per its logs). Optional: falls back to the brain slot.
    case brainFast = "brain-fast"
    /// Background jobs run by an agent harness (HeyClicky: its own harness or Codex, model gpt-6-luna).
    case agent
    /// Always-on and interview modes: one realtime speech-to-speech session that listens, answers aloud and calls
    /// tools (HeyClicky "full voice": gpt-realtime-2.1). Optional: without it those modes are off.
    case realtimeVoice = "realtime-voice"

    /// Optional slots turn a feature off (or fall back) when empty instead of failing validation.
    public var isOptional: Bool { self == .brainFast || self == .realtimeVoice }

    /// What a model must be to fill this slot.
    public var requirement: SlotRequirement {
        switch self {
        case .stt:
            SlotRequirement(
                kinds: [.speechToText],
                required: [.audioInput, .textOutput],
                preferred: [.streaming: "transcripts only arrive after the user lets go of the talk keys",
                            .interimResults: "no live caption while the user is speaking"])
        case .voice:
            SlotRequirement(
                kinds: [.textToSpeech, .realtimeSpeech],
                required: [.textInput, .audioOutput],
                preferred: [.streaming: "speech starts only after each whole line is synthesized"])
        case .brain:
            SlotRequirement(
                kinds: [.languageModel],
                required: [.textInput, .textOutput, .toolCalling, .streaming],
                preferred: [.imageInput: "the brain cannot see screenshots; it gets the Accessibility text of the screen instead"])
        case .brainFast:
            SlotRequirement(
                kinds: [.languageModel],
                required: [.textInput, .textOutput],
                preferred: [.streaming: "cleaned-up dictation appears only once the whole reply is back"])
        case .realtimeVoice:
            SlotRequirement(
                kinds: [.realtimeSpeech],
                required: [.audioInput, .audioOutput, .toolCalling, .streaming],
                preferred: [.imageInput: "always-on mode cannot look at your screen"])
        case .agent:
            SlotRequirement(
                kinds: [.languageModel],
                required: [.textInput, .textOutput, .toolCalling],
                preferred: [.imageInput: "the agent cannot look at screenshots or images it finds"])
        }
    }
}

/// The contract a slot imposes on its model.
public struct SlotRequirement: Sendable {
    /// Model kinds the slot accepts. Anything else is rejected outright.
    public var kinds: Set<ModelKind>
    /// Capabilities the model must declare.
    public var required: Set<Capability>
    /// Capabilities the slot works better with, and what the user loses without each.
    public var preferred: [Capability: String]
}

/// The user's choice for one slot.
public struct SlotSelection: Codable, Sendable, Hashable {
    /// Id of a configured provider.
    public var provider: String
    /// Model id as the provider knows it.
    public var model: String
    /// Agent slot only: which harness runs the job.
    public var harness: HarnessKind?
    /// Voice slot only: which voice to speak with.
    public var voice: String?
    /// Agent slot: the reasoning effort jobs run with ("low", "medium", …); nil or "default" leaves the harness's own.
    public var reasoningEffort: String?

    public init(provider: String, model: String, harness: HarnessKind? = nil, voice: String? = nil, reasoningEffort: String? = nil) {
        self.provider = provider
        self.model = model
        self.harness = harness
        self.voice = voice
        self.reasoningEffort = reasoningEffort
    }
}
