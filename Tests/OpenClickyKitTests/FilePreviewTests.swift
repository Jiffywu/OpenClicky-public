import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenClickyKit

@Suite struct MarkdownBlockParserTests {
    @Test func headingsParagraphsAndRules() {
        let blocks = MarkdownBlockParser.parse("""
            # Trip plan ##
            A **short** intro
            that wraps.\u{20}\u{20}
            New line here.

            Setext title
            ============
            Sub title
            ---
            * * *
            #not a heading
            """)
        #expect(blocks == [
            .heading(level: 1, text: "Trip plan"),
            .paragraph("A **short** intro that wraps.\nNew line here."),
            .heading(level: 1, text: "Setext title"),
            .heading(level: 2, text: "Sub title"),
            .rule,
            .paragraph("#not a heading"),
        ])
    }

    @Test func nestedListsTasksAndContinuations() {
        let blocks = MarkdownBlockParser.parse("""
            - Book flights
              - Compare fares
                with a lazy line
            - [x] Pack
            - [ ] Water plants

            1. First
            2) Second
            10. Tenth
            Text after.
            """)
        #expect(blocks == [
            .list(MarkdownList(ordered: false, items: [
                .init(depth: 0, text: "Book flights"),
                .init(depth: 1, text: "Compare fares with a lazy line"),
                .init(depth: 0, checked: true, text: "Pack"),
                .init(depth: 0, checked: false, text: "Water plants"),
            ])),
            .list(MarkdownList(ordered: true, items: [
                .init(depth: 0, ordinal: 1, text: "First"),
                .init(depth: 0, ordinal: 2, text: "Second"),
                .init(depth: 0, ordinal: 10, text: "Tenth Text after."),
            ])),
        ])
    }

    @Test func aBlankLineBetweenItemsKeepsOneList() {
        let blocks = MarkdownBlockParser.parse("- one\n\n- two\n\nAfter")
        #expect(blocks == [.list(MarkdownList(ordered: false, items: [.init(text: "one"), .init(text: "two")])), .paragraph("After")])
    }

    @Test func fencedCodeKeepsItsTextAndLanguage() {
        let blocks = MarkdownBlockParser.parse("""
            ```swift
            let x = 1
            # not a heading
            | not | a table |
            ```
            ~~~
            plain
            ~~~
            ```
            unclosed
            """)
        #expect(blocks == [
            .code(language: "swift", text: "let x = 1\n# not a heading\n| not | a table |"),
            .code(language: nil, text: "plain"),
            .code(language: nil, text: "unclosed"),
        ])
    }

    @Test func pipeTablesWithAlignmentEscapesAndRaggedRows() {
        let blocks = MarkdownBlockParser.parse("""
            | City | Nights | Cost |
            | :--- | :----: | ---: |
            | Lisbon | 3 | $420 |
            | Porto \\| Braga | 2 |
            | `a|b` | 1 | $90 | extra |
            Next paragraph
            """)
        #expect(blocks == [
            .table(MarkdownTable(header: ["City", "Nights", "Cost"], alignments: [.leading, .center, .trailing], rows: [
                ["Lisbon", "3", "$420"],
                ["Porto | Braga", "2", ""],
                ["`a|b`", "1", "$90"],
            ])),
            .paragraph("Next paragraph"),
        ])
        // Without outer pipes too.
        #expect(MarkdownBlockParser.parse("a | b\n--|--\n1 | 2") ==
                [.table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]]))])
        // A pipe in a sentence with no delimiter row is just a paragraph.
        #expect(MarkdownBlockParser.parse("this | that") == [.paragraph("this | that")])
    }

    @Test func quotesImagesAndOddInput() {
        let blocks = MarkdownBlockParser.parse("""
            > ## Note
            > Keep receipts.
            >
            > - one

            ![Chart of spending](output/chart.gif)
            ![inline](x.png) with text
            """)
        #expect(blocks == [
            .quote([.heading(level: 2, text: "Note"), .paragraph("Keep receipts."), .list(MarkdownList(ordered: false, items: [.init(text: "one")]))]),
            .image(alt: "Chart of spending", source: "output/chart.gif"),
            .paragraph("![inline](x.png) with text"),
        ])
        #expect(MarkdownBlockParser.parse("").isEmpty)
        #expect(MarkdownBlockParser.parse("\u{FEFF}# Hi\r\nthere\r\n") == [.heading(level: 1, text: "Hi"), .paragraph("there")])
    }

    @Test func aLongRunOfQuoteMarkersNestsOnlySoDeep() {
        // One quote level per `>` used to recurse once per character; 50,000 of them overflowed the stack.
        let markers = 50_000
        var blocks = MarkdownBlockParser.parse(String(repeating: ">", count: markers) + " hi")
        var depth = 0
        while case .quote(let inner) = blocks.first, blocks.count == 1 {
            depth += 1
            blocks = inner
        }
        #expect(depth == MarkdownBlockParser.maxQuoteDepth)
        #expect(blocks == [.paragraph(String(repeating: ">", count: markers - MarkdownBlockParser.maxQuoteDepth) + " hi")],
                "the deeper markers stay as text")
        // Ordinary nesting is unchanged.
        #expect(MarkdownBlockParser.parse(">> deep") == [.quote([.quote([.paragraph("deep")])])])
    }
}

@Suite struct DelimitedTextTests {
    @Test func quotedFieldsWithCommasQuotesAndLineBreaks() {
        let table = DelimitedText.parse("Name,Note,Amount\r\n\"Smith, Jo\",\"Said \"\"hi\"\"\",12\n\"Multi\nline\",,\"3,400.50\"\nLast,unquoted \"mid\" quote,7\n")
        #expect(table.delimiter == ",")
        #expect(table.header == ["Name", "Note", "Amount"])
        #expect(Array(table.body) == [
            ["Smith, Jo", "Said \"hi\"", "12"],
            ["Multi\nline", "", "3,400.50"],
            ["Last", "unquoted \"mid\" quote", "7"],
        ])
        #expect(!table.truncated)
    }

    @Test func delimitersAreGuessedOrTakenFromTheExtension() {
        #expect(DelimitedText.parse("a;b;c\n1;2;3").delimiter == ";")
        #expect(DelimitedText.parse("a\tb\n1\t2").delimiter == "\t")
        #expect(DelimitedText.parse("\"x,y\";z\n1;2").delimiter == ";", "commas inside quotes don't count")
        #expect(DelimitedText.delimiter(forExtension: "TSV") == "\t")
        let tsv = DelimitedText.parse("a,b\tc\n1,2\t3", delimiter: "\t")
        #expect(tsv.header == ["a,b", "c"])
    }

    @Test func raggedRowsBlankLinesAndLimits() {
        let table = DelimitedText.parse("\u{FEFF}h1,h2,h3\n1\n\n4,5,6,7\n")
        #expect(table.columnCount == 4)
        #expect(table.header == ["h1", "h2", "h3", ""])
        #expect(Array(table.body) == [["1", "", "", ""], ["4", "5", "6", "7"]])
        let capped = DelimitedText.parse("h\n1\n2\n3\n4", maxRows: 3)
        #expect(capped.rows.count == 3 && capped.truncated)
        #expect(DelimitedText.parse("").rows.isEmpty)
        #expect(DelimitedText.parse("a,b,").header == ["a", "b", ""], "a trailing delimiter is an empty last field")
    }

    @Test func theHeaderIsFrozenOutOfTheSelection() {
        let table = DelimitedText.parse("Item,Qty,Price\nApples,3,$1.20\nPears,,\"$2,000\"\nNotes,many,(5)\n")
        #expect(table.bodyCount == 3)
        #expect(table.cell(GridCell(row: 0, column: 0)) == "Apples", "row 0 is the first row under the header")
        #expect(table.cell(GridCell(row: 9, column: 9)) == "")
        // A whole column: the header "Price" never counts.
        let price = GridSelectionSummary(table: table, selection: .column(2, in: table))
        #expect(price.count == 3)
        #expect(price.numericCount == 3)
        #expect(price.sum == 1.2 + 2000 - 5)
        #expect(price.text == "Count 3 · Sum 1,996.2 · Average 665.4")
        // A rectangle dragged backwards, with an empty cell and text.
        let rect = GridSelection(anchor: GridCell(row: 2, column: 1), focus: GridCell(row: 0, column: 0))
        #expect(rect.rows == 0...2 && rect.columns == 0...1)
        let summary = GridSelectionSummary(table: table, selection: rect)
        #expect(summary.count == 5, "the empty Qty cell isn't counted")
        #expect(summary.numericCount == 1 && summary.sum == 3)
        #expect(GridSelectionSummary(table: table, selection: GridSelection(GridCell(row: 0, column: 0))).text == "Count 1")
        // Out of range selects nothing (and never crashes).
        #expect(GridSelectionSummary(table: table, selection: GridSelection(GridCell(row: 40, column: 40))).count == 0)
        #expect(GridSelection(GridCell(row: 1, column: 1)).extended(to: GridCell(row: 2, column: 2)).contains(GridCell(row: 2, column: 1)))
        #expect(DelimitedTable.columnName(0) == "A" && DelimitedTable.columnName(25) == "Z" && DelimitedTable.columnName(27) == "AB")
    }

    @Test func filesThatAreNotUTF8AreDecodedByTheirMarkOrAsWindows1252() throws {
        func file(_ bytes: [UInt8]) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).csv")
            try Data(bytes).write(to: url)
            return url
        }
        // A Windows-1252 export with an even byte count used to decode as BOM-less UTF-16: one column of CJK.
        let latin = try file(Array("name,city\nAna,Caf".utf8) + [0xE9])
        defer { try? FileManager.default.removeItem(at: latin) }
        #expect(try DelimitedText.read(latin).rows == [["name", "city"], ["Ana", "Café"]])
        #expect(PreviewText.decode(Data([0x93, 0x51, 0x94, 0x80])) == "\u{201C}Q\u{201D}€", "Windows-1252 quotes and euro")
        // UTF-16 with a byte-order mark, either way round.
        let little = try file([0xFF, 0xFE] + "a,b\n1,2".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        defer { try? FileManager.default.removeItem(at: little) }
        #expect(try DelimitedText.read(little).rows == [["a", "b"], ["1", "2"]])
        #expect(PreviewText.decode(Data([0xFE, 0xFF] + "é".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })).replacingOccurrences(of: "\u{FEFF}", with: "") == "é")
        #expect(PreviewText.decode(Data("Café".utf8)) == "Café")
    }

    @Test func bigFilesAreReadOnlyUpToALimitAtALineBreak() throws {
        func file(_ bytes: [UInt8]) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).csv")
            try Data(bytes).write(to: url)
            return url
        }
        // A CSV far past the byte limit: only whole rows inside the limit are read, and the table says it was cut.
        let rows = (0..<1_000).map { "row\($0),\($0)" }.joined(separator: "\n")
        let big = try file(Array("name,value\n\(rows)\n".utf8))
        defer { try? FileManager.default.removeItem(at: big) }
        let table = try DelimitedText.read(big, maxBytes: 38)
        #expect(table.truncated)
        #expect(table.rows == [["name", "value"], ["row0", "0"], ["row1", "1"], ["row2", "2"]], "\"row3,3\\n\" ends at byte 39")
        #expect(try !DelimitedText.read(big).truncated, "the default limit holds the whole file")

        // No line break inside the limit: a multi-byte character isn't split (that would fail UTF-8 and fall back).
        let accents = try file(Array("éééééé".utf8))
        defer { try? FileManager.default.removeItem(at: accents) }
        #expect(try PreviewText.read(accents, maxBytes: 5) == PreviewText.Loaded(text: "éé", truncated: true))
        #expect(try PreviewText.read(accents, maxBytes: 12) == PreviewText.Loaded(text: "éééééé", truncated: false))

        // UTF-16 is cut at a whole line break in either byte order.
        let text = "a,b\n1,2\n3,4"
        for bigEndian in [false, true] {
            let units = text.utf16.flatMap { bigEndian ? [UInt8($0 >> 8), UInt8($0 & 0xFF)] : [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let url = try file((bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) + units)
            defer { try? FileManager.default.removeItem(at: url) }
            let loaded = try PreviewText.read(url, maxBytes: 19)
            #expect(loaded.truncated)
            #expect(loaded.text.replacingOccurrences(of: "\u{FEFF}", with: "") == "a,b\n1,2\n", "big-endian: \(bigEndian)")
        }
    }

    @Test func numbersInCells() {
        #expect(GridSelectionSummary.number("1,234.5") == 1234.5)
        #expect(GridSelectionSummary.number("€ 12") == 12)
        #expect(GridSelectionSummary.number("12%") == 0.12)
        #expect(GridSelectionSummary.number("(3.50)") == -3.5)
        #expect(GridSelectionSummary.number("-$4") == -4)
        #expect(GridSelectionSummary.number("1e3") == 1000)
        #expect(GridSelectionSummary.number("12 apples") == nil)
        #expect(GridSelectionSummary.number("1,23") == nil)
        #expect(GridSelectionSummary.number("") == nil)
    }
}

@Suite struct FilePreviewKindTests {
    static func animatedImage(type: UTType, frames: Int, delay: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        let space = CGColorSpaceCreateDeviceRGB()
        for frame in 0..<frames {
            let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: Double(frame) / Double(max(1, frames - 1)), green: 0.3, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let properties: [CFString: Any] = type == .gif
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func kindsByExtensionAndContent() throws {
        #expect(FilePreviewKind.classify("/tmp/report.md") == .markdown)
        #expect(FilePreviewKind.classify("/tmp/data.CSV") == .spreadsheet)
        #expect(FilePreviewKind.classify("/tmp/data.tsv") == .spreadsheet)
        #expect(FilePreviewKind.classify("/tmp/a.pdf") == .pdf)
        #expect(FilePreviewKind.classify("/tmp/budget.xlsx") == .quickLook, "XLSX falls back to Quick Look")
        #expect(FilePreviewKind.classify("/tmp/deck.key") == .quickLook)
        #expect(FilePreviewKind.classify("https://example.com/a.pdf") == .link)

        let gif = try Self.animatedImage(type: .gif, frames: 3, delay: 0.25)
        defer { try? FileManager.default.removeItem(at: gif) }
        #expect(FilePreviewKind.classify(gif.path) == .animatedImage)
        let frames = try #require(AnimatedImageReader.frames(gif))
        #expect(frames.count == 3)
        #expect(frames.delays.allSatisfy { abs($0 - 0.25) < 0.01 })

        let apng = try Self.animatedImage(type: .png, frames: 2, delay: 0.5)
        defer { try? FileManager.default.removeItem(at: apng) }
        #expect(AnimatedImageReader.isAPNG(apng))
        #expect(FilePreviewKind.classify(apng.path) == .animatedImage)
        #expect(try #require(AnimatedImageReader.frames(apng)).delays.allSatisfy { abs($0 - 0.5) < 0.01 })

        let still = try Self.animatedImage(type: .png, frames: 1, delay: 0)
        defer { try? FileManager.default.removeItem(at: still) }
        #expect(!AnimatedImageReader.isAPNG(still))
        #expect(FilePreviewKind.classify(still.path) == .quickLook)
        #expect(AnimatedImageReader.delay([:]) == 0.1)
    }
}
