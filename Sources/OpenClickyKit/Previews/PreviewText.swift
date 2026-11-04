import Foundation

/// Reads a text file for a native preview: at most `maxBytes` of it, cut at the last whole line, and decoded as UTF-8,
/// UTF-16 when the file starts with a byte-order mark, else Windows-1252 (which covers Latin-1 exports).
public enum PreviewText {
    /// Spreadsheets: the grid shows 5,000 rows at most, which fit well inside this.
    public static let spreadsheetMaxBytes = 8 * 1024 * 1024
    /// Markdown: every block becomes a view, so a smaller share of a huge file is shown.
    public static let markdownMaxBytes = 1024 * 1024

    public struct Loaded: Sendable, Hashable {
        public var text: String
        /// True when the file is longer than what was read.
        public var truncated: Bool
    }

    public static func read(_ url: URL, maxBytes: Int) throws -> Loaded {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = max(0, maxBytes)
        var data = try handle.read(upToCount: limit + 1) ?? Data()
        let truncated = data.count > limit
        if truncated { data = wholeLines(data.prefix(limit)) }
        return Loaded(text: decode(data), truncated: truncated)
    }

    public static func decode(_ data: Data) -> String {
        if utf16Mark(data) != nil, let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// A cut-off prefix up to its last line break, so no row or character is split; without a line break, up to the
    /// last whole UTF-8 character.
    static func wholeLines(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        if let bigEndian = utf16Mark(data) {
            var offset = (bytes.count - 2) & ~1
            while offset >= 2 {
                let unit = bigEndian ? UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) : UInt16(bytes[offset + 1]) << 8 | UInt16(bytes[offset])
                if unit == 0x0A { return Data(bytes[..<(offset + 2)]) }
                offset -= 2
            }
            return Data(bytes[..<(bytes.count & ~1)])
        }
        if let newline = bytes.lastIndex(of: 0x0A) { return Data(bytes[...newline]) }
        var end = bytes.count
        while end > 0, bytes[end - 1] & 0xC0 == 0x80 { end -= 1 }
        if end > 0, bytes[end - 1] >= 0xC0 { end -= 1 }
        return Data(bytes[..<end])
    }

    /// True for a big-endian byte-order mark, false for little-endian, nil for none.
    static func utf16Mark(_ data: Data) -> Bool? {
        guard data.count >= 2 else { return nil }
        let first = data[data.startIndex], second = data[data.startIndex + 1]
        if first == 0xFE, second == 0xFF { return true }
        if first == 0xFF, second == 0xFE { return false }
        return nil
    }
}
