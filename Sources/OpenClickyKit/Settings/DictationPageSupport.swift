import Foundation

/// Settings → Dictation's language list: a language hint for speech to text, or automatic detection.
public enum DictationLanguages {
    /// BCP-47 codes offered in the picker, roughly by how many people dictate in them. Speech-to-text providers take
    /// the hint; Apple Speech uses it to pick its on-device model.
    public static let common: [String] = [
        "en-US", "en-GB", "en-AU", "en-IN", "es-ES", "es-MX", "fr-FR", "fr-CA", "de-DE", "it-IT", "pt-BR", "pt-PT",
        "nl-NL", "sv-SE", "da-DK", "nb-NO", "fi-FI", "pl-PL", "cs-CZ", "tr-TR", "ru-RU", "uk-UA", "el-GR", "he-IL",
        "ar-SA", "hi-IN", "ja-JP", "ko-KR", "zh-CN", "zh-TW", "yue-HK", "vi-VN", "th-TH", "id-ID", "ms-MY",
    ]

    /// "English (United States)", in the user's own language.
    public static func displayName(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code) ?? code
    }

    /// The picker's options: the common list, plus the saved code if it isn't on it.
    public static func options(including saved: String?) -> [String] {
        guard let saved, !saved.isEmpty, !common.contains(saved) else { return common }
        return [saved] + common
    }

    /// The best match for the Mac's preferred languages, for a first choice when automatic detection is turned off.
    public static func suggested(preferred: [String] = Locale.preferredLanguages) -> String {
        for language in preferred {
            if let exact = common.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) { return exact }
            let base = language.split(separator: "-").first.map(String.init) ?? language
            if let near = common.first(where: { $0.hasPrefix(base + "-") }) { return near }
        }
        return "en-US"
    }

    /// Applies the page's two controls to the settings: automatic detection clears the hint.
    public static func apply(autoDetect: Bool, language: String?, to settings: inout DictationSettings) {
        settings.language = autoDetect ? nil : (language?.isEmpty == false ? language : suggested())
    }
}

/// Settings → Dictation's dictionary: the user's words (up to `DictationVocabulary.maxWords`) and why an add failed.
public enum DictionaryEdit {
    public enum Outcome: Sendable, Equatable {
        case added(String)
        case blank
        case tooLong
        case duplicate
        case full

        public var message: String? {
            switch self {
            case .added: nil
            case .blank: "Type a word or name first."
            case .tooLong: "That's longer than \(DictationVocabulary.maxTermLength) characters."
            case .duplicate: "That's already in your dictionary."
            case .full: "The dictionary holds up to \(DictationVocabulary.maxWords) words. Remove one to add another."
            }
        }
    }

    /// Adds a word with a reason when it can't be added.
    public static func add(_ word: String, to vocabulary: inout DictationVocabulary) -> Outcome {
        let collapsed = word.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.isEmpty { return .blank }
        if collapsed.count > DictationVocabulary.maxTermLength { return .tooLong }
        if vocabulary.words.contains(where: { $0.caseInsensitiveCompare(collapsed) == .orderedSame }) { return .duplicate }
        if vocabulary.words.count >= DictationVocabulary.maxWords { return .full }
        return vocabulary.add(collapsed) ? .added(collapsed) : .full
    }
}
