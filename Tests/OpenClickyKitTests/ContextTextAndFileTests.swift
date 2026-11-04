import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OpenClickyKit

@Suite("Readable text")
struct ReadableTextTests {
    @Test func cleaningCollapsesWhitespaceAndInvisibleCharacters() {
        let raw = "  Title\u{200B}  \r\n\r\n\r\n\tBody\u{00A0}\u{00A0}text   here  \n\n\n\nEnd\u{00AD}ing \n\n"
        #expect(ReadableText.clean(raw) == "Title\n\nBody text here\n\nEnding")
        #expect(ReadableText.clean("\n\n  \n") == "")
    }

    @Test func truncationPrefersBoundaries() {
        let text = "First paragraph is here.\n\nSecond paragraph goes on and on."
        let cut = ReadableText.truncate(text, maxCharacters: 30)
        #expect(cut.truncated)
        #expect(cut.text == "First paragraph is here.")
        let words = ReadableText.truncate("alpha beta gamma delta", maxCharacters: 13)
        #expect(words.text == "alpha beta")
        // No boundary nearby: hard cut.
        let hard = ReadableText.truncate(String(repeating: "x", count: 50), maxCharacters: 20)
        #expect(hard.text.count == 20)
        #expect(ReadableText.truncate("short", maxCharacters: 20) == ("short", false))
        #expect(ReadableText.truncate("abc", maxCharacters: 0) == ("", true))
    }

    @Test func hostsAndAddresses() {
        #expect(ReadableText.host(of: "https://www.Example.com/path?q=1") == "example.com")
        #expect(ReadableText.host(of: "docs.swift.org/swift-book") == "docs.swift.org")
        #expect(ReadableText.host(of: "not a url") == nil)
        #expect(ReadableText.normalizedAddress("example.com/a b") == nil)
        #expect(ReadableText.normalizedAddress("example.com/path") == "https://example.com/path")
        #expect(ReadableText.normalizedAddress("localhost:3000/app") == "http://localhost:3000/app")
        #expect(ReadableText.normalizedAddress("192.168.1.10/admin") == "http://192.168.1.10/admin")
        #expect(ReadableText.normalizedAddress("https://a.test/x") == "https://a.test/x")
        #expect(ReadableText.normalizedAddress("file:///Users/me/a.html") == "file:///Users/me/a.html")
        #expect(ReadableText.normalizedAddress("how do I bake bread") == nil)
        #expect(ReadableText.normalizedAddress("Favorites") == nil)
        #expect(ReadableText.normalizedAddress("") == nil)
    }

    @Test func htmlBecomesText() {
        let html = """
        <html><head><style>p{color:red}</style><script>var x = "<p>no</p>";</script></head>
        <body><h1>Recipe</h1><p>Mix &amp; bake.</p><ul><li>Flour</li><li>Water</li></ul><br>Done&nbsp;now</body></html>
        """
        #expect(ReadableText.textFromHTML(html) == "Recipe\nMix & bake.\nFlour\nWater\n\nDone now")
    }

    @Test func cutMultibyteSequencesAreDropped() {
        let full = Data("héllo €".utf8)
        // Cut in the middle of the 3-byte euro sign.
        let cut = full.prefix(full.count - 1)
        #expect(ReadableText.decodeTextPrefix(Data(cut), isComplete: false) == "héllo ")
        #expect(ReadableText.decodeTextPrefix(full, isComplete: true) == "héllo €")
        // Legacy 8-bit text falls back to Latin-1.
        #expect(ReadableText.decodeTextPrefix(Data([0x63, 0x61, 0x66, 0xE9]), isComplete: true) == "café")
    }

    @Test func textSniffing() {
        #expect(ReadableText.looksLikeText(Data("plain\ttext\nlines".utf8)))
        #expect(!ReadableText.looksLikeText(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        #expect(ReadableText.looksLikeText(Data()))
    }

    @Test func addressBarHeuristics() {
        #expect(AddressBarHeuristics.isAddressField(role: "AXTextField", identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", description: nil, title: nil, placeholder: nil))
        #expect(AddressBarHeuristics.isAddressField(role: "AXTextField", identifier: nil, description: "Address and search bar", title: nil, placeholder: nil))
        #expect(AddressBarHeuristics.isAddressField(role: "AXComboBox", identifier: "urlbar-input", description: nil, title: nil, placeholder: nil))
        #expect(AddressBarHeuristics.isAddressField(role: "AXTextField", identifier: nil, description: nil, title: nil, placeholder: "Search or enter website name"))
        #expect(!AddressBarHeuristics.isAddressField(role: "AXTextField", identifier: "comment-box", description: "Write a comment", title: nil, placeholder: nil))
        #expect(!AddressBarHeuristics.isAddressField(role: "AXTextField", identifier: nil, description: "curl options", title: nil, placeholder: nil))
        #expect(!AddressBarHeuristics.isAddressField(role: "AXButton", identifier: "address", description: nil, title: nil, placeholder: nil))
    }
}

/// A fresh temporary directory per test.
private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A two-page PDF with real text, drawn with Core Text.
private func writePDF(to url: URL, pages: [String]) throws {
    var box = CGRect(x: 0, y: 0, width: 400, height: 300)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
    for text in pages {
        context.beginPDFPage(nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: 14) as CTFont]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 20, y: 250)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

@Suite("Document files")
struct DocumentFileReaderTests {
    @Test func readsPlainText() throws {
        let dir = try scratchDirectory()
        let url = dir.appendingPathComponent("notes.md")
        try "# Notes\r\nLine two\n".write(to: url, atomically: true, encoding: .utf8)
        let result = try DocumentFileReader.read(url)
        #expect(result.kind == .textFile)
        #expect(result.text == "# Notes\nLine two\n")
        #expect(!result.isTruncated)
        #expect(result.byteCount == 18)
    }

    @Test func limitsBytesAndCharacters() throws {
        let dir = try scratchDirectory()
        let url = dir.appendingPathComponent("big.log")
        try String(repeating: "0123456789\n", count: 2_000).write(to: url, atomically: true, encoding: .utf8)
        let byBytes = try DocumentFileReader.read(url, limits: DocumentLimits(maxCharacters: 1_000_000, maxTextBytes: 1_000))
        #expect(byBytes.isTruncated)
        #expect((byBytes.text?.utf8.count ?? 0) <= 1_000)
        let byChars = try DocumentFileReader.read(url, limits: DocumentLimits(maxCharacters: 500))
        #expect(byChars.isTruncated)
        #expect((byChars.text?.count ?? 0) <= 500)
        #expect(byChars.byteCount == 22_000)
    }

    @Test func sourceCodeKeepsIndentation() throws {
        let dir = try scratchDirectory()
        let url = dir.appendingPathComponent("main.swift")
        try "func f() {\n    return\n}\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(try DocumentFileReader.read(url).text == "func f() {\n    return\n}\n")
    }

    @Test func binaryFilesHaveNoText() throws {
        let dir = try scratchDirectory()
        let url = dir.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x10]).write(to: url)
        let result = try DocumentFileReader.read(url)
        #expect(result.kind == .file)
        #expect(result.text == nil)
        let image = dir.appendingPathComponent("shot.png")
        try ImageCoding.pngData(makeTestImage(width: 8, height: 8)).write(to: image)
        #expect(try DocumentFileReader.read(image).kind == .file)
    }

    @Test func htmlFilesReadAsText() throws {
        let dir = try scratchDirectory()
        let url = dir.appendingPathComponent("page.html")
        try "<p>Hello <b>there</b></p><p>Bye</p>".write(to: url, atomically: true, encoding: .utf8)
        #expect(try DocumentFileReader.read(url).text == "Hello there\nBye")
    }

    @Test func richTextReadsThroughAppKit() throws {
        let dir = try scratchDirectory()
        let url = dir.appendingPathComponent("letter.rtf")
        let attributed = NSAttributedString(string: "Dear Sam,\nThe quarterly numbers are in.")
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: url)
        let result = try DocumentFileReader.read(url)
        #expect(result.kind == .richText)
        #expect(result.text == "Dear Sam,\nThe quarterly numbers are in.")
    }

    @Test func pdfTextAndPageCount() throws {
        let dir = try scratchDirectory()
        let url = dir.appendingPathComponent("report.pdf")
        try writePDF(to: url, pages: ["Revenue grew nine percent", "Costs fell slightly"])
        let result = try DocumentFileReader.read(url)
        #expect(result.kind == .pdf)
        #expect(result.pageCount == 2)
        #expect(result.text?.contains("Revenue grew nine percent") == true)
        #expect(result.text?.contains("Costs fell slightly") == true)
        let onePage = try DocumentFileReader.read(url, limits: DocumentLimits(maxPDFPages: 1))
        #expect(onePage.isTruncated)
        #expect(onePage.text?.contains("Costs") == false)
    }

    @Test func missingAndUnreadableFiles() throws {
        let dir = try scratchDirectory()
        #expect(throws: DocumentReadError.notFound) { try DocumentFileReader.read(dir.appendingPathComponent("gone.txt")) }
        let locked = dir.appendingPathComponent("locked.txt")
        try "secret".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        #expect(throws: DocumentReadError.accessDenied) { try DocumentFileReader.read(locked) }
    }
}

@Suite("Guarded folders")
struct GuardedFolderTests {
    let classifier = GuardedFolderClassifier(homeDirectory: URL(fileURLWithPath: "/Users/sam"))

    @Test func classifiesByPathAlone() {
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Users/sam/Desktop/a.pdf")) == .desktop)
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Users/sam/Documents/Work/b.txt")) == .documents)
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Users/sam/Downloads/c.zip")) == .downloads)
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Users/sam/Library/Mobile Documents/com~apple~CloudDocs/d.md")) == .iCloudDrive)
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Users/sam/Library/CloudStorage/Dropbox/e.key")) == .cloudStorage)
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Volumes/USB/f.txt")) == .volumes)
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Users/sam/Developer/g.swift")) == nil)
        // A sibling whose name only starts the same isn't inside.
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Users/sam/DesktopBackup/h.txt")) == nil)
        #expect(classifier.folder(for: URL(fileURLWithPath: "/Users/sam/Desktop/../Developer/i.txt")) == nil)
        #expect(classifier.folder(for: URL(string: "https://example.com/Desktop/x")!) == nil)
    }

    @Test func ledgerRemembersFirstReads() {
        let storage = InMemoryGuardedFolderStorage()
        let ledger = GuardedFolderLedger(classifier: classifier, storage: storage)
        let file = URL(fileURLWithPath: "/Users/sam/Documents/plan.txt")
        #expect(ledger.firstReadFolder(for: file) == .documents)
        ledger.recordSuccessfulRead(of: file)
        #expect(ledger.firstReadFolder(for: file) == nil)
        #expect(ledger.firstReadFolder(for: URL(fileURLWithPath: "/Users/sam/Desktop/x.txt")) == .desktop)
        #expect(storage.load() == ["documents"])
        // A new ledger over the same storage remembers.
        #expect(GuardedFolderLedger(classifier: classifier, storage: storage).hasRead(from: .documents))
        ledger.forget(.documents)
        #expect(ledger.firstReadFolder(for: file) == .documents)
        #expect(storage.load().isEmpty)
        // Unguarded files never need a first read.
        #expect(ledger.firstReadFolder(for: URL(fileURLWithPath: "/tmp/x.txt")) == nil)
    }
}
