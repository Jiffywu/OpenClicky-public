import Foundation

// Block-level Markdown for native previews (a job's report, `.md` deliverables): headings, paragraphs, lists with
// nesting and task boxes, fenced code, pipe tables, block quotes, rules and standalone images. Inline styling (bold,
// links, code spans) stays in each block's text for the view to render; this parser only finds the blocks. It is
// forgiving the way readers are: anything it doesn't recognise is a paragraph.

public enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(MarkdownList)
    case code(language: String?, text: String)
    case table(MarkdownTable)
    /// A block quote's own blocks.
    case quote([MarkdownBlock])
    case rule
    /// An image on a line of its own (`![alt](source)`).
    case image(alt: String, source: String)
}

public struct MarkdownList: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        /// Nesting level, 0 for the outermost.
        public var depth: Int
        /// The number for an ordered item (as written), nil for a bullet.
        public var ordinal: Int?
        /// A task box: false for `[ ]`, true for `[x]`, nil for none.
        public var checked: Bool?
        public var text: String

        public init(depth: Int = 0, ordinal: Int? = nil, checked: Bool? = nil, text: String) {
            self.depth = depth
            self.ordinal = ordinal
            self.checked = checked
            self.text = text
        }
    }

    public var ordered: Bool
    public var items: [Item]

    public init(ordered: Bool, items: [Item]) {
        self.ordered = ordered
        self.items = items
    }
}

public struct MarkdownTable: Sendable, Hashable {
    public enum Alignment: String, Sendable, Hashable { case leading, center, trailing }

    public var header: [String]
    public var alignments: [Alignment]
    /// Body rows, each padded or cut to the header's width.
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

public enum MarkdownBlockParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        return parse(lines: lines[...], depth: 0)
    }

    /// How many block quotes can nest; deeper `>` markers stay in the text. Each level is parsed (and drawn) by a call
    /// of its own, so an untrusted file with a long run of `>` would otherwise overflow the stack.
    public static let maxQuoteDepth = 8

    // MARK: Blocks

    static func parse(lines: ArraySlice<String>, depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = lines.startIndex
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(joinParagraph(paragraph)))
            paragraph = []
        }

        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            // Fenced code.
            if let fence = codeFence(trimmed) {
                flushParagraph()
                let indent = leadingSpaces(line)
                var body: [String] = []
                index += 1
                while index < lines.endIndex {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker), candidate.allSatisfy({ $0 == fence.marker.first }) { index += 1; break }
                    body.append(String(lines[index].dropFirst(min(indent, leadingSpaces(lines[index])))))
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }
            // Setext heading underline (`===` / `---` under a paragraph line).
            if !paragraph.isEmpty, let level = setextLevel(trimmed) {
                let text = joinParagraph(paragraph)
                paragraph = []
                blocks.append(.heading(level: level, text: text))
                index += 1
                continue
            }
            if let heading = atxHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">"), depth < maxQuoteDepth {
                flushParagraph()
                var inner: [String] = []
                while index < lines.endIndex {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var rest = candidate.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    index += 1
                }
                blocks.append(.quote(parse(lines: inner[...], depth: depth + 1)))
                continue
            }
            // A table: a row with pipes over a delimiter row.
            if line.contains("|"), index + 1 < lines.endIndex, let alignments = delimiterRow(lines[index + 1]) {
                let header = cells(line)
                if header.count == alignments.count || (header.count > 0 && alignments.count > 0) {
                    flushParagraph()
                    let width = max(header.count, alignments.count)
                    var rows: [[String]] = []
                    index += 2
                    while index < lines.endIndex {
                        let row = lines[index]
                        guard row.contains("|"), !row.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                        rows.append(pad(cells(row), to: width))
                        index += 1
                    }
                    blocks.append(.table(MarkdownTable(header: pad(header, to: width),
                                                       alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count)),
                                                       rows: rows)))
                    continue
                }
            }
            if listMarker(line) != nil {
                flushParagraph()
                let (list, next) = parseList(lines, from: index)
                blocks.append(.list(list))
                index = next
                continue
            }
            if paragraph.isEmpty, let image = standaloneImage(trimmed) {
                blocks.append(.image(alt: image.alt, source: image.source))
                index += 1
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Lists

    struct Marker {
        var indent: Int
        var ordinal: Int?
        /// Where the item's text starts (indent + marker + space).
        var contentColumn: Int
        var text: String
    }

    static func listMarker(_ line: String) -> Marker? {
        let indent = leadingSpaces(line)
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }
        if "-*+".contains(first) {
            let rest = body.dropFirst()
            guard rest.first == " " || rest.first == "\t" else { return nil }
            // `* * *` and `- - -` are rules, not items.
            if isRule(String(body)) { return nil }
            let text = rest.drop { $0 == " " || $0 == "\t" }
            return Marker(indent: indent, ordinal: nil, contentColumn: indent + body.count - text.count, text: String(text))
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.first == " " || rest.first == "\t" || rest.isEmpty else { return nil }
        let text = rest.drop { $0 == " " || $0 == "\t" }
        return Marker(indent: indent, ordinal: Int(digits), contentColumn: indent + body.count - text.count, text: String(text))
    }

    static func parseList(_ lines: ArraySlice<String>, from start: Int) -> (MarkdownList, Int) {
        guard let first = listMarker(lines[start]) else { return (MarkdownList(ordered: false, items: []), start + 1) }
        let ordered = first.ordinal != nil
        let baseIndent = first.indent
        var items: [MarkdownList.Item] = []
        var indents: [Int] = [baseIndent]
        var index = start
        var lastContentColumn = first.contentColumn
        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // A blank line ends the list unless another item (or an indented continuation) follows.
                var next = index + 1
                while next < lines.endIndex, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                guard next < lines.endIndex else { index = next; break }
                if let marker = listMarker(lines[next]), marker.indent >= baseIndent,
                   marker.indent > baseIndent || (marker.ordinal != nil) == ordered {
                    index = next
                    continue
                }
                if leadingSpaces(lines[next]) >= lastContentColumn, !items.isEmpty {
                    index = next
                    continue
                }
                break
            }
            if let marker = listMarker(line), marker.indent >= baseIndent {
                // A top-level item of the other kind starts a new list.
                if marker.indent == baseIndent, (marker.ordinal != nil) != ordered, !items.isEmpty { break }
                while let last = indents.last, marker.indent < last, indents.count > 1 { indents.removeLast() }
                if let last = indents.last, marker.indent > last { indents.append(marker.indent) }
                let depth = indents.count - 1
                var text = marker.text
                var checked: Bool?
                if text.hasPrefix("[ ] ") || text == "[ ]" { checked = false; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                else if text.lowercased().hasPrefix("[x] ") || text.lowercased() == "[x]" { checked = true; text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
                items.append(MarkdownList.Item(depth: depth, ordinal: marker.ordinal, checked: checked, text: text))
                lastContentColumn = marker.contentColumn
                index += 1
                continue
            }
            // A lazy or indented continuation of the last item, unless it starts another kind of block.
            if !items.isEmpty, leadingSpaces(line) > baseIndent || !startsBlock(trimmed) {
                if leadingSpaces(line) <= baseIndent, startsBlock(trimmed) { break }
                items[items.count - 1].text += " " + trimmed
                index += 1
                continue
            }
            break
        }
        return (MarkdownList(ordered: ordered, items: items), index)
    }

    /// Lines that begin a block of their own (and so end a lazy list continuation or a paragraph).
    static func startsBlock(_ trimmed: String) -> Bool {
        codeFence(trimmed) != nil || atxHeading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">") || trimmed.hasPrefix("|")
    }

    // MARK: Line kinds

    static func codeFence(_ trimmed: String) -> (marker: String, language: String?)? {
        for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) {
            let run = trimmed.prefix { $0 == fence.first }
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            // A backtick fence's info string can't hold backticks.
            if fence == "```", info.contains("`") { return nil }
            let language = info.split(separator: " ").first.map(String.init)
            return (String(run), language?.isEmpty == false ? language : nil)
        }
        return nil
    }

    static func atxHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s goes.
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (hashes.count, text)
    }

    static func setextLevel(_ trimmed: String) -> Int? {
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }), trimmed.count >= 2 { return 2 }
        return nil
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func standaloneImage(_ trimmed: String) -> (alt: String, source: String)? {
        guard let match = trimmed.wholeMatch(of: /!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/) else { return nil }
        return (String(match.1), String(match.2))
    }

    /// The delimiter row under a table header (`| :--- | ---: |`), as alignments; nil when the line isn't one.
    static func delimiterRow(_ line: String) -> [MarkdownTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespaces)
            guard cell.contains("-"), cell.filter({ $0 != ":" }).allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        // A delimiter row needs a pipe unless it's a single column written with one.
        return trimmed.contains("|") ? alignments : nil
    }

    /// A table row's cells: split on pipes that aren't escaped or inside a code span, outer pipes dropped.
    static func cells(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                current.append(character == "|" ? "|" : "\\")
                if character != "|" { current.append(character) }
                escaped = false
                continue
            }
            switch character {
            case "\\": escaped = true
            case "`": inCode.toggle(); current.append(character)
            case "|" where !inCode:
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(character)
            }
        }
        if escaped { current.append("\\") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), result.first == "" { result.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), result.last == "" { result.removeLast() }
        return result
    }

    static func pad(_ row: [String], to width: Int) -> [String] {
        row.count >= width ? Array(row.prefix(width)) : row + Array(repeating: "", count: width - row.count)
    }

    /// A paragraph's lines: soft breaks become spaces, hard breaks (two trailing spaces or a backslash) newlines.
    static func joinParagraph(_ lines: [String]) -> String {
        var text = ""
        for (offset, line) in lines.enumerated() {
            let hard = line.hasSuffix("  ") || line.hasSuffix("\\")
            var piece = line.trimmingCharacters(in: .whitespaces)
            if piece.hasSuffix("\\") { piece.removeLast() }
            text += piece
            if offset < lines.count - 1 { text += hard ? "\n" : " " }
        }
        return text
    }

    static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }
}
