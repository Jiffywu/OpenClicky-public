import AVFoundation
import CryptoKit
import Foundation

/// How the voice speaks, beyond which model and voice fill the slot: playback speed and spoken languages. Saved at
/// `~/Library/Application Support/OpenClicky/voice.json`.
public struct VoiceSettings: Codable, Sendable, Hashable {
    /// Playback speed; the speech player keeps the pitch.
    public var speed: Double
    /// Languages to answer in (BCP 47, "en", "fr-CA"); empty follows the user.
    public var languages: [String]

    public init(speed: Double = 1, languages: [String] = []) {
        self.speed = speed
        self.languages = languages
    }

    /// The speeds the picker offers.
    public static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5]

    public static func label(forSpeed speed: Double) -> String {
        speed == 1 ? "Normal" : String(format: "%gx", speed)
    }

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("voice.json")
    }

    public static func load(from url: URL = defaultURL) -> VoiceSettings {
        guard let data = try? Data(contentsOf: url), var settings = try? JSONDecoder().decode(VoiceSettings.self, from: data) else {
            return VoiceSettings()
        }
        settings.speed = min(max(settings.speed, 0.5), 2)
        return settings
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// One voice the picker can offer.
public struct VoiceOption: Sendable, Hashable, Identifiable {
    /// What goes in the voice slot's `voice` field.
    public var id: String
    public var name: String
    public var detail: String?
    public var language: String?

    public init(id: String, name: String, detail: String? = nil, language: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.language = language
    }
}

/// The voices a voice-slot model offers: the catalog's fixed list, the voices installed on this Mac, or the voices
/// in the user's ElevenLabs account.
public enum VoiceCatalog {
    /// Short descriptions written for OpenClicky's picker (by ear, not from any vendor list).
    static let openAIDetails: [String: String] = [
        "alloy": "Even and neutral", "ash": "Low and calm", "ballad": "Soft, storytelling", "cedar": "Warm, relaxed",
        "coral": "Bright and friendly", "echo": "Clear and direct", "marin": "Natural, upbeat", "sage": "Thoughtful",
        "shimmer": "Light and gentle", "verse": "Lively, expressive", "nova": "Crisp and friendly", "onyx": "Deep and steady",
        "fable": "Animated", "fable-uk": "Animated",
    ]

    /// Voices from the catalog entry for the slot's model, when the model has a fixed list.
    public static func fixedOptions(for model: ModelDescriptor?) -> [VoiceOption]? {
        guard let voices = model?.voices, !voices.isEmpty else { return nil }
        return voices.map { VoiceOption(id: $0, name: $0.prefix(1).uppercased() + $0.dropFirst(), detail: openAIDetails[$0.lowercased()]) }
    }

    /// macOS voices installed on this Mac, best quality first, for one language (or all when nil).
    public static func installedVoices(language: String? = Locale.current.language.languageCode?.identifier) -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                guard let language else { return true }
                return voice.language.hasPrefix(language)
            }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
            .map { voice in
                let quality = switch voice.quality {
                case .premium: "Premium"
                case .enhanced: "Enhanced"
                default: "Compact"
                }
                return VoiceOption(id: voice.identifier, name: voice.name, detail: "\(quality), \(voice.language)", language: voice.language)
            }
    }

    /// The voices in an ElevenLabs account (`GET /v1/voices`), sorted by name. One small request; no audio.
    public static func elevenLabsVoices(context: ProviderContext) async throws -> [VoiceOption] {
        var request = URLRequest(url: context.url("/v1/voices", default: "https://api.elevenlabs.io"))
        request.httpMethod = "GET"
        if let key = context.apiKey { request.setValue(key, forHTTPHeaderField: "xi-api-key") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await context.http.checkedData(for: request, provider: "elevenlabs")
        return try parseElevenLabsVoices(data)
    }

    static func parseElevenLabsVoices(_ data: Data) throws -> [VoiceOption] {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let voices = json["voices"]?.arrayValue ?? []
        return voices.compactMap { voice -> VoiceOption? in
            guard let id = voice["voice_id"]?.stringValue, let name = voice["name"]?.stringValue else { return nil }
            let labels = voice["labels"]?.objectValue ?? [:]
            let parts = ["description", "accent", "use_case"].compactMap { labels[$0]?.stringValue }.filter { !$0.isEmpty }
            let detail = parts.isEmpty ? voice["category"]?.stringValue : parts.joined(separator: ", ")
            return VoiceOption(id: id, name: name, detail: detail, language: labels["language"]?.stringValue)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A preview clip rendered through the voice slot.
public struct VoicePreview: Sendable, Hashable {
    public var voice: String?
    public var text: String
    public var pcm: Data
    public var format: PCMFormat
    /// Where the clip is cached, when caching is on.
    public var fileURL: URL?
    public var fromCache: Bool
    /// Seconds until the first audio arrived (nil for cached clips).
    public var firstAudioSeconds: Double?

    public var duration: Double { Double(pcm.count) / Double(max(1, format.bytesPerSecond)) }
    public var wavData: Data { WAVEncoder.encode(pcm, format: format) }
}

public enum VoicePreviewError: Error, Equatable, CustomStringConvertible {
    case noAudio(String)

    public var description: String {
        switch self {
        case .noAudio(let voice): "The voice \(voice) sent no audio back."
        }
    }
}

/// Renders short preview lines through whatever fills the voice slot and caches them as WAV files under
/// `~/Library/Application Support/OpenClicky/VoicePreviews/`, so each voice costs one request. The app plays the
/// clip at the chosen speed; tests and `occtl voices preview` only write the WAV.
public struct VoicePreviewRenderer: Sendable {
    public static let sampleLine = "Hi, I'm OpenClicky. Hold your talk keys and ask me about anything on your screen."

    public static var defaultCacheDirectory: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("VoicePreviews", isDirectory: true)
    }

    public var makeClient: @Sendable () throws -> any SpeechOutputClient
    /// Names the provider and model in cache keys, so changing either renders fresh clips.
    public var cacheIdentity: String
    public var cacheDirectory: URL?

    public init(cacheIdentity: String, cacheDirectory: URL? = VoicePreviewRenderer.defaultCacheDirectory,
                makeClient: @escaping @Sendable () throws -> any SpeechOutputClient) {
        self.cacheIdentity = cacheIdentity
        self.cacheDirectory = cacheDirectory
        self.makeClient = makeClient
    }

    /// The renderer for the config's voice slot.
    public static func forVoiceSlot(_ factory: EngineFactory, cacheDirectory: URL? = defaultCacheDirectory) throws -> VoicePreviewRenderer {
        let resolution = try factory.resolve(.voice)
        let identity = "\(resolution.provider?.dialect.rawValue ?? "?")|\(resolution.provider?.id ?? "?")|\(resolution.selection.model)"
        return VoicePreviewRenderer(cacheIdentity: identity, cacheDirectory: cacheDirectory) { try factory.speechOutput() }
    }

    func cacheURL(voice: String?, text: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data("\(cacheIdentity)|\(voice ?? "")|\(text)".utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let readable = (voice ?? "default").unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        return cacheDirectory.appendingPathComponent(String(String(readable).prefix(40)) + "-" + digest + ".wav")
    }

    /// The cached clip for a voice, if one was rendered before.
    public func cached(voice: String?, text: String = VoicePreviewRenderer.sampleLine) -> VoicePreview? {
        guard let url = cacheURL(voice: voice, text: text), let data = try? Data(contentsOf: url),
              let audio = try? WAVDecoder.decode(data), !audio.pcm.isEmpty else { return nil }
        return VoicePreview(voice: voice, text: text, pcm: audio.pcm, format: audio.format, fileURL: url, fromCache: true)
    }

    /// Renders (or loads) the preview clip for `voice`; nil uses the slot's own voice.
    public func render(voice: String?, text: String = VoicePreviewRenderer.sampleLine, useCache: Bool = true) async throws -> VoicePreview {
        if useCache, let hit = cached(voice: voice, text: text) { return hit }
        let client = try makeClient()
        let started = Date()
        var pcm = Data()
        var format: PCMFormat?
        var firstAudio: Double?
        for try await event in client.speak(text, voice: voice, instructions: nil) {
            guard case .audio(let chunk, let chunkFormat) = event else { continue }
            if firstAudio == nil { firstAudio = Date().timeIntervalSince(started) }
            pcm.append(chunk)
            format = chunkFormat
        }
        guard let format, !pcm.isEmpty else { throw VoicePreviewError.noAudio(voice ?? "default") }
        var preview = VoicePreview(voice: voice, text: text, pcm: pcm, format: format, fileURL: nil, fromCache: false,
                                   firstAudioSeconds: firstAudio)
        if let url = cacheURL(voice: voice, text: text) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try preview.wavData.write(to: url, options: .atomic)
            preview.fileURL = url
        }
        return preview
    }
}
