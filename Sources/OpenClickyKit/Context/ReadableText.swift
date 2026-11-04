import Foundation

/// Cleaning, trimming and small parsing helpers for text pulled out of pages, files and the Accessibility tree.
public enum ReadableText {
    /// Normalizes line endings and odd spaces, trims every line, collapses runs of spaces and keeps at most one blank
    /// line between paragraphs.
    public static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Invisible characters that only get in the way: zero-width spaces and joiners, soft hyphens, BOMs.
        text.unicodeScalars.removeAll { [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD].contains($0.value) }
        var lines: [String] = []
        var blankRun = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = collapseSpaces(line)
            if collapsed.isEmpty {
                blankRun += 1
                if blankRun == 1, !lines.isEmpty { lines.append("") }
            } else {
                blankRun = 0
                lines.append(collapsed)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func collapseSpaces(_ line: Substring) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        var pendingSpace = false
        for character in line {
            if character == " " || character == "\t" || character == "\u{00A0}" || character == "\u{202F}" || character == "\u{2009}" || character == "\u{3000}" {
                pendingSpace = true
            } else {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    /// Cuts `text` to at most `maxCharacters`, preferring to end at a paragraph, line or word boundary near the limit.
    public static func truncate(_ text: String, maxCharacters: Int) -> (text: String, truncated: Bool) {
        guard maxCharacters > 0 else { return ("", !text.isEmpty) }
        guard text.count > maxCharacters else { return (text, false) }
        let hardEnd = text.index(text.startIndex, offsetBy: maxCharacters)
        let head = text[..<hardEnd]
        // Back up to a boundary only if that keeps most of the budget: a tenth of it, or for small budgets up to half
        // (at most 40 characters).
        let slack = max(maxCharacters / 10, min(40, maxCharacters / 2))
        let floor = text.index(text.startIndex, offsetBy: maxCharacters - slack)
        for separator in ["\n\n", "\n", " "] {
            if let range = head.range(of: separator, options: .backwards), range.lowerBound >= floor {
                return (String(head[..<range.lowerBound]), true)
            }
        }
        return (String(head), true)
    }

    /// The host of a URL string, lowercased, without a leading "www.".
    public static func host(of urlString: String) -> String? {
        guard let host = URLComponents(string: normalizedAddress(urlString) ?? urlString)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Turns what an address bar shows into a full URL: adds "https://" when the scheme is hidden. Returns nil for
    /// text that isn't an address (a search the user is typing, "Favorites", an empty field).
    public static func normalizedAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let scheme = URLComponents(string: trimmed)?.scheme?.lowercased(),
           ["http", "https", "file", "about", "chrome", "edge", "brave", "arc", "safari-resource", "data"].contains(scheme) {
            return trimmed
        }
        // "example.com/path", "localhost:3000", "192.168.1.1"
        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let bareHost = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let looksLikeHost = bareHost == "localhost" || (bareHost.contains(".") && !bareHost.hasPrefix(".") && !bareHost.hasSuffix(".")
            && bareHost.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
        guard looksLikeHost else { return nil }
        let candidate = (bareHost == "localhost" || bareHost.first?.isNumber == true ? "http://" : "https://") + trimmed
        return URLComponents(string: candidate)?.host == nil ? nil : candidate
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<[^>]*>"#)
    private static let dropBlocks = try! NSRegularExpression(pattern: #"<(script|style|noscript|template)\b[^>]*>.*?</\1\s*>"#,
                                                             options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let blockBreaks = try! NSRegularExpression(pattern: #"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/header|/footer)\b[^>]*>"#,
                                                              options: [.caseInsensitive])

    /// Rough text of an HTML file: drops scripts and styles, breaks lines at block ends, removes tags and decodes the
    /// common entities. Good enough to answer questions about a saved page; not a browser.
    public static func textFromHTML(_ html: String) -> String {
        var text = html
        text = replace(dropBlocks, in: text, with: " ")
        text = replace(blockBreaks, in: text, with: "\n")
        text = replace(tagPattern, in: text, with: "")
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return clean(text)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Decodes bytes read from the start of a text file. A multi-byte UTF-8 sequence cut off by the read limit is
    /// dropped rather than turned into a replacement character; other invalid bytes fall back to Latin-1.
    public static func decodeTextPrefix(_ data: Data, isComplete: Bool) -> String {
        var bytes = data
        if !isComplete { bytes = trimIncompleteUTF8Tail(bytes) }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]), let string = String(data: bytes, encoding: .utf16) { return string }
        if let string = String(data: bytes, encoding: .utf8) { return string }
        // Mostly UTF-8 with a few bad bytes: keep it, with replacement characters. Otherwise it's a legacy 8-bit file.
        let lenient = String(decoding: bytes, as: UTF8.self)
        let replacements = lenient.unicodeScalars.lazy.filter { $0 == "\u{FFFD}" }.count
        if replacements * 100 <= max(lenient.unicodeScalars.count, 1) { return lenient }
        return String(data: bytes, encoding: .isoLatin1) ?? lenient
    }

    static func trimIncompleteUTF8Tail(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        // Walk back over at most 3 continuation bytes to the lead byte of the last sequence.
        var index = data.endIndex - 1
        var continuation = 0
        while index > data.startIndex, data[index] & 0xC0 == 0x80, continuation < 3 {
            index -= 1
            continuation += 1
        }
        let lead = data[index]
        let expected: Int
        if lead & 0x80 == 0 { expected = 1 } else if lead & 0xE0 == 0xC0 { expected = 2 } else if lead & 0xF0 == 0xE0 { expected = 3 } else if lead & 0xF8 == 0xF0 { expected = 4 } else { return data }
        return continuation + 1 < expected ? data[data.startIndex..<index] : data
    }

    /// True when the first bytes of a file look like text rather than binary.
    public static func looksLikeText(_ sample: Data) -> Bool {
        guard !sample.isEmpty else { return true }
        if sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) { return true }
        if sample.contains(0) { return false }
        let controls = sample.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0x0C }.count
        return Double(controls) / Double(sample.count) < 0.02
    }
}
