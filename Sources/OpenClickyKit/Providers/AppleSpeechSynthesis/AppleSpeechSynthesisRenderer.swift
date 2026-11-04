// The live renderer (AVSpeechSynthesizer) and voice selection for AppleSpeechSynthesisClient.
// Sources and observed behaviour are listed at the top of AppleSpeechSynthesisClient.swift.

import AVFAudio
import Foundation

extension AppleSpeechSynthesisClient {
    /// Renders one line with its own AVSpeechSynthesizer, which it keeps alive until `stop()`.
    final class SynthesizerRenderer: Renderer, @unchecked Sendable {
        /// Every synthesizer call happens on this queue, which also confines the properties below.
        private static let queue = DispatchQueue(label: "OpenClicky.AppleSpeechSynthesis", qos: .userInitiated)

        private var synthesizer: AVSpeechSynthesizer?
        private var observer: DelegateObserver?
        private var stopped = false

        func start(text: String, voice: String?, line: Line) {
            Self.queue.async { [self] in
                guard !stopped else { return }
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AppleSpeechSynthesisClient.resolveVoice(voice)
                let synthesizer = AVSpeechSynthesizer()
                let observer = DelegateObserver(line: line)
                synthesizer.delegate = observer  // weak; retained by `observer` below
                self.synthesizer = synthesizer
                self.observer = observer
                synthesizer.write(utterance) { buffer in line.deliver(buffer) }
            }
        }

        func stop() {
            Self.queue.async { [self] in
                stopped = true
                guard let synthesizer else { return }
                synthesizer.delegate = nil
                synthesizer.stopSpeaking(at: .immediate)
                // On macOS 27.2 stopSpeaking does not stop a write in progress; releasing the synthesizer does.
                self.synthesizer = nil
                observer = nil
            }
        }
    }

    /// AVSpeechSynthesizerDelegate, forwarding the end of the utterance to its line.
    final class DelegateObserver: NSObject, AVSpeechSynthesizerDelegate {
        let line: Line

        init(line: Line) { self.line = line }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            line.synthesizerDidFinish()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            line.synthesizerDidCancel()
        }
    }
}

// MARK: - Voice selection

extension AppleSpeechSynthesisClient {
    /// What `chooseVoice` needs to know about an installed voice.
    struct VoiceInfo: Sendable, Hashable {
        var identifier: String
        var name: String
        /// BCP 47, e.g. `en-US`.
        var language: String
        /// `AVSpeechSynthesisVoiceQuality.rawValue`: 1 default, 2 enhanced, 3 premium.
        var quality: Int
    }

    enum VoiceChoice: Sendable, Hashable {
        /// Leave `utterance.voice` nil: the system default voice.
        case systemDefault
        case identifier(String)
        /// A BCP 47 tag of an installed voice, for `AVSpeechSynthesisVoice(language:)`, which picks the best voice
        /// installed for it.
        case language(String)
    }

    /// Maps the configured voice to an installed one. In order: an exact identifier; a name, case- and
    /// diacritic-insensitive, preferring the user's language and then the highest quality; a language tag (`en-GB`,
    /// `en_gb`), or its base language when that region is not installed (`fr`, `fr-BE` → `fr-FR`). Anything else is
    /// the system default.
    static func chooseVoice(_ requested: String?, among voices: [VoiceInfo], preferredLanguage: String) -> VoiceChoice {
        guard let requested = nonBlank(requested) else { return .systemDefault }
        if voices.contains(where: { $0.identifier == requested }) { return .identifier(requested) }

        let preferred = normalizedLanguage(preferredLanguage)
        let preferredBase = baseLanguage(preferred)

        // Names repeat across languages (Eddy, Flo) and qualities (compact and enhanced Samantha).
        func rank(_ voice: VoiceInfo) -> (Int, Int, Int) {
            let language = normalizedLanguage(voice.language)
            return (language == preferred ? 0 : 1, baseLanguage(language) == preferredBase ? 0 : 1, -voice.quality)
        }
        let named = voices.filter {
            $0.name.compare(requested, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if let best = named.min(by: { rank($0) < rank($1) }) { return .identifier(best.identifier) }

        let wanted = normalizedLanguage(requested)
        if let exact = voices.first(where: { normalizedLanguage($0.language) == wanted }) {
            return .language(exact.language)
        }
        let base = baseLanguage(wanted)
        let sameBase = voices.filter { baseLanguage(normalizedLanguage($0.language)) == base }
        guard !sameBase.isEmpty else { return .systemDefault }
        // The user's own region if it speaks this language, then the language's home region (fr-FR, de-DE), then
        // the first installed.
        let pick = sameBase.first { normalizedLanguage($0.language) == preferred }
            ?? sameBase.first { normalizedLanguage($0.language) == "\(base)-\(base)" }
            ?? sameBase[0]
        return .language(pick.language)
    }

    /// The voice to set on the utterance; nil means the system default.
    static func resolveVoice(_ requested: String?) -> AVSpeechSynthesisVoice? {
        guard let requested = nonBlank(requested) else { return nil }
        // The common case, a stored identifier, without listing every voice.
        if let voice = AVSpeechSynthesisVoice(identifier: requested) { return voice }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let infos = voices.map {
            VoiceInfo(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue)
        }
        switch chooseVoice(requested, among: infos, preferredLanguage: AVSpeechSynthesisVoice.currentLanguageCode()) {
        case .systemDefault: return nil
        case .identifier(let identifier): return voices.first { $0.identifier == identifier }
        case .language(let tag): return AVSpeechSynthesisVoice(language: tag)
        }
    }

    /// Lowercased, with `_` read as `-`.
    private static func normalizedLanguage(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func baseLanguage(_ normalized: String) -> String {
        String(normalized.prefix { $0 != "-" })
    }
}
