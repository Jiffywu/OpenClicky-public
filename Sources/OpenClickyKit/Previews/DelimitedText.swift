import Foundation

// CSV and TSV for the spreadsheet preview: RFC 4180 quoting (quoted fields with doubled quotes, delimiters and line
// breaks inside quotes), any line ending, a byte-order mark, and a delimiter guessed from the first lines when the file
// extension doesn't say. The first row is the header, which the grid keeps frozen above the scrolling rows; selection
// sums and counts cover body cells only.

public struct DelimitedTable: Sendable, Hashable {
    /// Every row, the header first, each padded to `columnCount`.
    public var rows: [[String]]
    public var delimiter: Character
    /// True when the file had more rows than were read.
    public var truncated: Bool

    public init(rows: [[String]], delimiter: Character = ",", truncated: Bool = false) {
        let width = rows.map(\.count).max() ?? 0
        self.rows = rows.map { $0.count < width ? $0 + Array(repeating: "", count: width - $0.count) : $0 }
        self.delimiter = delimiter
        self.truncated = truncated
    }

    public var columnCount: Int { rows.first?.count ?? 0 }
    /// The frozen first row.
    public var header: [String] { rows.first ?? [] }
    /// The rows under the header.
    public var body: ArraySlice<[String]> { rows.dropFirst() }
    public var bodyCount: Int { max(0, rows.count - 1) }

    /// A body cell (row 0 is the first row under the header); "" outside the table.
    public func cell(_ cell: GridCell) -> String {
        let row = cell.row + 1
        guard rows.indices.contains(row), rows[row].indices.contains(cell.column) else { return "" }
        return rows[row][cell.column]
    }

    /// Spreadsheet-style column name: A, B, …, Z, AA, AB, …
    public static func columnName(_ index: Int) -> String {
        var name = ""
        var value = index + 1
        while value > 0 {
            let remainder = (value - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            value = (value - 1) / 26
        }
        return name
    }
}

public enum DelimitedText {
    /// The delimiter a file's extension implies (`tsv`/`tab` → tab), else nil (guess).
    public static func delimiter(forExtension ext: String) -> Character? {
        switch ext.lowercased() {
        case "tsv", "tab": "\t"
        case "csv": nil
        default: nil
        }
    }

    /// Reads the first `maxBytes` of a file's text (UTF-8, UTF-16 with a byte-order mark, else Windows-1252; see
    /// `PreviewText`) and parses it; the table is `truncated` when either limit cut the file short.
    public static func read(_ url: URL, maxRows: Int = 5_000, maxBytes: Int = PreviewText.spreadsheetMaxBytes) throws -> DelimitedTable {
        let loaded = try PreviewText.read(url, maxBytes: maxBytes)
        var table = parse(loaded.text, delimiter: delimiter(forExtension: url.pathExtension), maxRows: maxRows)
        if loaded.truncated { table.truncated = true }
        return table
    }

    public static func parse(_ text: String, delimiter: Character? = nil, maxRows: Int = .max) -> DelimitedTable {
        var source = Substring(text)
        if source.first == "\u{FEFF}" { source = source.dropFirst() }
        let delimiter = delimiter ?? guessDelimiter(source)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var truncated = false
        var iterator = source.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
            fieldStarted = false
        }
        func endRow() {
            endField()
            // A line with nothing on it (not even a delimiter) is skipped.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if rows.count >= maxRows {
                truncated = true
                break
            }
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where !fieldStarted:
                inQuotes = true
                fieldStarted = true
            case delimiter:
                endField()
            case "\r\n", "\n", "\r":
                endRow()
            default:
                field.append(character)
                fieldStarted = true
            }
        }
        if !truncated, !field.isEmpty || !row.isEmpty || fieldStarted { endRow() }
        return DelimitedTable(rows: rows, delimiter: delimiter, truncated: truncated)
    }

    /// The candidate (comma, semicolon, tab, pipe) that splits the first lines most consistently into more than one
    /// field. Quoted text is skipped while counting.
    static func guessDelimiter(_ text: Substring) -> Character {
        let candidates: [Character] = [",", "\t", ";", "|"]
        var counts: [Character: [Int]] = [:]
        var line: [Character: Int] = [:]
        var lines = 0
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if character == "\n" || character == "\r\n" || character == "\r" {
                for candidate in candidates { counts[candidate, default: []].append(line[candidate] ?? 0) }
                line = [:]
                lines += 1
                if lines >= 20 { break }
                continue
            }
            if candidates.contains(character) { line[character, default: 0] += 1 }
        }
        if !line.isEmpty { for candidate in candidates { counts[candidate, default: []].append(line[candidate] ?? 0) } }
        var best: (Character, Int) = (",", -1)
        for candidate in candidates {
            let perLine = counts[candidate] ?? []
            guard let first = perLine.first, first > 0 else { continue }
            let consistent = perLine.filter { $0 == first }.count
            let score = consistent * 100 + first
            if score > best.1 { best = (candidate, score) }
        }
        return best.0
    }
}

// MARK: - Selection

/// A body cell: row 0 is the first row under the frozen header.
public struct GridCell: Sendable, Hashable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// A rectangle of cells from where the selection started to where it reaches (click, then shift-click).
public struct GridSelection: Sendable, Hashable {
    public var anchor: GridCell
    public var focus: GridCell

    public init(_ cell: GridCell) {
        anchor = cell
        focus = cell
    }

    public init(anchor: GridCell, focus: GridCell) {
        self.anchor = anchor
        self.focus = focus
    }

    public var rows: ClosedRange<Int> { min(anchor.row, focus.row)...max(anchor.row, focus.row) }
    public var columns: ClosedRange<Int> { min(anchor.column, focus.column)...max(anchor.column, focus.column) }

    public func contains(_ cell: GridCell) -> Bool { rows.contains(cell.row) && columns.contains(cell.column) }

    /// Extends to `cell` (shift-click), keeping the anchor.
    public func extended(to cell: GridCell) -> GridSelection { GridSelection(anchor: anchor, focus: cell) }

    /// The whole column under the header.
    public static func column(_ column: Int, in table: DelimitedTable) -> GridSelection {
        GridSelection(anchor: GridCell(row: 0, column: column), focus: GridCell(row: max(0, table.bodyCount - 1), column: column))
    }
}

/// What a spreadsheet's status bar shows for a selection: how many cells have something in them, and the sum and
/// average of the ones that are numbers.
public struct GridSelectionSummary: Sendable, Hashable {
    public var count: Int
    public var numericCount: Int
    public var sum: Double
    public var average: Double? { numericCount > 0 ? sum / Double(numericCount) : nil }

    public init(table: DelimitedTable, selection: GridSelection) {
        var count = 0
        var numbers = 0
        var sum = 0.0
        let rowRange = max(0, selection.rows.lowerBound)...max(0, selection.rows.upperBound)
        let columnRange = max(0, selection.columns.lowerBound)...max(0, selection.columns.upperBound)
        let rows = rowRange.clamped(to: 0...max(0, table.bodyCount - 1))
        let columns = columnRange.clamped(to: 0...max(0, table.columnCount - 1))
        if table.bodyCount > 0, table.columnCount > 0, rowRange.overlaps(rows), columnRange.overlaps(columns) {
            for row in rows {
                for column in columns {
                    let text = table.cell(GridCell(row: row, column: column))
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    count += 1
                    if let value = Self.number(text) {
                        numbers += 1
                        sum += value
                    }
                }
            }
        }
        self.count = count
        numericCount = numbers
        self.sum = sum
    }

    /// "Count 4 · Sum 1,234.5 · Average 308.63", or just the count when nothing selected is a number.
    public var text: String {
        var parts = ["Count \(count)"]
        if numericCount > 0 {
            parts.append("Sum \(Self.format(sum))")
            if let average { parts.append("Average \(Self.format(average))") }
        }
        return parts.joined(separator: " · ")
    }

    /// A cell's number: thousands separators, a currency sign, a percent (as a fraction) and accounting parentheses
    /// for negatives are understood; anything else with letters in it isn't a number.
    public static func number(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        var negative = false
        if value.hasPrefix("("), value.hasSuffix(")") {
            negative = true
            value = String(value.dropFirst().dropLast())
        }
        var percent = false
        if value.hasSuffix("%") {
            percent = true
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("-") || value.hasPrefix("\u{2212}") {
            negative.toggle()
            value.removeFirst()
        } else if value.hasPrefix("+") {
            value.removeFirst()
        }
        let currency: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "₺", "₫", "₪", "฿"]
        value = String(value.drop { currency.contains($0) || $0 == " " })
        while let last = value.last, currency.contains(last) || last == " " { value.removeLast() }
        // Thousands separators: commas between digit groups.
        if value.contains(",") {
            guard value.range(of: #"^\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
            value = value.replacingOccurrences(of: ",", with: "")
        }
        guard value.range(of: #"^(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil, var number = Double(value) else {
            return nil
        }
        if percent { number /= 100 }
        return negative ? -number : number
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
