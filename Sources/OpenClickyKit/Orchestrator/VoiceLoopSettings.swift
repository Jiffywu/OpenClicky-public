import Foundation

/// How the voice loop behaves around the answer, saved at `~/Library/Application Support/OpenClicky/voice-loop.json`.
/// Missing keys take their defaults. The voice itself (model, voice, speed) lives in config.json and voice.json.
public struct VoiceLoopSettings: Codable, Sendable, Hashable {
    /// Read answers to typed questions aloud (otherwise they appear in the text panel and draw at once).
    public var speaksTypedAnswers: Bool
    /// Show the line being spoken as a caption at the bottom of the screen.
    public var showsCaptions: Bool
    /// Play short sounds when the mic opens and closes, and when something fails.
    public var playsCues: Bool
    /// Show the last turn's step timings in the notch pill (for tuning latency).
    public var showsTimings: Bool
    /// The user allowed take-overs to move the pointer, click and type for real (each drive still needs their yes on
    /// the consent card). Off, the default: drives are rehearsals that show what they would do and post nothing.
    public var takeoverPostsInput: Bool
    /// Reveal the caption word by word as the words are heard (otherwise the whole line shows at once).
    public var captionsWordByWord: Bool
    /// The caption's text size in points (14 to 28).
    public var captionSize: Double
    /// Show the drawing's beats under the caption: each statement of the line being heard, waiting, drawing or done
    /// (for tuning drawings).
    public var showsBeatChips: Bool
    /// Play the soft pen, pop and paper sounds of a drawing as it is drawn.
    public var playsDrawingSounds: Bool

    /// The microphone to listen with (an input device UID); nil follows the system default input.
    public var microphoneUID: String?
    /// Echo cancellation for always-on voice on speakers (docs/audio-robustness.md).
    public var echoCancellation: EchoCancellationMode
    /// While on a call, recording, or in a Focus, hold job reports, routine notices, meeting countdowns and onboarding
    /// prompts until it's over.
    public var holdsDuringQuiet: Bool
    /// When the Mac is muted or at zero volume, answer silently, copy the reply and offer to unmute.
    public var handlesMutedOutput: Bool

    public init(speaksTypedAnswers: Bool = false, showsCaptions: Bool = true, playsCues: Bool = true, showsTimings: Bool = false,
                captionsWordByWord: Bool = true, captionSize: Double = 17, showsBeatChips: Bool = false,
                playsDrawingSounds: Bool = true, takeoverPostsInput: Bool = false, microphoneUID: String? = nil, echoCancellation: EchoCancellationMode = .automatic,
                holdsDuringQuiet: Bool = true, handlesMutedOutput: Bool = true) {
        self.speaksTypedAnswers = speaksTypedAnswers
        self.showsCaptions = showsCaptions
        self.playsCues = playsCues
        self.showsTimings = showsTimings
        self.takeoverPostsInput = takeoverPostsInput
        self.captionsWordByWord = captionsWordByWord
        self.captionSize = min(max(captionSize, 14), 28)
        self.showsBeatChips = showsBeatChips
        self.playsDrawingSounds = playsDrawingSounds
        self.microphoneUID = microphoneUID
        self.echoCancellation = echoCancellation
        self.holdsDuringQuiet = holdsDuringQuiet
        self.handlesMutedOutput = handlesMutedOutput
    }

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("voice-loop.json")
    }

    private enum CodingKeys: String, CodingKey {
        case speaksTypedAnswers, showsCaptions, playsCues, showsTimings, takeoverPostsInput
        case captionsWordByWord, captionSize, showsBeatChips, playsDrawingSounds
        case microphoneUID, echoCancellation, holdsDuringQuiet, handlesMutedOutput
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceLoopSettings()
        speaksTypedAnswers = try c.decodeIfPresent(Bool.self, forKey: .speaksTypedAnswers) ?? defaults.speaksTypedAnswers
        showsCaptions = try c.decodeIfPresent(Bool.self, forKey: .showsCaptions) ?? defaults.showsCaptions
        playsCues = try c.decodeIfPresent(Bool.self, forKey: .playsCues) ?? defaults.playsCues
        showsTimings = try c.decodeIfPresent(Bool.self, forKey: .showsTimings) ?? defaults.showsTimings
        takeoverPostsInput = try c.decodeIfPresent(Bool.self, forKey: .takeoverPostsInput) ?? defaults.takeoverPostsInput
        captionsWordByWord = try c.decodeIfPresent(Bool.self, forKey: .captionsWordByWord) ?? defaults.captionsWordByWord
        captionSize = min(max(try c.decodeIfPresent(Double.self, forKey: .captionSize) ?? defaults.captionSize, 14), 28)
        showsBeatChips = try c.decodeIfPresent(Bool.self, forKey: .showsBeatChips) ?? defaults.showsBeatChips
        playsDrawingSounds = try c.decodeIfPresent(Bool.self, forKey: .playsDrawingSounds) ?? defaults.playsDrawingSounds
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID)
        echoCancellation = (try? c.decodeIfPresent(EchoCancellationMode.self, forKey: .echoCancellation)) ?? defaults.echoCancellation
        holdsDuringQuiet = try c.decodeIfPresent(Bool.self, forKey: .holdsDuringQuiet) ?? defaults.holdsDuringQuiet
        handlesMutedOutput = try c.decodeIfPresent(Bool.self, forKey: .handlesMutedOutput) ?? defaults.handlesMutedOutput
    }

    public static func load(from url: URL = defaultURL) -> VoiceLoopSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(VoiceLoopSettings.self, from: data) else {
            return VoiceLoopSettings()
        }
        return settings
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
