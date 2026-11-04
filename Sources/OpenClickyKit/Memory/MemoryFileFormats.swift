import Foundation

/// Reading and writing the memory folder's files. All formats are plain text a person can edit; readers are
/// forgiving and writers produce the canonical form.
public enum MemoryFileFormat {
    // MARK: - standing-context.md

    static let standingHeader = """
        # Standing context

        Requests OpenClicky keeps in mind in every conversation. One per line, each starting with "- ".
        """

    /// The items of `standing-context.md`: every `- `, `* ` or `+ ` line. Headings and other text are ignored.
    public static func parseStanding(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap(MemoryProfile.bulletText)
    }

    public static func renderStanding(_ lines: [String]) -> String {
        var text = standingHeader + "\n"
        if !lines.isEmpty { text += "\n" + lines.map { "- \(MemoryText.oneLine($0))" }.joined(separator: "\n") + "\n" }
        return text
    }

    // MARK: - how-tos.md

    static let howToHeader = """
        # Learned how-tos

        Things OpenClicky learned about doing tasks for this user. Each starts with a "## " title.
        """

    /// `## title` blocks; the text under each title (trimmed) is its steps. Text before the first title is ignored.
    public static func parseHowTos(_ text: String) -> [MemoryHowTo] {
        var result: [MemoryHowTo] = []
        var current: (title: String, lines: [String])?
        func close() {
            if let block = current {
                result.append(MemoryHowTo(title: block.title, steps: block.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        for line in text.components(separatedBy: .newlines) {
            if let title = MemoryProfile.heading(line, level: 2) {
                close()
                current = (title, [])
            } else if MemoryProfile.heading(line, level: 1) != nil {
                close()
                current = nil
            } else {
                current?.lines.append(line)
            }
        }
        close()
        return result
    }

    public static func renderHowTos(_ howTos: [MemoryHowTo]) -> String {
        var text = howToHeader + "\n"
        for howTo in howTos {
            text += "\n## \(MemoryText.oneLine(howTo.title))\n"
            let steps = howTo.steps.trimmingCharacters(in: .whitespacesAndNewlines)
            if !steps.isEmpty { text += stepsBody(steps) + "\n" }
        }
        return text
    }

    /// Steps as they go under their title. A step line that reads as a `# ` or `## ` heading would end the how-to
    /// (or start a new one) when the file is read back, so it becomes a `### ` subheading instead.
    static func stepsBody(_ steps: String) -> String {
        steps.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line in
            guard MemoryProfile.heading(line, level: 1) != nil || MemoryProfile.heading(line, level: 2) != nil else { return line }
            return "###" + line.drop { $0 == "#" }
        }.joined(separator: "\n")
    }

    // MARK: - memories.jsonl

    /// The parsed records, plus any lines that could not be read. Unreadable lines are written back untouched so a
    /// hand edit that went wrong is never silently lost.
    public struct MemoriesFile: Sendable, Hashable {
        public var records: [MemoryRecord]
        public var unreadableLines: [String]

        public init(records: [MemoryRecord] = [], unreadableLines: [String] = []) {
            self.records = records
            self.unreadableLines = unreadableLines
        }
    }

    public static func parseMemories(_ text: String) -> MemoriesFile {
        var file = MemoriesFile()
        let decoder = jsonDecoder
        // Records are separated by "\n" only. JSON strings may hold other line breaks (U+2028, U+0085) unescaped,
        // and splitting on those would break a valid record in two.
        let unix = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in unix.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let record = try? decoder.decode(MemoryRecord.self, from: Data(trimmed.utf8)) {
                file.records.append(record)
            } else {
                file.unreadableLines.append(line)
            }
        }
        return file
    }

    public static func renderMemories(_ file: MemoriesFile) -> String {
        let encoder = jsonEncoder
        let lines = file.records.compactMap { record in
            (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) }
        }
        let all = lines + file.unreadableLines
        return all.isEmpty ? "" : all.joined(separator: "\n") + "\n"
    }

    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Accepts what a person might type when editing the file: full ISO 8601 with or without fractional seconds, or
    /// a plain date.
    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    static func parseDate(_ text: String) -> Date? {
        let options: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate],
        ]
        for option in options {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = option
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
